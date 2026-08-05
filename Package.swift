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
        // SwiftPM ne connaît que les versions majeures/mineures ici : .v14 correspond à
        // 14.0, d'où l'attribut @available(macOS 14.2) sur ProcessTapCapture lui-même.
        .macOS(.v15)
    ],
    dependencies: [
        // Primitives atomiques pour le ring buffer lock-free (invariant section 12).
        // Bibliothèque officielle Apple ; l'alternative serait d'appeler les atomiques C
        // à la main, ce qui contredirait la règle « aucun pointeur C manipulé à nu ».
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0")
    ],
    targets: [
        // Cœur : capture, senders, DSP. Ne connaît aucune interface, ne dépend d'aucun
        // exécutable. Invariant section 12 : toute dépendance de code pointe vers ce cœur.
        .target(
            name: "AudioCore",
            dependencies: [.product(name: "Atomics", package: "swift-atomics")],
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
            dependencies: ["AudioCore"],
            path: "Tests/AudioCoreTests"
        ),
    ]
)
