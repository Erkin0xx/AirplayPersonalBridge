#!/usr/bin/env bash
# Construit `audiocap` puis l'empaquette en .app minimal signé ad-hoc.
#
# Pourquoi un bundle alors que le CDC (section 11) dit que les jalons 1 à 4 se valident au
# terminal : un exécutable SwiftPM nu n'a ni Info.plist, ni identité de code stable. macOS
# ne peut donc ni afficher la demande d'autorisation d'enregistrement audio, ni mémoriser
# la réponse. Sans autorisation, le Process Tap ne renvoie pas d'erreur — il livre des
# buffers de silence numérique, ce qui est indiscernable d'un blocage DRM.
#
# Le bundle reste un outil de validation en ligne de commande : il se lance au terminal,
# écrit des .wav, et ne contient aucune interface. Le jalon 5 construira la vraie app.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-debug}"
# Hors .build/ : ce dossier est effacé par `swift package clean`, et TCC rattache
# l'autorisation au chemin autant qu'à l'identifiant. Un bundle qui change de place
# redemande l'autorisation à chaque fois.
APP="${REPO_ROOT}/build/audiocap.app"

log() { printf '\n==> %s\n' "$1"; }

log "Compilation (${CONFIG})..."
swift build --configuration "$CONFIG"

BIN="$(swift build --configuration "$CONFIG" --show-bin-path)/audiocap"
[ -x "$BIN" ] || { echo "Binaire introuvable : $BIN" >&2; exit 1; }

log "Assemblage du bundle ${APP}..."
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS"
cp "${REPO_ROOT}/Resources/audiocap-Info.plist" "${APP}/Contents/Info.plist"
cp "$BIN" "${APP}/Contents/MacOS/audiocap"

# Signature ad-hoc : suffisante pour que TCC attribue une identité stable au binaire et
# retienne l'autorisation d'une exécution à l'autre. Une vraie signature Developer ID ne
# devient nécessaire qu'à la distribution (jalon 5).
log "Signature ad-hoc..."
codesign --force --sign - --identifier fr.baptiste.airplaymultioutput.audiocap "$APP"
codesign --display --verbose=2 "$APP" 2>&1 | grep -E 'Identifier|Signature' || true

# Sans cet enregistrement, TCC ne connaît pas l'identifiant du bundle et ne peut lui
# attribuer aucune autorisation : `tccutil` répond "No such bundle identifier", et la
# capture renvoie du silence sans jamais afficher de demande.
log "Enregistrement auprès de LaunchServices..."
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$APP"

log "Bundle prêt."
echo "Lancer :  ${APP}/Contents/MacOS/audiocap <durée_s> <sortie.wav>"
