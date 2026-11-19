# Réveiller la Geneva à distance — rapport (2026-11-18)

Réponse au brief `docs/prompt_reveil_geneva.md`. Session du 2026-11-18, 19:42 à 20:55, Geneva AeroSphere Large allumée
par Baptiste au début.

Niveaux de preuve : **capture** (trace `tshark`), **mesuré** (sonde scriptée, horodatée), **vu par Baptiste**,
**documentation** (source datée), **hypothèse**.

## En une phrase

**Rien de ce qui passe par le réseau ne réveille la Geneva**, ni une coupure de courant. Seuls son bouton, et d'après le
manuel sa télécommande infrarouge, la rallument. Mais son firmware contient un réglage caché, « Standby Mode », qui
promet exactement ce que veut Baptiste : sortir de veille quand on la choisit comme sortie AirPlay. Le brief interdisait de
l'écrire ; Baptiste l'a ensuite demandé, et **il est activé depuis le 2026-11-18 à 21:00** : voir le § 8, où l'essai
décisif reste à faire. Les § 1 à 7 décrivent l'enceinte **avant** cette écriture.

## 1. La carte des états

| État | Voyant | Sur le réseau | Comment on y entre | Comment on en sort |
|---|---|---|---|---|
| **Démarrage** | orange ~20 s, puis vert clignotant ~10 s | rien, puis association Wi-Fi | bouton (vu par Baptiste) ; télécommande (documentation) | seul, ~30 s |
| **Marche** | vert fixe | ping, ARP, Bonjour (`_raop`, `_airplay`, `_http`), UPnP | fin du démarrage | voir les deux lignes suivantes |
| **Veille** | éteint (vu par Baptiste) | **plus rien** : ni ping, ni ARP, ni Bonjour, ni SSDP (capture) | **15 min sans entrée audio**, ou appui sur le bouton d'arrêt | bouton ; télécommande (documentation) |

Un seul état d'arrêt se voit sur le réseau. L'extinction automatique et l'arrêt par le bouton laissent la même trace : un
« goodbye » mDNS (TTL 0 sur toutes ses annonces), puis le silence complet. La requête ARP de la Freebox reste sans réponse
deux minutes plus tard (capture, 19:59:24). Aucun état intermédiaire, aucune phase où elle répondrait encore à l'ARP.

### Transitions mesurées

| Événement | Heure | Délai |
|---|---|---|
| 1re mise en marche (bouton) | avant 19:42:53 (première vue Bonjour) | — |
| 1re extinction automatique, goodbye mDNS | **19:57:05,36** | ~15 min |
| Débranchée puis rebranchée, puis multiprise coupée et rallumée | ~20:24 à 20:27 | **aucun redémarrage** (vu par Baptiste, mesuré : aucune trame) |
| 2e mise en marche (bouton) : premier ping | 20:27:47,8 | — |
| 2e extinction automatique, goodbye mDNS | **20:42:44,96** | **14 min 57 s** |
| 3e mise en marche (bouton) | 20:49:55,9 | — |
| Arrêt par l'autre bouton, goodbye mDNS | 20:50:03,8 | 8 s |

**Ce qui ne la retient pas allumée** (capture) : un scan TCP de ses 65 535 ports pendant toute la durée de la 2e session,
des requêtes HTTP sur sa page de configuration, des requêtes UPnP. Seule une entrée audio compte, comme le dit le manuel.
Le projet savait déjà qu'un flux à −50 dBFS la retient et qu'un flux à −60 dBFS ne la retient pas.

**Deux boutons** (vu par Baptiste) : l'un l'allume, l'autre l'éteint. Le manuel ne décrit que Power et SETUP à l'arrière,
et **Power maintenu 10 s la remet en réglages d'usine** (documentation). Tout ce qui appuie à la place de Baptiste ne
doit faire que des appuis courts.

## 2. Ce que l'enceinte expose quand elle est allumée (phase B)

| Quoi | Valeur | Preuve |
|---|---|---|
| MAC | `F8:F2:5A:01:12:61` (= préfixe de l'instance RAOP) | `arp`, capture |
| Fabricant du préfixe | `G-Lab GmbH` : la marque elle-même, pas le module Wi-Fi | table OUI locale de `tshark -G manuf` |
| Bonjour | `_raop._tcp` et `_airplay._tcp` sur 5000, `_http._tcp` sur 80. Aucun service de réveil, aucun enregistrement auprès d'un « sleep proxy » (les HomePod et l'Apple TV en proposent un, elle ne s'en sert pas) | `dns-sd`, capture |
| TXT `_airplay` | `deviceid=F8:F2:5A:01:12:61 features=0x444C0A00 flags=0x4 model=AeroSphere Large srcvers=190.9` | `dns-sd -L` |
| Ports TCP ouverts | **80, 443, 5000, 8080, 10200, 15555** (union de deux scans, l'enceinte perd des sondes sous charge) | `nmap -sT -p-`, capture des SYN-ACK |
| Ports UDP | non scannés : `nmap -sU` exige `sudo` | — |
| RTSP `OPTIONS` sur 5000 | `200 OK`, `Server: AirTunes/190.9`, `Public: ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER, POST, GET` | `nc` |
| HTTP 80 | `Server: GoAhead-Webs`, horloge au 1er janvier 2000, redirection vers `/index.asp` (page « Network Setup ») | `curl` |
| UPnP | `MediaRenderer:1` décrit sur `http://<ip>:8080/description.xml`, `Server: KnOS/3.2 UPnP/1.0 DMP/3.5`. **Il répond au `M-SEARCH` depuis le port source 3911, pas 1900** : un client qui filtre sur 1900 ne le voit pas | capture |
| Services UPnP | RenderingControl, ConnectionManager, AVTransport, `urn:schemas-smsc-com:service:X_WholeHomeAudio:1`, `urn:schemas-tencent-com:service:QPlay:1`. **Aucune action de marche, de veille ou de réveil** dans leurs descriptions | `curl` des SCPD |
| `X_WholeHomeAudio#GetDeviceStatusInfo` | `DeviceStatus=1`, `PlayState=0`, rien sur la veille | SOAP en lecture |

**Plateforme** : **Microchip JukeBlox** (ex-SMSC), d'après quatre indices concordants : le logo Microchip sur la page de
configuration, l'espace de noms UPnP `schemas-smsc-com`, le type Bonjour `_JB2XiOSApp._tcp` (« JukeBlox 2.x »), instance
`iOSApp_011261`, que l'enceinte retire elle-même par un goodbye à chaque démarrage (capture, 20:49:55), et le serveur `KnOS`. C'est une **hypothèse forte**, aucune source ne le
confirme pour ce modèle.

### Le réglage caché « Standby Mode »

La page de configuration charge le script générique de la plateforme (`airplayRelJavScr.js`, 100 Ko), qui contient un
gestionnaire **`POST /goform/aformHandlerConfigureStandByMode`** (`state=1` active, `state=0` désactive) et ce texte
d'aide, recopié tel quel :

> « If you would like your product to be ready to power up and start automatically from standby mode when it is
> selected for AirPlay music streaming, turn this feature On. Otherwise, the product will need to be turned on from
> standby mode with a button press or the IR remote control in order to be ready to stream music. »

- **Geneva a retiré l'interrupteur de sa page** : la variable `isInStandBy` qui le positionne n'y est jamais définie, et
  aucune page lisible n'expose l'état du réglage (`/default.asp`, `/settings.asp` et `/advanced.asp` : 404). Le seul
  moyen de le connaître est de l'écrire.
- Le comportement mesuré (départ complet du réseau en veille) dit qu'il est **désactivé**, ou sans effet sur ce firmware
  (**hypothèse**).
- Pourquoi Geneva l'aurait masqué : une enceinte restée associée au Wi-Fi consomme plus que les 0,47 W annoncés pour la
  veille, que le règlement 1275/2008 plafonne à 0,50 W pour un état sans réseau. Le règlement 801/2013 autorise
  pourtant une veille réseau jusqu'à 6 W pour un produit de 2015 (documentation) : rien ne l'interdisait. **Hypothèse**.
- **Ce que l'activation coûterait et risquerait** : une requête, défaite par `state=0`. Consommation en veille réseau
  inconnue (aucune fiche ne la donne). Risque inconnu sur un firmware qui ne l'affiche pas : au pire, la remise en
  réglages d'usine (Power 10 s) efface tout.

## 3. Les essais de réveil (phase D)

Enceinte en veille, Mac sur le même Wi-Fi, capture `tshark` en continu. Chaque essai est suivi de **60 s d'observation**
(ping chaque seconde, Bonjour en continu). « Réveillée » = elle répond au ping ou réapparaît dans Bonjour.

| # | Envoyé | Reçu en retour | Réveillée ? | Répétitions |
|---|---|---|---|---|
| 1 | Paquet magique Wake-on-LAN (6 × `FF` + 16 × MAC), 3 fois chacun, vers `255.255.255.255`, `192.168.1.255` et sa dernière IP, ports UDP 9 et 7. Dans la capture : 12 en diffusion, 1 en unicast vers sa MAC tant que l'ARP du Mac la connaissait encore | rien | **non** | 3 (veille auto ×2, arrêt bouton ×1) |
| 2 | Ping, requête ARP, requêtes mDNS de son nom (`A`) et de son service RAOP (`SRV`) | rien : 42 requêtes ARP sans réponse au premier passage, le Mac finit par répondre « Host is down ». Après l'arrêt par le bouton, `dns-sd` a rendu `A` et `SRV`, **depuis le cache du Mac** : aucune trame de l'enceinte dans la capture. Son goodbye ne retire que les PTR de ses services, pas son adresse | **non** | 3 |
| 3 | Connexions TCP vers 5000, 7000, 80, 443, 8080, 10200 et 15555 | aucun SYN ne part : le Mac ne résout plus son adresse (`EHOSTDOWN`) | **non** | 2 |
| 4 | `M-SEARCH` SSDP en multicast et en unicast | rien, ni dans le script ni dans la capture (allumée, elle répondait : voir § 2) | **non** | 1 |
| 5 | Vraie session RAOP : `swift run audiocap --tone --airplay "Erki’s geneva" --volume -30 10` | la sortie reste en `connexion` : sans annonce Bonjour, rien ne part vers l'enceinte | **non** | 1 |
| 6 | Sélecteur AirPlay de l'iPhone | elle n'y figure pas | **non** | 1 (vu par Baptiste) |
| 7 | Coupure de courant : débranchée puis rebranchée, puis multiprise coupée et rallumée | elle reste en veille, aucune trame | **non** | 2 (vu par Baptiste) |
| 8 | Bouton de l'enceinte | de retour sur le réseau ~30 s plus tard | **oui** | 3 (vu par Baptiste) |

Pas d'essai propre à la plateforme : l'UPnP n'a aucune action de marche, et la seule piste trouvée (le « Standby Mode »)
est un changement de réglage, interdit par le brief.

**Conclusion des essais** : en veille, l'enceinte n'est plus associée au Wi-Fi, ou n'écoute plus rien. Tout ce que le
réseau peut lui envoyer est perdu, sans exception. C'est ce que prévoyaient le manuel (veille à 0,47 W) et la
recherche documentaire. La phrase de `CLAUDE.md`, « rien ne la réveille à distance », **est confirmée pour le réseau**,
preuve à l'appui. Elle doit être complétée : une coupure de courant ne la réveille pas non plus, et le « Standby Mode »
reste à éprouver.

**Le retour du courant**, plus précisément : Baptiste dit qu'en temps normal, la débrancher et la rebrancher la relance.
Ce soir, en veille, rien. **Hypothèse** : elle reprend son dernier état au retour du courant, marche si elle était en
marche, veille si elle était en veille. Une prise connectée ne sert donc à rien, puisqu'on veut justement la sortir
de veille.

## 4. La documentation (phase A)

Recherche du 2026-11-18, sur le modèle uniquement. Détail dans le rapport de l'agent, résumé ici.

| Fait | Source |
|---|---|
| Gamme de **2014** (modèle A010, FCC ID ZXX-A010, G-Lab GmbH, Zurich), pas de 2020 | Setup Guide v1.0, « © 2014 G-Lab GmbH », PDF du 2014-09-10 : `genevalab.com/_files/ugd/3d3fbe_6f7d8035e0ac4fc98e082f5145ec8006.pdf` ; What Hi-Fi, 2015-06-17 |
| Veille à **0,47 W** ; extinction automatique après **15 min** sans entrée audio, « required by law », réglage non documenté | Setup Guide p. 16 ; FAQ Geneva, PDF du 2016-08-31 : `genevalab.com/_files/ugd/3d3fbe_31c859af4cef4d3f832722e4311162c8.pdf` |
| Voyant : jaune = démarrage, vert clignotant = attente du Wi-Fi, vert fixe = connectée | Setup Guide, Feature Guide (PDF du 2014-10-29) |
| Power maintenu 10 s = réglages d'usine ; SETUP court = WPS, long = WAC | Setup Guide p. 10 |
| **Télécommande infrarouge fournie** avec la Large (pile CR2032) ; sa touche Power sort l'enceinte de veille | Feature Guide § 1 ; Trusted Reviews, 2015-09-23 |
| Codes IR de l'AeroSphere : **non publiés**. Flipper-IRDB n'a que l'ancienne Geneva Model L (NEC, adresse 0x00, Power 0x00), un autre produit | `github.com/Lucaslhm/Flipper-IRDB`, consulté le 2026-11-18 |
| Télécommande de rechange propre à l'AeroSphere : introuvable ; des copies « Geneva Model S/L/XL » à ~10 USD, compatibilité inconnue | eBay, consulté le 2026-11-18 |
| Wi-Fi 802.11 b/g seulement ; AirPlay 1, DLNA/UPnP, Bluetooth aptX ; app « Geneva AeroSphère » sans fonction d'allumage | FAQ 2016 ; App Store id903049429 |
| Firmwares publiés en 2016 : Large `s9846.276.1040`. L'enceinte a `s9816.258.1009`, plus ancien | FAQ 2016 |
| Règlement 1275/2008 : état sans réseau ≤ 0,50 W. Règlement 801/2013 (2015) : veille réseau ≤ 6 W puis 3 W et 2 W, et l'appareil **peut** passer de la veille réseau à la simple veille. Rien n'oblige l'enceinte à rester réveillable | EUR-Lex, CELEX 02008R1275-20170109 et 32013R0801 |
| Aucun retour d'utilisateur sur un réveil à distance de l'AeroSphere | Reddit, Home Assistant, Homebridge, Roon, consultés le 2026-11-18 ; AVForums illisible (403) |

## 5. Les solutions de rechange, chiffrées (phase E)

| Solution | Matériel | Code dans l'app | Fiabilité | Ce qui reste incertain |
|---|---|---|---|---|
| **A. « Standby Mode » du firmware** | aucun | presque rien : la sortie attend déjà un récepteur absent (`waitingForReceiver`). Il faudrait en revanche qu'elle reste visible en veille | inconnue | qu'il fonctionne ; ce qu'elle consomme alors ; si elle reste annoncée dans Bonjour, ou si l'app devra viser son adresse connue |
| **B. Pousse-bouton Bluetooth** (type SwitchBot Bot, ~30 €) collé sur le bouton de mise en marche | ~30 € | ~150 lignes : CoreBluetooth vers un protocole publié, sans pont ni compte ; appuyer seulement si la Geneva est absente de Bonjour, puis attendre ~30 s | élevée : le bouton la rallume à chaque fois (vu par Baptiste) | la course du bouton ; la pile du pousse-bouton ; **un appui long la remettrait en réglages d'usine** : appui court seulement |
| **C. Émetteur infrarouge** piloté par le réseau (Broadlink RM4 mini, ~30 €) | ~30 €, plus une télécommande d'origine d'occasion pour apprendre le code, introuvable aujourd'hui | intégration Broadlink locale | moyenne : code inconnu, ligne de vue requise | le code Power ; une copie à 10 USD pourrait ne pas fonctionner |
| **D. L'empêcher de dormir** (session à −50 dBFS, déjà éprouvée 2 h 30) | aucun | une session de maintien tant que l'app tourne | élevée, tant que le Mac et l'app tournent | sa consommation en marche, publiée nulle part ; elle s'éteint 15 min après la mise en veille du Mac |
| ~~E. Prise connectée~~ | — | — | **nulle** : elle ne sort pas de veille au retour du courant (vu par Baptiste, deux fois) | — |

## 6. Recommandation

**Essayer d'abord le « Standby Mode » du firmware** : `POST http://<ip>:80/goform/aformHandlerConfigureStandByMode` avec
`state=1`, enceinte allumée. Puis la laisser s'endormir et observer en capture : reste-t-elle associée, annoncée,
réveillable par une session AirPlay ? Cet essai ne coûte ni matériel ni code, il se défait par `state=0`, et c'est le
seul chemin qui rendrait « Diffuser » suffisant, sans rien ajouter.

**S'il ne la réveille pas : le pousse-bouton Bluetooth (solution B)**. C'est la seule solution dont le mécanisme est
prouvé, puisque le bouton la réveille à chaque fois. Elle coûte ~30 € et une intégration CoreBluetooth.

Ce que Baptiste décide : autoriser ou non l'écriture du réglage. Le brief l'interdisait à cette session.

### Si le « Standby Mode » fonctionne : comment l'app s'en servirait

1. La Geneva reste « Hors ligne », en grisé, tant qu'elle n'est pas annoncée.
2. Au clic sur « Diffuser », ou quand on la coche : si elle reste annoncée en veille, le sender ouvre la session comme
   aujourd'hui. Le premier `ANNOUNCE`/`SETUP` est le déclencheur, et la session doit tolérer ~30 s de démarrage.
3. Si elle n'est pas annoncée : la sortie reste en `waitingForReceiver`, qui sait déjà attendre un récepteur absent, et
   la connexion part à son retour dans Bonjour.
4. Il faudra mesurer si le premier essai de session échoue pendant le démarrage, et si la renégociation existante suffit.

Avec la solution B, l'étape 2 devient : appuyer une fois (appui court), attendre l'annonce, puis ouvrir la session.

## 7. Captures et journaux

Dans `captures/reveil-geneva/` (les `.pcapng` sont ignorés par git) :

- `phaseC-endormissement.pcapng` : de 19:43 à 20:00, trames de et vers la Geneva, dont la première extinction (19:57:05).
- `phaseD-essais-reveil.pcapng` : de 20:00 à 20:55, essais de réveil (WoL, ARP, SSDP), deuxième mise en marche et
  extinction, arrêt par le bouton.
- `monitor-transitions.log` : changements d'état ping/ARP, toutes les 5 s.
- `bonjour-raop.log`, `bonjour-airplay.log` : apparitions et départs Bonjour. Pendant le scan à haut débit (20:37 à
  20:41), l'enceinte saturée a manqué des réponses mDNS : ces départs-là ne sont pas des extinctions.
- `phaseD-essais.log` : sortie des essais de réveil.

## 8. Le « Standby Mode » activé (phase F, 2026-11-18 de 21:00 à 21:45) — essai décisif à faire

Baptiste a demandé d'aller jusqu'au réveil : l'interdiction d'écrire ce réglage est levée. Une mise à jour du firmware et
une remise en réglages d'usine restent exclues sans son accord.

**L'écriture** (mesuré, 21:00:17, enceinte allumée) :

```
curl -s -m 20 -H 'Content-type: application/x-www-form-urlencoded' --data 'state=1' \
     http://<ip>/goform/aformHandlerConfigureStandByMode
→ 2qwhgpstgriz0qwhgpstgriz1qwhgpstgrizEndRes   (HTTP 200 en 7,6 s ; le dernier champ à 1 = accepté)
```

`state=0` le défait. `index.asp` met ~11 s à répondre (la page scanne les réseaux Wi-Fi) : tout délai court échoue.

**Ce qui a été observé ensuite** (capture `phaseF-standby-mode.pcapng`) :

| Heure | Événement | Preuve |
|---|---|---|
| 21:00:17 | réglage écrit, enceinte restée allumée, **sans redémarrage** | mesuré |
| 21:12:36 | extinction automatique, goodbye mDNS, plus aucune trame : **comme avant**. SYN TCP (en unicast, ARP encore en cache) et Wake-on-LAN sans effet | capture |
| 21:24:07 | rallumée au bouton par Baptiste : le réglage est donc relu **après un redémarrage** | capture |
| **21:24:42** | éteinte au bouton d'arrêt (dit par Baptiste). Dernière réponse au ping à 21:24:37,95. **Aucun goodbye mDNS**, puis aucune trame pendant ~132 s | capture |
| **21:26:49** | **elle revient seule sur le réseau** : sondes mDNS, réponse ARP, annonce ARP (21:26:53), puis `_http`, `_airplay`, `_raop` avec des TXT **identiques** à ceux de la marche | capture |
| **21:39:42** | goodbye mDNS, plus aucune trame : **15 min 00 s après l'appui sur le bouton d'arrêt** | capture |
| 21:40:27 à 21:42:31 | TCP, Wake-on-LAN, ping, mDNS : sans effet, comme en veille profonde | mesuré |

**Lecture** : une fois relu au démarrage, le réglage crée un état nouveau, une **veille réseau** : éteinte au bouton, elle
redémarre son réseau (~2 min), s'annonce en AirPlay comme si elle était allumée, puis coupe tout 15 min après l'appui.
Trois choses ne sont **pas** établies :

1. **Le voyant pendant cette veille réseau** : personne ne l'a regardé. Si elle était simplement rallumée, ce ne serait
   pas une veille.
2. **Qu'une session AirPlay la rallume** dans cette fenêtre : aucun essai n'y a été lancé, la fenêtre n'a été comprise
   qu'après coup, dans la capture.
3. **Qu'on puisse prolonger la fenêtre** au-delà de 15 min, par une activité réseau périodique ou autrement. Sans cela,
   le gain se limite au quart d'heure qui suit l'extinction, et l'extinction automatique (21:12:36, avant le
   redémarrage) reste à refaire avec le réglage relu.

**Aussi essayé, sans résultat** : pages cachées de la page de configuration (noms courants, toutes en 404) ; Bluetooth
(l'enceinte n'est pas appairée au Mac et n'apparaît dans `blueutil --inquiry` ni allumée ni en veille).

**L'essai décisif** est scripté (`standby-wake.sh`, hors dépôt) et attend une action de Baptiste : allumer, attendre le
vert fixe, éteindre d'un appui court, puis regarder le voyant quatre minutes. Au retour de l'enceinte sur le réseau, le
script ouvre une session RAOP inaudible (−50 dBFS, volume −30, 25 s) et relève l'heure à laquelle elle quitte le réseau :
15 min après l'appui si la session n'a rien changé, 15 min après la session si elle l'a rallumée.

Journaux de la phase F dans `captures/reveil-geneva/` : `phaseF-monitor.log`, `phaseF-bonjour-raop.log`,
`phaseF-essais.log`. Capture et sondes arrêtées le 2026-11-19 à 14:26 : l'enceinte n'a pas été rallumée depuis 21:39:42,
aucune trame d'elle entre-temps, et le script de l'essai décisif n'est plus armé (il a attendu 14 h).
