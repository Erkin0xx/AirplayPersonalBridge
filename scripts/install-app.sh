#!/usr/bin/env bash
# Compile l'app en Release, la signe avec l'identité stable et l'installe.
#
#   scripts/install-app.sh                         installe dans /Applications
#   scripts/install-app.sh --open                  … puis lance l'app
#   scripts/install-app.sh --destination <dossier> installe ailleurs (essai) : ne touche ni à
#                                                  /Applications, ni à l'instance installée,
#                                                  ni à LaunchServices
#   scripts/install-app.sh --derived-data <dossier> dossier de compilation à utiliser
#
# Pourquoi passer par ce script plutôt que par le bouton Run de Xcode : Xcode signe en ad-hoc
# (aucune équipe de développement), et chaque compilation change alors le CDHash, donc révoque
# l'autorisation « sons du système ». L'identité stable de scripts/setup-signing.sh garde la
# même exigence désignée d'une installation à l'autre : l'autorisation survit.
#
# Pas de hardened runtime (ENABLE_HARDENED_RUNTIME reste à NO dans le projet) : ce mode exigerait
# l'entitlement `com.apple.security.device.audio-input` pour le micro et n'apporte rien hors
# notarisation, impossible sans compte Developer. Vérifié : le `dlopen` de TCC.framework
# fonctionne avec ou sans lui, un framework système échappe à la library validation.

set -euo pipefail

APP_DISPLAY_NAME="AirPlay Personal Bridge"
PRODUCT_NAME="AirplayPersonalBridge"
BUNDLE_ID="fr.baptiste.airplaymultioutput.AirplayPersonalBridge"
DEFAULT_DESTINATION="/Applications"
QUIT_TIMEOUT_SECONDS=20

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT="${REPO_ROOT}/AirplayPersonalBridge/AirplayPersonalBridge.xcodeproj"
SIGNING_SCRIPT="${SCRIPT_DIR}/setup-signing.sh"

log() { printf '\n==> %s\n' "$1"; }
die() { printf 'ERREUR : %s\n' "$1" >&2; exit 1; }

DESTINATION="$DEFAULT_DESTINATION"
# Hors du dépôt : Xcode y écrit des centaines de Mo, et `git add -A` du hook de fin de tour ne
# doit pas pouvoir les voir. Dossier stable pour garder la compilation incrémentale.
DERIVED_DATA="${HOME}/Library/Caches/fr.baptiste.airplaymultioutput/DerivedData"
OPEN_AFTER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --open) OPEN_AFTER=1 ;;
    --destination)
      [ $# -ge 2 ] || die "--destination attend un dossier"
      DESTINATION="$2"
      shift
      ;;
    --derived-data)
      [ $# -ge 2 ] || die "--derived-data attend un dossier"
      DERIVED_DATA="$2"
      shift
      ;;
    -h|--help)
      sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "option inconnue : $1 (voir --help)" ;;
  esac
  shift
done

[ -d "$DESTINATION" ] || die "dossier de destination introuvable : ${DESTINATION}"
DESTINATION="$(cd "$DESTINATION" && pwd -P)"
APP_DEST="${DESTINATION}/${APP_DISPLAY_NAME}.app"
BUILT_APP="${DERIVED_DATA}/Build/Products/Release/${PRODUCT_NAME}.app"

# --- Identité : décidée avant de compiler, pour ne pas attendre 5 minutes un avertissement ---
if IDENTITY="$("$SIGNING_SCRIPT" --print-identity)"; then
  log "Signature prévue avec l'identité stable ${IDENTITY}."
else
  IDENTITY=""
  printf '\n' >&2
  printf 'AVERTISSEMENT : aucune identité stable, repli sur une signature ad-hoc.\n' >&2
  printf "  L'autorisation « sons du système » sera perdue à CHAQUE réinstallation.\n" >&2
  printf '  Pour y remédier une fois pour toutes : scripts/setup-signing.sh\n' >&2
fi

# --- Compilation ---
# CODE_SIGNING_ALLOWED=NO : Xcode ne signe pas, ce script le fait ensuite. Xcode n'a donc pas à
# trouver l'identité lui-même (il écarte les certificats non approuvés), et n'ouvre aucune
# fenêtre de trousseau.
log "Compilation Release (dossier de travail : ${DERIVED_DATA})..."
BUILD_LOG="$(mktemp -t apb-xcodebuild)"
if ! xcodebuild -project "$PROJECT" -scheme "$PRODUCT_NAME" -configuration Release \
    -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build > "$BUILD_LOG" 2>&1; then
  tail -40 "$BUILD_LOG" >&2
  die "échec de xcodebuild, journal complet : ${BUILD_LOG}"
fi
rm -f "$BUILD_LOG"
[ -x "${BUILT_APP}/Contents/MacOS/${PRODUCT_NAME}" ] || die "produit introuvable : ${BUILT_APP}"

# Une dépendance à Homebrew empêcherait l'app de démarrer après un `brew upgrade` : autant le
# découvrir ici. C'est aussi le filet du `-w` de Package.swift, qui masque les avertissements
# de l'éditeur de liens.
if otool -L "${BUILT_APP}/Contents/MacOS/${PRODUCT_NAME}" | grep -q '/opt/homebrew'; then
  otool -L "${BUILT_APP}/Contents/MacOS/${PRODUCT_NAME}" | grep '/opt/homebrew' >&2
  die "le binaire dépend de Homebrew à l'exécution"
fi

# --- Préparation et signature, à côté de la destination ---
# Même volume : le remplacement final se réduit à un `mv`, et une signature ratée laisse
# l'ancienne version intacte.
STAGE_DIR="$(mktemp -d "${DESTINATION}/.apb-install.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
STAGED_APP="${STAGE_DIR}/${APP_DISPLAY_NAME}.app"
ditto "$BUILT_APP" "$STAGED_APP"
# Attributs étendus : codesign les refuse (« resource fork, Finder information, or similar »).
xattr -cr "$STAGED_APP"

sign_code() {
  if [ -n "$IDENTITY" ]; then
    "$SIGNING_SCRIPT" --codesign --force "$1"
  else
    codesign --force --sign - --timestamp=none "$1"
  fi
}

log "Signature..."
# De l'intérieur vers l'extérieur : le sceau du bundle couvre le code imbriqué. L'app n'en a pas
# aujourd'hui (AudioCore est lié statiquement), mais une extension ajoutée plus tard ne doit pas
# produire un bundle invalide.
if [ -d "${STAGED_APP}/Contents/Frameworks" ] || [ -d "${STAGED_APP}/Contents/PlugIns" ]; then
  while IFS= read -r -d '' nested; do
    sign_code "$nested"
  done < <(find "${STAGED_APP}/Contents" -mindepth 2 -maxdepth 2 \
    \( -path '*/Frameworks/*' -o -path '*/PlugIns/*' \) -print0)
fi
sign_code "$STAGED_APP"

codesign --verify --deep --strict --verbose=2 "$STAGED_APP" \
  || die "signature invalide : l'installation précédente est laissée en place"
REQUIREMENT="$(codesign --display -r- "$STAGED_APP" 2>/dev/null | grep '^designated' || true)"
echo "$REQUIREMENT"

# --- Arrêt de l'instance installée ---
# Seulement l'instance lancée depuis ce chemin précis : un essai vers un dossier de test ne doit
# jamais arrêter l'app installée, ni une compilation lancée depuis Xcode.
running_pid() {
  local pid
  for pid in $(pgrep -x "$PRODUCT_NAME" || true); do
    if [ "$(ps -o comm= -p "$pid" 2>/dev/null)" = "${APP_DEST}/Contents/MacOS/${PRODUCT_NAME}" ]; then
      echo "$pid"
      return 0
    fi
  done
  return 1
}

if PID="$(running_pid)"; then
  log "Arrêt propre de l'instance en cours (pid ${PID})..."
  # SIGTERM, que l'app convertit en « Quitter » (TerminationSignal.swift) : elle ferme ses sessions
  # AirPlay comme sur un Cmd-Q, ce qui évite de laisser un récepteur bloqué sans TEARDOWN. Pas
  # d'AppleEvent `quit` : TCC exige un consentement pour celui-ci aussi (vérifié :
  # AEDeterminePermissionToAutomateTarget rend -1744), donc une fenêtre d'autorisation.
  kill -TERM "$PID"
  waited=0
  while kill -0 "$PID" 2>/dev/null; do
    [ "$waited" -lt "$QUIT_TIMEOUT_SECONDS" ] \
      || die "l'app ne s'arrête pas après ${QUIT_TIMEOUT_SECONDS} s. La quitter à la main puis relancer : l'installation précédente est laissée en place."
    sleep 1
    waited=$((waited + 1))
  done
fi

# --- Remplacement ---
log "Installation dans ${APP_DEST}..."
if [ -e "$APP_DEST" ]; then
  mv "$APP_DEST" "${STAGE_DIR}/previous.app"
fi
if ! mv "$STAGED_APP" "$APP_DEST"; then
  [ ! -e "${STAGE_DIR}/previous.app" ] || mv "${STAGE_DIR}/previous.app" "$APP_DEST"
  die "remplacement impossible : version précédente restaurée"
fi

# LaunchServices et lancement : réservés à une vraie installation. Enregistrer une copie d'essai
# sous le même identifiant de bundle embrouillerait `open -b` et les réglages système.
if [ "$DESTINATION" = "$DEFAULT_DESTINATION" ]; then
  log "Enregistrement auprès de LaunchServices..."
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DEST"
else
  log "Destination d'essai : LaunchServices n'est pas sollicité."
fi

log "Installé : ${APP_DEST}"
if [ -n "$IDENTITY" ]; then
  cat <<EOF

À faire à la main, une seule fois : la première autorisation.
  1. Lancer l'app, puis autoriser « Enregistrement des sons du système » à la première diffusion
     (Réglages Système > Confidentialité et sécurité > Enregistrement de l'écran et des sons du
     système > section « Enregistrement des sons du système uniquement »).
  2. Accepter aussi « Réseau local », sans quoi aucune enceinte n'apparaît.
  Une ancienne entrée signée en ad-hoc reste inopérante ; si le dialogue n'apparaît pas, la purger :
     tccutil reset AudioCapture ${BUNDLE_ID}

Les réinstallations suivantes conservent l'autorisation : l'exigence désignée ne change pas tant
que credentials/signing/ est conservé. Une compilation lancée depuis Xcode (signature ad-hoc)
utilise son propre identifiant de bundle en Debug, elle ne touche pas à cette autorisation.
EOF
else
  cat <<EOF

Signature ad-hoc : l'autorisation « sons du système » est à redonner après chaque installation
(Réglages Système > Confidentialité et sécurité > Enregistrement de l'écran et des sons du
système). Pour que ce soit la dernière fois : scripts/setup-signing.sh, puis réinstaller.
EOF
fi

if [ "$OPEN_AFTER" -eq 1 ]; then
  log "Lancement..."
  open "$APP_DEST"
fi
