# PROGRESS.md

Journal de progression par jalon. Voir docs/cahier_des_charges_diffusion_audio.md section 14.
Distinguer explicitement "validé contre mock" et "validé contre matériel réel".

**Statut matériel réel : aucun accès à ce jour.** Tout ce qui suit est validé contre les
émulateurs logiciels uniquement (`shairport-sync`, `airplay2-receiver`).

---

## OÙ ON EN EST — à lire en premier

| | |
|---|---|
| **Dernier jalon terminé** | Jalon 2 — sender RAOP (validé **contre mock** le 2026-08-06) |
| **Prochain jalon** | **Jalon 3 — sender AirPlay 2 (Apple TV/HomePod)** (prompt : CDC section 14) |
| **Dépôt** | `github.com/Erkin0xx/AirplayPersonalBridge`, branche `main` |

**Acquis réutilisables au jalon 3** : le sender RAOP (`Sources/AudioCore/RAOP/`) fournit des
briques directement réemployables — client RTSP générique (`RTSPClient`, `RTSPMessage`),
canaux UDP à port local fixé (`UDPChannel`), horloge NTP et fabrique de paquets RTP
(`RTPTransport`), rééchantillonnage vers le format d'une sortie (`RAOPResampler`). Le
jalon 3 remplace la crypto et la séquence de pairing, pas ce socle.

**Le patron à reproduire** : `RAOPSender` est un acteur qui **lit** un ring buffer et ne
l'écrit jamais, ne connaît pas la source de capture, et confine ses pannes (invariant
section 12). Le sender AirPlay 2 doit être son jumeau sur son propre ring buffer.

**Avant de coder quoi que ce soit au jalon 3** : lire `CLAUDE.md` en entier (invariants
section 12 + pièges vérifiés, dont **les trois pièges RAOP** ajoutés à ce jalon), puis le
détail du jalon 2 ci-dessous.

---

## Jalon -1 : setup initial — TERMINÉ (validé contre mock)

Date : 2026-08-05
Machine : macOS 26.5.1 (build 25F80), Apple Silicon, Swift 6.3.3, Homebrew /opt/homebrew
Réseau : en0, 192.168.1.21

### Résultat

`./setup.sh` s'exécute intégralement (exit code 0) et est idempotent (relancé 4 fois).
Les deux mocks démarrent et sont **détectables sur le réseau** :

| Mock | Outil | Service Bonjour | Résolution |
|---|---|---|---|
| Geneva-Mock | shairport-sync 5.2.1 | `_raop._tcp` ✓ | `65D15B6D3AC1@Geneva-Mock` → `MacBook-Pro-de-Erki.local:5000` |
| ApTV-HomePod-Mock | airplay2-receiver | `_airplay._tcp` ✓ | `ApTV-HomePod-Mock._airplay.local:7000` |

Vérification reproductible : `./run-mocks.sh` (script ajouté, voir ci-dessous).

### Problèmes rencontrés et résolutions

Le `setup.sh` fourni ne passait pas en l'état sur cette machine. Cinq blocages, tous
corrigés dans le script (il reste idempotent et relançable) :

1. **`owntone` n'existe plus dans homebrew-core** (ni `owntone`, ni `forked-daapd`).
   Sous `set -euo pipefail`, le `brew install` groupé tuait le script avant tout le reste.
   → Résolution : OwnTone sorti du groupe et rendu **non bloquant**. Il ne sert qu'au
   jalon 0, qui nécessite de toute façon le matériel réel et est déjà décalé. À installer
   depuis les sources le moment venu. Aucune conséquence sur les jalons 1 à 5 (CDC
   section 5 : OwnTone n'est jamais une dépendance runtime).

2. **Wireshark (cask) exige un `sudo` interactif** pour son pkg "add to system path",
   impossible en session non interactive.
   → Résolution : rendu non bloquant dans le script. Wireshark n'est requis qu'au jalon 2
   (comparaison de trafic). **Installé manuellement par Baptiste depuis, en fin de
   jalon -1** : Wireshark 4.6.7, avec `tshark` dans le PATH et capture possible sans `sudo`
   (membre du groupe `access_bpf`). Le prérequis du jalon 2 est donc satisfait.

3. **PEP 668 / "externally-managed-environment"** : le Python 3.14 de Homebrew refuse
   `pip3 install virtualenv` et `pip3 install pyatv` en global.
   → Résolution : `python3 -m venv` (stdlib) au lieu d'installer `virtualenv`, et pyatv
   installé dans un venv dédié `tools/pyatv-venv/` au lieu du Python système.

4. **`av==8.1.0` (pin de requirements.txt d'airplay2-receiver) ne compile pas** sur
   Python 3.12+ : son `setup.py` importe `distutils.msvccompiler`, supprimé de la stdlib.
   → Résolution : pin relâché **pour cette seule dépendance** (av 18.0.0 installé), le
   reste de `requirements.txt` est respecté tel quel. `av` ne sert qu'au décodage audio
   côté récepteur (`ap2/connections/audio.py`), c'est du code de mock, pas du code projet.
   Également corrigé : `pip install --global-option=...` pour pyaudio, option supprimée de
   pip ≥ 23.1, remplacée par `CFLAGS`/`LDFLAGS`.

5. **shairport-sync ne démarrait pas**, deux causes distinctes :
   - Le script écrivait la config dans `etc/shairport-sync.conf`, alors que le binaire lit
     `etc/shairport-sync/shairport-sync.conf` (sous-dossier). Le mock démarrait donc sans
     le nom "Geneva-Mock". → Chemin corrigé.
   - Backend audio par défaut `pulseaudio` (choix de compilation Homebrew), qui échoue sans
     serveur PulseAudio : *"pa context is not good -- Connection refused"*.
     → Backend forcé à `ao` (driver `macosx`).

### Décision prise, hors CDC

**Le récepteur AirPlay natif de macOS a été désactivé** (Réglages Système > Général >
AirDrop et Handoff > Récepteur AirPlay : OFF). Il occupait le port 5000, ce qui empêchait
shairport-sync de démarrer. Changer de port n'est pas une option : cette build 5.2.1 ignore
`port`/`-p` en mode AirPlay 1 (vérifié — le log annonce `rtsp listening port is 5000` même
lancé avec `-p 5010`). Décision validée avec Baptiste.
**À réactiver manuellement si le Mac doit redevenir une cible AirPlay.**

### Ajouts au dépôt, hors CDC

- **`.gitignore`** : exclut `tools/` (clone + venv), `.build/`, les dumps `*.wav`/`*.pcap`,
  et surtout `credentials/` — les credentials de pairing du jalon 3 ne doivent jamais être
  committés.
- **`run-mocks.sh`** : lance les deux mocks et vérifie leur annonce Bonjour
  (`start` / `check` / `stop`). Rend la vérification du jalon -1 reproductible en une
  commande, et servira à chaque session des jalons 2 et 3.
- **Specs déplacées à la racine vers `docs/`**, conformément à l'étape 8 du guide
  d'installation et aux chemins que le CDC référence lui-même (section 14).

### Ce qui reste ouvert

- ~~Wireshark non installé~~ — **résolu en fin de jalon -1** (4.6.7, `tshark` disponible,
  capture sans `sudo`). Plus de blocage pour le jalon 2.
- **OwnTone non installé** — à compiler depuis les sources au jalon 0.
- Le mock AirPlay 2 émet un warning zeroconf non fatal au démarrage
  (`Error with socket ... No route to host` sur l'IPv6 link-local) ; l'enregistrement mDNS
  aboutit malgré tout et le service est résolvable. À re-regarder si le jalon 3 montre des
  problèmes de découverte.
- Rappel CDC/guide section 3.3 : un handshake qui passe contre `airplay2-receiver`
  (expérimental de son propre aveu) n'est **pas** une garantie contre le vrai firmware Apple.

---

## Jalon 1 : capture Core Audio — TERMINÉ (validé en local, sans sortie AirPlay)

Date : 2026-08-05

### Test DRM — le point demandé en priorité par le jalon (CDC section 6)

**Résultat : aucun blocage DRM constaté. Le Process Tap capte le contenu protégé.**

| Source | Résultat | Mesure |
|---|---|---|
| Apple Music (« Stolen Dance », vol. 100) | **CAPTÉ** | 6,02 s, 99,1 % d'échantillons non nuls, crête −29,7 dBFS |
| Netflix, vidéo en lecture (Dia/Chromium) | **CAPTÉ** | 12,01 s, 96,0 % non nuls, crête −4,3 dBFS |

Les deux `.wav` ont été relus à l'oreille via `afplay` : c'est bien l'audio attendu, pas du
bruit ni du silence. Le test Netflix a été fait dans Dia plutôt que Safari (pas de session
ouverte côté Safari) — sans incidence, ce qui compte est le contenu protégé, pas le
navigateur.

Cela confirme l'hypothèse de la section 4.4 du CDC : le DRM protège le fichier chiffré, pas
les échantillons PCM déjà décodés au moment où ils atteignent le graphe Core Audio.
**Conséquence : pas besoin de la piste de repli BlackHole.**

Nuance à garder : constaté sur macOS 26.5.1 en août 2026, sur ces deux services. Ce n'est
pas une garantie qu'Apple n'ajoutera pas une restriction de politique plus tard, l'API
restant récente.

### Les 3 modes de capture

Tous validés, `.wav` produit et relu via `afplay` :

| Mode | Commande | Résultat |
|---|---|---|
| Système global | `./audiocap 5 out.wav` | 5,00 s, 99,5 % non nuls, −4,1 dBFS |
| Application ciblée | `./audiocap --app Music 6 out.wav` | 6,04 s, 98,4 % non nuls, −31,7 dBFS |
| Entrée physique | `./audiocap --mode input 6 out.wav` | 6,00 s, mono 48 kHz, −46,8 dBFS (bruit ambiant) |

**Isolation du mode application prouvée** : Music mis en pause pendant qu'un bruit fort
jouait depuis un autre process → silence numérique strict (0 échantillon non nul sur 4 s).
Le tap ne capte que l'application ciblée, conformément au CDC 4.2.

Le mode entrée physique capte le micro interne ; la validation avec l'ampli tourne-disque
demandera d'être physiquement sur place (déjà prévu au guide, section 1).

### Ring buffer lock-free (invariant section 12)

`AudioRingBuffer`, SPSC lock-free : allocation unique à l'init, `write`/`read` sans verrou,
sans allocation et non bloquants, index atomiques en acquire/release. En saturation, le
producteur temps réel abandonne des trames et les comptabilise plutôt que de bloquer.

6 tests unitaires, tous verts, dont un test producteur/consommateur **concurrent** sur
20 000 échantillons vérifiant qu'aucune valeur n'est corrompue ni réordonnée — c'est lui qui
justifie l'ordonnancement acquire/release.

### Problèmes rencontrés et résolutions

Le gros du temps est passé sur un symptôme unique et trompeur : **le tap « fonctionnait »
(callbacks appelés au bon rythme, buffers de la bonne taille) mais ne livrait que des
zéros**. Trois causes distinctes empilées, chacune produisant exactement le même symptôme :

1. **Mauvais UID de sous-tap.** `kAudioSubTapUIDKey` attend `CATapDescription.uuid`, et non
   la valeur lue via `kAudioTapPropertyUID`. Trouvé en comparant au projet de référence
   `insidegui/AudioCap` (CDC section 10) après épuisement des hypothèses.
2. **Agrégat sans horloge.** Il manquait le périphérique de sortie courant en
   `MainSubDevice` et dans `SubDeviceList`.
3. **Autorisation TCC.** `kTCCServiceAudioCapture` est **distincte** du micro, et
   `AVCaptureDevice.authorizationStatus(for: .audio)` — que j'utilisais — renvoie l'état du
   micro. Elle répondait `authorized` alors que le tap n'était pas autorisé. Résolu en
   passant par les SPI privées de TCC, comme AudioCap.

Deux pièges d'outillage se sont ajoutés, chacun ayant produit de faux résultats négatifs :
- **Exécuter le binaire interne du bundle fait perdre l'autorisation.** Il faut passer par
  `open` (wrapper `./audiocap` ajouté pour ça).
- **Chaque re-signature révoque l'autorisation.** Plusieurs tests « échoués » testaient en
  réalité un binaire redevenu non autorisé après rebuild.

Erreur de méthode à noter : mon script d'analyse supposait du stéréo en dur et annonçait
donc une durée deux fois trop courte sur les captures mono. J'ai cru à une troncature de la
capture avant de vérifier l'en-tête réel du `.wav` — la capture était correcte depuis le
début. `analyse-wav.py` lit maintenant le bloc `fmt `.

### Décisions prises, hors CDC

- **Dépendance `swift-atomics`** (bibliothèque officielle Apple) pour le ring buffer.
  L'alternative, appeler les atomiques C à la main, contredirait la règle « aucun pointeur C
  manipulé à nu en dehors d'un wrapper » (section 12).
- **Plateforme du package fixée à macOS 15** alors que le Process Tap exige 14.2 : SwiftPM
  ne sait exprimer que des versions majeures ici, `.v14` valant 14.0. `ProcessTapCapture`
  porte en plus un `@available(macOS 14.2)` explicite.
- **Bundle `.app` signé pour un outil CLI**, hors `.build/` (effacé par `swift package
  clean`). Sans identité de code stable, macOS ne peut accorder aucune autorisation.
- **Récepteur AirPlay natif de macOS toujours désactivé** (décision du jalon -1).
- **Push git automatique délégué à Claude** par Baptiste, ainsi que l'autonomie sur
  l'exécution des commandes et des autorisations (noté dans `CLAUDE.md`).

### Ce qui reste ouvert

- **Le mode entrée physique n'a été testé qu'avec le micro interne.** Le cas réel visé
  (sortie d'ampli tourne-disque via interface USB) demande d'être sur place.
- **Le CLI n'affiche sa sortie que via le wrapper `./audiocap`** : `open` ne relaie ni
  stdout ni stderr, la sortie transite par `/tmp/audiocap-output.txt`. Fonctionnel, mais peu
  élégant ; à revoir au jalon 5, où l'app aura une vraie interface.
- **La taille du ring buffer (48 000 trames, 1 s) est un choix provisoire**, à réévaluer au
  jalon 2 en fonction de la gigue réelle du sender réseau.
- Le CDC (section 11) suggérait de commencer par le mode entrée physique, le mieux
  documenté. J'ai suivi l'ordre imposé par le prompt du jalon 1, qui exige le test DRM en
  premier — donc le Process Tap d'abord. Sans conséquence, les trois modes sont faits.

---

## Jalon 2 : sender RAOP (Geneva) — TERMINÉ (validé CONTRE MOCK, pas contre la vraie Geneva)

Date : 2026-08-06

> **Portée de la validation.** Tout ce qui suit est mesuré contre `shairport-sync` 5.2.1
> (mock « Geneva-Mock »), sur la machine locale. **La vraie enceinte Geneva n'a jamais été
> sollicitée** : aucun accès au matériel réel à ce jour. Un handshake qui passe contre
> shairport-sync ne garantit pas le comportement d'un récepteur matériel, qui peut être plus
> strict sur les URI de session, les délais, ou le contenu exact du SDP.

### Ce qui fonctionne

Le CLI diffuse le flux capturé vers le mock, de bout en bout :

```
./audiocap --browse              # liste les récepteurs _raop._tcp
./audiocap --airplay Geneva 25   # capture système -> RAOP pendant 25 s
./audiocap --airplay Geneva --volume -15 30
```

Séquence RTSP observée en capture Wireshark, toutes réponses `200 OK` :

| # | Requête | Réponse notable |
|---|---|---|
| 1 | `ANNOUNCE` (SDP : ALAC, `rsaaeskey`, `aesiv`) | 200 OK |
| 2 | `SETUP` (ports locaux annoncés) | `server_port=6003;control_port=6001;timing_port=6002` |
| 3 | `RECORD` (`RTP-Info: seq=…;rtptime=…`) | `Audio-Latency: 11025` |
| 4 | `SET_PARAMETER` (volume) | 200 OK |
| 5 | `TEARDOWN` | 200 OK |

Qualité du flux RTP mesurée sur une session de 25 s (3 140 paquets audio) :

| Mesure | Valeur | Attendu |
|---|---|---|
| Ruptures de numéro de séquence | **0** | 0 |
| Intervalle moyen entre paquets | **7,983 ms** | 7,982 ms (352 trames à 44,1 kHz) |
| Intervalle médian | 8,795 ms | ~7,98 ms |
| Gigue p95 / max | 13,0 / 28,4 ms | << 2 s de tampon récepteur |
| Taille des paquets audio | **uniforme**, 1 431 o UDP | 8 + 12 RTP + 1 411 ALAC |
| Trames perdues **en diffusion** | **0** | 0 |
| Paquets de synchro / réponses de timing | 25 / 2 | périodiques |

Le récepteur interroge bien le canal de timing et le sender lui répond : c'est le point
d'ancrage temporel dont le jalon 4 aura besoin (CDC 4.5).

**41 tests unitaires, tous verts**, dont un aller-retour complet
PCM → ALAC → AES → AES⁻¹ → ALAC⁻¹ → PCM qui vérifie que le signal ressort **bit pour bit
identique**. Ce test a une propriété importante : son décodeur reproduit l'ordre de lecture
de `alac.c` de shairport-sync, pas les hypothèses de mon encodeur — sans quoi il aurait
validé n'importe quoi (voir le défaut n°2 ci-dessous, qu'il n'attrapait pas dans sa
première version).

### Respect de l'invariant section 12

- `RAOPSender` reçoit un `AudioRingBuffer` et un format, **rien d'autre** : il ne connaît ni
  le mode de capture, ni l'existence d'un autre sender.
- Il **lit** le ring buffer et ne l'écrit jamais. Tout le traitement (conversion, encodage,
  chiffrement) opère sur une copie extraite dans un tampon propre au sender. Deux tests
  couvrent ce point, dont un qui vérifie que deux pipelines de sortie distincts n'interfèrent
  pas.
- Les erreurs de diffusion sont comptées et la boucle continue : une panne réseau côté
  Geneva n'interrompt ni la capture ni une autre sortie.
- Le rééchantillonnage tourne dans la tâche du sender, en aval du ring buffer, jamais dans
  le callback temps réel — emplacement explicitement autorisé par le CDC 4.5.

### Les trois défauts trouvés, et comment

Chacun produisait un symptôme trompeur ; aucun n'aurait été trouvé sans mesure directe.

**1. Perte silencieuse de 6,5 % du flux au rééchantillonnage.**
`AVAudioConverter.convert` ne rend **jamais plus de 4 096 trames par appel**, quelle que soit
la capacité du tampon de sortie, et signale alors `.inputRanDry` **tout en retenant encore
des trames**. Ma boucle sortait sur ce statut. Sur 4 800 trames d'entrée, 4 096 sortaient au
lieu de 4 410 — un défaut permanent, audible, que rien ne signalait à l'exécution. Trouvé en
sondant le convertisseur hors du projet, après qu'un test de ratio ait échoué de 314 trames.
→ Corrigé (on ne s'arrête que sur un appel réellement improductif) + **test de régression**
sur 10 blocs consécutifs.

**2. En-tête ALAC de 11 bits au lieu de 20.**
Le décodeur lit 4 bits puis **12 bits** d'inutilisé avant `hasSize` ; j'écrivais
`channels - 1` sur 3 bits puis 4 bits d'inutilisé, comme le décrivent plusieurs
documentations informelles d'ALAC. Ces 3 bits appartiennent en réalité au *tag d'élément* du
bitstream, que RAOP ne transporte pas. Avec 9 bits manquants, `isNotCompressed` était lu à 0
et le récepteur partait décoder une trame compressée inexistante :
`FIXME: unhandled prediction type`. Trouvé en lisant `alac.c` de shairport-sync, après avoir
constaté que mon propre test d'aller-retour ne voyait rien — il rejouait mes hypothèses.
→ Corrigé, et le décodeur de test réaligné sur `alac.c` pour qu'il soit capable d'attraper
ce genre d'écart.

**3. Flux émis en rafales au lieu d'être cadencé.**
La boucle émettait *tous* les paquets disponibles avant de dormir. Mesuré : intervalle médian
de **0,69 ms pour 7,98 ms théoriques**, avec des pauses allant jusqu'à **944 ms**. Un
récepteur matériel avec un tampon plus petit que shairport aurait décroché.
→ Corrigé (un paquet par tour, à l'échéance). Après correction : médian 8,795 ms, max
28,4 ms.

Un quatrième point, mineur : le `TEARDOWN` et le `SET_PARAMETER` construisaient une URI
`/stream` au lieu de réutiliser l'URI de session. shairport-sync l'accepte, mais les
récepteurs matériels rejettent couramment un `TEARDOWN` dont l'URI ne correspond à aucune
session — et la session reste alors bloquée côté récepteur. Corrigé avant d'avoir pu le
constater, précisément parce que le mock ne l'aurait pas signalé.

### Décisions prises, hors CDC

- **ALAC en trames non compressées.** Le codec est sans perte dans les deux cas : la qualité
  audio est rigoureusement identique, seul le débit change (~1,4 Mbit/s au lieu de
  ~0,8 Mbit/s), ce qui est sans conséquence sur un réseau local. Cela évite d'embarquer une
  implémentation de prédiction linéaire et de codage de Rice dont une erreur produirait une
  corruption audio silencieuse. Si le jalon 4 montre que ce débit gêne, le passage à la
  compression se fait derrière la même interface.
- **Clé publique RAOP en dur.** Ce n'est pas un contournement : c'est la clé *publique* que
  tout récepteur annonçant `et=1` attend, publiée depuis 2011 et identique dans
  shairport-sync, OwnTone et pyatv. Sans elle, aucun sender ne peut parler à un récepteur
  RAOP classique. Elle est reconstruite depuis modulus et exposant plutôt que collée en
  base64, pour rester vérifiable à la lecture.
- **Socket BSD plutôt que `NWConnection` pour l'UDP.** RAOP exige d'émettre *et* de recevoir
  sur le **même port local**, connu **avant** le `SETUP`. Le Network framework ne l'exprime
  pas directement pour UDP. Toute la manipulation du descripteur est confinée à `UDPChannel`,
  qui le referme dans son `deinit` (invariant section 12).
- **`.claude/settings.json` ajouté** à la demande de Baptiste (permissions d'outils).
- **Arriéré de capture écarté au démarrage de la diffusion** : la capture tourne pendant la
  négociation (~4 s), le ring buffer déborde donc avant que le sender ne draine. Sans cela,
  la diffusion démarrerait avec plusieurs secondes de retard sur le direct.

### Validation Wireshark : ce qui a pu être fait, et ce qui n'a pas pu

Le prompt du jalon demandait une comparaison avec **une session Airfoil ou macOS natif
fonctionnelle vers le même appareil**. **Cette comparaison n'a pas pu être faite**, pour des
raisons qui tiennent toutes à l'outillage, pas au sender :

- **macOS natif** : **vérifié par Baptiste le 2026-08-06, Wireshark ouvert — le mock Geneva
  n'apparaît pas du tout dans le menu son.** macOS ne liste que `ApTV-HomePod-Mock`
  (`_airplay._tcp`, AirPlay 2) et ignore Geneva-Mock (`_raop._tcp`, AirPlay 1) : macOS récent
  ne propose comme sortie que les récepteurs AirPlay 2. Ce n'est donc pas une contrainte
  d'outillage contournable, mais une **impossibilité de principe contre ce mock** : la
  comparaison avec macOS natif ne pourra se faire **qu'avec la vraie Geneva**.
  Le mock Apple TV n'est pas un substitut — il parle AirPlay 2, protocole différent, sans
  rapport avec le sender RAOP de ce jalon (il servira au jalon 3).
- **Airfoil** (présent dans `~/Downloads`) : son interface de script exige l'autorisation
  « Accessibilité », un interrupteur graphique. Il installe en outre un pilote audio qui
  demande d'accepter une licence.
- **pyatv 0.18.0** (installé en secours dans `tools/pyatv313/`, venv Python 3.13 — celui du
  jalon -1 est cassé sur Python 3.14) : **échoue contre ce mock**. Il envoie un
  `GET /info` AirPlay 2, shairport-sync 5.2.1 répond `200 OK` avec un **corps vide**, et
  pyatv analyse ce corps vide comme un plist binaire → `InvalidFileException`. Vérifié en
  traçant l'échange. C'est une incompatibilité pyatv/shairport, extérieure au projet.

**Ce qui a été fait à la place** est une validation directe plutôt que comparative : la
séquence RTSP complète et la qualité du flux RTP ont été extraites et mesurées depuis la
capture (tableaux ci-dessus), et l'exactitude du contenu audio est établie par le test
d'aller-retour bit à bit. C'est plus faible qu'une comparaison à un sender de référence sur
un point précis : **rien ne garantit qu'un détail attendu par le firmware Apple mais toléré
par shairport-sync ne manque pas**. La comparaison reste donc à faire, et elle est le
meilleur usage de la première session avec la vraie Geneva.

### Ce qui reste ouvert

- **Rien n'a été validé contre la vraie Geneva.** C'est la limite principale de ce jalon.
- **La comparaison Wireshark avec un sender de référence reste à faire, et elle est
  reportée au premier accès à la vraie Geneva.** Tentée le 2026-08-06 : macOS ne propose
  pas le mock Geneva comme sortie (voir ci-dessus), donc aucun sender de référence ne peut
  atteindre ce mock sur cette machine. Ce n'est plus une question d'outillage à débloquer.
  **Marche à suivre le jour J** : lancer `tshark -i en0 -f "tcp port 5000 or udp portrange
  6000-6100"` (la vraie Geneva étant sur le réseau, c'est bien `en0` et non `lo0`),
  sélectionner la Geneva dans le menu son de macOS, laisser jouer ~30 s, puis rejouer la
  même séquence avec `./audiocap --airplay Geneva 30` et comparer les deux traces.
- **~11 erreurs de décodage côté mock, groupées à la fin de chaque session.** Elles
  n'apparaissent jamais pendant la diffusion (log vérifié : elles sont contiguës en fin de
  fichier, jamais entrelacées avec les 40 s de flux), leur nombre ne croît pas avec la durée
  (14 sur 15 s, 12 sur 40 s), et tous les paquets émis sont de taille rigoureusement
  uniforme. Interprétation retenue : le mock décode un reliquat de tampon au moment du
  `TEARDOWN`. **Non élucidé avec certitude** : à re-regarder si la vraie Geneva produit un
  artefact audible en fin de lecture.
- **Le mock quitte après chaque session.** Il est stable au repos (vérifié) et ne quitte
  qu'après un `TEARDOWN`. Sans conséquence pour la validation, mais il faut relancer
  `./run-mocks.sh` entre deux essais.
- **Aucune reconnexion automatique.** Le CDC (section 8) l'exige : une perte réseau
  temporaire doit être rattrapée sans redémarrer l'application. Le sender remonte
  aujourd'hui l'erreur et continue sa boucle, mais ne rétablit pas la session RTSP. À traiter
  au jalon 4 ou 5.
- **Le volume n'est réglé qu'au démarrage.** `setVolume` existe et fonctionne en cours de
  session, mais le CLI ne l'expose pas dynamiquement — l'interface du jalon 5 le fera.
- **La taille du ring buffer (1 s) est confirmée suffisante en régime établi** : 0 trame
  refusée pendant la diffusion sur toutes les sessions mesurées. Les refus observés
  (~209 000) sont intégralement imputables à la fenêtre de négociation, pendant laquelle la
  capture tourne sans consommateur ; le CLI les distingue désormais explicitement.

---
