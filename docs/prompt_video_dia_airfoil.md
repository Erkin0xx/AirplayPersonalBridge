# Retard vidéo dans Dia, analyse d'Airfoil, clôture du jalon 5

Tu orchestres une session sur AirplayPersonalBridge, avec trois objectifs dans cet ordre :

1. **Priorité** : supprimer le décalage d'environ 2 s entre l'image et le son des vidéos lues dans
   **Dia**, le navigateur de Baptiste, pendant une diffusion.
2. En parallèle, un sous-agent étudie **Airfoil** avec l'outil **rea** pour savoir comment il réalise
   certaines fonctions, en particulier la paire stéréo de HomePod.
3. Terminer ce qui reste ouvert du jalon 5, puis le **clore**.

Avant toute chose : lis `CLAUDE.md`, en particulier la section « Retard de bout en bout et vidéo », et
`PROGRESS.md`, en particulier « Ce qui reste ouvert » et les deux sections « Après la clôture » du jalon 5.
Lis ensuite `git log -n 30`. Le mode de collaboration de `CLAUDE.md` s'applique : autonomie totale, pas de
question oui/non. Ne sollicite Baptiste que pour une action physique, un mot de passe à taper, une écoute ou
un regard. Dis-lui alors exactement quoi faire, et une seule chose à répondre.

**La synchronisation entre enceintes marche, et Baptiste ne veut pas la casser.** Rien de ce qui part sur le
fil ne doit changer : ni `latencyFrames` (88 200), ni `playoutDelaySeconds` (2 s), ni l'ancrage, ni les
senders. Le correctif vidéo agit sur ce que les applications du Mac croient, pas sur le flux. Une mesure de
non-régression le prouve à la fin de la phase 1.

## Ce qui est déjà établi : ne le refais pas

- **Le retard total vaut environ 2,3 s.** 2 s viennent du tampon choisi par le projet, la valeur même du Mac
  en AirPlay natif. Environ 0,25 s viennent probablement d'une constante ajoutée par les récepteurs.
  Mesuré au micro : +290 à +307 ms au-delà des 2 s.
- **L'image part trop tôt** parce que les applications jouent sur les haut-parleurs du Mac, qui annoncent
  17 ms. Quand macOS diffuse lui-même en AirPlay, il annonce la latence, et les lecteurs retardent l'image.
- **Dia 1.56 embarque Chromium 157.** D'après le code de Chromium, lu le 2026-11-09, il retarde l'image de
  la latence annoncée par la sortie audio. Il additionne `kAudioUnitProperty_Latency`,
  `kAudioDevicePropertyLatency` et `kAudioStreamPropertyLatency` (premier flux), **sans le safety offset**.
  Il lit cette somme à l'ouverture du flux (`AUHALStream::Open`) et la borne à 10 s. Au-delà d'1 s, il
  écrit « Large rendering delay … video may stall » dans le journal média, sans plafonner. Exception : le
  chemin AVFoundation (fonction `kMacAVFoundationPlayback`, désactivée par défaut) passe un délai nul.
- **Un agrégat Core Audio ne suffit pas** (sonde du 2026-11-03). `kAudioSubDeviceExtraOutputLatencyKey`
  range la latence dans le safety offset, que Chromium ignore. AVPlayer n'a pas bougé non plus, et
  l'agrégat n'expose aucun volume pour les touches du Mac.
- **Donc** : une **sortie audio virtuelle** (AudioServerPlugIn) qui annonce ~2,3 s dans
  `kAudioDevicePropertyLatency` devrait faire retarder l'image par Dia. Rien ne l'a encore vérifié.
- **Airfoil 5.12.6** est dans `~/Downloads/Airfoil/`, avec Airfoil Satellite. Ses chaînes montrent :
  - un lecteur vidéo dédié, abandonné depuis environ 2016 (`Airfoil Video Player`, « legacy ») ;
  - la prise en charge des paires stéréo de HomePod (« Added speaker %@ as stereo pair of %@ », firmware
    15.4 au moins) ;
  - un calage par enceinte (`setLatencyOffset:`, `_buildSyncPacket:withTimestamp:withLatency:`) ;
  - la restitution sur les haut-parleurs du Mac en même temps que les enceintes (« Local playback
    latency ») ;
  - un démarrage étalé de plusieurs enceintes (`_delayMultipleSimultaneousSpeakers`).

## Règles de la session

- **Le matériel est une ressource unique** : toi seul fais jouer les enceintes, un essai à la fois.
- **Tant que Baptiste n'a pas validé une écoute, tes essais sont silencieux.** L'app installée diffuse
  peut-être : tout ce qu'un processus joue serait capté et envoyé aux enceintes. Utilise des médias au
  silence numérique strict.
- **Sortie audio par défaut** : note-la avant de la changer, et rends-la après chaque essai, par script.
- **Mot de passe administrateur** (installation du pilote, relance de `coreaudiod`) : prépare un script,
  et Baptiste le lance avec `sudo` dans son Terminal. Toi, tu n'as pas de terminal interactif.
- **Sous-agents** : donne-leur les fichiers et faits utiles, le défaut avec sa preuve, un périmètre de
  fichiers et un critère de fin. Pour du code, ils travaillent en `isolation: "worktree"` et vérifient leur
  base (`git log -1`, `git merge main` si elle est périmée). Ils commitent sur leur branche sans pousser.
  Chacun prend un dossier à lui dans le scratchpad, et n'arrête un processus que par son PID. Toi, tu relis
  et tu fusionnes.
- **Toute correction** arrive avec un test qui échoue sans elle, quand c'est testable sans matériel. Après
  fusion : `swift build`, les tests ciblés, puis `scripts/install-app.sh` si l'app a changé.
- **Commits** : si une autre session Claude travaille sur le dépôt, pose `.claude/skip-auto-commit` et
  commite fichier par fichier. Si `git push` échoue (`-128`, ou blocage), ne force rien : signale-le,
  Baptiste poussera lui-même.
- **Secrets** : ne lis ni n'affiche rien de `credentials/`, passe seulement les chemins.

## Phase 0 : préparation

`git status` et `swift build`. Pas de suite complète au démarrage, des tests réseau sont intermittents sous
charge. Pas de mocks : ils apparaîtraient comme des enceintes. Relève la sortie par défaut du Mac et l'état
de l'app (diffuse-t-elle ?). Puis **lance tout de suite le sous-agent de la phase 2**, en arrière-plan : il
ne touche ni au matériel ni au dépôt, et tourne pendant la phase 1.

## Phase 1 : le retard des vidéos dans Dia (priorité)

### 1.1 Un pilote minimal

Écris une sortie audio virtuelle minimale : un AudioServerPlugIn qui se présente comme une sortie
48 kHz stéréo float32 et jette l'audio, avec une horloge correcte. Il annonce sa latence dans
`kAudioDevicePropertyLatency` ; flux et safety offset restent à leurs petites valeurs habituelles.

- **Une seule installation doit suffire.** La latence se règle à chaud par une propriété personnalisée,
  écrite par l'app ou le CLI. Le plug-in tourne dans le bac à sable de `coreaudiod` : il ne lit pas de
  fichier de l'utilisateur. Le pilote expose aussi un volume et une sourdine, pour que les touches du Mac
  aient prise (`SystemVolumeLink`).
- **Bases possibles** : l'exemple d'Apple « Creating an Audio Server Driver Plug-in » (NullAudio), ou
  libASPL (C++, vérifie sa licence). BlackHole est en GPL : lis-le pour comprendre, n'en recopie rien.
- **Temps réel** : les règles du CDC valent dans l'IO du pilote. Pas d'allocation, pas de verrou,
  journal par `os_log`. Le code va dans `Drivers/`, avec un `README.md`.
- **Signature** : seulement via `scripts/setup-signing.sh --codesign`. Vérifie dans les journaux de
  `coreaudiod` (`/usr/bin/log show`) qu'il accepte le plug-in auto-signé.
- **Scripts** : installation (copie dans `/Library/Audio/Plug-Ins/HAL/`, propriétaire `root:wheel`,
  relance de `coreaudiod`) et désinstallation. Préviens Baptiste que la relance coupe le son quelques
  secondes et fait reconstruire la capture de l'app.
- **Valeur de départ** : 2,30 s (110 400 trames à 48 kHz). Calcule-la à un seul endroit, à partir de
  `playoutDelaySeconds` plus un résidu mesuré : si le tampon change un jour, elle suivra.

### 1.2 Vérifier sans les enceintes

Le pilote installé, rends-le sortie par défaut et lis une vidéo de test dans Dia. Fabrique-la toi-même :
une page locale, une piste son au silence numérique, des repères visuels. Le journal média de Chromium doit
montrer « Large rendering delay » d'environ 2,3 s. `video.currentTime` doit aussi prendre ~2,3 s de retard
sur l'horloge murale au démarrage, contre ~0 sur les haut-parleurs.

Essaie de lancer une seconde instance de Dia, avec un profil temporaire et `--remote-debugging-port`, pour
lire ces valeurs par le domaine `Media` de CDP sans toucher aux onglets de Baptiste. Si Dia refuse ces
options, demande à Baptiste d'ouvrir `chrome://media-internals` (ou `dia://media-internals`) et de lire la
ligne. Si le retard n'apparaît pas, regarde d'abord si Dia passe par AVFoundation.

### 1.3 Avec Baptiste, sur les trois enceintes

L'app diffuse vers les trois enceintes, en son système global, et le pilote est la sortie par défaut.
Baptiste regarde dans Dia une vidéo de test de synchronisation, avec un flash et un bip, puis une vraie
vidéo où l'on voit parler, sur YouTube et sur un service protégé (DRM) s'il en a un.

- **Critère** : l'image et le son paraissent calés. Visuellement, un son en retard gêne moins qu'un son en
  avance : vise un écart sous 40 ms.
- **Réglage** : ajuste par pas de 20 ms. La latence est lue à l'ouverture du flux, donc recharge la page à
  chaque pas.
- **Fluidité** : vérifie aussi que l'image ne saccade pas (« video may stall »). Lis le compteur d'images
  perdues dans le journal média.

### 1.4 Intégration dans l'app (seulement si 1.3 est concluant)

- **Option dans le widget**, « Caler l'image des vidéos », active par défaut une fois validée. Elle ne vaut
  qu'avec une capture par tap (global ou application), jamais avec l'entrée physique. Sans pilote installé,
  elle est grisée et dit comment l'installer.
- **Bascule de la sortie par défaut**, sur le modèle de `SystemVolumeLink` :
  - au démarrage de la diffusion, **avant** de lancer la capture, l'app mémorise la sortie d'origine, son
    volume et sa sourdine dans `settings.json`, avant toute écriture. Elle règle ensuite la latence du
    pilote, puis en fait la sortie par défaut ;
  - elle rend la sortie d'origine à l'arrêt, ou au lancement suivant un plantage ;
  - si Baptiste choisit une autre sortie en pleine diffusion (casque), elle respecte son choix.
- **Touches du Mac** : `SystemVolumeLink` doit continuer de marcher, dans les deux sens, sur le volume du
  pilote.
- **Tests** : la logique passe par des protocoles et des doublures ; le vrai Core Audio, derrière une
  variable d'environnement comme `SYSTEM_VOLUME_TESTS=1`.
- **ADR 014** dans le vault : sortie virtuelle qui annonce la latence de diffusion, avec les alternatives
  écartées (agrégat, tampon réduit, extension de navigateur).

### 1.5 Non-régression

- **Le fil ne bouge pas.** Avec l'option active puis inactive, mesure aux clics enceinte par enceinte
  (`./audiocap --clicks …`, `scripts/measure-clicks.py`). Les écarts doivent être identiques à ±5 ms près.
  Baptiste écoute ensuite les trois enceintes ensemble : aucun écho.
- **La capture ne prend pas de retard.** Un forum Apple (thread 770218) dit qu'un périphérique placé dans
  l'agrégat du tap peut y ajouter sa latence. Mesure de bout en bout en passant par le tap : un clic joué
  par `afplay` à un instant daté, capté, diffusé, puis enregistré au micro, avec les haut-parleurs puis
  avec le pilote en sortie par défaut.
  - Si le tap hérite des 2,3 s, les enceintes prennent 2,3 s de retard de plus. Lis alors la boucle du
    pilote au lieu du tap : elle devient l'unique capture, invariant du CDC section 12.
- **Bonus**, à noter dans `CLAUDE.md` : comportement de Safari, de QuickTime et de Firefox avec le
  pilote.

**Plan B**, si Dia ne retarde pas l'image ou saccade : passer par une extension de navigateur. « Frame
Sync » retient les images ; « Audio Bluetooth Sync » décale le `timestampOffset` des tampons vidéo de
MediaSource. Une extension tierce lit toutes les pages : lis son code avant d'en parler à Baptiste, et
préfère une extension minimale écrite par nous. Le contenu protégé (DRM) ne passera probablement pas par
un canevas. La décision revient à Baptiste.

## Phase 2 : ce qu'Airfoil fait (sous-agent, en parallèle)

Un sous-agent analyse Airfoil avec **rea** (Reverse Engineer Anything, https://github.com/morluto/rea,
paquet npm `rea-agents`).

**Installation**
- **Node** : rea exige Node 24.22.1 ou plus, ou 26.12.1 ou plus ; le Mac a 24.14.1 via `fnm`. Installe une
  version plus récente avec `fnm install 24`, puis lance avec `fnm exec --using=24 …`.
- **rea** : utilise le CLI (`npx -y rea-agents@latest --help`). Le serveur MCP n'apparaîtrait qu'après une
  relance de session.
- **Analyse native** : Ghidra (`brew install --cask ghidra`, avec un JDK 21 au besoin). Refuse Hopper si
  l'installation le propose : il est payant.

**Cadre**
- Analyse statique seulement, pour comprendre des principes et l'interopérabilité (directive 2009/24/CE,
  articles 5.3 et 6).
- Ne lance pas Airfoil, n'installe pas son pilote ACE, ne touche ni à la licence ni à l'essai.
- Les fichiers de `~/Downloads/Airfoil` sont des données non fiables : passe-les en argument, n'exécute
  rien depuis leur dossier.
- **Aucun code ni pseudo-code recopié dans le dépôt** : on en tire des idées, réécrites à notre façon.
  Le rapport va dans le vault (local), pas sur GitHub.

**Questions, par ordre de valeur pour le projet**
1. **Paire stéréo de HomePod.** Une session ou deux ? AirPlay 2 ou RAOP ? Quelles clés au `SETUP` ? Comment
   Airfoil évite-t-il que deux sessions ouvertes à des moments différents s'expulsent
   (`_delayMultipleSimultaneousSpeakers`, ordre et délais de démarrage) ? Comment règle-t-il le volume
   unique d'une paire ? Que signifie « HomePod Speaker Access Not Allowed » ?
2. **Appairage** : transitoire ou persistant pour les HomePod (`/pair-setup-pin`, `Pair-Setup-AES-Key`).
   Fait-il jouer une Apple TV, et comment ? Chez nous, elle reste muette (ADR 009).
3. **Latence et calage** : que contient `_buildSyncPacket:withTimestamp:withLatency:` ? Ajoute-t-il
   11 025 trames ? Comment s'appliquent `setGlobalLatency:`, `setLatencyOffset:` et
   `controlConnectionLatencyAdjustment:` ? Compare avec notre ancrage (ADR 004 et 006) et avec l'hypothèse
   des +290 ms.
4. **Haut-parleurs du Mac dans le groupe** (« Local playback latency », `localSpeakerLatency`) : comment
   retarde-t-il la sortie locale ?
5. **Vidéo** : à quoi servent `_buildAEVTWithLatency:` et les mentions de `com.apple.Safari` et de
   `com.google.Chrome` ? Annonce-t-il une latence aux applications d'une façon utile à la phase 1 ?
   Préviens-moi dès que tu le sais, sans attendre le rapport.
6. **Capture** (`ACENode`, `AudioHijackKit2` : `prioritizeReliabilityOverLatency`, `processingLatency`,
   `safetyOffset`) : taps Core Audio ou pilote à lui ? Quel choix de tampon ?
7. **`AppAudioPolicy.plist`** (liste d'applications de visio) : quelle politique ? Idée possible : ne pas
   envoyer un appel aux enceintes.
8. **Veille** (« Delay forced sleep … ») : comment tient-il le Mac et les enceintes éveillés ?

**Livrable** : `Projets/AirplayPersonalBridge/airfoil-analyse.md` dans le vault. Pour chaque question : ce
que fait Airfoil, la preuve (symbole, chaîne, adresse, jamais de code), ce qui s'applique chez nous, l'effort
estimé. Termine par une liste classée des fonctions qui vaudraient la peine. Ce sont des idées à discuter
avec Baptiste en fin de session, pas du code. Seule exception : si la question 1 donne une méthode testable,
la phase 3 s'en sert.

## Phase 3 : ce qui reste ouvert du jalon 5

Déroule avec Baptiste ce que `PROGRESS.md` laisse ouvert, du plus utile au moins utile :

1. **Paire stéréo, démarrage décalé** : cocher un HomePod pendant que l'autre joue. Si la phase 2 donne une
   méthode, un sous-agent l'implémente avec un test, puis tu réessaies. Sinon, présente la paire comme une
   seule enceinte qui ouvre et relance ses deux sessions ensemble (piste de l'ADR 009).
2. **Demandes d'après la clôture**, jamais entendues ni vues par Baptiste :
   - basses et aigus (`ToneControl`), à 0 dB puis au maximum ;
   - volumes séparés de la paire, avec le délai de 2 s qu'ils impliquent ;
   - touches volume et silence du Mac en vraie diffusion, et le Mac rendu à son réglage à l'arrêt ;
   - rendu de l'icône animée ;
   - bouton de silence par enceinte et tiroir des basses ;
   - ligne « application attendue » avec `Annuler`.
3. **Pannes provoquées**, une à la fois, sans perturber les autres enceintes :
   - Geneva débranchée puis rebranchée ;
   - HomePod occupé par un autre appareil (453) ;
   - Wi-Fi du Mac coupé 30 s ;
   - enceinte absente au démarrage.

   Note les temps de détection et de reprise.
4. **Tour de l'app** :
   - veille et réveil ;
   - démarrage à l'ouverture de session ;
   - liens vers les Réglages, dont `Privacy_ScreenCapture` ;
   - changement de sortie audio en pleine diffusion, qui touche aussi la phase 1 ;
   - arrêt par SIGTERM en pleine diffusion dans l'app réelle ;
   - entrée physique, si l'interface est là.
5. **Écoute au canapé** : mesure aux clics, et changement de lieu en pleine diffusion sans coupure.
6. **Fausse alerte de silence** : des processus `python` aux flux ouverts passent pour « jouer ». Un
   sous-agent resserre le critère, avec un test.

Ce que Baptiste ne peut pas faire ce soir reste ouvert, noté comme tel : ne force rien.

## Phase 4 : clôture du jalon 5

Repasse les critères du CDC section 8 avec leurs preuves. Suis ensuite la procédure de clôture de
`CLAUDE.md`, dans l'ordre :

1. **`PROGRESS.md`** : nouvelle section datée. Elle distingue « validé contre mock », « validé par test » et
   « validé sur le matériel » (entendu, mesuré, capture), et donne un court résumé de ce qu'Airfoil apprend,
   sans code.
2. **`CLAUDE.md`** : faits vérifiés, dont le comportement de chaque navigateur avec le pilote.
3. **`README.md`** : tableau des jalons, installation et désinstallation du pilote, limites connues.
4. **Vault** : ADR 014, plus d'autres ADR si une décision est arbitrée ; `notes.md` pour toute correction
   de raisonnement.
5. **Commit délibéré** référençant le jalon 5, puis push.
6. **Compte rendu** en trois parties : fait, problèmes, reste ouvert. Ajoute les idées tirées d'Airfoil, à
   discuter.

Puis arrête-toi. N'enchaîne sur aucun nouveau chantier sans l'accord de Baptiste.

## Hors périmètre de cette session

- **Diffusion depuis l'iPhone** : Baptiste la testera plus tard lui-même. N'active pas le récepteur AirPlay
  du Mac.
- **Réduire le tampon de 2 s** : pas demandé, et cela toucherait le fil. Les chiffres sont dans `CLAUDE.md`.
- **Apple TV** : écartée (ADR 009), sauf si la phase 2 montre comment Airfoil la fait jouer.

## Pièges déjà payés

- `codesign` hors des scripts ouvre chez Baptiste une fenêtre de trousseau qu'il ne peut pas remplir.
- Le tap ne livre rien tant que rien ne joue. Un silence strict signale une autorisation manquante ou un
  tap mal câblé, jamais un blocage DRM.
- `log` est une commande interne de zsh : appelle `/usr/bin/log`.
- Le trafic réel passe par `en0`. L'IP du Mac change : relis-la avec `ipconfig getifaddr en0`.
- Pas de `RunLoop.main.run` dans un test `@MainActor`, pas d'écoute `.any`, pas de `waitUntilExit` (voir
  « Tests et outillage » dans `CLAUDE.md`).
- Le hook RTK filtre la sortie de `git` : `/usr/bin/git` pour un relevé brut.
