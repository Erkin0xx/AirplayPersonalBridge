# Retard de bout en bout : notes de la session « retard 2 s »

Notes de travail du chantier `docs/prompt_retard_2s.md`, tenues à part parce qu'une autre session réécrit
`PROGRESS.md`, `CLAUDE.md` et `README.md` à la clôture du jalon 5. À fusionner ensuite dans `CLAUDE.md`
(« Retard de bout en bout et vidéo ») et `PROGRESS.md`.

Niveaux de preuve : **test** (`swift test`, faux récepteurs en boucle locale), **mesuré** (micro), **entendu**
(Baptiste). **Rien ci-dessous n'est encore mesuré ni entendu.**

## État au 2026-11-09, 23 h 50

| Étape | État |
|---|---|
| 1. Retirer la constante du récepteur (~0,25 s) | Code et tests faits, **désactivé par défaut**. Mesure au micro à faire |
| 2. Raccourcir le délai de restitution | Pas commencé. Le délai est maintenant une seule constante (voir plus bas) |
| 3. Compte rendu, ADR | Pas commencé |

Aucune enceinte n'a joué pendant cette session : l'app de Baptiste diffusait (sortie par défaut sur la sortie
virtuelle, flux ouvert par l'app), et l'autre session n'était pas terminée.

## Étape 1 : le raisonnement sur l'ancrage

Le paquet de synchro (`RTPPacketBuilder.sync`) porte trois champs : `estampille courante − latence annoncée`,
un instant NTP, et l'estampille courante. Un récepteur RAOP joue l'estampille courante à :

    NTP + (latence annoncée + 11 025 trames) / 44 100

Avant ce chantier : latence annoncée 88 200, NTP = instant visé − 88 200 / 44 100. L'estampille courante sort
donc à l'instant visé **+ 0,25 s**. C'est cohérent avec les +290 à +307 ms mesurés au micro le 2026-11-02, le
reste (40 à 57 ms) étant le trajet du son et les tampons.

Pour qu'elle sorte à l'instant visé :

- **annoncer `88 200 − 11 025` = 77 175 trames** (1,75 s, la valeur d'Airfoil) ;
- **garder le NTP tel quel**, c'est-à-dire l'instant visé moins la latence **visée** entière (88 200), et non
  moins la latence annoncée. Retrancher seulement 77 175 reculerait le NTP de 0,25 s : le gain serait annulé.

Conséquence utile : **sur le fil, seul le premier champ du paquet de synchro change** (octets 4 à 7). L'instant
NTP, les estampilles et l'audio sont identiques à ce qui a été entendu et mesuré le 2026-11-02.

**Ce qui reste une hypothèse** : que la Geneva ajoute bien 11 025 trames (décrit pour shairport-sync et OwnTone,
déduit d'Airfoil, jamais isolé sur elle), et surtout que **les HomePod, en AirPlay 2, lisent ce champ de la même
façon**. Leurs résidus mesurés, semblables à celui de la Geneva, le suggèrent sans le prouver. Si une famille
ajoute la constante et l'autre non, compenser les deux décalerait la Geneva et les HomePod de 0,25 s : un écho
franc. D'où un réglage par protocole et une mesure enceinte par enceinte avant de changer le défaut.

## Ce qui est dans le code (test)

- `Sources/AudioCore/Sync/SyncLatency.swift` :
  - `SyncLatency` : latence visée (`playoutFrames`, tirée du délai de l'horloge commune) et latence annoncée
    (`announcedFrames` = visée − ajout du récepteur). **Seul endroit où le délai de restitution devient des
    trames.**
  - `ReceiverAddedLatency` : l'ajout par famille (`raopFrames`, `airPlay2Frames`). **`default` = 0 et 0** : le
    fil est celui d'avant tant que la mesure n'a pas tranché. `historicalFrames` = 11 025.
- `RAOPSender` et `AirPlay2Sender` n'ont plus de constante `latencyFrames = 88_200`. Ils calculent leur
  `syncLatency` à l'init depuis `clock.playoutDelaySeconds`. L'ancrage reçoit `playoutFrames`, le paquet
  `announcedFrames`.
- `LiveOutputSenderFactory(receiverAddedLatency:)` transmet l'ajout de chaque famille. L'app emploie le défaut.
- CLI : `--receiver-latency <trames>` (RAOP) et `--receiver-latency2 <trames>` (toutes les sorties AirPlay 2).
- Tests (`Tests/AudioCoreTests/SyncLatencyTests.swift`) : arithmétique ; paquets de synchro réellement émis par
  les deux senders contre leurs faux récepteurs (latence annoncée et instant NTP, à la microseconde, grâce à
  une horloge qui rend un instant constant) ; câblage de la fabrique. **Deux mutations vérifiées** : l'ancrage
  qui retranche la latence annoncée, et le paquet qui annonce la latence visée, font chacune échouer 3 tests.

## Mesure à faire (Baptiste sur place, pièce calme, app arrêtée)

    ./make-cli-bundle.sh                      # si le bundle date d'avant ce chantier
    scripts/measure-receiver-latency.sh       # ~11 min, fait jouer les enceintes

Le script mesure chaque enceinte seule, sans puis avec `--receiver-latency[2] 11025`, puis les trois ensemble,
sans puis avec. Résultats dans `captures/retard-2s/<date>/`, résumé en fin de sortie.

Lecture :

- son direct (premier groupe) de chaque enceinte : attendu d'environ +300 ms à environ +50 ms ;
- écarts entre enceintes : ceux de la mesure « sans », à ±5 ms ;
- une enceinte qui ne bouge pas n'ajoute pas la constante : sa famille reste à 0 ;
- **piège** : avec la compensation, une enceinte restée à +300 ms tombe à ~250 ms des autres, soit l'écart des
  salves doublées (une sur cinq, 250 ms plus tard). Replier l'enregistrement modulo 2 s en cas de doute ;
- un membre de la paire mesuré seul ne joue que son canal : normal, les salves sont sur les deux canaux.

Ensuite, si la mesure confirme : passer `ReceiverAddedLatency.default` à 11 025 pour les familles confirmées,
écoute à trois par Baptiste (aucun écho), puis remesurer le résidu et mettre à jour
`VideoSyncLatency.measuredReceiverResidualSeconds` (0,30 aujourd'hui, ~0,05 attendu), `scripts/install-app.sh`,
et vérifier la vidéo flash-bip dans Dia (recharger la page : la latence se lit à l'ouverture du flux).

## Étape 2 : ce qui dépend encore de 2 s

`SharedPlaybackClock.defaultPlayoutDelaySeconds` est désormais **la seule constante** : la latence annoncée des
deux senders, l'ancrage et `VideoSyncLatency` en découlent (test « Un délai de restitution de 1,5 s se lit dans
les deux senders »). Restent, à regarder avant de descendre :

- `AirPlay2Session.swift` : `latencyMin` 11 025 et `latencyMax` 88 200 au `SETUP`, en dur. On ne sait pas ce que
  le HomePod en fait ; à faire suivre ou non, capture à l'appui.
- `AirPlay2Retransmitter.capacity` = 512 paquets (~4 s) et l'historique RAOP : assez pour tout délai plus court.
- Le délai manuel et la compensation du lieu d'écoute s'ajoutent à l'ancrage : marge à garder positive.
- Retransmissions des HomePod avec un tampon de 2 s : p99 ~0,95 s, max ~1,08 s (`CLAUDE.md`). Pas de palier
  sous ~1,1 s sans nouvelle capture.
