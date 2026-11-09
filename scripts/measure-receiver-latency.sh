#!/usr/bin/env bash
# Mesure au micro ce que change la compensation des 11 025 trames que les récepteurs ajoutent à la
# latence annoncée (docs/prompt_retard_2s.md, étape 1) : chaque enceinte seule, sans puis avec, puis
# les trois ensemble, sans puis avec.
#
#   scripts/measure-receiver-latency.sh [dossier]
#
# FAIT JOUER LES ENCEINTES : des salves de 5 ms à 3 kHz toutes les 2 s, pendant une dizaine de
# minutes. Pièce calme, micro du Mac à sa place habituelle (à table), app arrêtée, mocks éteints.
# Ne touche ni à la sortie du Mac ni au tap : la source est synthétique.
#
# Réglages par l'environnement :
#   DUREE=70        durée d'une mesure à une enceinte, en secondes (au moins 60)
#   DUREE_TROIS=90  durée d'une mesure à trois
#   VOLUME=-10      volume AirPlay des enceintes, de -30 à 0 (trop bas, le micro ne capte rien)
#   TRAMES=11025    compensation essayée, en trames à 44,1 kHz (RAOP et AirPlay 2)
#   ETAPES="..."    sous-ensemble des mesures, parmi : geneva salon salon2 trois
#
# Ce qu'il faut lire à la fin : le son direct de chaque enceinte doit passer d'environ +300 ms à
# environ +50 ms, et les écarts entre enceintes rester ceux de la mesure « sans », à ±5 ms. Une
# enceinte qui ne bouge pas n'ajoute pas ces trames : sa famille garde alors 0.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OUT="${1:-captures/retard-2s/$(date +%Y%m%d-%H%M%S)}"
DUREE="${DUREE:-70}"
DUREE_TROIS="${DUREE_TROIS:-90}"
TRAMES="${TRAMES:-11025}"
VOLUME="${VOLUME:--10}"
ETAPES="${ETAPES:-geneva salon salon2 trois}"
GENEVA="${GENEVA:-Erki’s geneva}"
GAUCHE="${GAUCHE:-Salon}"
DROITE="${DROITE:-Salon (2)}"

[ -d build/audiocap.app ] || { echo "Bundle absent : lancer ./make-cli-bundle.sh" >&2; exit 1; }
if ! ./audiocap --help 2>&1 | grep -q -- "--receiver-latency2"; then
  echo "Le bundle ne connaît pas --receiver-latency : relancer ./make-cli-bundle.sh" >&2
  exit 1
fi
mkdir -p "$OUT"

# Une mesure : diffusion des salves, enregistrement du micro, analyse.
mesure() {
  local nom="$1" duree="$2"
  shift 2
  printf '\n=== %s (%s s) ===\n' "$nom" "$duree"
  # Un échec de diffusion ne doit pas faire perdre les mesures suivantes.
  # Chaque option de volume exige sa sortie : --volume2 sans --airplay2 est refusé.
  local volumes=() argument
  for argument in "$@"; do
    case "$argument" in
      --airplay) volumes+=(--volume "$VOLUME") ;;
      --airplay2) [[ " ${volumes[*]-} " == *" --volume2 "* ]] || volumes+=(--volume2 "$VOLUME") ;;
    esac
  done
  ./audiocap --clicks "$@" "${volumes[@]}" --record-input "${OUT}/${nom}.wav" "$duree" \
    > "${OUT}/${nom}.log" 2>&1 || echo "audiocap a rendu $? : voir ${OUT}/${nom}.log"
  tail -n 4 "${OUT}/${nom}.log"
  scripts/measure-clicks.py "${OUT}/${nom}.wav" > "${OUT}/${nom}.txt" 2>&1 || true
  scripts/measure-clicks.py "${OUT}/${nom}.wav" --json > "${OUT}/${nom}.json-resultat" 2>/dev/null || true
  cat "${OUT}/${nom}.txt"
  # Laisse le récepteur refermer sa session avant la suivante.
  sleep 6
}

for etape in $ETAPES; do
  case "$etape" in
    geneva)
      mesure geneva-sans "$DUREE" --airplay "$GENEVA" --receiver-latency 0
      mesure geneva-avec "$DUREE" --airplay "$GENEVA" --receiver-latency "$TRAMES"
      ;;
    salon)
      mesure salon-sans "$DUREE" --airplay2 "$GAUCHE" --receiver-latency2 0
      mesure salon-avec "$DUREE" --airplay2 "$GAUCHE" --receiver-latency2 "$TRAMES"
      ;;
    salon2)
      mesure salon2-sans "$DUREE" --airplay2 "$DROITE" --receiver-latency2 0
      mesure salon2-avec "$DUREE" --airplay2 "$DROITE" --receiver-latency2 "$TRAMES"
      ;;
    trois)
      mesure trois-sans "$DUREE_TROIS" --airplay "$GENEVA" --airplay2 "$GAUCHE" --airplay2 "$DROITE" \
        --receiver-latency 0 --receiver-latency2 0
      mesure trois-avec "$DUREE_TROIS" --airplay "$GENEVA" --airplay2 "$GAUCHE" --airplay2 "$DROITE" \
        --receiver-latency "$TRAMES" --receiver-latency2 "$TRAMES"
      ;;
    *)
      echo "Étape inconnue : $etape" >&2
      exit 2
      ;;
  esac
done

printf '\n=== Résumé : groupes trouvés, du premier (son direct) au dernier ===\n'
python3 - "$OUT" <<'PY'
import glob, json, os, sys

for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.json-resultat"))):
    name = os.path.basename(path)[: -len(".json-resultat")]
    try:
        with open(path) as handle:
            result = json.load(handle)
    except (OSError, ValueError):
        print("%-14s analyse absente" % name)
        continue
    groups = result.get("groupes") or []
    if not groups:
        print("%-14s aucune salve" % name)
        continue
    cells = ", ".join(
        "%+.1f ms (σ %.1f, %d/%d)"
        % (g["ecart_moyen_ms"], g["ecart_type_ms"], g["nombre"], g.get("attendues", 0))
        for g in groups
    )
    print("%-14s %s" % (name, cells))
PY
printf '\nFichiers dans %s\n' "$OUT"
