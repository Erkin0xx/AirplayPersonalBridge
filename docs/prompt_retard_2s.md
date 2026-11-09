# Réduire le retard de 2,3 s : son des enceintes et lancement des vidéos

Tu travailles sur AirplayPersonalBridge, l'app macOS de Baptiste qui capte le son du Mac et le diffuse vers une
Geneva (RAOP) et une paire stéréo de HomePod (AirPlay 2), synchronisées. **Objectif : réduire le retard de bout en
bout, aujourd'hui ~2,3 s, sans casser la synchronisation entre enceintes.**

## Ce que Baptiste constate

Depuis le 2026-11-09, une sortie audio virtuelle (`Drivers/APBOutput`) annonce aux applications le retard de la
diffusion, et Dia retarde l'image d'autant. Le calage image/son est « impec ». En contrepartie, **une vidéo met ~2 s
à démarrer** dans Dia : le lecteur n'avance son horloge que lorsque le son de la première image sort des enceintes.
Le même retard se ressent sur tout le reste : un clic de souris, un son d'interface, une pause dans une vidéo.

**L'attente au lancement est le retard de bout en bout, rien d'autre.** Un lecteur ne peut pas montrer l'image 0
avant que le son de l'image 0 soit audible, sauf à démarrer décalé. Le seul levier honnête est de réduire le
retard réel. La sortie virtuelle suivra : elle annonce `VideoSyncLatency`, calculé à un seul endroit.

## Avant toute chose

1. Lis `CLAUDE.md` en entier, puis `PROGRESS.md` : « Ce qui reste ouvert » et les sections les plus récentes.
   Lis ensuite `git log -n 40`. Le mode de collaboration de `CLAUDE.md` s'applique : autonomie totale, pas de
   question oui/non. Sollicite Baptiste seulement pour une action physique, un mot de passe ou une écoute. Dis-lui
   alors exactement quoi faire, et une seule chose à répondre.
2. Dans le vault (`/Users/baptiste/Documents/Vault/Projets/AirplayPersonalBridge/`), lis `notes.md`, les ADR `004`
   (alignement par horloge de restitution commune), `006` (graduation commune), `009` (paire stéréo) et `014` (sortie
   virtuelle), et **`airfoil-analyse.md`**, en particulier la question 3.
3. **Une autre session Claude a peut-être travaillé juste avant toi, ou travaille encore** (clôture du jalon 5) :
   regarde `git log`, `git worktree list` et les processus `claude`. Si une session tourne, pose
   `.claude/skip-auto-commit`, commite fichier par fichier, et **ne fais jouer aucune enceinte sans l'accord de
   Baptiste** : le matériel est une ressource unique.

## Ce qui est établi : ne le refais pas

**D'où viennent les 2,3 s** (relevés de `CLAUDE.md`, « Retard de bout en bout et vidéo », et mesures du 2026-11-09) :

| Maillon | Valeur | Où |
|---|---|---|
| Capture par le tap | quasi nulle : un clic lancé par `afplay` est capté 47 à 65 ms après son lancement, démarrage d'`afplay` compris, que la sortie par défaut soit les haut-parleurs ou la sortie virtuelle | mesuré |
| Délai de restitution choisi | **2 s** : `latencyFrames` = 88 200 (`RAOPSender.swift:45`, `AirPlay2Sender.swift:53`), `SharedPlaybackClock.defaultPlayoutDelaySeconds` = 2.0 (`Sync/PlaybackClock.swift`) | code |
| Ce que les récepteurs ajoutent | **+290 à +307 ms** au-delà des 2 s, mesurés au micro enceinte par enceinte | mesuré |
| `SETUP` AirPlay 2 | `latencyMin` 11 025, `latencyMax` 88 200 (`AirPlay2Session.swift:252`) | code |

- **`latencyFrames` et `playoutDelaySeconds` se compensent** dans `OutputSynchronizer.syncAnchorUnixTime`
  (`Sync/OutputSynchronizer.swift:295`) : changer l'un sans l'autre décale toutes les enceintes d'un coup.
- **Les ~0,29 s viennent très probablement de 11 025 trames (0,25 s) que le récepteur ajoute** à la latence
  annoncée dans le paquet de synchro. Décrit par OwnTone et shairport-sync ; et **Airfoil annonce 1,75 s
  (77 175 trames) dans ses paquets de synchro pour obtenir 2,0 s réels** (analyse statique, `airfoil-analyse.md`,
  Q3). Reste ~40 à 60 ms : trajet du son et tampons des récepteurs.
- **Retransmissions sur le vrai Wi-Fi**, mesurées avec un tampon de 2 s (`captures/p5-endurance-1h.pcapng`) : délai
  entre la première émission et la demande, HomePod médiane ~95 ms, **p99 ~940 à 970 ms, max ~1,08 s** ; Geneva p99
  168 ms, max 295 ms. **Rien ne dit qu'un HomePod garde ce rythme avec un tampon plus court.** Un tampon sous ~1,1 s
  ferait arriver trop tard une partie des paquets retransmis aux HomePod : trous audibles.
- **macOS natif** emploie aussi 2 s en AirPlay. 2 s n'est donc pas un minimum, mais c'est le choix d'Apple.
- **La sortie virtuelle** annonce `VideoSyncLatency.seconds()` = délai de restitution + 0,30 s de résidu mesuré
  (`Sources/AudioCore/VirtualOutputDevice.swift`). Chromium 157 retarde l'image de cette valeur : mesuré
  +2,28 s, « Large rendering delay (2.34 s) », 0 image perdue. AVPlayer suit aussi. Une page lit la latence à
  l'ouverture de son flux : il faut recharger.

**Ce que Baptiste ne veut pas perdre** : la synchronisation entre enceintes. Écart mesuré ≤ 17 ms, aucun écho
entendu à trois. La paire de HomePod ne tient que si ses deux sessions démarrent ensemble (`CLAUDE.md`). La Geneva
ne doit pas voir son `Audio-Latency` (4096) retranché de l'ancrage : c'est ce qui l'a fait jouer 84 ms trop tôt.

## Démarche proposée, du moins risqué au plus risqué

Chaque étape change le fil : **mesure avant, mesure après**, une étape à la fois, et Baptiste écoute avant la
suivante. Toute valeur retenue se règle à un seul endroit, et `VideoSyncLatency` suit sans constante recopiée.

### Étape 1 : retirer la constante du récepteur (~0,25 s, sans toucher au tampon)

Hypothèse à vérifier, pas à présumer : annoncer `L − 11 025` dans le paquet de synchro, et non `L`, pour que le
récepteur restitue à `L` et non à `L + 0,25 s`. Réfléchis d'abord à l'ancrage. `syncAnchorUnixTime` place l'instant
annoncé en retranchant `latencyFrames` ; si le récepteur ajoute 11 025 trames de son côté, l'ancrage doit en tenir
compte, sinon toutes les enceintes avancent ou reculent ensemble. Lis `RTPTransport.swift:163`, `OutputSynchronizer`
et les ADR 004 et 006 avant d'écrire une ligne. Vérifie aussi si les HomePod (AirPlay 2, `TIME_ANNOUNCE_NTP` sur le
canal de contrôle) se comportent comme la Geneva (RAOP) : la constante peut différer d'un protocole à l'autre.

- **Test** qui échoue sans le changement, sur les octets du paquet de synchro et sur l'instant d'ancrage.
- **Mesure** aux clics, une enceinte à la fois puis les trois : le résidu doit passer d'~+300 ms à ~+50 ms, **et
  les écarts entre enceintes rester ceux d'avant à ±5 ms**. Puis Baptiste écoute les trois ensemble : aucun écho.
- **Puis** : remesurer le résidu et mettre à jour `VideoSyncLatency.measuredReceiverResidualSeconds`. Vérifier à
  l'œil, avec Baptiste, la vidéo flash-bip dans Dia.

### Étape 2 : raccourcir le délai de restitution, par paliers

Seulement si l'étape 1 est validée et si Baptiste le veut. Paliers suggérés : 2,0 → 1,5 → 1,2 s. Ne descends pas
sous ~1,1 s sans données nouvelles sur les retransmissions.

- `latencyFrames` des deux senders et `playoutDelaySeconds` bougent **ensemble**, par une seule constante.
- À chaque palier : endurance d'au moins 30 min sur les trois enceintes, avec capture `tshark` sur `en0`. Compte les
  demandes de retransmission (`0xD5`) et celles dont la réponse arrive **après** l'instant de restitution du paquet.
  Baptiste écoute de la musique : aucun craquement, aucun trou. Puis mesure aux clics, et retouche de
  `VideoSyncLatency` (automatique si le délai passe par la constante).
- Regarde ce que chaque récepteur accepte : la plage `latencyMin`/`latencyMax` du `SETUP` AirPlay 2, et le
  comportement de la Geneva sous 2 s, qui ne l'a jamais connu.

### Étape 3 : rendre compte

Tableau par palier : résidu au micro, écarts entre enceintes, retransmissions tardives, ce que Baptiste a entendu,
attente au lancement d'une vidéo dans Dia. C'est **Baptiste qui choisit** le palier retenu. Ensuite : ADR dans
`decisions/` du vault, faits dans `CLAUDE.md` (« Retard de bout en bout et vidéo »), entrée dans `PROGRESS.md`, en
distinguant « validé par test », « mesuré » et « entendu ».

## Outils

- **Calage entre enceintes** : `./audiocap --clicks --airplay "Erki’s geneva" --airplay2 Salon --airplay2 "Salon (2)"
  --record-input <f.wav> 90`, puis `scripts/measure-clicks.py <f.wav>`. Une enceinte à la fois d'abord, pièce
  calme, au moins 60 s. Voir `CLAUDE.md`, « Mesure acoustique ».
- **Retard de l'horloge vidéo de Chromium, sans fenêtre** : `scripts/video-sync/` (`make-media.sh`, `page.html`,
  `measure.mjs` ; le mode d'emploi est en tête de `measure.mjs`). Chrome 157 sans fenêtre, profil temporaire :
  **jamais une seconde instance de Dia**, qui affiche chez Baptiste son écran de connexion.
- **Sortie virtuelle** : `swift run audiocap --video-sync`, `--video-latency auto|<s>`, `--default-output
  bridge|<uid>`.

## Règles de la session

- **Le matériel est une ressource unique** : un essai à la fois, et toi seul fais jouer les enceintes.
- **Avant tout essai qui touche la sortie du Mac** (sortie par défaut, sourdine, `--mute-local`) : `swift run
  audiocap --list`. Si une application de Baptiste joue (`●`), **n'y touche pas** : demande-lui de mettre en pause.
  Un essai mené pendant qu'il écoute lui coupe le son, c'est arrivé le 2026-11-09.
- **Tant que Baptiste n'a pas validé une écoute, tes essais sont silencieux** : médias au silence numérique strict.
- **Sortie audio par défaut** : note-la avant de la changer, rends-la après chaque essai, par script (`trap`).
- **Mot de passe administrateur** : prépare un script, Baptiste le lance avec `sudo` dans son Terminal.
- **L'app quitte en relançant coreaudiod** (`sudo -n killall coreaudiod`) : chaque `scripts/install-app.sh` coupe le
  son du Mac une à deux secondes. Préviens Baptiste avant.
- **Sous-agents** : `isolation: "worktree"`, base vérifiée (`git log -1`, `git merge main`), commits sur leur branche
  sans push, un dossier à eux dans le scratchpad, processus arrêtés par PID. Toi, tu relis et tu fusionnes.
- **Toute correction arrive avec un test qui échoue sans elle.** Après fusion : `swift build`, tests ciblés (pas la
  suite complète, tests réseau intermittents sous charge), puis `scripts/install-app.sh` si l'app a changé.
- **Secrets** : ne lis ni n'affiche rien de `credentials/`.
- Si `git push` échoue, ne force rien : signale-le.

## Pièges déjà payés

- Le tap ne livre rien tant que rien ne joue : pour dater une capture, fais jouer un fichier de silence strict en
  continu.
- Mesure aux clics : une salve sur cinq est doublée 250 ms plus tard. Une enceinte en retard d'environ 250 ms se
  confond avec ces doublures : replie l'enregistrement modulo 2 s.
- `log` est une commande interne de zsh : `/usr/bin/log`. Le hook RTK filtre `git` : `/usr/bin/git` pour un relevé brut.
- `codesign` hors de `scripts/setup-signing.sh --codesign` ouvre chez Baptiste une fenêtre de trousseau.
- Pas de `RunLoop.main.run` dans un test `@MainActor`, pas d'écoute `.any`, pas de `waitUntilExit`.

Arrête-toi après l'étape 3 : n'enchaîne sur aucun autre chantier sans l'accord de Baptiste.
