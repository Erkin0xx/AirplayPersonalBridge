import AudioCore
import Foundation

/// Erreur d'usage de la ligne de commande : le message s'affiche tel quel, le code de retour est 2.
struct CLIUsageError: Error, Equatable, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Une option répétable qui règle une autre option répétable : `--volume2` pour `--airplay2`.
enum RepeatedOption {
    /// Répartit les valeurs d'une option sur les cibles qu'elle règle.
    ///
    /// - absente : la valeur par défaut pour toutes ;
    /// - donnée une fois : cette valeur pour toutes ;
    /// - répétée : dans l'ordre, la n-ième valeur pour la n-ième cible. Il en faut alors exactement
    ///   une par cible : deviner à qui revient une valeur manquante serait régler la mauvaise
    ///   enceinte en silence.
    ///
    /// - Parameters:
    ///   - option: nom de l'option, pour le message d'erreur (`--volume2`).
    ///   - target: nom de l'option des cibles (`--airplay2`).
    static func distribute<Value>(
        _ values: [Value], over targetCount: Int, default defaultValue: Value,
        option: String, target: String
    ) throws -> [Value] {
        if values.isEmpty { return Array(repeating: defaultValue, count: targetCount) }
        guard targetCount > 0 else { throw CLIUsageError("\(option) sans \(target)") }
        if values.count == 1 { return Array(repeating: values[0], count: targetCount) }
        guard values.count == targetCount else {
            throw CLIUsageError(
                "\(option) est répété \(values.count) fois pour \(targetCount) \(target) : "
                    + "une seule fois pour toutes les sorties, ou une fois par sortie, dans l'ordre"
            )
        }
        return values
    }
}

/// Les sorties demandées en ligne de commande, avant toute découverte.
///
/// Séparé de `main.swift` pour être vérifiable à l'unité : c'est ici que se décide quel réglage
/// revient à quelle enceinte quand plusieurs `--airplay2` sont donnés.
struct OutputPlan: Equatable {
    struct Output: Equatable {
        /// Identifiant de la sortie dans le moteur et le compte rendu : protocole et nom demandé
        /// (`airplay2/Salon (2)`), ce qui distingue deux HomePod au nom voisin.
        let id: String
        let proto: BridgeEngine.OutputProtocol
        let deviceName: String
        let volumeDB: Float
        let manualDelayMs: Double
        /// Renfort de basses, RAOP seulement.
        let bassBoostDB: Float
        /// Credentials d'appairage système, AirPlay 2 seulement.
        let credentialsPath: String?
    }

    let outputs: [Output]

    var isEmpty: Bool { outputs.isEmpty }

    /// - Parameters:
    ///   - raopTarget: `--airplay`, une seule Geneva au plus.
    ///   - airplay2Targets: les `--airplay2`, dans l'ordre de la ligne de commande.
    ///   - airplay2Volumes, airplay2DelaysMs, airplay2Credentials: les `--volume2`, `--delay2`,
    ///     `--credentials2`, répartis par ``RepeatedOption/distribute(_:over:default:option:target:)``.
    static func make(
        raopTarget: String?,
        raopVolumeDB: Float,
        raopDelayMs: Double,
        raopBassDB: Float?,
        airplay2Targets: [String],
        airplay2Volumes: [Float],
        airplay2DelaysMs: [Double],
        airplay2Credentials: [String],
        defaultVolumeDB: Float = -20
    ) throws -> OutputPlan {
        var outputs: [Output] = []
        if let raopTarget {
            outputs.append(Output(
                id: "raop/\(raopTarget)", proto: .raop, deviceName: raopTarget,
                volumeDB: raopVolumeDB, manualDelayMs: raopDelayMs, bassBoostDB: raopBassDB ?? 0,
                credentialsPath: nil
            ))
        } else if raopBassDB != nil {
            throw CLIUsageError("--bass sans --airplay : le renfort de basses ne vaut que pour la sortie RAOP")
        }

        let volumes = try RepeatedOption.distribute(
            airplay2Volumes, over: airplay2Targets.count, default: defaultVolumeDB,
            option: "--volume2", target: "--airplay2"
        )
        let delays = try RepeatedOption.distribute(
            airplay2DelaysMs, over: airplay2Targets.count, default: 0,
            option: "--delay2", target: "--airplay2"
        )
        let credentials = try RepeatedOption.distribute(
            airplay2Credentials.map(Optional.some), over: airplay2Targets.count, default: nil,
            option: "--credentials2", target: "--airplay2"
        )

        var seen: Set<String> = []
        for (index, name) in airplay2Targets.enumerated() {
            // La correspondance des noms ignore la casse : « salon » et « Salon » viseraient le même
            // HomePod, et deux sessions sur une même enceinte ne se mesurent pas.
            guard seen.insert(name.lowercased()).inserted else {
                throw CLIUsageError("--airplay2 « \(name) » est demandé deux fois")
            }
            outputs.append(Output(
                id: "airplay2/\(name)", proto: .airplay2, deviceName: name,
                volumeDB: volumes[index], manualDelayMs: delays[index], bassBoostDB: 0,
                credentialsPath: credentials[index]
            ))
        }
        return OutputPlan(outputs: outputs)
    }
}
