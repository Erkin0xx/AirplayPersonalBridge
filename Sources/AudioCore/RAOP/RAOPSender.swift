import AVFoundation
import Foundation
import OSLog

/// État observable d'un sender RAOP.
public enum RAOPSenderState: String, Sendable {
    case idle
    case connecting
    case streaming
    /// Session perdue, rétablissement en cours (CDC section 8). La capture et l'autre sortie
    /// ne sont pas touchées : c'est tout l'intérêt d'un état distinct de `failed`.
    case reconnecting
    case failed
}

/// Sender AirPlay 1 / RAOP (CDC 4.3) : RTSP pour la négociation, RTP pour le transport,
/// ALAC pour l'encodage.
///
/// ## Position dans l'architecture (invariants section 12)
///
/// - Il **lit** un `AudioRingBuffer` alimenté par la capture et ne l'écrit jamais. Le PCM
///   extrait est copié dans un tampon propre au sender avant toute transformation
///   (conversion de fréquence, encodage, chiffrement) : le tampon partagé n'est jamais
///   modifié.
/// - Il **ignore tout de la source de capture** : il ne reçoit qu'un ring buffer et un
///   format. Symétriquement, la capture ignore tout de lui.
/// - Il **ignore l'existence de tout autre sender**. Une panne ici n'affecte aucune autre
///   sortie, et la boucle de diffusion se termine sans jamais toucher à la capture.
///
/// ## Séquence protocolaire
///
/// `ANNOUNCE` (SDP : format ALAC, clé AES chiffrée, IV) → `SETUP` (ports UDP) →
/// `RECORD` (départ du flux) → `SET_PARAMETER` (volume) → paquets RTP → `TEARDOWN`.
public actor RAOPSender {
    /// Trames par paquet, valeur canonique du protocole.
    private static let framesPerPacket = ALACEncoder.framesPerPacket
    /// Latence annoncée au récepteur, en trames à 44,1 kHz — soit ~2 s. C'est la valeur
    /// qu'utilisent les senders Apple et que shairport-sync attend par défaut.
    private static let latencyFrames: UInt32 = 88_200
    /// Période des annonces de synchro sur le canal de contrôle, en paquets audio.
    /// 126 paquets ≈ 1 s à 44,1 kHz, cadence usuelle des senders RAOP.
    private static let syncInterval = 126
    /// Erreurs d'émission consécutives au-delà desquelles la session est réputée perdue.
    /// 50 paquets ≈ 0,4 s : assez pour ne pas réagir à un à-coup, assez peu pour rétablir
    /// avant que le tampon du récepteur ne se vide.
    private static let lostSessionErrorThreshold = 20
    /// Silence du canal de timing au-delà duquel un avertissement est journalisé.
    ///
    /// **Volontairement pas un critère de perte de session.** shairport-sync 5.2.1 interroge
    /// l'horloge densément pendant la trentaine de secondes qui suit le `RECORD`, puis se tait
    /// complètement alors que la session se porte très bien (mesuré au jalon 4 : 14 requêtes
    /// en tout sur une session de 60 s, aucune après la 35ᵉ seconde). En faire une condition
    /// de perte déclenchait une reconnexion sur une session saine — un défaut bien pire que
    /// celui qu'il prétendait détecter. Le critère franc est la rupture de la connexion RTSP.
    private static let timingSilenceWarning: TimeInterval = 120

    public private(set) var state: RAOPSenderState = .idle

    private let device: RAOPDevice
    private let ring: AudioRingBuffer
    private let captureFormat: AVAudioFormat
    /// Alignement, réglage manuel et correction de dérive de **cette** sortie (CDC 4.5).
    /// Injecté : c'est par lui que la sortie partage l'horloge de restitution commune, sans
    /// jamais connaître l'autre sortie (invariant section 12).
    public nonisolated let synchronizer: OutputSynchronizer
    private let log = AudioLog.raop

    private var rtsp: RTSPClient?
    private var crypto: RAOPCrypto?
    private var encoder: ALACEncoder?
    private var resampler: RAOPResampler?

    private var audioChannel: UDPChannel?
    private var controlChannel: UDPChannel?
    private var timingChannel: UDPChannel?

    private let ssrc: UInt32 = UInt32.random(in: .min ... .max)
    private var sequenceNumber = UInt16.random(in: 0...UInt16.max / 2)
    private var rtpTimestamp: UInt32 = UInt32.random(in: 0...UInt32.max / 2)
    private var packetsSent = 0
    /// Paquets émis **depuis le début de la session courante**. Distinct de `packetsSent`,
    /// qui survit aux reconnexions : c'est lui qui décide du bit marker et de la toute
    /// première annonce de synchro, deux choses qui doivent repartir à zéro à chaque session.
    private var packetsInSession = 0
    private var streamTask: Task<Void, Never>?
    /// Volume courant, à réappliquer après une reconnexion.
    private var currentVolume: Float = -20
    /// Rétablissement automatique après perte réseau (CDC section 8). Désactivable pour les
    /// tests, qui ne doivent pas voir un sender ressusciter une session volontairement close.
    private let reconnects: Bool
    /// Vrai quand la boucle de diffusion a conclu à une perte de session.
    private var sessionLost = false
    private var consecutiveSendErrors = 0
    /// Instant de la dernière requête d'horloge reçue, s'il y en a eu une.
    private var lastTimingRequestUnix: TimeInterval?
    /// Évite de répéter l'avertissement de silence du canal de timing à chaque tour.
    private var timingSilenceReported = false

    /// URI de session, construite à l'`ANNOUNCE` et réutilisée par toutes les requêtes
    /// suivantes.
    ///
    /// Le `SET_PARAMETER` et le `TEARDOWN` doivent porter **cette même URI**, pas une URI
    /// reconstruite : le récepteur y identifie la session. shairport-sync tolère un écart,
    /// mais les récepteurs matériels rejettent couramment un TEARDOWN dont l'URI ne
    /// correspond à aucune session ouverte — et la session reste alors bloquée côté
    /// récepteur, ce qui empêche toute reconnexion jusqu'à expiration de son délai.
    private var sessionURI: String?

    /// Échantillons convertis en attente de constituer un paquet complet de 352 trames.
    /// Propre au sender : cette copie est ce sur quoi tout le traitement opère, jamais le
    /// tampon partagé.
    private var pendingSamples: [Int16] = []
    /// Tampon de lecture du ring buffer, alloué une fois.
    private var readScratch: [Float]

    /// Statistiques exposées pour la validation du jalon.
    public private(set) var statistics = RAOPStatistics()

    /// - Parameters:
    ///   - device: le récepteur, tel que la découverte Bonjour l'a résolu.
    ///   - ring: le ring buffer **propre à cette sortie** (invariant section 12).
    ///   - captureFormat: format livré par la capture.
    ///   - clock: horloge de restitution commune (CDC 4.5). Par défaut une horloge propre à
    ///     ce sender, ce qui laisse le comportement du jalon 2 inchangé quand une seule
    ///     sortie diffuse ; l'alignement inter-sorties suppose de passer **la même** aux deux.
    ///   - reconnects: rétablissement automatique de la session après perte réseau.
    public init(
        device: RAOPDevice,
        ring: AudioRingBuffer,
        captureFormat: AVAudioFormat,
        clock: PlaybackClockProtocol? = nil,
        reconnects: Bool = true
    ) {
        self.device = device
        self.ring = ring
        self.captureFormat = captureFormat
        self.reconnects = reconnects
        let effectiveClock =
            clock ?? SharedPlaybackClock(captureSampleRate: captureFormat.sampleRate)
        (effectiveClock as? SharedPlaybackClock)?.startIfNeeded()
        self.synchronizer = OutputSynchronizer(
            label: "RAOP/\(device.displayName)",
            clock: effectiveClock,
            outputSampleRate: Double(device.sampleRate)
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

    /// Établit la session RTSP et démarre la diffusion.
    public func start(volume: Float = -20) async throws {
        guard state == .idle else { return }
        state = .connecting
        currentVolume = volume

        do {
            try await negotiate(volume: volume)
        } catch {
            state = .failed
            log.error("Établissement de la session RAOP en échec : \(String(describing: error), privacy: .public)")
            await teardown()
            throw error
        }

        beginStreaming(firstSession: true)
        state = .streaming
        streamTask = Task { [weak self] in
            await self?.supervise()
        }
        log.info("Diffusion RAOP démarrée vers \(self.device.displayName, privacy: .public)")
    }

    /// Prépare le début (ou la reprise) de la diffusion.
    private func beginStreaming(firstSession: Bool) {
        // La capture tourne déjà pendant la découverte Bonjour et la négociation RTSP
        // (plusieurs secondes) : le ring buffer contient donc un arriéré d'audio périmé, et
        // a même déjà débordé. Le jeter ici évite de commencer la diffusion avec plusieurs
        // secondes de retard sur le direct. Après une reconnexion, la raison est la même :
        // l'audio accumulé pendant la coupure n'a plus lieu d'être joué.
        //
        // C'est une lecture, pas une écriture : l'invariant section 12 (le sender ne modifie
        // jamais le tampon partagé) reste respecté — avancer l'index de lecture est le rôle
        // normal du consommateur.
        let staleFrames = ring.availableFrames
        if staleFrames > 0 {
            discardStaleAudio()
            log.info("Arriéré de \(staleFrames) trames écarté avant le début de la diffusion")
        }
        pendingSamples.removeAll(keepingCapacity: true)
        if firstSession {
            // Photographie du compteur de refus au moment précis où la diffusion démarre.
            // Tout ce qui précède est imputable à la négociation (découverte Bonjour +
            // RTSP), pendant laquelle la capture tourne sans consommateur ; seul l'écart
            // mesuré ensuite signale un vrai sous-dimensionnement du tampon en régime établi.
            statistics.droppedBeforeStreaming = ring.droppedFrames
        }
        packetsInSession = 0
        consecutiveSendErrors = 0
        sessionLost = false
        lastTimingRequestUnix = nil
        timingSilenceReported = false
        // Ancre le flux sur l'horloge de capture commune aux deux sorties.
        synchronizer.beginStreaming(atCaptureFrame: ring.totalFramesRead)
    }

    /// Surveille la diffusion et rétablit la session après une perte réseau (CDC section 8).
    ///
    /// La reconnexion est **isolée** : elle ne touche ni la capture, ni le ring buffer, ni
    /// l'autre sortie, qui n'a aucun moyen de savoir que celle-ci a décroché (invariant
    /// section 12). Le repli exponentiel évite de marteler un récepteur absent.
    private func supervise() async {
        while !Task.isCancelled {
            await streamLoop()
            guard !Task.isCancelled, sessionLost, reconnects else { break }

            state = .reconnecting
            statistics.reconnections += 1
            log.error("Session RAOP perdue — tentative de rétablissement")
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
                        "Reconnexion RAOP en échec : \(String(describing: error), privacy: .public)"
                    )
                    await teardown()
                    backoff = min(backoff * 2, .seconds(15))
                }
            }
            guard reconnected, !Task.isCancelled else { break }
            beginStreaming(firstSession: false)
            state = .streaming
            log.info("Session RAOP rétablie")
        }
    }

    /// Arrête la diffusion et libère la session.
    public func stop() async {
        streamTask?.cancel()
        streamTask = nil
        if state == .streaming || state == .reconnecting {
            try? await sendTeardown()
        }
        await teardown()
        state = .idle
        log.info("Diffusion RAOP arrêtée (\(self.packetsSent) paquets émis)")
    }

    private func negotiate(volume: Float) async throws {
        guard device.supportsALAC else { throw RAOPSenderError.alacUnsupported(device.serviceName) }
        guard device.supportsRSAEncryption else {
            throw RAOPSenderError.encryptionUnsupported(device.serviceName)
        }

        let crypto = try RAOPCrypto()
        self.crypto = crypto
        self.encoder = ALACEncoder(
            framesPerPacket: Self.framesPerPacket, channelCount: device.channelCount
        )
        self.resampler = try RAOPResampler(
            inputFormat: captureFormat,
            outputSampleRate: Double(device.sampleRate),
            channelCount: AVAudioChannelCount(device.channelCount)
        )

        let client = RTSPClient(host: device.host, port: device.port)
        try await client.connect()
        self.rtsp = client

        // Les ports locaux doivent exister avant le SETUP : ils y sont annoncés.
        let control = try UDPChannel(label: "control")
        let timing = try UDPChannel(label: "timing")
        let audio = try UDPChannel(label: "audio")
        self.controlChannel = control
        self.timingChannel = timing
        self.audioChannel = audio

        let sessionID = UInt32.random(in: 1...UInt32.max)
        let uri = "rtsp://\(await client.localAddress)/\(sessionID)"
        sessionURI = uri

        try await announce(client: client, uri: uri, crypto: crypto, sessionID: sessionID)
        let ports = try await setup(client: client, uri: uri, control: control, timing: timing)
        try audio.setDestination(host: device.host, port: ports.audio)
        try control.setDestination(host: device.host, port: ports.control)
        try timing.setDestination(host: device.host, port: ports.timing)

        installTimingResponder(on: timing)
        control.startReceiving()
        timing.startReceiving()

        try await record(client: client, uri: uri)
        try await setVolume(volume, client: client, uri: uri)

        // Signal franc de perte de session, posé une fois la négociation terminée : le flux
        // audio étant en UDP, la rupture de cette connexion TCP est la seule indication
        // fiable qu'un récepteur a disparu (CDC section 8).
        await client.onConnectionLost { [weak self] in
            Task { await self?.noteControlConnectionLost() }
        }
    }

    /// `ANNOUNCE` : décrit le flux en SDP, clé AES chiffrée comprise.
    private func announce(
        client: RTSPClient, uri: String, crypto: RAOPCrypto, sessionID: UInt32
    ) async throws {
        let encryptedKey = RAOPCrypto.base64Unpadded(try crypto.encryptedSessionKey())
        let iv = RAOPCrypto.base64Unpadded(crypto.aesIV)
        let localAddress = await client.localAddress

        // Les paramètres `fmtp` sont ceux du décodeur ALAC, dans l'ordre imposé par le
        // protocole : frameLength, compatibleVersion, bitDepth, pb, mb, kb, channels,
        // maxRun, maxFrameBytes, avgBitRate, sampleRate.
        let fmtp = [
            "\(Self.framesPerPacket)", "0", "\(device.bitDepth)", "40", "10", "14",
            "\(device.channelCount)", "255", "0", "0", "\(device.sampleRate)",
        ].joined(separator: " ")

        let sdp = """
            v=0\r
            o=iTunes \(sessionID) 0 IN IP4 \(localAddress)\r
            s=iTunes\r
            c=IN IP4 \(device.host)\r
            t=0 0\r
            m=audio 0 RTP/AVP 96\r
            a=rtpmap:96 AppleLossless\r
            a=fmtp:96 \(fmtp)\r
            a=rsaaeskey:\(encryptedKey)\r
            a=aesiv:\(iv)\r

            """

        try await client.send(RTSPRequest(
            method: "ANNOUNCE",
            uri: uri,
            headers: [("Content-Type", "application/sdp")],
            body: Data(sdp.utf8)
        ))
    }

    /// `SETUP` : annonce les ports locaux, récupère ceux du récepteur.
    private func setup(
        client: RTSPClient, uri: String, control: UDPChannel, timing: UDPChannel
    ) async throws -> RTPPorts {
        let transport = [
            "RTP/AVP/UDP", "unicast", "interleaved=0-1", "mode=record",
            "control_port=\(control.localPort)", "timing_port=\(timing.localPort)",
        ].joined(separator: ";")

        let response = try await client.send(RTSPRequest(
            method: "SETUP", uri: uri, headers: [("Transport", transport)]
        ))

        // PIÈGE : ce sont les ports **de la réponse** qui font foi, jamais ceux demandés.
        let parameters = response.transportParameters
        guard let serverPort = parameters["server_port"].flatMap({ UInt16($0) }) else {
            throw RTSPError.missingHeader("Transport/server_port")
        }
        let controlPort = parameters["control_port"].flatMap { UInt16($0) } ?? serverPort
        let timingPort = parameters["timing_port"].flatMap { UInt16($0) } ?? serverPort

        log.info("Ports du récepteur — audio \(serverPort), control \(controlPort), timing \(timingPort)")
        return RTPPorts(audio: serverPort, control: controlPort, timing: timingPort)
    }

    /// `RECORD` : démarre le flux. `RTP-Info` porte la séquence et l'estampille de départ.
    private func record(client: RTSPClient, uri: String) async throws {
        let response = try await client.send(RTSPRequest(
            method: "RECORD",
            uri: uri,
            headers: [
                ("Range", "npt=0-"),
                ("RTP-Info", "seq=\(sequenceNumber);rtptime=\(rtpTimestamp)"),
            ]
        ))
        // Latence annoncée par le récepteur : sa profondeur de tampon interne, en trames.
        // C'est précisément la grandeur qu'une mesure de trajet réseau ne verrait pas (CDC
        // 4.5) — elle vaut ici des centaines de millisecondes là où un aller-retour sur un
        // réseau local se compte en dizaines de microsecondes.
        if let audioLatency = response.headers["audio-latency"] {
            log.info("Latence annoncée par le récepteur : \(audioLatency, privacy: .public) trames")
            let frames = Int(audioLatency) ?? 0
            statistics.reportedLatencyFrames = frames
            synchronizer.declaredReceiverLatencyFrames = frames
        }
    }

    /// `SET_PARAMETER` : volume, en dB. RAOP attend −144 (silence) ou −30…0.
    public func setVolume(_ volume: Float) async throws {
        guard let client = rtsp, let uri = sessionURI else { throw RTSPError.notConnected }
        try await setVolume(volume, client: client, uri: uri)
    }

    private func setVolume(_ volume: Float, client: RTSPClient, uri: String) async throws {
        let clamped = volume <= -144 ? -144 : min(max(volume, -30), 0)
        let body = "volume: \(String(format: "%.6f", clamped))\r\n"
        try await client.send(RTSPRequest(
            method: "SET_PARAMETER",
            uri: uri,
            headers: [("Content-Type", "text/parameters")],
            body: Data(body.utf8)
        ))
        statistics.volume = clamped
    }

    private func sendTeardown() async throws {
        guard let client = rtsp, let uri = sessionURI else { return }
        // Délai court : beaucoup de récepteurs ferment la connexion dès le TEARDOWN reçu,
        // sans jamais répondre — c'est le cas du mock shairport-sync, qui quitte. Attendre
        // les 10 s par défaut retarderait l'arrêt sans rien apporter : à ce stade la
        // diffusion est terminée et la réponse n'est plus exploitable.
        try await client.send(RTSPRequest(method: "TEARDOWN", uri: uri), timeout: .seconds(2))
    }

    // MARK: - Diffusion

    /// Boucle de diffusion : draine le ring buffer, convertit, encode, chiffre, émet.
    ///
    /// Hors temps réel (tâche propre au sender), donc Swift Concurrency est ici légitime
    /// (CDC 4.5 et section 13). Le rythme est donné par l'horloge : un paquet représente
    /// 352 trames, soit ~7,98 ms à 44,1 kHz.
    private func streamLoop() async {
        let packetDuration = Duration.seconds(
            Double(Self.framesPerPacket) / Double(device.sampleRate)
        )
        // Échéance du **prochain** paquet. Chaque paquet émis la décale d'exactement une
        // durée de paquet : le rythme reste accroché à l'horloge et ne dérive pas, même si
        // un tour de boucle prend plus longtemps que prévu.
        var nextDeadline = ContinuousClock.now

        while !Task.isCancelled && !sessionLost {
            do {
                try drainRingBuffer()
            } catch {
                log.error("Erreur de lecture du flux RAOP : \(String(describing: error), privacy: .public)")
                statistics.errors += 1
                // Invariant section 12 : l'échec reste confiné à ce sender. Il n'interrompt
                // ni la capture, ni aucune autre sortie ; la boucle continue et retentera.
            }

            // Une correction de dérive peut demander une trame de plus que le paquet.
            let channels = device.channelCount
            let neededSamples = (Self.framesPerPacket + 1) * channels

            // Un seul paquet par tour, à l'échéance : un flux RTP doit arriver au rythme
            // de lecture, pas en rafales. Émettre d'un coup tout le retard accumulé ferait
            // déborder le tampon du récepteur — et c'est ce que faisait une première
            // version, mesurée à un intervalle médian de 0,7 ms pour 7,98 ms théoriques.
            guard pendingSamples.count >= neededSamples else {
                // Pas encore assez d'audio : attendre un fragment de durée de paquet plutôt
                // que de tourner à vide.
                try? await Task.sleep(for: .milliseconds(2))
                checkLiveness()
                continue
            }

            let now = ContinuousClock.now
            if nextDeadline > now {
                try? await Task.sleep(until: nextDeadline, clock: .continuous)
            } else if now - nextDeadline > .seconds(1) {
                // Retard irrattrapable (récepteur ou réseau bloqué) : repartir de l'instant
                // courant plutôt que d'émettre une rafale de rattrapage.
                nextDeadline = now
                statistics.resyncs += 1
            }

            do {
                try sendNextPacket()
                consecutiveSendErrors = 0
                nextDeadline += packetDuration
            } catch {
                log.error("Erreur d'émission RAOP : \(String(describing: error), privacy: .public)")
                statistics.errors += 1
                consecutiveSendErrors += 1
                nextDeadline += packetDuration
            }
            checkLiveness()
        }
    }

    /// Décide si la session est perdue.
    ///
    /// Deux signaux seulement font foi : les erreurs d'émission répétées, et la rupture de la
    /// connexion RTSP (posée par ``RTSPClient/onConnectionLost(_:)``). Le silence du canal de
    /// timing, lui, est **seulement journalisé** : voir ``timingSilenceWarning``.
    private func checkLiveness() {
        guard !sessionLost else { return }
        if consecutiveSendErrors >= Self.lostSessionErrorThreshold {
            log.error("\(self.consecutiveSendErrors) erreurs d'émission consécutives")
            sessionLost = true
            return
        }
        if let last = lastTimingRequestUnix, !timingSilenceReported,
           Date().timeIntervalSince1970 - last > Self.timingSilenceWarning {
            timingSilenceReported = true
            log.info(
                "Canal de timing silencieux depuis plus de \(Self.timingSilenceWarning) s — normal avec shairport-sync"
            )
        }
    }

    /// La connexion RTSP est tombée : c'est le signal franc de perte de session.
    private func noteControlConnectionLost() {
        guard state == .streaming else { return }
        log.error("Connexion RTSP rompue — session réputée perdue")
        sessionLost = true
    }

    /// Vide le ring buffer sans rien émettre, pour repartir du direct.
    ///
    /// Lecture seule du point de vue du contenu : les échantillons sont recopiés dans le
    /// tampon propre au sender puis abandonnés, le tampon partagé n'est jamais écrit.
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

    /// Extrait le PCM disponible du ring buffer et le convertit au format RAOP.
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

    /// Délai de pipeline courant, en trames de sortie : audio capté mais pas encore émis.
    ///
    /// Somme de l'arriéré du ring buffer (à la fréquence de capture, converti) et des
    /// échantillons déjà convertis en attente de constituer un paquet. C'est la grandeur que
    /// la correction de dérive maintient constante.
    private var pipelineDelayOutputFrames: Double {
        let ratio = Double(device.sampleRate) / captureFormat.sampleRate
        let ringFrames = Double(ring.availableFrames) * ratio
        let pendingFrames = Double(pendingSamples.count / device.channelCount)
        return ringFrames + pendingFrames
    }

    /// Encode, chiffre et émet un paquet audio, puis la synchro périodique si elle est due.
    ///
    /// C'est ici qu'est appliquée la correction de dérive (CDC 4.5, technique Snapcast) :
    /// selon la décision du synchroniseur, le paquet est bâti à partir d'une trame de plus,
    /// d'une trame de moins, ou d'exactement sa taille. Le fondu est assuré par
    /// ``SampleSplice`` ; le paquet émis fait **toujours** 352 trames, seule la position du
    /// flux se décale d'une trame.
    ///
    /// La manipulation porte sur `pendingSamples`, copie propre au sender extraite en aval du
    /// ring buffer : le tampon partagé n'est jamais touché (invariant section 12).
    private func sendNextPacket() throws {
        guard let encoder, let crypto, let audio = audioChannel else { return }
        let channels = device.channelCount
        let sampleCount = Self.framesPerPacket * channels

        let correction = synchronizer.observe(pipelineDelayOutputFrames: pipelineDelayOutputFrames)
        var consumedFrames = Self.framesPerPacket
        var block: [Int16]
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
        // L'ancrage doit décrire **le paquet qu'on émet**, donc être calculé avant d'avancer
        // la position du flux.
        let anchor = synchronizer.syncAnchorUnixTime(latencyFrames: Self.latencyFrames)
        pendingSamples.removeFirst(consumedFrames * channels)
        synchronizer.didConsume(outputFrames: consumedFrames)

        var payload = encoder.encode(block, frameCount: Self.framesPerPacket)
        try crypto.encryptAudioInPlace(&payload)

        // Le bit marker signale le premier paquet du flux : le récepteur y réinitialise
        // ses tampons. Compteur de session, pas compteur global : après une reconnexion, le
        // récepteur doit repartir sur des tampons neufs.
        let packet = RTPPacketBuilder.audio(
            sequenceNumber: sequenceNumber,
            timestamp: rtpTimestamp,
            ssrc: ssrc,
            marker: packetsInSession == 0,
            payload: payload
        )
        try audio.send(packet)

        if packetsInSession % Self.syncInterval == 0 {
            try sendSync(isFirst: packetsInSession == 0, anchorUnixTime: anchor)
        }

        sequenceNumber &+= 1
        rtpTimestamp &+= UInt32(Self.framesPerPacket)
        packetsSent += 1
        packetsInSession += 1
        statistics.packetsSent = packetsSent
    }

    /// Annonce de synchro sur le canal de contrôle : relie l'horloge NTP au timestamp RTP.
    ///
    /// **C'est ici que se fait l'alignement automatique entre sorties** (CDC 4.5). L'instant
    /// annoncé ne vient pas de « maintenant » mais de l'horloge de restitution commune : il
    /// dit au récepteur à quelle heure murale il doit restituer cette estampille. Deux
    /// sorties qui partagent cette horloge annoncent le même instant pour la même trame
    /// captée, et se retrouvent alignées sans jamais se connaître.
    ///
    /// Sans horloge démarrée (sortie unique lancée hors du contexte du jalon 4), on retombe
    /// sur « maintenant », c'est-à-dire exactement le comportement validé au jalon 2.
    private func sendSync(isFirst: Bool, anchorUnixTime: TimeInterval?) throws {
        guard let control = controlChannel else { return }
        let ntp = anchorUnixTime.map { NTPTime(unixTime: $0) } ?? NTPTime.now()
        let packet = RTPPacketBuilder.sync(
            rtpTimestamp: rtpTimestamp,
            latencyFrames: Self.latencyFrames,
            ntp: ntp,
            isFirst: isFirst
        )
        try control.send(packet)
        statistics.syncPacketsSent += 1
        if anchorUnixTime != nil { statistics.anchoredSyncPackets += 1 }
    }

    /// Répond aux requêtes d'horloge du récepteur **et** en tire la mesure de décalage.
    ///
    /// Double rôle, et c'est le cœur du jalon 4 côté AirPlay 1 :
    /// 1. répondre fidèlement, pour que le récepteur puisse caler son horloge sur la nôtre —
    ///    c'est ce qui rend l'ancrage des annonces de synchro exploitable ;
    /// 2. relever l'estampille d'émission du récepteur, qui donne le décalage entre son
    ///    horloge et la nôtre (voir ``TimingEstimator``) et sert de signal de vie.
    private nonisolated func installTimingResponder(on timing: UDPChannel) {
        timing.onReceive = { [weak self] data, _ in
            let receiveTime = NTPTime.now()
            // Un paquet de timing fait 32 octets : en-tête RTP de 4, puis 4 octets de
            // bourrage, puis trois estampilles NTP de 8.
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
            try? timing.send(response)
            // L'estampille d'origine est l'instant d'émission de la requête, lu sur
            // l'horloge du récepteur : c'est la matière première de la mesure.
            if let sender = self, let remote = NTPTime(bigEndianBytes: origin) {
                sender.synchronizer.timing.record(
                    remoteTransmitUnix: remote.unixTime,
                    localReceiveUnix: receiveTime.unixTime
                )
            }
            Task { await self?.countTimingResponse(at: receiveTime.unixTime) }
        }
    }

    private func countTimingResponse(at unixTime: TimeInterval) {
        statistics.timingResponsesSent += 1
        lastTimingRequestUnix = unixTime
    }

    private func teardown() async {
        audioChannel?.stop()
        controlChannel?.stop()
        timingChannel?.stop()
        audioChannel = nil
        controlChannel = nil
        timingChannel = nil
        await rtsp?.disconnect()
        rtsp = nil
        crypto = nil
        encoder = nil
        resampler = nil
        pendingSamples.removeAll(keepingCapacity: false)
        // Après le TEARDOWN, qui l'utilise encore : une session suivante en construira une
        // nouvelle à l'ANNOUNCE.
        sessionURI = nil
    }
}

/// Compteurs de session, pour la validation du jalon et le diagnostic.
public struct RAOPStatistics: Sendable {
    public var packetsSent = 0
    public var syncPacketsSent = 0
    public var timingResponsesSent = 0
    public var framesRead = 0
    public var errors = 0
    public var resyncs = 0
    public var volume: Float = 0
    public var reportedLatencyFrames = 0
    /// Annonces de synchro portant un ancrage issu de l'horloge commune (jalon 4). L'écart
    /// avec `syncPacketsSent` mesure combien d'annonces ont dû retomber sur « maintenant ».
    public var anchoredSyncPackets = 0
    /// Corrections de dérive appliquées (technique Snapcast, CDC 4.5).
    public var framesInserted = 0
    public var framesRemoved = 0
    /// Sessions rétablies après une perte réseau, et tentatives infructueuses (CDC section 8).
    public var reconnections = 0
    public var reconnectionAttempts = 0
    /// Trames refusées avant le premier paquet émis, imputables à la seule négociation.
    /// L'écart entre `AudioRingBuffer.droppedFrames` et cette valeur est le refus réel en
    /// régime établi — c'est lui, et lui seul, qui indiquerait un tampon trop petit.
    public var droppedBeforeStreaming = 0
}

public enum RAOPSenderError: Error, CustomStringConvertible {
    case alacUnsupported(String)
    case encryptionUnsupported(String)

    public var description: String {
        switch self {
        case let .alacUnsupported(name):
            return "\(name) n'annonce pas la prise en charge d'ALAC (cn=1)"
        case let .encryptionUnsupported(name):
            return "\(name) n'annonce pas la prise en charge de RSA-AES (et=1)"
        }
    }
}
