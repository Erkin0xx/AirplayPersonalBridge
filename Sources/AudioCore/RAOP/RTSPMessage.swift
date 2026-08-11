import Foundation

/// Requête RTSP sortante.
///
/// RTSP reprend la syntaxe d'HTTP/1.1 mais s'en distingue sur trois points qui comptent
/// pour l'interopérabilité RAOP : le `CSeq` est obligatoire sur chaque requête, la réponse
/// le renvoie tel quel, et l'URI porte l'identifiant de session RAOP.
public struct RTSPRequest: Sendable {
    public var method: String
    public var uri: String
    public var headers: [(name: String, value: String)]
    public var body: Data

    /// Version de protocole portée par la ligne de requête.
    ///
    /// Le pairing AirPlay 2 sort du cadre RTSP : pyatv y poste en **`HTTP/1.1`, sans `CSeq`**,
    /// de sorte que le `SETUP` qui suit est la première requête RTSP de la connexion et porte
    /// `CSeq: 1`. Un `CSeq` déjà avancé par le pairing est le dernier écart relevé avec lui.
    public var protocolVersion: String

    /// Vrai pour une requête RTSP, qui doit porter un `CSeq`.
    public var usesRTSP: Bool { protocolVersion.hasPrefix("RTSP") }

    public init(
        method: String,
        uri: String,
        headers: [(name: String, value: String)] = [],
        body: Data = Data(),
        protocolVersion: String = "RTSP/1.0"
    ) {
        self.method = method
        self.uri = uri
        self.headers = headers
        self.body = body
        self.protocolVersion = protocolVersion
    }

    /// Sérialise la requête. `Content-Length` est ajouté automatiquement si le corps n'est
    /// pas vide et que l'appelant ne l'a pas déjà posé.
    public func serialized() -> Data {
        var text = "\(method) \(uri) \(protocolVersion)\r\n"
        for header in headers {
            text += "\(header.name): \(header.value)\r\n"
        }
        let hasContentLength = headers.contains {
            $0.name.lowercased() == "content-length"
        }
        if !body.isEmpty && !hasContentLength {
            text += "Content-Length: \(body.count)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }
}

/// Réponse RTSP entrante.
public struct RTSPResponse: Sendable {
    public let statusCode: Int
    public let reasonPhrase: String
    /// Noms normalisés en minuscules : RTSP les déclare insensibles à la casse et les
    /// récepteurs ne les orthographient pas tous pareil.
    public let headers: [String: String]
    public let body: Data

    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// Analyse une réponse complète. Renvoie `nil` si le tampon est encore incomplet, ce qui
    /// est un cas normal en lecture par morceaux, pas une erreur.
    public static func parse(_ data: Data) -> (response: RTSPResponse, consumed: Int)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[data.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard statusLine.count >= 2, let code = Int(statusLine[1]) else { return nil }
        let reason = statusLine.count > 2 ? statusLine[2] : ""

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<separator]).lowercased()
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyLength = headers["content-length"].flatMap(Int.init) ?? 0
        let bodyStart = headerEnd.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= bodyLength else { return nil }  // corps encore incomplet
        let bodyEnd = data.index(bodyStart, offsetBy: bodyLength)
        let body = Data(data[bodyStart..<bodyEnd])

        let response = RTSPResponse(
            statusCode: code, reasonPhrase: reason, headers: headers, body: body
        )
        return (response, data.distance(from: data.startIndex, to: bodyEnd))
    }

    /// Analyse l'en-tête `Transport` en paires clé/valeur.
    ///
    /// Le récepteur y renvoie les ports qu'il a réellement ouverts — jamais ceux demandés,
    /// qui ne sont qu'une suggestion. Les utiliser tels quels est indispensable.
    public var transportParameters: [String: String] {
        guard let transport = headers["transport"] else { return [:] }
        var parameters: [String: String] = [:]
        for component in transport.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 {
                parameters[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                    pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return parameters
    }
}
