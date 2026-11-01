# Phases de test sur le vrai matériel et fin du projet

Tu orchestres la dernière étape d'AirplayPersonalBridge. Baptiste est sur place, la Geneva, les
deux HomePod et l'Apple TV sont allumés. Jusqu'ici presque tout a été validé contre des mocks et
des tests : le but est de confirmer sur le vrai matériel, de corriger ce qui casse, puis de clore
le jalon 5.

Avant toute chose : lis `PROGRESS.md` et `CLAUDE.md` en entier, puis `git log -n 30`. Le mode de
collaboration de `CLAUDE.md` s'applique : autonomie totale, pas de question oui/non, Baptiste n'est
sollicité que pour une action physique ou une écoute. Quand tu as besoin de lui, dis exactement
quoi faire et quoi écouter, puis une seule chose à répondre.

## Règles d'orchestration

- **Le matériel est une ressource unique.** Toi seul pilotes les essais sur les enceintes, un à la
  fois. Les sous-agents servent à ce qui peut tourner en parallèle : analyser une capture réseau,
  corriger un défaut, écrire un outil de mesure, relire. Un seul sous-agent par défaut, en
  `isolation: "worktree"`, jamais deux qui touchent aux enceintes.
- **Brief d'un sous-agent** : fichiers et faits utiles, défaut constaté avec sa preuve (extrait de
  capture, journal), périmètre de fichiers, critère de fin. Il vérifie sa base (`git log -1`) et
  fait `git merge main` si elle est périmée ; il commite sur sa branche sans pousser ; il prend un
  dossier à lui dans le scratchpad, qui est partagé ; il n'arrête un processus que par son PID,
  jamais par son nom. Tu relis et tu fusionnes.
- **Toute correction** arrive avec un test qui échoue sans elle, quand c'est testable sans matériel.
  Après fusion : `swift build`, `swift test`, puis réinstallation si l'app a changé.
- **Volume** : commence toujours au plus bas (`--tone --tone-level -50 --volume -30`). Ne monte
  qu'une fois Baptiste prêt, jamais de saut brutal.
- **Secrets** : `credentials/` contient des clés privées. Passe leurs chemins, n'affiche ni ne lis
  jamais leur contenu.
- **Preuves** : capture chaque session sur `en0`, dans `captures/` (ignoré par git pour les pcap) :
  `tshark -i en0 -f "host <ip>" -w captures/<essai>.pcapng`. Note chaque résultat avec son niveau :
  « entendu », « mesuré », « capture », « non testé ».

## Phase 0 : préparation

1. État : `git status`, `swift build`, `swift test`. `AUDIOCORE_MOCK_TESTS=1` et `RUN_MOCK_TESTS=1`
   activent les tests contre mocks si tu doutes d'un sender (mocks : `./run-mocks.sh start`, à
   arrêter ensuite pour éviter toute confusion de noms).
2. Signature et installation : `scripts/setup-signing.sh`, `scripts/install-app.sh --open`,
   `./make-cli-bundle.sh`. Première autorisation « sons du système » : à faire faire par Baptiste,
   une fois pour l'app et une fois pour `audiocap`. Une recompilation ne doit plus la révoquer : à
   confirmer ici.
3. Découverte : `swift run audiocap --browse` et `--browse2`. Relève les noms exacts et les bits de
   fonctionnalité de chaque appareil. Le nom réseau de la Geneva n'a jamais été noté : ajoute-le à
   `CLAUDE.md`.
4. Les deux HomePod **forment une paire stéréo** (confirmé par Baptiste). Relève leur TXT
   `_airplay._tcp` (`dns-sd -L`) : `gid`, `igl`, `gcgl`, `tsid` et ce qui distingue le leader, pour
   comprendre ce que représentent « Salon » et « Salon (2) ». Demande à Baptiste quelle est la sortie
   audio par défaut de l'Apple TV (app Réglages de l'Apple TV ou app Maison).
5. **Garder la Geneva éveillée.** Sa veille n'a jamais été mesurée ; un ping ne garantit rien, car
   ce genre d'enceinte se met en général en veille faute de son. Ping en arrière-plan uniquement
   comme témoin (il dit si elle est tombée), et tiens-la éveillée par une session quasi inaudible :
   ```bash
   swift run audiocap --tone --tone-level -60 --tone-freq 60 --airplay "<nom>" --volume -30 3600
   ```
   Pas d'autorisation requise : `--tone` n'utilise pas la capture. Relance-la si elle s'arrête.
   **Une session occupe l'enceinte** : arrête ce gardien (par son PID) avant chaque essai sur la
   Geneva, et relance-le après. Si elle s'éteint quand même, monte à −50 puis −40 dBFS et note le
   seuil et le délai dans `CLAUDE.md`.

## Phase 1 : chaque enceinte seule (non-régression)

Pour la Geneva, puis « Salon », puis « Salon (2) » : sinusoïde faible 30 s, capture réseau, puis
une seconde session aussitôt après (la première ne doit rien laisser bloqué), puis de la vraie
musique par le Process Tap pendant 60 s. Baptiste juge : son propre, pas de craquement.

Un sous-agent analyse chaque capture : séquence RTSP, codes de réponse, cadence des paquets. Ces
changements n'ont jamais vu le vrai matériel, et chacun peut casser ce qui marchait :

- **Geneva** : `POST /feedback` avant `RECORD` puis toutes les 25 s si accepté ; réponses `80 D6`
  aux demandes de retransmission ; `Session` au `TEARDOWN` ; keepalive TCP et `noDelay` ; SDP censé
  être inchangé ; renfort de basses (`LowShelfFilter` et limiteur) à l'oreille, à 0 dB puis au
  maximum.
- **HomePod** : `POST /feedback` toutes les 2 s après `RECORD` ; réponses `80 D6` ; acquittement 200
  chiffré sur le canal d'événements ; `TEARDOWN` à la perte de session ; nouvel essai si le port
  d'événements refuse ; IPv4 pour le `SETUP` ; volume sous −30 traduit en −144.
- **Découverte** : adresse sans connexion TCP, et combien de temps un appareil éteint reste listé.

Ce qui peut couper un son qui marchait, à regarder en premier : côté Geneva, le code de réponse au
`/feedback` et son délai, un FIN ou RST reçu sur RTSP (il déclenche désormais une renégociation, alors
que l'ancien code l'ignorait), des sondes keepalive sans ACK, et les paires `0x55`/`0xD6`. Côté HomePod
le RTSP est chiffré et illisible en capture : lis les journaux (`log show`, sous-système du projet).
Les HomePod annoncent-ils une `Audio-Latency` au `RECORD` ? Rien n'a jamais lu cette réponse : si
c'est le cas, elle compte dans le calage de la phase 2.

Si un ajout est refusé ou gêne : rends-le conditionnel plutôt que de le retirer d'office, en suivant
ce que fait pyatv (`tools/pyatv313/`).

## Phase 2 : synchronisation (priorité n°1)

**Le calcul d'ancrage a changé sans jamais avoir été entendu** : l'instant annoncé valait
« maintenant + 1 s − négociation », il vaut « maintenant » (commit c41b2ac). Le commit 0cf8a31
compense la latence annoncée par la Geneva (4 096 trames) et n'a pas été confirmé à l'oreille non
plus, d'autant que l'ancien écart suivait surtout la différence de durée de négociation. Si un écart
apparaît, commence par la capture : sur chaque paquet `0xD4`, NTP − instant de la trame doit valoir
≈ −0,1 s sur la Geneva et ≈ 0 sur les HomePod, champ 3 − champ 1 = 88 200, et ΔNTP = Δrtp / 44 100,
sans saut. **Ne reviens pas à l'ancien calcul en retirant seulement `dropped` de `timelineSkew`** :
l'horloge démarre désormais à la capture (commit 4a10071), et un HomePod négocié après 5 s annoncerait
alors un instant passé de 4 s, ses trames arrivant trop tard. Ce retour exige aussi de ramener l'origine
de l'horloge au premier sender.

1. **Mesure acoustique, pour ne pas dépendre de la seule oreille.** Un sous-agent écrit une source
   de clics (salve courte toutes les 2 s, drapeau CLI à côté de `--tone`) et un script qui repère
   les salves dans un enregistrement. **Deux lieux d'écoute sont sélectionnables : « À table » par
   défaut (dos à la fenêtre, face à la télé) et « Au canapé » (place gauche sur le plan).** Le calage
   doit être bon avant tout à table : Baptiste pose le Mac sur le bord de la table côté fenêtre.
   Enregistre avec `./audiocap --mode input` (autorisation micro à donner une fois) pendant que
   chaque enceinte joue seule, puis les trois ensemble. Rapporte l'écart entre enceintes. Critère du
   CDC section 8 : moins de 20 à 30 ms. Refais la mesure au canapé, en sélectionnant ce lieu, pour
   vérifier que le choix améliore bien le calage là où on écoute.
2. Rejoue en lançant les sorties dans un ordre différent, et après une reconnexion forcée :
   l'alignement ne doit plus dépendre de la durée de négociation. Ajoute une enceinte en pleine
   diffusion : elle doit s'aligner.
3. Le lieu sélectionné compense la distance de chaque enceinte, en plus du réglage manuel. Valeurs du
   plan (distance, compensation) : à table, Geneva 1,86 m et 2,2 ms, HomePod gauche 2,62 m et 0 ms,
   droit 2,20 m et 1,2 ms ; au canapé, Geneva 3,71 m et 0 ms, HomePod gauche 1,75 m et 5,7 ms, droit
   2,07 m et 4,8 ms. Ces écarts sont sous le seuil de perception : vérifie par la mesure qu'ils
   améliorent le calage, et que changer de lieu en pleine diffusion ne produit aucune coupure audible.
   Si la paire devient une seule session en phase 3, sa compensation est la moyenne des deux HomePod.
4. Écoute finale par Baptiste, sur une musique avec des attaques nettes. Il dit s'il entend un écho.

Si un réglage de délai manuel est nécessaire à chaque session, c'est un défaut à comprendre, pas un
réglage à conserver.

## Phase 3 : la paire stéréo de HomePod

Les deux HomePod forment une paire stéréo, et le projet les a jusqu'ici adressés comme deux sorties
séparées, sans jamais savoir ce que chacun restitue dans ce cas. Teste du plus simple au plus lourd.

1. **Une seule session, vers `Salon` seul, puis vers `Salon (2)` seul.** Fais écouter un test de
   canaux gauche/droite (un sous-agent ajoute au besoin une source de test qui alterne les canaux).
   Question à trancher : est-ce qu'une seule enceinte joue, ou les deux, et avec quelle répartition ?
   Si le leader de la paire répartit lui-même gauche et droite, **c'est la solution** : vraie stéréo,
   calage assuré par les HomePod, une seule session, et l'interface doit présenter la paire comme une
   seule enceinte. C'est une hypothèse, pas un fait établi.
2. **Deux sessions** (`Salon` + `Salon (2)`) : la référence, déjà jouée en août. Mesure l'écart entre
   les deux, et note ce que chacune joue quand les deux sessions sont actives, et si l'une expulse
   l'autre.
3. **Via l'Apple TV** : `pair-verify` n'a jamais abouti sur elle. La correction `X-Apple-HKP: 3` n'a
   été confirmée que contre un accessoire simulé.
   ```bash
   ./audiocap --airplay2 "Apple TV Salon" --credentials2 "<chemin absolu>/credentials/appletv-salon-airplay.txt" 30
   ```
   Attendu : `pair-verify abouti`. Si « autre identité » réapparaît, l'hypothèse est fausse : compare
   l'échange à celui de pyatv avec ces mêmes credentials. Si ça passe, compare à l'oreille : image
   stéréo, latence, tenue dans la durée, et ajoute à l'interface ce qu'il faut pour la choisir.
4. **Décision**, tracée dans un ADR du vault, en comparant stéréo, calage avec la Geneva et simplicité.
   Dernier recours, seulement si aucune des options ne donne d'image stéréo et que l'écart mesuré en 2
   est de l'ordre de quelques ms : un sous-agent ajoute un mode de canal par sortie (gauche, droite,
   stéréo), sur la copie propre au sender (invariant section 12), réglé par enceinte dans l'interface.
   Adapte ensuite le plan : la distance d'une sortie est déjà la moyenne de ses enceintes, donc une
   paire adressée en une session se rattache aux deux HomePod du plan. Si tu touches à l'identifiant
   de sortie, rattache à nouveau (`RoomLayout.salon`, plan réel de Baptiste).

## Phase 4 : l'app et le widget de la barre de menus

Déroule avec Baptiste la liste « à vérifier » de `PROGRESS.md`, au minimum : icône selon l'état ;
cocher et décocher une enceinte en pleine diffusion sans perturber les autres ; quitter pendant une
diffusion (`TEARDOWN` visible en capture) ; veille puis réveil ; réouverture de la fenêtre ; réglages
conservés après relance ; démarrage à l'ouverture de session ; « Couper le son du Mac » ; alerte de
silence ; changement de sortie audio du Mac en pleine diffusion (casque débranché) ; enceintes du plan
rattachées aux bonnes sorties (gauche = `Salon` est une hypothèse, à confirmer en faisant jouer une
seule enceinte) ; choix du lieu d'écoute depuis le widget et depuis le plan ; hauteurs et place exacte
des deux lieux d'écoute à corriger par Baptiste ; entrée physique si l'interface audio est disponible.

## Phase 5 : pannes et endurance

Une panne à la fois, chacune sans perturber les autres enceintes (invariant section 12) : Geneva
débranchée puis rebranchée ; HomePod occupé par un autre appareil (453) ; Wi-Fi du Mac coupé 30 s ;
enceinte absente au démarrage puis allumée. Note le temps de détection et de reprise.

Puis la validation du CDC section 8 : **au moins 1 h** de diffusion continue vers toutes les sorties,
pendant que Baptiste vaque à ses occupations. Un sous-agent relève les compteurs (retransmissions,
reconnexions, corrections de dérive, trames refusées), et Baptiste écoute au début et à la fin pour
détecter une dérive.

## Phase 6 : clôture du jalon 5

Passe en revue chaque critère du CDC section 8 : validé, avec sa preuve, ou explicitement ouvert.
Décide du sort du jalon 0 (OwnTone), décalé depuis le début, et écris pourquoi. Puis suis la procédure
de clôture de `CLAUDE.md`, dans l'ordre : `PROGRESS.md` en distinguant « validé contre mock » et
« validé contre matériel réel », `CLAUDE.md`, `README.md`, vault (ADR et `notes.md`), commit délibéré
référençant le jalon, push. Termine par un compte rendu en trois parties : fait, problèmes, reste
ouvert. Puis arrête-toi.

## Pièges déjà payés

- Un `codesign` sur un trousseau verrouillé ouvre une fenêtre de mot de passe chez Baptiste : signe
  uniquement via les scripts, qui déverrouillent juste avant.
- Un silence strict signale une autorisation manquante ou un tap mal câblé, jamais un blocage DRM.
- Le tap ne livre aucun bloc tant que rien ne joue : lance la lecture avant de conclure.
- Le trafic réel passe par `en0`, celui des mocks par `lo0`.
- L'IP du Mac a changé (192.168.1.176 lors de la dernière vérification, pas .21) : relis-la.
