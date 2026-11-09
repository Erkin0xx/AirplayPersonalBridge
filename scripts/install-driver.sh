#!/usr/bin/env bash
# Installe la sortie virtuelle « AirPlay Personal Bridge » et la règle sudoers qui permet à l'app
# de relancer coreaudiod en quittant. À lancer par Baptiste, dans son Terminal :
#
#   Drivers/APBOutput/build.sh          (sans sudo : compile et signe)
#   sudo scripts/install-driver.sh      (copie, règle sudoers, relance de coreaudiod)
#
# Ce script ne compile ni ne signe rien : il tourne en root, et la signature passe par le trousseau
# dédié de l'utilisateur (scripts/setup-signing.sh).
#
# La relance de coreaudiod coupe tout le son du Mac une à deux secondes, et fait reconstruire la
# capture de l'app si elle tourne.
#
# Règle sudoers : /etc/sudoers.d/airplay-bridge (root:wheel, 0440), limitée à une seule commande
# exacte, vérifiée par `visudo -cf` avant d'être mise en place :
#   <utilisateur> ALL=(root) NOPASSWD: /usr/bin/killall coreaudiod
# L'app l'appelle en quittant par `/usr/bin/sudo -n /usr/bin/killall coreaudiod`.

set -euo pipefail

die() { printf 'ERREUR : %s\n' "$1" >&2; exit 1; }
log() { printf '==> %s\n' "$1"; }

[ "$(id -u)" = 0 ] || die "à lancer avec sudo : sudo $0"
USER_NAME="${SUDO_USER:-}"
[ -n "$USER_NAME" ] && [ "$USER_NAME" != root ] || die "lancer avec sudo depuis le compte de l'utilisateur, pas depuis root"
# Le nom entre tel quel dans sudoers : rien d'autre qu'un identifiant de compte ordinaire.
[[ "$USER_NAME" =~ ^[a-z_][a-z0-9_.-]*$ ]] || die "nom d'utilisateur inattendu : $USER_NAME"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SRC="$SCRIPT_DIR/../Drivers/APBOutput/build/APBOutput.driver"
DEST="/Library/Audio/Plug-Ins/HAL/APBOutput.driver"
RULE_FILE="/etc/sudoers.d/airplay-bridge"
RULE="$USER_NAME ALL=(root) NOPASSWD: /usr/bin/killall coreaudiod"

[ -d "$SRC" ] || die "pilote non compilé : lancer d'abord Drivers/APBOutput/build.sh (sans sudo)"
codesign --verify --strict "$SRC" || die "signature du pilote invalide : relancer Drivers/APBOutput/build.sh"

log "Copie du pilote dans $DEST"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
chown -R root:wheel "$DEST"
chmod -R go-w "$DEST"

log "Règle sudoers : $RULE"
grep -Eq '^#includedir[[:space:]]+(/private)?/etc/sudoers\.d' /etc/sudoers \
  || die "/etc/sudoers n'inclut pas /etc/sudoers.d : règle non posée"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$RULE" > "$TMP"
visudo -cf "$TMP" >/dev/null || die "visudo refuse la règle : rien n'a été posé"
install -m 0440 -o root -g wheel "$TMP" "$RULE_FILE"
if ! visudo -c >/dev/null; then
  rm -f "$RULE_FILE"
  die "la configuration sudo complète ne passe plus visudo : règle retirée"
fi
sudo -u "$USER_NAME" /usr/bin/sudo -n -l /usr/bin/killall coreaudiod >/dev/null \
  || die "la règle est posée mais sudo -n ne l'accepte pas pour $USER_NAME"

log "Relance de coreaudiod (le son du Mac se coupe une à deux secondes)"
/usr/bin/killall coreaudiod || true
sleep 3
if system_profiler SPAudioDataType 2>/dev/null | grep -q "AirPlay Personal Bridge"; then
  log "Sortie « AirPlay Personal Bridge » présente. Installation terminée."
else
  log "La sortie n'apparaît pas encore : vérifier avec  /usr/bin/log show --last 2m --predicate 'process CONTAINS \"coreaudiod\" OR process CONTAINS \"Core Audio\"' | grep -i APBOutput"
fi
