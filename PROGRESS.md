# PROGRESS.md

Journal de progression par jalon. Voir docs/cahier_des_charges_diffusion_audio.md section 14.
Distinguer explicitement "validé contre mock" et "validé contre matériel réel".

**Statut matériel réel : aucun accès à ce jour.** Tout ce qui suit est validé contre les
émulateurs logiciels uniquement (`shairport-sync`, `airplay2-receiver`).

---

## Jalon -1 : setup initial — TERMINÉ (validé contre mock)

Date : 2026-08-05
Machine : macOS 26.5.1 (build 25F80), Apple Silicon, Swift 6.3.3, Homebrew /opt/homebrew
Réseau : en0, 192.168.1.21

### Résultat

`./setup.sh` s'exécute intégralement (exit code 0) et est idempotent (relancé 4 fois).
Les deux mocks démarrent et sont **détectables sur le réseau** :

| Mock | Outil | Service Bonjour | Résolution |
|---|---|---|---|
| Geneva-Mock | shairport-sync 5.2.1 | `_raop._tcp` ✓ | `65D15B6D3AC1@Geneva-Mock` → `MacBook-Pro-de-Erki.local:5000` |
| ApTV-HomePod-Mock | airplay2-receiver | `_airplay._tcp` ✓ | `ApTV-HomePod-Mock._airplay.local:7000` |

Vérification reproductible : `./run-mocks.sh` (script ajouté, voir ci-dessous).

### Problèmes rencontrés et résolutions

Le `setup.sh` fourni ne passait pas en l'état sur cette machine. Cinq blocages, tous
corrigés dans le script (il reste idempotent et relançable) :

1. **`owntone` n'existe plus dans homebrew-core** (ni `owntone`, ni `forked-daapd`).
   Sous `set -euo pipefail`, le `brew install` groupé tuait le script avant tout le reste.
   → Résolution : OwnTone sorti du groupe et rendu **non bloquant**. Il ne sert qu'au
   jalon 0, qui nécessite de toute façon le matériel réel et est déjà décalé. À installer
   depuis les sources le moment venu. Aucune conséquence sur les jalons 1 à 5 (CDC
   section 5 : OwnTone n'est jamais une dépendance runtime).

2. **Wireshark (cask) exige un `sudo` interactif** pour son pkg "add to system path",
   impossible en session non interactive.
   → Résolution : rendu non bloquant dans le script. Wireshark n'est requis qu'au jalon 2
   (comparaison de trafic). **Installé manuellement par Baptiste depuis, en fin de
   jalon -1** : Wireshark 4.6.7, avec `tshark` dans le PATH et capture possible sans `sudo`
   (membre du groupe `access_bpf`). Le prérequis du jalon 2 est donc satisfait.

3. **PEP 668 / "externally-managed-environment"** : le Python 3.14 de Homebrew refuse
   `pip3 install virtualenv` et `pip3 install pyatv` en global.
   → Résolution : `python3 -m venv` (stdlib) au lieu d'installer `virtualenv`, et pyatv
   installé dans un venv dédié `tools/pyatv-venv/` au lieu du Python système.

4. **`av==8.1.0` (pin de requirements.txt d'airplay2-receiver) ne compile pas** sur
   Python 3.12+ : son `setup.py` importe `distutils.msvccompiler`, supprimé de la stdlib.
   → Résolution : pin relâché **pour cette seule dépendance** (av 18.0.0 installé), le
   reste de `requirements.txt` est respecté tel quel. `av` ne sert qu'au décodage audio
   côté récepteur (`ap2/connections/audio.py`), c'est du code de mock, pas du code projet.
   Également corrigé : `pip install --global-option=...` pour pyaudio, option supprimée de
   pip ≥ 23.1, remplacée par `CFLAGS`/`LDFLAGS`.

5. **shairport-sync ne démarrait pas**, deux causes distinctes :
   - Le script écrivait la config dans `etc/shairport-sync.conf`, alors que le binaire lit
     `etc/shairport-sync/shairport-sync.conf` (sous-dossier). Le mock démarrait donc sans
     le nom "Geneva-Mock". → Chemin corrigé.
   - Backend audio par défaut `pulseaudio` (choix de compilation Homebrew), qui échoue sans
     serveur PulseAudio : *"pa context is not good -- Connection refused"*.
     → Backend forcé à `ao` (driver `macosx`).

### Décision prise, hors CDC

**Le récepteur AirPlay natif de macOS a été désactivé** (Réglages Système > Général >
AirDrop et Handoff > Récepteur AirPlay : OFF). Il occupait le port 5000, ce qui empêchait
shairport-sync de démarrer. Changer de port n'est pas une option : cette build 5.2.1 ignore
`port`/`-p` en mode AirPlay 1 (vérifié — le log annonce `rtsp listening port is 5000` même
lancé avec `-p 5010`). Décision validée avec Baptiste.
**À réactiver manuellement si le Mac doit redevenir une cible AirPlay.**

### Ajouts au dépôt, hors CDC

- **`.gitignore`** : exclut `tools/` (clone + venv), `.build/`, les dumps `*.wav`/`*.pcap`,
  et surtout `credentials/` — les credentials de pairing du jalon 3 ne doivent jamais être
  committés.
- **`run-mocks.sh`** : lance les deux mocks et vérifie leur annonce Bonjour
  (`start` / `check` / `stop`). Rend la vérification du jalon -1 reproductible en une
  commande, et servira à chaque session des jalons 2 et 3.
- **Specs déplacées à la racine vers `docs/`**, conformément à l'étape 8 du guide
  d'installation et aux chemins que le CDC référence lui-même (section 14).

### Ce qui reste ouvert

- ~~Wireshark non installé~~ — **résolu en fin de jalon -1** (4.6.7, `tshark` disponible,
  capture sans `sudo`). Plus de blocage pour le jalon 2.
- **OwnTone non installé** — à compiler depuis les sources au jalon 0.
- Le mock AirPlay 2 émet un warning zeroconf non fatal au démarrage
  (`Error with socket ... No route to host` sur l'IPv6 link-local) ; l'enregistrement mDNS
  aboutit malgré tout et le service est résolvable. À re-regarder si le jalon 3 montre des
  problèmes de découverte.
- Rappel CDC/guide section 3.3 : un handshake qui passe contre `airplay2-receiver`
  (expérimental de son propre aveu) n'est **pas** une garantie contre le vrai firmware Apple.

---
