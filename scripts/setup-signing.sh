#!/usr/bin/env bash
# Crée une identité de signature de code stable, pour que macOS retienne les autorisations
# d'une compilation à l'autre.
#
#   scripts/setup-signing.sh                   crée ce qui manque, puis vérifie (idempotent)
#   scripts/setup-signing.sh --print-identity  rend l'empreinte SHA-1 sur stdout, prête à
#                                              signer ; code 1 s'il n'y a pas de certificat
#                                              (dans ce mode, aucun certificat n'est créé)
#   scripts/setup-signing.sh --codesign ARGS…  signe : `codesign ARGS…` avec cette identité,
#                                              trousseau déverrouillé juste avant
#
# RÈGLE : ne jamais appeler `codesign` avec cette identité autrement que par `--codesign`.
# Sur un trousseau verrouillé, `codesign` ouvre une fenêtre qui réclame le mot de passe du
# trousseau, que Baptiste n'a pas (il vit dans credentials/signing/). Vérifié à la dure, comme
# `security show-keychain-info`, qui fait de même. Passer par ce point d'entrée rend cette
# fenêtre impossible, y compris après une réouverture de session.
#
# Pourquoi : TCC rattache l'autorisation « sons du système » à l'exigence désignée du binaire.
# Avec une signature ad-hoc, cette exigence est le CDHash lui-même : toute compilation la
# change, et chaque rebuild révoque l'autorisation. Avec un certificat, elle devient
# `identifier "…" and certificate leaf = H"…"`, identique tant que le certificat ne change
# pas. Un compte Apple Developer n'apporte rien de plus à un outil personnel : TCC compare
# une empreinte, il n'exige pas de chaîne de confiance.
#
# Pourquoi un trousseau dédié à mot de passe connu : `codesign` peut alors signer sans aucune
# fenêtre ni mot de passe du trousseau de session. Une identité importée dans le trousseau de
# session demanderait une validation à la première signature de chaque binaire.
#
# Le certificat n'est volontairement pas marqué comme approuvé : `add-trusted-cert` ouvre une
# fenêtre d'authentification, et codesign n'en a pas besoin. `find-identity -v` n'affiche donc
# pas cette identité (il ne liste que les identités approuvées) : c'est normal.
#
# Les fichiers vivent dans <dépôt principal>/credentials/signing/, ignoré par git, et pas dans
# le worktree courant : un worktree est jetable, et perdre `signing.key` changerait l'exigence
# désignée, donc reperdrait l'autorisation. `signing.key` + `signing.crt` sont la seule source
# de vérité : le trousseau et le mot de passe se régénèrent à partir d'eux, à l'identique.

set -euo pipefail

IDENTITY_NAME="AirPlay Personal Bridge Local Signing"
VALIDITY_DAYS=7300

# Le worktree n'a pas de credentials/ : on remonte au dépôt principal, que `--git-common-dir`
# désigne quel que soit le worktree. Hors dépôt git, le parent du script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
COMMON_DIR="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -n "$COMMON_DIR" ]; then
  REPO_ROOT="$(dirname "$COMMON_DIR")"
else
  REPO_ROOT="$(dirname "$SCRIPT_DIR")"
fi

SIGNING_DIR="${REPO_ROOT}/credentials/signing"
KEY_FILE="${SIGNING_DIR}/signing.key"
CERT_FILE="${SIGNING_DIR}/signing.crt"
PASSWORD_FILE="${SIGNING_DIR}/keychain-password"
KEYCHAIN="${SIGNING_DIR}/signing.keychain-db"

# LibreSSL du système, pas l'OpenSSL de Homebrew : ce script ne doit dépendre de rien
# d'installé, et un PKCS#12 d'OpenSSL 3 (AES/PBKDF2 par défaut) est refusé par `security`.
OPENSSL=/usr/bin/openssl

log() { printf '==> %s\n' "$1" >&2; }
die() { printf 'ERREUR : %s\n' "$1" >&2; exit 1; }

# Empreinte SHA-1 de signing.crt, en hexadécimal majuscule sans « : », la forme que
# `security` affiche et que `codesign --sign` accepte.
certificate_sha1() {
  "$OPENSSL" x509 -in "$CERT_FILE" -noout -fingerprint -sha1 | sed -e 's/^.*=//' -e 's/://g'
}

identity_is_in_keychain() {
  # `security` échoue si le trousseau n'existe plus : c'est le même verdict.
  security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$1"
}

# Déverrouille le trousseau. Un trousseau se reverrouille à chaque fermeture de session, et
# codesign ouvrirait alors une fenêtre de mot de passe. Déverrouiller un trousseau déjà ouvert
# est sans effet, d'où un appel systématique. Le mot de passe passe en argument (visible un
# instant dans `ps`) : `security` n'offre pas mieux hors terminal, et il ne protège que cette
# clé locale, déjà lisible sur disque.
unlock_keychain() {
  security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN" 2>/dev/null
}

# Le seul appel à codesign de ce dépôt qui utilise la clé. `--keychain` désigne le trousseau
# explicitement, et le déverrouillage juste avant ferme la fenêtre : un échec ici s'arrête avant
# d'atteindre codesign. `--timestamp=none` : le serveur d'horodatage d'Apple ne signe pas pour
# un certificat auto-signé, inutile de le contacter.
sign_with_identity() {
  local sha1="$1"
  shift
  unlock_keychain || die "impossible de déverrouiller ${KEYCHAIN} : signature annulée"
  codesign --keychain "$KEYCHAIN" --sign "$sha1" --timestamp=none "$@"
}

# Ajoute le trousseau à la liste de recherche, à la fin, sans en retirer aucun autre : le
# trousseau par défaut reste celui de session. Lecture ligne à ligne : ces chemins contiennent
# des espaces, et Bash 3.2 (celui de macOS) n'a pas mapfile.
ensure_in_search_list() {
  local line
  local keychains=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#\"}"
    line="${line%\"}"
    [ -n "$line" ] || continue
    [ "$line" != "$KEYCHAIN" ] || return 0
    keychains+=("$line")
  done < <(security list-keychains -d user)
  log "Ajout du trousseau à la liste de recherche (les autres sont conservés)."
  security list-keychains -d user -s ${keychains[@]+"${keychains[@]}"} "$KEYCHAIN"
}

# Rend le trousseau utilisable à partir de signing.key et signing.crt, quel que soit son état.
#
# Le cas « illisible » n'est pas théorique : après l'annulation d'une fenêtre de mot de passe sur
# ce trousseau verrouillé, il a refusé le bon mot de passe, durablement, à deux reprises. Cause
# non élucidée (non reproduit sur un trousseau d'essai vide). Le recréer est sans risque : il ne
# contient que ce qu'on sait réimporter, et l'exigence désignée ne change pas.
ensure_keychain() {
  local sha1="$1"

  if [ -f "$KEYCHAIN" ] && { [ ! -f "$PASSWORD_FILE" ] || ! unlock_keychain; }; then
    log "Trousseau illisible avec le mot de passe enregistré : il va être recréé."
    security delete-keychain "$KEYCHAIN" 2>/dev/null || rm -f "$KEYCHAIN"
  fi

  if [ ! -f "$PASSWORD_FILE" ]; then
    "$OPENSSL" rand -hex 32 > "$PASSWORD_FILE"
  fi
  local password
  password="$(cat "$PASSWORD_FILE")"

  if [ ! -f "$KEYCHAIN" ]; then
    log "Création du trousseau dédié."
    security create-keychain -p "$password" "$KEYCHAIN"
  fi
  unlock_keychain || die "impossible de déverrouiller ${KEYCHAIN}"
  # Sans option : ni verrouillage après inactivité, ni à la mise en veille. Les réglages par
  # défaut (5 min) feraient échouer une compilation longue au moment de signer.
  security set-keychain-settings "$KEYCHAIN"

  if ! identity_is_in_keychain "$sha1"; then
    log "Import de l'identité dans le trousseau."
    # `-T` autorise codesign sur la clé ; la liste de partition lève la validation d'accès
    # (la fenêtre « codesign souhaite signer ») depuis macOS Sierra. Les deux sont nécessaires.
    # Le PKCS#12 n'est qu'un format de transport : il reste dans le dossier temporaire.
    "$OPENSSL" pkcs12 -export -inkey "$KEY_FILE" -in "$CERT_FILE" -name "$IDENTITY_NAME" \
      -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
      -passout "pass:${password}" -out "${WORK_DIR}/identity.p12"
    security import "${WORK_DIR}/identity.p12" -k "$KEYCHAIN" -P "$password" -f pkcs12 \
      -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$KEYCHAIN" >/dev/null
  fi

  ensure_in_search_list
}

case "${1:-}" in
  "") MODE=setup ;;
  --print-identity) MODE=print ;;
  --codesign)
    MODE=codesign
    shift
    ;;
  *)
    echo "Usage : $0 [--print-identity | --codesign <arguments de codesign>]" >&2
    exit 2
    ;;
esac

if [ "$MODE" != setup ] && { [ ! -f "$KEY_FILE" ] || [ ! -f "$CERT_FILE" ]; }; then
  [ "$MODE" = print ] || echo "Pas d'identité : lancer scripts/setup-signing.sh" >&2
  exit 1
fi

umask 077
mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"
WORK_DIR="$(mktemp -d "${SIGNING_DIR}/.tmp.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

# Appelés par install-app.sh et make-cli-bundle.sh : réparent le trousseau au besoin (session
# rouverte, trousseau verrouillé), mais ne créent jamais de certificat. umask ramené à la
# normale pour --codesign : il ne doit pas décider des droits des fichiers signés.
if [ "$MODE" = print ]; then
  SHA1="$(certificate_sha1)"
  ensure_keychain "$SHA1"
  printf '%s\n' "$SHA1"
  exit 0
elif [ "$MODE" = codesign ]; then
  SHA1="$(certificate_sha1)"
  ensure_keychain "$SHA1"
  umask 022
  sign_with_identity "$SHA1" "$@"
  exit 0
fi

# --- Création de ce qui manque ---

# Un certificat neuf est une nouvelle exigence désignée : ne jamais en créer un tant que les
# deux fichiers existent, et ne pas garder dans le trousseau une identité qui ne sert plus.
if [ ! -f "$KEY_FILE" ] || [ ! -f "$CERT_FILE" ]; then
  log "Création du certificat auto-signé « ${IDENTITY_NAME} »."
  if [ -f "$KEYCHAIN" ]; then
    security delete-keychain "$KEYCHAIN" 2>/dev/null || rm -f "$KEYCHAIN"
  fi
  # Fichier de configuration plutôt que `-addext`, absent de cette version de LibreSSL.
  cat > "${WORK_DIR}/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = codesign
prompt = no
[dn]
CN = ${IDENTITY_NAME}
[codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days "$VALIDITY_DAYS" \
    -config "${WORK_DIR}/openssl.cnf" -keyout "$KEY_FILE" -out "$CERT_FILE" 2>/dev/null
else
  log "Certificat déjà présent : conservé, l'exigence désignée ne change pas."
fi

SHA1="$(certificate_sha1)"
ensure_keychain "$SHA1"

# --- Vérification : deux binaires différents, signés sans fenêtre, même exigence désignée ---
# C'est sur cette exigence que TCC se fonde. Un CDHash qui change avec une exigence identique
# est exactement ce qu'on cherche.
PROBE_ID="fr.baptiste.airplaymultioutput.signing-probe"
probe() {
  printf 'int main(void) { return %s; }\n' "$1" > "${WORK_DIR}/probe.c"
  cc -o "${WORK_DIR}/probe$1" "${WORK_DIR}/probe.c"
  sign_with_identity "$SHA1" --force --identifier "$PROBE_ID" "${WORK_DIR}/probe$1" 2>/dev/null \
    || die "codesign refuse l'identité ${SHA1}"
}
requirement_of() { codesign --display -r- "$1" 2>/dev/null | grep '^designated'; }
cdhash_of() { codesign --display --verbose=3 "$1" 2>&1 | grep '^CDHash=' | head -1; }

probe 1
probe 2
[ "$(requirement_of "${WORK_DIR}/probe1")" = "$(requirement_of "${WORK_DIR}/probe2")" ] \
  || die "l'exigence désignée change d'un binaire à l'autre"
[ "$(cdhash_of "${WORK_DIR}/probe1")" != "$(cdhash_of "${WORK_DIR}/probe2")" ] \
  || die "le test de signature n'a pas produit deux binaires différents"

log "Identité opérationnelle, signature sans fenêtre vérifiée."
log "  empreinte : ${SHA1}"
log "  trousseau : ${KEYCHAIN}"
log "  exigence  : $(requirement_of "${WORK_DIR}/probe1" | sed -e "s/${PROBE_ID}/<bundle>/")"
log "À conserver : ${SIGNING_DIR} (ignoré par git). Le perdre oblige à redonner les autorisations."
