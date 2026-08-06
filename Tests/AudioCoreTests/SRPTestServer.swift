import CSRP
import Foundation

@testable import AudioCore

/// Côté serveur de SRP-6a, **à usage de test uniquement**.
///
/// Le projet est un sender : il n'a aucune raison d'implémenter le vérificateur SRP en
/// production, c'est le rôle de l'Apple TV. Ce type existe pour donner un partenaire au
/// ``SRPClient`` dans les tests unitaires, sans dépendre du mock réseau.
///
/// Il s'appuie sur `srp_verifier_*` de la bibliothèque vendue, avec les mêmes paramètres
/// qu'AirPlay 2 (SHA-512, groupe 3072 bits). Comme ``SRPClient``, il libère la structure C
/// dans son `deinit`.
///
/// Portée du test que ce type rend possible : il vérifie le **câblage** du wrapper client
/// (paramètres, longueurs, ordre des appels), pas la conformité au protocole réel — les deux
/// côtés partagent la même bibliothèque. La conformité protocolaire est établie par le
/// handshake contre le mock airplay2-receiver.
final class SRPTestServer {

    enum Failure: Error {
        case verifierCreationFailed
        case clientProofRejected
    }

    private var verifier: OpaquePointer?
    private let saltStorage: Data
    private let verifierKeyStorage: Data
    private let username: String

    /// Clé de session côté serveur, renseignée une fois la preuve du client acceptée.
    private(set) var sessionKey = Data()

    init(username: String, password: String) throws {
        self.username = username

        var saltBytes: UnsafePointer<UInt8>?
        var saltLength: UInt32 = 0
        var verifierBytes: UnsafePointer<UInt8>?
        var verifierLength: UInt32 = 0

        let passwordBytes = Array(password.utf8)
        username.withCString { usernameCString in
            SRPClient.group3072N.withCString { nHex in
                SRPClient.group3072g.withCString { gHex in
                    passwordBytes.withUnsafeBufferPointer { passwordBuffer in
                        srp_create_salted_verification_key(
                            SRP_SHA512,
                            SRP_NG_CUSTOM,
                            usernameCString,
                            passwordBuffer.baseAddress, UInt32(passwordBytes.count),
                            &saltBytes, &saltLength,
                            &verifierBytes, &verifierLength,
                            nHex, gHex
                        )
                    }
                }
            }
        }

        guard let saltBytes, let verifierBytes, saltLength > 0, verifierLength > 0 else {
            throw Failure.verifierCreationFailed
        }
        // csrp alloue ces deux tampons avec malloc et en transfère la propriété :
        // on les copie dans des `Data`, puis on rend la mémoire d'origine.
        saltStorage = Data(bytes: saltBytes, count: Int(saltLength))
        verifierKeyStorage = Data(bytes: verifierBytes, count: Int(verifierLength))
        free(UnsafeMutableRawPointer(mutating: saltBytes))
        free(UnsafeMutableRawPointer(mutating: verifierBytes))
    }

    deinit {
        if let verifier {
            srp_verifier_delete(verifier)
        }
    }

    /// Répond au `A` du client par le couple (sel, `B`).
    func challenge(forClientPublicKey publicA: Data) throws -> (salt: Data, publicB: Data) {
        var publicBBytes: UnsafePointer<UInt8>?
        var publicBLength: Int32 = 0

        let created: OpaquePointer? = username.withCString { usernameCString in
            SRPClient.group3072N.withCString { nHex in
                SRPClient.group3072g.withCString { gHex in
                    saltStorage.withUnsafeBytes { saltBuffer in
                        verifierKeyStorage.withUnsafeBytes { verifierBuffer in
                            publicA.withUnsafeBytes { publicABuffer in
                                srp_verifier_new(
                                    SRP_SHA512,
                                    SRP_NG_CUSTOM,
                                    usernameCString,
                                    saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                                    UInt32(saltStorage.count),
                                    verifierBuffer.bindMemory(to: UInt8.self).baseAddress,
                                    UInt32(verifierKeyStorage.count),
                                    publicABuffer.bindMemory(to: UInt8.self).baseAddress,
                                    UInt32(publicA.count),
                                    &publicBBytes, &publicBLength,
                                    nHex, gHex,
                                    1  // rfc5054_compat, comme le client
                                )
                            }
                        }
                    }
                }
            }
        }

        guard let created, let publicBBytes, publicBLength > 0 else {
            throw Failure.verifierCreationFailed
        }
        verifier = created
        return (saltStorage, Data(bytes: publicBBytes, count: Int(publicBLength)))
    }

    /// Vérifie la preuve `M1` du client et renvoie la preuve `HAMK` du serveur.
    func verify(clientProof: Data) throws -> Data {
        guard let verifier else { throw Failure.verifierCreationFailed }

        var proofBytes: UnsafePointer<UInt8>?
        clientProof.withUnsafeBytes { proofBuffer in
            srp_verifier_verify_session(
                verifier,
                proofBuffer.bindMemory(to: UInt8.self).baseAddress,
                &proofBytes
            )
        }

        // csrp signale une preuve refusée en laissant `bytes_HAMK` à NULL.
        guard let proofBytes, srp_verifier_is_authenticated(verifier) != 0 else {
            throw Failure.clientProofRejected
        }

        var keyLength: Int32 = 0
        if let key = srp_verifier_get_session_key(verifier, &keyLength), keyLength > 0 {
            sessionKey = Data(bytes: key, count: Int(keyLength))
        }

        return Data(bytes: proofBytes, count: srp_verifier_get_session_key_length(verifier).asInt)
    }
}

extension Int32 {
    fileprivate var asInt: Int { Int(self) }
}
