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
  - l'historique contient des commits `auto: …` intermédiaires, **qui ne sont pas des
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

## Sortie réelle — faits vérifiés sur le matériel (2026-08-11 et 12)

Ce qui suit vient des commits 824f16d à 0cf8a31. Détail dans `PROGRESS.md`. **Ce qui a été ajouté
depuis n'a jamais été entendu** : la liste est dans la section du jalon 5 de `PROGRESS.md`.

- **Geneva AeroSphere Large** : TXT `et=0,4`, `cn=0`, `features=0x444c0a00` sans aucun bit de pairing,
  donc récepteur AirPlay 1 même si elle s'annonce aussi en `_airplay._tcp`. Reçoit du PCM `L16`
  big-endian sans chiffrement. Répond `Audio-Latency: 4096`, soit 92,88 ms, retranchés de l'ancrage
  (0cf8a31). **Son nom réseau n'a jamais été noté** : le plan la rattache par alias (`Geneva`,
  `AeroSphere`).
- **HomePod gen 2**, « Salon » et « Salon (2) » : acceptent le transitoire sans `/pair-pin-start`.
  **Ils forment une paire stéréo** (fait donné par Baptiste, 2026-11-01). **On ne sait pas ce que joue
  un membre adressé seul**, ni si une seule session fait jouer les deux : à trancher en phase 3 de
  `docs/prompt_tests_materiel.md`.
- **Le HomePod ne répond au `SETUP` qu'après avoir mesuré notre horloge** : le répondeur de timing doit
  écouter **avant** le `SETUP`. Il refuse le `SETUP` en 400 sur l'IPv6 de lien local : IPv4 d'abord.
- **Charge utile AirPlay 2 en PCM big-endian.** Données associées de l'AEAD = octets 4 à 12 de l'en-tête
  RTP. Nonce de 8 octets ajouté après l'étiquette Poly1305. Un bruit blanc est une bonne nouvelle : un
  paquet mal chiffré serait rejeté et donnerait du silence.
- **Apple TV** : refuse le transitoire en 470 même en annonçant le bit 48. L'app la signale donc
  « appairage requis » d'après le TXT `model` (`AppleTV…`). `pair-verify` n'a jamais abouti. Credentials au
  format pyatv (`ltpk:ltsk:atv_id:client_id`), sous `credentials/`, à passer par chemin absolu
  (`--credentials2`), jamais à afficher. L'identifiant renvoyé (`pi` Bonjour) diffère de celui enregistré
  par pyatv : écart journalisé, pas fatal.
- **`X-Apple-HKP`** : `3` en appairage système, `4` en transitoire. L'accessoire simulé de pyatv refuse en
  501 un `pair-verify` qui n'annonce pas `3`. Correction confirmée contre un accessoire simulé seulement.
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
- **`replaceCapture` change la source sans toucher aux sessions des sorties**, et rend la main sans attendre.
- **Capture bloquée** : reconstruction à 5 s, repli jusqu'à 60 s, seulement si une application joue.
- **Un abandon avec une raison met la sortie en `failed`, sans relance** (`currentOutputError`). Seuls les
  refus de capacité ou d'authentification sont permanents (`isPermanentOutputFailure`). `ipv4Required` ne l'est
  pas : une réponse DNS peut être tardive.
- **Après 3 reconnexions ratées**, les senders relisent l'annonce du récepteur (`rediscoveryInterval`), par
  nom exact : une adresse peut avoir changé.
- **`DNSServiceResolve` veut le nom brut, `DNSServiceQueryRecord` le nom échappé.** A et AAAA arrivent
  séparément : ne pas s'arrêter à la première réponse. **La découverte ne se connecte plus à aucun appareil.**
- **Options TCP : `transportProtocol`, jamais `internetProtocol`.** Le transtypage échoue sans bruit :
  `noDelay` n'avait jamais été appliqué.
- **`UDPChannel.onReceive` capture le canal en `weak`**, sinon le socket fuit à chaque session.
- **Pas de surcharge `async` d'un nom synchrone** : elle casse les appelants.
- **csrp exige `A` avant `B`** côté serveur, d'où `TransientSRPServer` dans les tests.

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
- La source ou le son du Mac changés en diffusion relancent la capture. La dernière enceinte décochée arrête la
  diffusion après 4 s de grâce.

## Signature et installation

```bash
scripts/setup-signing.sh       # une fois, idempotent
scripts/install-app.sh --open  # compile en Release, signe, remplace l'app dans /Applications, lance
```

- **L'exigence désignée ne dépend plus du CDHash** (`identifier "…" and certificate leaf = H"…"`) : recompiler
  conserve l'autorisation « sons du système », à confirmer sur le premier rebuild réel. Un certificat auto-signé
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
  Automation (-1744). Arrêt propre borné à 5 s, avec `TEARDOWN`.
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
