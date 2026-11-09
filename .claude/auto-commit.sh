#!/bin/bash
# Commit + push automatique en fin de tour (hook Stop).
#
# Choix de Baptiste, 2026-08-06 : tout ce qui est modifié part sur GitHub sans
# confirmation. Le dépôt est personnel et non distribué (README, section Licence),
# donc le risque d'un commit intermédiaire est limité à du bruit dans l'historique.
#
# Garde-fous délibérés, pour que ce bruit reste supportable :
#   - rien n'est fait si l'arbre est propre (pas de commit vide) ;
#   - un fichier .claude/skip-auto-commit suspend le mécanisme, sans toucher au hook ;
#   - le push échoue en silence plutôt que de bloquer la fin de tour (pas de réseau,
#     conflit distant) ; le commit local reste fait et repartira au tour suivant.
#
# `git add -A` prend tout ce que .gitignore ne couvre pas : c'est donc .gitignore qui garde ce
# qui ne doit jamais partir (credentials/, clés et trousseaux, tools/, .mock-logs/, build/,
# captures audio et réseau, worktrees d'agents). Tout nouveau secret ou artefact s'y déclare
# AVANT sa création.
#
# Ce script ne remplace PAS la procédure de clôture de jalon (CDC section 14) :
# celle-ci reste un commit délibéré, avec message rédigé, après mise à jour de
# PROGRESS.md / CLAUDE.md / README.md.

set -uo pipefail

cd "$CLAUDE_PROJECT_DIR" 2>/dev/null || exit 0

# Échappatoire : `touch .claude/skip-auto-commit` suspend l'automatisme.
[ -f .claude/skip-auto-commit ] && exit 0

# Hors dépôt git : ne rien tenter.
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Arbre propre : rien à faire, et surtout pas de commit vide.
[ -z "$(git status --porcelain)" ] && exit 0

# Résumé court de ce qui change, pour que le message ait un minimum de valeur
# à la relecture de l'historique.
changed=$(git status --porcelain | wc -l | tr -d ' ')
# Ligne par ligne : un nom de fichier peut contenir des espaces (git le met alors entre
# guillemets, et ne garde que la cible d'un renommage).
files=$(git status --porcelain | cut -c4- | sed -e 's/.* -> //' -e 's/^"//' -e 's/"$//' \
        | while IFS= read -r path; do basename "$path"; done \
        | head -3 | paste -sd ',' - | sed 's/,/, /g')
[ "$changed" -gt 3 ] && files="$files, +$((changed - 3))"

git add -A || exit 0
# Message en anglais, au format conventional commits, et sans aucune ligne d'attribution : règle de
# Baptiste pour tous ses dépôts depuis le 2026-11-08 (~/.claude/CLAUDE.md, skill super-commit).
git commit -q -m "chore(auto): checkpoint $files" \
    -m "End-of-turn automatic commit (Stop hook, .claude/auto-commit.sh).
Not a milestone closing commit: PROGRESS.md holds the real state." || exit 0

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

# Push non bloquant : une panne réseau ou un conflit distant ne doit pas faire
# échouer la fin de tour. Le commit local est fait, il repartira plus tard.
if git push -q origin "$branch" 2>/dev/null; then
    printf '{"systemMessage":"Auto-commit poussé sur %s : %s"}\n' "$branch" "$files"
else
    printf '{"systemMessage":"Auto-commit fait localement sur %s (push impossible — à repousser)"}\n' "$branch"
fi
