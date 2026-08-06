# Sources/CCrypto — primitives cryptographiques AirPlay 2

Bibliothèques C **vendues telles quelles**, jamais retranscrites en Swift.

Le CDC 4.4 l'impose : ce code manipule des buffers et des pointeurs, et une erreur de
portage (endianness, off-by-one) peut casser la sécurité ou la compatibilité **sans
symptôme visible en test**. Chacune est pilotée depuis Swift par un wrapper dédié
(`Sources/AudioCore/AirPlay2/Crypto/`) qui gère allocation et désallocation via `deinit` ;
aucun pointeur C n'est manipulé à nu en dehors de ces wrappers (invariant section 12).

Le CDC (section 14, jalon -1) exclut volontairement ces dépôts de `./setup.sh` : leurs
sources exactes doivent être vérifiées à la main, pas récupérées à l'aveugle. Chaque dépôt
ci-dessous a donc été ouvert et vérifié individuellement au jalon 3 avant vendorisation.

## Provenance

| Dossier | Dépôt amont | Commit vendu | Licence |
|---|---|---|---|
| `CEd25519` | [orlp/ed25519](https://github.com/orlp/ed25519) | `b1f19fa` | zlib |
| `CCurve25519` | [agl/curve25519-donna](https://github.com/agl/curve25519-donna) | `f7837ad` | BSD 3-clause |
| `CChachaPoly` | [grigorig/chachapoly](https://github.com/grigorig/chachapoly) | `ec7d8e0` | MIT |
| `CSRP` | [cocagne/csrp](https://github.com/cocagne/csrp), branche `rfc5054_compat` | `b1a6ebc` | MIT |

Ce sont les quatre bibliothèques nommées par l'annexe du CDC (section 10). Le CDC y note
aussi que `openairplay/ap2-sender`, d'où vient cette liste, est à l'arrêt depuis 2020 :
**seules ses dépendances crypto sont reprises, jamais son code d'intégration.** Les
primitives mathématiques sont stables et ne demandent pas de suivi actif, contrairement à
un projet d'intégration protocolaire.

## Écarts par rapport à l'amont

Aucune modification du code cryptographique lui-même. Trois écarts de packaging seulement :

1. **`CEd25519` : `seed.c` retiré.** Il tire son entropie de `/dev/urandom` en C ; le projet
   sème depuis Swift. La macro `ED25519_NO_SEED` (déclarée dans `Package.swift`) neutralise
   la déclaration correspondante dans `ed25519.h`, laissé intact par ailleurs.
2. **`CCurve25519` : en-tête ajouté.** L'amont ne fournit aucun `.h`, seulement les `.c`.
   SwiftPM exige un en-tête public dans `include/` pour exposer le symbole au module map.
   `include/curve25519-donna.h` recopie la déclaration de `curve25519-donna-c64.c` (ligne
   430) en explicitant `u8` en `uint8_t`. C'est le seul fichier de ce dossier écrit ici.
   Seule la variante `-c64` est vendue : elle exige un entier 128 bits natif, disponible sur
   Apple Silicon.
3. **`CSRP` : compilé contre l'OpenSSL de Homebrew.** C'est la seule des quatre à avoir une
   dépendance externe (BIGNUM, pour l'arithmétique modulaire). Elle n'est pas contournable
   sans réécrire la partie mathématique, ce que le CDC 4.4 proscrit. Les API
   `SHA*_Init/Update/Final` sont dépréciées dans OpenSSL 3 mais fonctionnelles :
   l'avertissement est réduit au silence dans `Package.swift`, pas dans le code vendu.

Les en-têtes publics sont placés dans `include/`, le reste à la racine du dossier : c'est la
disposition attendue par SwiftPM pour une cible C.

## Pourquoi csrp convient malgré son README

Le README de csrp met en avant `SRP_SHA1` et `SRP_NG_2048`. AirPlay 2 exige **SRP-6a en
SHA-512 sur le groupe 3072 bits**. La bibliothèque le couvre : `SRP_HashAlgorithm` inclut
`SRP_SHA512`, et `SRP_NG_CUSTOM` accepte `N` et `g` en hexadécimal — c'est par là que passe
le groupe 3072 bits d'AirPlay. Vérifié dans `srp.h` avant de retenir la bibliothèque.

## Écart local dans `CSRP/srp.c` (jalon 3)

**Branche vendue : `rfc5054_compat` (commit `b1a6ebc`), pas `master`.** AirPlay 2 suit la
convention RFC 5054, qui bourre `u = H(A, B)` et `k = H(N, g)` de zéros à gauche jusqu'à la
largeur du module (384 octets). `master` concatène sans bourrage. Les deux produisent une
preuve de la bonne taille : l'écart ne se voit qu'au refus du récepteur.

**Une modification locale de six lignes** a été appliquée en plus, dans `calculate_M` : le
`padding` y est forcé à 0. L'amont bourre `g` avant d'en prendre le condensat dès que
`rfc5054_compat` est armé ; **AirPlay 2 ne le fait pas** — il calcule `H(g)` sur l'octet
`0x05` seul, tout en bourrant bien `u` et `k`. C'est un hybride qu'aucun réglage du drapeau
n'exprime.

Vérifié contre l'implémentation de référence du récepteur (`ap2/pairing/srp.py`
d'airplay2-receiver) : `H(self.N) ^ H(self.g)` y est appelé **sans** `pad=True`, alors que
`u` et `k` le sont. Diagnostiqué en instrumentant le mock pour comparer les deux côtés :
`A`, `B`, le sel et toutes les longueurs concordaient octet pour octet, seule la preuve
`M1` différait.

La modification est signalée par un commentaire dans le fichier. Elle ne touche pas
l'arithmétique de SRP, seulement le choix des opérandes d'un condensat.
