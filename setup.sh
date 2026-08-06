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
# Wireshark : cask, nécessite un sudo interactif pour son pkg "system path".
# Non bloquant : utile seulement au jalon 2 (comparaison de trafic), pas avant.
log "Installation de Wireshark (cask, best-effort — peut exiger un sudo interactif)..."
brew install --cask wireshark || log "Wireshark non installé automatiquement (sudo interactif requis). À installer manuellement avant le jalon 2."

# Paquets réellement nécessaires aux jalons 1 à 3. Un échec ici doit arrêter le script.
log "Installation des paquets Homebrew requis (shairport-sync, libsamplerate, python3, portaudio, git)..."
brew install shairport-sync libsamplerate python3 portaudio git

# OwnTone : utilisé uniquement au jalon 0 (validation, nécessite le matériel réel),
# jamais au runtime de l'application (CDC section 5). N'existe plus dans homebrew-core
# (ni owntone, ni forked-daapd) : rendu non bloquant plutôt que de bloquer les jalons 1+.
log "Installation d'OwnTone (best-effort, requis seulement au jalon 0)..."
brew install owntone 2>/dev/null || log "OwnTone indisponible via Homebrew. À installer depuis les sources (https://github.com/owntone/owntone-server) au moment du jalon 0, qui nécessite de toute façon le matériel réel."

# --- Config shairport-sync (mock Geneva) ---
# Chemin réel lu par le binaire Homebrew : etc/shairport-sync/shairport-sync.conf
# (sous-dossier), et non etc/shairport-sync.conf. Vérifié via `shairport-sync -v`, qui
# logue "looking for configuration file at full path ...". Écrire au mauvais endroit
# laisse le mock démarrer sous son nom par défaut, pas sous "Geneva-Mock".
SPS_CONF_DIR="$(brew --prefix)/etc/shairport-sync"
SPS_CONF="${SPS_CONF_DIR}/shairport-sync.conf"
mkdir -p "$SPS_CONF_DIR"
if [ -f "$SPS_CONF" ] && [ ! -f "${SPS_CONF}.bak" ]; then
  log "Sauvegarde de la config shairport-sync d'origine en ${SPS_CONF}.bak"
  cp "$SPS_CONF" "${SPS_CONF}.bak"
fi
# Backend audio : "ao" (driver macosx) et non "pulseaudio", qui est le défaut de la
# compilation Homebrew mais échoue immédiatement sans serveur PulseAudio lancé
# ("pa context is not good -- Connection refused").
# Prérequis macOS : le récepteur AirPlay natif (ControlCenter) occupe le port 5000 et
# fait échouer shairport-sync au démarrage ("could not establish a service on port 5000").
# Cette build 5.2.1 ignore l'option `port`/`-p` en mode AirPlay 1 (vérifié : le log
# annonce "rtsp listening port is 5000" même avec -p 5010), donc changer de port ne
# contourne pas le conflit. Il faut désactiver :
#   Réglages Système > Général > AirDrop et Handoff > Récepteur AirPlay : OFF
log "Écriture d'une config minimale shairport-sync (Geneva-Mock, backend ao/macosx)."
cat > "$SPS_CONF" <<'EOF'
general =
{
  name = "Geneva-Mock";
  output_backend = "ao";
  port = 5010;
};
EOF

if lsof -nP -iTCP:5000 -sTCP:LISTEN >/dev/null 2>&1; then
  log "ATTENTION : le port 5000 est déjà occupé (récepteur AirPlay natif de macOS ?)."
  log "shairport-sync ne pourra pas démarrer tant qu'il l'est. Désactiver :"
  log "  Réglages Système > Général > AirDrop et Handoff > Récepteur AirPlay : OFF"
fi

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
  # `python3 -m venv` plutôt que `pip3 install virtualenv` : le Python de Homebrew est
  # "externally managed" (PEP 668) et refuse toute installation globale via pip.
  # venv est dans la stdlib, aucune installation préalable nécessaire.
  log "Création de l'environnement virtuel Python pour airplay2-receiver (python3 -m venv)..."
  python3 -m venv proto
fi
# shellcheck disable=SC1091
source proto/bin/activate
pip install --quiet --upgrade pip
# `av==8.1.0` (pin du dépôt, daté de 2021) ne compile pas sur Python 3.12+ : son setup.py
# importe `distutils.msvccompiler`, supprimé de la stdlib depuis 3.12. Le pin est donc
# relâché pour cette seule dépendance ; le reste de requirements.txt est respecté tel quel.
# av ne sert qu'au décodage audio du récepteur (ap2/connections/audio.py), côté mock.
grep -v '^av==' requirements.txt > /tmp/ap2-requirements-noav.txt
pip install -r /tmp/ap2-requirements-noav.txt
rm -f /tmp/ap2-requirements-noav.txt
pip install av

PORTAUDIO_PREFIX="$(brew --prefix portaudio)"
log "Installation de pyaudio (chemins portaudio résolus dynamiquement : ${PORTAUDIO_PREFIX})..."
# `--global-option` a été supprimé de pip (>= 23.1) : on passe les chemins portaudio
# par les variables d'environnement standard du compilateur à la place.
CFLAGS="-I${PORTAUDIO_PREFIX}/include" \
LDFLAGS="-L${PORTAUDIO_PREFIX}/lib" \
  pip install pyaudio
deactivate
cd - >/dev/null

# --- pyatv (pairing initial uniquement) ---
# Installé dans un venv dédié, pas globalement : le Python de Homebrew refuse les
# installations globales (PEP 668). pyatv ne sert qu'au pairing en CLI (jalon 3),
# jamais au runtime de l'application (CDC section 5).
PYATV_VENV="${TOOLS_DIR}/pyatv-venv"
if [ ! -d "$PYATV_VENV" ]; then
  log "Création du venv dédié à pyatv..."
  python3 -m venv "$PYATV_VENV"
fi
log "Installation de pyatv (pairing AirPlay 2 en CLI)..."
"${PYATV_VENV}/bin/pip" install --quiet --upgrade pip
"${PYATV_VENV}/bin/pip" install --quiet pyatv

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
