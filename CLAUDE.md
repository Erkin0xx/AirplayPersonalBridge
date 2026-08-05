# CLAUDE.md

Instructions et faits durables découverts pendant le développement.
Voir docs/cahier_des_charges_diffusion_audio.md section 13.

**Avant toute chose, à chaque nouvelle session : lire `PROGRESS.md` et ce fichier.**
Claude Code n'a aucune mémoire automatique du projet d'un jalon à l'autre en dehors de ces
deux fichiers et de l'historique git (CDC section 14).

## Mode de collaboration (décidé par Baptiste, 2026-08-05)

Ces règles valent pour tout le projet, à chaque session et à chaque jalon.

- **Autonomie totale sur l'exécution.** Ne pas demander d'accord pour lancer des commandes,
  installer des paquets, accorder/réinitialiser des autorisations, choisir entre deux
  implémentations équivalentes, ou faire des essais. Agir, puis rendre compte.
- **Ne jamais poser de question fermée de type oui/non, ni demander d'autoriser une
  commande.** Baptiste fait confiance sur ces points : une question dont la réponse est
  « oui, vas-y » ne doit pas être posée. En cas d'hésitation entre deux options techniques,
  trancher soi-même, appliquer, et signaler le choix dans le compte rendu de fin d'étape.
- **Push git automatique**, sans demander à chaque fois. Dépôt :
  `https://github.com/Erkin0xx/AirplayPersonalBridge.git` (branche `main`).
- **Solliciter Baptiste uniquement dans deux cas :**
  1. une étape ou un jalon est terminé, et il faut faire le point ;
  2. il y a une **action concrète que lui seul peut faire** : lancer une vidéo dans un
     service où il est connecté, brancher un ampli ou une interface audio, basculer un
     réglage dans une interface graphique, valider un rendu à l'oreille. Autrement dit du
     travail réel de sa part — jamais une simple confirmation ni une autorisation.
- Le point d'arrêt en fin de jalon reste obligatoire (CDC section 14) : ne jamais enchaîner
  sur le jalon suivant sans son accord explicite. C'est la seule exception à ce qui précède.

---

## Invariants d'architecture — recopiés littéralement du CDC section 12

Ces règles ne sont pas des préférences de style. Elles sont recopiées ici mot pour mot
plutôt que résumées, parce qu'un résumé perd exactement les nuances qui comptent
(CDC section 13, limite connue de PROGRESS.md/CLAUDE.md comme mémoire d'agent).

- Une seule capture Core Audio active à la fois. Jamais deux Process Tap, ou tap et entrée
  physique, simultanés.
- Le flux PCM capturé est dupliqué en lecture seule vers chaque pipeline de sortie ; aucun
  sender ni traitement DSP ne modifie le buffer partagé. Toute transformation (EQ,
  crossover) se fait sur une copie propre à sa sortie, après duplication.
- La capture ne connaît jamais les destinations (Geneva, HomePod) ; les senders ne
  connaissent jamais la source de capture. Chaque sender ignore l'existence de l'autre.
- Une panne ou déconnexion sur une sortie (ex. la Geneva perd le réseau) n'interrompt jamais
  la capture ni l'autre sortie ; le sender concerné tente une reconnexion isolée.
- Toute dépendance de code pointe vers le cœur du projet (capture, modèle de données PCM),
  jamais l'inverse : le module de capture ne doit jamais importer un sender.
- Transfert du callback de capture temps réel vers les threads réseau uniquement via un ring
  buffer lock-free (un par pipeline de sortie), jamais via une structure verrouillée (mutex,
  sémaphore) ni via Swift Concurrency à cet endroit précis. L'écriture dans ces ring
  buffers, effectuée depuis le callback de capture, doit elle-même rester lock-free et sans
  allocation.
- Toute bibliothèque C wrappée (crypto, resampling) est encapsulée dans une classe Swift
  dédiée qui gère l'allocation et la désallocation via `deinit` ; aucun pointeur C manipulé
  à nu en dehors de ce wrapper.

## Règles de code (CDC section 13)

- Pas de force-unwrap.
- Injection de dépendance par protocole.
- `OSLog` pour tous les logs.
- Pas de singleton.
- `fatalError` réservé aux erreurs de programmation non récupérables, jamais à la gestion
  d'erreurs runtime.
- **Frontière temps réel** : le callback audio temps réel (rendu Core Audio) n'utilise
  **pas** Swift Concurrency — callbacks C classiques et structures lock-free, sans
  allocation. Swift Concurrency reste approprié partout ailleurs (UI, réseau de contrôle,
  gestion de session, **et le resampling en aval du ring buffer** — celui-ci tourne dans la
  tâche propre à chaque sender, pas dans le callback de capture, donc l'appel synchrone à
  une bibliothèque C y est légitime, cf. CDC 4.5).

---

## Faits vérifiés sur cette machine

Environnement constaté au jalon -1 (2026-08-05) :

- macOS 26.5.1 (build 25F80), Apple Silicon. Homebrew dans `/opt/homebrew`.
- Swift 6.3.3, target `arm64-apple-macosx26.0`. Les jalons 1 à 4 ne nécessitent que les
  Command Line Tools (`swift build`/`swift run`), pas Xcode (CDC section 11).
- Interface réseau active : `en0`, 192.168.1.21. C'est la valeur à passer en `--netiface`.
- **L'API Process Tap est bien disponible dans le SDK** : `AudioHardwareCreateProcessTap`
  (`CoreAudio/AudioHardwareTapping.h`), `initStereoGlobalTapButExcludeProcesses:` et
  `initStereoMixdownOfProcesses:` (`CoreAudio/CATapDescription.h`). Ces deux initialiseurs
  sont marqués `NS_REFINED_FOR_SWIFT` : côté Swift ils sont exposés sous une forme affinée,
  ne pas s'attendre au nom Objective-C littéral.

## Capture Core Audio — faits vérifiés au jalon 1

Format livré par le Process Tap sur cette machine : **48 000 Hz, 2 canaux, float32
ENTRELACÉ** (`mBytesPerFrame` = 8). Deux conséquences vérifiées à la dure :
- le nombre de trames se déduit de `mBytesPerFrame`, pas de `MemoryLayout<Float>.size` —
  sinon on compte le double des trames réelles ;
- `AVAudioFile(forWriting:..., interleaved:)` décrit le format des buffers **fournis**, pas
  celui du fichier. Une valeur incohérente fait échouer `ExtAudioFileWrite` (OSStatus -50).

Le mode entrée physique (`AVAudioEngine.inputNode`) livre en revanche du **mono planaire**
à 48 kHz : les deux formats coexistent, le code ne doit jamais supposer l'un ou l'autre.

### Les trois pièges du Process Tap (chacun coûte des heures)

1. **`kAudioSubTapUIDKey` attend `CATapDescription.uuid`**, pas la valeur lue via
   `kAudioTapPropertyUID`. Avec la mauvaise valeur, tout « réussit » : le tap se crée,
   l'agrégat se crée, le callback d'IO est appelé au rythme normal avec des buffers de la
   bonne taille — mais entièrement remplis de zéros.
2. **L'agrégat doit porter le périphérique de sortie courant** comme
   `kAudioAggregateDeviceMainSubDeviceKey` **et** dans `kAudioAggregateDeviceSubDeviceListKey` :
   c'est lui qui fournit l'horloge.
3. **Le binaire doit être lancé via le bundle** (`open`, d'où le wrapper `./audiocap`).
   Exécuter `build/audiocap.app/Contents/MacOS/audiocap` directement fait perdre
   l'autorisation TCC : silence numérique, sans erreur.

### Autorisations : deux services TCC distincts

- **Process Tap** (modes global et application) → `kTCCServiceAudioCapture`, panneau
  « Enregistrement de l'écran et des sons du système » > section **« Enregistrement des
  sons du système uniquement »**.
- **Entrée physique** → `kTCCServiceMicrophone`, panneau « Microphone ».

**`AVCaptureDevice.authorizationStatus(for: .audio)` renvoie l'état du MICRO**, jamais
celui de `kTCCServiceAudioCapture`. Elle peut répondre `authorized` alors que le tap ne
livre que du silence : ne jamais s'en servir pour décider si le Process Tap est autorisé.
Aucune API publique n'expose `kTCCServiceAudioCapture` ; `CapturePermission` passe par les
SPI privées `TCCAccessPreflight`/`TCCAccessRequest` (`TCC.framework`), comme le projet de
référence `insidegui/AudioCap`. Ces SPI interdisent une soumission au Mac App Store — sans
objet pour un usage personnel.

**Piège opérationnel** : chaque `./make-cli-bundle.sh` re-signe le bundle, change son CDHash
et **révoque l'autorisation accordée**. Après un rebuild, la retirer puis la ré-ajouter dans
le panneau. Un test qui renvoie du silence juste après un rebuild teste presque toujours ça,
pas le code.

**Diagnostic** : un silence numérique **strict** (0 échantillon non nul) signale une
autorisation manquante ou un tap mal câblé — jamais un blocage DRM (voir le résultat du test
DRM dans `PROGRESS.md`). Un fichier **vide** (0 échantillon écrit) signifie que rien ne
jouait : résultat non concluant, pas un blocage.

## Mocks AirPlay — état et pièges

Lancer/vérifier les deux mocks : **`./run-mocks.sh`** (`start` / `check` / `stop`).
Logs dans `.mock-logs/`.

- **Le récepteur AirPlay natif de macOS doit rester désactivé** (Réglages Système > Général
  > AirDrop et Handoff > Récepteur AirPlay : OFF). Il occupe le port 5000 et empêche
  shairport-sync de démarrer. La build shairport-sync 5.2.1 de Homebrew **ignore l'option
  `port`/`-p`** en mode AirPlay 1 (le log annonce `rtsp listening port is 5000` même avec
  `-p 5010`), donc changer de port ne contourne pas le conflit.
- **Config shairport-sync** : le binaire lit `/opt/homebrew/etc/shairport-sync/shairport-sync.conf`
  (sous-dossier), **pas** `/opt/homebrew/etc/shairport-sync.conf`. Écrire au mauvais endroit
  laisse le mock démarrer sous son nom par défaut, sans erreur visible.
- **Backend audio** : forcer `output_backend = "ao"`. Le défaut de compilation Homebrew est
  `pulseaudio`, qui échoue immédiatement sans serveur PulseAudio lancé.
- **Nom d'instance RAOP** : le service est annoncé sous `65D15B6D3AC1@Geneva-Mock`, avec un
  préfixe d'adresse matérielle. Pour le jalon 2, **le sender doit parcourir `_raop._tcp` et
  résoudre le service**, jamais supposer le nom ni le port en dur.
- Services et ports observés : Geneva-Mock → `_raop._tcp`, port 5000.
  ApTV-HomePod-Mock → `_airplay._tcp`, port 7000.

## Environnement Python (outils de dev uniquement)

Le Python de Homebrew est "externally managed" (PEP 668) : **aucune installation pip
globale n'est possible**, tout passe par un venv.

- Mock AirPlay 2 : venv `tools/airplay2-receiver/proto/`.
- pyatv (pairing du jalon 3, CLI uniquement) : venv dédié `tools/pyatv-venv/`,
  binaire `tools/pyatv-venv/bin/atvremote`.
- `tools/` est gitignoré. pyatv et les mocks sont des outils de développement, **jamais des
  dépendances runtime de l'application** (CDC section 5).

## Outillage réseau (jalon 2)

**Wireshark 4.6.7 installé** (`/Applications/Wireshark.app`), avec **`tshark` dans le PATH**
(`/opt/homebrew/bin/tshark`) : la comparaison de trafic du jalon 2 peut se scripter en CLI,
sans passer par la GUI. La capture fonctionne **sans `sudo`** (utilisateur membre du groupe
`access_bpf`, `/dev/bpf*` en `root:access_bpf` crw-rw----). Interface à capturer : `en0`.

## À installer avant certains jalons

- **OwnTone** : requis au jalon 0 uniquement. **N'existe plus dans homebrew-core** (ni
  `owntone`, ni `forked-daapd`) : à compiler depuis les sources
  (https://github.com/owntone/owntone-server).
- **Bibliothèques C crypto** (csrp, curve25519-donna, ed25519 d'orlp, chachapoly) : à
  récupérer dans `Sources/CCrypto` au jalon 3, en vérifiant soi-même les dépôts corrects.
  Volontairement non automatisé (CDC section 14).
