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

## Jalon 1 : capture Core Audio — TERMINÉ (validé en local, sans sortie AirPlay)

Date : 2026-08-05

### Test DRM — le point demandé en priorité par le jalon (CDC section 6)

**Résultat : aucun blocage DRM constaté. Le Process Tap capte le contenu protégé.**

| Source | Résultat | Mesure |
|---|---|---|
| Apple Music (« Stolen Dance », vol. 100) | **CAPTÉ** | 6,02 s, 99,1 % d'échantillons non nuls, crête −29,7 dBFS |
| Netflix, vidéo en lecture (Dia/Chromium) | **CAPTÉ** | 12,01 s, 96,0 % non nuls, crête −4,3 dBFS |

Les deux `.wav` ont été relus à l'oreille via `afplay` : c'est bien l'audio attendu, pas du
bruit ni du silence. Le test Netflix a été fait dans Dia plutôt que Safari (pas de session
ouverte côté Safari) — sans incidence, ce qui compte est le contenu protégé, pas le
navigateur.

Cela confirme l'hypothèse de la section 4.4 du CDC : le DRM protège le fichier chiffré, pas
les échantillons PCM déjà décodés au moment où ils atteignent le graphe Core Audio.
**Conséquence : pas besoin de la piste de repli BlackHole.**

Nuance à garder : constaté sur macOS 26.5.1 en août 2026, sur ces deux services. Ce n'est
pas une garantie qu'Apple n'ajoutera pas une restriction de politique plus tard, l'API
restant récente.

### Les 3 modes de capture

Tous validés, `.wav` produit et relu via `afplay` :

| Mode | Commande | Résultat |
|---|---|---|
| Système global | `./audiocap 5 out.wav` | 5,00 s, 99,5 % non nuls, −4,1 dBFS |
| Application ciblée | `./audiocap --app Music 6 out.wav` | 6,04 s, 98,4 % non nuls, −31,7 dBFS |
| Entrée physique | `./audiocap --mode input 6 out.wav` | 6,00 s, mono 48 kHz, −46,8 dBFS (bruit ambiant) |

**Isolation du mode application prouvée** : Music mis en pause pendant qu'un bruit fort
jouait depuis un autre process → silence numérique strict (0 échantillon non nul sur 4 s).
Le tap ne capte que l'application ciblée, conformément au CDC 4.2.

Le mode entrée physique capte le micro interne ; la validation avec l'ampli tourne-disque
demandera d'être physiquement sur place (déjà prévu au guide, section 1).

### Ring buffer lock-free (invariant section 12)

`AudioRingBuffer`, SPSC lock-free : allocation unique à l'init, `write`/`read` sans verrou,
sans allocation et non bloquants, index atomiques en acquire/release. En saturation, le
producteur temps réel abandonne des trames et les comptabilise plutôt que de bloquer.

6 tests unitaires, tous verts, dont un test producteur/consommateur **concurrent** sur
20 000 échantillons vérifiant qu'aucune valeur n'est corrompue ni réordonnée — c'est lui qui
justifie l'ordonnancement acquire/release.

### Problèmes rencontrés et résolutions

Le gros du temps est passé sur un symptôme unique et trompeur : **le tap « fonctionnait »
(callbacks appelés au bon rythme, buffers de la bonne taille) mais ne livrait que des
zéros**. Trois causes distinctes empilées, chacune produisant exactement le même symptôme :

1. **Mauvais UID de sous-tap.** `kAudioSubTapUIDKey` attend `CATapDescription.uuid`, et non
   la valeur lue via `kAudioTapPropertyUID`. Trouvé en comparant au projet de référence
   `insidegui/AudioCap` (CDC section 10) après épuisement des hypothèses.
2. **Agrégat sans horloge.** Il manquait le périphérique de sortie courant en
   `MainSubDevice` et dans `SubDeviceList`.
3. **Autorisation TCC.** `kTCCServiceAudioCapture` est **distincte** du micro, et
   `AVCaptureDevice.authorizationStatus(for: .audio)` — que j'utilisais — renvoie l'état du
   micro. Elle répondait `authorized` alors que le tap n'était pas autorisé. Résolu en
   passant par les SPI privées de TCC, comme AudioCap.

Deux pièges d'outillage se sont ajoutés, chacun ayant produit de faux résultats négatifs :
- **Exécuter le binaire interne du bundle fait perdre l'autorisation.** Il faut passer par
  `open` (wrapper `./audiocap` ajouté pour ça).
- **Chaque re-signature révoque l'autorisation.** Plusieurs tests « échoués » testaient en
  réalité un binaire redevenu non autorisé après rebuild.

Erreur de méthode à noter : mon script d'analyse supposait du stéréo en dur et annonçait
donc une durée deux fois trop courte sur les captures mono. J'ai cru à une troncature de la
capture avant de vérifier l'en-tête réel du `.wav` — la capture était correcte depuis le
début. `analyse-wav.py` lit maintenant le bloc `fmt `.

### Décisions prises, hors CDC

- **Dépendance `swift-atomics`** (bibliothèque officielle Apple) pour le ring buffer.
  L'alternative, appeler les atomiques C à la main, contredirait la règle « aucun pointeur C
  manipulé à nu en dehors d'un wrapper » (section 12).
- **Plateforme du package fixée à macOS 15** alors que le Process Tap exige 14.2 : SwiftPM
  ne sait exprimer que des versions majeures ici, `.v14` valant 14.0. `ProcessTapCapture`
  porte en plus un `@available(macOS 14.2)` explicite.
- **Bundle `.app` signé pour un outil CLI**, hors `.build/` (effacé par `swift package
  clean`). Sans identité de code stable, macOS ne peut accorder aucune autorisation.
- **Récepteur AirPlay natif de macOS toujours désactivé** (décision du jalon -1).
- **Push git automatique délégué à Claude** par Baptiste, ainsi que l'autonomie sur
  l'exécution des commandes et des autorisations (noté dans `CLAUDE.md`).

### Ce qui reste ouvert

- **Le mode entrée physique n'a été testé qu'avec le micro interne.** Le cas réel visé
  (sortie d'ampli tourne-disque via interface USB) demande d'être sur place.
- **Le CLI n'affiche sa sortie que via le wrapper `./audiocap`** : `open` ne relaie ni
  stdout ni stderr, la sortie transite par `/tmp/audiocap-output.txt`. Fonctionnel, mais peu
  élégant ; à revoir au jalon 5, où l'app aura une vraie interface.
- **La taille du ring buffer (48 000 trames, 1 s) est un choix provisoire**, à réévaluer au
  jalon 2 en fonction de la gigue réelle du sender réseau.
- Le CDC (section 11) suggérait de commencer par le mode entrée physique, le mieux
  documenté. J'ai suivi l'ordre imposé par le prompt du jalon 1, qui exige le test DRM en
  premier — donc le Process Tap d'abord. Sans conséquence, les trois modes sont faits.

---
