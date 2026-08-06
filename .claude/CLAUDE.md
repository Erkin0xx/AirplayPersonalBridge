# CLAUDE.md — instructions locales au dépôt

Complète, sans le remplacer, le `CLAUDE.md` à la racine du dépôt (invariants d'architecture
recopiés du CDC section 12, règles de code section 13, faits vérifiés par jalon).

## Wiki Knowledge Base
Path: /Users/baptiste/Documents/Vault

Ce projet est un projet PERSO. Avant de proposer une archi ou un choix
technique :
1. Lire Projets/AirplayPersonalBridge/notes.md et deployment.md
2. Lire Projets/AirplayPersonalBridge/decisions/ (tous les fichiers NNN-*.md)
3. Consulter Conventions/Stack Standards et Resources/ si un pattern
   correspond à la tâche

Déclencheurs d'écriture dans le vault :
- Décision d'archi actée -> créer un nouveau
  Projets/AirplayPersonalBridge/decisions/NNN-titre.md
- Correction faite sur un raisonnement/une erreur -> noter dans
  Projets/AirplayPersonalBridge/notes.md

### Articulation avec la mémoire du dépôt

Le vault ne remplace ni `PROGRESS.md` ni le `CLAUDE.md` racine, qui restent la mémoire
d'un jalon à l'autre imposée par le CDC section 14 :

- **`PROGRESS.md`** : journal par jalon (fait / problèmes / reste ouvert), et la distinction
  « validé contre mock » vs « validé contre matériel réel ».
- **`CLAUDE.md` racine** : invariants et faits techniques vérifiés sur cette machine.
- **Vault `decisions/`** : le *pourquoi* d'un choix d'architecture arbitré, au format ADR
  (gabarit dans `Conventions/ADR Template.md`). Numérotation continue — 001 et 002 existent
  déjà, la prochaine décision est donc 003.
- **Vault `notes.md`** : les corrections de raisonnement, y compris les miennes.
