# AirPlay Personal Bridge

Application macOS native de diffusion audio multi-sortie, à usage strictement personnel.

Capture le son du Mac (système global, application précise, ou entrée physique) et le
diffuse **simultanément** vers une enceinte **AirPlay 1** (Geneva) et un groupe
**AirPlay 2** (Apple TV + 2 HomePod), avec volume indépendant par sortie et compensation
du décalage temporel entre elles.

## Pourquoi ce projet

macOS ne sait pas faire. Le périphérique de sortie multiple (Audio MIDI Setup) n'agrège pas
un appareil AirPlay 1 et un groupe AirPlay 2 simultanément. Airfoil y arrive en gérant
lui-même les deux protocoles en parallèle au lieu de s'appuyer sur le système : c'est
l'approche reprise ici, avec deux senders AirPlay implémentés en interne.

## État d'avancement

| Jalon | Contenu | État |
|---|---|---|
| -1 | Setup, émulateurs de récepteurs | ✅ validé contre mock |
| 0 | Validation OwnTone | ⏸️ décalé (nécessite le matériel réel) |
| 1 | Capture Core Audio (3 modes + test DRM) | ✅ validé en local |
| 2 | Sender RAOP (Geneva) | ✅ validé contre mock |
| 3 | Sender AirPlay 2 (Apple TV/HomePod) | ✅ validé contre mock |
| 4 | Synchronisation et dérive | ✅ validé contre mock |
| 5 | Interface SwiftUI | ⬜ |

**Les deux sorties diffusent en parallèle depuis le jalon 3**, et **synchronisées depuis le
jalon 4**, ce qui est l'objectif fonctionnel du projet :

```bash
./audiocap --airplay Geneva --airplay2 ApTV 30
```

Mesuré sur **1 h 02 de diffusion continue** contre les émulateurs : 454 621 paquets RAOP et
466 088 paquets AirPlay 2, **0 erreur de part et d'autre**, écart de synchronisation résiduel
sous **0,1 ms** (le critère du cahier des charges est de 20 à 30 ms). Une panne sur une sortie
n'interrompt pas l'autre : le mock RAOP est mort 90 fois pendant cette heure, la sortie
AirPlay 2 ne s'en est pas aperçue et les 90 reconnexions ont toutes abouti.

> **Important** : « validé » signifie *validé contre les émulateurs logiciels*. Le
> développement a démarré sans accès au matériel AirPlay réel. La validation contre la vraie
> Geneva et le vrai groupe Apple TV/HomePod reste une étape distincte.
> Voir [`PROGRESS.md`](PROGRESS.md) pour le détail par jalon.

## Architecture

Process unique, natif Swift. **Aucune dépendance runtime à un sous-processus externe** :
OwnTone et pyatv servent au développement et au pairing initial, jamais à l'exécution.

```
                  ┌────────────────────┐
   Process Tap ──▶│                    │──▶ ring buffer ──▶ Sender RAOP    ──▶ Geneva
   ou entrée      │  Capture (1 seule  │      lock-free
   physique       │  active à la fois) │──▶ ring buffer ──▶ Sender AirPlay 2 ──▶ ApTV+HomePod
                  └────────────────────┘      lock-free
```

Deux règles structurantes : la capture ne connaît **jamais** les destinations, et chaque
sender ignore l'existence de l'autre. Le flux PCM est dupliqué en lecture seule ; aucun
sender ne modifie le buffer partagé.

L'ensemble des invariants est listé dans [`CLAUDE.md`](CLAUDE.md) et en section 12 du
cahier des charges — ils ne sont pas négociables, y compris pour un développement assisté
par agent.

### Organisation du dépôt

```
Sources/AudioCore/          bibliothèque cœur (capture, senders, DSP) — sans interface
  ├── RAOP/                 sender AirPlay 1 + socle partagé (RTSP, UDP, RTP, resampling)
  ├── AirPlay2/             sender AirPlay 2 (pairing, canal chiffré, RTSP, événements)
  │   └── Crypto/           wrappers Swift des primitives C
Sources/CCrypto/            bibliothèques C vendues (SRP, X25519, Ed25519, ChaCha20-Poly1305)
Sources/audiocap/           exécutable CLI de validation (dump .wav, diffusion, logs)
Sources/AudioCore/Sync/     horloge commune, mesure de timing, correction de dérive
Tests/                      tests unitaires (105)
docs/                       cahier des charges + guide d'installation et de tests
tools/                      émulateurs et venvs Python (gitignoré)
```

Les primitives cryptographiques d'AirPlay 2 ne sont **jamais réécrites en Swift** : quatre
bibliothèques C éprouvées sont vendues telles quelles et pilotées par des wrappers dédiés
qui gèrent leur mémoire. Une erreur de portage (endianness, off-by-one) casserait la
compatibilité sans symptôme visible en test. Provenance, commits et écarts :
[`Sources/CCrypto/README.md`](Sources/CCrypto/README.md).

## Démarrage rapide

Prérequis : macOS 14.2+ (Process Tap), Xcode Command Line Tools. Xcode complet n'est
nécessaire qu'au jalon 5.

```bash
git clone https://github.com/Erkin0xx/AirplayPersonalBridge.git
cd AirplayPersonalBridge
./setup.sh            # Homebrew, mocks, pyatv, fichiers de suivi — idempotent
```

### Lancer les émulateurs de récepteurs

Le développement ne nécessite pas le matériel AirPlay réel : deux récepteurs logiciels
tiennent lieu de cibles de test.

```bash
./run-mocks.sh          # lance les deux mocks + vérifie leur annonce Bonjour
./run-mocks.sh check    # vérifie seulement
./run-mocks.sh stop     # arrête
```

| Mock | Émule | Outil | Service |
|---|---|---|---|
| `Geneva-Mock` | l'enceinte Geneva (AirPlay 1) | shairport-sync | `_raop._tcp` |
| `ApTV-HomePod-Mock` | le groupe Apple TV + HomePod (AirPlay 2) | airplay2-receiver | `_airplay._tcp` |

> Un seul mock suffit pour le groupe Apple TV/HomePod : le sender l'adresse comme **une
> seule destination**, jamais les HomePod individuellement.

> ⚠️ **Le récepteur AirPlay natif de macOS doit rester désactivé** (Réglages Système >
> Général > AirDrop et Handoff). Il occupe le port 5000 et empêche shairport-sync de
> démarrer ; l'option `-p` est ignorée par cette build.

### Capturer du son

```bash
./make-cli-bundle.sh                          # compile + signe + enregistre le bundle

./audiocap --list                             # process audio (● = en train de jouer)
./audiocap 10 systeme.wav                     # son système global
./audiocap --app Music 10 music.wav           # une application précise
./audiocap --mode input 10 entree.wav         # entrée physique (micro/ligne)

./analyse-wav.py systeme.wav                  # son capté ? silence ? fichier vide ?
afplay systeme.wav
```

**Toujours passer par `./audiocap`**, jamais par le binaire interne du bundle : macOS
attribue l'autorisation à l'identité de l'**app**, et un binaire lancé directement depuis le
shell n'en hérite pas — le tap renvoie alors du silence sans la moindre erreur. Le wrapper
lance le bundle via `open`, ce qui règle le problème.

> ⚠️ **Autorisation requise, et ce n'est pas celle du micro.** Le Process Tap dépend de
> « Enregistrement des sons du système » (`kTCCServiceAudioCapture`), distincte de
> « Microphone ». Sans elle, le tap **ne renvoie aucune erreur** : il livre des buffers de
> silence numérique, ce qui ressemble trompeusement à un blocage DRM.
>
> Réglages Système > Confidentialité et sécurité > « Enregistrement de l'écran et des sons
> du système » > section « Enregistrement des sons du système uniquement » > **+** >
> ajouter `build/audiocap.app`.
>
> Ré-exécuter `make-cli-bundle.sh` change la signature du binaire et **invalide
> l'autorisation** : il faut la retirer puis la ré-ajouter. Un silence inexpliqué juste
> après un rebuild, c'est presque toujours ça.

### Diffuser vers les récepteurs

```bash
./audiocap --browse                            # récepteurs AirPlay 1 (_raop._tcp)
./audiocap --browse2                           # récepteurs AirPlay 2 (_airplay._tcp)

./audiocap --airplay Geneva 30                 # vers la Geneva seule
./audiocap --airplay2 ApTV 30                  # vers le groupe Apple TV/HomePod seul
./audiocap --airplay Geneva --airplay2 ApTV 30 # les deux en parallèle

./audiocap --airplay Geneva --volume -15 30    # volume par sortie (--volume2 pour l'autre)
./audiocap --airplay Geneva --airplay2 ApTV --delay2 25 30   # décalage manuel, en ms
```

`--browse2` affiche les **bits de fonctionnalité** annoncés par le récepteur, dont son mode
de pairing. C'est la première commande à lancer devant un récepteur inconnu : elle détermine
en une fois si le sender saura lui parler.

> Les mocks perdent leur annonce Bonjour au bout de quelques minutes. Devant un « récepteur
> introuvable », relancer `./run-mocks.sh` avant de suspecter le code.

### Le DRM bloque-t-il la capture ?

**Non, d'après les mesures du jalon 1.** Apple Music et une vidéo Netflix ont été captés
sans blocage (99,1 % et 96,0 % d'échantillons non nuls, fichiers relus à l'oreille). Le DRM
protège le fichier chiffré, pas les échantillons PCM déjà décodés quand ils atteignent le
graphe Core Audio. Détail des mesures dans [`PROGRESS.md`](PROGRESS.md).

## Développement

```bash
swift build      # compile la bibliothèque et le CLI
swift test       # tests unitaires
```

Le travail se fait jalon par jalon. Chaque jalon se clôt par une mise à jour de
`PROGRESS.md`, un commit qui le référence, et un point d'arrêt — jamais d'enchaînement
automatique sur le suivant.

Toute session de travail (humaine ou agent) commence par lire [`PROGRESS.md`](PROGRESS.md)
et [`CLAUDE.md`](CLAUDE.md) : ces deux fichiers et l'historique git constituent la seule
mémoire du projet d'un jalon à l'autre.

## Documentation

- [Cahier des charges](docs/cahier_des_charges_diffusion_audio.md) — périmètre,
  architecture, invariants, jalons.
- [Guide d'installation et de tests](docs/guide_installation_et_tests.md) — mise en place
  des émulateurs, checklists de validation par jalon.
- [`CLAUDE.md`](CLAUDE.md) — invariants recopiés littéralement et faits vérifiés sur la
  machine de dev (formats, pièges d'API, chemins de config).
- [`PROGRESS.md`](PROGRESS.md) — journal par jalon.

### Synchroniser les deux sorties

Depuis le jalon 4, les deux sorties partagent une **horloge de restitution commune** : elle
traduit un numéro de trame de capture en instant de restitution attendu, et chaque sender en
tire l'ancrage NTP qu'il annonce au récepteur. C'est le récepteur qui cale sa restitution
dessus — le mécanisme natif d'AirPlay, pas une mesure de trajet réseau. Aucun des deux
senders ne sait que l'autre existe.

```bash
./audiocap --airplay Geneva --airplay2 ApTV --delay2 25 30   # fine-tune : +25 ms sur l'AP2
```

Le décalage manuel n'insère aucun échantillon : il décale l'instant annoncé, donc s'applique
sans rupture de flux. Il reste un fine-tune et un filet de sécurité, en complément de
l'alignement automatique — pas à sa place.

La **dérive** entre l'horloge du périphérique audio (qui cadence la capture) et celle de
l'hôte (qui cadence l'émission) est corrigée par ajout ou suppression d'**une** trame, avec
un fondu de 32 trames — la technique de Snapcast. Le compte rendu de fin de session affiche
l'écart résiduel, la latence annoncée par chaque récepteur et le nombre de corrections.

## Limites connues

- **AirPlay 2 est un protocole propriétaire non documenté.** La logique portée depuis
  OwnTone/pyatv peut cesser de fonctionner après une mise à jour tvOS ou HomePod, sans
  préavis ni recours.
- **Les émulateurs ne prouvent rien sur le matériel réel.** `airplay2-receiver` est
  expérimental de son propre aveu : un handshake qui passe contre lui est un signal de
  départ, pas une garantie contre le vrai firmware Apple.
- **Le debug est limité au-delà du handshake** : le trafic AirPlay 2 est chiffré.
- **Le mock shairport-sync meurt ~25 s après le début de chaque session** (`Bus error`,
  précédé de `client announced rsaaeskey of 256 bytes, wanted 16`). Comportement apparu au
  jalon 4 alors que le code RAOP n'a pas bougé depuis le jalon 2 ; à élucider en premier au
  jalon 5. La reconnexion automatique le rattrape, mais toute validation RAOP de longue
  durée en est affectée.
- **La mesure de décalage d'horloge n'a jamais produit de valeur** : shairport-sync envoie ses
  requêtes de timing à zéro. Le code est en place et testé, il attend un récepteur qui
  remplisse le champ.
- Pas de spatialisation 3D, pas de portage vers un autre OS, pas de fonction récepteur :
  l'application est un sender exclusivement (section 3 du CDC).

## Licence

Projet personnel, non distribué.
