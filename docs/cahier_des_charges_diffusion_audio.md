# Cahier des charges : application macOS de diffusion audio multi-sortie

## 1. Contexte et objectif

Usage personnel. Le système natif macOS (Multi-Output Device via Audio MIDI Setup) ne permet pas d'agréger simultanément un appareil AirPlay 1 (enceinte Geneva) et un groupe AirPlay 2 (Apple TV + 2 HomePod, déjà groupés en zone via l'app Maison). Airfoil contourne cette limite en gérant lui-même les deux protocoles en parallèle plutôt que de s'appuyer sur le système.

Objectif : application native macOS, à usage strictement personnel, capturant soit le son système global, soit le son d'une application spécifique choisie par l'utilisateur, et le diffusant simultanément vers ces deux destinations, avec volume indépendant par sortie et compensation manuelle du décalage temporel entre elles.

## 2. Périmètre fonctionnel

- Capture système globale, indépendante de toute configuration Multi-Output Device.
- Choix de la source de capture : audio système global (par défaut), audio d'une application spécifique, ou entrée audio physique (micro/ligne, par exemple la sortie d'un ampli tourne-disque relié à une interface audio) — voir 4.2.
- Diffusion simultanée vers :
  - la Geneva (AirPlay 1 / RAOP), via un sender implémenté en interne ;
  - le groupe Apple TV + HomePod (AirPlay 2), via un sender implémenté en interne.
- Volume réglable indépendamment par sortie.
- Mesure et compensation automatiques de la latence par sortie, via le canal de timing natif d'AirPlay (voir 4.5), avec réglage manuel conservé en fine-tune/secours plutôt qu'en mécanisme principal.
- Correction continue de la dérive d'horloge entre les deux sorties pendant la lecture.
- Interface minimale : liste des sorties actives, volume et délai par sortie, activation/désactivation individuelle, sélecteur de source de capture.

## 3. Hors périmètre

- **Spatialisation audio 3D** : écartée. Elle suppose une relation de phase et de timing stable entre les sorties, incompatible avec des récepteurs AirPlay tiers non synchronisés au sample près, avec buffers de 1 à 2 secondes et dérive d'horloge propre à chaque appareil. Un changement d'objectif (spatialisation binaurale casque, par exemple) sortirait du périmètre de ce document.
- Portage vers un autre OS.
- Découverte automatique de tout appareil AirPlay du marché : le scope se limite au matériel personnel listé ci-dessus.
- Gestion multi-pièces ou multi-utilisateurs façon Sonos.
- Fonction de récepteur AirPlay : l'application est un sender exclusivement.

## 4. Architecture technique

### 4.1 Vue d'ensemble

Process unique, natif Swift/macOS. Aucune dépendance runtime à un sous-processus externe. pyatv reste utile en amont du développement (pairing initial, extraction de credentials), mais la référence de portage pour la logique AirPlay 2 change par rapport à la version précédente de ce document : voir 4.4 et l'annexe en section 10.

Avant d'engager le développement natif, une phase de validation low-cost est recommandée (voir Phase 0, section 7) : OwnTone (anciennement forked-daapd), serveur audio open source activement maintenu, sait déjà diffuser en multiroom synchronisé vers un mélange d'appareils AirPlay 1 et AirPlay 2. Le faire tourner localement sur le Mac avec le système audio en entrée permet de vérifier concrètement, en quelques heures, si l'objectif fonctionnel du point 2 est atteignable avec du logiciel existant, avant de committer plusieurs mois à une réécriture native.

### 4.2 Capture audio

- API : Core Audio Process Tap (`AudioHardwareCreateProcessTap`, macOS 14.2+) pour les modes système global et application spécifique.
- Deux modes disponibles sur la même API, sans framework supplémentaire : `CATapDescription` initialisé en mode global (`initStereoGlobalTapButExcludeProcesses:`) pour le son système, ou en mode ciblé (`initStereoMixdownOfProcesses:`) pour capturer une seule application choisie par l'utilisateur. Le choix se fait à la création du tap, pas de changement d'architecture entre les deux modes.
- Troisième mode, distinct des deux précédents : entrée audio physique (micro ou ligne, par exemple la sortie d'un ampli tourne-disque relié à une interface audio USB). Ce mode n'utilise pas le Process Tap mais l'API d'entrée audio standard (`AVAudioEngine.inputNode`), disponible sans contrainte de version macOS récente et bien plus documentée que le Process Tap. Le périphérique effectivement capté est celui sélectionné comme entrée système dans Réglages Son > Entrée ; l'application n'a pas à gérer elle-même la liste des interfaces audio connectées.
- Permission macOS différente selon le mode : autorisation d'enregistrement audio système pour les deux premiers modes, autorisation microphone classique (`NSMicrophoneUsageDescription`) pour le troisième — deux bascules de confidentialité distinctes à déclencher selon la source choisie.
- Sortie : un flux PCM interne, dupliqué vers les deux pipelines de diffusion décrits ci-dessous, quel que soit le mode de capture actif.
- Point à vérifier tôt, pas encore tranché : le comportement du Process Tap face à du contenu protégé par DRM (FairPlay, contenu vidéo premium). Aucune source primaire trouvée ne confirme un blocage systématique ; les outils de capture historiques (Loopback, Airfoil, BlackHole) captent Apple Music sans souci depuis des années, ce qui va plutôt dans le sens contraire, car le DRM protège le fichier chiffré, pas les échantillons PCM déjà décodés au moment où ils atteignent le graphe Core Audio. Précision : BlackHole n'est pas un pilote plus "bas niveau" que Process Tap au sens architectural, c'est un plugin HAL en espace utilisateur comme lui, les deux récupèrent du PCM déjà décodé au même point du pipeline ; il n'y a donc pas de raison technique claire de penser que l'un serait plus susceptible d'être bloqué que l'autre pour cette seule raison. Mais l'API Process Tap étant récente, il reste possible qu'Apple y ait ajouté une restriction de politique spécifique, indépendante de ce raisonnement architectural. Vérification empirique dès la phase 1 (voir section 14) ; si Process Tap s'avère bloqué sur du contenu protégé, tester BlackHole en piste de repli, sans garantie que ça résolve le problème si la restriction constatée est de nature à s'appliquer aux deux mécanismes.

### 4.3 Sender AirPlay 1 / RAOP (Geneva)

- Implémentation directe du protocole RAOP : RTSP pour la négociation, RTP pour le transport, encodage ALAC.
- Aucune dépendance externe requise, protocole stable et documenté.
- Validation par capture Wireshark, en comparant la séquence produite par l'application à une session fonctionnelle (macOS natif ou Airfoil) vers le même appareil.

### 4.4 Sender AirPlay 2 (Apple TV + HomePod)

- Pairing initial réalisé une seule fois via pyatv en ligne de commande (`atvremote pair`), pour obtenir les credentials long terme de chaque appareil. pyatv reste activement maintenu (dernière version stable de juin 2026), donc fiable pour cet usage ponctuel.
- Distinction importante entre deux types de logique, traitées différemment :
  - **Primitives cryptographiques** (SRP-6a-3072, X25519, Ed25519, ChaCha20-Poly1305, HKDF-SHA512) : pas de retranscription à la main en Swift. Ce code manipule des buffers et des pointeurs, une erreur de portage (endianness, off-by-one) peut casser la sécurité ou la compatibilité sans symptôme visible en test. À la place : compiler en bibliothèques C statiques des implémentations isolées et éprouvées (`csrp` pour SRP-6a, `curve25519-donna` pour X25519, `ed25519` d'orlp, `chachapoly`), et les piloter depuis Swift via l'interopérabilité C native, sans jamais réécrire la logique elle-même.
  - **Séquence protocolaire** (RTSP SETUP/RECORD, canal d'événements, ordonnancement des messages) : écrite nativement en Swift avec le Network framework, en utilisant le code source d'OwnTone (`airplay.c`) comme référence de comportement pour obtenir l'ordre et le contenu exacts des messages, pas comme code à porter littéralement. Cette partie est un enchaînement logique, pas de la manipulation mémoire sensible, donc adaptée à une réécriture directe.
- Point de vigilance : l'ancien projet `openairplay/ap2-sender`, dont la liste de dépendances (`csrp`, `curve25519-donna`, `ed25519`, `chachapoly`, `rfc6234`) reste pertinente et reprise ci-dessus, est lui-même à l'arrêt depuis 2020 (13 commits, aucune release) et n'a pas suivi les évolutions du protocole. Ses bibliothèques crypto restent utilisables (primitives mathématiques stables), mais son code d'intégration ne doit pas servir de référence.

### 4.5 Synchronisation et gestion de la dérive

- Horloge maître unique côté application, un seul process, pas de synchronisation inter-langages à gérer.
- Nuance par rapport à la version précédente de ce document : AirPlay transporte nativement des informations de timing précises (timestamps RTP/NTP) que le récepteur utilise pour son propre calage. Un sender qui implémente correctement cette partie du protocole (ce que fait OwnTone) dispose donc d'un point d'ancrage temporel réel. C'est ce mécanisme qui sert de base à la mesure automatique de latence par sortie (passée en cœur de projet, voir section 2) : il reflète le calage réel du récepteur, contrairement à une mesure de type ping réseau qui ne capturerait que le temps de trajet, négligeable face au buffering interne de chaque récepteur (souvent des centaines de ms).
- Réglage manuel du délai par sortie conservé comme fine-tune et filet de sécurité, pas comme mécanisme principal : la mesure automatique via le canal de timing natif peut rester imprécise dans certains cas (calibration qui devient obsolète si une enceinte est déplacée, par exemple), d'où l'intérêt de garder un ajustement manuel disponible.
- Évolution possible, non retenue par défaut : calibration acoustique par son test et micro (réutilisant le pipeline d'entrée physique déjà prévu en 4.2), mesurant le délai bout-en-bout réel y compris le DAC et le haut-parleur. Plus rigoureuse que le timing protocolaire seul, mais ajoute réellement 1 à 2 semaines de travail (génération de tonalité, corrélation du signal capté). À envisager seulement si la mesure via timing natif ne suffit pas en pratique.
- Correction de la dérive : pas d'algorithme de resampling à concevoir de zéro, risque réel de distorsion audible si mal implémenté. Précision d'emplacement, pour lever toute ambiguïté avec la règle de la section 13 : cette correction tourne dans le thread/tâche propre à chaque sender, en aval du ring buffer de la section 12, jamais dans le callback de capture temps réel partagé. Ce n'est donc pas le contexte temps réel dur, Swift Concurrency y est pleinement approprié, et l'appel à une bibliothèque C s'y fait de façon synchrone sans contradiction avec l'interdiction posée en section 13.
- Approche par défaut : technique de Snapcast, ajout ou suppression ponctuelle d'un seul échantillon plutôt qu'un resampling continu, documentée pour maintenir une dérive typique sous 0,2 ms. Point d'implémentation important : la transition doit inclure un court fondu (crossfade sur quelques échantillons), jamais une coupure instantanée, pour éviter l'artefact haute fréquence qu'une coupure brute peut produire sur du matériel qui révèle bien les aigus.
- Escalade conditionnelle, seulement si un test d'écoute réel sur la Geneva/HomePod révèle un problème audible malgré le fondu : passer à un resampling continu à ratio dynamique. Préférer `AVAudioConverter` (natif, aucune dépendance C supplémentaire) en premier choix ; `libsamplerate` ou `soxr` en second recours seulement si `AVAudioConverter` ne convient pas.

## 5. Frameworks et dépendances

- CoreAudio / AudioToolbox pour la capture et la gestion des formats PCM/ASBD.
- Network framework pour les sockets RTSP/RTP.
- Bibliothèques C statiques wrappées via interop Swift, plutôt que du code crypto/DSP réécrit à la main : `csrp` (SRP-6a), `curve25519-donna` (X25519), `ed25519` d'orlp, `chachapoly` (ChaCha20-Poly1305), et `libsamplerate` ou `soxr` pour la correction de dérive si le resampling continu s'avère nécessaire (voir 4.4 et 4.5).
- Aucune dépendance runtime externe côté outils : OwnTone et pyatv n'interviennent qu'en phase de développement, de validation (phase 0) et de pairing initial, jamais au runtime de l'application finale. Les bibliothèques C listées ci-dessus, elles, sont bien des dépendances runtime, compilées et liées statiquement dans l'application.

## 6. Risques et contraintes

- AirPlay 2 est un protocole propriétaire non documenté officiellement par Apple. La logique portée depuis OwnTone ou pyatv peut cesser de fonctionner après une mise à jour tvOS ou HomePod, sans préavis ni voie de recours officielle.
- Maintenance à prévoir à chaque mise à jour majeure côté Apple, sans garantie de compatibilité long terme. OwnTone étant un projet communautaire actif avec un historique de plusieurs années de suivi des changements Apple, le risque de rupture silencieuse est réel mais mieux couvert que sur un projet abandonné.
- Tests dépendants du matériel réel : pas de simulateur fiable pour AirPlay 2.
- Debug limité au-delà de la négociation initiale : le trafic AirPlay 2 est chiffré, l'inspection Wireshark au-delà du handshake nécessite de logger soi-même les clés de session.
- Un repository trouvé en recherche (`akustikrausch/airplay2-sender-cpp`) se présente en langage commercial et promeut un produit tiers ; ses affirmations techniques ne sont pas vérifiables indépendamment et ne doivent pas être prises comme source de référence sans validation propre, même si certains détails cités (clé audio dérivée du secret de pairing, ordre RECORD/event channel) recoupent ce qui s'observe dans le code d'OwnTone.
- DRM / contenu protégé : comportement du Process Tap non confirmé face à FairPlay ou à d'autres protections. Les précédents historiques (Airfoil, Loopback, BlackHole captent Apple Music sans blocage documenté) suggèrent que ce n'est probablement pas un blocage systématique, le DRM protégeant le fichier chiffré et non les échantillons PCM déjà décodés au moment de la capture. Mais l'API étant récente et peu documentée par Apple, ce point reste à vérifier empiriquement en phase 1 plutôt qu'à trancher par supposition.

## 7. Phasage indicatif

| Phase | Contenu | Durée estimée |
|---|---|---|
| 0 | Validation avec OwnTone existant (installation, pipe audio, test réel Geneva + Apple TV/HomePod simultané) | 2 à 5 jours |
| 1 | Capture Core Audio et lecture locale, y compris test du comportement face à du contenu DRM (Apple Music, Netflix/Safari) | 1 à 2 semaines |
| 2 | Sender RAOP pour la Geneva | 2 à 3 semaines |
| 3 | Sender AirPlay 2 pour Apple TV/HomePod | 4 à 8 semaines |
| 4 | Synchronisation et correction de dérive | 2 à 4 semaines |
| 5 | Intégration, interface minimale, stabilisation | 1 à 2 semaines |

Total estimé : 3 à 5 mois à temps partiel, hors phase 0. La phase 3 constitue la principale zone d'incertitude, sa durée dépend de la réaction du matériel réel face au pairing porté depuis OwnTone/pyatv. La phase 0 n'engage presque aucun coût de développement et peut invalider ou renforcer la décision de poursuivre avant d'investir dans les phases 1 à 5.

Contrainte de démarrage : le développement débute sans accès au matériel AirPlay réel (absence physique temporaire, pas un choix de conception). La phase 0, qui nécessite le matériel réel, est donc décalée à la prochaine présence physique plutôt que de bloquer le début du développement : les phases 1 à 5 démarrent directement contre les émulateurs logiciels décrits dans le guide d'installation (`shairport-sync`, `airplay2-receiver`), rien n'empêche d'avancer significativement ainsi. Voir section 14 pour le détail de ce que chaque jalon peut valider sans matériel réel.

## 8. Critères de validation

- Diffusion simultanée sans coupure vers la Geneva et le groupe Apple TV/HomePod pendant plus d'une heure, sans désynchronisation audible.
- Volume réglable indépendamment par sortie, sans effet sur les autres sorties.
- Reprise automatique après une perte de connexion réseau temporaire sur une sortie, sans redémarrage de l'application.
- Décalage résiduel corrigeable, automatiquement via le timing natif AirPlay en priorité, manuellement en secours, en dessous du seuil de perception humaine, de l'ordre de 20 à 30 ms.

## 9. Évolutions envisageables hors périmètre initial

- Prise en charge d'appareils supplémentaires en cas d'acquisition de nouveau matériel.
- **Contrôle à distance depuis un téléphone** : une page web légère servie par un petit serveur local sur le Mac, accessible depuis le navigateur du téléphone sur le même réseau, pour piloter volume/source/basse à distance. Pas d'app mobile ni de store nécessaire. Effort faible, dans la même logique que le contrôle web déjà présent dans des outils comme OwnTone.
- **Téléphone comme source audio envoyée au Mac** : à distinguer en deux cas très différents. Le micro du téléphone est capturable depuis une simple page web (`getUserMedia` dans Safari iOS, streamé en WebSocket vers le Mac), effort modéré. Le son jouant sur le téléphone lui-même (équivalent de la capture système macOS, mais côté iOS) n'est pas transposable aussi simplement : iOS ne donne pas à une app tierce la même liberté que Process Tap pour capter l'audio système d'autres apps ; ReplayKit, l'API la plus proche, est pensée pour l'enregistrement d'écran et reste contrainte. Ce cas constituerait un sous-projet distinct, pas une extension directe de l'architecture actuelle.
  - Axe de réflexion pour le cas micro : s'appuyer sur les technologies de VoIP (WebRTC) plutôt que sur un flux PCM brut en WebSocket. WebRTC résout déjà nativement la gigue réseau, l'adaptation de débit, la suppression d'écho et la traversée NAT, exactement les problèmes qu'un flux maison devrait sinon réinventer pour un relais audio temps réel fiable entre le téléphone et le Mac.
- **Visualisation de la pièce (plan avec meubles et position des enceintes)** : fonctionnalité d'interface pure, indépendante de tout traitement du signal. Elle sert de repère visuel pour le réglage manuel du délai par sortie (savoir laquelle des enceintes est la plus proche/loin), pas à produire un rendu spatial du son. À ne pas confondre avec la spatialisation 3D écartée en section 3 : celle-ci portait sur le traitement audio, pas sur l'affichage. Deux niveaux d'effort distincts : un plan 2D vu du dessus avec icônes déplaçables (quelques jours, SwiftUI Canvas) ou une scène 3D avec modèles de meubles et navigation caméra (plusieurs semaines, SceneKit, assets 3D à produire ou récupérer). Par défaut, le plan 2D couvre le besoin déclaré ("petit plan") pour un coût nettement inférieur ; la 3D complète n'apporte rien de fonctionnel en plus ici, seulement du confort visuel.
- **Renfort de basses sur la Geneva** : pas de filtre côté HomePod, qui restent en stéréo pleine bande sans traitement, exactement comme prévu à l'origine. Sur la Geneva uniquement, un filtre low shelf (gain augmenté en dessous d'un seuil réglable, par exemple 150 Hz) appliqué à son propre flux. C'est un réglage de tonalité, pas un changement d'architecture : un seul `AVAudioUnitEQ` sur le chemin Geneva, aucun impact sur le groupe Apple TV/HomePod ni sur la synchronisation prévue en 4.5. Toujours 2 sessions AirPlay, contenu identique envoyé aux deux, seule la Geneva reçoit un traitement de tonalité supplémentaire. Contrôle d'interface envisagé : bouton rotatif continu plutôt qu'un simple interrupteur, mappé linéairement sur le gain du filtre (position minimale = 0 dB, aucun changement de code au-delà d'un `@Published` lié au paramètre de l'EQ).
  - Variante plus ambitieuse, non retenue par défaut : un vrai renfort type caisson de basse, où la Geneva rejouerait en plus les graves déjà présentes dans le mix des HomePod. Risque réel d'interférences constructives/destructives entre les deux sources selon l'alignement temporel (effet de peigne), ce qui reporterait une exigence de synchronisation fine supplémentaire sur la section 4.5. À envisager seulement si le simple boost EQ ne suffit pas à l'usage.

La spatialisation 3D n'apparaît pas dans cette liste : elle a été écartée comme non réalisable dans cette architecture, sauf abandon complet d'AirPlay au profit d'un protocole propriétaire point à point synchronisé au sample près, ce qui constituerait un projet distinct.

## 10. Annexe : bibliothèques et projets de référence

État vérifié au moment de la rédaction de ce document.

| Projet | Rôle pour ce projet | État constaté |
|---|---|---|
| [owntone/owntone-server](https://github.com/owntone/owntone-server) | Référence principale pour le sender AirPlay 1+2 et la synchronisation multiroom ; base de test pragmatique en phase 0 | Actif, releases régulières (27.x en cours), ~2,5k étoiles, tourne sur macOS |
| [insidegui/AudioCap](https://github.com/insidegui/AudioCap) | Exemple de référence pour la capture via Core Audio Process Tap (section 4.2) | Projet de documentation ciblé macOS 14.4+, maintenu par un développeur macOS reconnu |
| [postlund/pyatv](https://github.com/postlund/pyatv) | Outil de pairing/credentials AirPlay 2 en amont du développement | Actif, licence MIT, version 0.18.0 publiée en juin 2026 |
| [badaix/snapcast](https://github.com/badaix/snapcast) | Référence d'architecture pour la correction de dérive par resampling (section 4.5) | Actif, projet de référence du secteur pour le multiroom synchronisé |
| [openairplay/ap2-sender](https://github.com/openairplay/ap2-sender) | Intégration abandonnée, mais liste de dépendances crypto pertinente et reprise (voir ci-dessous) | À l'arrêt depuis septembre 2020, 13 commits, aucune release |
| [openairplay/airplay2-receiver](https://github.com/openairplay/airplay2-receiver) | Utile pour la partie pairing/chiffrement (symétrique entre émission et réception), pas pour la partie sender à proprement parler. Sert aussi d'émulateur de test pour le jalon 3 (voir guide d'installation) | Actif, ~2,3k étoiles, mais expérimental de son propre aveu ("experimental, yet fully functional", n'implémente pas tous les protocoles/méthodes d'authentification) : un handshake qui passe contre cet émulateur n'est pas une garantie de fonctionnement contre le vrai firmware Apple |
| `csrp`, `curve25519-donna`, `ed25519` (orlp), `chachapoly` | Bibliothèques C isolées pour les primitives crypto AirPlay 2 (section 4.4), à wrapper via interop Swift plutôt qu'à retranscrire | Primitives mathématiques stables, ne nécessitent pas de suivi actif contrairement à un projet d'intégration complet |
| `libsamplerate` / `soxr` | Bibliothèques de resampling éprouvées pour la correction de dérive (section 4.5), si le resampling continu s'avère nécessaire au-delà de la technique simple de Snapcast | Bibliothèques de référence du secteur audio, stables |

`akustikrausch/airplay2-sender-cpp`, trouvé en recherche, n'est pas retenu comme référence : présentation commerciale, revendications techniques non vérifiables indépendamment, promotion d'un produit tiers. À écarter comme source, même si certains détails cités recoupent le code d'OwnTone.

## 12. Principes architecturaux (invariants)

Ces règles ne sont pas des préférences de style : ce sont des invariants que l'architecture ne doit jamais violer, quel que soit le module qui écrit le code. Utile en particulier pour un développement assisté par agent, qui n'a pas de mémoire tacite du projet d'une session à l'autre.

- Une seule capture Core Audio active à la fois. Jamais deux Process Tap, ou tap et entrée physique, simultanés.
- Le flux PCM capturé est dupliqué en lecture seule vers chaque pipeline de sortie ; aucun sender ni traitement DSP ne modifie le buffer partagé. Toute transformation (EQ, crossover) se fait sur une copie propre à sa sortie, après duplication.
- La capture ne connaît jamais les destinations (Geneva, HomePod) ; les senders ne connaissent jamais la source de capture. Chaque sender ignore l'existence de l'autre.
- Une panne ou déconnexion sur une sortie (ex. la Geneva perd le réseau) n'interrompt jamais la capture ni l'autre sortie ; le sender concerné tente une reconnexion isolée.
- Toute dépendance de code pointe vers le cœur du projet (capture, modèle de données PCM), jamais l'inverse : le module de capture ne doit jamais importer un sender.
- Transfert du callback de capture temps réel vers les threads réseau uniquement via un ring buffer lock-free (un par pipeline de sortie), jamais via une structure verrouillée (mutex, sémaphore) ni via Swift Concurrency à cet endroit précis. L'écriture dans ces ring buffers, effectuée depuis le callback de capture, doit elle-même rester lock-free et sans allocation.
- Toute bibliothèque C wrappée (crypto, resampling) est encapsulée dans une classe Swift dédiée qui gère l'allocation et la désallocation via `deinit` ; aucun pointeur C manipulé à nu en dehors de ce wrapper.

Ces invariants sont volontairement limités à ce qui est déjà certain aujourd'hui. Les contrats plus fins (taille exacte des buffers, modèle de threading détaillé par module, format mémoire précis) dépendent de faits que seules les phases 0 et 1 révéleront (taille réelle des buffers livrés par le Process Tap, comportement observé en pratique). Les figer maintenant reviendrait à spéculer plutôt qu'à documenter, avec le risque de devoir tout réécrire une fois le code réel en main.

## 13. Guide de développement pour agent de code (hors CDC)

Les règles de code détaillées (limite de lignes par fichier, interdiction de `Any`, diagramme de threading complet par module, tables exhaustives de dépendances autorisées/interdites) n'ont pas leur place dans ce document : elles dépendent de faits pas encore connus et méritent d'être vivantes plutôt que figées. Elles iront dans un fichier `CLAUDE.md` (ou équivalent) dans le dépôt de code, enrichi au fil du développement. Base raisonnable pour ce fichier une fois le projet démarré : interdiction du force-unwrap, injection de dépendance par protocole, `OSLog` pour tous les logs, pas de singleton, `fatalError` réservé aux erreurs de programmation non récupérables et non à la gestion d'erreurs runtime.

Correction technique sur un point precis : l'interdiction totale de `Thread`/GCD/`DispatchSemaphore` au profit de Swift Concurrency partout ne s'applique pas au callback audio temps réel (rendu Core Audio). Ce contexte a des contraintes dures où le scheduling coopératif de Swift Concurrency est déconseillé par la pratique courante en audio pro sur Apple, à cause du risque d'ordonnancement non garanti et d'inversion de priorité. Cette partie du code utilisera plutôt des callbacks C classiques et des structures lock-free, sans allocation. Swift Concurrency reste approprié pour le reste (UI, réseau de contrôle, gestion de session, y compris le resampling en aval du ring buffer, voir 4.5 et 12), mais pas pour le thread de rendu audio lui-même.

Limite connue de `PROGRESS.md`/`CLAUDE.md` comme mémoire d'agent : un agent perdra probablement les nuances fines (ex. règles précises de gestion mémoire d'un wrapper C) s'il doit les redéduire de son propre résumé d'une session à l'autre. Les règles à fort enjeu (ownership mémoire, invariants de la section 12) doivent être écrites explicitement et littéralement dans ces fichiers, pas laissées à la reformulation de l'agent.

## 14. Jalons et prompts de développement

Cette section formalise le phasage de la section 7 en jalons actionnables pour un développement assisté par Claude Code, avec un prompt de démarrage par jalon et une procédure de clôture commune à tous.

Statut de développement actuel : le développement démarre sans accès au matériel AirPlay réel, par contrainte (absence physique temporaire au démarrage), pas par choix de conception. Chaque jalon ci-dessous se développe et se valide d'abord contre les émulateurs logiciels du guide d'installation (`shairport-sync` pour la Geneva, `airplay2-receiver` pour l'Apple TV/HomePod). Un jalon marqué "terminé" dans ces conditions signifie développement complet et validé contre mock, pas encore confirmé contre le matériel réel : la validation finale contre le vrai matériel reste une étape distincte, à faire à la prochaine présence physique (ou via accès distant à une machine restée chez toi, voir guide d'installation section 1).

### Jalon -1 : setup initial (automatisé)

Avant le jalon 0, exécuter `./setup.sh` à la racine du dépôt (script fourni, voir guide d'installation). Ce script installe Homebrew et les paquets nécessaires, configure et prépare les deux émulateurs (`shairport-sync` en Geneva-Mock, `airplay2-receiver` en ApTV-HomePod-Mock), installe pyatv, et crée `CLAUDE.md`/`PROGRESS.md`/`docs/` s'ils n'existent pas. Il est idempotent, relançable sans risque. Il ne couvre pas les bibliothèques C de la section 10 (csrp, curve25519-donna, ed25519, chachapoly) : leurs sources exactes doivent être vérifiées et récupérées explicitement au jalon 3, pas automatisées à l'aveugle par prudence sur l'exactitude des dépôts.

```
Contexte : guide d'installation, section 3 (mise en place des émulateurs).
Tâche : exécute ./setup.sh à la racine du dépôt. Vérifie que shairport-sync se lance et apparaît comme "Geneva-Mock" dans le sélecteur AirPlay, et que airplay2-receiver se lance et apparaît comme "ApTV-HomePod-Mock". Documente le résultat dans PROGRESS.md avant de passer au jalon 1.
```

### Procédure de clôture, identique à chaque jalon

Avant de passer au jalon suivant :

1. Mettre à jour `PROGRESS.md` à la racine du dépôt : ce qui a été fait, les décisions prises qui ne figuraient pas dans ce CDC, les problèmes rencontrés et comment ils ont été résolus, ce qui reste ouvert. Distinguer explicitement "validé contre mock" et "validé contre matériel réel" tant que l'accès au matériel réel n'est pas confirmé.
2. Si un fait concret et durable a été découvert (taille réelle d'un buffer, comportement observé d'une API), l'ajouter à `CLAUDE.md` (section 13), pas à ce CDC.
3. Commit git référençant le jalon, par exemple `jalon 1: capture Core Audio validée (3 modes + test DRM)`.
4. Démarrer le jalon suivant dans une nouvelle session Claude Code, qui doit lire `PROGRESS.md` et `CLAUDE.md` avant toute chose. C'est le mécanisme réel qui fait office de mémoire persistante d'un jalon à l'autre : Claude Code n'a pas de mémoire automatique du projet d'une session à l'autre en dehors de ces deux fichiers et de l'historique git.

### Jalon 0 : validation OwnTone (décalé à la prochaine présence physique)

Objectif : vérifier si OwnTone seul résout déjà le besoin fonctionnel avant d'investir dans le développement natif (section 4.1). Ce jalon nécessite le matériel réel et n'est donc pas fait en premier dans les conditions actuelles ; il peut se faire en parallèle ou après les premiers jalons natifs, dès qu'un accès physique (ou distant) au réseau domestique est possible.

```
Contexte : cahier des charges dans docs/cahier_des_charges_diffusion_audio.md, section 4.1 et phase 0 du tableau en section 7.
Tâche : installe OwnTone sur ce Mac, configure une entrée pipe recevant le son système, connecte-le en sortie simultanée vers la Geneva (AirPlay 1) et le groupe Apple TV/HomePod (AirPlay 2). Documente chaque étape et le résultat dans PROGRESS.md. Le but est de vérifier si la diffusion simultanée fonctionne sans coupure, pas encore d'écrire de code Swift.
```

### Jalon 1 : capture Core Audio

Objectif : les trois modes de capture (section 4.2) fonctionnent en CLI, avec test explicite du comportement face au DRM.

```
Contexte : docs/cahier_des_charges_diffusion_audio.md, section 4.2, invariants section 12 (une seule capture active à la fois, la capture ne connaît jamais les destinations).
Lis PROGRESS.md et CLAUDE.md avant de commencer.
Tâche, dans cet ordre précis : commence par un script minimal de capture système global qui dump vers un .wav, et teste-le en premier contre un flux Apple Music et une vidéo Netflix dans Safari, avant d'écrire quoi que ce soit d'autre. Note le résultat dans PROGRESS.md (voir section 6, risque DRM). Seulement après ce test, développe le reste : les 3 modes de capture complets (système global, application spécifique, entrée physique), avec un exécutable CLI, dump .wav pour chaque mode, ring buffer lock-free en sortie du callback de capture (section 12).
Respecte les invariants de la section 12 sans exception.
```

### Jalon 2 : sender RAOP (Geneva)

```
Contexte : section 4.3, invariants section 12.
Lis PROGRESS.md et CLAUDE.md avant de commencer.
Le mock Geneva (shairport-sync) est déjà configuré et lancé via ./setup.sh (jalon -1). Vérifie qu'il tourne, sinon relance-le.
Tâche : implémente un sender RAOP (RTSP + RTP + ALAC) qui prend le flux PCM du CLI existant et le diffuse vers ce mock. Valide par comparaison Wireshark avec une session Airfoil ou macOS natif fonctionnelle vers le même appareil. Le sender ne doit jamais modifier le buffer PCM partagé (invariant section 12). Documente dans PROGRESS.md que cette validation est faite contre mock, pas encore contre la vraie Geneva.
```

### Jalon 3 : sender AirPlay 2 (Apple TV/HomePod)

```
Contexte : section 4.4, annexe section 10 (csrp, curve25519-donna, ed25519, chachapoly), invariants section 12.
Lis PROGRESS.md et CLAUDE.md avant de commencer.
Le mock Apple TV/HomePod (airplay2-receiver) est déjà cloné et préparé via ./setup.sh (jalon -1). Lance-le : cd tools/airplay2-receiver && source proto/bin/activate && python ap2-receiver.py -m ApTV-HomePod-Mock --netiface=en0 (adapte l'interface si besoin, vérifie avec ifconfig). Une seule instance suffit puisque le sender adresse ce groupe comme une seule destination, jamais les HomePod individuellement.
Recherche et récupère les sources exactes des bibliothèques C (csrp, curve25519-donna, ed25519 d'orlp, chachapoly) dans Sources/CCrypto, en vérifiant toi-même les dépôts corrects avant de les vendre (non automatisé par ./setup.sh par prudence).
Tâche : compile ces bibliothèques, wrappe chacune dans une classe Swift dédiée avec désallocation via deinit (invariant section 12). Écris des tests unitaires stricts contre les vecteurs de test de référence (RFC officiels) pour chaque primitive (SRP-6a, X25519, Ed25519, ChaCha20-Poly1305), et ne passe à l'intégration réseau qu'une fois ces tests verts. Réalise ensuite le pairing initial via pyatv en CLI pour obtenir les credentials, contre ce mock d'abord. Implémente la séquence RTSP (SETUP, RECORD, canal d'événements) nativement en Swift avec le Network framework, en te référant au code source d'OwnTone (airplay.c) pour l'ordre exact des messages, sans le porter littéralement. Documente dans PROGRESS.md que cette validation est faite contre mock, pas encore contre le vrai Apple TV/HomePod.
```

### Jalon 4 : synchronisation et dérive

```
Contexte : section 4.5, invariants section 12.
Lis PROGRESS.md et CLAUDE.md avant de commencer.
Tâche : implémente l'alignement automatique par sortie via le canal de timing natif AirPlay (NTP/RTP), pas via un ping réseau qui ne capturerait pas le buffering interne des récepteurs. Ajoute un réglage manuel par sortie en fine-tune/secours. Implémente ensuite la correction de dérive par ajout/suppression ponctuelle d'un seul échantillon (technique Snapcast, section 4.5), avant d'envisager un resampling continu via libsamplerate/soxr si nécessaire. Valide sur plus d'une heure de lecture continue (critère section 8).
```

### Jalon 5 : intégration et interface

```
Contexte : sections 2, 9, 11, 13.
Lis PROGRESS.md et CLAUDE.md avant de commencer.
Tâche : construis l'interface SwiftUI (liste des sorties, volume, délai, sélecteur de source, bouton rotatif de renfort de basse sur la Geneva uniquement). Branche-la sur la bibliothèque cœur existante sans dupliquer sa logique. Vérifie les critères de validation de la section 8.
```

## 11. Méthodologie de développement et outillage

- Développement en package Swift structuré en deux parties : une bibliothèque cœur (capture, senders, DSP) sans aucune dépendance à une interface, plus un exécutable en ligne de commande minimal pour valider chaque étape avant d'écrire la moindre vue. Concrètement : dump du flux capturé dans un fichier `.wav` et lecture via `afplay` pour valider la capture, logs (`Logger`) pour suivre l'état des sessions AirPlay et la valeur des paramètres DSP. Chaque phase du tableau en section 7 se valide ainsi au terminal avant tout travail d'interface.
- Outillage : les jalons 1 à 4 ne nécessitent que les Xcode Command Line Tools (`swift build`/`swift run`), pas Xcode lui-même. Claude Code peut donc s'utiliser en terminal ou via son extension officielle VS Code pour cette majorité du projet. Xcode (ou son intégration native avec le Claude Agent SDK depuis la version 26.3) devient nécessaire seulement au jalon 5, pour l'interface SwiftUI, les Previews visuelles, et la signature finale de l'application.
- Ordre d'implémentation suggéré pour la capture : commencer par le mode entrée physique (`AVAudioEngine.inputNode`), le plus simple et le mieux documenté des trois modes décrits en 4.2, pour valider les senders RAOP/AirPlay 2 avec une source fiable avant de s'attaquer au Process Tap, plus récent et moins documenté.
- Interface graphique à construire directement en SwiftUI dans le projet Xcode, pas via un outil de maquettage externe pour ce projet précis. Un outil de mockup ajoute une étape de traduction manuelle vers SwiftUI, sans bénéfice réel pour une interface de cette taille (liste de sorties, volume, délai, sélecteur de source, bouton de renfort de basse). Ce choix se reconsidère seulement si le plan de la pièce (section 9) prend une ampleur visuelle qui justifierait une exploration graphique séparée avant implémentation.
- Choix de Swift plutôt que Flutter pour l'ensemble de l'application : le cœur du projet (capture Core Audio, protocoles AirPlay 1/2, cryptographie, DSP) repose sur des frameworks système qui n'existent qu'en Swift/Objective-C/C. Flutter ne pourrait habiller que la couche interface, en communiquant avec ce cœur natif via platform channels ou FFI, sans jamais remplacer la partie qui concentre l'effort réel (sections 4.2 à 4.5). Son intérêt principal, la portabilité multi-plateforme, ne s'applique pas à ce projet explicitement limité à macOS (section 3). Décision : SwiftUI natif, pas de bridge ni de toolchain supplémentaire.
