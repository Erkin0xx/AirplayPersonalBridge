#!/usr/bin/env bash
# Setup automatique de l'environnement de dev pour le projet de diffusion audio multi-sortie.
# Ne couvre pas Xcode lui-même (à installer manuellement depuis le Mac App Store, une seule fois).
# Idempotent : peut se relancer sans casser une installation existante.

set -euo pipefail

log() { printf '\n==> %s\n' "$1"; }

# --- Homebrew ---
if ! command -v brew &>/dev/null; then
  log "Homebrew absent, installation..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
else
  log "Homebrew déjà présent."
fi

# --- Paquets Homebrew ---
log "Installation des paquets Homebrew (wireshark, owntone, shairport-sync, libsamplerate, python3, portaudio, git)..."
brew install --cask wireshark || true
brew install owntone shairport-sync libsamplerate python3 portaudio git

# --- Config shairport-sync (mock Geneva) ---
SPS_CONF="$(brew --prefix)/etc/shairport-sync.conf"
if [ -f "$SPS_CONF" ]; then
  log "Sauvegarde de la config shairport-sync existante en ${SPS_CONF}.bak"
  cp "$SPS_CONF" "${SPS_CONF}.bak"
fi
log "Écriture d'une config minimale shairport-sync (Geneva-Mock)."
cat > "$SPS_CONF" <<'EOF'
general =
{
  name = "Geneva-Mock";
};
EOF

# --- airplay2-receiver (mock groupe Apple TV/HomePod) ---
TOOLS_DIR="tools"
AP2_DIR="${TOOLS_DIR}/airplay2-receiver"
mkdir -p "$TOOLS_DIR"
if [ ! -d "$AP2_DIR" ]; then
  log "Clonage de airplay2-receiver..."
  git clone https://github.com/openairplay/airplay2-receiver.git "$AP2_DIR"
else
  log "airplay2-receiver déjà cloné, pas de re-clonage."
fi

cd "$AP2_DIR"
if [ ! -d "proto" ]; then
  log "Création de l'environnement virtuel Python pour airplay2-receiver..."
  pip3 install --quiet virtualenv
  virtualenv -p "$(command -v python3)" proto
fi
# shellcheck disable=SC1091
source proto/bin/activate
pip install -r requirements.txt

PORTAUDIO_PREFIX="$(brew --prefix portaudio)"
log "Installation de pyaudio (chemins portaudio résolus dynamiquement : ${PORTAUDIO_PREFIX})..."
pip install --global-option=build_ext \
  --global-option="-I${PORTAUDIO_PREFIX}/include" \
  --global-option="-L${PORTAUDIO_PREFIX}/lib" \
  pyaudio
deactivate
cd - >/dev/null

# --- pyatv (pairing initial uniquement) ---
log "Installation de pyatv (pairing AirPlay 2 en CLI)..."
pip3 install --quiet pyatv

# --- Structure du dépôt ---
log "Création des fichiers de suivi de projet (CLAUDE.md, PROGRESS.md, docs/) si absents..."
mkdir -p docs Sources/CCrypto
[ -f CLAUDE.md ] || cat > CLAUDE.md <<'EOF'
# CLAUDE.md

Instructions et faits durables découverts pendant le développement.
Voir docs/cahier_des_charges_diffusion_audio.md section 13.
EOF
[ -f PROGRESS.md ] || cat > PROGRESS.md <<'EOF'
# PROGRESS.md

Journal de progression par jalon. Voir docs/cahier_des_charges_diffusion_audio.md section 14.
Distinguer explicitement "validé contre mock" et "validé contre matériel réel".
EOF

log "Setup terminé."
log "Pour lancer le mock Geneva (AirPlay 1)  : shairport-sync"
log "Pour lancer le mock Apple TV/HomePod (AirPlay 2) : cd ${AP2_DIR} && source proto/bin/activate && python ap2-receiver.py -m ApTV-HomePod-Mock --netiface=en0"
log "Note : les bibliothèques C (csrp, curve25519-donna, ed25519, chachapoly) ne sont pas automatisées ici,"
log "leurs sources exactes doivent être vérifiées et récupérées manuellement au jalon 3 (voir CDC section 10)."
