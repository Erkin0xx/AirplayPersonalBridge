//
//  SystemVolumeLink.swift
//  AirplayPersonalBridge
//

import AudioCore
import CoreAudio
import Foundation
import OSLog

private let volumeLinkLog = Logger(subsystem: AudioLog.subsystem, category: "volume")

/// Relie le volume général des enceintes au volume du Mac, dans les deux sens, comme quand macOS
/// diffuse lui-même en AirPlay : les touches de volume, la touche silence et le curseur du Centre de
/// contrôle règlent les enceintes, et le master de l'app règle le volume du Mac.
///
/// **Correspondance.** Le scalaire du Mac `s` (0…1) donne `master = −60 + 60·s` dB, donc
/// `−30 + 30·s` sur le fil (`BridgeState.receiverVolume`) : l'échelle même de l'AirPlay natif.
/// `s = 0` vaut le silence (−144 sur le fil). Les 16 crans des touches font des pas de 3,75 dB sur le
/// master, 1,875 dB sur le fil ; Option-Maj en donne quatre fois plus fins.
///
/// **Sans boucle.** Ce que l'app écrit, Core Audio le renvoie à l'écouteur. Trois garde-fous :
/// - une marque d'origine (`isApplying`) : ce que le Mac impose au master ne repart pas vers le Mac ;
/// - une tolérance (`tolerance`) : un relevé qui ne diffère pas de la dernière valeur connue n'est
///   pas un geste, et une sortie qui arrondit le scalaire ne relance rien ;
/// - une fenêtre d'écho après chaque écriture : un relevé périmé, arrivé entre l'écriture et son
///   effet, n'est pas pris pour une touche. Le relevé qui la clôt rattrape une vraie touche pressée
///   entre-temps.
///
/// **Débit borné.** Au plus un réglage du Mac par tour de la boucle de 250 ms (`writeInterval`) :
/// un glissement du curseur n'écrit pas une propriété Core Audio par pixel.
///
/// **Chaque sortie du Mac garde son volume**, comme dans macOS : un casque branché, le master adopte
/// le volume du casque. Une sortie sans volume réglable (numérique, HDMI) rend la liaison
/// inopérante, sans rien changer au master.
///
/// La capture n'en sait rien, ni les senders : seul le master de `BridgeState` bouge, et la boucle de
/// 250 ms le pousse comme n'importe quel geste.
@Observable
final class SystemVolumeLink {
    /// Ce que le Mac impose au master, ou au silence des enceintes.
    struct Update: Equatable {
        var masterDB: Double?
        var isMuted: Bool?
    }

    // MARK: - Correspondance

    /// La course du master, partagée avec les curseurs.
    private static let masterRange = BridgeSettings.Limits.masterDB

    static func masterDB(forScalar scalar: Double) -> Double {
        let clamped = min(max(scalar, 0), 1)
        return masterRange.lowerBound + (masterRange.upperBound - masterRange.lowerBound) * clamped
    }

    static func scalar(forMasterDB decibels: Double) -> Double {
        let span = masterRange.upperBound - masterRange.lowerBound
        let clamped = min(max(decibels, masterRange.lowerBound), masterRange.upperBound)
        return (clamped - masterRange.lowerBound) / span
    }

    /// La moitié du cran le plus fin des touches (Option-Maj, 1/64) : en deçà, deux scalaires sont la
    /// même position. Assez large pour l'arrondi d'une sortie, assez étroit pour ne manquer aucun cran.
    static let tolerance = 1.0 / 128

    private static func matches(_ value: Double, _ known: Double?) -> Bool {
        guard let known else { return false }
        return abs(value - known) < tolerance
    }

    // MARK: - État

    /// L'option « Touches de volume du Mac → enceintes ». Désactivée, plus rien n'est lié.
    var isEnabled = true {
        didSet { if oldValue != isEnabled { refreshActivity() } }
    }

    /// La sortie du Mac, quand elle n'a pas de volume réglable : la liaison y est inopérante, et le
    /// panneau le dit.
    private(set) var inoperativeDeviceName: String?

    /// Applique ce que le Mac impose. Branché par `BridgeState`.
    @ObservationIgnored var onUpdate: (Update) -> Void = { _ in }

    @ObservationIgnored private let control: any SystemVolumeControlling
    @ObservationIgnored private let writeInterval: Duration
    /// Le temps laissé à une écriture pour revenir par l'écouteur.
    @ObservationIgnored private let echoGrace: Duration

    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isObserving = false
    /// La sortie dont on a adopté le volume.
    @ObservationIgnored private var device: AudioObjectID?
    /// Dernières valeurs connues du Mac, relevées ou écrites. `nil` : pas de réglage de ce côté.
    @ObservationIgnored private var knownScalar: Double?
    @ObservationIgnored private var knownMute: Bool?
    /// Ce que l'app veut écrire au prochain tour.
    @ObservationIgnored private var pendingScalar: Double?
    @ObservationIgnored private var pendingMute: Bool?
    @ObservationIgnored private var lastWrite: ContinuousClock.Instant?
    @ObservationIgnored private var echoDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    /// Vrai le temps d'appliquer un relevé : ce que le Mac impose ne lui est pas renvoyé.
    @ObservationIgnored private var isApplying = false

    init(control: any SystemVolumeControlling, writeInterval: Duration) {
        self.control = control
        self.writeInterval = writeInterval
        self.echoGrace = writeInterval * 2
    }

    /// Lance le suivi, si l'option le veut. Le premier relevé est adopté : au lancement, le master
    /// prend le volume du Mac. Idempotent.
    func start() {
        isStarted = true
        refreshActivity()
    }

    private func refreshActivity() {
        let shouldObserve = isStarted && isEnabled
        guard shouldObserve != isObserving else { return }
        isObserving = shouldObserve
        if shouldObserve {
            control.startObserving { [weak self] in self?.systemDidChange() }
            systemDidChange()
        } else {
            control.stopObserving()
            reset()
            volumeLinkLog.notice("Volume du Mac délié des enceintes")
        }
    }

    // MARK: - Du Mac vers les enceintes

    private func systemDidChange() {
        guard isObserving else { return }
        guard let reading = control.read() else {
            if device != nil {
                volumeLinkLog.notice("Plus aucune sortie sur le Mac : volume non suivi")
                reset()
            }
            return
        }
        guard reading.deviceID == device else {
            adopt(reading)
            return
        }
        // Une sortie sans volume réglable : rien de lié, silence compris.
        guard knownScalar != nil else { return }
        // Entre une écriture et son retour, un relevé peut être périmé. Celui qui clôt la fenêtre
        // (`scheduleReconcile`) tranche.
        if let echoDeadline, ContinuousClock.now < echoDeadline { return }

        var update = Update()
        if pendingScalar == nil, let volume = reading.volume.map(Double.init),
            !Self.matches(volume, knownScalar)
        {
            knownScalar = volume
            update.masterDB = Self.masterDB(forScalar: volume)
        }
        if pendingMute == nil, let muted = reading.isMuted, muted != knownMute {
            knownMute = muted
            update.isMuted = muted
        }
        deliver(update)
    }

    /// Une sortie qu'on ne suivait pas : le premier relevé, ou un changement de sortie du Mac. Elle
    /// garde son volume et son silence, et le master les adopte.
    private func adopt(_ reading: SystemOutputVolume.Reading) {
        let isFirst = device == nil
        cancelWrites()
        device = reading.deviceID
        knownScalar = reading.volume.map(Double.init)
        knownMute = reading.isMuted
        let name = reading.deviceName.isEmpty ? "sans nom" : reading.deviceName

        guard let scalar = knownScalar else {
            // Inopérante en entier : sans volume, son silence ne se relie pas non plus.
            knownMute = nil
            if inoperativeDeviceName != name { inoperativeDeviceName = name }
            volumeLinkLog.notice(
                """
                Sortie du Mac « \(name, privacy: .public) » sans volume réglable : les touches de \
                volume n'agissent pas sur les enceintes
                """
            )
            return
        }
        if inoperativeDeviceName != nil { inoperativeDeviceName = nil }
        let master = Self.masterDB(forScalar: scalar)
        let context = isFirst ? "Volume du Mac relevé" : "Sortie du Mac changée"
        let muteText = knownMute.map { $0 ? "oui" : "non" } ?? "sans objet"
        let percent = Int((scalar * 100).rounded())
        volumeLinkLog.notice(
            """
            \(context, privacy: .public) : « \(name, privacy: .public) » à \
            \(percent, privacy: .public) %, silence \(muteText, privacy: .public) ; master adopté \
            à \(master, format: .fixed(precision: 2), privacy: .public) dB
            """
        )
        deliver(Update(masterDB: master, isMuted: knownMute))
    }

    private func deliver(_ update: Update) {
        guard update.masterDB != nil || update.isMuted != nil else { return }
        isApplying = true
        defer { isApplying = false }
        onUpdate(update)
    }

    // MARK: - De l'app vers le Mac

    /// Le master a bougé dans l'app : le Mac suit, au prochain tour.
    ///
    /// Comparé à la valeur connue sans la tolérance, qui ne vaut que pour ce qui revient du Mac : un
    /// glissement qui finit à moins d'un demi-cran de la dernière écriture doit quand même arriver, sans
    /// quoi le Mac resterait à 99 % quand le master est au maximum. Le débit, lui, reste borné.
    func appDidChange(masterDB: Double) {
        guard isObserving, !isApplying, device != nil, let known = knownScalar else { return }
        let scalar = Self.scalar(forMasterDB: masterDB)
        pendingScalar = abs(scalar - known) < 1e-9 ? nil : scalar
        if pendingScalar != nil { scheduleFlush() }
    }

    /// Le silence des enceintes a basculé dans l'app : le Mac suit, au prochain tour.
    func appDidChange(isMuted: Bool) {
        guard isObserving, !isApplying, device != nil, let known = knownMute else { return }
        pendingMute = isMuted == known ? nil : isMuted
        if pendingMute != nil { scheduleFlush() }
    }

    /// Au tour suivant, pour qu'un même geste (rétablir le son en saisissant le curseur) ne fasse
    /// qu'une écriture ; et pas avant `writeInterval` après la précédente.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let earliest = lastWrite.map { $0 + writeInterval }
        flushTask = Task { [weak self] in
            if let earliest {
                do { try await Task.sleep(until: earliest, clock: .continuous) } catch { return }
            }
            self?.flush()
        }
    }

    private func flush() {
        flushTask = nil
        guard isObserving, let device else { return }
        let scalar = pendingScalar
        let muted = pendingMute
        pendingScalar = nil
        pendingMute = nil
        guard scalar != nil || muted != nil else { return }

        let now = ContinuousClock.now
        lastWrite = now
        let deadline = now + echoGrace
        echoDeadline = deadline
        // Couper avant de changer le volume, rétablir après : jamais un éclat au niveau d'avant.
        if muted == true, control.setMuted(true, on: device) { knownMute = true }
        if let scalar, control.setVolume(Float(scalar), on: device) { knownScalar = scalar }
        if muted == false, control.setMuted(false, on: device) { knownMute = false }
        scheduleReconcile(at: deadline)
    }

    /// Relit le Mac au terme de la fenêtre d'écho : une sortie qui arrondit le scalaire, ou une touche
    /// pressée pendant la fenêtre, s'y retrouvent.
    private func scheduleReconcile(at deadline: ContinuousClock.Instant) {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard let self else { return }
            self.reconcileTask = nil
            if self.echoDeadline == deadline { self.echoDeadline = nil }
            self.systemDidChange()
        }
    }

    private func cancelWrites() {
        flushTask?.cancel()
        flushTask = nil
        reconcileTask?.cancel()
        reconcileTask = nil
        pendingScalar = nil
        pendingMute = nil
        lastWrite = nil
        echoDeadline = nil
    }

    private func reset() {
        cancelWrites()
        device = nil
        knownScalar = nil
        knownMute = nil
        if inoperativeDeviceName != nil { inoperativeDeviceName = nil }
    }
}
