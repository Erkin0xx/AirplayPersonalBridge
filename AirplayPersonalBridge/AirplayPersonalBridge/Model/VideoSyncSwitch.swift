//
//  VideoSyncSwitch.swift
//  AirplayPersonalBridge
//

import AudioCore
import Foundation
import OSLog

private let videoSyncLog = Logger(subsystem: AudioLog.subsystem, category: "video-sync")

/// La sortie du Mac d'avant une diffusion, à lui rendre à la fin.
///
/// Persistée dans `settings.json` **avant** qu'on touche au Mac : après un plantage ou un `kill -9`, le
/// lancement suivant la rend (`VideoSyncSwitch.restoreLeftoverMemory`). Jamais la sortie virtuelle.
struct VideoSyncMemory: Codable, Equatable {
    var deviceUID: String
    var deviceName: String
    /// `nil` : rien à rendre de ce côté, faute de volume réglable, ou parce que le lien du volume du
    /// Mac s'en charge (bascule en pleine diffusion).
    var volume: Float?
    var isMuted: Bool?
}

/// Fait de la sortie virtuelle « AirPlay Personal Bridge » (`Drivers/APBOutput`) la sortie par défaut du
/// Mac **le temps d'une diffusion**, pour que les lecteurs vidéo retardent l'image du retard des
/// enceintes. Le pilote jette le son et annonce ce retard (`VideoSyncLatency`) ; Chromium et AVPlayer
/// le lisent à l'ouverture de leur flux. Le son, lui, ne passe jamais par le pilote : le tap le capte en
/// amont de toute sortie. Rien ne change sur le fil.
///
/// **Une diffusion.** Avant la capture : la sortie du Mac est mémorisée et persistée, la latence écrite
/// dans le pilote, puis le pilote devient la sortie par défaut. Avant la capture, parce que l'agrégat du
/// tap prend pour horloge la sortie par défaut du moment ; avant le lien du volume
/// (`SystemVolumeLink.beginSession`), qui doit trouver le pilote comme sortie du Mac, et lui relier les
/// touches de volume. À l'arrêt, capture détruite : la sortie d'origine retrouve sa place, son volume et
/// son silence.
///
/// **Le choix de l'utilisateur prime.** Une autre sortie choisie en pleine diffusion (un casque) est
/// laissée à l'arrêt, et la mémoire oubliée ; aucune bascule ne la remplace avant le prochain démarrage
/// demandé par l'utilisateur, relances comprises. Rien n'est observé pour cela : l'arrêt constate.
///
/// **Jamais le Mac sur le pilote hors diffusion**, où il serait muet. Sortie d'origine débranchée, ou
/// pilote trouvé en sortie par défaut sans mémoire (reste d'une bascule à la main) : repli sur la sortie
/// intégrée, sinon la première autre. Le pilote n'est jamais mémorisé comme sortie d'origine.
@Observable
final class VideoSyncSwitch {
    static let virtualOutputUID = VirtualOutputDevice.deviceUID

    /// L'option « Caler l'image des vidéos ». La désactiver en pleine diffusion rend aussitôt la sortie
    /// d'origine ; la capture se reconstruit d'elle-même au changement de sortie.
    var isEnabled = true {
        didSet { if oldValue != isEnabled, !isEnabled { endSession() } }
    }

    /// Vrai pendant une diffusion où le pilote a été fait sortie par défaut par l'app.
    private(set) var isActive = false

    /// Le pilote est-il installé ? Relu à l'ouverture du panneau, au lancement et à chaque démarrage.
    private(set) var isDriverInstalled = false

    /// La sortie que l'utilisateur a choisie à la place du pilote pendant une diffusion : plus de
    /// bascule jusqu'au prochain démarrage qu'il demande. Le panneau le dit.
    private(set) var userChosenOutputName: String?

    /// Ce qu'il faudra rendre au Mac. À persister dès qu'il change (`onMemoryChange`).
    @ObservationIgnored private(set) var memory: VideoSyncMemory?

    /// La mémoire a changé : à écrire tout de suite, pas au prochain enregistrement différé.
    @ObservationIgnored var onMemoryChange: () -> Void = {}

    @ObservationIgnored private let control: any DefaultOutputSwitching

    init(control: any DefaultOutputSwitching, memory: VideoSyncMemory? = nil) {
        self.control = control
        self.memory = memory
    }

    // MARK: - Pilote

    /// Relit la présence du pilote. Rend la valeur relue.
    @discardableResult
    func refreshDriverPresence() -> Bool {
        let installed = control.isVirtualOutputInstalled()
        if installed != isDriverInstalled { isDriverInstalled = installed }
        return installed
    }

    // MARK: - Lancement

    /// Au lancement de l'app : une mémoire restée là (plantage, `kill -9`) est rendue, puis effacée ; le
    /// pilote trouvé en sortie par défaut sans mémoire cède la place à la sortie de repli. Quel que soit
    /// l'état de l'option : hors diffusion, le pilote rend le Mac muet.
    func restoreLeftoverMemory() {
        guard !isActive else { return }
        refreshDriverPresence()
        if let memory {
            videoSyncLog.notice(
                "Sortie du Mac d'une diffusion interrompue trouvée au lancement : « \(memory.deviceName, privacy: .public) »"
            )
            endSession()
            return
        }
        guard isDriverInstalled, control.currentOutput()?.deviceUID == Self.virtualOutputUID else {
            return
        }
        videoSyncLog.notice("Pilote en sortie par défaut hors diffusion, sans sortie d'origine connue")
        restoreOrigin()
    }

    // MARK: - Diffusion

    /// L'utilisateur demande une diffusion : un choix de sortie fait pendant la précédente ne vaut plus.
    func forgetUserChoice() {
        if userChosenOutputName != nil { userChosenOutputName = nil }
    }

    /// Avant la capture : mémorise la sortie du Mac (persistée avant toute écriture), écrit la latence
    /// du pilote, puis fait du pilote la sortie par défaut. Rend vrai si le pilote est en place.
    ///
    /// - Parameter memorizesLevels: faux quand le lien du volume du Mac tient déjà cette sortie (bascule
    ///   en pleine diffusion) : il lui a imposé le master, et lui rendra lui-même son volume d'origine
    ///   en passant au pilote. Les mémoriser ici rendrait le master à l'arrêt.
    @discardableResult
    func beginSession(memorizesLevels: Bool = true) -> Bool {
        guard isEnabled, !isActive else { return false }
        if let name = userChosenOutputName {
            videoSyncLog.notice(
                "« \(name, privacy: .public) » choisie pendant la diffusion : pas de bascule avant le prochain démarrage"
            )
            return false
        }
        guard refreshDriverPresence() else {
            videoSyncLog.notice("Pilote absent : image des vidéos non calée")
            return false
        }

        let current = control.currentOutput()
        let isOnDriver = current?.deviceUID == Self.virtualOutputUID
        if isOnDriver {
            // Déjà la sortie par défaut. Une mémoire d'avant dit d'où l'on vient ; sans elle (bascule à
            // la main), on rendra la sortie de repli, jamais le pilote.
            if memory == nil, let fallback = fallbackOutput() {
                remember(fallback, levels: memorizesLevels)
            }
        } else {
            guard let current else {
                videoSyncLog.error("Sortie du Mac illisible : image des vidéos non calée")
                return false
            }
            remember(current, levels: memorizesLevels)
        }

        let frames = VideoSyncLatency.frames()
        guard control.setVirtualOutputLatency(frames: frames) else {
            // Sans latence, le pilote ne servirait qu'à rendre le Mac muet. Déjà en place, l'arrêt le
            // retirera : la mémoire reste.
            videoSyncLog.error("Latence du pilote refusée : sortie du Mac inchangée")
            if !isOnDriver { forgetMemory() }
            return false
        }
        if !isOnDriver {
            guard control.makeDefault(uid: Self.virtualOutputUID) else {
                videoSyncLog.error("Le pilote n'a pas pu devenir la sortie par défaut")
                forgetMemory()
                return false
            }
        }
        isActive = true
        videoSyncLog.notice(
            """
            Sortie du Mac « \(self.memory?.deviceName ?? "aucune", privacy: .public) » mémorisée, \
            pilote en sortie par défaut, latence \(frames) trames
            """
        )
        return true
    }

    /// La diffusion s'est arrêtée, capture détruite : le Mac retrouve sa sortie d'origine, son volume et
    /// son silence. Idempotent : sans session ni mémoire, rien n'est lu ni écrit.
    ///
    /// Une autre sortie choisie pendant la diffusion est laissée, et la mémoire oubliée. Une sortie
    /// illisible (coreaudiod en pleine relance) garde la mémoire pour le prochain arrêt ou lancement.
    func endSession() {
        let wasActive = isActive
        if isActive { isActive = false }
        guard wasActive || memory != nil else { return }
        guard let current = control.currentOutput() else {
            videoSyncLog.error("Sortie du Mac illisible : sortie d'origine rendue plus tard")
            return
        }
        guard current.deviceUID == Self.virtualOutputUID else {
            if wasActive, userChosenOutputName != current.deviceName {
                userChosenOutputName = current.deviceName
            }
            videoSyncLog.notice(
                "« \(current.deviceName, privacy: .public) » choisie pendant la diffusion : laissée telle quelle"
            )
            forgetMemory()
            return
        }
        restoreOrigin()
    }

    // MARK: - Restitution

    /// Le Mac est sur le pilote : la sortie mémorisée reprend sa place, ou à défaut la sortie de repli.
    /// Volume et silence d'abord, sortie ensuite : elle ne joue jamais au mauvais niveau.
    private func restoreOrigin() {
        if let memory, control.output(uid: memory.deviceUID) != nil {
            restoreLevels(memory)
            guard control.makeDefault(uid: memory.deviceUID) else {
                videoSyncLog.error(
                    "« \(memory.deviceName, privacy: .public) » refusée comme sortie par défaut : nouvel essai plus tard"
                )
                return
            }
            videoSyncLog.notice("Sortie du Mac rendue : « \(memory.deviceName, privacy: .public) »")
            forgetMemory()
            return
        }
        if let memory {
            videoSyncLog.notice("Sortie d'origine « \(memory.deviceName, privacy: .public) » absente : repli")
        }
        guard let fallback = fallbackOutput() else {
            // Rien d'autre que le pilote : la mémoire reste, pour la sortie d'origine rebranchée.
            videoSyncLog.error("Aucune autre sortie que le pilote : le Mac reste muet")
            return
        }
        guard control.makeDefault(uid: fallback.deviceUID) else {
            videoSyncLog.error("Sortie de repli « \(fallback.deviceName, privacy: .public) » refusée")
            return
        }
        videoSyncLog.notice("Sortie du Mac : repli sur « \(fallback.deviceName, privacy: .public) »")
        forgetMemory()
    }

    /// Couper avant de changer le volume, rétablir après : jamais un éclat au mauvais niveau. N'écrit que
    /// ce qui a changé.
    private func restoreLevels(_ memory: VideoSyncMemory) {
        guard let now = control.output(uid: memory.deviceUID) else { return }
        let uid = memory.deviceUID
        if memory.isMuted == true, now.isMuted == false { control.setMuted(true, onOutput: uid) }
        if let volume = memory.volume, let current = now.volume, abs(current - volume) > 1e-4 {
            control.setVolume(volume, onOutput: uid)
        }
        if memory.isMuted == false, now.isMuted == true { control.setMuted(false, onOutput: uid) }
    }

    /// La sortie intégrée du Mac, sinon la première autre que le pilote.
    private func fallbackOutput() -> SystemOutputVolume.Reading? {
        let candidates = [control.builtInOutputUID()].compactMap { $0 } + control.outputUIDs()
        for uid in candidates where uid != Self.virtualOutputUID {
            if let reading = control.output(uid: uid) { return reading }
        }
        return nil
    }

    private func remember(_ reading: SystemOutputVolume.Reading, levels: Bool) {
        guard reading.deviceUID != Self.virtualOutputUID else { return }
        let memory = VideoSyncMemory(
            deviceUID: reading.deviceUID, deviceName: reading.deviceName,
            volume: levels ? reading.volume : nil, isMuted: levels ? reading.isMuted : nil
        )
        guard memory != self.memory else { return }
        self.memory = memory
        onMemoryChange()
    }

    private func forgetMemory() {
        guard memory != nil else { return }
        memory = nil
        onMemoryChange()
    }
}
