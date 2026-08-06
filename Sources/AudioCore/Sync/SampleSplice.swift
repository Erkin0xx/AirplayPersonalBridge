import Foundation

/// Ajout et suppression d'**un seul échantillon**, avec fondu — la technique de Snapcast
/// retenue par défaut au CDC 4.5 pour corriger la dérive.
///
/// ## Le principe
///
/// Corriger une dérive d'horloge revient à faire avancer ou reculer le flux d'une fraction
/// d'échantillon par seconde. Plutôt qu'un rééchantillonnage continu à ratio variable — qu'il
/// faudrait concevoir, et dont une erreur produit une distorsion permanente et discrète — on
/// retire ou duplique **une trame**, ponctuellement, quand l'écart accumulé le justifie. Une
/// trame à 44,1 kHz vaut 22,7 µs : l'opération est inaudible si la jonction est propre.
///
/// ## Pourquoi le fondu est obligatoire
///
/// Le CDC 4.5 l'exige explicitement : « la transition doit inclure un court fondu (crossfade
/// sur quelques échantillons), jamais une coupure instantanée, pour éviter l'artefact haute
/// fréquence qu'une coupure brute peut produire sur du matériel qui révèle bien les aigus ».
/// Un saut brut d'une trame crée une discontinuité dont le spectre s'étale sur tout l'aigu —
/// un clic. Étaler la même correction sur ``crossfadeFrames`` trames divise l'amplitude de
/// la discontinuité par autant, et la ramène sous le plancher de bruit du signal.
///
/// Concrètement, l'opération n'est pas « couper puis recoller » mais un glissement progressif
/// d'une trame : sur la fenêtre de fondu, la sortie interpole entre le flux d'origine et le
/// flux décalé d'une trame ; au-delà, elle suit exactement le flux décalé. La correction est
/// donc exacte (une trame, pas 0,98) et sans discontinuité.
///
/// ## Invariant section 12
///
/// Ces fonctions sont **pures** : elles prennent un tableau et en rendent un autre. Elles ne
/// voient jamais le tampon partagé, seulement la copie propre au sender extraite en aval du
/// ring buffer. C'est ce qui rend l'invariant « aucun sender ne modifie le buffer partagé »
/// vérifiable par simple lecture, plutôt que par convention.
public enum SampleSplice {
    /// Longueur de fondu par défaut, en trames. 32 trames = 0,73 ms à 44,1 kHz : assez long
    /// pour que la discontinuité résiduelle soit négligeable, assez court pour que la
    /// correction reste localisée et n'altère aucun transitoire perceptible.
    public static let defaultCrossfadeFrames = 32

    /// Rend `frameCount` trames à partir de `frameCount + 1`, en **supprimant une trame**.
    ///
    /// - Parameters:
    ///   - input: échantillons entrelacés, exactement `(frameCount + 1) * channelCount`.
    ///   - channelCount: nombre de canaux entrelacés.
    ///   - crossfadeFrames: longueur du fondu, en trames.
    /// - Returns: `frameCount * channelCount` échantillons. Le début coïncide avec l'entrée
    ///   (continuité avec le paquet précédent), la fin est l'entrée avancée d'une trame.
    public static func removingOneFrame(
        from input: [Int16],
        channelCount: Int,
        crossfadeFrames: Int = defaultCrossfadeFrames
    ) -> [Int16] {
        precondition(channelCount > 0, "nombre de canaux nul")
        let inputFrames = input.count / channelCount
        guard inputFrames >= 2 else { return input }
        let outputFrames = inputFrames - 1
        let fade = max(1, min(crossfadeFrames, outputFrames))

        var output = [Int16](repeating: 0, count: outputFrames * channelCount)
        for frame in 0..<outputFrames {
            // Poids du flux avancé d'une trame : 0 au départ (on suit l'entrée), 1 au bout
            // du fondu (on suit définitivement le flux avancé).
            let weight = min(1.0, Double(frame + 1) / Double(fade))
            let ahead = min(frame + 1, inputFrames - 1)
            for channel in 0..<channelCount {
                output[frame * channelCount + channel] = blend(
                    input[frame * channelCount + channel],
                    input[ahead * channelCount + channel],
                    weight
                )
            }
        }
        return output
    }

    /// Rend `frameCount` trames à partir de `frameCount - 1`, en **ajoutant une trame**.
    ///
    /// - Returns: `frameCount * channelCount` échantillons. Le début coïncide avec l'entrée,
    ///   la fin est l'entrée retardée d'une trame.
    public static func insertingOneFrame(
        into input: [Int16],
        channelCount: Int,
        crossfadeFrames: Int = defaultCrossfadeFrames
    ) -> [Int16] {
        precondition(channelCount > 0, "nombre de canaux nul")
        let inputFrames = input.count / channelCount
        guard inputFrames >= 1 else { return input }
        let outputFrames = inputFrames + 1
        let fade = max(1, min(crossfadeFrames, outputFrames))

        var output = [Int16](repeating: 0, count: outputFrames * channelCount)
        for frame in 0..<outputFrames {
            // Poids du flux retardé d'une trame, symétrique du cas précédent.
            let weight = min(1.0, Double(frame) / Double(fade))
            let current = min(frame, inputFrames - 1)
            let delayed = max(0, min(frame - 1, inputFrames - 1))
            for channel in 0..<channelCount {
                output[frame * channelCount + channel] = blend(
                    input[current * channelCount + channel],
                    input[delayed * channelCount + channel],
                    weight
                )
            }
        }
        return output
    }

    /// Interpolation linéaire de deux échantillons, arrondie et bornée.
    ///
    /// Le calcul passe par `Double` : mélanger deux `Int16` en arithmétique entière
    /// tronquerait vers zéro et introduirait un biais continu sur la fenêtre de fondu.
    private static func blend(_ a: Int16, _ b: Int16, _ weight: Double) -> Int16 {
        let value = (Double(a) * (1 - weight) + Double(b) * weight).rounded()
        return Int16(max(Double(Int16.min), min(Double(Int16.max), value)))
    }
}
