import Foundation

/// Échec d'une sortie AirPlay 2, sous une forme destinée à l'affichage.
///
/// Le moteur montre `description` telle quelle à l'utilisateur : le message doit dire ce qui se
/// passe et ce qu'on peut y faire, là où `RTSPError` et consorts décrivent le protocole. L'erreur
/// d'origine reste journalisée par le sender.
public enum AirPlay2SenderError: Error, CustomStringConvertible, LocalizedError, Equatable {
    /// Le récepteur exige un appairage : `470` ou `401`, `403` au pair-setup ou au `pair-verify`,
    /// ou annonce sans transitoire.
    case pairingRequired(receiver: String, status: Int?)
    /// Des credentials ont été présentés et refusés.
    case credentialsRejected(receiver: String, detail: String)
    /// Le récepteur diffuse déjà pour quelqu'un d'autre (`453`, ou TLV `busy`).
    case receiverBusy(receiver: String)
    /// Trop de tentatives de pairing : il faut laisser passer du temps.
    case pairingBackoff(receiver: String)
    /// Le récepteur refuse l'accès à une requête de session (`403`), l'appairage ayant abouti.
    ///
    /// Ce n'est pas un appairage à faire : le récepteur nous a authentifiés et a ouvert la session,
    /// c'est cette requête-là qu'il refuse à ce contrôleur. Cas relevé sur les HomePod (firmware
    /// 27.2) quand le volume partait sans l'identité du `SETUP`.
    ///
    /// **Passager**, contrairement à `pairingRequired` : aucun geste de l'utilisateur ne le lève
    /// (ni appairage, ni credentials), et ses causes connues tiennent à la session — une identité de
    /// contrôleur qui ne concorde pas, un autre appareil qui prend la main. Le déclarer définitif
    /// laisserait la sortie en échec jusqu'à ce qu'on la décoche, pour un refus qu'une nouvelle
    /// session peut ne pas rencontrer. D'où une simple attente plus longue avant de réessayer.
    case requestForbidden(receiver: String, step: String, reason: String)
    /// Le récepteur a refusé une requête (`4xx` autre que ci-dessus).
    case requestRejected(receiver: String, step: String, status: Int, reason: String)
    /// Le récepteur a échoué en traitant une requête (`5xx`).
    case receiverFailed(receiver: String, step: String, status: Int)
    /// Connexion activement refusée : l'adresse répond, mais rien n'écoute sur ce port.
    case connectionRefused(receiver: String, address: String)
    /// Connexion impossible à établir : éteint, hors réseau, ou adresse périmée.
    case unreachable(receiver: String, address: String)
    /// Le récepteur a cessé de répondre en cours d'échange.
    case noResponse(receiver: String, step: String)
    /// La connexion s'est rompue en cours d'échange.
    case connectionLost(receiver: String)
    /// Le récepteur refuse explicitement le pairing : mauvaise preuve, nombre maximal d'appairages
    /// atteint, ou pairing indisponible.
    case pairingRefused(receiver: String, detail: String)
    /// Le pair-setup **transitoire** a échoué à l'authentification SRP : TLV d'erreur
    /// « authentification », ou réponse SRP du récepteur qui ne vérifie pas.
    ///
    /// **Passager**, contrairement à `pairingRefused` : en transitoire, le mot de passe est fixe
    /// (`3939`), personne ne saisit de code, et aucun geste de l'utilisateur ne lèverait ce refus.
    /// Relevé sur un HomePod d'une paire stéréo, quand les deux pair-setups de la paire partaient
    /// ensemble ; le pair-setup suivant aboutissait. Le sender en refait déjà quelques-uns avant de
    /// rendre cette erreur, le moteur continue ensuite avec son repli.
    case transientPairingRejected(receiver: String, step: String)
    /// Le pairing a échoué pour une autre raison qu'un refus explicite.
    case pairingFailed(receiver: String, detail: String)
    /// Tout le reste : le message d'origine, déjà en français, faute de mieux à en dire.
    case other(receiver: String, detail: String)

    /// Réessayer sans intervention ne servira à rien : il faut un geste de l'utilisateur.
    ///
    /// Reprend le partage de `isPermanentOutputFailure` du moteur : ne sont permanents que les
    /// refus explicites de capacité ou d'authentification. Un refus d'authentification au
    /// pair-setup transitoire n'en est pas un (`transientPairingRejected`) : aucun code n'y est en
    /// jeu, donc rien que l'utilisateur puisse corriger.
    public var isPermanent: Bool {
        switch self {
        case .pairingRequired, .credentialsRejected, .pairingRefused: return true
        default: return false
        }
    }

    /// Attente minimale avant une nouvelle tentative.
    ///
    /// Un récepteur occupé n'a aucune raison de se libérer dans la seconde : le relancer en
    /// boucle serrée ne ferait que le solliciter pour rien, et chaque tentative refait un pairing
    /// complet. Un accès refusé non plus : s'il se lève, ce ne sera pas dans la seconde.
    public var minimumRetryDelay: Duration {
        switch self {
        case .receiverBusy, .pairingBackoff, .requestForbidden: return .seconds(10)
        default: return .seconds(1)
        }
    }

    public var description: String {
        switch self {
        case let .pairingRequired(receiver, status):
            let cause = status.map { "(réponse \($0))" } ?? "(il ne propose pas le mode sans code)"
            return """
                « \(receiver) » exige un appairage \(cause). Appaire-le une seule fois avec \
                tools/pyatv313/bin/atvremote -n "\(receiver)" --protocol airplay pair (un code \
                s'affiche sur l'appareil), enregistre les credentials obtenus dans un fichier, \
                puis passe ce fichier à --credentials2.
                """
        case let .credentialsRejected(receiver, detail):
            return """
                « \(receiver) » a refusé les credentials fournis (\(detail)) : ils sont périmés, \
                révoqués, ou ceux d'un autre appareil. Refais l'appairage avec \
                tools/pyatv313/bin/atvremote -n "\(receiver)" --protocol airplay pair.
                """
        case let .receiverBusy(receiver):
            return """
                « \(receiver) » est occupé par une autre source AirPlay. Arrête la lecture en \
                cours sur cet appareil, ou attends qu'elle se termine.
                """
        case let .pairingBackoff(receiver):
            return """
                « \(receiver) » refuse temporairement le pairing après trop de tentatives. \
                Patiente quelques minutes avant de réessayer.
                """
        case let .requestForbidden(receiver, step, reason):
            let detail = reason.isEmpty ? "" : " \(reason)"
            return """
                « \(receiver) » a refusé l'accès à la requête \(step) (réponse 403\(detail)). \
                L'appairage avait abouti : il n'y a pas d'appairage à refaire, c'est cette requête \
                que l'appareil refuse à ce contrôleur.
                """
        case let .requestRejected(receiver, step, status, reason):
            let detail = reason.isEmpty ? "" : " \(reason)"
            return """
                « \(receiver) » a refusé la requête \(step) (réponse \(status)\(detail)). Cette \
                version de l'appareil attend peut-être un autre format ; redémarrer l'appareil \
                peut aussi lever un blocage.
                """
        case let .receiverFailed(receiver, step, status):
            return """
                « \(receiver) » a rencontré une erreur interne sur \(step) (réponse \(status)). \
                Réessaie ; si cela persiste, redémarre l'appareil.
                """
        case let .connectionRefused(receiver, address):
            return """
                « \(receiver) » refuse la connexion (\(address)) : l'adresse répond mais AirPlay \
                n'y écoute pas. L'appareil redémarre peut-être, ou AirPlay y est désactivé.
                """
        case let .unreachable(receiver, address):
            return """
                Impossible de joindre « \(receiver) » (\(address)). Vérifie qu'il est allumé et \
                sur le même réseau que ce Mac.
                """
        case let .noResponse(receiver, step):
            return "« \(receiver) » ne répond plus (\(step)). Vérifie qu'il est allumé et sur le réseau."
        case let .connectionLost(receiver):
            return "La connexion à « \(receiver) » s'est rompue."
        case let .pairingRefused(receiver, detail):
            return "« \(receiver) » refuse le pairing : \(detail)."
        case let .transientPairingRejected(receiver, step):
            return """
                « \(receiver) » a refusé l'authentification du pairing sans code (étape \(step)). \
                Ce mode n'emploie aucun code à saisir : le refus est passager, et la connexion est \
                retentée automatiquement.
                """
        case let .pairingFailed(receiver, detail):
            return "Le pairing avec « \(receiver) » a échoué : \(detail)."
        case let .other(receiver, detail):
            return "« \(receiver) » : \(detail)."
        }
    }

    public var errorDescription: String? { description }

    /// Un échec à l'établissement, avant le moindre échange : l'appareil n'est pas joignable, ou
    /// il l'est mais refuse. Le remède n'est pas le même, le message non plus.
    static func connectionFailure(
        _ error: Error, receiver: String, address: String
    ) -> AirPlay2SenderError {
        if case let RTSPError.connectionFailed(reason) = error, reason.contains("refusée") {
            return .connectionRefused(receiver: receiver, address: address)
        }
        return .unreachable(receiver: receiver, address: address)
    }

    /// Traduit une erreur technique en message affichable.
    ///
    /// - Parameter hasCredentials: un refus n'a pas le même sens ni le même remède selon qu'on a
    ///   présenté des credentials ou non.
    init(classifying error: Error, receiver: String, address: String, hasCredentials: Bool) {
        switch error {
        case let already as AirPlay2SenderError:
            self = already

        case let rtsp as RTSPError:
            self = Self.classify(rtsp, receiver, address, hasCredentials)

        case let pairing as AirPlay2PairingSession.Failure:
            self = Self.classify(pairing, receiver, hasCredentials)

        case let srp as SRPClient.Failure:
            self = .pairingFailed(
                receiver: receiver,
                detail: srp == .serverProofRejected
                    ? "l'appareil n'a pas prouvé son identité"
                    : "échange SRP invalide"
            )

        case is ChaChaPoly1305.Failure:
            // Le sous-TLV de `pair-verify` ne se déchiffre pas : le secret partagé diffère.
            self = hasCredentials
                ? .credentialsRejected(receiver: receiver, detail: "réponse indéchiffrable")
                : .pairingFailed(receiver: receiver, detail: "réponse indéchiffrable")

        case is AirPlay2ControlChannel.Failure:
            self = .connectionLost(receiver: receiver)

        default:
            self = .other(receiver: receiver, detail: String(describing: error))
        }
    }

    private static func classify(
        _ error: RTSPError, _ receiver: String, _ address: String, _ hasCredentials: Bool
    ) -> AirPlay2SenderError {
        switch error {
        case let .unexpectedStatus(method, code, reason):
            // Ne remontent ici que les refus de requêtes de session : ceux du pairing arrivent en
            // `AirPlay2PairingSession.Failure.authorizationRequired`.
            switch code {
            case 470, 401:
                return hasCredentials
                    ? .credentialsRejected(receiver: receiver, detail: "réponse \(code)")
                    : .pairingRequired(receiver: receiver, status: code)
            case 403:
                return .requestForbidden(receiver: receiver, step: method, reason: reason)
            case 453:
                return .receiverBusy(receiver: receiver)
            case 500...599:
                return .receiverFailed(receiver: receiver, step: method, status: code)
            default:
                return .requestRejected(
                    receiver: receiver, step: method, status: code, reason: reason)
            }
        case .connectionFailed, .notConnected:
            return .connectionLost(receiver: receiver)
        case let .timedOut(method):
            return .noResponse(receiver: receiver, step: method)
        case .missingHeader, .malformedResponse:
            return .other(receiver: receiver, detail: error.description)
        }
    }

    private static func classify(
        _ error: AirPlay2PairingSession.Failure, _ receiver: String, _ hasCredentials: Bool
    ) -> AirPlay2SenderError {
        switch error {
        case .transientPairingUnsupported:
            return .pairingRequired(receiver: receiver, status: nil)
        case .receiverIdentityMismatch, .receiverSignatureInvalid:
            return .credentialsRejected(receiver: receiver, detail: error.description)
        case let .receiverRejected(tlv, _):
            switch tlv {
            case .busy:
                return .receiverBusy(receiver: receiver)
            case .backoff, .maxTries:
                return .pairingBackoff(receiver: receiver)
            case .authentication where hasCredentials:
                return .credentialsRejected(receiver: receiver, detail: tlv.description)
            // Le pair-setup transitoire ne remonte pas ce TLV sous cette forme : il le traduit en
            // `transientAuthenticationFailed`. Reste un refus d'authentification hors transitoire.
            case .authentication, .maxPeers, .unavailable:
                return .pairingRefused(receiver: receiver, detail: tlv.description)
            case .unknown:
                return .pairingFailed(receiver: receiver, detail: tlv.description)
            }
        case .malformedResponse, .unexpectedState:
            return .pairingFailed(receiver: receiver, detail: error.description)
        case let .authorizationRequired(status, _):
            return hasCredentials
                ? .credentialsRejected(receiver: receiver, detail: "réponse \(status)")
                : .pairingRequired(receiver: receiver, status: status)
        case let .transientAuthenticationFailed(step, _):
            // Sans rapport avec des credentials : le transitoire ne s'emploie que sans eux.
            return .transientPairingRejected(receiver: receiver, step: step)
        }
    }
}
