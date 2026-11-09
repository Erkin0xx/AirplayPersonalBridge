import Foundation
import Testing

@testable import AudioCore

/// L'app tutoie (« Vérifie », « Relance »). Un message du moteur s'affiche tel quel dans l'app, à
/// côté des siens : une erreur qui vouvoie s'y lit comme un corps étranger.
@Suite("Textes affichés — tutoiement")
struct DisplayedTextTests {
    /// Les mots français qui finissent en « ez » sans être un verbe conjugué au vouvoiement.
    private static let harmlessWords: Set<String> = ["assez", "chez", "nez", "rez"]

    private func formalWords(in text: String) throws -> [String] {
        let formalAddress = try Regex("\\b(\\p{L}+ez|vous|votre|vos)\\b").ignoresCase()
        return text.matches(of: formalAddress)
            .map { String(text[$0.range]) }
            .filter { !Self.harmlessWords.contains($0.lowercased()) }
    }

    @Test("Le détecteur reconnaît le vouvoiement et épargne le reste")
    func detector() throws {
        #expect(try formalWords(in: "Vérifiez qu'il est allumé") == ["Vérifiez"])
        #expect(
            try formalWords(in: "Appairez-le une fois, puis redémarrez") == ["Appairez", "redémarrez"]
        )
        #expect(try formalWords(in: "Si vous voulez") == ["vous", "voulez"])
        #expect(try formalWords(in: "Vérifie qu'il est allumé, assez près, chez toi").isEmpty)
    }

    @Test("Aucune erreur AirPlay 2 ne vouvoie, quel que soit le cas")
    func airPlay2Errors() throws {
        let receiver = "Salon"
        let errors: [AirPlay2SenderError] = [
            .pairingRequired(receiver: receiver, status: 470),
            .pairingRequired(receiver: receiver, status: nil),
            .credentialsRejected(receiver: receiver, detail: "réponse 470"),
            .receiverBusy(receiver: receiver),
            .pairingBackoff(receiver: receiver),
            .requestRejected(receiver: receiver, step: "SETUP", status: 400, reason: "Bad"),
            .receiverFailed(receiver: receiver, step: "SETUP", status: 500),
            .connectionRefused(receiver: receiver, address: "192.0.2.1:7000"),
            .unreachable(receiver: receiver, address: "192.0.2.1:7000"),
            .noResponse(receiver: receiver, step: "RECORD"),
            .connectionLost(receiver: receiver),
            .pairingRefused(receiver: receiver, detail: "indisponible"),
            .pairingFailed(receiver: receiver, detail: "réponse indéchiffrable"),
            .other(receiver: receiver, detail: "inconnu"),
        ]
        for error in errors {
            #expect(try formalWords(in: error.description).isEmpty, "\(error.description)")
        }
    }

    /// Le moteur affiche la `description` sous le nom de l'enceinte : un récepteur éteint y montrait
    /// le diagnostic du parcours (capture du 2026-11-09). Le détail reste, dans `diagnostic`.
    @Test("Un récepteur introuvable se dit en une phrase, le détail allant au journal")
    func receiverNotFound() throws {
        let raopSeen = ["001122334455@Apple TV Salon", "111111111111@Salon"]
        let raop = RAOPDiscoveryError.notFound(name: "F8F25A011261@Erki’s geneva", seen: raopSeen)
        let airplay2 = AirPlay2DiscoveryError.notFound(name: "Salon", seen: ["Geneva", "Salon (2)"])
        let expected = "Introuvable sur le réseau — éteinte ?"

        #expect(raop.description == expected)
        #expect(airplay2.description == expected)
        for text in [raop.description, airplay2.description] {
            for detail in ["_tcp", "F8F25A011261", "services vus", "Salon"] {
                #expect(!text.contains(detail), "« \(detail) » dans « \(text) »")
            }
            #expect(try formalWords(in: text).isEmpty, "\(text)")
        }

        #expect(raop.diagnostic.contains("_raop._tcp"))
        #expect(raop.diagnostic.contains("F8F25A011261@Erki’s geneva"))
        #expect(raop.diagnostic.contains("001122334455@Apple TV Salon, 111111111111@Salon"))
        #expect(airplay2.diagnostic.contains("_airplay._tcp"))
        #expect(airplay2.diagnostic.contains("Geneva, Salon (2)"))
        #expect(AirPlay2DiscoveryError.notFound(name: "Salon", seen: []).diagnostic.contains("services vus : aucun"))
    }

    @Test("Aucune réponse RTSP traduite ne vouvoie, quel que soit le statut")
    func rtspErrors() throws {
        for status in [400, 401, 403, 404, 453, 470, 500, 503, 600] {
            let error = RTSPError.unexpectedStatus(method: "SETUP", code: status, reason: "Refus")
            #expect(try formalWords(in: error.description).isEmpty, "\(error.description)")
        }
    }

    /// Filet pour tout ce qu'on ne sait pas énumérer : aperçus de l'app, sorties du CLI, futurs
    /// messages. Les noms de code français de ce dépôt ne finissent pas en « ez » : une ligne de
    /// code est donc traitée comme du texte, seuls les commentaires étant écartés.
    @Test("Aucun texte du code source ne vouvoie")
    func sourceTree() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folders = ["Sources/AudioCore", "Sources/audiocap", "AirplayPersonalBridge/AirplayPersonalBridge"]
        var scanned = 0
        var offenders: [String] = []

        for folder in folders {
            let base = root.appendingPathComponent(folder)
            let files = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                scanned += 1
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//") else { continue }
                    // « // » précédé d'une espace : un commentaire de fin de ligne, pas une URL.
                    let code = line.components(separatedBy: " // ").first ?? line
                    // Le motif se compile à chaque appel, et le parcours porte sur 30 000 lignes :
                    // ce tri préalable lui évite de prendre un cœur plusieurs secondes.
                    let lowered = code.lowercased()
                    guard lowered.contains("ez") || lowered.contains("vo") else { continue }
                    let words = try formalWords(in: code)
                    if !words.isEmpty {
                        offenders.append("\(file.lastPathComponent):\(index + 1) \(words)")
                    }
                }
            }
        }
        #expect(scanned > 50, "le parcours n'a pas trouvé les sources")
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
