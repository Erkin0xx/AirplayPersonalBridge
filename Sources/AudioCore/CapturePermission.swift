import AVFoundation
import Foundation
import OSLog

/// Accès aux SPI privées de TCC pour l'autorisation « enregistrement des sons du système ».
///
/// Aucune API publique n'expose l'état de `kTCCServiceAudioCapture`, dont dépend pourtant
/// le Process Tap. Les symboles sont donc résolus dynamiquement, comme le fait le projet de
/// référence `insidegui/AudioCap` (CDC section 10). Conséquence assumée : ce sont des SPI
/// non documentées, susceptibles de disparaître à une mise à jour de macOS. Les deux
/// accesseurs renvoient `nil` si le symbole est absent, et l'appelant retombe alors sur un
/// diagnostic empirique plutôt que de planter.
///
/// À noter pour le jalon 5 : une app distribuée hors App Store peut utiliser ces SPI, mais
/// elles interdisent une soumission au Mac App Store. Sans objet pour un usage personnel.
enum TCCSPI {
    typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    typealias RequestFunc =
        @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    // `nonisolated(unsafe)` : ces poignées sont résolues une seule fois au premier accès et
    // ne sont jamais réassignées ; les fonctions C pointées sont réentrantes.
    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW
    )

    nonisolated(unsafe) static let preflight: PreflightFunc? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightFunc.self)
    }()

    nonisolated(unsafe) static let request: RequestFunc? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: RequestFunc.self)
    }()
}

/// Demande et vérification des autorisations de capture.
///
/// Point non documenté par Apple, découvert au jalon 1 : **sans autorisation, le Process
/// Tap n'échoue pas**. `AudioHardwareCreateProcessTap` réussit, le périphérique agrégé se
/// crée, le callback d'IO est appelé au rythme normal avec des buffers de la bonne taille —
/// mais tous les échantillons valent zéro. Un silence numérique parfait est donc le
/// symptôme d'une autorisation manquante, et non la preuve d'un blocage DRM. Vérifier
/// l'autorisation **avant** de conclure quoi que ce soit sur le DRM (CDC section 6).
public enum CapturePermission {
    private static let log = AudioLog.capture

    public enum Status: String {
        case notDetermined, restricted, denied, authorized, unknown
    }

    /// Les deux bascules de confidentialité distinctes décrites en CDC 4.2.
    public enum Kind {
        /// Modes Process Tap (système global, application ciblée).
        case systemAudio
        /// Mode entrée physique (micro/ligne).
        case microphone
    }

    public static func status(for kind: Kind) -> Status {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            case .denied: return .denied
            case .authorized: return .authorized
            @unknown default: return .unknown
            }
        case .systemAudio:
            // PIÈGE : `AVCaptureDevice.authorizationStatus(for: .audio)` renvoie l'état du
            // **micro** (TCC « kTCCServiceMicrophone »), pas celui de l'enregistrement des
            // sons du système (« kTCCServiceAudioCapture ») dont dépend le Process Tap.
            // Elle peut répondre `authorized` alors que le tap ne livre que du silence.
            guard let preflight = TCCSPI.preflight else { return .unknown }
            switch preflight(Self.audioCaptureService as CFString, nil) {
            case 0: return .authorized
            case 1: return .denied
            default: return .notDetermined
            }
        }
    }

    private static let audioCaptureService = "kTCCServiceAudioCapture"

    /// Demande l'autorisation et attend la réponse de l'utilisateur.
    ///
    /// - Returns: `true` si la capture est autorisée à l'issue de l'appel.
    @discardableResult
    public static func request(for kind: Kind) async -> Bool {
        switch kind {
        case .microphone:
            let current = status(for: kind)
            guard current == .notDetermined else {
                log.info("Autorisation micro déjà déterminée : \(current.rawValue, privacy: .public)")
                return current == .authorized
            }
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .systemAudio:
            let current = status(for: .systemAudio)
            guard current != .authorized else { return true }
            guard let requestAccess = TCCSPI.request else {
                log.error("SPI TCCAccessRequest introuvable")
                return false
            }
            log.info("Demande d'autorisation d'enregistrement des sons du système...")
            return await withCheckedContinuation { continuation in
                requestAccess(audioCaptureService as CFString, nil) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// Message d'aide à afficher quand la capture ne renvoie que du silence.
    public static func guidance(for kind: Kind) -> String {
        switch kind {
        case .systemAudio:
            return """
                Le tap ne renvoie que du silence : l'autorisation d'enregistrement des sons
                du système manque probablement. Elle est DISTINCTE de celle du micro.

                Réglages Système > Confidentialité et sécurité
                  > « Enregistrement de l'écran et des sons du système »
                  > section « Enregistrement des sons du système uniquement »
                  > bouton +, puis ajouter :
                    build/audiocap.app

                Le binaire doit être lancé depuis ce bundle signé (./make-cli-bundle.sh) :
                un exécutable SwiftPM nu n'a pas d'identité de code stable, macOS ne peut
                donc lui attribuer aucune autorisation.
                """
        case .microphone:
            return """
                Autorisation micro manquante.
                Réglages Système > Confidentialité et sécurité > Microphone.
                """
        }
    }
}
