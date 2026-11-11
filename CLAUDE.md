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
- **Commit et push automatiques en fin de tour** (décidé le 2026-08-06) : un hook `Stop`
  déclare `.claude/auto-commit.sh`, qui commite et pousse tout ce qui a changé, sans
  confirmation. Conséquences à connaître :
  - l'historique contient des commits intermédiaires `chore(auto): checkpoint …` (`auto: …` avant le
    2026-11-09), **qui ne sont pas des
    commits de clôture de jalon** — `PROGRESS.md` reste la source de vérité sur l'état réel ;
  - le script ne fait rien si l'arbre est propre (jamais de commit vide) ;
  - `touch .claude/skip-auto-commit` suspend le mécanisme sans toucher au hook. **À poser dès que
    deux sessions travaillent sur le dépôt** : le `git add -A` du hook de l'une emporterait les
    fichiers en cours de l'autre. Chacune commite alors ses chemins à la main, et l'interrupteur
    est retiré quand il n'en reste qu'une ;
  - un push impossible (réseau, conflit distant) ne bloque pas la fin de tour : le commit
    local est fait et repartira au tour suivant.

  Cela ne remplace pas la procédure de clôture de jalon, qui reste un commit **délibéré**
  avec un message rédigé, après mise à jour de la documentation.
- **Solliciter Baptiste uniquement dans deux cas :**
  1. une étape ou un jalon est terminé, et il faut faire le point ;
  2. il y a une **action concrète que lui seul peut faire** : lancer une vidéo dans un
     service où il est connecté, brancher un ampli ou une interface audio, basculer un
     réglage dans une interface graphique, valider un rendu à l'oreille. Autrement dit du
     travail réel de sa part — jamais une simple confirmation ni une autorisation.
- Le point d'arrêt en fin de jalon reste obligatoire (CDC section 14) : ne jamais enchaîner
  sur le jalon suivant sans son accord explicite. C'est la seule exception à ce qui précède.

### Procédure de clôture de jalon — ordre à suivre

Le CDC section 14 en fixe le principe ; voici la liste effective, **`README.md` inclus**
(ajouté le 2026-08-06 — il annonçait encore le jalon 2 comme non fait alors qu'il l'était) :

1. **`PROGRESS.md`** — fait / problèmes / reste ouvert, en distinguant explicitement
   « validé contre mock » de « validé contre matériel réel ».
2. **`CLAUDE.md`** (ce fichier) — les faits durables et les pièges vérifiés.
3. **`README.md`** — tableau des jalons, commandes disponibles, limites connues. C'est la
   vitrine du dépôt : un README périmé est la première chose que voit quelqu'un qui arrive.
4. **Vault** — un ADR dans `decisions/` pour toute décision d'architecture arbitrée, une
   entrée dans `notes.md` pour toute correction de raisonnement.
5. **Commit délibéré** référençant le jalon (pas un `auto:`), puis **push**.
6. **Point d'arrêt** et compte rendu.

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

Environnement relevé le 2026-11-01 (les mesures des jalons 1 à 4 datent de macOS 26.5.1) :

- macOS 27.0.1, Apple Silicon, Xcode 26.6, Swift 6.3.3. Homebrew dans `/opt/homebrew`.
- **Plancher macOS 26** partout (`Package.swift`, cible Xcode, `Resources/audiocap-Info.plist`) :
  c'est ce qu'exige `libcrypto.a`, bouteille Homebrew liée statiquement. Annoncer moins produit
  838 avertissements de l'éditeur de liens à chaque lien.
- `swift build` compile aussi toute l'app : la cible `BridgeApp` reprend les fichiers de la cible
  Xcode, sauf le point d'entrée `@main`, avec la même isolation par défaut. Seul `xcodebuild` compile
  `AirplayPersonalBridgeApp.swift`.
- **L'IP du Mac change** : `en0` valait 192.168.1.21 en août, 192.168.1.176 le 2026-11-01. La relire
  avec `ipconfig getifaddr en0`, ne jamais la tenir pour acquise. Le mock AirPlay 2 écoute sur cette
  adresse, pas sur `127.0.0.1`.
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

**Une signature ad-hoc révoque l'autorisation à chaque compilation**, car son CDHash change. C'est
ce que l'identité stable règle : voir « Signature et installation » plus bas. Un silence juste après
un rebuild reste à soupçonner si `credentials/signing/` a été perdu ou si la compilation vient de
Xcode, qui signe en ad-hoc.

**Diagnostic** : un silence numérique **strict** (0 échantillon non nul) signale une
autorisation manquante ou un tap mal câblé — jamais un blocage DRM (voir le résultat du test
DRM dans `PROGRESS.md`). Un fichier **vide** (0 échantillon écrit) signifie que rien ne
jouait : résultat non concluant, pas un blocage. **Le tap ne livre aucun bloc tant que rien ne
joue** (`kAudioAggregateDeviceTapAutoStartKey`) : lancer la lecture avant de conclure.

## Mocks AirPlay — état et pièges

Lancer/vérifier les deux mocks : **`./run-mocks.sh`** (`start` / `check` / `restart` / `stop`).
`check` vérifie l'annonce Bonjour **et** le port, `stop` n'arrête que les PID lancés par le script.
Logs dans `.mock-logs/`. Les laisser éteints pendant un essai sur le vrai matériel : ils
apparaîtraient comme des enceintes dans l'app, qui mémorise les sorties cochées.

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
- **Nom d'instance RAOP** : le service est annoncé sous `<préfixe>@Geneva-Mock`. Le préfixe
  change (`65D15B6D3AC1` en août, `52B8FAE6DA40` le 2026-11-01) et n'est pas la MAC d'`en0` : le
  relever avec `dns-sd -B _raop._tcp local`, **jamais le coder en dur**. Le sender parcourt
  `_raop._tcp` et résout le service, sans supposer ni le nom ni le port.
- Services et ports observés : Geneva-Mock → `_raop._tcp`, port 5000.
  ApTV-HomePod-Mock → `_airplay._tcp`, port 7000.
- **Juger le son reçu** : `shairport-sync -o stdout` livre ce que le mock a décodé, analysable, **à condition d'y
  ajouter `ignore_volume_control`** : sinon un volume de −30 ne laisse que du dither. Son journal
  `Input format: ALAC` s'affiche aussi pour du PCM : ne pas s'y fier.
- **shairport peut ignorer SIGTERM après une session** et tourner à vide (3/3) : `./run-mocks.sh stop` passe à
  SIGKILL après 5 s.

## Sender RAOP — faits vérifiés au jalon 2

Format négocié avec le mock Geneva (annonce TXT `_raop._tcp`) : `sr=44100`, `ss=16`, `ch=2`,
`et=0,1` (RSA-AES disponible), `cn=0,1` (ALAC disponible). **La vraie Geneva annonce autre chose**,
voir « Sortie réelle ». **La capture livrant du 48 kHz, un rééchantillonnage vers 44,1 kHz est
obligatoire** — il tourne dans la tâche du sender, en aval du ring buffer (emplacement autorisé par
le CDC 4.5).

Ports du récepteur observés : audio 6003, control 6001, timing 6002. **Ce sont ceux de la
réponse au `SETUP` qui font foi**, jamais ceux demandés — ces derniers ne sont qu'une
suggestion.

### Les trois pièges du sender RAOP (chacun a coûté du temps)

1. **L'en-tête ALAC fait 23 bits.** `alac_decode_frame` (`alac.c` de shairport-sync) lit
   `channels` sur 3 bits **avant** son `switch`, puis 4 et 12 bits d'inutilisé, `hasSize`,
   `uncompressedBytes` (2 bits) et `isNotCompressed`. Ce fichier a longtemps affirmé 20 bits, en
   tenant ces 3 bits pour un tag que RAOP ne transporterait pas : c'était faux, et le test
   d'aller-retour le validait parce qu'il rejouait la même hypothèse. Tout décalé de 3 bits, le
   décodeur abandonne chaque trame (`Not enough space […] E2`), et la vraie Geneva jouait un ton
   continu. Trame correcte pour 352 trames stéréo non compressées : **1 412 octets**. La Geneva
   reçoit maintenant du PCM, ALAC ne sert qu'aux récepteurs qui l'exigent.
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
- **Le base64 du SDP (`rsaaeskey`, `aesiv`) est envoyé sans bourrage `=`.** Il n'était pour rien dans
  l'échec du SDP, voir plus bas.
- **La clé publique RSA tient parce qu'elle est recoupée**, pas parce qu'elle a l'air juste : voir
  « L'échec du SDP contre shairport-sync ». `RAOPCryptoTests` épingle son empreinte.
- **Le chiffrement audio repart du même IV à chaque paquet** (CBC non chaîné entre paquets)
  et **laisse le reliquat de moins de 16 octets en clair**, sans bourrage. Les deux sont
  exigés par le protocole : c'est ce qui rend une retransmission isolée décodable.
- **La clé publique RAOP en dur n'est pas un secret** : c'est la clé *publique* qu'attend
  tout récepteur annonçant `et=1`, identique dans shairport-sync, OwnTone et pyatv.
- **Le mock RAOP ne quitte plus au `TEARDOWN` et ne meurt plus** (relevé le 2026-11-02, flux désormais bien formé) :
  plus besoin de le relancer entre deux essais.
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
  `Client-Instance`, `DACP-ID`, `Active-Remote`). **Le sender du projet ne l'envoie pas**, pas plus
  que pyatv : la vraie Geneva a joué sans.
- **Sélectionner une sortie AirPlay dans macOS passe par le menu son**, sans équivalent en
  ligne de commande. Toute comparaison avec un sender de référence demande donc une action
  physique de Baptiste, sur du matériel réel.

### Capture réseau : filtrer sur la bonne interface

Mock et sender tournant sur la **même machine**, le trafic passe par **`lo0`**, pas par
`en0`. Un filtre sur l'adresse du Mac ne capte rien. Utiliser :
`tshark -i lo0 -i en0 -f "tcp port 5000 or udp portrange 6000-6100"`. Le trafic vers le vrai
matériel passe par `en0`.
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

## Sender AirPlay 2 — faits vérifiés au jalon 3

### Le mode de pairing se lit dans les bits de fonctionnalité, pas dans la doc

Le TXT Bonjour de `_airplay._tcp` porte `features=<mot bas>,<mot haut>`, **le second mot
étant celui de poids fort** (`0x405f4200,0x1c300` → `0x1c300405f4200`). Les bits qui
décident du chemin de pairing :

- **bit 48** = pair-setup **transitoire** : M1–M4, aucune clé long terme échangée, aucun code
  à saisir, **aucun credential à persister**.
- **bit 43** = appairage système persistant (code + `pair-verify` à chaque session).
- bit 46 = HomeKit, bit 27 = legacy AirPlay 1.

Le mock arme **48 sans 43** : le jalon 3 implémente donc le transitoire. `./audiocap --browse2`
affiche ces bits — c'est la commande à lancer en premier devant un récepteur inconnu.
Sur le matériel réel, les HomePod acceptent le transitoire ; **l'Apple TV le refuse en 470 même en
annonçant le bit 48**, d'où le critère sur son modèle : voir « Sortie réelle ». Le bit 48 ne prouve
donc pas qu'un récepteur jouera, mais lui seul peut départager deux lignes d'une même enceinte.

**Corollaire à ne pas réapprendre** : `atvremote pair` échoue contre ce mock (il lève
`invalid proof`), alors que `atvremote stream_file` fonctionne sans aucun pair-setup. Ce
n'est pas un défaut de pyatv : ce récepteur ne sert pas le chemin avec code. pyatv le dit
lui-même en rapportant `Pairing: NotNeeded`.

### Le piège SRP : trois conventions de bourrage, pas deux

AirPlay 2 emploie SRP-6a **SHA-512 sur le groupe 3072 bits**, utilisateur `Pair-Setup`,
mot de passe fixe `3939` en transitoire. Le bourrage des opérandes est un **hybride** :

| Valeur | Bourré à 384 o ? |
|---|---|
| `u = H(A, B)` | **oui** |
| `k = H(N, g)` | **oui** |
| `H(g)` dans la preuve `M1` | **NON** — condensat de l'octet `0x05` seul |

Aucune des deux branches de `cocagne/csrp` n'exprime cet hybride : `master` ne bourre rien,
`rfc5054_compat` bourre les trois. D'où la branche `rfc5054_compat` **plus une modification
locale de six lignes** dans `calculate_M` (`padding` forcé à 0), commentée dans le fichier et
dans `Sources/CCrypto/README.md`.

**Symptôme si on se trompe** : le récepteur répond `invalid proof` alors que `A`, `B`, le sel
et toutes les longueurs concordent octet pour octet. Se fier aux tailles ne sert à rien ici.
La référence qui tranche est `ap2/pairing/srp.py` du mock, où `H(self.N) ^ H(self.g)` est
appelé **sans** `pad=True` tandis que `u` et `k` le sont.

### Canal de contrôle chiffré : trois détails qui font tout échouer

Après le pair-setup, chaque message RTSP est encadré en
`[longueur 2 o LE][cryptogramme][étiquette Poly1305 16 o]`, blocs de 1 024 o au plus.

1. **Les deux octets de longueur sont les données associées** de l'AEAD.
2. **Le nonce est un compteur de blocs 64 bits LE précédé de 4 octets nuls**, qui ne repart
   jamais de zéro tant que la connexion vit.
3. **Les deux sens ont clés et compteurs distincts** : `Control-Salt` avec
   `Control-Write-Encryption-Key` (ce qu'on écrit) et `Control-Read-Encryption-Key` (ce
   qu'on lit). Les intervertir donne un canal qui échoue au premier bloc.

Sels et infos HKDF-SHA512 du pairing (relevés dans `hap.py`) : `Pair-Setup-Encrypt-Salt`/
`-Info`, `Pair-Setup-Controller-Sign-Salt`/`-Info`, `Pair-Verify-Encrypt-Salt`/`-Info`.

### Séquence RTSP : deux SETUP, pas un, et des plists binaires

Pas d'`ANNOUNCE` ni de SDP : les paramètres passent en **plists binaires**.

1. `SETUP` **sans** clé `streams` → ouvre la session, rend `eventPort`.
2. `SETUP` **avec** `streams` → ouvre le flux, rend `dataPort`, `controlPort`, `streamID`.
3. `SET_PARAMETER` (volume), 4. `RECORD`, 5. `TEARDOWN`.

Comme en RAOP, **ce sont les ports de la réponse qui font foi**, jamais ceux demandés.
Format audio PCM 44,1 kHz, 16 bits, stéréo = `1 << 11` (`0x800`), avec `ct=1`, comme chez pyatv ; le
jalon 3 envoyait `ALAC_44100_16_2` = `1 << 18`. Type de flux temps réel = `96` (`103` = bufferisé).
`spf` = 352 trames, comme en RAOP.

### `NWBrowser` écarte silencieusement un service au TXT douteux

Avec `.bonjourWithTXTRecord`, le mock AirPlay 2 **n'apparaît pas du tout** dans les
résultats — pas d'erreur, liste vide — alors que `dns-sd` et `.bonjour` (sans TXT) le voient,
et que le même code rend bien le service RAOP de shairport-sync.

**Parade retenue** : parcourir **sans** TXT, puis lire le TXT par une requête DNS dédiée
(`BonjourTXTQuery`, API `dns_sd`). Sans TXT, pas de bits de fonctionnalité ni de clé
publique — donc pas de choix de pairing possible.

Piège associé : le nom pleinement qualifié se construit `instance._service._tcp.domaine.`.
`NWEndpoint` rend le type **sans** point final et le domaine **avec** : les concaténer tels
quels donne `_airplay._tcplocal.`, introuvable, et le TXT revient vide **sans erreur**.

### Attente infinie sur `NWConnection.receive` (défaut corrigé, présent depuis le jalon 2)

`receive` peut **ne jamais rappeler** quand le pair disparaît sans fermer proprement — ce que
font les deux mocks après un `TEARDOWN`. Vérifier une échéance *entre* deux lectures ne suffit
pas : le contrôle n'y revient jamais. Il faut une **échéance par lecture**, avec reprise
unique garantie (deux reprises d'une `CheckedContinuation` sont fatales).

Symptôme : le processus ne se termine jamais, **après** avoir affiché tous ses résultats et
alors que la diffusion s'est parfaitement passée. Les `TEARDOWN` des deux senders utilisent
désormais un délai court de 2 s. `RTSPClient` lit en permanence depuis le jalon 5 : il voit aussi un
FIN et un RST, qui passaient inaperçus.

### Mock AirPlay 2 : deux comportements à connaître

- **Son enregistrement mDNS devient périmé après quelques minutes** : `dns-sd` continue de
  l'annoncer alors que `NWBrowser` ne le voit plus. Relancer `./run-mocks.sh restart`. C'est la
  **première** chose à vérifier devant un « récepteur introuvable », avant de suspecter le code.
  Il n'accepte qu'une session à la fois.
- **Son puits audio plante sur `av` 18** (`codecContext.channels` en lecture seule), y compris
  avec pyatv comme sender. C'est **en aval du protocole** : la négociation et la réception des
  paquets fonctionnent, seul le décodage local échoue. Conséquence : la validation du jalon 3
  porte sur le protocole et le flux réseau, **pas sur une écoute**.

## Synchronisation et dérive — faits vérifiés au jalon 4

### shairport-sync n'horodate pas ses requêtes de timing

**Le fait le plus coûteux du jalon.** Le canal de timing RAOP prévoit que le récepteur place
son instant d'émission aux octets 24–31 de sa requête. shairport-sync 5.2.1 envoie ses
requêtes **intégralement à zéro** :

```
6002 → 51534   80d2000700000000 0000000000000000 0000000000000000 0000000000000000
51534 → 6002   80d30007000000000000000000000000 ee1f84870c0d9000 ee1f84870c0e0800
```

(capture `tshark -i lo0`, le second paquet étant notre réponse, correctement horodatée.)

Conséquence : **la mesure passive du décalage d'horloge est impossible contre ce récepteur**.
Une soustraction naïve donne `local − 0` = l'époque NTP, soit un décalage annoncé de
**3 995 042 823 685 ms**. `TimingEstimator` rejette donc les estampilles invraisemblables
(> 1 h d'écart) et les compte à part, plutôt que de publier un nombre absurde.

À revérifier contre la vraie Geneva : le champ existe dans le protocole, rien ne dit qu'un
récepteur matériel le laisse à zéro. Si elle l'horodate, la mesure fonctionne sans changer
une ligne.

### Le flux de requêtes d'horloge n'est PAS un signal de vie utilisable

shairport-sync interroge densément pendant ~35 s après le `RECORD`, puis **se tait
complètement** alors que la session se porte parfaitement (14 requêtes en tout sur une
session de 60 s, aucune après la 35ᵉ seconde). Un délai de garde de 30 s sur ce silence
déclenchait une reconnexion sur une session saine. Ce relevé date d'un flux qu'il décodait de travers ;
sur un flux bien formé, il interroge environ toutes les 3 s (63 requêtes en 180 s, le 2026-11-02), toujours
sans estampille. La conclusion ne change pas : rien n'oblige un récepteur à tenir ce rythme.

**Le signal franc de perte de session est la rupture de la connexion RTSP** (TCP), FIN et RST
compris, et celle du **canal d'événements** côté AirPlay 2. Une coupure de courant n'envoie ni l'un ni
l'autre : le keepalive TCP 5/2/3 de `RTSPClient` la voit en 11 s au pire, en théorie, jamais mesuré. Le
flux audio étant en UDP, il ne signale jamais rien : les datagrammes partent indéfiniment dans le vide
vers un récepteur disparu. **Un `/feedback` sans réponse n'est pas une perte** : chez pyatv il est
« best effort », et le déclarer fatal couperait un son qui marche.

### Le canal de contrôle AirPlay 2 accepte le paquet de synchro RAOP

Avec `timingProtocol=NTP`, le récepteur attend sur son `controlPort` un RTCP
`TIME_ANNOUNCE_NTP` — type 0x54, exactement le paquet que `RTPPacketBuilder.sync` produit
déjà pour RAOP (`ap2/connections/control.py`, `RTCP.PktType.TIME_ANNOUNCE_NTP = 212 = 0xd4`
une fois le bit marker posé ; il accepte `plen` 20 comme 32). **Aucun format spécifique à
écrire** : les deux sorties s'ancrent avec le même paquet.

### Le canal d'événements du mock AirPlay 2 ne fait que lire

`EventGeneric` (`ap2/connections/event.py`) accepte une connexion TCP, lit les octets et les
jette ; il n'émet **jamais rien**. Son port « ntp » est la même classe, donc un simple
listener TCP, pas un serveur NTP. Conséquence : **la connexion au canal d'événements est
validée, le décodage des événements ne l'est pas** — faute de récepteur qui en émette. Sur
du matériel réel le contenu est chiffré avec les clés du pairing et encadré comme le canal
de contrôle : `Events-Salt`, avec des infos **inversées** (on écrit avec `Events-Read-Encryption-Key`).
Comme pyatv, on déchiffre et on acquitte en 200 sans interpréter le contenu : validé contre un faux
canal seulement.

### La dérive réellement observée est minuscule, mais elle existe

Capture et émission ne partagent pas la même horloge : le périphérique audio cadence la
première, `ContinuousClock` (horloge hôte) la seconde. C'est ce que la correction Snapcast
rattrape. Sur cette machine, l'écart mesuré reste sous **0,1 ms** en régime établi, très en
deçà du seuil de perception de 20 à 30 ms — mais la boucle de correction reste indispensable
tant qu'un autre matériel n'a pas été mesuré.

**La consigne de délai de pipeline est observée, jamais décrétée** : elle est la moyenne
mesurée pendant 10 s de stabilisation. Une constante arbitraire obligerait la correction à
rattraper d'emblée un écart qui n'est pas de la dérive.

### L'échec du SDP contre shairport-sync — élucidé au jalon 5

Le symptôme, au jalon 4 : `client announced rsaaeskey of 256 bytes, wanted 16` à chaque `ANNOUNCE`,
décodage de travers, et le mock mort sur un `Bus error`. Trois causes empilées :

1. **Les 67 derniers octets du modulus RSA du code étaient faux** (`oaep decoding error` chez
   shairport-sync). Le bourrage base64, longtemps suspecté, n'y était pour rien. Côté sender, rien ne
   le trahit : la clé se charge et chiffre sans erreur, le cryptogramme fait 256 octets.
2. **L'en-tête ALAC était amputé de 3 bits** : voir le premier piège RAOP.
3. **shairport-sync jusqu'à 5.2.1 décode L16 + `fmtp` comme de l'ALAC**, quel que soit le `rtpmap` :
   `Bus error` au jalon 4, bruit pleine échelle le 2026-11-02. La ligne `fmtp` reste pourtant envoyée à la Geneva, comme le fait pyatv : elle n'a jamais été
   validée sans. Elle n'est retirée que face à un récepteur qui annonce aussi ALAC.

Le sender préfère désormais le **clair** quand `et` le propose (`et=0,1`), et le chemin clair a tenu
60 s contre le mock, son décodé sans anomalie à 440 Hz. **Rien de tout cela ne touchait la vraie Geneva
ni les HomePod**, qui n'emploient pas RSA.

### Toujours vérifier que le mock ACCEPTE avant de lancer une session longue

shairport-sync peut être annoncé alors que son port 5000 refuse encore les connexions, juste après son
lancement. `./run-mocks.sh check` vérifie désormais le port.
Le moteur, lui, attend un récepteur absent en tâche de fond (`waitingForReceiver`), avec repli
exponentiel : un récepteur en retard ne tue plus une sortie.

### Capture réseau d'une session AirPlay 2

Mock et sender sur la même machine : capturer sur **`lo0` et `en0` à la fois**, sans filtre
BPF restrictif (le filtre appliqué à une capture multi-interfaces s'est révélé peu fiable),
puis filtrer à la lecture (`-Y "tcp.port==7000"`). Trace de référence, de l'époque où le flux était
encore en ALAC : `captures/jalon3-airplay2-session.pcapng`.

Elle montre visuellement le chiffrement : les deux `POST /pair-setup` sont lisibles en clair,
et plus rien ne l'est ensuite. Le RTSP chiffré est illisible en capture : pour un HomePod, lire les
journaux (`log show`).

---

## Sortie réelle — faits vérifiés sur le matériel (2026-08-11 et 12, puis 2026-11-02)

Ce qui suit vient des commits 824f16d à 0cf8a31, puis de la session de test matériel du 2026-11-02
(`docs/prompt_tests_materiel.md`). Détail et niveaux de preuve dans `PROGRESS.md`.

- **Geneva AeroSphere Large**, nom réseau **`Erki’s geneva`** (apostrophe typographique), instance RAOP
  `F8F25A011261@Erki’s geneva`, hôte `Erkis-geneva.local`, 192.168.1.39:5000. `features=0x444c0a00` sans aucun bit
  de pairing : récepteur AirPlay 1 même si elle s'annonce aussi en `_airplay._tcp`. TXT `et=0,4` et, depuis son
  firmware `fv=s9816.258.1009`, **`cn=0,1`** (elle annonçait `cn=0` en août) : le SDP L16 part donc **sans** ligne
  `a=fmtp`, et elle le décode bien (entendu le 2026-11-02). PCM big-endian sans chiffrement.
- **`Audio-Latency: 4096` de la Geneva (92,88 ms) ne doit PAS être retranchée de l'ancrage** (commit 2ba1336). Mesuré
  au micro : avec cette soustraction (0cf8a31) elle jouait 84 ms avant les HomePod, un écho net ; sans elle, au niveau
  des HomePod, et Baptiste n'entend plus d'écho. Le récepteur tient déjà compte de sa latence pour l'instant annoncé.
- **Garder la Geneva éveillée : −50 dBFS au moins, jamais −60.** Une session RAOP à −50 dBFS 60 Hz, volume −30, relancée en
  boucle, l'a tenue allumée près de 2 h 30 (ping 60/60). À **−60 dBFS** 60 Hz, volume −30, elle a fermé la session et **quitté
  le réseau 15 min plus tard** (2026-11-02, 21:18 : FIN sur le RTSP, puis ping 0/60 et plus d'annonce Bonjour). Éteinte ainsi,
  rien ne la réveille à distance : il faut que Baptiste la rallume. Un ping seul ne prouve rien.
- **HomePod gen 2**, « Salon » (192.168.1.66, à gauche face à la télé) et « Salon (2) » (192.168.1.69, à droite,
  leader de la paire : bit 13 de `flags`). Ils forment une **paire stéréo** (même `tsid`), et font partie du groupe
  « Home cinéma » de l'Apple TV (même `gid`, `psgsz=3`). firmware `osvers=27.2`, `srcvers=1005.13.2`.
  - **Un membre adressé seul ne joue que SON canal** (entendu) : « Salon (2) » seul ne restitue que la droite, l'autre
    reste muet. Les clés de groupe d'un iPhone au `SETUP` (`tightSyncUUID`=`tsid`, `groupUUID`=`gid`) n'y changent rien.
    **La vraie stéréo exige une session vers chacun.**
  - **Deux sessions démarrées à des moments différents s'expulsent mutuellement** : chaque ouverture fait tomber l'autre,
    en boucle (coupures toutes les ~10 s, entendu). Démarrées ensemble, elles tiennent (1 h sans perte le 2026-11-02).
  - **Deux pair-setups transitoires simultanés vers les deux membres** : l'un échoue à M3 (TLV « authentification »).
    D'où un seul pairing à la fois par moteur (`PairingGate`), et un refus transitoire passager et réessayé.
  - **403 Forbidden si les requêtes de session ne portent pas toutes la même identité de contrôleur**
    (`User-Agent: AirPlay/550.10`, `DACP-ID`, `Active-Remote`, `Client-Instance` = DACP-ID). C'est ce qui empêchait
    toute session le 2026-11-02 (le volume, avant `RECORD`, était refusé). `AirPlay2Session.ControllerIdentity`.
  - **Le premier essai après une session terminée est souvent coupé** par le HomePod juste après le `SETUP` du flux
    (alternance démontrée, pyatv tombe pareil juste après nous). Cause inconnue : ni l'Apple TV (en veille, idem),
    ni le `TEARDOWN`, ni l'identifiant, ni l'ordre du canal d'événements. Parade : une renégociation immédiate.
  - **Une paire stéréo n'a qu'un seul volume** : le dernier `SET_PARAMETER volume` reçu par l'un vaut pour les deux (constaté par
    Baptiste). D'où les groupes de volume par `tsid` (`VolumeGroups`) : même volume AirPlay pour toute la paire, celui du plus fort, et
    l'écart en gain numérique sur la copie de chaque sender (`OutputGainStage`), **compté sur l'échelle du fil** (2 dB d'interface =
    1 dB AirPlay). Le gain numérique s'entend après le délai de restitution (0,4 s depuis le 2026-11-10), le volume AirPlay sans doute aussitôt.
    **Jamais −144 pour couper un seul membre** : le silence par enceinte est numérique.
  - Accepte le transitoire, `/pair-pin-start` inutile. **Pas d'`Audio-Latency`** au `RECORD`. Annonces `0xD4` à
    NTP − émission ≈ 0. Aucune requête sur le canal d'événements en session.
- **Le HomePod ne répond au `SETUP` qu'après avoir mesuré notre horloge** : le répondeur de timing doit
  écouter **avant** le `SETUP`. Il refuse le `SETUP` en 400 sur l'IPv6 de lien local : IPv4 d'abord.
- **Charge utile AirPlay 2 en PCM big-endian.** Données associées de l'AEAD = octets 4 à 12 de l'en-tête
  RTP. Nonce de 8 octets ajouté après l'étiquette Poly1305. Un bruit blanc est une bonne nouvelle : un
  paquet mal chiffré serait rejeté et donnerait du silence.
- **Apple TV** (« Apple TV Salon », AppleTV14,1, 192.168.1.52) : refuse le transitoire en 470 même en annonçant le
  bit 48 ; l'app la signale « appairage requis » d'après le TXT `model`. **`pair-verify` abouti le 2026-11-02** avec
  les credentials pyatv (`credentials/appletv-salon-airplay.txt`, par chemin absolu, jamais affichés), session et
  `TEARDOWN` acceptés, **mais aucun son ne sort**, Apple TV en veille comme réveillée, **et pyatv n'en obtient pas
  davantage**. Chemin écarté (ADR 009). L'identifiant renvoyé (`pi`) diffère de celui de pyatv : journalisé, pas fatal.
- **`X-Apple-HKP`** : `3` en appairage système, `4` en transitoire. **Confirmé sur la vraie Apple TV** le 2026-11-02.
- **Maintien de session** : chez pyatv, RAOP sonde `POST /feedback` puis répète toutes les 25 s si 200 ;
  AirPlay 2 toutes les 2 s. Jamais fatal, comme dit plus haut.
- **Retransmission** : réponse `80 D6 | séquence d'origine (2) | paquet complet` sur le canal de contrôle,
  depuis `RTPPacketHistory`. L'historique se vide à la reconnexion.
- **Échelle de volume** : l'interface court de −60 à 0 dB, le protocole de −30 à 0, −144 pour le silence
  (`BridgeState.receiverVolume`). Master à −24 par défaut pour −12 sur le fil, niveau déjà écouté. Master au
  minimum = −144, quel que soit le trim.
- **Dédoublonner une enceinte par adresse, jamais par nom** : une même enceinte s'annonce sur les deux
  services, et les noms de suffixe (`Salon`, `Salon (2)`) ne concordent pas forcément d'un service à l'autre.
  **Seule une annonce confirmant le bit 48 peut supplanter ou absorber une ligne RAOP** : une annonce sans TXT
  effacerait la Geneva et ses réglages.
- **Nom exact pour l'app** (`ReceiverNameMatching.exact`) : « Salon » est un préfixe de « Salon (2) » et
  d'« Apple TV Salon ». La correspondance partielle est réservée au CLI.

## Moteur et temps réel — faits vérifiés au jalon 5

- **`for … in 0..<n` alloue à chaque tour en debug** : `while` sur le chemin temps réel. Une sonde
  `malloc_logger` le vérifie dans les tests.
- **Une fermeture consommatrice formée dans l'acteur en hérite l'isolation** : celle que reçoit le
  callback temps réel ne doit pas y être formée.
- **`totalFramesWritten` compte tout ce que la capture a produit, refus compris** : c'est ce qui rend la
  graduation commune à toutes les sorties quel que soit le remplissage de leur tampon (`timelineSkew`).
  L'ancien compteur s'arrêtait au premier débordement, soit à 48 000 trames, quelle que soit la négociation.
- **L'horloge commune démarre à la capture**, plus au premier sender (`BridgeEngine.start`). **Revenir à
  l'ancien calcul exige donc deux changements** : retirer `dropped` de `timelineSkew` ne suffit pas, il faut
  aussi ramener l'origine au premier sender, sinon un récepteur négocié après 5 s annonce un instant passé de
  4 s. Voir l'ADR `006`.
- **`shiftOrigin` reporte l'horloge après un vrai trou de capture, confirmé au relevé suivant** : une
  rafale tardive sans trou ne décale rien. Il vaut pour toutes les sorties à la fois.
- **`replaceCapture` change la source sans toucher aux sessions des sorties**, et rend la main sans attendre. Une
  reconstruction en échec lui cède la place et reprend s'il échoue : elle ne finira peut-être jamais.
- **Capture bloquée** : reconstruction à 5 s, repli jusqu'à 60 s, seulement si une application joue. L'échéance part du
  dernier bloc, **sauf après une pause**, où elle part de la reprise : sinon le tap est détruit quand le son démarre. Seul
  un flux établi 5 s remet le repli à zéro. Un PID mort n'entre pas dans la description du tap.
- **Un abandon avec une raison met la sortie en `failed`, sans relance** (`currentOutputError`). Seuls les
  refus de capacité ou d'authentification sont permanents (`isPermanentOutputFailure`). `ipv4Required` ne l'est
  pas : une réponse DNS peut être tardive.
- **Après 3 reconnexions ratées**, les senders relisent l'annonce du récepteur (`rediscoveryInterval`), par
  nom exact : une adresse peut avoir changé. **Jamais une IPv4 remplacée par une IPv6** : A et AAAA reviennent séparément
  quand un appareil redémarre (`BonjourAddressResolver.canReplace`).
- **`DNSServiceResolve` veut le nom brut, `DNSServiceQueryRecord` le nom échappé.** A et AAAA arrivent
  séparément : ne pas s'arrêter à la première réponse. **La découverte ne se connecte plus à aucun appareil.**
- **Options TCP : `transportProtocol`, jamais `internetProtocol`.** Le transtypage échoue sans bruit :
  `noDelay` n'avait jamais été appliqué.
- **`UDPChannel.onReceive` capture le canal en `weak`**, sinon le socket fuit à chaque session.
- **Pas de surcharge `async` d'un nom synchrone** : elle casse les appelants.
- **csrp exige `A` avant `B`** côté serveur, d'où `TransientSRPServer` dans les tests.

- **Une boucle d'événements imbriquée lancée sous un bloc de la file principale ne vide plus cette file.** `terminate:`
  appelé depuis une source dispatch de la file principale (le SIGTERM) attendait donc pour toujours une réponse
  `.terminateLater` qui devait passer par le MainActor : interblocage en diffusion, `kill -9` nécessaire. SIGTERM passe
  désormais par `RunLoop.main.perform(inModes: [.common])`, et un minuteur de secours répond à 6 s. **Ne jamais appeler
  `terminate` depuis un `Task` ni un `DispatchQueue.main.async`.** Un second `terminate` pendant l'attente fait quitter
  AppKit sur-le-champ, sans `TEARDOWN` : il est ignoré.

- **Tester sans immobiliser le MainActor** : jamais de `RunLoop.main.run` dans un test `@MainActor`, qui bloque les tâches MainActor des
  autres suites lancées en parallèle (échecs par délai dépassé ailleurs, suite complète seulement). Attendre par `Task.sleep` ou `eventually`.
- **Changer l'image d'un `NSStatusItem` coûte cher** : chaque changement redessine un instantané par bureau (`_updateReplicants`), 6 % d'un
  cœur à 8 images/s. L'icône animée passe par un calque Core Animation posé sur le bouton (0,001 %), avec repli sur un minuteur.
- **Le silence local du tap (`.mutedWhenTapped`) coupe vraiment les haut-parleurs du Mac** : vérifié au micro le 2026-11-02.
- **Touches volume du Mac → master : seulement le temps d'une diffusion** (`SystemVolumeLink`). Baptiste garde son Mac à 0 % et coupé : un
  lien permanent aurait rendu les enceintes muettes au lancement et fait jouer le Mac. Volume et silence du Mac mémorisés dans
  `settings.json` **avant** toute écriture, rendus à l'arrêt ou au lancement suivant un plantage. Volume principal virtuel
  (`kAudioHardwareServiceDeviceProperty_VirtualMainVolume`), sans autorisation, sans intercepter les touches.

## Écoute et délais

- **Deux lieux d'écoute sélectionnables** : « À table » par défaut, dos à la fenêtre et face à la télé, et « Au
  canapé », place gauche sur le plan (`RoomLayout.activeListenerID`, écrit avec le plan). Un seul commande les
  distances et les délais.
- **Délai envoyé au moteur = `delayMS` (réglage manuel) + compensation du lieu en vigueur**
  (`BridgeState.effectiveDelayMS`). Il part sans rupture de flux, et un changement de lieu le pousse en pleine
  diffusion.
- **La compensation se calcule sur les sorties rattachées dans le plan**, jamais sur les sorties découvertes ni
  cochées : cocher une enceinte ou voir la Geneva s'allumer ne doit pas bouger le calage des autres. Une sortie
  absente du plan a 0 de compensation. Le premier rattachement de la Geneva provoque un seul recalage.
- Valeurs du plan, sous le seuil de perception : à table 0 à 2,2 ms, au canapé 0 à 5,7 ms.

## Mesure acoustique et essais sur le matériel — outils et pièges (2026-11-02)

- **Mesurer le calage au micro** : `./audiocap --clicks --airplay "Erki’s geneva" --airplay2 Salon --airplay2 "Salon (2)"
  --record-input <f.wav> 90`, puis `scripts/measure-clicks.py <f.wav>`. Salves de 5 ms à 3 kHz toutes les 2 s, datées
  sur l'horloge hôte (JSON à côté du WAV). Mesurer **une enceinte à la fois d'abord** : le script ne sait pas quel
  groupe est quelle enceinte. Le premier groupe est le son direct, les suivants des réflexions.
- **Valeurs mesurées à table** (son direct, écart à l'instant attendu, constante commune comprise) : Geneva +298 ms
  (sans la compensation de 0cf8a31 ; +206 avec), Salon +290 ms, Salon (2) de +267 à ~+307 ms en ~40 s de convergence.
  Écart entre enceintes ≤ 17 ms, mesuré enceinte par enceinte. Aucun écho entendu à trois. **Depuis la compensation de
  `4be98a9`, +40 à +47 ms**, écart 6,4 ms (2026-11-09, encore à 2 s de délai) : voir « Retard de bout en bout et vidéo ».
- **Repère du script** : une salve sur cinq est doublée **250 ms** plus tard. Une enceinte en retard d'environ 250 ms
  se confond avec ces doublures : replier l'enregistrement modulo 2 s pour lever le doute.
- **Pièce calme indispensable** : une vidéo, une télé, une conversation noient les salves dans la bande des 3 kHz.
  Durée ≥ 60 s : la connexion des HomePod coûte souvent 10 s au premier essai.
- **Test gauche/droite** : `--channel-test` (bip grave = gauche, deux aigus = droite), ou une voix « gauche »/« droite »
  sur un seul canal (`say` + WAV stéréo), jouée par `afplay` pendant `./audiocap --mute-local --airplay2 …`. La voix est
  la seule forme sans ambiguïté pour Baptiste.
- **`log` est une commande interne de zsh** : appeler `/usr/bin/log show …`, sinon « too many arguments ».
- **Fausse alerte « SILENCE STRICT … autorisation perdue ? »** quand rien ne joue : des processus `python` gardent un
  flux de sortie ouvert et muet, et sont réputés « jouer » (`./audiocap --list`). Les démons et outils hors des dossiers
  d'applications n'en déclenchent plus depuis le 2026-11-09 (`AudioProcessClassifier`).
- **Pendant une session vers les HomePod, l'Apple TV perd sa sortie Home cinéma**, et la reprend ~1 s après la fin.

## Retard de bout en bout et vidéo

Relevés du 2026-11-03, implémentés et mesurés les 2026-11-09 et 10 : ADR `014` et `015`, détail dans `docs/retard_2s_notes.md`.

- **Une seule constante : `SharedPlaybackClock.defaultPlayoutDelaySeconds` = 0,4 s** (2 s jusqu'au 2026-11-10). Latence visée et
  annoncée des deux senders (`SyncLatency`), ancrage et `VideoSyncLatency` (0,445 s) en découlent. Plus aucun `88_200` dans les
  senders. `latencyMin`/`latencyMax` du `SETUP` AirPlay 2 restent en dur (11 025 et 88 200).
- **Les récepteurs ajoutent 11 025 trames (0,25 s) à la latence annoncée, Geneva comme HomePod** : décrit par OwnTone et libraop,
  vu dans Airfoil (1,75 s annoncées pour 2,0 s appliquées), **mesuré** au micro le 2026-11-09 (+290 → +40 à +47 ms). D'où
  `ReceiverAddedLatency.default` = 11 025 pour les deux familles. Le paquet de synchro annonce la latence visée − 11 025, et
  **l'instant NTP reste calculé sur la latence visée entière** : le calculer sur l'annoncée annulerait le gain. Compenser une
  seule famille mettrait Geneva et HomePod à 0,25 s l'une de l'autre. Ainsi compensée, la Geneva démarre 8 à 20 ms en avance et
  se cale en ~45 s, cause inconnue.
- **Paliers du délai entendus le 2026-11-10** : 0,5 et 0,4 s tiennent, 0,3 s décroche, 0,25 s « bugue de fou ». Rien n'est mesuré
  à 0,4 s (ni endurance, ni capture, ni clics). Au premier craquement, remonter à 0,5 s.
- **Pourquoi l'image est en avance** : les applications jouent sur les haut-parleurs du Mac, qui annoncent 17 ms (`device` 60 +
  `safety` 48 + `stream` 690 trames à 48 kHz). Elles ignorent le retard de la diffusion.
- **Un agrégat ne sait pas annoncer de latence aux applications.** `kAudioSubDeviceExtraOutputLatencyKey` à 2,3 s (sonde sur fichier
  silencieux, agrégat privé et public) : la valeur va dans le `safety offset`, `kAudioDevicePropertyLatency` reste à 60, l'horodatage
  de sortie reste à 12 ms (IOProc et AUHAL), AVPlayer ne bouge pas (horloge partie à ~0,1 s, périphérique bien en marche). L'agrégat
  n'expose pas non plus de volume virtuel : les touches du Mac ne le piloteraient pas. Firefox lit `dev + stream` (`cubeb_audiounit`),
  donc pas le `safety offset`. D'où la sortie virtuelle.
- **La sortie virtuelle `Drivers/APBOutput`** (AudioServerPlugIn en C) jette le son et annonce dans `kAudioDevicePropertyLatency`
  ce que l'app écrit dans la propriété `'apbL'` (`CFNumber`, trames, 0 à 480 000), gardée par le stockage de l'hôte : le
  plug-in, dans le bac à sable de `coreaudiod`, ne lit aucun fichier. Pendant une diffusion par tap, l'app en fait la sortie par
  défaut (`VideoSyncSwitch`), sortie d'origine mémorisée dans `settings.json` **avant**, rendue à l'arrêt ou au lancement suivant.
  **Mesuré** : Chrome 157 journalise « Large rendering delay (2.34 s) » et retarde son horloge de 2,28 s, sans image perdue ;
  AVPlayer 2,41 s. **Vu** par Baptiste dans Dia, sur les trois enceintes. Installation : `Drivers/APBOutput/build.sh`, puis
  `sudo scripts/install-driver.sh` par Baptiste. État : `swift run audiocap --video-sync`.
- **L'agrégat du tap a pour horloge la sortie des effets sonores** (`kAudioHardwarePropertyDefaultSystemOutputDevice`,
  `ProcessTapCapture.currentClockDeviceUID`), pas la sortie par défaut : le pilote n'entre jamais dans l'agrégat, et le tap ne
  prend aucun retard (clic capté en 47 à 65 ms, pilote en sortie par défaut ou non).
- **Avant de toucher à la sortie par défaut, vérifier que rien ne joue** (`./audiocap --list`) : le son de Baptiste partirait
  dans le pilote, qui le jette. C'est arrivé le 2026-11-09.
- **Mesurer Chromium sans rien afficher** : Chrome 157 en `--headless=new`, profil temporaire, domaine CDP `Media`
  (`scripts/video-sync/`). **Jamais une seconde instance de Dia** : même avec un profil temporaire, elle a ouvert chez Baptiste
  l'écran de connexion.
- **Dia (1.56, Chromium 157) retarde l'image de la latence annoncée par la sortie, safety offset exclu** (code Chromium lu le
  2026-11-09 : `media/audio/mac/core_audio_util_mac.cc`, `media/audio/apple/audio_auhal.cc`). Somme `kAudioUnitProperty_Latency` +
  `kAudioDevicePropertyLatency` + `kAudioStreamPropertyLatency` du premier flux, **lue à l'ouverture du flux** (`AUHALStream::Open`),
  bornée à 10 s. Au-delà d'1 s, Chromium journalise « Large rendering delay » sans plafonner. Le chemin AVFoundation
  (`kMacAVFoundationPlayback`, macOS 27, désactivé par défaut) passe un délai **nul** : s'il devient le défaut, la sortie virtuelle
  ne servira plus à Dia. Lire Chromium : `chromium.googlesource.com/…/<fichier>?format=TEXT`, décodé en base64.
- **Retransmissions sur le vrai Wi-Fi** (`captures/p5-endurance-1h.pcapng`, 1 h, sinusoïde) : 0,54 % des paquets redemandés, un par
  demande, réponse servie en moins de 8 ms. Délai entre la 1re émission et la demande :

  | | médiane | p99 | max | > 0,5 s | > 0,75 s | > 1 s |
  |---|---|---|---|---|---|---|
  | HomePod « Salon » (2 510 demandes) | 95 ms | 938 ms | 1 058 ms | 303 | 120 | 9 |
  | HomePod « Salon (2) » (2 554) | 96 ms | 972 ms | 1 081 ms | 384 | 171 | 21 |
  | Geneva, 202 442 paquets (1 060) | 24 ms | 168 ms | 295 ms | 0 | 0 | 0 |

  **Rythme relevé avec un tampon de 2 s** : rien ne dit qu'un HomePod garderait les mêmes délais avec un tampon plus court.
- **Apple TV → Mac → enceintes** (entendu le 2026-11-10) : récepteur AirPlay du Mac allumé (Réglages > Général > AirDrop et
  Continuité), l'Apple TV propose le Mac comme sortie et **le tap global capte ce son**, Geneva comprise. Écho si l'Apple TV sort
  aussi sur les HomePod : ne cocher que le Mac. Ce récepteur occupe le port 5000 : **les mocks ne démarrent plus** tant qu'il est
  allumé. L'iPhone passerait par le même chemin, pas essayé.

## Plan et capture de Baptiste

- `RoomLayout.salon` (`Model/SalonPlan.swift`) reproduit sa capture. Échelle de la capture : **178 px/m,
  origine (166, 150)**, cotes imprimées cohérentes. Les croix jaunes et le point vert désignaient les enceintes :
  ce n'étaient pas des objets à dessiner.
- **Hypothèses à confirmer** : gauche = `airplay2/Salon`, hauteurs estimées, place exacte des lieux d'écoute.
  Présets gardés malgré l'écart avec la capture : canapé (retour de 91 cm, cote relevée, contre ~79 dessinés).
- Plan réel : `~/Library/Application Support/AirplayPersonalBridge/room-layout.json`. Le régénérer app fermée, car elle
  sauvegarde en quittant : `SALON_JSON_OUT=<fichier> swift test --filter PlanExport`. Rendu :
  `PLAN_PNG_OUT=<fichier> swift test --filter PlanExport`. Un JSON illisible est préservé à côté.
- **`WallSegment.thickness` part à gauche du sens de tracé** : contour horaire = extérieur. **Tout nouveau champ de
  `WallSegment` doit passer par le décodage manuel**, sinon tous les murs disparaissent à la lecture.
- **Hors fenêtre, `ImageRenderer` exige `performAsCurrentDrawingAppearance`** pour les couleurs dynamiques.

## Widget et app

- **Barre de menus, pas WidgetKit** : la capture doit tourner dans un processus vivant. Voir l'ADR `005`.
- **Fenêtre à trois vues** (2026-11-10, `WindowLayout` : `halo` par défaut, `console`, `plan`), sans barre d'outils ni barre
  latérale (scène en `hiddenTitleBar`) : tout flotte en verre sur le fond, source en pastille (`SourcePill`) en haut au centre,
  options (`WindowOptionsButton`) en haut à droite, marges dans `WindowChromeMetrics`. Rendus :
  `WINDOW_PNG_DIR=<dossier> swift test --filter HaloViewExport` (ou `ConsoleViewExport`, `MainWindowExport`), verres remplacés
  par un aplat (`windowSimulatesGlass`, `WindowSnapshot`). **Pas de rose sur une commande** : curseurs, anneau, boutons
  enclenchés en blanc ; le rose va à la sphère, à la pastille d'état et au fond.
- **Le fond se dessine à un seul endroit**, `Views/GrainientBackground.swift` (style *shadeshifter-05* de Grainient dans la
  palette de l'app : rampe en bandes obliques, nappe bleue en bas à droite, assombrie à 0,39 en diffusion et 0,085 au repos,
  grain fixe de 256 px). **Animé par Core Animation, pas par SwiftUI** : 120 images-clés de 160×100 calculées une fois par
  proportions de fenêtre, hors du MainActor, enchaînées par une `CAKeyframeAnimation` sur `contents` (cycle de 36 s). L'app ne
  se réveille pas pendant le mouvement. Une image fixe de la même recette vit sous le calque : c'est elle que montrent le
  repos, « Réduire les animations » et les rendus hors écran.
- **Un mouvement réglé sans le voir est trop faible** : le premier réglage (54 s, ondulation de 3,5 % de la largeur, ~10 pt/s)
  tournait bien, mais Baptiste voyait « une texture fixe ». Réglage vu depuis : ondulation de 9 %, pente des bandes qui varie,
  nappe qui dérive et respire, ~48 pt/s au plus, 14 pt au plus entre deux images-clés à 1200 pt de large. Sonde dans une vraie
  fenêtre : `swift run BackgroundMotionProbe [court]`. **Elle affiche une petite fenêtre et prend le premier plan** : pas
  quand Baptiste travaille. `swift test` ne peut pas devenir l'app active, le fond y reste en pause. Coût du process mesuré
  par `BACKGROUND_CPU_PROBE=30 swift test -c release --filter GrainientBackgroundCPUProbe` sur l'ancien réglage : égal à
  une fenêtre vide, contre 109 % pour le `Canvas` d'avant ; le serveur de fenêtres n'est pas mesuré.
- **Pas de shader SwiftUI** : `swift build` copie un `.metal` sans le compiler, et le Metal Toolchain n'est pas installé
  (`xcrun metal` échoue). `MTLDevice.makeLibrary(source:)` compilerait du MSL à l'exécution, si un jour il en faut un.
- **Aucune image de Grainient dans le dépôt** : sa licence (`grainient.supply/license-agreement`, 2024-08-20) permet l'usage
  personnel mais interdit de redistribuer les fichiers, et le dépôt est sur GitHub. Les trois références (*shadeshifter-05*,
  *Nova*, *Darkshells*) sont reproduites par le code. Aucune n'a de grain visible : celui de l'app est un ajout.
- **Centre du Halo : verre noir, triangle, logo vivant** (`Views/HaloSphere.swift`, maquette 17 retenue par Baptiste le
  2026-11-11 ; la bille Nova rayée et `NovaGlass.swift` sont retirés, l'anneau du volume n'en dépendait pas). Au repos, un
  disque « Darkshells » et un triangle lecture ; en diffusion, le logo du pont dont les cinq barres ondulent
  (`HaloLogoMotion`, `BridgeGlyph.Bars` : courses disjointes, le profil du pont tient à tout instant) et trois lueurs floues qui
  dérivent (`HaloGlass.lights`) ; son coupé, logo immobile et lueurs voilées, figées. **Tout est en dégradés vectoriels, rien
  n'est cuit** : le verre immobile est dans deux `Canvas` qui ne se redessinent pas (`HaloGlassPlate`, `Equatable`), seuls les
  lueurs et le logo suivent l'horloge, à 20 images/s, arrêtés fenêtre inactive ou sous « Réduire les animations ». Le disque ne
  grossit plus : c'est la lueur autour qui respire. Contraste du logo blanc ≥ 4,5:1 à tout instant (test, 9:1 au pire).
  Planches : `SPHERE_PNG_DIR=<dossier> swift test --filter HaloSphereExport`. **Leçon gardée de la bille Nova** : une texture
  calculée point par point se cuit hors du fil principal, jamais au premier dessin (elle figeait la fenêtre 1 s en debug et
  faisait dépasser leurs plafonds aux tests de la fermeture).
- **`==` sur deux `CGPath` ne suffit pas à dire deux tracés identiques** : `BridgeGlyph.marks(.idle)`, assemblé par `addPath`,
  et le même tracé construit barre par barre diffèrent au dernier bit de quelques flottants (cause non établie). Comparer
  élément par élément, avec une tolérance (`HaloSphereTests.match`).
- **Commandes de la Console en matière Darkshells** (`Views/Darkshell.swift`, variante 15 choisie par Baptiste) : piste presque
  noire à liseré, niveau en voile gris sous un trait blanc. Le volume général garde une **prise ronde**. `PanelVolumeSlider` et
  `PanelMuteButton` prennent un `look: ControlLook` (`.panel` par défaut) : le panneau et la vue Plan ne changent pas.
- **Vue Halo** : les ondes (`HaloWaveField`) sont un voile flou calculé par pixel dans une image de 160 px, plafonné à 28 %
  d'alpha, à 20 images/s. Une marge posée **autour** d'une vue rogne son fond : celle du haut est passée à `HaloView`
  (`topInset`), sinon les ondes s'arrêtaient net à 48 pt du bord et dessinaient une fausse barre. Le silence général est un
  bouton rond au bout de la rangée d'enceintes (`HaloMuteButton`), jamais masquable. Plus de mention « N enceintes masquées »
  dans les vues Halo et Console ; elle reste au pied du panneau de la vue Plan.
- **Boutons de fenêtre** (`Views/WindowControls.swift`) : une capsule de verre fermer / réduire / agrandir remplace les trois
  boutons système de la fenêtre principale, masqués par `SystemWindowButtons.hide` à chaque rattachement, retour au premier
  plan, entrée et sortie de plein écran, retour du Dock. `performClose` aboutit avec le bouton système masqué ;
  **`performMiniaturize` non** (il simule un clic sur le bouton) : `miniaturize`. Agrandir = plein écran, ⌥ = `zoom`.
- **Fenêtre réductible jusqu'à 440×400** (`Views/WindowSizing.swift`, paliers en fonctions pures) : pastilles du Halo sur une
  rangée défilante puis compactes, tuiles de la Console défilantes, lieu d'écoute replié en bouton, panneau des enceintes du
  Plan replié en barre et rouvert en surimpression. Rendus à toutes les tailles :
  `WINDOW_PNG_DIR=<dossier> swift test --filter SmallWindowExport`.
- **Masquer est visuel** (`HiddenElements`, `BridgeState+Visibility`) : une enceinte masquée et cochée continue de jouer, et
  disparaît des trois vues et du panneau. Le geste vaut pour toute la paire stéréo. Trois blocs masquables (`WindowBlock`) :
  ondes du Halo, volume général, lieu d'écoute de la Console ; jamais l'état, les avertissements, la source, Diffuser ni le
  silence. Persisté dans `settings.json` (`hiddenElements`), identifiants orphelins gardés. Les vues lisent `visibleOutputs`,
  jamais `outputs`, pour leurs listes.
- **Fenêtre Réglages** (scène `Settings`, ⌘,) : la scène est dans `AirplayPersonalBridgeApp.swift`, la vue dans
  `Views/SettingsView.swift`. Ouverte depuis le panneau, elle passe par `AppLifecycle.showSettingsWindow` : icône du Dock et
  activation **avant** l'ouverture, sinon elle s'ouvre derrière. L'icône du Dock dure tant que l'une des deux fenêtres est
  ouverte (`DockIconController.Window`). **Jamais ouverte pour de vrai par un agent** : à essayer d'abord depuis le panneau,
  fenêtre principale fermée.
- **Panneau des enceintes de la vue Plan, en cartes** (`BridgeSidebar`, flottant à gauche) : une carte d'en-tête puis une `SpeakerCard` par enceinte, sur un voile
  (`windowCard`), jamais un second verre. Ce qui se règle une fois est en fenêtre surgissante : `SpeakerSettings` (délai, tonalité,
  gain, adresse) et `MacOptions`. Un rendu hors écran n'ouvre pas de popover : l'export les rend seuls
  (`reglages-enceinte-*`, `options-mac-*`). `OutputRow` n'existe plus.
- **Plan** : sol rempli à l'intérieur des murs (`PlanRenderer.floorOutlines` : boucle fermée, ou suite ouverte par une porte et
  refermée d'un trait ; aucun sol sur un embranchement ni sous une image de fond), un point par mètre au lieu de lignes, et
  `SpeakerPulse`, l'onde des enceintes qu'on entend, dans son propre `Canvas` pour ne pas redessiner le plan 30 fois par seconde.
- **Options du panneau : une carte dessinée dans la fenêtre du panneau** (`PanelPopup`), pas un `.popover`. Rien ne garantit
  qu'un popover présenté depuis un `MenuBarExtra` ne ferme pas le panneau, et la sonde n'a pas pu trancher (écran verrouillé).
  Le panneau garde sa taille, options ouvertes ou non (`PanelPopupTests`). Sonde à rejouer écran déverrouillé :
  `scratchpad/options-popup/probe/probe.swift` (non versionnée).
- **Diffuser se déclenche par ⌘↩, jamais par `.defaultAction`** : Retour valide un champ de l'inspecteur, et cette validation ne
  doit pas faire partir le son.
- **Écran verrouillé, ni capture ni fenêtre** : `screencapture` échoue (« could not create image from display »), et une app
  lancée par un agent n'ouvre aucune fenêtre visible ni ne devient active (sonde du 2026-11-10 : `screenLocked=1`). Le verre se
  juge par Baptiste, dans l'app.
- **Paire stéréo** : un geste vaut pour les deux membres (`StereoPairs`), et la paire entre en session d'un seul coup. Un membre
  qui apparaît rejoint sa paire si elle est cochée ; jamais l'inverse (`joinCheckedPairs`).
- **`ImageRenderer` barre les contrôles AppKit** : le panneau se rend dans une fenêtre hors écran,
  `MENUBAR_PNG_DIR=<dossier> swift test --filter MenuBarPanelExport`. **`glassEffect` ne dessine rien avec
  `cacheDisplay`** : `panelSimulatesGlass` le remplace dans ces rendus, et le verre ne se juge que dans l'app réelle.
- **Un nom de SF Symbol inconnu n'affiche rien, sans erreur.** `hifispeaker.slash` n'existe pas.
- **macOS 27 compose l'icône d'app sans plaque grise** : le vérifier avec `NSWorkspace.icon(forFile:)`. Générée par
  `scripts/make-app-icon.swift`, dont l'en-tête donne la commande : `swiftc -parse-as-library`, deux fichiers, la
  géométrie du glyphe vivant dans `Views/BridgeGlyph.swift`.
- **App Nap** peut frapper une app sans fenêtre : une activité est retenue pendant la diffusion.
- Seule la première découverte coche d'office. Une sortie disparue reste affichée hors ligne si elle est cochée : une
  sortie de test restée cochée s'y retrouve, à décocher ou à retirer de `settings.json`, app fermée.
- **Une application choisie qui ne joue pas reste attendue** : le sélecteur montre le global, une ligne dit qu'elle reprendra la
  main, et `Annuler` y renonce (`awaitedSourceName`). Ne pas compter sur le setter du `Picker` pour cela : rien ne garantit
  qu'il réagisse à l'option déjà sélectionnée, ni qu'il se comporte de même dans le `Menu` du panneau.
- La source ou le son du Mac changés en diffusion relancent la capture. La dernière enceinte décochée arrête la
  diffusion après 4 s de grâce.

## Signature et installation

```bash
scripts/setup-signing.sh       # une fois, idempotent
scripts/install-app.sh --open  # compile en Release, signe, remplace l'app dans /Applications, lance
```

- **L'exigence désignée ne dépend plus du CDHash** (`identifier "…" and certificate leaf = H"…"`) : recompiler
  conserve l'autorisation « sons du système » **et le micro** : confirmé le 2026-11-02 sur `make-cli-bundle.sh`. Un certificat auto-signé
  suffit, TCC compare une empreinte. Il n'est pas approuvé, donc `find-identity -v` ne l'affiche pas : c'est normal.
- **Tout passe par `scripts/setup-signing.sh --codesign`.** Sur un trousseau verrouillé, `codesign` et
  `security show-keychain-info` ouvrent chez Baptiste une fenêtre de mot de passe qu'il ne peut pas remplir : c'est
  arrivé au moins 4 fois pendant la mise au point. Ne jamais les appeler autrement. Un trousseau qui refuse son mot
  de passe après une annulation est recréé automatiquement, cause inconnue.
- `credentials/signing/` vit dans le dépôt principal, ignoré par git : perdre `signing.key` oblige à redonner les
  autorisations. `make-cli-bundle.sh` emploie la même identité.
- **Xcode signe en ad-hoc** : le bundle Debug porte son propre identifiant (`….AirplayPersonalBridge.debug`), pour ne pas
  écraser l'autorisation de l'app installée.
- **L'app installée quitte sur SIGTERM** (`TerminationSignal.swift`), l'AppleEvent `quit` exigeant un consentement
  Automation (-1744). Arrêt propre borné à 5 s (`QuitSequence`) : `TEARDOWN` et capture, puis sortie, volume et silence du Mac
  rendus, puis `sudo -n killall coreaudiod` (règle `/etc/sudoers.d/airplay-bridge` posée par `install-driver.sh`), 1 s au plus.
  **Chaque réinstallation coupe donc le son du Mac une à deux secondes.** Sans la règle : une ligne OSLog, et l'app quitte.
- **OpenSSL est lié en statique** (`libcrypto.a`) : plus de référence à `/opt/homebrew` à l'exécution, mais toujours requis à
  la compilation. Le lien exige de renommer `poly1305_init` dans `CChachaPoly`, seul symbole en conflit.

## Tests et outillage

- Toute la logique de l'app passe par `swift test`, avec `@testable import BridgeApp`.
- **Tests contre mocks**, jamais lancés par défaut : `AUDIOCORE_MOCK_TESTS=1 swift test --filter BridgeEngineMockTests`,
  `RUN_MOCK_TESTS=1 RAOP_MOCK_INSTANCE=<nom> swift test --filter RAOPMockIntegration`,
  `RUN_MOCK_TESTS=1 swift test --filter AirPlay2MockIntegrationTests`.
- **Bout en bout sans autorisation** : `swift run audiocap --tone --airplay Geneva-Mock --volume -30 10`. Niveau par défaut
  −50 dBFS : shairport joue sur les haut-parleurs du Mac.
- `./audiocap` relaie sortie, code de retour et Ctrl-C malgré `open` (`open --env/--stdout/--stderr` existent). Codes : 0
  succès, 1 erreur, 2 silence ou mauvais usage, 3 autorisation refusée, 130 Ctrl-C, 70 mort sans code.
- `git apply --unidiff-zero` place les ajouts selon la position d'arrivée : à vérifier après application.
- **En test, jamais d'écoute `.any` ni de `waitUntilExit`** (`TestListenerPortTests` y veille pour `.any`). Toute écoute passe
  par `startLoopbackListener`, hors plage éphémère, avec repli sur le port suivant. Une `NWConnection` vers un port qui a servi
  de source à une connexion reçue par un `NWListener` du même process est refusée 30 s (`EADDRINUSE`), `restart()` inutile ;
  et `NWListener` refuse parfois un port libre. Réessayer ou allonger une attente ne soigne rien. L'app n'a aucune écoute, elle
  n'y est pas exposée. Un `waitUntilExit` a figé un passage 14 min : attendre la fin de fichier du tube.
- **Aucun plafond de temps serré sur ce qui reprend sur le MainActor** : toutes les suites de `BridgeAppTests` le partagent, et au
  départ d'une suite complète une reprise y attend jusqu'à ~2 s. Trois tests de la fermeture échouaient ainsi 3 fois sur 3, verts
  isolément. Plafond de quelques secondes (`QuitSequenceTests.mainActorSlack`), et le comportement fautif rendu bien plus lent
  (part de 10 s, fils qui dort 10 s) pour qu'une mutation se voie encore. **Ces plafonds cèdent encore quand le Mac est chargé**
  (2026-11-10, Dia à 87 % d'un cœur, charge 7 : 2 passages sur 5 en échec, sur le commit de départ comme après) : relancer au
  calme avant d'accuser le code, et comparer au commit précédent dans un worktree.
- **Un socket lié qui n'écoute pas ne simule pas un port fermé** : le noyau ignore le SYN au lieu de le refuser, et la connexion
  reste en préparation sans fin.
- **Les annonces Bonjour des tests restent sur l'interface locale, sous un type privé** (`_apbtest._tcp`) : la suite ne fait
  pas apparaître d'enceinte chez une app lancée à côté.

## Travailler avec des sous-agents

- **Un worktree d'agent peut partir d'une base périmée** (`origin/main`, ou plusieurs commits derrière `main`) : vérifier
  `git log -1` au début et repartir de `main` par `git merge main`.
- **Le scratchpad est partagé entre agents** : un dossier par agent, jamais de nom générique (`commit1.txt`, `mutate.py` ont
  été écrasés).
- **Arrêter un processus par son PID, jamais par son nom** : un `pkill` a pu tuer le mock d'un autre agent.
- **Le vrai matériel est une ressource unique.** Une seule session le fait jouer à la fois, et tout essai contre un mock
  vise celui-ci par adresse ou par nom exact.
- Ne pas lire `credentials/` : clés privées. Passer les chemins.
- **`/usr/bin/git` pour un relevé brut** : le hook RTK réécrit `git` et filtre sa sortie (`log`, `diff`, `status`).
