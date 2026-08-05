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
| 5 - Interface | Non, aucun matériel AirPlay nécessaire |

La seule étape strictement incontournable en présentiel (ou en accès distant à une machine restée chez toi) : le pairing initial AirPlay 2 avec l'Apple TV/HomePod (jalon 3), parce que la première vérification d'appareil affiche un code PIN sur l'écran de l'Apple TV qu'il faut lire et saisir. Une fois ce pairing fait une fois, les credentials sont stockés et réutilisables.

Si tu veux pouvoir tester contre le vrai matériel même en étant absent : laisse le Mac de dev allumé chez toi avec Partage d'écran ou Connexion à distance (SSH) activé, et connecte-toi dessus à distance (Tailscale simplifie cet accès sans configuration réseau). Lance les tests depuis ce Mac resté sur le réseau local plutôt que depuis un appareil distant : la découverte AirPlay (mDNS/Bonjour) ne traverse pas bien les VPN classiques, donc mieux vaut que le trafic AirPlay reste local au réseau de la maison.

## 2. Ce qu'il faut installer

### Outils de base
- Xcode (dernière version stable), inclut le compilateur Swift et les SDK macOS.
- Homebrew (`https://brew.sh`), gestionnaire de paquets pour tout le reste.
- Git.
- Wireshark (`brew install --cask wireshark`), pour comparer le trafic réseau produit par l'application à une session fonctionnelle.

### Émulateurs de récepteurs AirPlay (permettent de développer sans le matériel réel)
- `shairport-sync` (`brew install shairport-sync`) : récepteur AirPlay 1 logiciel, se lance en une commande, apparaît comme une enceinte AirPlay standard sur le réseau. Sert de cible de test pour le sender RAOP du jalon 2, mock de la Geneva.
- `openairplay/airplay2-receiver` (Python) : récepteur AirPlay 2 logiciel expérimental mais fonctionnel. Sert de cible de test pour le sender AirPlay 2 du jalon 3, mock du groupe Apple TV/HomePod. Détail de mise en place en section 3.

### Outils de validation Phase 0
- OwnTone (`brew install owntone`) : serveur audio pour la validation initiale avant tout développement natif.

### Outils de pairing AirPlay 2
- Python 3 (généralement déjà présent sur macOS, sinon `brew install python3`).
- pyatv (`pip install pyatv`), utilisé uniquement pour le pairing initial en ligne de commande (`atvremote pair`), jamais au runtime de l'application.

### Bibliothèques C à intégrer au projet Xcode
Ces bibliothèques ne s'installent pas via Homebrew : leurs sources sont à récupérer et à vendre directement dans le projet (dossier type `Sources/CCrypto`), pour compilation statique et wrapping via interop Swift.
- `csrp` (SRP-6a)
- `curve25519-donna` (X25519)
- `ed25519` d'orlp
- `chachapoly` (ChaCha20-Poly1305)

### Bibliothèque de resampling (si nécessaire au-delà de la technique simple de Snapcast)
- `libsamplerate` (`brew install libsamplerate`) ou `soxr` (`brew install sox`, qui inclut soxr).

### Outil de test audio
- `afplay` (déjà inclus dans macOS), pour écouter les fichiers `.wav` générés pendant les tests de capture.

## 3. Détail : mettre en place les émulateurs (Geneva + groupe Apple TV/HomePod)

Point de départ important, déjà établi dans le CDC : le sender n'adresse jamais les 2 HomePod individuellement, il envoie un flux stéréo unique au groupe Apple TV/HomePod, qui est lui-même une seule destination AirPlay 2 du point de vue de l'application. **Il faut donc seulement 2 émulateurs, pas 3** : un pour la Geneva, un pour tout le groupe Apple TV/HomePod. Émuler 3 appareils séparément ne correspondrait pas à l'architecture réelle et compliquerait la mise en place pour rien.

### 3.1 Mock de la Geneva : `shairport-sync`

```
brew install shairport-sync
```

Fichier de config, à éditer avant le premier lancement (chemin donné par `brew --prefix`, par exemple `/opt/homebrew/etc/shairport-sync.conf`) :

```
general =
{
  name = "Geneva-Mock";
};
```

Lancer en premier plan pour voir les logs pendant les tests :

```
shairport-sync
```

Ou en service en arrière-plan une fois que ça marche :

```
brew services start shairport-sync
```

"Geneva-Mock" doit apparaître comme une destination AirPlay standard dans le sélecteur AirPlay natif de macOS une fois lancé, exactement comme le ferait la vraie Geneva. Le sender RAOP du jalon 2 doit pouvoir la découvrir et s'y connecter de la même façon.

### 3.2 Mock du groupe Apple TV/HomePod : `openairplay/airplay2-receiver`

```
brew install python3 portaudio
git clone https://github.com/openairplay/airplay2-receiver.git
cd airplay2-receiver
pip3 install virtualenv
virtualenv -p $(which python3) proto
source proto/bin/activate
pip install -r requirements.txt
```

Installation de `pyaudio` séparément, avec les chemins de `portaudio` installés par Homebrew. Sur Mac Apple Silicon, Homebrew installe dans `/opt/homebrew` et non `/usr/local` (contrairement à ce qu'indique la doc du projet, écrite pour Intel) : vérifie le chemin exact avec `brew --prefix portaudio` avant de lancer cette commande, et adapte-la :

```
pip install --global-option=build_ext \
  --global-option="-I$(brew --prefix portaudio)/include" \
  --global-option="-L$(brew --prefix portaudio)/lib" \
  pyaudio
```

Lancement, en précisant l'interface réseau du Mac (`en0` pour le WiFi la plupart du temps, à vérifier avec `ifconfig`) :

```
python ap2-receiver.py -m ApTV-HomePod-Mock --netiface=en0
```

"ApTV-HomePod-Mock" apparaît alors comme une seule destination AirPlay 2 sur le réseau, exactement comme le groupe réel. Le sender AirPlay 2 du jalon 3 s'y connecte de la même façon qu'il se connecterait au vrai groupe.

### 3.3 Point de vigilance

Le README du projet le précise lui-même : implémentation expérimentale, qui ne couvre pas toutes les méthodes de pairing/authentification. Un handshake qui réussit contre ce mock est un bon signal de départ, pas une preuve que ça marchera du premier coup contre le vrai firmware Apple (déjà noté au jalon 3 du CDC). Si les deux émulateurs tournent sur la même machine que le code en développement, vérifie qu'il n'y a pas de conflit de port entre eux au premier lancement conjoint.

## 4. Étapes d'installation, dans l'ordre

Un script `setup.sh` automatise les étapes 2 à 7 ci-dessous (Homebrew, paquets, config des deux mocks, pyatv, fichiers de suivi). Claude Code peut l'exécuter directement (voir Jalon -1 du CDC, section 14). Les étapes détaillées restent listées ici pour comprendre ce que fait le script ou dépanner si besoin.

1. Installer Xcode depuis le Mac App Store, lancer une fois pour accepter la licence et installer les composants additionnels.
2. Installer Homebrew.
3. `brew install --cask wireshark`
4. `brew install owntone shairport-sync libsamplerate python3 portaudio`
5. Configurer et lancer `shairport-sync` (section 3.1).
6. Cloner et configurer `openairplay/airplay2-receiver` (section 3.2).
7. Installer Python 3 si besoin, puis `pip install pyatv`.
8. Créer le dépôt git du projet, avec un premier commit contenant ce cahier des charges et ce guide dans un dossier `docs/`.
9. Créer les fichiers `CLAUDE.md` et `PROGRESS.md` vides à la racine, comme point de départ (voir section 13 et 14 du CDC).
10. Récupérer les sources des bibliothèques C listées ci-dessus et les placer dans le projet, avant de démarrer le jalon 3. Non automatisé par `setup.sh`, volontairement : les dépôts exacts doivent être vérifiés au moment du jalon 3 plutôt que figés maintenant.

## 5. Comment savoir qu'un jalon est validé

Une checklist concrète par jalon, à cocher avant de passer au suivant.

**Jalon 0** : la Geneva et le groupe Apple TV/HomePod jouent le même flux simultanément pendant plus d'une heure sans coupure ni désynchronisation perceptible, en partant d'OwnTone seul.

**Jalon 1** : les 3 modes de capture (système global, application spécifique, entrée physique) produisent chacun un fichier `.wav` audible et correct via `afplay`. Le test explicite avec Apple Music et une vidéo Netflix/Safari est documenté dans `PROGRESS.md`, avec le résultat observé (capté ou muet).

**Jalon 2** : le flux capturé arrive correctement sur `shairport-sync` (Geneva-Mock) sans erreur ni coupure, avec une capture Wireshark comparée à une session fonctionnelle. Validation finale : la vraie Geneva reçoit le son sans souci lors d'un passage chez toi.

**Jalon 3** : le pairing avec l'Apple TV/HomePod est fait une fois (PIN saisi), les credentials sont stockés et réutilisés. Le sender fonctionne d'abord contre `airplay2-receiver` (ApTV-HomePod-Mock), puis contre le vrai matériel lors d'un passage chez toi. Ne pas confondre les deux niveaux de confiance : un handshake qui passe contre l'émulateur (expérimental de son propre aveu) est un bon premier signal, pas une garantie contre le vrai firmware Apple. Budgéter du temps de debug Wireshark spécifiquement sur le pairing au moment de basculer sur le matériel réel.

**Jalon 4** : sur plus d'une heure de lecture continue contre le matériel réel, aucune dérive audible, décalage résiduel sous le seuil de perception (20 à 30 ms), mesuré automatiquement via le timing natif AirPlay avec réglage manuel disponible en secours.

**Jalon 5** : tous les critères de la section 8 du CDC sont vérifiés dans l'application complète, interface comprise.
