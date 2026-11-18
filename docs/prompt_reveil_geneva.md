# Prompt : réveiller ou allumer la Geneva à distance

Prompt d'une session Claude Code, à lancer depuis la racine du dépôt. Rédigé le 2026-11-18. Langue de travail :
français pour les comptes rendus et le code, anglais pour les messages de commit.

---

## 0. Avant tout

1. Lis `CLAUDE.md` en entier, puis dans `PROGRESS.md` la section « Où on en est » et les deux dernières sections,
   puis `.claude/CLAUDE.md` (le vault). Ces fichiers et l'historique git sont la seule mémoire du projet.
2. Règles de collaboration (`CLAUDE.md`, « Mode de collaboration ») : autonomie totale, **aucune question fermée**, ne
   solliciter Baptiste que pour une action que lui seul peut faire (appuyer sur un bouton de l'enceinte, regarder un
   voyant, ouvrir une app sur son iPhone).
3. Commits : conventional commits en anglais, scope, sujet à l'impératif, corps qui explique pourquoi. **Aucune ligne
   d'attribution** (ni `Co-Authored-By`, ni « Generated with », ni mention de Claude ou d'IA). `git add <chemins>`,
   jamais `-A`. Pousse avec `perl -e 'alarm 30; exec @ARGV' /usr/bin/git push -q origin main`.
4. Contraintes dures :
   - **N'envoie à aucun service extérieur l'adresse MAC, l'adresse IP ni le nom réseau de l'enceinte.** Les recherches
     sur le web portent sur le modèle, jamais sur cet exemplaire.
   - **Ne fais jouer aucun son audible** sans que Baptiste l'ait demandé : les essais de session se font au volume
     AirPlay minimal (−30) avec le signal d'essai à −50 dBFS (`--tone`), ou sans audio du tout.
   - L'enceinte est une ressource unique, et Baptiste s'en sert : avant tout essai, vérifie que l'app ne diffuse pas
     (`lsof -a -p $(pgrep -x AirplayPersonalBridge) -i UDP` vide) et que rien ne joue (`./audiocap --list`, aucun `●`).
     Si elle diffuse, attends ou travaille sur la partie documentaire.
   - Ne lance pas l'app, ne l'installe pas, ne touche pas à la sortie audio du Mac. Ne lis rien de `credentials/`.
   - Aucune modification de réglage sur l'enceinte, aucune mise à jour de firmware, aucun redémarrage d'usine : tu
     observes et tu envoies des paquets, tu ne reconfigures pas.
   - Arrête un processus par son PID. `/usr/bin/git` pour une sortie brute.

## 1. Le besoin de Baptiste

> « Est-ce que c'est possible de réveiller/allumer la Geneva à distance sur le même Wi-Fi ? Là, à chaque fois, je suis
> obligé d'appuyer sur un des deux boutons, attendre que ça s'allume et connecter. Je sais qu'il y a une télécommande
> qui existe, que je n'ai pas. »

Ce qu'il veut au bout du compte : cliquer « Diffuser » dans l'app (ou cocher la Geneva) et que l'enceinte s'allume
toute seule, sans se lever. Aujourd'hui, éteinte, elle apparaît en grisé « Hors ligne » dans l'app et il faut aller
appuyer sur l'enceinte.

## 2. Ce qu'on sait déjà (ne pas le redécouvrir)

- **Modèle** : Geneva AeroSphere Large. Nom réseau « Erki’s geneva » (apostrophe typographique), instance RAOP
  `<12 hexa>@Erki’s geneva` — le préfixe de 12 chiffres hexadécimaux est très probablement son adresse MAC, à
  confirmer par `arp`. Hôte `Erkis-geneva.local`, port RAOP 5000. Firmware `fv=s9816.258.1009`. Les valeurs exactes
  sont dans `CLAUDE.md`, section « Sortie réelle » : relis-les là, et relis son IP avec `dns-sd`/`arp`, elle peut avoir
  changé.
- Elle se comporte en récepteur **AirPlay 1** (RAOP), même si elle s'annonce aussi en `_airplay._tcp`.
- **Elle s'éteint seule** quand elle ne reçoit rien d'audible : une session à −60 dBFS ne l'a pas retenue, elle a fermé
  la session puis **quitté le réseau 15 minutes plus tard** (plus de réponse au ping, plus d'annonce Bonjour). Une
  session à −50 dBFS relancée en boucle l'a tenue allumée 2 h 30.
- `CLAUDE.md` dit « éteinte ainsi, rien ne la réveille à distance » : **c'est une observation d'un soir, jamais
  éprouvée**. Personne n'a essayé de la réveiller par un paquet. C'est précisément l'objet de cette session.
- On ignore si « éteinte » recouvre un seul état ou plusieurs (veille réseau, veille profonde, arrêt complet), ce que
  font exactement « les deux boutons », et si un réglage de veille existe.
- Outils sur le Mac : `tshark` (capture sans `sudo`), `dns-sd`, `arp`, `ping`, `nc`, `curl`, Homebrew. `nmap` n'est
  peut-être pas installé : `brew install nmap` est permis.

## 3. Ce qui est attendu

Un **rapport qui tranche** : peut-on la réveiller à distance, par quel moyen, avec quelle fiabilité et quel délai — ou
bien pourquoi c'est impossible, preuve à l'appui, et quelle est alors la meilleure solution de rechange.

### Phase A — Documentaire (aucune enceinte nécessaire)

Recherche sur le web, sources datées, faits vérifiés distingués des hypothèses :

1. **Le manuel et la fiche technique** de l'AeroSphere Large (et de la gamme AeroSphere : Small, Base) : les modes
   d'alimentation (marche, veille, veille réseau, arrêt), la consommation dans chacun, le délai d'extinction
   automatique, et s'il se règle ou se désactive. Ce que font les boutons de l'enceinte.
2. **La télécommande** : existe-t-elle pour ce modèle, est-elle infrarouge ou radio, que commande-t-elle
   (marche/veille ?), se trouve-t-elle encore à la vente, et ses codes sont-ils publiés (bases de codes IR : LIRC,
   Flipper-IRDB, IRDB, bases Broadlink).
3. **La plateforme réseau** de l'enceinte : quel module Wi-Fi/audio l'anime (pistes : indices dans le TXT Bonjour, le
   numéro de firmware, l'app iOS/Android du fabricant et ce qu'elle sait faire). Existe-t-il une API locale connue
   (HTTP, UPnP/DLNA, protocole de l'app) qui commande la marche et la veille.
4. **Le réveil par le réseau** pour ce genre d'appareil : Wake-on-LAN et Wake-on-Wireless-LAN (paquet magique),
   réveil par une connexion AirPlay entrante, par une requête mDNS, par Spotify Connect ou UPnP ; ce que la
   réglementation européenne sur la veille en réseau impose (un appareil en veille réseau doit pouvoir être réactivé
   par le réseau) et ce que cela implique pour une enceinte de cette génération.
5. **Les retours d'utilisateurs** : forums, avis, tickets (Home Assistant, Homebridge, Roon, AirPlay) sur le réveil
   d'une AeroSphere, ou à défaut d'enceintes bâties sur le même module.

### Phase B — Observation de l'enceinte allumée (Baptiste l'allume, voir § 4)

Tout ce qu'elle expose tant qu'elle est en marche, en lecture seule :

1. Son adresse MAC (`arp -n <ip>`), le fabricant derrière le préfixe (table OUI **locale** : celle de Wireshark,
   `/Applications/Wireshark.app/Contents/Resources/share/wireshark/manuf*`, pas un site web).
2. **Tous** ses services Bonjour (`dns-sd -B _services._dns-sd._udp local`, puis le TXT de chacun), y compris un
   éventuel service de « sleep proxy » ou de réveil.
3. Ses ports ouverts, TCP et UDP courants (`nmap -sT -p- <ip>`, puis `-sU` sur les ports usuels : 9, 7, 1900, 5353,
   5000-5010, 7000, 8008, 8080, 49152+). Pour chaque port HTTP : la racine, et les chemins d'API usuels des modules
   d'enceintes réseau (description UPnP sur le port annoncé par SSDP ; ne tente aucune commande d'écriture).
4. Sa réponse SSDP (`M-SEARCH`), sa description d'appareil UPnP, ses services et leurs actions (cherche une action de
   marche, de veille, de mise sous tension).
5. Ce qu'un `OPTIONS` RTSP sur le port 5000 répond, pour la suite.

### Phase C — Le passage à l'arrêt, capturé (Baptiste absent, ~30 à 45 min)

Capture `tshark -i en0` filtrée sur son adresse pendant qu'elle s'endort seule, sans session :

1. À quel instant elle cesse de répondre au ping, à l'ARP, à Bonjour : dans quel ordre, et y a-t-il un état
   intermédiaire où elle répond encore à quelque chose.
2. Envoie-t-elle un « goodbye » mDNS, se désassocie-t-elle du Wi-Fi (plus aucune trame), ou reste-t-elle associée en
   économie d'énergie (elle répond encore à l'ARP, même lentement).
3. Note l'heure exacte de chaque transition : c'est la carte des états dont tout le reste dépend.

### Phase D — Les essais de réveil (enceinte éteinte)

Dans chaque état d'arrêt identifié (veille après inactivité ; arrêt par le bouton, si Baptiste dit que c'est un autre
état), essaie **dans cet ordre, un à la fois**, en capturant, et en attendant 60 s après chacun avant de conclure :

1. Paquet magique Wake-on-LAN vers sa MAC : en diffusion générale (`255.255.255.255`), en diffusion du sous-réseau,
   et vers sa dernière IP ; ports UDP 9 et 7. Écris-le toi-même (6 octets `FF` puis 16 fois la MAC), sans dépendance.
2. Requête ARP et ping vers sa dernière IP ; requête mDNS de son nom et de ses services.
3. Connexion TCP vers ses ports d'avant l'arrêt (5000, 7000, ports HTTP relevés en phase B) ; `OPTIONS` RTSP.
4. `M-SEARCH` SSDP, et l'action UPnP de mise en marche si la phase B en a trouvé une.
5. Une vraie tentative de session RAOP au volume minimal : `swift run audiocap --tone --airplay "<nom exact>" --volume -30 10`.
6. Toute piste propre à sa plateforme trouvée en phase A.

Pour chaque essai : ce qui a été envoyé, ce qui est revenu, si elle a rejoint le réseau (ping, Bonjour), au bout de
combien de secondes. **Un seul succès ne suffit pas : refais-le trois fois**, après l'avoir laissée se rendormir.

Vérifie aussi, enceinte éteinte, si l'iPhone de Baptiste la voit encore dans son sélecteur AirPlay et si la choisir
la rallume (action de Baptiste, 30 secondes) : si oui, quelque chose la réveille, et la capture dira quoi.

### Phase E — Si rien ne la réveille par le réseau : les solutions de rechange

Chiffre et compare, sans rien acheter ni installer :

- **L'empêcher de s'endormir** tant que l'app tourne (la session silencieuse à −50 dBFS déjà éprouvée) : consommation
  électrique estimée d'après la fiche technique, usure, et ce que cela donne si le Mac dort. Un réglage de l'enceinte
  qui désactive la veille automatique vaut mieux, s'il existe.
- **L'infrarouge**, si la télécommande est infrarouge : un émetteur IR piloté par le réseau (types d'appareils, ordre
  de prix, comment l'app l'appellerait), avec les codes de la télécommande s'ils sont publiés, ou la télécommande
  d'origine à acheter d'occasion pour les apprendre.
- **Une prise connectée** : seulement si l'enceinte se rallume et rejoint le Wi-Fi toute seule au retour du courant
  (à vérifier dans le manuel ; ne coupe pas le courant de l'enceinte pour essayer sans que Baptiste le fasse lui-même).
- Toute autre voie trouvée en phase A (app du fabricant, Bluetooth, entrée déclencheur).

## 4. Ce que Baptiste doit faire, et quand

Dis-le-lui clairement au début, en une fois :

- **Au début de la phase B : allumer l'enceinte** (un appui, comme d'habitude) et le dire. Tu peux aussi détecter son
  retour seul (`ping`, `dns-sd`).
- **Ensuite, ne plus y toucher** pendant la phase C : elle doit s'éteindre toute seule, sans musique.
- **Pendant la phase D** : rien, sauf un coup d'œil au voyant si tu le lui demandes, et l'essai de l'iPhone.
- S'il existe deux façons de l'éteindre, une fois : l'éteindre par le bouton, pour que tu refasses les essais de
  réveil dans cet état-là aussi.

La phase A ne demande rien : commence par elle si l'enceinte est éteinte ou si Baptiste n'est pas là.

## 5. Organisation

Un agent de recherche documentaire (phase A, sans worktree, sans toucher au dépôt, scratchpad à lui) peut tourner
pendant que tu mènes les phases B à D toi-même : l'enceinte ne se partage pas entre agents. Garde les captures dans
`captures/reveil-geneva/` (les `.pcapng` sont ignorés par git ; cite leurs noms dans le rapport).

## 6. Rendre

1. **Le rapport**, dans `docs/reveil_geneva.md` : la carte des états de l'enceinte, le tableau des essais (envoyé,
   reçu, réveillée ou non, délai, nombre de répétitions), les sources documentaires datées, et **une recommandation
   unique**, avec ce qu'elle coûte (code, matériel, consommation) et ce qui reste incertain. Niveaux de preuve
   explicites : **capture**, **mesuré**, **vu par Baptiste**, **documentation**, **hypothèse**.
2. `CLAUDE.md` : corrige ou confirme la phrase « rien ne la réveille à distance », avec la preuve ; ajoute les faits
   durables (MAC, états, ports, ce qui réveille ou non).
3. `PROGRESS.md` : une section datée.
4. Vault : une entrée dans `notes.md` si un raisonnement établi tombe ; un ADR `018` seulement si une décision
   d'architecture est prise.
5. **N'implémente rien dans l'app** à cette session. Si un réveil par le réseau fonctionne, décris en dix lignes
   comment l'app s'en servirait (au clic sur Diffuser et quand la Geneva est cochée : envoyer le réveil, attendre
   son annonce, puis ouvrir la session ; l'enceinte restant « Hors ligne » en grisé jusque-là), et arrête-toi là :
   Baptiste décidera.
6. Compte rendu court à Baptiste : ça marche ou non, par quoi, en combien de temps, et la seule chose qu'il a à faire
   ensuite.
