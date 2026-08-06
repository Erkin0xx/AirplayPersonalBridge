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

## Sender RAOP — faits vérifiés au jalon 2

Format négocié avec le mock Geneva (annonce TXT `_raop._tcp`) : `sr=44100`, `ss=16`, `ch=2`,
`et=0,1` (RSA-AES disponible), `cn=0,1` (ALAC disponible). **La capture livrant du 48 kHz, un
rééchantillonnage vers 44,1 kHz est obligatoire** — il tourne dans la tâche du sender, en
aval du ring buffer (emplacement autorisé par le CDC 4.5).

Ports du récepteur observés : audio 6003, control 6001, timing 6002. **Ce sont ceux de la
réponse au `SETUP` qui font foi**, jamais ceux demandés — ces derniers ne sont qu'une
suggestion.

### Les trois pièges du sender RAOP (chacun a coûté du temps)

1. **L'en-tête ALAC fait 20 bits, pas 11.** Le décodeur (`alac.c` de shairport-sync, cas
   « 2 channels ») lit 4 bits puis **12 bits** d'inutilisé avant `hasSize`,
   `uncompressedBytes` (2 bits) et `isNotCompressed`. Plusieurs documentations informelles
   décrivent un en-tête commençant par `channels - 1` sur 3 bits : ces 3 bits appartiennent
   au *tag d'élément* du bitstream ALAC, **que RAOP ne transporte pas**. Avec 9 bits
   manquants, `isNotCompressed` est lu à 0, le récepteur décode une trame compressée
   inexistante et journalise `FIXME: unhandled prediction type`. Trame correcte pour 352
   trames stéréo non compressées : **1 411 octets**.
2. **`AVAudioConverter.convert` ne rend jamais plus de 4 096 trames par appel**, quelle que
   soit la capacité du tampon de sortie, et signale `.inputRanDry` **en retenant encore des
   trames**. S'arrêter sur ce statut perd ~6,5 % du flux, en silence et définitivement. Ne
   sortir de la boucle que sur un appel réellement improductif (0 trame produite).
3. **Un flux RTP doit être cadencé, pas envoyé en rafales.** Émettre tous les paquets
   disponibles avant de dormir donne un intervalle médian de 0,7 ms pour 7,98 ms théoriques,
   avec des pauses de près d'une seconde. Un paquet par tour de boucle, à l'échéance
   (`nextDeadline += packetDuration`), donne 7,98 ms de moyenne et 0 rupture de séquence.

### Autres points à ne pas réapprendre

- **`TEARDOWN` et `SET_PARAMETER` doivent porter l'URI de session** construite à
  l'`ANNOUNCE`, pas une URI reconstruite. shairport-sync tolère l'écart ; les récepteurs
  matériels rejettent couramment un `TEARDOWN` dont l'URI ne correspond à aucune session, et
  la session reste alors bloquée côté récepteur.
- **Le base64 du SDP (`rsaaeskey`, `aesiv`) doit être sans bourrage `=`.**
- **Le chiffrement audio repart du même IV à chaque paquet** (CBC non chaîné entre paquets)
  et **laisse le reliquat de moins de 16 octets en clair**, sans bourrage. Les deux sont
  exigés par le protocole : c'est ce qui rend une retransmission isolée décodable.
- **La clé publique RAOP en dur n'est pas un secret** : c'est la clé *publique* qu'attend
  tout récepteur annonçant `et=1`, identique dans shairport-sync, OwnTone et pyatv.
- **Le mock quitte après chaque session** (`TEARDOWN`). Il est stable au repos. Relancer
  `./run-mocks.sh start` entre deux essais.
- **Écarter l'arriéré du ring buffer avant de commencer à diffuser** : la capture tourne
  pendant la découverte Bonjour et la négociation RTSP (~4 s), le tampon a déjà débordé.
  Sans cela, la diffusion démarre avec plusieurs secondes de retard sur le direct.
- **`droppedFrames` du ring buffer est ambigu sans point de repère** : la quasi-totalité des
  refus vient de la fenêtre de négociation, pas du régime établi. Photographier le compteur
  au premier paquet émis pour distinguer les deux (`RAOPStatistics.droppedBeforeStreaming`).

### Outils de comparaison : ce qui ne marche pas sur cette machine

- **pyatv échoue contre shairport-sync 5.2.1** : il envoie un `GET /info` AirPlay 2, le mock
  répond `200 OK` avec un corps **vide**, et pyatv analyse ce corps vide comme un plist
  binaire → `InvalidFileException`. Incompatibilité pyatv/shairport, sans rapport avec le
  code du projet.
- **Le pyatv du jalon -1 (`tools/pyatv-venv/`) est cassé sur Python 3.14** (`asyncio.get_event_loop`
  supprimé). Un venv Python 3.13 fonctionnel a été créé : **`tools/pyatv313/`**.
- **Airfoil** (dans `~/Downloads`) exige l'autorisation « Accessibilité » pour son interface
  de script, et installe un pilote audio sous licence à accepter : deux actions graphiques.
- **Deux sélecteurs de sortie AirPlay distincts dans macOS, qui ne listent pas la même
  chose** (vérifié le 2026-08-06) :
  - le **menu son de la barre de menus** ne montre que les récepteurs **AirPlay 2**
    (`ApTV-HomePod-Mock`) et **omet** Geneva-Mock (`_raop._tcp`) ;
  - le **sélecteur AirPlay d'Apple Music** liste bien **les deux**, Geneva-Mock compris.

  Conséquence pratique : pour capturer une session RAOP de référence, **passer par Apple
  Music**, pas par le menu son. Ne pas conclure d'une absence dans le menu son que macOS ne
  sait pas parler à un récepteur AirPlay 1 — c'est faux, et cette erreur a été commise puis
  corrigée à ce jalon.
- **macOS ne parvient pas à diffuser vers shairport-sync 5.2.1, même en ne cochant que
  lui.** Capture de 33 s : seulement deux `OPTIONS *` et leurs `200 OK`, jamais d'`ANNOUNCE`
  ni d'audio. Symptômes visibles : sortie affichée comme active, aucun son, lecture qui
  repart au début. Cause **non élucidée** — ce n'est *pas* le défi `Apple-Challenge`
  (absent des requêtes, et shairport sait y répondre). **Ne pas y repasser de temps : la
  comparaison avec macOS natif demandera la vraie Geneva.**
- **macOS envoie un `OPTIONS *` avant l'`ANNOUNCE`** (`User-Agent: Music/…`,
  `Client-Instance`, `DACP-ID`, `Active-Remote`). **Le sender du projet ne l'envoie pas** et
  attaque directement par `ANNOUNCE` ; shairport l'accepte. À vérifier contre la vraie
  Geneva : si elle refuse, ajouter l'`OPTIONS` préalable est trivial.
- **Sélectionner une sortie AirPlay dans macOS passe par le menu son**, sans équivalent en
  ligne de commande. Toute comparaison avec un sender de référence demande donc une action
  physique de Baptiste, sur du matériel réel.

### Capture réseau : filtrer sur la bonne interface

Mock et sender tournant sur la **même machine**, le trafic passe par **`lo0`**, pas par
`en0`. Un filtre `host 192.168.1.21` ne capte rien. Utiliser :
`tshark -i lo0 -i en0 -f "tcp port 5000 or udp portrange 6000-6100"`.
Ne pas déduire la taille de la charge utile de `frame.len` : lire `udp.length` et `data.len`.

## Environnement Python (outils de dev uniquement)

Le Python de Homebrew est "externally managed" (PEP 668) : **aucune installation pip
globale n'est possible**, tout passe par un venv.

- Mock AirPlay 2 : venv `tools/airplay2-receiver/proto/`.
- pyatv (pairing du jalon 3, CLI uniquement) : venv dédié `tools/pyatv-venv/`,
  binaire `tools/pyatv-venv/bin/atvremote`. **Cassé sur Python 3.14** (voir jalon 2) :
  utiliser **`tools/pyatv313/bin/atvremote`** (pyatv 0.18.0 sur Python 3.13).
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
