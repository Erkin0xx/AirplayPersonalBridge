//
//  SystemVolumeLink.swift
//  AirplayPersonalBridge
//

import AudioCore
import CoreAudio
import Foundation
import OSLog

private let volumeLinkLog = Logger(subsystem: AudioLog.subsystem, category: "volume")

/// Le volume et le silence du Mac d'avant une diffusion, à lui rendre à la fin.
///
/// Persisté dans `settings.json` **avant** qu'on touche au Mac : après un plantage ou un `kill -9`, le
/// lancement suivant le rend (`SystemVolumeLink.restoreLeftoverMemory`). La sortie est désignée par son
/// identifiant stable, l'identifiant Core Audio ne survivant pas forcément à un redémarrage.
struct SystemVolumeMemory: Codable, Equatable {
    var deviceUID: String
    var deviceName: String
    /// `nil` : la sortie n'a pas de volume réglable, il n'y a rien à rendre de ce côté.
    var volume: Float?
    var isMuted: Bool?
}

/// Relie le volume général des enceintes au volume du Mac **pendant une diffusion**, comme l'AirPlay
/// natif de macOS : les touches de volume, la touche silence et le curseur du Centre de contrôle
/// règlent alors les enceintes, et le master de l'app règle le Mac. Hors diffusion, rien n'est lié :
/// l'app ne lit ni n'écrit le volume du Mac, et le master reste le sien.
///
/// **Une diffusion.** Au démarrage, le volume et le silence du Mac sont mémorisés et persistés, puis le
/// Mac est réglé sur le master (`s = (master + 60) / 60`) et sur le silence des enceintes. Le son local
/// est coupé par le tap pendant tout ce temps (`BridgeState` force `muteLocalOutput` au démarrage) : le
/// Mac se tait, et son volume ne sert plus qu'à piloter les enceintes. À l'arrêt, ou si l'option est
/// désactivée en cours de route, le Mac retrouve le volume et le silence mémorisés. Pour Baptiste, dont
/// le Mac reste à 0 % et coupé, c'est ce qui évite des enceintes muettes au démarrage, et un Mac qui se
/// mettrait à jouer.
///
/// **Correspondance.** `master = −60 + 60·s` dB, donc `−30 + 30·s` sur le fil
/// (`BridgeState.receiverVolume`) : l'échelle même de l'AirPlay natif. `s = 0` vaut le silence (−144 sur
/// le fil). Les 16 crans des touches font des pas de 3,75 dB sur le master, 1,875 dB sur le fil ;
/// Option-Maj en donne quatre fois plus fins.
///
/// **Sans boucle.** Ce que l'app écrit, Core Audio le renvoie à l'écouteur. Trois garde-fous :
/// - une marque d'origine (`isApplying`) : ce que le Mac impose au master ne repart pas vers le Mac ;
/// - une tolérance (`tolerance`), pour ce qui revient du Mac : un relevé qui ne diffère pas de la
///   dernière valeur connue n'est pas un geste, et une sortie qui arrondit le scalaire ne relance rien ;
/// - une fenêtre d'écho après chaque écriture : un relevé périmé, arrivé entre l'écriture et son effet,
///   n'est pas pris pour une touche. Le relevé qui la clôt rattrape une vraie touche pressée entre-temps.
///
/// **Débit borné.** Au plus un réglage du Mac par tour de la boucle de 250 ms (`writeInterval`).
///
/// **Changement de sortie du Mac pendant une diffusion** (un casque branché) : l'ancienne sortie
/// retrouve son volume mémorisé si elle est encore là, la nouvelle est mémorisée à son tour, puis
/// réglée sur le master. **Le master ne saute pas** : c'est la sortie du Mac qui s'aligne sur lui, et
/// non l'inverse, puisque le Mac se tait de toute façon. Une sortie sans volume réglable (numérique,
/// HDMI) rend la liaison inopérante, sans rien changer au master.
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

    /// L'option « Touches de volume du Mac → enceintes ». La désactiver en pleine diffusion rend au
    /// Mac son volume.
    var isEnabled = true {
        didSet { if oldValue != isEnabled, !isEnabled { endSession() } }
    }

    /// Vrai pendant une diffusion où le Mac est relié aux enceintes.
    private(set) var isActive = false

    /// La sortie du Mac, quand elle n'a pas de volume réglable : la liaison y est inopérante, et le
    /// panneau le dit.
    private(set) var inoperativeDeviceName: String?

    /// Ce qu'il faudra rendre au Mac. À persister dès qu'il change (`onMemoryChange`).
    @ObservationIgnored private(set) var memory: SystemVolumeMemory?

    /// Applique ce que le Mac impose. Branché par `BridgeState`.
    @ObservationIgnored var onUpdate: (Update) -> Void = { _ in }
    /// La mémoire a changé : à écrire tout de suite, pas au prochain enregistrement différé.
    @ObservationIgnored var onMemoryChange: () -> Void = {}

    @ObservationIgnored private let control: any SystemVolumeControlling
    @ObservationIgnored private let writeInterval: Duration
    /// Le temps laissé à une écriture pour revenir par l'écouteur.
    @ObservationIgnored private let echoGrace: Duration

    /// Le master et le silence de l'app, tels qu'ils sont : une nouvelle sortie du Mac s'aligne dessus.
    @ObservationIgnored private var appMasterDB = BridgeState.defaultMasterVolumeDB
    @ObservationIgnored private var appIsMuted = false
    /// La sortie du Mac suivie pendant la diffusion.
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

    init(
        control: any SystemVolumeControlling, writeInterval: Duration,
        memory: SystemVolumeMemory? = nil
    ) {
        self.control = control
        self.writeInterval = writeInterval
        self.echoGrace = writeInterval * 2
        self.memory = memory
    }

    // MARK: - Lancement

    /// Au lancement de l'app : une mémoire restée là (plantage, `kill -9`) est rendue, puis effacée.
    /// Rien d'autre n'est lu ni écrit hors diffusion.
    func restoreLeftoverMemory() {
        guard !isActive, let memory else { return }
        volumeLinkLog.notice(
            "Volume du Mac d'une diffusion interrompue trouvé au lancement : rendu à « \(memory.deviceName, privacy: .public) »"
        )
        restore(memory)
        forgetMemory()
    }

    // MARK: - Diffusion

    /// La sortie du Mac peut-elle piloter les enceintes ? Lue au démarrage d'une diffusion, pour décider
    /// s'il faut couper le son local par le tap. Une sortie sans volume réglable : non, et le panneau le
    /// dit.
    func canLink() -> Bool {
        guard isEnabled else { return false }
        guard let reading = control.read() else { return false }
        guard reading.volume != nil else {
            noteInoperative(reading)
            return false
        }
        if inoperativeDeviceName != nil { inoperativeDeviceName = nil }
        return true
    }

    /// La diffusion a démarré, le son local coupé : mémorise le Mac, puis le règle sur le master.
    func beginSession(masterDB: Double, isMuted: Bool) {
        guard isEnabled, !isActive else { return }
        // Une mémoire d'avant : le Mac ne l'a pas encore retrouvée. Elle passe en premier.
        if memory != nil { restoreLeftoverMemory() }
        appMasterDB = masterDB
        appIsMuted = isMuted
        guard let reading = control.read() else {
            volumeLinkLog.notice("Aucune sortie sur le Mac : volume non relié")
            return
        }
        isActive = true
        control.startObserving { [weak self] in self?.systemDidChange() }
        take(reading, context: "Diffusion")
    }

    /// La diffusion s'arrête : le Mac retrouve son volume et son silence. À appeler **avant** de
    /// détruire le tap, pour que le rétablissement se fasse pendant que le son local est encore coupé.
    func endSession() {
        if inoperativeDeviceName != nil { inoperativeDeviceName = nil }
        guard isActive else { return }
        isActive = false
        control.stopObserving()
        cancelWrites()
        device = nil
        knownScalar = nil
        knownMute = nil
        if let memory {
            restore(memory)
            forgetMemory()
        }
    }

    /// Mémorise la sortie (persistée avant toute écriture), puis l'aligne sur le master.
    private func take(_ reading: SystemOutputVolume.Reading, context: String) {
        cancelWrites()
        memory = SystemVolumeMemory(
            deviceUID: reading.deviceUID, deviceName: reading.deviceName,
            volume: reading.volume, isMuted: reading.isMuted
        )
        onMemoryChange()
        device = reading.deviceID
        knownScalar = reading.volume.map(Double.init)
        knownMute = reading.volume == nil ? nil : reading.isMuted

        guard let known = knownScalar else {
            noteInoperative(reading)
            return
        }
        if inoperativeDeviceName != nil { inoperativeDeviceName = nil }
        let target = Self.scalar(forMasterDB: appMasterDB)
        pendingScalar = abs(target - known) < 1e-9 ? nil : target
        if let knownMute, knownMute != appIsMuted { pendingMute = appIsMuted }
        flush()
        volumeLinkLog.notice(
            """
            \(context, privacy: .public) : volume du Mac « \(reading.deviceName, privacy: .public) » \
            mémorisé (\(Self.percent(known), privacy: .public) %, silence \
            \(Self.text(reading.isMuted), privacy: .public)), réglé sur le master \
            \(self.appMasterDB, format: .fixed(precision: 2), privacy: .public) dB
            """
        )
    }

    /// Rend au Mac ce qui avait été mémorisé, à la sortie mémorisée si elle est encore là. Couper avant
    /// de changer le volume, rétablir après : jamais un éclat au mauvais niveau.
    private func restore(_ memory: SystemVolumeMemory) {
        guard let target = control.device(forUID: memory.deviceUID) else {
            volumeLinkLog.notice(
                "Sortie du Mac « \(memory.deviceName, privacy: .public) » absente : son volume n'est pas rendu"
            )
            return
        }
        if memory.isMuted == true { control.setMuted(true, on: target) }
        if let volume = memory.volume { control.setVolume(volume, on: target) }
        if memory.isMuted == false { control.setMuted(false, on: target) }
        let volumeText = memory.volume.map { "\(Self.percent(Double($0))) %" } ?? "sans volume"
        volumeLinkLog.notice(
            """
            Volume du Mac rendu à « \(memory.deviceName, privacy: .public) » : \
            \(volumeText, privacy: .public), silence \(Self.text(memory.isMuted), privacy: .public)
            """
        )
    }

    private func forgetMemory() {
        guard memory != nil else { return }
        memory = nil
        onMemoryChange()
    }

    private func noteInoperative(_ reading: SystemOutputVolume.Reading) {
        let name = reading.deviceName.isEmpty ? "sans nom" : reading.deviceName
        if inoperativeDeviceName != name { inoperativeDeviceName = name }
        volumeLinkLog.notice(
            """
            Sortie du Mac « \(name, privacy: .public) » sans volume réglable : les touches de volume \
            n'agissent pas sur les enceintes
            """
        )
    }

    private static func percent(_ scalar: Double) -> Int { Int((scalar * 100).rounded()) }

    private static func text(_ muted: Bool?) -> String {
        muted.map { $0 ? "oui" : "non" } ?? "sans objet"
    }

    // MARK: - Du Mac vers les enceintes

    private func systemDidChange() {
        guard isActive, let reading = control.read() else { return }
        guard reading.deviceID == device else {
            switchDevice(to: reading)
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

    /// Une autre sortie du Mac en pleine diffusion : l'ancienne retrouve son volume, la nouvelle est
    /// mémorisée, puis réglée sur le master. Le master ne bouge pas.
    private func switchDevice(to reading: SystemOutputVolume.Reading) {
        if let previous = memory {
            restore(previous)
        }
        take(reading, context: "Sortie du Mac changée en diffusion")
    }

    private func deliver(_ update: Update) {
        guard update.masterDB != nil || update.isMuted != nil else { return }
        if let master = update.masterDB { appMasterDB = master }
        if let muted = update.isMuted { appIsMuted = muted }
        isApplying = true
        defer { isApplying = false }
        onUpdate(update)
    }

    // MARK: - De l'app vers le Mac

    /// Le master a bougé dans l'app : le Mac suit, au prochain tour, pendant une diffusion.
    ///
    /// Comparé à la valeur connue sans la tolérance, qui ne vaut que pour ce qui revient du Mac : un
    /// glissement qui finit à moins d'un demi-cran de la dernière écriture doit quand même arriver, sans
    /// quoi le Mac resterait à 99 % quand le master est au maximum. Le débit, lui, reste borné.
    func appDidChange(masterDB: Double) {
        guard !isApplying else { return }
        appMasterDB = masterDB
        guard isActive, device != nil, let known = knownScalar else { return }
        let scalar = Self.scalar(forMasterDB: masterDB)
        pendingScalar = abs(scalar - known) < 1e-9 ? nil : scalar
        if pendingScalar != nil { scheduleFlush() }
    }

    /// Le silence des enceintes a basculé dans l'app : le Mac suit, au prochain tour.
    func appDidChange(isMuted: Bool) {
        guard !isApplying else { return }
        appIsMuted = isMuted
        guard isActive, device != nil, let known = knownMute else { return }
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
        guard isActive, let device else { return }
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
}
