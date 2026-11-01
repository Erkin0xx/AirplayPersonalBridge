import AVFoundation
import Foundation
import OSLog

/// État observable d'un sender AirPlay 2.
public enum AirPlay2SenderState: String, Sendable {
    case idle
    case connecting
    case streaming
    /// Session perdue, rétablissement en cours (CDC section 8), sans effet sur la capture
    /// ni sur l'autre sortie.
    case reconnecting
    case failed
}

/// Sender AirPlay 2 (CDC 4.4) : pair-setup SRP, canal de contrôle chiffré, RTSP pour la
/// négociation, RTP pour le transport, PCM chiffré pour la charge utile.
///
/// ## Position dans l'architecture (invariants section 12)
///
/// Ce sender est le **jumeau** de `RAOPSender`, et respecte exactement les mêmes règles :
///
/// - Il **lit** un `AudioRingBuffer` alimenté par la capture et ne l'écrit jamais. Le PCM
///   extrait est copié dans un tampon propre au sender avant toute transformation
///   (rééchantillonnage, encodage, chiffrement) : le tampon partagé n'est jamais modifié.
/// - Il **ignore tout de la source de capture** : il ne reçoit qu'un ring buffer et un
///   format. Symétriquement, la capture ignore tout de lui.
/// - Il **ignore l'existence du sender RAOP**. Les deux peuvent tourner en parallèle sur
///   deux ring buffers distincts, sans se connaître ni partager le moindre état.
/// - Une panne ici est **confinée** : les erreurs d'émission sont comptées et la boucle
///   continue, sans jamais toucher à la capture ni à l'autre sortie.
///
/// ## Séquence protocolaire
///
/// `POST /pair-setup` (M1→M4, SRP transitoire) → chiffrement du canal → `SETUP` (session,
/// rend `eventPort`) → `SETUP` (flux, rend `dataPort`/`controlPort`) →
/// `SET_PARAMETER` (volume) → `RECORD` → paquets RTP et `POST /feedback` périodique →
/// `TEARDOWN`.
///
/// Ordre vérifié contre le mock, et recoupé avec une session pyatv de référence vers ce même
/// récepteur. Le CDC 4.4 désigne `airplay.c` d'OwnTone comme référence de comportement :
/// c'est bien un enchaînement logique réécrit ici en Swift, jamais du code porté.
public actor AirPlay2Sender {
    /// Trames par paquet, valeur canonique du protocole (identique à RAOP).
    private static let framesPerPacket = ALACEncoder.framesPerPacket
    /// Fréquence du flux négocié. La capture livre du 48 kHz : le rééchantillonnage vers
    /// 44,1 kHz tourne dans la tâche du sender, en aval du ring buffer (CDC 4.5).
    private static let streamSampleRate = 44_100
    private static let streamChannelCount = 2
    /// Latence annoncée dans les paquets de synchronisation, en trames à 44,1 kHz (~2 s).
    /// Identique à celle du sender RAOP : les deux sorties doivent viser la même profondeur
    /// de restitution pour que l'ancrage commun ait un sens.
    private static let latencyFrames: UInt32 = 88_200
    /// Période des annonces de synchro, en paquets audio (~1 s).
    private static let syncInterval = 126
    /// Erreurs d'émission consécutives au-delà desquelles la session est réputée perdue : ~2 s.
    ///
    /// Une valeur plus faible (20, soit 160 ms) transformait le moindre accroc Wi-Fi en
    /// reconnexion complète, audible pendant plusieurs secondes, alors que le paquet raté reste
    /// dans l'historique et que le tampon du récepteur lui laisse le temps de le réclamer.
    private static let lostSessionErrorThreshold = 250
    /// Durée de `TEARDOWN` qu'on s'accorde à l'arrêt, puis à la reconnexion : au-delà, on ferme
    /// sans attendre. Un récepteur muet ne doit jamais retenir l'arrêt de la diffusion.
    private static let stopTeardownLimit: Duration = .milliseconds(2_500)
    private static let lossTeardownLimit: Duration = .seconds(1)
    /// Une session qui a tenu au moins ce temps était saine : la suivante repart du délai de
    /// reconnexion le plus court. En deçà, le délai continue de croître, pour qu'un récepteur qui
    /// accepte puis coupe aussitôt ne parte pas en boucle serrée.
    private static let stableSessionDuration: Duration = .seconds(30)

    public private(set) var state: AirPlay2SenderState = .idle

    private let device: AirPlay2Device
    private let ring: AudioRingBuffer
    private let captureFormat: AVAudioFormat
    /// Alignement, réglage manuel et correction de dérive de **cette** sortie (CDC 4.5).
    public nonisolated let synchronizer: OutputSynchronizer
    private let log = AudioLog.airplay2

    private var rtsp: RTSPClient?
    private var session: AirPlay2Session?
    private var resampler: RAOPResampler?
    private var streamCipher: ChaChaPoly1305?

    private var audioChannel: UDPChannel?
    /// Canal de contrôle : c'est par lui que passent les annonces de synchronisation NTP,
    /// que le récepteur attend au même format qu'en RAOP (`TIME_ANNOUNCE_NTP`).
    private var controlChannel: UDPChannel?
    /// Canal d'horloge. Son port local est annoncé au `SETUP` (`timingPort`) : il doit donc
    /// être ouvert avant, et rester ouvert tant que la session vit.
    private var timingChannel: UDPChannel?
    /// Canal d'événements, ouvert depuis l'`eventPort` du premier `SETUP` (jalon 4).
    private var eventChannel: AirPlay2EventChannel?

    private let ssrc: UInt32 = UInt32.random(in: .min ... .max)
    private var sequenceNumber = UInt16.random(in: 0...UInt16.max / 2)
    private var rtpTimestamp: UInt32 = UInt32.random(in: 0...UInt32.max / 2)
    private var packetsSent = 0
    /// Paquets émis depuis le début de la session courante : c'est lui qui décide du bit
    /// marker et de la première annonce de synchro, qui doivent repartir à zéro à chaque
    /// reconnexion.
    private var packetsInSession = 0
    private var streamTask: Task<Void, Never>?
    private var currentVolume: Float = -20
    private let reconnects: Bool
    /// Credentials d'appairage système, quand ce récepteur en exige un. `nil` = pairing
    /// transitoire, qui n'a rien à mémoriser.
    private let credentials: HapCredentials?
    private var sessionLost = false
    private var consecutiveSendErrors = 0
    /// Numéro de la session courante. Un signal de perte peut arriver en retard, par une tâche
    /// en vol : il ne doit jamais condamner la session qui a remplacé la sienne.
    private var sessionGeneration = 0
    /// `stop()` appelé pendant que `start()` négocie.
    private var stopRequestedDuringStart = false
    /// Paquets émis, pour répondre aux demandes de retransmission.
    private let retransmitter = AirPlay2Retransmitter()
    /// Maintien de session (`POST /feedback`).
    private var keepAliveTask: Task<Void, Never>?
    private var keepAlivePolicy = KeepAlivePolicy()

    /// Réglages du maintien de session.
    struct KeepAlivePolicy: Sendable {
        /// Cadence : celle de pyatv et d'iOS.
        var interval: Duration = .seconds(2)
        /// Échéance d'un `feedback`.
        var timeout: Duration = .seconds(4)
        /// `feedback` consécutifs sans réponse au-delà desquels le récepteur est réputé parti.
        var silenceThreshold = 3
    }

    /// Permet aux tests de vérifier la détection de silence sans attendre vingt secondes.
    func setKeepAlivePolicy(_ policy: KeepAlivePolicy) {
        keepAlivePolicy = policy
    }

    /// Échantillons convertis en attente de constituer un paquet complet de 352 trames.
    /// Propre au sender : c'est cette copie que tout le traitement manipule.
    private var pendingSamples: [Int16] = []
    /// Tampon de lecture du ring buffer, alloué une fois pour éviter toute allocation en
    /// régime établi.
    private var readScratch: [Float]

    public private(set) var statistics = AirPlay2Statistics()

    /// - Parameters:
    ///   - device: le récepteur, tel que la découverte Bonjour l'a résolu.
    ///   - ring: le ring buffer **propre à cette sortie**, alimenté par la capture. Chaque
    ///     pipeline de sortie a le sien (invariant section 12).
    ///   - captureFormat: format livré par la capture, pour configurer le rééchantillonneur.
    ///   - clock: horloge de restitution commune (CDC 4.5). Passer **la même** aux deux
    ///     senders est ce qui les aligne ; à défaut, chacun s'en fabrique une et se comporte
    ///     comme au jalon 3.
    ///   - reconnects: rétablissement automatique de la session après perte réseau.
    public init(
        device: AirPlay2Device,
        ring: AudioRingBuffer,
        captureFormat: AVAudioFormat,
        clock: PlaybackClockProtocol? = nil,
        reconnects: Bool = true,
        credentials: HapCredentials? = nil
    ) {
        self.device = device
        self.ring = ring
        self.captureFormat = captureFormat
        self.reconnects = reconnects
        self.credentials = credentials
        let effectiveClock =
            clock ?? SharedPlaybackClock(captureSampleRate: captureFormat.sampleRate)
        (effectiveClock as? SharedPlaybackClock)?.startIfNeeded()
        self.synchronizer = OutputSynchronizer(
            label: "AirPlay2/\(device.serviceName)",
            clock: effectiveClock,
            outputSampleRate: Double(Self.streamSampleRate)
        )
        self.readScratch = [Float](
            repeating: 0, count: 8_192 * Int(captureFormat.channelCount)
        )
    }

    /// Décalage manuel de cette sortie, en secondes (CDC 4.5 : fine-tune et filet de
    /// sécurité). Positif = restituer plus tard. Applicable en cours de diffusion.
    public func setManualDelay(seconds: TimeInterval) {
        synchronizer.manualOffsetSeconds = seconds
    }

    // MARK: - Session

    /// Établit la session (pairing compris) et démarre la diffusion.
    ///
    /// - Throws: un ``AirPlay2SenderError`` dont la description est faite pour l'affichage, ou
    ///   `CancellationError` si la tâche a été annulée ou `stop()` appelé entre-temps.
    public func start(volume: Float = -20) async throws {
        guard state == .idle || state == .failed else { return }
        state = .connecting
        currentVolume = volume
        stopRequestedDuringStart = false

        do {
            try await negotiateCancellably(volume: volume)
        } catch {
            await teardown()
            if Task.isCancelled || stopRequestedDuringStart {
                state = .idle
                throw CancellationError()
            }
            state = .failed
            log.error(
                "Établissement de la session AirPlay 2 en échec : \(String(describing: error), privacy: .public)"
            )
            let failure = readable(error)
            statistics.lastFailure = failure.description
            throw failure
        }
        // L'arrêt a pu tomber juste après le dernier échange de la négociation.
        if Task.isCancelled || stopRequestedDuringStart {
            await teardown()
            state = .idle
            throw CancellationError()
        }

        beginStreaming(firstSession: true)
        state = .streaming
        streamTask = Task { [weak self] in
            await self?.supervise()
        }
        log.info("Diffusion AirPlay 2 démarrée vers \(self.device.serviceName, privacy: .public)")
    }

    /// Prépare le début (ou la reprise) de la diffusion.
    private func beginStreaming(firstSession: Bool) {
        // La capture tourne pendant la découverte et toute la négociation (pairing SRP
        // compris, plusieurs secondes) : le ring buffer contient un arriéré périmé et a
        // sans doute déjà débordé. Le jeter évite de démarrer avec du retard sur le direct.
        //
        // C'est une lecture, pas une écriture : avancer l'index de lecture est le rôle
        // normal du consommateur, l'invariant section 12 reste respecté.
        let staleFrames = ring.availableFrames
        if staleFrames > 0 {
            discardStaleAudio()
            log.info("Arriéré de \(staleFrames) trames écarté avant le début de la diffusion")
        }
        pendingSamples.removeAll(keepingCapacity: true)
        if firstSession {
            // Photographie du compteur de refus au démarrage réel de la diffusion : tout ce
            // qui précède est imputable à la fenêtre de négociation, pendant laquelle la
            // capture tourne sans consommateur.
            statistics.droppedBeforeStreaming = ring.droppedFrames
        }
        packetsInSession = 0
        consecutiveSendErrors = 0
        synchronizer.beginStreaming(atCaptureFrame: ring.totalFramesRead)
    }

    /// Surveille la diffusion et rétablit la session après une perte réseau (CDC section 8).
    ///
    /// Isolée par construction : ni la capture, ni le ring buffer, ni l'autre sortie ne sont
    /// touchés — cette dernière n'a d'ailleurs aucun moyen de savoir que celle-ci a décroché
    /// (invariant section 12). La reconnexion refait **tout** le chemin, pair-setup compris :
    /// les clés de session et le chiffrement du canal ne survivent pas à une coupure.
    private func supervise() async {
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            let sessionStart = ContinuousClock.now
            await streamLoop()
            guard !Task.isCancelled, sessionLost else { return }

            // Sans reconnexion, l'état doit le dire : rester en `.streaming` sur une session
            // morte ferait croire à une sortie qui joue.
            guard reconnects else {
                await tearDownSessionBestEffort(limit: Self.lossTeardownLimit)
                await teardown()
                state = .failed
                statistics.lastFailure =
                    AirPlay2SenderError.connectionLost(receiver: device.serviceName).description
                return
            }

            state = .reconnecting
            statistics.reconnections += 1
            log.error("Session AirPlay 2 perdue — tentative de rétablissement")
            // La perte d'un seul canal laisse souvent la connexion de contrôle vivante. Fermer
            // proprement évite que le récepteur nous croie encore là, et refuse en `453` la
            // session qu'on s'apprête à rouvrir.
            await tearDownSessionBestEffort(limit: Self.lossTeardownLimit)
            await teardown()
            guard !Task.isCancelled else { return }

            backoff =
                ContinuousClock.now - sessionStart >= Self.stableSessionDuration
                ? .seconds(1) : min(backoff * 2, .seconds(15))

            var reconnected = false
            while !Task.isCancelled && !reconnected {
                do {
                    try await Task.sleep(for: backoff)
                    try await negotiateCancellably(volume: currentVolume)
                    reconnected = true
                } catch {
                    // `stop()` ferme lui-même : refermer ici pourrait atteindre la session
                    // d'un `start()` suivant.
                    if Task.isCancelled { return }
                    let failure = readable(error)
                    statistics.reconnectionAttempts += 1
                    statistics.lastFailure = failure.description
                    log.error(
                        "Reconnexion AirPlay 2 en échec : \(String(describing: error), privacy: .public)"
                    )
                    await teardown()
                    // Sans geste de l'utilisateur, réessayer un appairage refusé ne mènera nulle
                    // part, et un Apple TV finit par sanctionner les tentatives répétées.
                    if failure.isPermanent {
                        state = .failed
                        return
                    }
                    backoff = min(max(backoff * 2, failure.minimumRetryDelay), .seconds(15))
                }
            }
            guard reconnected, !Task.isCancelled else { return }
            beginStreaming(firstSession: false)
            state = .streaming
            log.info("Session AirPlay 2 rétablie")
        }
    }

    /// Arrête la diffusion et libère la session.
    ///
    /// Ne reste jamais bloqué : le `TEARDOWN` a droit à un délai borné, après quoi la connexion
    /// est fermée sans attendre sa réponse. Appelable depuis une tâche déjà annulée — le moteur
    /// le fait — d'où les tâches non structurées, qui n'héritent pas de cette annulation.
    public func stop() async {
        if state == .connecting { stopRequestedDuringStart = true }
        let supervision = streamTask
        streamTask = nil
        supervision?.cancel()
        keepAliveTask?.cancel()
        keepAliveTask = nil

        if state == .streaming || state == .reconnecting {
            await tearDownSessionBestEffort(limit: Self.stopTeardownLimit)
        }
        await teardown()
        if let supervision {
            // La supervision en cours se débloque d'elle-même, la connexion étant fermée. L'attendre
            // évite qu'une négociation interrompue n'écrive dans l'état d'un `start()` suivant.
            await Self.waitForCompletion(of: supervision, atMost: .seconds(1))
            await teardown()
        }
        state = .idle
        log.info("Diffusion AirPlay 2 arrêtée (\(self.packetsSent) paquets émis)")
    }

    /// Envoie un `TEARDOWN` sans jamais attendre plus que `limit`.
    private func tearDownSessionBestEffort(limit: Duration) async {
        guard let session else { return }
        let teardown = Task { await session.teardown() }
        await Self.waitForCompletion(of: teardown, atMost: limit)
    }

    /// Attend une tâche, mais pas plus que `limit`. La tâche n'est pas annulée pour autant.
    private static func waitForCompletion(
        of task: Task<Void, Never>, atMost limit: Duration
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = ManagedFlag()
            let timer = Task {
                try? await Task.sleep(for: limit)
                if resumed.claim() { continuation.resume() }
            }
            Task {
                await task.value
                timer.cancel()
                if resumed.claim() { continuation.resume() }
            }
        }
    }

    /// Règle le volume en cours de session.
    ///
    /// La consigne est retenue même hors session : c'est elle qu'une reconnexion réapplique.
    /// Sans cela, une perte réseau ramenait la sortie au volume de son démarrage.
    public func setVolume(_ volume: Float) async throws {
        currentVolume = volume
        guard let session else { return }
        try await session.setVolume(volume)
    }

    private func readable(_ error: Error) -> AirPlay2SenderError {
        AirPlay2SenderError(
            classifying: error,
            receiver: device.serviceName,
            address: "\(device.host):\(device.port)",
            hasCredentials: credentials != nil
        )
    }

    // MARK: - Négociation

    /// Négocie, en interrompant l'échange dès que la tâche est annulée.
    ///
    /// Les attentes réseau ne réagissent pas d'elles-mêmes à l'annulation : sans ce gestionnaire,
    /// arrêter une sortie en cours de connexion restait bloqué jusqu'à l'échéance de l'étape en
    /// cours, soit jusqu'à dix secondes.
    private func negotiateCancellably(volume: Float) async throws {
        try await withTaskCancellationHandler {
            try await negotiate(volume: volume)
        } onCancel: { [weak self] in
            Task { await self?.abortNegotiation() }
        }
    }

    private func abortNegotiation() async {
        eventChannel?.close()
        await rtsp?.disconnect()
    }

    private func negotiate(volume: Float) async throws {
        sessionGeneration &+= 1
        let generation = sessionGeneration
        sessionLost = false

        let client = RTSPClient(host: device.host, port: device.port)
        rtsp = client
        try Task.checkCancellation()
        do {
            try await client.connect()
        } catch {
            throw AirPlay2SenderError.connectionFailure(
                error, receiver: device.serviceName, address: "\(device.host):\(device.port)"
            )
        }

        // Second signal de perte, à côté du canal d'événements (voir ``noteSessionLost``).
        await client.onConnectionLost { [weak self] in
            Task {
                await self?.noteSessionLost(generation: generation, reason: "connexion RTSP rompue")
            }
        }

        // 1. Pairing. Deux chemins, et c'est la présence de credentials qui tranche :
        //    un appairage système déjà acquis se rejoue par `pair-verify`, sans code à
        //    saisir ; à défaut, on tente le transitoire, qui n'exige rien mais que certains
        //    récepteurs — un Apple TV, typiquement — refusent en 470.
        let pairing = AirPlay2PairingSession(client: client, device: device)
        let keys: AirPlay2PairingSession.SessionKeys
        if let credentials {
            keys = try await pairing.performPairVerify(credentials: credentials)
        } else {
            keys = try await pairing.performTransientPairSetup()
        }

        // 2. Tout ce qui suit passe en chiffré. À activer seulement une fois la réponse M4
        //    entièrement lue : le récepteur ne chiffre qu'à partir du message suivant.
        try await client.enableEncryption(keys: keys)

        // 3. Les deux SETUP, puis le volume et le RECORD.
        let session = AirPlay2Session(client: client, device: device)
        self.session = session

        // Les canaux de contrôle et de timing sont ouverts **avant** le `SETUP` : leurs ports
        // locaux y sont annoncés. Le mock s'en passait, un récepteur Apple réel refuse en
        // `400` un `SETUP` sans `timingPort` — il n'aurait aucune adresse où interroger notre
        // horloge (comparaison avec pyatv, 2026-08-11).
        let control = try UDPChannel(label: "airplay2-control")
        let timing = try UDPChannel(label: "airplay2-timing")
        self.timingChannel = timing
        // Le répondeur d'horloge doit écouter **avant** le `SETUP`, pas après : le HomePod
        // interroge notre horloge dès qu'il a lu `timingPort`, et **ne répond au `SETUP`
        // qu'une fois cette mesure aboutie**. Sans répondeur, il émet ses requêtes dans le
        // vide et la session reste en suspens, sans le moindre message d'erreur — 22 requêtes
        // de 32 octets restées sans réponse, relevées à la capture le 2026-08-11.
        installTimingResponder(on: timing)
        timing.startReceiving()

        let endpoints = try await session.setup(
            timingPort: timing.localPort, controlPort: control.localPort
        )

        // Le canal audio est un socket UDP dont le port local est choisi par le système :
        // contrairement à RAOP, le récepteur n'exige pas ici un port annoncé à l'avance.
        let audio = try UDPChannel(label: "airplay2-audio")
        try audio.setDestination(host: device.host, port: endpoints.dataPort)
        audioChannel = audio

        // Canal de contrôle : c'est par lui que partent les annonces de synchronisation NTP
        // (jalon 4). Le récepteur les attend dans le même format qu'en RAOP — un RTCP
        // `TIME_ANNOUNCE_NTP`, type 0x54 — puisque le `SETUP` a négocié `timingProtocol=NTP`.
        // Il y renvoie ses demandes de retransmission, d'où l'écoute.
        if endpoints.controlPort != 0 {
            try control.setDestination(host: device.host, port: endpoints.controlPort)
            installControlObserver(on: control)
            control.startReceiving()
            controlChannel = control
        } else {
            log.error("Aucun port de contrôle annoncé : les annonces de synchro ne partiront pas")
        }

        // `audioBufferSize` est rapporté brut, **sans** être converti en latence : son unité
        // n'est pas établie et le mock y met une taille en octets (voir la documentation du
        // champ). La latence de référence d'AirPlay 2 reste celle que nous annonçons
        // nous-mêmes dans les paquets de synchronisation.
        statistics.receiverBufferSize = endpoints.audioBufferSize

        // Canal d'événements : signal de vie et répondeur aux requêtes du récepteur, sous les
        // clés dérivées du même secret que le canal de contrôle. Son indisponibilité n'empêche
        // pas de diffuser.
        if endpoints.eventPort != 0 {
            let events = AirPlay2EventChannel(
                host: device.host,
                port: endpoints.eventPort,
                sessionSecret: keys.sharedSecret,
                onMessage: { [weak self] _ in
                    Task { await self?.noteEventMessage() }
                }
            )
            // Stocké avant l'attente : une annulation doit pouvoir le fermer pendant celle-ci.
            eventChannel = events
            let connected = await events.connect { [weak self] in
                Task {
                    await self?.noteSessionLost(
                        generation: generation, reason: "canal d'événements rompu")
                }
            }
            statistics.eventChannelConnected = connected
        }

        // Même rééchantillonneur qu'au jalon 2 : la capture livre du 48 kHz, le flux exige
        // 44,1 kHz. Il tourne dans la tâche du sender, en aval du ring buffer — emplacement
        // explicitement autorisé par le CDC 4.5, jamais dans le callback temps réel.
        resampler = try RAOPResampler(
            inputFormat: captureFormat,
            outputSampleRate: Double(Self.streamSampleRate),
            channelCount: AVAudioChannelCount(Self.streamChannelCount)
        )
        // Le flux audio est chiffré avec la clé tirée au sort et transmise dans le SETUP.
        streamCipher = try ChaChaPoly1305(key: session.streamKey)

        try await session.setVolume(volume)
        try await session.record(startSequence: sequenceNumber, startTimestamp: rtpTimestamp)
        startKeepAlive(session: session, generation: generation)

        log.info(
            "Session AirPlay 2 négociée : data=\(endpoints.dataPort) control=\(endpoints.controlPort) event=\(endpoints.eventPort)"
        )
    }

    // MARK: - Diffusion

    /// Boucle de diffusion : un paquet par tour, à l'échéance.
    ///
    /// Hors temps réel (tâche propre au sender), donc Swift Concurrency est légitime ici
    /// (CDC 4.5 et section 13). Le cadencement reprend la leçon du jalon 2 : émettre tous
    /// les paquets disponibles d'un coup ferait déborder le tampon du récepteur.
    private func streamLoop() async {
        let packetDuration = Duration.seconds(
            Double(Self.framesPerPacket) / Double(Self.streamSampleRate)
        )
        var nextDeadline = ContinuousClock.now

        while !Task.isCancelled && !sessionLost {
            do {
                try drainRingBuffer()
            } catch {
                log.error(
                    "Erreur de lecture du flux AirPlay 2 : \(String(describing: error), privacy: .public)"
                )
                statistics.errors += 1
                // Invariant section 12 : l'échec reste confiné. Il n'interrompt ni la
                // capture ni l'autre sortie ; la boucle continue et retentera.
            }

            // Une correction de dérive peut demander une trame de plus que le paquet.
            let needed = (Self.framesPerPacket + 1) * Self.streamChannelCount
            guard pendingSamples.count >= needed else {
                try? await Task.sleep(for: .milliseconds(2))
                continue
            }

            let now = ContinuousClock.now
            if nextDeadline > now {
                try? await Task.sleep(until: nextDeadline, clock: .continuous)
            } else if now - nextDeadline > .seconds(1) {
                // Retard irrattrapable : repartir de maintenant plutôt que d'émettre une
                // rafale de rattrapage.
                nextDeadline = now
                statistics.resyncs += 1
            }

            do {
                try sendNextPacket()
                consecutiveSendErrors = 0
                nextDeadline += packetDuration
            } catch {
                log.error(
                    "Erreur d'émission AirPlay 2 : \(String(describing: error), privacy: .public)")
                statistics.errors += 1
                consecutiveSendErrors += 1
                if consecutiveSendErrors >= Self.lostSessionErrorThreshold { sessionLost = true }
                nextDeadline += packetDuration
            }
        }
    }

    /// Une rupture du canal d'événements ou de la connexion RTSP vaut perte de session.
    ///
    /// Ce sont les signaux francs dont dispose AirPlay 2 : le flux audio étant en UDP, un
    /// récepteur disparu ne provoque aucune erreur d'émission — les datagrammes partiraient
    /// indéfiniment dans le vide. Un signal peut arriver pendant la négociation (la boucle de
    /// diffusion sort alors aussitôt), ou en retard d'une session : le numéro l'écarte.
    func noteSessionLost(generation: Int, reason: String) {
        guard generation == sessionGeneration, !sessionLost else { return }
        log.error("Session AirPlay 2 réputée perdue : \(reason, privacy: .public)")
        sessionLost = true
    }

    private func noteEventMessage() {
        statistics.eventMessages += 1
    }

    /// Démarre le maintien de session, une fois le `RECORD` accepté.
    private func startKeepAlive(session: AirPlay2Session, generation: Int) {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            await self?.runKeepAlive(session: session, generation: generation)
        }
    }

    /// `POST /feedback` périodique, sans jamais entrelacer avec une autre requête : `RTSPClient`
    /// sérialise ses échanges.
    ///
    /// Trois issues, et une seule condamne la session :
    ///
    /// - **refus** (`4xx`, `5xx`) : le récepteur a répondu, il est donc là. pyatv traite ce
    ///   message en « best effort », et un keep-alive refusé ne vaut pas une panne ;
    /// - **rupture** de la connexion : perte franche. C'est même le seul moyen de voir une
    ///   fermeture côté récepteur, personne ne lisant cette connexion entre deux requêtes ;
    /// - **silence** : plusieurs échéances de suite, chez un récepteur qui répondait jusque-là,
    ///   signifient qu'il est parti sans fermer — éteint, ou sorti du réseau. Un récepteur qui
    ///   n'a *jamais* répondu n'est pas pénalisé : il ne gère peut-être pas ce message.
    private func runKeepAlive(session: AirPlay2Session, generation: Int) async {
        let policy = keepAlivePolicy
        var hasAnswered = false
        var silentRounds = 0

        while !Task.isCancelled && generation == sessionGeneration {
            do {
                try await session.sendFeedback(timeout: policy.timeout)
                hasAnswered = true
                silentRounds = 0
                statistics.feedbackSent += 1
            } catch RTSPError.unexpectedStatus(_, let code, _) {
                hasAnswered = true
                silentRounds = 0
                statistics.feedbackRefused += 1
                log.debug("feedback refusé (\(code)), sans conséquence")
            } catch RTSPError.timedOut {
                silentRounds += 1
                log.debug("feedback sans réponse (\(silentRounds) de suite)")
                if hasAnswered && silentRounds >= policy.silenceThreshold {
                    noteSessionLost(generation: generation, reason: "le récepteur ne répond plus")
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                noteSessionLost(
                    generation: generation,
                    reason: "keep-alive en échec : \(String(describing: error))"
                )
                return
            }
            try? await Task.sleep(for: policy.interval)
        }
    }

    /// Répond aux requêtes d'horloge du récepteur.
    ///
    /// Format identique à RAOP — RTCP type 0x52, 32 octets, estampille d'origine aux octets
    /// 24 à 31 — puisque le `SETUP` négocie `timingProtocol=NTP`. Deux différences avec RAOP :
    /// la réponse part vers **l'expéditeur** (le canal n'a pas de destination fixée à ce
    /// stade), et l'écoute commence avant le `SETUP`, dont la réponse en dépend.
    ///
    /// Contrairement à shairport-sync, qui envoie ses requêtes intégralement à zéro, le
    /// HomePod **horodate** les siennes : la mesure passive du décalage d'horloge y fonctionne.
    ///
    /// `timing` capturé faiblement : le canal détient cette fermeture, une référence forte en
    /// retour ferait un cycle qui ne libère jamais le socket. Il continuerait alors de répondre
    /// après l'arrêt, un descripteur de plus perdu à chaque reconnexion.
    private nonisolated func installTimingResponder(on timing: UDPChannel) {
        timing.onReceive = { [weak self, weak timing] data, source in
            guard let timing else { return }
            let receiveTime = NTPTime.now()
            guard data.count >= 32,
                data[data.startIndex + 1] & 0x7F == RTPPayloadType.timingRequest.rawValue
            else { return }
            let originStart = data.index(data.startIndex, offsetBy: 24)
            let origin = Array(data[originStart..<data.index(originStart, offsetBy: 8)])
            let response = RTPPacketBuilder.timingResponse(
                originTimestamp: origin,
                receiveTime: receiveTime,
                transmitTime: NTPTime.now()
            )
            try? timing.send(response, to: source)
            if let sender = self, let remote = NTPTime(bigEndianBytes: origin) {
                sender.synchronizer.timing.record(
                    remoteTransmitUnix: remote.unixTime,
                    localReceiveUnix: receiveTime.unixTime
                )
            }
        }
    }

    /// Observe le canal de contrôle et répond aux demandes de retransmission.
    ///
    /// La réponse part de cette file, vers l'expéditeur de la demande comme chez pyatv, sans
    /// repasser par l'acteur : une rafale de demandes ne retarde donc jamais le flux.
    private nonisolated func installControlObserver(on control: UDPChannel) {
        let retransmitter = self.retransmitter
        control.onReceive = { [weak self, weak control] data, source in
            guard let control, let request = RTPRetransmitRequest(datagram: data) else { return }
            let (responses, missing) = retransmitter.responses(for: request)
            var served = 0
            for response in responses where (try? control.send(response, to: source)) != nil {
                served += 1
            }
            Task { [served] in
                await self?.noteRetransmitRequest(served: served, missing: missing)
            }
        }
    }

    private func noteRetransmitRequest(served: Int, missing: Int) {
        statistics.retransmitRequests += 1
        statistics.retransmittedPackets += served
        statistics.retransmitMisses += missing
    }

    /// Vide le ring buffer sans rien émettre, pour repartir du direct.
    ///
    /// Lecture seule du point de vue du contenu : les échantillons sont recopiés dans le
    /// tampon propre au sender puis abandonnés ; le tampon partagé n'est jamais écrit.
    private func discardStaleAudio() {
        let channels = Int(captureFormat.channelCount)
        while ring.availableFrames > 0 {
            let frames = min(ring.availableFrames, readScratch.count / channels)
            guard frames > 0 else { break }
            let read = readScratch.withUnsafeMutableBufferPointer { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return ring.read(into: base, frameCount: frames)
            }
            if read == 0 { break }
        }
    }

    /// Extrait le PCM disponible du ring buffer et le convertit au format du flux.
    ///
    /// **Lecture seule sur le tampon partagé** : `read` recopie dans `readScratch`, propre
    /// au sender. Tout le traitement en aval opère sur cette copie (invariant section 12).
    private func drainRingBuffer() throws {
        guard let resampler else { return }
        let channels = Int(captureFormat.channelCount)
        while ring.availableFrames > 0 {
            let frames = min(ring.availableFrames, readScratch.count / channels)
            guard frames > 0 else { break }
            let converted = try readScratch.withUnsafeMutableBufferPointer {
                buffer -> [Int16] in
                guard let base = buffer.baseAddress else { return [] }
                let read = ring.read(into: base, frameCount: frames)
                guard read > 0 else { return [] }
                return try resampler.convert(base, frameCount: read)
            }
            guard !converted.isEmpty else { break }
            pendingSamples.append(contentsOf: converted)
            statistics.framesRead += frames
        }
    }

    /// Encode, chiffre et émet un paquet audio.
    ///
    /// Le chiffrement diffère de RAOP : ChaCha20-Poly1305 avec un nonce dérivé du numéro de
    /// paquet, et non AES-CBC.
    ///
    /// Trois détails de format, chacun suffisant à rendre le flux inaudible sans provoquer la
    /// moindre erreur — le récepteur accepte la session, reçoit les paquets, et ne joue rien
    /// (constaté contre un HomePod le 2026-08-11, corrigé d'après `pyatv/protocols/raop/
    /// protocols/airplayv2.py`) :
    ///
    /// 1. **La charge utile est du PCM brut**, pas de l'ALAC. C'est ce que déclare le `SETUP`
    ///    (`ct: 1`, `audioFormat` = PCM 44100/16/2), et déclarer un format puis en envoyer un
    ///    autre ne produit aucun message d'erreur. L'ordre est **big-endian**, comme le L16 de
    ///    RAOP : en little-endian le HomePod restitue un bruit blanc à pleine échelle — signe
    ///    que le déchiffrement, lui, réussit.
    /// 2. **Les données associées sont les octets 4 à 12 de l'en-tête RTP** (horodatage et
    ///    SSRC), pas l'en-tête entier.
    /// 3. **Le nonce de 8 octets est ajouté à la fin du paquet**, après l'étiquette : c'est
    ///    lui qui permet au récepteur de déchiffrer malgré un paquet perdu.
    private func sendNextPacket() throws {
        guard let cipher = streamCipher, let audio = audioChannel else { return }
        let channels = Self.streamChannelCount
        let sampleCount = Self.framesPerPacket * channels

        // Correction de dérive (CDC 4.5, technique Snapcast), appliquée exactement comme
        // côté RAOP : le paquet émis fait toujours 352 trames, seule la position du flux se
        // décale d'une trame. La manipulation porte sur `pendingSamples`, copie propre au
        // sender ; le tampon partagé n'est jamais touché (invariant section 12).
        let correction = synchronizer.observe(pipelineDelayOutputFrames: pipelineDelayOutputFrames)
        var consumedFrames = Self.framesPerPacket
        let block: [Int16]
        switch correction {
        case .none:
            block = Array(pendingSamples[0..<sampleCount])
        case .removeFrame:
            consumedFrames = Self.framesPerPacket + 1
            block = SampleSplice.removingOneFrame(
                from: Array(pendingSamples[0..<(sampleCount + channels)]),
                channelCount: channels
            )
            statistics.framesRemoved += 1
        case .insertFrame:
            consumedFrames = Self.framesPerPacket - 1
            block = SampleSplice.insertingOneFrame(
                into: Array(pendingSamples[0..<(sampleCount - channels)]),
                channelCount: channels
            )
            statistics.framesInserted += 1
        }
        // L'ancrage décrit le paquet qu'on émet : le calculer avant d'avancer la position.
        let anchor = synchronizer.syncAnchorUnixTime(latencyFrames: Self.latencyFrames)
        pendingSamples.removeFirst(consumedFrames * channels)
        synchronizer.didConsume(outputFrames: consumedFrames)

        var payload = Data(capacity: block.count * 2)
        for sample in block {
            let bits = UInt16(bitPattern: sample)
            payload.append(UInt8(truncatingIfNeeded: bits >> 8))
            payload.append(UInt8(truncatingIfNeeded: bits))
        }

        // Le bit marker signale le premier paquet du flux : le récepteur y réinitialise
        // ses tampons. Compteur de session, pas compteur global : après une reconnexion le
        // récepteur doit repartir sur des tampons neufs.
        let header = RTPPacketBuilder.audioHeader(
            sequenceNumber: sequenceNumber,
            timestamp: rtpTimestamp,
            ssrc: ssrc,
            marker: packetsInSession == 0
        )
        // Nonce : 4 octets nuls puis le compteur de paquets sur 64 bits little-endian.
        // Il ne se répète jamais tant que la session vit, condition de sûreté de l'AEAD.
        var nonce = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: UInt64(packetsSent).littleEndian) { nonce.append(contentsOf: $0) }

        let associated = header.subdata(in: 4..<12)
        let sealed = try cipher.seal(payload, nonce: nonce, additionalData: associated)
        let packet = header + sealed + nonce.suffix(8)

        // Retenu tel quel pour une éventuelle retransmission, y compris si l'émission échoue : ce
        // paquet est alors une perte comme une autre, que le récepteur réclamera. Son nonce le
        // suit, il reste déchiffrable sans rien recalculer.
        retransmitter.record(sequence: sequenceNumber, packet: packet)
        let emission = Result { try audio.send(packet) }

        if packetsInSession % Self.syncInterval == 0 {
            sendSync(isFirst: packetsInSession == 0, anchorUnixTime: anchor)
        }

        // Les compteurs avancent même en cas d'échec. Les échantillons sont déjà consommés et le
        // synchroniseur en a tenu compte : ne pas avancer l'horodatage décalerait tout le flux de
        // 8 ms par paquet raté, et réutiliser le nonce sur un autre contenu casserait l'AEAD.
        sequenceNumber &+= 1
        rtpTimestamp &+= UInt32(Self.framesPerPacket)
        packetsSent += 1
        packetsInSession += 1
        statistics.packetsSent = packetsSent
        try emission.get()
    }

    /// Annonce de synchronisation NTP sur le canal de contrôle.
    ///
    /// **C'est ici que se fait l'alignement automatique de cette sortie** (CDC 4.5), au même
    /// endroit et par le même mécanisme qu'en RAOP : l'instant annoncé sort de l'horloge de
    /// restitution commune, pas de « maintenant ». Deux sorties qui la partagent annoncent le
    /// même instant pour la même trame captée.
    ///
    /// Le format est celui de RAOP (`TIME_ANNOUNCE_NTP`, type 0x54) : le `SETUP` ayant
    /// négocié `timingProtocol=NTP`, c'est bien ce que le récepteur attend. Les erreurs sont
    /// journalisées sans être propagées : perdre une annonce dégrade le calage, perdre le
    /// flux audio l'interromprait.
    private func sendSync(isFirst: Bool, anchorUnixTime: TimeInterval?) {
        guard let control = controlChannel else { return }
        let ntp = anchorUnixTime.map { NTPTime(unixTime: $0) } ?? NTPTime.now()
        let packet = RTPPacketBuilder.sync(
            rtpTimestamp: rtpTimestamp,
            latencyFrames: Self.latencyFrames,
            ntp: ntp,
            isFirst: isFirst
        )
        do {
            try control.send(packet)
            statistics.syncPacketsSent += 1
            if anchorUnixTime != nil { statistics.anchoredSyncPackets += 1 }
        } catch {
            log.error(
                "Annonce de synchro AirPlay 2 en échec : \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Délai de pipeline courant, en trames de sortie : audio capté mais pas encore émis.
    private var pipelineDelayOutputFrames: Double {
        let ratio = Double(Self.streamSampleRate) / captureFormat.sampleRate
        let ringFrames = Double(ring.availableFrames) * ratio
        let pendingFrames = Double(pendingSamples.count / Self.streamChannelCount)
        return ringFrames + pendingFrames
    }

    /// Ferme les ressources réseau. Idempotent : appelable après un échec partiel.
    private func teardown() async {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        audioChannel?.stop()
        audioChannel = nil
        controlChannel?.stop()
        controlChannel = nil
        timingChannel?.stop()
        timingChannel = nil
        eventChannel?.close()
        eventChannel = nil
        retransmitter.reset()
        await rtsp?.disconnect()
        rtsp = nil
        session = nil
        resampler = nil
        streamCipher = nil
    }
}

/// Statistiques de diffusion, exposées pour la validation du jalon.
public struct AirPlay2Statistics: Sendable {
    public var packetsSent = 0
    public var framesRead = 0
    public var errors = 0
    public var resyncs = 0
    /// Trames refusées par le ring buffer **avant** le premier paquet émis.
    ///
    /// Distinguer les deux régimes est indispensable : la quasi-totalité des refus vient de
    /// la fenêtre de négociation, pendant laquelle la capture tourne sans consommateur. Seul
    /// l'écart mesuré ensuite signale un vrai sous-dimensionnement du tampon.
    public var droppedBeforeStreaming = 0
    /// Annonces de synchronisation NTP émises sur le canal de contrôle (jalon 4), dont
    /// celles portant un ancrage issu de l'horloge commune.
    public var syncPacketsSent = 0
    public var anchoredSyncPackets = 0
    /// Corrections de dérive appliquées (technique Snapcast, CDC 4.5).
    public var framesInserted = 0
    public var framesRemoved = 0
    /// Demandes de retransmission reçues du récepteur : indicateur de pertes de paquets.
    public var retransmitRequests = 0
    /// Paquets renvoyés en réponse, et paquets demandés qu'on n'avait plus.
    public var retransmittedPackets = 0
    public var retransmitMisses = 0
    /// `POST /feedback` acceptés et refusés par le récepteur.
    public var feedbackSent = 0
    public var feedbackRefused = 0
    /// Requêtes du récepteur reçues sur le canal d'événements, déchiffrées et acquittées.
    public var eventMessages = 0
    /// Dernier échec, sous sa forme affichable. Survit à une reconnexion réussie : il dit ce qui
    /// s'est passé, pas l'état courant, que porte `AirPlay2Sender.state`.
    public var lastFailure: String?
    /// Valeur brute d'`audioBufferSize` annoncée par le récepteur, unité non établie.
    public var receiverBufferSize = 0
    /// Canal d'événements effectivement ouvert.
    public var eventChannelConnected = false
    /// Sessions rétablies après une perte réseau, et tentatives infructueuses (CDC section 8).
    public var reconnections = 0
    public var reconnectionAttempts = 0

    public init() {}
}
