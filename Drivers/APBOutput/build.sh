#!/usr/bin/env bash
# Compile et signe la sortie virtuelle : Drivers/APBOutput/build/APBOutput.driver.
#
#   Drivers/APBOutput/build.sh
#
# Sans mot de passe : rien n'est installé ici. L'installation, qui demande les droits
# administrateur, passe par scripts/install-driver.sh, lancé avec sudo par Baptiste.
#
# Universel arm64 + x86_64, comme les autres pilotes tiers : coreaudiod charge les pilotes tiers
# dans un processus d'aide dont l'architecture n'est pas garantie.
#
# Signature : seulement par scripts/setup-signing.sh --codesign (voir CLAUDE.md, « Signature et
# installation ») ; un appel direct à codesign ouvrirait une fenêtre de trousseau.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$DIR/../.." && pwd -P)"
BUNDLE="$DIR/build/APBOutput.driver"
BUNDLE_ID="fr.baptiste.airplaypersonalbridge.output"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$DIR/Info.plist" "$BUNDLE/Contents/Info.plist"
plutil -lint "$BUNDLE/Contents/Info.plist" >/dev/null

xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
  -arch arm64 -arch x86_64 -mmacosx-version-min=26.0 \
  -bundle -o "$BUNDLE/Contents/MacOS/APBOutput" "$DIR/APBOutput.c" \
  -framework CoreAudio -framework CoreFoundation

"$REPO/scripts/setup-signing.sh" --codesign --force --identifier "$BUNDLE_ID" "$BUNDLE"
codesign --verify --strict "$BUNDLE"
echo "==> $BUNDLE"
