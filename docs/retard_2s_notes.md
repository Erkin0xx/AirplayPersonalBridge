# Retard de bout en bout : notes de la session « retard 2 s »

Notes de travail du chantier `docs/prompt_retard_2s.md`, tenues à part parce qu'une autre session réécrit
`PROGRESS.md`, `CLAUDE.md` et `README.md` à la clôture du jalon 5. À fusionner ensuite dans `CLAUDE.md`
(« Retard de bout en bout et vidéo ») et `PROGRESS.md`.

Niveaux de preuve : **test** (`swift test`, faux récepteurs en boucle locale), **mesuré** (micro), **entendu**
(Baptiste).

## État au 2026-11-10, 0 h 10

| Étape | État |
|---|---|
| 1. Retirer la constante du récepteur (~0,25 s) | **Mesuré** sur les trois enceintes, activé par défaut. **Pas encore entendu** en musique, ni vérifié dans Dia |
| 2. Raccourcir le délai de restitution | Pas commencé. Le délai est maintenant une seule constante (voir plus bas) |
| 3. Compte rendu, ADR | Pas commencé |

## Étape 1 : mesure du 2026-11-09 (micro du Mac, à table, volume AirPlay −10, clics à −20 dBFS)

Son direct (premier groupe de `scripts/measure-clicks.py`), écart à l'instant visé, enceinte seule :

| Enceinte | Sans compensation | Avec 11 025 trames | Gain |
|---|---|---|---|
| Geneva (RAOP) | +292,4 ms | +43 ms, **après ~45 s de convergence** | 249 ms |
| HomePod « Salon » | +289,7 ms | +40,1 ms | 249,6 ms |
| HomePod « Salon (2) » | +295,9 ms | +46,5 ms | 249,4 ms |
| Écart entre enceintes | 6,2 ms | 6,4 ms | |

Les trois ensemble : deux groupes directs à +293,2 et +299,1 ms sans, +41,8 et +48,5 ms avec (écart 6,0 puis
6,7 ms), et plus aucune arrivée forte vers +300 ms.

- **L'hypothèse tient pour les deux protocoles** : la Geneva et les HomePod ajoutent bien 11 025 trames à la
  latence annoncée, et lisent tous le premier champ du paquet de synchro.
- **La Geneva converge** : avec 77 175 trames annoncées, elle démarre 8 à 20 ms **en avance** (+23 à +35 ms) et
  glisse jusqu'à +43 ms en 35 à 50 s, puis s'y tient. Sans compensation elle était stable dès la première salve.
  Pendant cette première minute, l'écart avec les HomePod monte donc jusqu'à ~20 ms, à la limite du seuil.
  Cause inconnue. **À écouter** : un début de morceau à trois.
- **Piège d'analyse** : cette glissade étale les détections, et `measure-clicks.py` rend alors un seul groupe
  énorme (σ 37 à 73 ms, 700 à 1 500 détections) qui ressemble à du bruit de pièce. Ce n'en était pas : suivre
  la première arrivée forte salve par salve (`--json`, champ `salves`) montre la glissade. Deux mesures de
  « Salon » ont, elles, bien été gâchées par du bruit dans la pièce, et refaites.
- Le volume par défaut (−20) était trop faible pour le micro : −10 dans le script. À −10, chaque réflexion forme
  son groupe (30 à 40 groupes) : seul le premier compte.

Enregistrements : `captures/retard-2s/etape1-fort`, `etape1-bis`, `etape1-ter` (non versionnés).

**Suite donnée** : `ReceiverAddedLatency.default` = 11 025 pour les deux familles, et
`VideoSyncLatency.measuredReceiverResidualSeconds` = 0,045 (la sortie virtuelle annonce 2,045 s au lieu de 2,30).

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

C'était une hypothèse avant la mesure ci-dessus, pour la Geneva comme pour les HomePod. Le réglage reste par
protocole : une famille compensée sans l'autre les mettrait à 0,25 s l'une de l'autre.

## Ce qui est dans le code (test)

- `Sources/AudioCore/Sync/SyncLatency.swift` :
  - `SyncLatency` : latence visée (`playoutFrames`, tirée du délai de l'horloge commune) et latence annoncée
    (`announcedFrames` = visée − ajout du récepteur). **Seul endroit où le délai de restitution devient des
    trames.**
  - `ReceiverAddedLatency` : l'ajout par famille (`raopFrames`, `airPlay2Frames`). **`default` = 11 025 pour
    les deux** depuis la mesure. `0` rend le fil d'avant.
- `RAOPSender` et `AirPlay2Sender` n'ont plus de constante `latencyFrames = 88_200`. Ils calculent leur
  `syncLatency` à l'init depuis `clock.playoutDelaySeconds`. L'ancrage reçoit `playoutFrames`, le paquet
  `announcedFrames`.
- `LiveOutputSenderFactory(receiverAddedLatency:)` transmet l'ajout de chaque famille. L'app emploie le défaut.
- CLI : `--receiver-latency <trames>` (RAOP) et `--receiver-latency2 <trames>` (toutes les sorties AirPlay 2).
- Tests (`Tests/AudioCoreTests/SyncLatencyTests.swift`) : arithmétique ; paquets de synchro réellement émis par
  les deux senders contre leurs faux récepteurs (latence annoncée et instant NTP, à la microseconde, grâce à
  une horloge qui rend un instant constant) ; câblage de la fabrique. **Deux mutations vérifiées** : l'ancrage
  qui retranche la latence annoncée, et le paquet qui annonce la latence visée, font chacune échouer 3 tests.

## Refaire la mesure

    ./make-cli-bundle.sh
    VOLUME=-10 scripts/measure-receiver-latency.sh    # ~11 min, fait jouer les enceintes

Chaque enceinte seule puis les trois, avec `--receiver-latency[2] 0` puis 11 025. Pièce silencieuse, app
arrêtée. Un membre de la paire mesuré seul ne joue que son canal : normal, les salves sont sur les deux canaux.

## Reste à faire pour clore l'étape 1

- Écoute à trois par Baptiste, musique, début de morceau compris : aucun écho.
- Vidéo flash-bip dans Dia, page rechargée : image et son calés avec 2,045 s annoncés.

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
