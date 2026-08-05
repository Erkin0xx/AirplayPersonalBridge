#!/usr/bin/env bash
# Lance les deux mocks de récepteurs AirPlay et vérifie qu'ils sont annoncés sur le réseau.
#
#   ./run-mocks.sh          lance les deux mocks en arrière-plan, puis vérifie la découverte
#   ./run-mocks.sh check    vérifie seulement la découverte Bonjour, ne lance rien
#   ./run-mocks.sh stop     arrête les deux mocks
#
# Geneva-Mock       : shairport-sync        (AirPlay 1 / RAOP) — cible du jalon 2
# ApTV-HomePod-Mock : airplay2-receiver     (AirPlay 2)        — cible du jalon 3

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AP2_DIR="${REPO_ROOT}/tools/airplay2-receiver"
LOG_DIR="${REPO_ROOT}/.mock-logs"
NETIFACE="${NETIFACE:-en0}"

mkdir -p "$LOG_DIR"
log() { printf '\n==> %s\n' "$1"; }

stop_mocks() {
  log "Arrêt des mocks..."
  pkill -f 'shairport-sync' 2>/dev/null && echo "  shairport-sync arrêté" || echo "  shairport-sync non lancé"
  pkill -f 'ap2-receiver.py' 2>/dev/null && echo "  airplay2-receiver arrêté" || echo "  airplay2-receiver non lancé"
}

# Vérifie qu'un nom de service est bien annoncé en Bonjour sur le type donné.
# dns-sd ne se termine jamais seul : on le lance en arrière-plan et on lit sa sortie.
check_bonjour() {
  local svc_type="$1" expected="$2" out
  out="${LOG_DIR}/browse-$(echo "$svc_type" | tr -d '._').txt"
  dns-sd -B "$svc_type" local > "$out" 2>&1 &
  local pid=$!
  sleep 5
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  if grep -q "$expected" "$out"; then
    echo "  ✓ \"${expected}\" annoncé en ${svc_type}"
    return 0
  fi
  echo "  ✗ \"${expected}\" ABSENT de ${svc_type}"
  return 1
}

case "${1:-start}" in
  stop)
    stop_mocks
    exit 0
    ;;
  check) ;;
  start)
    # --- Mock Geneva (AirPlay 1) ---
    if lsof -nP -iTCP:5000 -sTCP:LISTEN >/dev/null 2>&1 && ! pgrep -f 'shairport-sync' >/dev/null; then
      log "Port 5000 occupé par un autre process (récepteur AirPlay natif de macOS ?)."
      echo "  shairport-sync ne démarrera pas. Désactiver :"
      echo "  Réglages Système > Général > AirDrop et Handoff > Récepteur AirPlay : OFF"
    fi
    if pgrep -f 'shairport-sync' >/dev/null; then
      log "shairport-sync déjà lancé."
    else
      log "Lancement de shairport-sync (Geneva-Mock)..."
      shairport-sync > "${LOG_DIR}/shairport-sync.log" 2>&1 &
      sleep 3
      pgrep -f 'shairport-sync' >/dev/null \
        && echo "  démarré (log: .mock-logs/shairport-sync.log)" \
        || { echo "  ÉCHEC — voir .mock-logs/shairport-sync.log"; tail -3 "${LOG_DIR}/shairport-sync.log"; }
    fi

    # --- Mock groupe Apple TV/HomePod (AirPlay 2) ---
    if pgrep -f 'ap2-receiver.py' >/dev/null; then
      log "airplay2-receiver déjà lancé."
    else
      log "Lancement de airplay2-receiver (ApTV-HomePod-Mock, iface ${NETIFACE})..."
      ( cd "$AP2_DIR" \
        && source proto/bin/activate \
        && python ap2-receiver.py -m ApTV-HomePod-Mock --netiface="$NETIFACE" \
      ) > "${LOG_DIR}/airplay2-receiver.log" 2>&1 &
      sleep 8
      pgrep -f 'ap2-receiver.py' >/dev/null \
        && echo "  démarré (log: .mock-logs/airplay2-receiver.log)" \
        || { echo "  ÉCHEC — voir .mock-logs/airplay2-receiver.log"; tail -5 "${LOG_DIR}/airplay2-receiver.log"; }
    fi
    ;;
  *)
    echo "Usage: $0 [start|check|stop]" >&2
    exit 2
    ;;
esac

# --- Vérification de la découverte réseau ---
log "Vérification de l'annonce Bonjour (5 s par type de service)..."
rc=0
check_bonjour "_raop._tcp"    "Geneva-Mock"       || rc=1
check_bonjour "_airplay._tcp" "ApTV-HomePod-Mock" || rc=1

if [ "$rc" -eq 0 ]; then
  log "Les deux mocks sont détectables sur le réseau."
else
  log "Au moins un mock n'est pas détectable — voir les logs dans .mock-logs/"
fi
exit "$rc"
