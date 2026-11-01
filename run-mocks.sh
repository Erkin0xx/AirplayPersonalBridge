#!/usr/bin/env bash
# Lance les deux mocks de récepteurs AirPlay et vérifie qu'ils sont réellement joignables.
#
#   ./run-mocks.sh          lance les deux mocks en arrière-plan, puis vérifie
#   ./run-mocks.sh check    vérifie seulement (Bonjour + port), ne lance rien
#   ./run-mocks.sh restart  arrête puis relance (la parade au mock AirPlay 2 périmé)
#   ./run-mocks.sh stop     arrête les mocks lancés par ce script
#
# Geneva-Mock       : shairport-sync        (AirPlay 1 / RAOP) — cible du jalon 2
# ApTV-HomePod-Mock : airplay2-receiver     (AirPlay 2)        — cible du jalon 3
#
# Ce script ne parle qu'aux mocks de cette machine. Il ne contacte jamais un vrai récepteur :
# `dns-sd -B` ne fait qu'écouter les annonces, et le test de port vise l'adresse locale.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Surchargeables pour le test de ce script (`RunMocksScriptTests`), qui ne doit toucher ni aux
# journaux ni aux pid des vrais mocks.
LOG_DIR="${MOCK_LOG_DIR:-${REPO_ROOT}/.mock-logs}"
STOP_TIMEOUT_SECONDS="${MOCK_STOP_TIMEOUT_SECONDS:-5}"
NETIFACE="${NETIFACE:-en0}"
GENEVA_PORT=5000
AP2_PORT=7000
START_TIMEOUT_SECONDS=20

mkdir -p "$LOG_DIR"
log() { printf '\n==> %s\n' "$1"; }

# tools/ est ignoré par git : un worktree n'en a pas, on se rabat sur le dépôt principal, que
# `--git-common-dir` désigne quel que soit le worktree.
locate_ap2_dir() {
  local common_dir
  if [ -d "${REPO_ROOT}/tools/airplay2-receiver" ]; then
    echo "${REPO_ROOT}/tools/airplay2-receiver"
    return 0
  fi
  common_dir="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -n "$common_dir" ] && [ -d "$(dirname "$common_dir")/tools/airplay2-receiver" ]; then
    echo "$(dirname "$common_dir")/tools/airplay2-receiver"
    return 0
  fi
  return 1
}

# --- Suivi des process ---
# Un mock est désigné par le contenu de son fichier pid ET par son nom de process : un pid seul
# peut avoir été réattribué, un nom seul attraperait un autre lancement. `pgrep -f shairport-sync`
# trouvait aussi un `tail` sur le journal du mock, ou un éditeur ouvert sur sa configuration.
pid_file() { echo "${LOG_DIR}/$1.pid"; }

# Le pid est-il vivant et est-ce bien ce mock ?
is_mock_process() {
  local name="$1" pid="$2" command_line
  command_line="$(ps -o command= -p "$pid" 2>/dev/null || true)"
  case "$name" in
    shairport-sync) case "$command_line" in shairport-sync*|*/shairport-sync*) return 0 ;; esac ;;
    # « python » exigé : un éditeur ouvert sur ap2-receiver.py n'est pas le mock.
    airplay2-receiver) case "$command_line" in *[Pp]ython*ap2-receiver.py*) return 0 ;; esac ;;
  esac
  return 1
}

# Pid mémorisé par CE dépôt, s'il désigne encore le mock.
recorded_pid() {
  local name="$1" file pid
  file="$(pid_file "$name")"
  [ -f "$file" ] || return 1
  pid="$(cat "$file")"
  if [ -n "$pid" ] && is_mock_process "$name" "$pid"; then
    echo "$pid"
    return 0
  fi
  rm -f "$file"
  return 1
}

# Tout process du mock, lancé par ce script ou non (autre terminal, autre worktree).
any_running_pid() {
  local name="$1" pid
  case "$name" in
    shairport-sync) pgrep -x shairport-sync | head -1 ;;
    # pgrep -f, faute de nom exact (le process s'appelle python), mais sur le motif complet.
    airplay2-receiver)
      for pid in $(pgrep -f 'ap2-receiver\.py' || true); do
        if is_mock_process "$name" "$pid"; then
          echo "$pid"
          return 0
        fi
      done
      return 1
      ;;
  esac
}

elapsed_of() { ps -o etime= -p "$1" 2>/dev/null | tr -d ' '; }

stop_one() {
  local name="$1" pid other waited=0
  if pid="$(recorded_pid "$name")"; then
    kill "$pid" 2>/dev/null || true
    # Attendre que le port se libère : `restart` échouerait sinon sur « port occupé ».
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$STOP_TIMEOUT_SECONDS" ]; do
      sleep 1
      waited=$((waited + 1))
    done
    # shairport-sync peut fermer son port sur SIGTERM sans jamais quitter, et tourner ensuite à vide
    # sur un cœur (constaté après une session). Le laisser ferait annoncer un arrêt qui n'a pas eu
    # lieu, et le `start` suivant conclurait à « déjà lancé » devant un port fermé.
    if kill -0 "$pid" 2>/dev/null; then
      echo "  ${name} ignore SIGTERM : SIGKILL (pid ${pid})"
      kill -KILL "$pid" 2>/dev/null || true
      sleep 1
    fi
    rm -f "$(pid_file "$name")"
    echo "  ${name} arrêté (pid ${pid})"
  elif other="$(any_running_pid "$name")" && [ -n "$other" ]; then
    # Volontairement laissé : il appartient à un autre terminal ou à un autre worktree.
    echo "  ${name} : pid ${other} non lancé par ce script, laissé en place (kill ${other} pour l'arrêter)"
  else
    echo "  ${name} non lancé"
  fi
}

stop_mocks() {
  log "Arrêt des mocks..."
  stop_one shairport-sync
  stop_one airplay2-receiver
}

# Le port accepte-t-il une connexion, et qui l'écoute ? Un mock annoncé peut refuser encore : il
# quitte après chaque TEARDOWN et met quelques secondes à revenir, d'où un « Connection reset »
# qui tuerait la sortie pour toute la session. L'adresse est celle de l'interface, car c'est
# celle que le sender obtient par Bonjour.
local_address() { ipconfig getifaddr "$NETIFACE" 2>/dev/null || echo 127.0.0.1; }
port_accepts() { nc -z -G 2 "$(local_address)" "$1" >/dev/null 2>&1; }
# `|| true` : lsof rend 1 quand personne n'écoute, ce qui n'est pas une erreur ici.
port_owner() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fc 2>/dev/null | sed -n 's/^c//p' | head -1 || true; }

wait_for_port() {
  local port="$1" waited=0
  while [ "$waited" -lt "$START_TIMEOUT_SECONDS" ]; do
    if port_accepts "$port"; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

check_port() {
  local name="$1" port="$2" expected="$3" owner
  owner="$(port_owner "$port")"
  if ! port_accepts "$port"; then
    echo "  ✗ \"${name}\" : le port ${port} refuse les connexions"
    return 1
  fi
  # Le récepteur AirPlay natif de macOS écoute sur 5000 et 7000 : un port ouvert ne prouve rien.
  case "$owner" in
    ${expected}*)
      echo "  ✓ \"${name}\" : port ${port} ouvert (${owner})"
      return 0
      ;;
  esac
  echo "  ✗ \"${name}\" : le port ${port} répond, mais il est tenu par « ${owner:-inconnu} », pas par le mock"
  return 1
}

# Vérifie qu'un nom de service est bien annoncé en Bonjour sur le type donné.
# dns-sd ne se termine jamais seul : on le lance en arrière-plan et on lit sa sortie.
check_bonjour() {
  local svc_type="$1" expected="$2" out pid
  out="${LOG_DIR}/browse-$(echo "$svc_type" | tr -d '._').txt"
  dns-sd -B "$svc_type" local > "$out" 2>&1 &
  pid=$!
  sleep 5
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if grep -q "$expected" "$out"; then
    echo "  ✓ \"${expected}\" annoncé en ${svc_type}"
    return 0
  fi
  echo "  ✗ \"${expected}\" ABSENT de ${svc_type}"
  return 1
}

# Refuse de lancer sur un port occupé par autre chose : le mock mourrait aussitôt.
port_is_free_for() {
  local name="$1" port="$2" owner
  owner="$(port_owner "$port")"
  if [ -n "$owner" ]; then
    echo "  ÉCHEC : le port ${port} est tenu par « ${owner} », ${name} ne démarrera pas."
    echo "  Récepteur AirPlay natif de macOS ? Le désactiver :"
    echo "  Réglages Système > Général > AirDrop et Handoff > Récepteur AirPlay : OFF"
    return 1
  fi
}

start_geneva() {
  local pid log_file="${LOG_DIR}/shairport-sync.log"
  if pid="$(any_running_pid shairport-sync)" && [ -n "$pid" ]; then
    log "shairport-sync déjà lancé (pid ${pid}, depuis $(elapsed_of "$pid"))."
    return 0
  fi
  log "Lancement de shairport-sync (Geneva-Mock)..."
  command -v shairport-sync >/dev/null || {
    echo "  ÉCHEC : shairport-sync absent. Lancer ./setup.sh"
    return 1
  }
  port_is_free_for shairport-sync "$GENEVA_PORT" || return 1
  # nohup : le mock doit survivre à la fermeture du terminal qui l'a lancé.
  nohup shairport-sync > "$log_file" 2>&1 &
  pid=$!
  echo "$pid" > "$(pid_file shairport-sync)"
  if wait_for_port "$GENEVA_PORT" && is_mock_process shairport-sync "$pid"; then
    echo "  démarré, pid ${pid} (log: .mock-logs/shairport-sync.log)"
    return 0
  fi
  echo "  ÉCHEC — voir .mock-logs/shairport-sync.log"
  tail -3 "$log_file"
  return 1
}

start_airplay2() {
  local pid ap2_dir log_file="${LOG_DIR}/airplay2-receiver.log"
  if pid="$(any_running_pid airplay2-receiver)" && [ -n "$pid" ]; then
    log "airplay2-receiver déjà lancé (pid ${pid}, depuis $(elapsed_of "$pid"))."
    return 0
  fi
  log "Lancement de airplay2-receiver (ApTV-HomePod-Mock, iface ${NETIFACE})..."
  ap2_dir="$(locate_ap2_dir)" || {
    echo "  ÉCHEC : tools/airplay2-receiver introuvable. Lancer ./setup.sh dans le dépôt principal."
    return 1
  }
  [ -x "${ap2_dir}/proto/bin/python" ] || {
    echo "  ÉCHEC : venv absent (${ap2_dir}/proto). Lancer ./setup.sh"
    return 1
  }
  port_is_free_for airplay2-receiver "$AP2_PORT" || return 1
  # Le python du venv directement plutôt que `source activate` : `exec` fait que `$!` désigne bien
  # le mock, et non le sous-shell, sans quoi `stop` n'arrêterait jamais le bon process.
  (
    cd "$ap2_dir"
    exec nohup "${ap2_dir}/proto/bin/python" ap2-receiver.py -m ApTV-HomePod-Mock --netiface="$NETIFACE"
  ) > "$log_file" 2>&1 &
  pid=$!
  echo "$pid" > "$(pid_file airplay2-receiver)"
  if wait_for_port "$AP2_PORT" && is_mock_process airplay2-receiver "$pid"; then
    echo "  démarré, pid ${pid} (log: .mock-logs/airplay2-receiver.log)"
    return 0
  fi
  echo "  ÉCHEC — voir .mock-logs/airplay2-receiver.log"
  tail -5 "$log_file"
  return 1
}

COMMAND="${1:-start}"
rc=0
case "$COMMAND" in
  stop)
    stop_mocks
    exit 0
    ;;
  check) ;;
  restart)
    stop_mocks
    start_geneva || rc=1
    start_airplay2 || rc=1
    ;;
  start)
    start_geneva || rc=1
    start_airplay2 || rc=1
    ;;
  *)
    echo "Usage: $0 [start|check|restart|stop]" >&2
    exit 2
    ;;
esac

# --- Vérification : annonce réseau ET port, l'un ne garantit pas l'autre ---
log "Vérification de l'annonce Bonjour (5 s par type de service) et des ports..."
check_bonjour "_raop._tcp" "Geneva-Mock" || rc=1
check_port "Geneva-Mock" "$GENEVA_PORT" "shairport" || rc=1
check_bonjour "_airplay._tcp" "ApTV-HomePod-Mock" || rc=1
check_port "ApTV-HomePod-Mock" "$AP2_PORT" "[Pp]ython" || rc=1

if [ "$rc" -eq 0 ]; then
  log "Les deux mocks sont détectables et acceptent les connexions."
else
  log "Au moins un mock n'est pas utilisable — voir les logs dans .mock-logs/"
fi

# Deux comportements qui ressemblent à une panne du code du projet, à rappeler à l'écran.
if ap2_pid="$(any_running_pid airplay2-receiver)" && [ -n "$ap2_pid" ]; then
  echo "  Âge du mock AirPlay 2 : $(elapsed_of "$ap2_pid")."
fi
echo "  Rappel : le mock AirPlay 2 se périme au bout de quelques minutes (dns-sd l'annonce encore,"
echo "  NWBrowser ne le voit plus). Devant un « récepteur introuvable » : ./run-mocks.sh restart"
echo "  Rappel : shairport-sync quitte après chaque session (TEARDOWN) : relancer entre deux essais."
exit "$rc"
