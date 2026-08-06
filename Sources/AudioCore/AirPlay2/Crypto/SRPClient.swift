import CSRP
import Foundation

/// Client SRP-6a, adossé à `cocagne/csrp`.
///
/// Wrapper de la bibliothèque C vendue dans `Sources/CCrypto/CSRP` (CDC 4.4). Seul endroit
/// du projet qui manipule `SRPUser` (invariant section 12) : la structure est allouée par
/// `srp_user_new` et rendue par `srp_user_delete` dans `deinit`.
///
/// AirPlay 2 utilise SRP-6a **en SHA-512 sur le groupe 3072 bits**, avec le nom
/// d'utilisateur fixe `Pair-Setup`. Le README de csrp met en avant SHA-1 et le groupe
/// 2048 bits, mais la bibliothèque couvre les deux besoins : `SRP_SHA512` existe dans
/// `SRP_HashAlgorithm`, et `SRP_NG_CUSTOM` accepte `N` et `g` en hexadécimal.
///
/// ## Le détail qui décide de tout : le bourrage de `u` et `k`
///
/// SRP-6a se décline en deux conventions incompatibles pour calculer `u = H(A, B)` et
/// `k = H(N, g)` :
///
/// - **`master` de csrp** concatène les nombres *tels quels*, sans bourrage.
/// - **RFC 5054**, que suit AirPlay 2 (comme HomeKit), bourre chaque opérande de zéros à
///   gauche jusqu'à la largeur du module — 384 octets ici.
///
/// Les deux produisent une preuve de la bonne taille et un échange qui « se déroule » : la
/// différence n'apparaît qu'au moment où le récepteur vérifie la preuve, sous la forme d'un
/// laconique `invalid proof`. C'est précisément le genre d'écart que le CDC 4.4 cherche à
/// éviter en interdisant de réécrire ces primitives à la main.
///
/// D'où la branche **`rfc5054_compat`** de csrp, vendue ici plutôt que `master` : elle
/// expose les deux conventions et laisse l'appelant choisir. Le drapeau est armé dans
/// ``init(username:password:)`` — sans lui, le pairing échoue contre tout récepteur AirPlay.
///
/// Rôle : c'est l'étape M1→M4 du `pair-setup`, celle qui transforme le code à 4 chiffres
/// affiché par l'Apple TV en une clé de session partagée, sans jamais transmettre le code.
public final class SRPClient {
    /// Nom d'utilisateur imposé par le protocole de pairing HomeKit/AirPlay 2.
    public static let pairSetupUsername = "Pair-Setup"

    /// Groupe 3072 bits de SRP-6a (RFC 5054 annexe A), celui qu'emploie AirPlay 2.
    /// Recopié en hexadécimal : c'est la forme qu'attend `SRP_NG_CUSTOM`.
    public static let group3072N = """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74\
        020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437\
        4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED\
        EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05\
        98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB\
        9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B\
        E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718\
        3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33\
        A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7\
        ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864\
        D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2\
        08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
        """
    /// Générateur du groupe 3072 bits.
    public static let group3072g = "05"

    public enum Failure: Error, Equatable {
        /// `srp_user_new` a renvoyé NULL.
        case allocationFailed
        /// `srp_user_start_authentication` n'a pas produit de A.
        case startFailed
        /// Le serveur a renvoyé un B invalide (multiple de N), ou le calcul a échoué.
        /// csrp signale ce cas en ne produisant pas de M.
        case invalidServerPublicKey
        /// La preuve HAMK du serveur ne correspond pas : le récepteur n'a pas prouvé
        /// connaître le mot de passe. Session à abandonner.
        case serverProofRejected
        /// Clé de session demandée avant la fin de l'échange.
        case sessionNotEstablished
    }

    /// Alloué par `srp_user_new`, rendu par `srp_user_delete` dans `deinit`.
    private let user: OpaquePointer

    /// Le mot de passe doit rester vivant aussi longtemps que `user` : csrp conserve un
    /// pointeur vers ces octets sans les copier.
    private let passwordStorage: UnsafeMutableBufferPointer<UInt8>

    /// Vrai une fois ``verifyServerProof(_:)`` accepté.
    private var authenticated = false

    /// - Parameters:
    ///   - username: `Pair-Setup` pour AirPlay 2.
    ///   - password: le code affiché par le récepteur (4 chiffres, ou 3939 sur le mock).
    public init(username: String = SRPClient.pairSetupUsername, password: String) throws {
        let passwordBytes = Array(password.utf8)
        passwordStorage = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(passwordBytes.count, 1))
        _ = passwordStorage.initialize(from: passwordBytes)

        guard let base = passwordStorage.baseAddress else {
            passwordStorage.deallocate()
            throw Failure.allocationFailed
        }

        let created: OpaquePointer? = username.withCString { usernameCString in
            Self.group3072N.withCString { nHex in
                Self.group3072g.withCString { gHex in
                    srp_user_new(
                        SRP_SHA512,
                        SRP_NG_CUSTOM,
                        usernameCString,
                        base, UInt32(passwordBytes.count),
                        nHex, gHex,
                        1  // rfc5054_compat : bourrage de u et k, exigé par AirPlay 2
                    )
                }
            }
        }
        guard let created else {
            passwordStorage.deallocate()
            throw Failure.allocationFailed
        }
        user = created
    }

    deinit {
        srp_user_delete(user)
        // Le mot de passe n'est plus référencé par csrp : l'effacer avant de le rendre.
        if let base = passwordStorage.baseAddress {
            base.update(repeating: 0, count: passwordStorage.count)
        }
        passwordStorage.deallocate()
    }

    /// Étape M1 : produit la clé publique `A` à envoyer au récepteur.
    public func startAuthentication() throws -> Data {
        var usernamePointer: UnsafePointer<CChar>?
        var publicA: UnsafePointer<UInt8>?
        var lengthA: Int32 = 0

        srp_user_start_authentication(user, &usernamePointer, &publicA, &lengthA)

        guard let publicA, lengthA > 0 else {
            throw Failure.startFailed
        }
        // csrp garde la propriété du tampon : on en prend une copie immédiate.
        return Data(bytes: publicA, count: Int(lengthA))
    }

    /// Étape M3 : traite `salt` et `B` reçus du récepteur, et produit la preuve `M1`.
    public func processChallenge(salt: Data, serverPublicKey: Data) throws -> Data {
        var proof: UnsafePointer<UInt8>?
        var proofLength: Int32 = 0

        salt.withUnsafeBytes { saltBytes in
            serverPublicKey.withUnsafeBytes { serverBytes in
                srp_user_process_challenge(
                    user,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, UInt32(salt.count),
                    serverBytes.bindMemory(to: UInt8.self).baseAddress, UInt32(serverPublicKey.count),
                    &proof, &proofLength
                )
            }
        }

        // csrp signale un B invalide en laissant `proof` à NULL, sans code d'erreur séparé.
        guard let proof, proofLength > 0 else {
            throw Failure.invalidServerPublicKey
        }
        return Data(bytes: proof, count: Int(proofLength))
    }

    /// Étape M4 : vérifie la preuve `HAMK` du récepteur.
    ///
    /// C'est cette étape qui authentifie le **récepteur** auprès de nous. La sauter
    /// reviendrait à accepter n'importe quel interlocuteur se disant Apple TV.
    public func verifyServerProof(_ serverProof: Data) throws {
        serverProof.withUnsafeBytes { proofBytes in
            srp_user_verify_session(user, proofBytes.bindMemory(to: UInt8.self).baseAddress)
        }
        guard srp_user_is_authenticated(user) != 0 else {
            throw Failure.serverProofRejected
        }
        authenticated = true
    }

    /// Clé de session partagée `K`, disponible seulement après ``verifyServerProof(_:)``.
    ///
    /// C'est la racine dont le HKDF tire les clés de chiffrement du pairing
    /// (`Pair-Setup-Encrypt-Salt` / `-Info`).
    public func sessionKey() throws -> Data {
        guard authenticated else {
            throw Failure.sessionNotEstablished
        }
        var length: Int32 = 0
        guard let key = srp_user_get_session_key(user, &length), length > 0 else {
            throw Failure.sessionNotEstablished
        }
        return Data(bytes: key, count: Int(length))
    }
}
