# Guide pratique : installation, environnement de test, validation des jalons

Document compagnon du cahier des charges, pensé pour toi : quoi installer, dans quel ordre, et comment savoir si un jalon est bon sans forcément être chez toi.

## 1. Est-ce que ne pas être chez toi bloque le développement ?

Non, pas pour l'essentiel, à condition d'installer deux émulateurs logiciels de récepteurs AirPlay (détaillés en section 2). Répartition réelle par jalon :

| Jalon | Nécessite le matériel réel chez toi ? |
|---|---|
| 0 - Validation OwnTone | Oui, obligatoirement, il faut Geneva et Apple TV/HomePod sur le même réseau |
| 1 - Capture Core Audio | Non. Aucune sortie AirPlay impliquée, tout se teste en local sur le Mac. Seul le mode entrée physique (ampli tourne-disque) demande d'être là où l'ampli est branché |
| 2 - Sender RAOP (Geneva) | Non pour l'essentiel : `shairport-sync` fait un récepteur AirPlay 1 logiciel, installable sur n'importe quelle machine, y compris le Mac de dev lui-même. Validation finale contre la vraie Geneva seulement en fin de jalon |
| 3 - Sender AirPlay 2 | Non pour l'essentiel : `openairplay/airplay2-receiver` fait un récepteur AirPlay 2 logiciel en Python. Validation finale contre le vrai Apple TV/HomePod seulement en fin de jalon |
| 4 - Synchronisation | Partiellement testable contre les émulateurs, validation fine de la dérive réelle nécessite le vrai matériel |
| 5 - Interface | Non pour la mise au point. La clôture demande le vrai matériel et une écoute : voir `docs/prompt_tests_materiel.md` |

La seule étape strictement incontournable en présentiel (ou en accès distant à une machine restée chez toi) : le pairing initial AirPlay 2 avec l'Apple TV (jalon 3), parce que la première vérification d'appareil affiche un code PIN sur son écran qu'il faut lire et saisir. Une fois ce pairing fait une fois, les credentials sont stockés et réutilisables. Constaté sur le vrai matériel : les HomePod acceptent le pairing transitoire et n'affichent aucun code, seul l'Apple TV en réclame un.

Si tu veux pouvoir tester contre le vrai matériel même en étant absent : laisse le Mac de dev allumé chez toi avec Partage d'écran ou Connexion à distance (SSH) activé, et connecte-toi dessus à distance (Tailscale simplifie cet accès sans configuration réseau). Lance les tests depuis ce Mac resté sur le réseau local plutôt que depuis un appareil distant : la découverte AirPlay (mDNS/Bonjour) ne traverse pas bien les VPN classiques, donc mieux vaut que le trafic AirPlay reste local au réseau de la maison.

## 2. Ce qu'il faut installer

### Outils de base
- Xcode (dernière version stable), inclut le compilateur Swift et les SDK macOS.
- Homebrew (`https://brew.sh`), gestionnaire de paquets pour tout le reste.
- Git.
- Wireshark (`brew install --cask wireshark-app`), pour comparer le trafic réseau produit par l'application à une session fonctionnelle.

### Émulateurs de récepteurs AirPlay (permettent de développer sans le matériel réel)
- `shairport-sync` (`brew install shairport-sync`) : récepteur AirPlay 1 logiciel, se lance en une commande, apparaît comme une enceinte AirPlay standard sur le réseau. Sert de cible de test pour le sender RAOP du jalon 2, mock de la Geneva.
- `openairplay/airplay2-receiver` (Python) : récepteur AirPlay 2 logiciel expérimental mais fonctionnel. Sert de cible de test pour le sender AirPlay 2 du jalon 3, mock du groupe Apple TV/HomePod. Détail de mise en place en section 3.

### Outils de validation Phase 0
- OwnTone : serveur audio pour la validation initiale avant tout développement natif. N'existe plus dans homebrew-core, à compiler depuis les sources (https://github.com/owntone/owntone-server).

### Outils de pairing AirPlay 2
- Python 3.13 (`brew install python@3.13`) : pyatv ne fonctionne pas sur Python 3.14.
- pyatv, dans un venv dédié (`tools/pyatv313/`, créé par `setup.sh`), utilisé uniquement pour le pairing initial en ligne de commande (`atvremote pair`), jamais au runtime de l'application.

### Bibliothèques C
`csrp` (SRP-6a), `curve25519-donna` (X25519), `ed25519` d'orlp et `chachapoly` (ChaCha20-Poly1305) sont déjà vendues dans `Sources/CCrypto`. Il n'y a rien à récupérer. `csrp` s'appuie sur OpenSSL (`brew install openssl@3`), requis à la compilation seulement car lié en statique.

### Bibliothèque de resampling (si nécessaire au-delà de la technique simple de Snapcast)
- `libsamplerate` (`brew install libsamplerate`) ou `soxr` (`brew install sox`, qui inclut soxr).

### Outil de test audio
- `afplay` (déjà inclus dans macOS), pour écouter les fichiers `.wav` générés pendant les tests de capture.

## 3. Détail : mettre en place les émulateurs (Geneva + récepteur AirPlay 2)

`./setup.sh` installe et configure les deux, et `./run-mocks.sh` (`start`, `check`, `restart`, `stop`) les lance : les étapes ci-dessous ne servent qu'à comprendre ce qu'ils font ou à dépanner. Les pièges vérifiés sont dans `CLAUDE.md`.

Le CDC prévoyait que le sender adresse l'Apple TV et ses HomePod comme une seule destination AirPlay 2. **Sur le vrai matériel, seuls les deux HomePod ont joué, comme deux sorties séparées** ; l'Apple TV exige un `pair-verify` qui n'a jamais abouti. **2 émulateurs suffisent quand même**, un pour chaque protocole : le moteur gère N sorties de la même façon, et ses tests à plusieurs sorties passent par de faux senders.

### 3.1 Mock de la Geneva : `shairport-sync`

```
brew install shairport-sync
```

Fichier de config, à éditer avant le premier lancement. Le binaire lit `/opt/homebrew/etc/shairport-sync/shairport-sync.conf`, dans un sous-dossier. Le backend audio doit être forcé, le défaut `pulseaudio` échouant sans serveur PulseAudio :

```
general =
{
  name = "Geneva-Mock";
  output_backend = "ao";
};
```

Le récepteur AirPlay natif de macOS doit être désactivé : il occupe le port 5000, et cette build ignore `-p`.

Lancer en premier plan pour voir les logs pendant les tests :

```
shairport-sync
```

Ou en service en arrière-plan une fois que ça marche :

```
brew services start shairport-sync
```

"Geneva-Mock" apparaît comme une destination AirPlay dans le sélecteur d'Apple Music, mais pas dans le menu son de la barre de menus, qui n'affiche que les récepteurs AirPlay 2. Le sender RAOP la découvre par `_raop._tcp`.

### 3.2 Mock du récepteur AirPlay 2 : `openairplay/airplay2-receiver`

```
brew install python3 portaudio
git clone https://github.com/openairplay/airplay2-receiver.git
cd airplay2-receiver
python3 -m venv proto
source proto/bin/activate
pip install -r requirements.txt
```

`requirements.txt` épingle une version d'`av` qui ne compile plus sur les Python récents : `setup.sh` relâche ce seul pin. Installation de `pyaudio` séparément, avec les chemins de `portaudio` installés par Homebrew :

```
CFLAGS="-I$(brew --prefix portaudio)/include" \
LDFLAGS="-L$(brew --prefix portaudio)/lib" \
pip install pyaudio
```

Lancement, en précisant l'interface réseau du Mac (`en0` pour le WiFi la plupart du temps, à vérifier avec `ifconfig`) :

```
python ap2-receiver.py -m ApTV-HomePod-Mock --netiface=en0
```

"ApTV-HomePod-Mock" apparaît alors comme une destination AirPlay 2 sur le réseau. Il écoute sur l'adresse d'`en0`, n'accepte qu'une session à la fois, et son annonce périme au bout de quelques minutes : `./run-mocks.sh restart`.

### 3.3 Point de vigilance

Le README du projet le précise lui-même : implémentation expérimentale, qui ne couvre pas toutes les méthodes de pairing/authentification. Un handshake qui réussit contre ce mock est un bon signal de départ, pas une preuve que ça marchera du premier coup contre le vrai firmware Apple (déjà noté au jalon 3 du CDC). Si les deux émulateurs tournent sur la même machine que le code en développement, vérifie qu'il n'y a pas de conflit de port entre eux au premier lancement conjoint.

## 4. Étapes d'installation, dans l'ordre

Un script `setup.sh` automatise les étapes 2 à 7 ci-dessous (Homebrew, paquets, config des deux mocks, pyatv, fichiers de suivi). Claude Code peut l'exécuter directement (voir Jalon -1 du CDC, section 14). Les étapes détaillées restent listées ici pour comprendre ce que fait le script ou dépanner si besoin.

1. Installer Xcode depuis le Mac App Store, lancer une fois pour accepter la licence et installer les composants additionnels.
2. Installer Homebrew.
3. `brew install --cask wireshark-app`
4. `brew install shairport-sync libsamplerate openssl@3 python3 python@3.13 portaudio`
5. Configurer et lancer `shairport-sync` (section 3.1).
6. Cloner et configurer `openairplay/airplay2-receiver` (section 3.2).
7. Créer le venv de pyatv sur Python 3.13 (`tools/pyatv313/`).

Pour installer l'app elle-même : `scripts/setup-signing.sh`, une fois, puis `scripts/install-app.sh --open`.

## 5. Comment savoir qu'un jalon est validé

Une checklist concrète par jalon, à cocher avant de passer au suivant.

**Jalon 0** : la Geneva et le groupe Apple TV/HomePod jouent le même flux simultanément pendant plus d'une heure sans coupure ni désynchronisation perceptible, en partant d'OwnTone seul.

**Jalon 1** : les 3 modes de capture (système global, application spécifique, entrée physique) produisent chacun un fichier `.wav` audible et correct via `afplay`. Le test explicite avec Apple Music et une vidéo Netflix/Safari est documenté dans `PROGRESS.md`, avec le résultat observé (capté ou muet).

**Jalon 2** : le flux capturé arrive correctement sur `shairport-sync` (Geneva-Mock) sans erreur ni coupure, avec une capture Wireshark comparée à une session fonctionnelle. Validation finale : la vraie Geneva reçoit le son sans souci lors d'un passage chez toi.

**Jalon 3** : le pairing avec l'Apple TV/HomePod est fait une fois (PIN saisi), les credentials sont stockés et réutilisés. Le sender fonctionne d'abord contre `airplay2-receiver` (ApTV-HomePod-Mock), puis contre le vrai matériel lors d'un passage chez toi. Ne pas confondre les deux niveaux de confiance : un handshake qui passe contre l'émulateur (expérimental de son propre aveu) est un bon premier signal, pas une garantie contre le vrai firmware Apple. Budgéter du temps de debug Wireshark spécifiquement sur le pairing au moment de basculer sur le matériel réel.

**Jalon 4** : sur plus d'une heure de lecture continue contre le matériel réel, aucune dérive audible, décalage résiduel sous le seuil de perception (20 à 30 ms), mesuré automatiquement via le timing natif AirPlay avec réglage manuel disponible en secours.

**Jalon 5** : tous les critères de la section 8 du CDC sont vérifiés dans l'application complète, interface comprise. Déroulé des essais sur le vrai matériel : `docs/prompt_tests_materiel.md`.
