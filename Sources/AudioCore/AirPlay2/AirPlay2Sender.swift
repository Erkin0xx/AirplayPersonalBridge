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
/// négociation, RTP pour le transport, ALAC pour l'encodage.
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
/// `SET_PARAMETER` (volume) → `RECORD` → paquets RTP → `TEARDOWN`.
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
    /// Erreurs d'émission consécutives au-delà desquelles la session est réputée perdue.
    private static let lostSessionErrorThreshold = 20

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
    public func start(volume: Float = -20) async throws {
        guard state == .idle else { return }
        state = .connecting
        currentVolume = volume

        do {
            try await negotiate(volume: volume)
        } catch {
            state = .failed
            log.error(
                "Établissement de la session AirPlay 2 en échec : \(String(describing: error), privacy: .public)"
            )
            await teardown()
            throw error
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
        sessionLost = false
        synchronizer.beginStreaming(atCaptureFrame: ring.totalFramesRead)
    }

    /// Surveille la diffusion et rétablit la session après une perte réseau (CDC section 8).
    ///
    /// Isolée par construction : ni la capture, ni le ring buffer, ni l'autre sortie ne sont
    /// touchés — cette dernière n'a d'ailleurs aucun moyen de savoir que celle-ci a décroché
    /// (invariant section 12). La reconnexion refait **tout** le chemin, pair-setup compris :
    /// les clés de session et le chiffrement du canal ne survivent pas à une coupure.
    private func supervise() async {
        while !Task.isCancelled {
            await streamLoop()
            guard !Task.isCancelled, sessionLost, reconnects else { break }

            state = .reconnecting
            statistics.reconnections += 1
            log.error("Session AirPlay 2 perdue — tentative de rétablissement")
            await teardown()

            var backoff: Duration = .seconds(1)
            var reconnected = false
            while !Task.isCancelled && !reconnected {
                do {
                    try await Task.sleep(for: backoff)
                    try await negotiate(volume: currentVolume)
                    reconnected = true
                } catch is CancellationError {
                    return
                } catch {
                    statistics.reconnectionAttempts += 1
                    log.error(
                        "Reconnexion AirPlay 2 en échec : \(String(describing: error), privacy: .public)"
                    )
                    await teardown()
                    backoff = min(backoff * 2, .seconds(15))
                }
            }
            guard reconnected, !Task.isCancelled else { break }
            beginStreaming(firstSession: false)
            state = .streaming
            log.info("Session AirPlay 2 rétablie")
        }
    }

    /// Arrête la diffusion et libère la session.
    public func stop() async {
        streamTask?.cancel()
        streamTask = nil
        if state == .streaming || state == .reconnecting, let session {
            await session.teardown()
        }
        await teardown()
        state = .idle
        log.info("Diffusion AirPlay 2 arrêtée (\(self.packetsSent) paquets émis)")
    }

    /// Règle le volume en cours de session.
    public func setVolume(_ volume: Float) async throws {
        guard let session else { return }
        try await session.setVolume(volume)
    }

    // MARK: - Négociation

    private func negotiate(volume: Float) async throws {
        let client = RTSPClient(host: device.host, port: device.port)
        rtsp = client
        try await client.connect()

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

        // Canal d'événements : récupéré dès le jalon 3, exploité seulement ici. Il sert de
        // signal de vie — le canal audio étant en UDP, rien d'autre ne signale un récepteur
        // disparu. Son indisponibilité n'empêche pas de diffuser.
        if endpoints.eventPort != 0 {
            let events = AirPlay2EventChannel(host: device.host, port: endpoints.eventPort)
            let connected = await events.connect { [weak self] in
                Task { await self?.noteEventChannelLost() }
            }
            eventChannel = events
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

    /// La rupture du canal d'événements vaut perte de session.
    ///
    /// C'est le seul signal franc dont dispose AirPlay 2 : le flux audio étant en UDP, un
    /// récepteur disparu ne provoque aucune erreur d'émission — les datagrammes partiraient
    /// indéfiniment dans le vide.
    private func noteEventChannelLost() {
        guard state == .streaming else { return }
        log.error("Canal d'événements rompu — session réputée perdue")
        sessionLost = true
    }

    /// Observe le canal de contrôle : demandes de retransmission du récepteur.
    ///
    /// La retransmission elle-même n'est pas implémentée (hors périmètre du jalon) ; les
    /// demandes sont comptées, car leur apparition est le premier signe d'un flux qui perd
    /// des paquets — donc d'un problème de cadencement ou de réseau.
    /// Répond aux requêtes d'horloge du récepteur.
    ///
    /// Format identique à RAOP — RTCP type 0x52, 32 octets, estampille d'origine aux octets
    /// 24 à 31 — puisque le `SETUP` négocie `timingProtocol=NTP`. Deux différences avec RAOP :
    /// la réponse part vers **l'expéditeur** (le canal n'a pas de destination fixée à ce
    /// stade), et l'écoute commence avant le `SETUP`, dont la réponse en dépend.
    ///
    /// Contrairement à shairport-sync, qui envoie ses requêtes intégralement à zéro, le
    /// HomePod **horodate** les siennes : la mesure passive du décalage d'horloge y fonctionne.
    private nonisolated func installTimingResponder(on timing: UDPChannel) {
        timing.onReceive = { [weak self] data, source in
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

    private nonisolated func installControlObserver(on control: UDPChannel) {
        control.onReceive = { [weak self] data, _ in
            guard data.count >= 2,
                  data[data.startIndex + 1] & 0x7F == RTPPayloadType.retransmitRequest.rawValue
            else { return }
            Task { await self?.countRetransmitRequest() }
        }
    }

    private func countRetransmitRequest() {
        statistics.retransmitRequests += 1
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
    /// 1. **La charge utile est du PCM brut little-endian**, pas de l'ALAC. C'est ce que
    ///    déclare le `SETUP` (`ct: 1`, `audioFormat` = PCM 44100/16/2), et déclarer un format
    ///    puis en envoyer un autre ne produit aucun message d'erreur. L'ordre est
    ///    **big-endian**, comme le L16 de RAOP : en little-endian le HomePod restitue un
    ///    bruit blanc à pleine échelle — signe que le déchiffrement, lui, réussit.
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
        try audio.send(header + sealed + nonce.suffix(8))

        if packetsInSession % Self.syncInterval == 0 {
            sendSync(isFirst: packetsInSession == 0, anchorUnixTime: anchor)
        }

        sequenceNumber &+= 1
        rtpTimestamp &+= UInt32(Self.framesPerPacket)
        packetsSent += 1
        packetsInSession += 1
        statistics.packetsSent = packetsSent
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
        audioChannel?.stop()
        audioChannel = nil
        controlChannel?.stop()
        controlChannel = nil
        eventChannel?.close()
        eventChannel = nil
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
    /// Valeur brute d'`audioBufferSize` annoncée par le récepteur, unité non établie.
    public var receiverBufferSize = 0
    /// Canal d'événements effectivement ouvert.
    public var eventChannelConnected = false
    /// Sessions rétablies après une perte réseau, et tentatives infructueuses (CDC section 8).
    public var reconnections = 0
    public var reconnectionAttempts = 0

    public init() {}
}
