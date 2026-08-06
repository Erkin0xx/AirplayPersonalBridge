# PROGRESS.md

Journal de progression par jalon. Voir docs/cahier_des_charges_diffusion_audio.md section 14.
Distinguer explicitement "validé contre mock" et "validé contre matériel réel".

**Statut matériel réel : aucun accès à ce jour.** Tout ce qui suit est validé contre les
émulateurs logiciels uniquement (`shairport-sync`, `airplay2-receiver`).

---

## OÙ ON EN EST — à lire en premier

| | |
|---|---|
| **Dernier jalon terminé** | Jalon 4 — synchronisation et dérive (validé **contre mock** le 2026-08-07) |
| **Prochain jalon** | **Jalon 5 — intégration et interface SwiftUI** (prompt : CDC section 14) |
| **Dépôt** | `github.com/Erkin0xx/AirplayPersonalBridge`, branche `main` |

**Les deux sorties diffusent en parallèle et synchronisées**, ce qui est l'objectif
fonctionnel du projet (CDC section 2) :

```
./audiocap --airplay Geneva --airplay2 ApTV 30
./audiocap --airplay Geneva --airplay2 ApTV --delay2 25 30   # fine-tune manuel, en ms
```

**Le mécanisme d'alignement, en une phrase** : une horloge de restitution commune traduit un
numéro de trame de capture en instant de restitution attendu ; chaque sender en tire
l'ancrage NTP qu'il annonce dans ses paquets de synchronisation, et c'est le récepteur qui
cale sa restitution dessus. Deux sorties ancrées sur la même horloge restituent la même trame
captée au même instant, sans jamais se connaître. Voir l'ADR `004` du vault : ce n'est **pas**
la lecture littérale du CDC (« mesurer la latence puis compenser »), qui s'est révélée
impraticable, mais ce qui en réalise l'intention.

**Le patron, respecté par les deux senders** : un acteur qui **lit** son propre ring buffer
et ne l'écrit jamais, ne connaît pas la source de capture, ignore l'autre sender, et confine
ses pannes (invariant section 12). La correction de dérive n'a rien changé à cela : elle
opère sur la copie propre au sender, en aval du ring buffer.

**Avant de coder quoi que ce soit au jalon 5** : lire `CLAUDE.md` en entier (invariants
section 12 + pièges vérifiés, dont **les trois pièges RAOP** du jalon 2, **le piège SRP** du
jalon 3, et **les faits de synchronisation** du jalon 4), puis le détail des jalons ci-dessous.

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
- ~~**Aucune reconnexion automatique.**~~ — **faite au jalon 4**, et validée 90 fois de
  suite sur une heure (voir le jalon 4).
- **Le volume n'est réglé qu'au démarrage.** `setVolume` existe et fonctionne en cours de
  session, mais le CLI ne l'expose pas dynamiquement — l'interface du jalon 5 le fera.
- ~~**La taille du ring buffer (1 s) reste à éprouver sur une longue durée**~~ — **clos au
  jalon 4** : 0 trame refusée en régime établi sur 1 h 02 et 466 088 paquets. Confirmé aussi
  en régime établi sur toutes les sessions courtes : Les refus observés
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
- **Le canal d'événements est branché au jalon 4**, mais seule la **connexion** est validée :
  le mock n'émet jamais rien, donc le décodage des événements (volume distant, arrêt côté
  récepteur) reste à faire au jalon 5.
- ~~**Aucune synchronisation entre les deux sorties.**~~ — **faite au jalon 4** : horloge de
  restitution commune, ancrage NTP, correction de dérive.
- ~~**Aucune reconnexion automatique**, comme au jalon 2 (CDC section 8).~~ — **faite au
  jalon 4** : pair-setup SRP refait à chaque rétablissement.
- **L'enregistrement mDNS du mock devient périmé après quelques minutes** : `dns-sd` continue
  de l'annoncer alors que `NWBrowser` ne le voit plus, et il faut relancer
  `./run-mocks.sh start`. Comportement du mock, sans rapport avec le code du projet — mais
  c'est la première chose à vérifier devant un « récepteur introuvable ».
- **Le puits audio du mock plante sur `av` 18** (`codecContext.channels` en lecture seule),
  y compris avec pyatv comme sender. C'est en aval du protocole : la négociation et la
  réception des paquets fonctionnent, seul le décodage local du mock échoue. Conséquence
  pratique : **la validation de ce jalon porte sur le protocole et le flux réseau, pas sur
  une écoute**. Défaut du mock hérité du pin `av` relâché au jalon -1.

---

## Jalon 4 : synchronisation et dérive — TERMINÉ (validé CONTRE MOCK)

Date : 2026-08-07

> **Portée de la validation.** Contre les deux émulateurs, sur la machine locale. **Aucun
> matériel réel n'a été sollicité.** La réserve est ici d'une nature particulière et il faut
> la lire attentivement : l'alignement automatique repose sur le fait que **les récepteurs
> honorent l'ancrage temporel annoncé**. Les mocks acceptent et journalisent les annonces de
> synchronisation, mais **aucun des deux ne restitue réellement de l'audio** (shairport-sync
> tourne sur un backend `ao` sans écoute, le puits du mock AirPlay 2 est cassé depuis le
> jalon -1). **Le mécanisme est donc validé de bout en bout côté protocole, et pas du tout
> côté restitution.** C'est la limite principale du jalon.

### Ce qui a été construit

Quatre briques, dans `Sources/AudioCore/Sync/` :

| Brique | Rôle |
|---|---|
| `SharedPlaybackClock` | horloge de restitution commune : trame de capture → instant de restitution attendu |
| `TimingEstimator` | mesure du décalage d'horloge depuis le canal de timing natif |
| `SampleSplice` | ajout/suppression d'**une** trame avec fondu (technique Snapcast) |
| `OutputSynchronizer` | par sortie : ancrage, réglage manuel, pilotage de la dérive |

Plus, dans les senders : le canal de contrôle AirPlay 2 (annonces de synchro), le canal
d'événements AirPlay 2, et la reconnexion automatique des deux sorties.

### L'alignement automatique : pourquoi « ancrer » et non « mesurer puis compenser »

C'est l'écart le plus important au prompt du jalon, et il est documenté en ADR
(`decisions/004-alignement-par-horloge-de-restitution-commune.md`).

Le prompt demande « l'alignement automatique par sortie via le canal de timing natif AirPlay
(NTP/RTP), pas via un ping réseau ». La lecture littérale — mesurer la latence de chaque
sortie, retarder la plus rapide — s'est révélée impraticable pour deux raisons **découvertes
en implémentant**, pas anticipées :

1. **La latence d'une sortie n'est pas observable depuis le sender.** Il voit sa propre file
   d'attente et la profondeur de tampon *annoncée* par le récepteur ; il ne voit ni le DAC,
   ni le haut-parleur, ni l'instant réel de restitution. Seule la calibration acoustique le
   donnerait — l'évolution que le CDC 4.5 range explicitement en conditionnel.
2. **shairport-sync n'horodate pas ses requêtes de timing** (voir ci-dessous) : il n'y a
   littéralement rien à mesurer contre ce récepteur.

Ce qui est fait à la place : les deux senders partagent une horloge de restitution qui
traduit un **numéro de trame de capture** en **instant de restitution attendu**. Chaque
sender en tire l'instant NTP annoncé dans ses paquets de synchronisation, et c'est le
récepteur qui aligne. L'alignement est alors **exact par construction** — à l'arrondi de
conversion 48 → 44,1 kHz près, soit 23 µs — au lieu d'être « aussi bon que la mesure ».

Le canal de timing garde deux rôles réels : il fournit la **latence annoncée** par le
récepteur (250 ms côté shairport-sync — précisément ce qu'un ping ne verrait pas), et il
fournirait le décalage d'horloge si le récepteur horodatait ses requêtes.

Le **réglage manuel** (`--delay`, `--delay2`, en ms) agit sur ce même ancrage, en s'y
ajoutant : il reste bien le fine-tune et le filet de sécurité voulus par le CDC 4.5, et non
un mécanisme parallèle. Il ne manipule aucun échantillon — le récepteur redate sa restitution
à l'annonce suivante, sans rupture de flux.

### La correction de dérive (technique Snapcast, CDC 4.5)

Capture et émission ne partagent pas la même horloge : le périphérique audio cadence la
première, `ContinuousClock` (horloge hôte) la seconde. Quelques dizaines de ppm suffisent à
déplacer le calage de plus de 100 ms en une heure.

La grandeur pilotée est le **délai de pipeline** : l'audio capté mais pas encore émis
(arriéré du ring buffer + échantillons convertis en attente). Le maintenir constant, c'est
maintenir constant le décalage capture → restitution, donc l'alignement.

Trois choix d'implémentation qui méritent d'être notés :

- **La consigne est observée, jamais décrétée.** Elle est la moyenne mesurée pendant 10 s de
  stabilisation. Une constante arbitraire aurait obligé la correction à rattraper d'emblée un
  écart qui n'est pas de la dérive.
- **La mesure est lissée** (constante de temps 5 s). L'instantané est bruité de plusieurs
  millisecondes : le ring buffer se remplit par blocs de ~256 trames et se vide par paquets
  de 352. C'est la tendance qui est de la dérive, pas l'oscillation.
- **Bande morte de 64 trames** (1,45 ms), un vingtième du seuil de perception de 20 à 30 ms
  du CDC section 8. En deçà, corriger reviendrait à s'agiter dans le bruit de mesure.

Le fondu est **obligatoire et exigé par le CDC 4.5**. `SampleSplice` ne coupe pas puis
recolle : il fait glisser progressivement le flux d'une trame sur 32 trames (0,73 ms), en
interpolant entre le flux d'origine et le flux décalé. La correction reste donc exacte — une
trame pleine, pas 0,98 — et sans discontinuité. Un test le vérifie sur une sinusoïde proche
de Nyquist : le raccord brut dépasse d'au moins 50 % le pas maximal naturel du signal, le
raccord fondu reste dans son voisinage immédiat.

**Le resampling continu (`libsamplerate`/`soxr`) n'a pas été engagé**, conformément à
l'escalade conditionnelle du CDC 4.5 : la dérive mesurée reste deux ordres de grandeur sous
le seuil, et l'escalade n'est justifiée que par un problème audible constaté à l'écoute
réelle — qui n'est pas possible ici.

### Les deux défauts trouvés, et comment

**1. Un décalage d'horloge annoncé à 3 995 042 823 685 ms.**
La première mesure sortait ce nombre. Le réflexe — chercher un facteur 1000 — était le
mauvais : la valeur vaut exactement l'heure Unix courante **plus l'époque NTP**, c'est-à-dire
`local − 0`. Vérifié en capture (`tshark -i lo0`) : **shairport-sync 5.2.1 envoie ses
requêtes de timing intégralement à zéro**, alors que le protocole prévoit son instant
d'émission aux octets 24–31. La mesure passive est donc impossible contre ce récepteur.
→ Corrigé : `TimingEstimator` rejette les estampilles invraisemblables, les compte à part, et
le compte rendu affiche « non mesurable (requêtes non horodatées) ». **Une mesure impossible
doit rester absente, jamais devenir un nombre.** Le champ existe dans le protocole : à
revérifier contre la vraie Geneva, où la mesure fonctionnerait sans changer une ligne.

**2. Un détecteur de panne qui aurait cassé les sessions saines.**
Comme signal de vie j'avais retenu l'arrêt des requêtes d'horloge du récepteur : natif au
protocole, et bien meilleur qu'un ping puisqu'il ne se tait que si le récepteur cesse
vraiment de tenir sa session. Sauf que **shairport-sync interroge densément pendant ~35 s
après le `RECORD`, puis se tait complètement** alors que tout va bien : 14 requêtes en tout
sur une session de 60 s, aucune après la 35ᵉ seconde. Mon délai de garde de 30 s aurait
déclenché une reconnexion sur chaque session au bout d'une minute.
Ce qui l'a révélé n'est pas un test mais **un compteur lu dans une mesure faite pour autre
chose** — le nombre de réponses de timing qui plafonnait dans le compte rendu.
→ Corrigé : le silence du canal de timing n'est plus qu'un avertissement journalisé (120 s).
Le critère franc de perte est la **rupture de la connexion RTSP** côté RAOP et celle du
**canal d'événements** côté AirPlay 2. Le flux audio étant en UDP, il ne signale jamais rien.

### Le canal d'événements AirPlay 2 (resté ouvert au jalon 3)

Branché. Le premier `SETUP` rendait déjà un `eventPort` que rien n'utilisait ; une connexion
TCP y est maintenant ouverte et surveillée.

**Ce qui est validé, et ce qui ne l'est pas** : la connexion est établie et sa rupture est
détectée — c'est ce qui en fait le signal de perte de session pour AirPlay 2. **Le décodage
des événements n'est pas validé**, faute de récepteur qui en émette : `EventGeneric` du mock
accepte la connexion, lit les octets et les jette, sans jamais rien pousser. Sur du matériel
réel le contenu est chiffré avec les clés du pairing et encadré comme le canal de contrôle.
Les octets reçus sont donc journalisés et comptés, **jamais interprétés** : les interpréter à
l'aveugle aurait été de la fiction.

### La reconnexion automatique (CDC section 8, restée ouverte aux jalons 2 et 3)

Implémentée pour les deux sorties. Sur perte de session : `TEARDOWN` des ressources réseau,
repli exponentiel (1 s → 15 s), renégociation complète — pair-setup SRP compris côté
AirPlay 2, les clés de session ne survivant pas à une coupure — puis reprise avec l'arriéré
écarté. Le compteur de paquets *de session* repart à zéro, ce qui repose le bit marker et
fait réinitialiser ses tampons au récepteur.

**Isolée par construction** : ni la capture, ni le ring buffer, ni l'autre sortie ne sont
touchés, et cette dernière n'a aucun moyen de savoir que sa voisine a décroché.

**Vérifiée en conditions réelles, involontairement** : le mock shairport-sync est mort en
cours de session pendant une première tentative de validation longue. Le journal montre la
séquence complète — `Connexion RTSP rompue — session réputée perdue`, puis les tentatives de
rétablissement espacées par le repli exponentiel — pendant que **la sortie AirPlay 2
continuait sans la moindre dégradation**. C'est la meilleure preuve d'isolement du jalon, et
elle n'a pas été mise en scène.

**Limite assumée** : la reconnexion couvre la perte d'une session **établie**, pas un
récepteur absent au démarrage. Un échec de la première négociation remonte à l'appelant, qui
le signale et laisse l'autre sortie continuer.

### Respect de l'invariant section 12

- **La correction de dérive ne touche jamais le buffer partagé.** `SampleSplice` est composé
  de **fonctions pures** : elles prennent un tableau et en rendent un autre. Ce tableau est
  `pendingSamples`, la copie propre au sender extraite en aval du ring buffer. C'est ce qui
  rend l'invariant vérifiable par simple lecture plutôt que par convention — et un test
  vérifie explicitement que l'entrée n'est pas modifiée.
- **Une panne sur une sortie n'affecte pas l'autre** : vérifié en conditions réelles (voir
  ci-dessus), et par construction — deux tâches indépendantes, deux ring buffers, deux
  synchroniseurs.
- **L'horloge commune n'est pas un canal entre les senders.** C'est une graduation : elle ne
  connaît aucune sortie et n'en distingue aucune. Deux senders qui la consultent ne
  s'échangent rien et continuent de s'ignorer. Le ring buffer expose pour cela
  `totalFramesWritten`, identique dans les deux pipelines puisqu'un unique producteur les
  alimente — aucune sortie ne lit l'état de sa voisine.
- **Rien n'a été ajouté au callback temps réel.** Toute la synchronisation vit dans les
  tâches des senders, en aval du ring buffer (emplacement autorisé par le CDC 4.5).
- Les verrous employés (`NSLock` dans l'horloge et les synchroniseurs) sont hors du chemin
  temps réel, que l'invariant section 12 est seul à protéger.

### Tests

**105 tests unitaires, tous verts** (79 du jalon 3 + 26 ajoutés). Les 79 précédents sont
restés verts en permanence.

Les ajouts ne visent pas la couverture mais des affirmations précises : que deux sorties sur
la même horloge s'accordent sur l'instant de restitution d'une même trame captée à moins
d'une trame près ; que l'ancrage retranche exactement la latence annoncée ; que le réglage
manuel décale l'ancrage d'exactement sa valeur ; que le sens de la correction suit le sens de
la dérive ; que le fondu réduit franchement la discontinuité par rapport à une coupure
brute ; et — régression du défaut n° 1 — qu'une requête non horodatée ne produit pas un
décalage absurde.

### La validation d'une heure (critère CDC section 8)

`./audiocap --airplay Geneva --airplay2 ApTV --delay2 25 3700`, soit **1 h 02 de diffusion
continue vers les deux sorties simultanément**. Trace complète :
`captures/jalon4-validation-1h.txt`.

| Mesure | RAOP (Geneva-Mock) | AirPlay 2 (ApTV-Mock) |
|---|---|---|
| Paquets audio émis | **454 621** | **466 088** |
| Trames lues du ring buffer | 174 197 760 | 178 572 800 |
| Erreurs d'émission | **0** | **0** |
| Recalages de cadence | **0** | **0** |
| Annonces de synchro ancrées | **3 661 / 3 661** | **3 700 / 3 700** |
| Écart résiduel de dérive | **−0,09 ms** | **0,00 ms** |
| Corrections d'un échantillon | −10 trames | −14 trames |
| Délai de pipeline / consigne | 13,28 / 13,37 ms | 13,37 / 13,37 ms |
| Latence annoncée par le récepteur | 250 ms | non annoncée |
| Délai manuel appliqué | 0 ms | **25 ms** |
| Reconnexions | **90 (0 échec)** | 0 |
| Trames refusées **en diffusion** | 113 536 | **0** |

**Ce que ces chiffres établissent :**

- **L'écart résiduel reste sous 0,1 ms sur une heure**, là où le CDC section 8 vise un
  décalage résiduel sous 20 à 30 ms. Deux ordres de grandeur de marge.
- **La correction de dérive agit, et très peu** : 10 et 14 trames retirées en une heure, soit
  ~0,3 ms de rattrapage total. C'est la mesure directe de l'écart entre l'horloge du
  périphérique audio et celle de l'hôte sur cette machine — minuscule, mais non nulle, et
  elle se serait accumulée sans correction. **Aucune trame ajoutée** : les deux sorties
  dérivaient dans le même sens, ce qui est cohérent avec une seule horloge d'émission
  commune (`ContinuousClock`) face à une seule horloge de capture.
- **Toutes les annonces de synchro portent un ancrage issu de l'horloge commune**, sans
  exception, y compris après chacune des 90 reconnexions.
- **La taille du ring buffer (1 s) tient la durée** — question ouverte depuis le jalon 1.
  Côté AirPlay 2 : **0 trame refusée en régime établi sur 466 088 paquets**. Les 252 032
  refus sont intégralement imputables à la fenêtre de négociation. Le point est clos.
  Les 113 536 refus côté RAOP correspondent aux 90 fenêtres de reconnexion, pendant
  lesquelles le sender ne draine pas — ~1 260 trames par fenêtre, soit ~26 ms : cohérent.

**La reconnexion automatique validée 90 fois de suite (CDC section 8).** Ce n'est pas une
mise en scène : le mock shairport-sync meurt reproductiblement ~25 s après le début de chaque
session (voir « ce qui reste ouvert »). Un script auxiliaire l'a relancé à chaque mort
pendant l'heure ; **les 90 morts ont donné 90 reconnexions réussies et 0 tentative
infructueuse**, la correspondance étant exacte. La sortie AirPlay 2, elle, n'a pas bronché :
0 reconnexion, 0 erreur, 0 trame refusée. **C'est la démonstration la plus nette de
l'invariant section 12 obtenue à ce jour** — une sortie qui décroche 90 fois en une heure
sans que l'autre s'en aperçoive.

**Réserve importante** : cette heure valide la tenue du flux, la stabilité des tampons et la
convergence de la boucle de dérive. Elle **ne valide aucune écoute** : aucun des deux mocks
ne restitue réellement d'audio. « Sans désynchronisation audible » reste donc à vérifier
contre le matériel réel.

### Décisions prises, hors CDC

- **Ancrer plutôt que mesurer puis compenser** — le point important du jalon, tracé en ADR
  `004`. Voir ci-dessus.
- **Le décalage manuel agit sur l'ancrage, pas sur les échantillons.** Retarder une sortie de
  30 ms ne consiste pas à insérer 1 323 trames mais à annoncer un instant de restitution
  décalé de 30 ms. C'est instantané, sans rupture de flux, et réversible. La marge est
  couverte par les 2 s de délai de restitution commun.
- **Consigne de dérive observée sur 10 s plutôt que constante**, lissage à 5 s, bande morte à
  64 trames. Justifications ci-dessus ; ces trois valeurs sont les seuls réglages du jalon.
- **`audioBufferSize` d'AirPlay 2 rapporté brut, sans être converti en latence.** Le mock rend
  8 388 608 — exactement 8 MiB, donc une taille en octets, qui vaudrait 190 secondes lue en
  trames. Le champ est donc affiché tel quel et n'alimente aucun calcul, plutôt que de
  publier une latence fausse. Même principe que pour le décalage d'horloge non mesurable.
- **Pas de sondage actif du canal de timing.** Envoyer nos propres requêtes donnerait un vrai
  aller-retour NTP, mais RAOP ne prévoit pas que le sender interroge, et le délai de trajet
  sur un réseau local est de toute façon deux ordres de grandeur sous le seuil visé.
- **Pas de `libsamplerate`/`soxr`.** L'escalade du CDC 4.5 est conditionnée à un problème
  audible constaté à l'écoute réelle. La dérive mesurée reste sous 0,1 ms, et aucune écoute
  n'est possible contre les mocks : engager cette dépendance maintenant serait spéculatif.

### Ce qui reste ouvert

- **Rien n'a été validé contre le matériel réel**, et la réserve est ici plus forte
  qu'ailleurs : **aucun des deux mocks ne restitue réellement de l'audio**. L'alignement
  repose sur le fait que les récepteurs honorent l'ancrage annoncé — c'est le pari du
  protocole, celui que fait aussi OwnTone, mais il n'a été vérifié par aucune écoute.
- **shairport-sync rejette notre SDP et meurt ~25 s après le début de chaque session** —
  `client announced rsaaeskey of 256 bytes, wanted 16`, puis décodage de travers, puis arrêt
  du process. **Comportement nouveau : le jalon 2 tenait des sessions de 40 s sans incident**,
  et `RAOPCrypto.swift`/`ALACEncoder.swift` sont pourtant inchangés depuis (`git diff` vide).
  Écarté au passage : le backend audio (`pipe` vers `/dev/null` ne change rien, config remise
  à `ao`) et une build AirPlay 2 (`shairport-sync -V` n'en mentionne pas).
  **C'est le point à élucider en premier au jalon 5** ; pistes classées par coût dans
  `CLAUDE.md`, la moins chère étant d'essayer le base64 bourré pour `rsaaeskey`/`aesiv`.
- **La validation d'une heure a exigé un script auxiliaire qui relance shairport-sync** à
  chaque mort. Sans lui, la sortie RAOP se serait arrêtée après ~25 s. Le flux RAOP mesuré
  est donc bien continu du point de vue du sender, mais il est fait de 91 sessions
  successives, pas d'une seule. La sortie AirPlay 2, elle, a tenu l'heure d'une traite.
- **La reconnexion ne couvre pas un récepteur absent au démarrage.** Un échec de la première
  négociation remonte à l'appelant. Discutable : au jalon 5, l'interface aura probablement
  intérêt à réessayer en tâche de fond plutôt qu'à déclarer la sortie perdue.
- **Le décodage des événements AirPlay 2 n'est pas validé**, faute de récepteur qui en émette.
  Seule la connexion l'est. À reprendre au jalon 5, où l'interface devra refléter le volume
  changé depuis le récepteur.
- **La mesure de décalage d'horloge n'a jamais pu produire une valeur**, shairport-sync
  n'horodatant pas ses requêtes. Le code est là et testé ; il attend un récepteur qui remplit
  le champ. À revérifier contre la vraie Geneva.
- **Chaque `./make-cli-bundle.sh` coûte une autorisation TCC à redonner à la main.** Trois
  fois pendant ce jalon. Pour une session de validation longue, geler le code d'abord.
