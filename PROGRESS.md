# PROGRESS.md

Journal de progression par jalon. Voir docs/cahier_des_charges_diffusion_audio.md section 14.
Distinguer explicitement "validé contre mock" et "validé contre matériel réel".

**Statut matériel réel : aucun accès à ce jour.** Tout ce qui suit est validé contre les
émulateurs logiciels uniquement (`shairport-sync`, `airplay2-receiver`).

---

## OÙ ON EN EST — à lire en premier

| | |
|---|---|
| **Dernier jalon terminé** | Jalon 3 — sender AirPlay 2 (validé **contre mock** le 2026-08-06) |
| **Prochain jalon** | **Jalon 4 — synchronisation et dérive** (prompt : CDC section 14) |
| **Dépôt** | `github.com/Erkin0xx/AirplayPersonalBridge`, branche `main` |

**Les deux sorties diffusent désormais en parallèle**, ce qui est l'objectif fonctionnel du
projet (CDC section 2) :

```
./audiocap --airplay Geneva --airplay2 ApTV 15
```

Mesuré sur 15 s : 1 884 paquets RAOP et 1 882 paquets AirPlay 2, **0 erreur de part et
d'autre**. Une panne sur une sortie n'affecte pas l'autre (vérifié en visant un récepteur
RAOP inexistant : la sortie AirPlay 2 a continué sans dégradation).

**Acquis réutilisables au jalon 4** : `RTSPClient`, `UDPChannel`, `RTPTransport` (horloge
NTP), `RAOPResampler` sont partagés par les deux senders. Le canal de timing RAOP répond
déjà aux requêtes du récepteur, et le `SETUP` AirPlay 2 négocie `timingProtocol=NTP` : ce
sont les deux points d'ancrage dont le jalon 4 aura besoin (CDC 4.5).

**Le patron, respecté par les deux senders** : un acteur qui **lit** son propre ring buffer
et ne l'écrit jamais, ne connaît pas la source de capture, ignore l'autre sender, et confine
ses pannes (invariant section 12).

**Avant de coder quoi que ce soit au jalon 4** : lire `CLAUDE.md` en entier (invariants
section 12 + pièges vérifiés, dont **les trois pièges RAOP** du jalon 2 et **le piège SRP**
du jalon 3), puis le détail des jalons 2 et 3 ci-dessous.

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

- **macOS natif** : **possible, contrairement à ce qui était d'abord conclu.** Le menu son
  de la barre de menus n'affiche pas Geneva-Mock, ce qui m'avait fait écrire à tort que
  macOS ne savait pas parler à un récepteur AirPlay 1. **Le sélecteur AirPlay d'Apple Music,
  lui, le liste bien** (vérifié par Baptiste le 2026-08-06, capture d'écran à l'appui), et
  une capture montre macOS lui envoyant un `OPTIONS * RTSP/1.0` auquel le mock répond
  `200 OK`.
  **Mais la comparaison reste impossible contre ce mock** : refaite en ne cochant que
  Geneva-Mock, la capture (33 s, `captures/genavamock uniquement.pcapng`) ne contient que
  **4 messages RTSP** — deux `OPTIONS *` de macOS, deux `200 OK` du mock — et **aucun
  `ANNOUNCE`, aucun paquet audio**. macOS tente, s'arrête après l'`OPTIONS`, recommence, puis
  abandonne. Côté utilisateur cela se voit : sortie affichée comme sélectionnée, aucun son
  nulle part, lecture qui repart au début à chaque bascule.

  **Cause non élucidée.** Une première explication — défi RSA `Apple-Challenge` resté sans
  réponse — a été proposée puis **infirmée** : les `OPTIONS` capturés ne portent aucun
  en-tête `Apple-Challenge`, et shairport sait de toute façon y répondre (`rtsp.c`). Le refus
  vient de macOS, sans message. À ne pas confondre avec un défaut du sender du projet : mon
  sender négocie, lui, une session complète avec ce même mock.

  **Écart concret relevé au passage, et c'est le vrai apport de cette capture** : macOS
  envoie un `OPTIONS *` (avec `User-Agent: Music/1.6.5`, `Client-Instance`, `DACP-ID`,
  `Active-Remote`) **avant** l'`ANNOUNCE`. **Mon sender n'envoie pas d'`OPTIONS` du tout** et
  attaque directement par `ANNOUNCE`. shairport-sync l'accepte, mais rien ne garantit que la
  vraie Geneva soit aussi tolérante. À vérifier en priorité au premier essai matériel, et à
  ajouter si besoin — c'est peu coûteux.
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

## Jalon 3 : sender AirPlay 2 (Apple TV/HomePod) — TERMINÉ (validé CONTRE MOCK)

Date : 2026-08-06

> **Portée de la validation.** Tout ce qui suit est mesuré contre `airplay2-receiver`
> (mock « ApTV-HomePod-Mock »), sur la machine locale. **Aucun Apple TV ni HomePod réel n'a
> été sollicité** : aucun accès au matériel à ce jour.
>
> Cette réserve est plus forte ici qu'au jalon 2, et le CDC (section 10) la formule
> explicitement : `airplay2-receiver` est **expérimental de son propre aveu**
> (« experimental, yet fully functional », il n'implémente pas tous les protocoles ni toutes
> les méthodes d'authentification). **Un handshake qui passe contre cet émulateur ne
> garantit pas le fonctionnement contre le vrai firmware Apple.** Le point le plus incertain
> est identifié et documenté ci-dessous : le mode de pairing.

### Ce qui fonctionne

```
./audiocap --browse2                              # liste les récepteurs _airplay._tcp
./audiocap --airplay2 ApTV 30                     # capture système -> AirPlay 2
./audiocap --airplay Geneva --airplay2 ApTV 30    # LES DEUX SORTIES EN PARALLÈLE
```

Séquence observée en capture (`captures/jalon3-airplay2-session.pcapng`) :

| # | Requête | Réponse |
|---|---|---|
| 1 | `POST /pair-setup` (TLV8, M1, méthode 0 + drapeau transitoire) | 200 OK, M2 (sel 16 o, B 384 o) |
| 2 | `POST /pair-setup` (TLV8, M3, A 384 o + preuve 64 o) | 200 OK, M4 (preuve serveur) |
| — | *bascule du canal en chiffré* | *tout le reste est illisible en capture* |
| 3 | `SETUP` (plist binaire, **sans** `streams`) | `eventPort` |
| 4 | `SETUP` (plist binaire, **avec** `streams`) | `dataPort`, `controlPort`, `streamID` |
| 5 | `SET_PARAMETER` (volume) | 200 OK |
| 6 | `RECORD` (`RTP-Info: seq=…;rtptime=…`) | 200 OK |
| 7 | `TEARDOWN` | 200 OK |

**La capture prouve visuellement le chiffrement** : les deux premiers `POST /pair-setup`
sont lisibles en clair, et à partir du message suivant plus aucun octet n'est interprétable.

Qualité du flux RTP mesurée sur une session de 10 s (1 254 paquets audio) :

| Mesure | Valeur | Attendu |
|---|---|---|
| Ruptures de numéro de séquence | **0** | 0 |
| Intervalle moyen entre paquets | **7,985 ms** | 7,982 ms (352 trames à 44,1 kHz) |
| Intervalle médian | 8,994 ms | ~7,98 ms |
| Gigue p95 / max | 12,7 / 22,3 ms | << tampon récepteur |
| Taille des paquets audio | **uniforme**, 1 447 o UDP | 8 + 12 RTP + 1 411 ALAC + 16 étiquette |
| Trames perdues **en diffusion** | **0** | 0 |

**79 tests unitaires, tous verts** (41 du jalon 2 + 38 ajoutés). Les 41 du jalon 2 sont
restés verts en permanence : le socle partagé n'a pas été cassé.

### Les quatre bibliothèques C, vendues et non réécrites (CDC 4.4)

Dépôts vérifiés un par un avant vendorisation (`Sources/CCrypto/README.md` donne les commits
exacts et les écarts) : `orlp/ed25519` (zlib), `agl/curve25519-donna` (BSD),
`grigorig/chachapoly` (MIT), `cocagne/csrp` (MIT). Chacune est pilotée par un wrapper Swift
dédié qui libère sa mémoire dans `deinit` ; aucun pointeur C hors de ces wrappers.

**Tests contre les vecteurs des RFC officiels, verts avant toute intégration réseau** comme
l'exige le prompt du jalon : X25519 (RFC 7748 §6.1), Ed25519 (RFC 8032 §7.1, TEST 1 à 3),
ChaCha20-Poly1305 (RFC 7539 §2.8.2). Aucune valeur attendue ne sort de ce projet.

HKDF-SHA512 fait exception et **n'est pas** wrappé depuis une bibliothèque C : CryptoKit le
fournit nativement. Le CDC 4.4 proscrit de *retranscrire à la main* une primitive, pas
d'employer une implémentation système éprouvée.

### Le défaut qui a coûté le plus de temps : le bourrage SRP

Le pairing échouait sur un laconique `invalid proof` du récepteur, alors que **A, B, le sel
et toutes les longueurs concordaient octet pour octet des deux côtés** (vérifié en
instrumentant le mock pour qu'il publie ses propres valeurs).

Cause : SRP-6a se décline en conventions incompatibles pour le bourrage des opérandes.

1. La branche `master` de csrp ne bourre **ni** `u = H(A,B)` **ni** `k = H(N,g)`. AirPlay 2
   exige le bourrage RFC 5054 des deux. → bascule sur la branche **`rfc5054_compat`** du
   même dépôt.
2. Mais cette branche bourre **aussi** `g` avant d'en prendre le condensat dans le calcul de
   la preuve `M1`, alors qu'**AirPlay 2 ne le fait pas** : il calcule `H(g)` sur l'octet
   `0x05` seul. C'est un hybride qu'aucun réglage du drapeau n'exprime.
   → **modification locale de six lignes** dans `calculate_M`, commentée dans le fichier et
   documentée dans `Sources/CCrypto/README.md`. Elle ne touche pas l'arithmétique de SRP,
   seulement le choix des opérandes d'un condensat.

Vérifié contre l'implémentation de référence du récepteur (`ap2/pairing/srp.py`), où
`H(self.N) ^ H(self.g)` est appelé **sans** `pad=True` tandis que `u` et `k` le sont.

C'est exactement le risque que le CDC 4.4 cherche à écarter en interdisant de réécrire ces
primitives : une divergence d'un seul opérande, sans symptôme exploitable.

### Deux défauts trouvés dans le socle existant

**1. `NWBrowser` écarte silencieusement un service dont le TXT lui déplaît.** Avec
`bonjourWithTXTRecord`, le mock AirPlay 2 **n'apparaît pas du tout** dans les résultats —
aucune erreur, juste une liste vide — alors que `dns-sd` et un parcours `.bonjour` sans TXT
le voient tous les deux, et que le même code rend bien le service RAOP de shairport-sync.
→ Parade : parcourir **sans** TXT, puis lire le TXT par une requête DNS dédiée
(`BonjourTXTQuery`, API `dns_sd`). Sans cela les bits de fonctionnalité et la clé publique
du récepteur seraient inaccessibles, et un récepteur matériel au TXT inhabituel serait
invisible sans explication.

**2. Attente infinie sur `NWConnection.receive` — défaut présent depuis le jalon 2.**
`RTSPClient.receiveChunk` n'avait **aucune échéance propre** : le délai n'était vérifié
qu'*entre* deux lectures, or le contrôle n'y revient jamais si le pair disparaît sans fermer
proprement. C'est précisément ce que fait le mock RAOP, qui quitte dès le `TEARDOWN` reçu :
**le processus ne se terminait jamais**, alors que toute la diffusion s'était bien passée.
Passé inaperçu au jalon 2 parce que le symptôme apparaît après l'affichage des résultats.
→ Corrigé (échéance par lecture, reprise unique garantie par un verrou), plus un délai court
de 2 s sur les `TEARDOWN` des deux senders, dont la réponse n'est de toute façon plus
exploitable.

### Respect de l'invariant section 12

- `AirPlay2Sender` reçoit un `AudioRingBuffer` et un format, **rien d'autre** : il ignore le
  mode de capture comme l'existence du sender RAOP.
- Il **lit** son ring buffer et ne l'écrit jamais. Un test écrit un motif connu, laisse le
  sender vivre, et vérifie que le contenu est relu **à l'identique**.
- **Un ring buffer par pipeline de sortie** : `CaptureSink.enableSecondaryPipeline()` en
  crée un second, et le callback temps réel duplique le PCM vers les deux (lock-free, sans
  allocation). Un test vérifie que vider l'un ne retire rien à l'autre.
- **Pannes confinées** : les deux senders tournent dans des tâches indépendantes d'un
  `withTaskGroup`, chaque échec étant capturé dans sa propre branche. Un `async let` aurait
  annulé l'autre sortie. Vérifié en conditions réelles (voir ci-dessus).
- Le rééchantillonnage 48 → 44,1 kHz tourne dans la tâche du sender, en aval du ring buffer,
  jamais dans le callback temps réel (CDC 4.5).

### Décisions prises, hors CDC

- **Pairing transitoire au lieu de credentials long terme.** C'est l'écart le plus important
  au prompt du jalon, et il est dicté par ce que le récepteur propose réellement. Trois
  observations concordantes : le mock annonce le **bit 48** (`TransientPairing`) et **pas le
  bit 43** (`SystemPairing`) ; **pyatv lui-même rapporte `Pairing: NotNeeded`** ; et
  `atvremote pair` échoue contre lui (le mock lève `invalid proof`), alors que
  `atvremote stream_file` fonctionne sans aucun pair-setup.
  En transitoire, l'échange s'arrête à M4 et **aucune clé long terme n'est échangée** :
  il n'y a, par construction, aucun credential à extraire ni à persister. **L'absence de
  `credentials/` n'est donc pas un oubli.** Le sender refuse explicitement de continuer si un
  récepteur n'annonce pas le transitoire, plutôt que d'échouer plus loin sur un message
  cryptographique obscur. Décision tracée en ADR : `decisions/003-pairing-transitoire-airplay2.md`.
- **ALAC non compressé et 352 trames par paquet**, comme au jalon 2 : le format négocié
  (`ALAC_44100_16_2`) permet de réutiliser tel quel l'encodeur et le rééchantillonneur.
- **Chiffrement du flux audio en ChaCha20-Poly1305**, nonce dérivé du compteur de paquets,
  en-tête RTP en données associées. `RTPPacketBuilder.audioHeader` a été ajouté pour obtenir
  l'en-tête avant de chiffrer ; la fabrique RAOP existante est inchangée.
- **`RTSPClient` porte le chiffrement de canal en option** (`enableEncryption`), inerte pour
  RAOP. Le chiffrement s'applique au transport, en dessous d'une sémantique RTSP identique
  pour les deux protocoles : une sous-classe aurait dupliqué le reste.
- **Découverte avec plusieurs tentatives** : `NWBrowser` rend parfois une liste vide au
  premier passage puis la bonne au suivant, sans erreur (constaté de façon intermittente).

### Ce qui reste ouvert

- **Rien n'a été validé contre un vrai Apple TV ni un vrai HomePod.** C'est la limite
  principale de ce jalon, et elle est plus lourde qu'au jalon 2 : l'émulateur est
  expérimental de son propre aveu (CDC section 10).
- **Le mode de pairing est le point le plus incertain pour le matériel réel.** Un Apple TV
  rattaché à une maison HomeKit arme en général le **bit 43** et réclame un appairage
  persistant avec code. Le travail restant est cadré et non spéculatif : `pair-setup` M5/M6
  (échange de clés long terme signées) puis `pair-verify` M1–M4. **Toutes les primitives
  nécessaires sont déjà implémentées et testées contre les vecteurs des RFC** — c'est une
  extension, pas une réécriture. `./audiocap --browse2` affiche les bits annoncés, ce qui
  permettra de trancher en une commande le jour J.
- **Le canal d'événements n'est pas exploité.** Le `SETUP` récupère bien son `eventPort`,
  mais rien ne s'y connecte : le récepteur y pousse des changements d'état (volume distant,
  arrêt côté récepteur). Sans objet pour diffuser, à traiter au jalon 5 si l'interface doit
  refléter l'état réel des sorties.
- **Aucune synchronisation entre les deux sorties.** Elles diffusent en parallèle mais
  chacune à son propre rythme : c'est précisément l'objet du jalon 4.
- **Aucune reconnexion automatique**, comme au jalon 2 (CDC section 8). Une panne est
  confinée et journalisée, mais la session n'est pas rétablie. À traiter au jalon 4 ou 5.
- **L'enregistrement mDNS du mock devient périmé après quelques minutes** : `dns-sd` continue
  de l'annoncer alors que `NWBrowser` ne le voit plus, et il faut relancer
  `./run-mocks.sh start`. Comportement du mock, sans rapport avec le code du projet — mais
  c'est la première chose à vérifier devant un « récepteur introuvable ».
- **Le puits audio du mock plante sur `av` 18** (`codecContext.channels` en lecture seule),
  y compris avec pyatv comme sender. C'est en aval du protocole : la négociation et la
  réception des paquets fonctionnent, seul le décodage local du mock échoue. Conséquence
  pratique : **la validation de ce jalon porte sur le protocole et le flux réseau, pas sur
  une écoute**. Défaut du mock hérité du pin `av` relâché au jalon -1.
