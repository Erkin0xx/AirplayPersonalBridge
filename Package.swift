// swift-tools-version: 6.0
import PackageDescription

// Structure imposée par le CDC section 11 : une bibliothèque cœur sans aucune dépendance
// à une interface, plus un exécutable CLI minimal pour valider chaque étape avant
// d'écrire la moindre vue.
let package = Package(
    name: "AirPlayMultiOutput",
    platforms: [
        // Process Tap (AudioHardwareCreateProcessTap) : macOS 14.2+. Le mode entrée
        // physique (AVAudioEngine) n'a pas cette contrainte, mais la cible du package
        // s'aligne sur le plus exigeant des trois modes de capture (CDC 4.2).
        // Valeur à garder alignée sur MACOSX_DEPLOYMENT_TARGET de la cible Xcode et sur
        // LSMinimumSystemVersion de Resources/audiocap-Info.plist.
        .macOS(.v15)
    ],
    products: [
        // Le cœur exposé comme bibliothèque, pour que l'app SwiftUI du jalon 5 puisse le
        // lier depuis Xcode (CDC section 11 : l'interface se branche sur le cœur existant
        // sans en dupliquer la logique). La dépendance reste à sens unique — AudioCore
        // ignore toujours qu'une interface existe.
        .library(name: "AudioCore", targets: ["AudioCore"]),
    ],
    dependencies: [
        // Primitives atomiques pour le ring buffer lock-free (invariant section 12).
        // Bibliothèque officielle Apple ; l'alternative serait d'appeler les atomiques C
        // à la main, ce qui contredirait la règle « aucun pointeur C manipulé à nu ».
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0")
    ],
    targets: [
        // --- Primitives cryptographiques AirPlay 2 (CDC 4.4 + annexe section 10) ---
        //
        // Ces quatre bibliothèques C sont vendues telles quelles, jamais retranscrites en
        // Swift : le CDC 4.4 l'interdit explicitement, une erreur de portage (endianness,
        // off-by-one) cassant la sécurité ou la compatibilité sans symptôme visible en test.
        // Chacune est pilotée depuis Swift par un wrapper dédié qui gère l'allocation et la
        // désallocation via deinit (invariant section 12) ; aucun pointeur C n'est manipulé
        // à nu en dehors de ces wrappers.
        //
        // Dépôts vérifiés un par un au jalon 3 (non automatisé par ./setup.sh, par prudence
        // sur l'exactitude des dépôts) — commits vendus notés dans Sources/CCrypto/README.md.

        // Ed25519 (orlp/ed25519, portage SUPERCOP ref10, licence zlib).
        // seed.c est volontairement écarté : il tire son entropie de /dev/urandom en C,
        // alors que le projet sème depuis Swift (SystemRandomNumberGenerator). D'où
        // ED25519_NO_SEED, qui neutralise aussi la déclaration correspondante de l'en-tête.
        .target(
            name: "CEd25519",
            path: "Sources/CCrypto/CEd25519",
            cSettings: [.define("ED25519_NO_SEED")]
        ),

        // X25519 (agl/curve25519-donna). La variante c64 exige un entier 128 bits natif,
        // disponible sur Apple Silicon comme sur tout arm64/x86_64.
        .target(
            name: "CCurve25519",
            path: "Sources/CCrypto/CCurve25519"
        ),

        // ChaCha20-Poly1305 AEAD conforme RFC 7539 (grigorig/chachapoly, licence MIT).
        // Le renommage évite un conflit au lien statique avec libcrypto.a, dont l'objet
        // poly1305-armv8.o exporte aussi `poly1305_init` (aucun autre symbole en commun,
        // vérifié par `nm`) : la macro laisse le code vendu intact. Aucun appel Swift ne
        // passe par ce symbole, seul chachapoly.c s'en sert.
        .target(
            name: "CChachaPoly",
            path: "Sources/CCrypto/CChachaPoly",
            cSettings: [.define("poly1305_init", to: "cchachapoly_poly1305_init")]
        ),

        // SRP-6a (cocagne/csrp, licence MIT). Seule des quatre à avoir une dépendance
        // externe : elle s'appuie sur le BIGNUM d'OpenSSL pour l'arithmétique modulaire.
        // Cette dépendance n'est pas contournable sans réécrire la partie mathématique,
        // ce que le CDC 4.4 proscrit — d'où le lien vers l'OpenSSL de Homebrew.
        // Les API SHA*_Init/Update/Final sont dépréciées dans OpenSSL 3 mais toujours
        // fonctionnelles ; l'avertissement est réduit au silence pour garder un build propre.
        //
        // Lien STATIQUE, par le chemin complet de l'archive : `-lcrypto` choisirait la
        // .dylib, et une app liée à /opt/homebrew ne démarre plus après un `brew upgrade`
        // ou un retrait de Homebrew. OpenSSL reste requis à la compilation, plus à
        // l'exécution (`scripts/install-app.sh` vérifie avec `otool -L` qu'aucune
        // référence à /opt/homebrew ne subsiste).
        //
        // `-w` coupe les avertissements de l'éditeur de liens : la bouteille Homebrew est
        // compilée pour macOS 26, plus récent que la cible de déploiement, et ld en émet un
        // par objet de l'archive (838 à chaque lien, qui noient tout le reste dans Xcode).
        // Ce n'est pas anodin : le binaire exige de fait la version de macOS de la bouteille.
        .target(
            name: "CSRP",
            path: "Sources/CCrypto/CSRP",
            cSettings: [
                .unsafeFlags([
                    "-I/opt/homebrew/opt/openssl@3/include",
                    "-Wno-deprecated-declarations",
                ])
            ],
            linkerSettings: [
                .unsafeFlags(["/opt/homebrew/opt/openssl@3/lib/libcrypto.a", "-Xlinker", "-w"]),
            ]
        ),

        // Cœur : capture, senders, DSP. Ne connaît aucune interface, ne dépend d'aucun
        // exécutable. Invariant section 12 : toute dépendance de code pointe vers ce cœur.
        .target(
            name: "AudioCore",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
                "CEd25519",
                "CCurve25519",
                "CChachaPoly",
                "CSRP",
            ],
            path: "Sources/AudioCore"
        ),
        // CLI de validation : dump .wav, logs. Dépend du cœur, jamais l'inverse.
        .executableTarget(
            name: "audiocap",
            dependencies: ["AudioCore"],
            path: "Sources/audiocap"
        ),
        .testTarget(
            name: "AudioCoreTests",
            // CSRP est en dépendance directe des tests : ils implémentent le **côté
            // serveur** de SRP (srp_verifier_*) pour donner un partenaire au client dans
            // les tests unitaires. Le projet étant un sender, ce côté n'existe pas en
            // production — il n'a donc pas sa place dans AudioCore.
            dependencies: ["AudioCore", "CSRP"],
            path: "Tests/AudioCoreTests"
        ),
    ]
)
