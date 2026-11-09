#!/usr/bin/env bash
# Retire la sortie virtuelle « AirPlay Personal Bridge » et la règle sudoers posée par
# install-driver.sh, puis relance coreaudiod (coupure du son d'une à deux secondes).
#
#   sudo scripts/uninstall-driver.sh
#
# Si le pilote était la sortie par défaut, macOS en choisit une autre tout seul. L'app, sans la
# règle, journalise l'échec de la relance de coreaudiod en quittant, et quitte quand même.

set -euo pipefail

die() { printf 'ERREUR : %s\n' "$1" >&2; exit 1; }
log() { printf '==> %s\n' "$1"; }

[ "$(id -u)" = 0 ] || die "à lancer avec sudo : sudo $0"

DEST="/Library/Audio/Plug-Ins/HAL/APBOutput.driver"
RULE_FILE="/etc/sudoers.d/airplay-bridge"

if [ -e "$RULE_FILE" ]; then
  rm -f "$RULE_FILE"
  log "Règle sudoers retirée ($RULE_FILE)"
fi
if [ -e "$DEST" ]; then
  rm -rf "$DEST"
  log "Pilote retiré ($DEST)"
fi
log "Relance de coreaudiod (le son du Mac se coupe une à deux secondes)"
/usr/bin/killall coreaudiod || true
log "Désinstallation terminée."
