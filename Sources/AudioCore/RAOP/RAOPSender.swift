import AVFoundation
import Foundation
import OSLog

/// État observable d'un sender RAOP.
public enum RAOPSenderState: String, Sendable {
    case idle
    case connecting
    case streaming
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

    public private(set) var state: RAOPSenderState = .idle

    private let device: RAOPDevice
    private let ring: AudioRingBuffer
    private let captureFormat: AVAudioFormat
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
    private var streamTask: Task<Void, Never>?

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

    public init(device: RAOPDevice, ring: AudioRingBuffer, captureFormat: AVAudioFormat) {
        self.device = device
        self.ring = ring
        self.captureFormat = captureFormat
        self.readScratch = [Float](
            repeating: 0, count: 8_192 * Int(captureFormat.channelCount)
        )
    }

    // MARK: - Session

    /// Établit la session RTSP et démarre la diffusion.
    public func start(volume: Float = -20) async throws {
        guard state == .idle else { return }
        state = .connecting

        do {
            try await negotiate(volume: volume)
        } catch {
            state = .failed
            log.error("Établissement de la session RAOP en échec : \(String(describing: error), privacy: .public)")
            await teardown()
            throw error
        }

        // La capture tourne déjà pendant la découverte Bonjour et la négociation RTSP
        // (plusieurs secondes) : le ring buffer contient donc un arriéré d'audio périmé, et
        // a même déjà débordé. Le jeter ici évite de commencer la diffusion avec plusieurs
        // secondes de retard sur le direct.
        //
        // C'est une lecture, pas une écriture : l'invariant section 12 (le sender ne modifie
        // jamais le tampon partagé) reste respecté — avancer l'index de lecture est le rôle
        // normal du consommateur.
        let staleFrames = ring.availableFrames
        if staleFrames > 0 {
            discardStaleAudio()
            log.info("Arriéré de \(staleFrames) trames écarté avant le début de la diffusion")
        }
        // Photographie du compteur de refus au moment précis où la diffusion démarre. Tout
        // ce qui précède est imputable à la négociation (découverte Bonjour + RTSP), pendant
        // laquelle la capture tourne sans consommateur ; seul l'écart mesuré ensuite
        // signale un vrai sous-dimensionnement du tampon en régime établi.
        statistics.droppedBeforeStreaming = ring.droppedFrames

        state = .streaming
        streamTask = Task { [weak self] in
            await self?.streamLoop()
        }
        log.info("Diffusion RAOP démarrée vers \(self.device.displayName, privacy: .public)")
    }

    /// Arrête la diffusion et libère la session.
    public func stop() async {
        streamTask?.cancel()
        streamTask = nil
        if state == .streaming {
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
        // Le récepteur peut annoncer sa propre latence : elle servira au jalon 4 pour la
        // compensation automatique du décalage (CDC 4.5).
        if let audioLatency = response.headers["audio-latency"] {
            log.info("Latence annoncée par le récepteur : \(audioLatency, privacy: .public) trames")
            statistics.reportedLatencyFrames = Int(audioLatency) ?? 0
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
        try await client.send(RTSPRequest(method: "TEARDOWN", uri: uri))
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

        while !Task.isCancelled {
            do {
                try drainRingBuffer()
            } catch {
                log.error("Erreur de lecture du flux RAOP : \(String(describing: error), privacy: .public)")
                statistics.errors += 1
                // Invariant section 12 : l'échec reste confiné à ce sender. Il n'interrompt
                // ni la capture, ni aucune autre sortie ; la boucle continue et retentera.
            }

            // Un seul paquet par tour, à l'échéance : un flux RTP doit arriver au rythme
            // de lecture, pas en rafales. Émettre d'un coup tout le retard accumulé ferait
            // déborder le tampon du récepteur — et c'est ce que faisait une première
            // version, mesurée à un intervalle médian de 0,7 ms pour 7,98 ms théoriques.
            guard pendingSamples.count >= Self.framesPerPacket * device.channelCount else {
                // Pas encore assez d'audio : attendre un fragment de durée de paquet plutôt
                // que de tourner à vide.
                try? await Task.sleep(for: .milliseconds(2))
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
                nextDeadline += packetDuration
            } catch {
                log.error("Erreur d'émission RAOP : \(String(describing: error), privacy: .public)")
                statistics.errors += 1
                nextDeadline += packetDuration
            }
        }
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

    /// Encode, chiffre et émet un paquet audio, puis la synchro périodique si elle est due.
    private func sendNextPacket() throws {
        guard let encoder, let crypto, let audio = audioChannel else { return }
        let sampleCount = Self.framesPerPacket * device.channelCount
        let block = Array(pendingSamples[0..<sampleCount])
        pendingSamples.removeFirst(sampleCount)

        var payload = encoder.encode(block, frameCount: Self.framesPerPacket)
        try crypto.encryptAudioInPlace(&payload)

        // Le bit marker signale le premier paquet du flux : le récepteur y réinitialise
        // ses tampons.
        let packet = RTPPacketBuilder.audio(
            sequenceNumber: sequenceNumber,
            timestamp: rtpTimestamp,
            ssrc: ssrc,
            marker: packetsSent == 0,
            payload: payload
        )
        try audio.send(packet)

        if packetsSent % Self.syncInterval == 0 {
            try sendSync(isFirst: packetsSent == 0)
        }

        sequenceNumber &+= 1
        rtpTimestamp &+= UInt32(Self.framesPerPacket)
        packetsSent += 1
        statistics.packetsSent = packetsSent
    }

    /// Annonce de synchro sur le canal de contrôle : relie l'horloge NTP au timestamp RTP.
    private func sendSync(isFirst: Bool) throws {
        guard let control = controlChannel else { return }
        let packet = RTPPacketBuilder.sync(
            rtpTimestamp: rtpTimestamp,
            latencyFrames: Self.latencyFrames,
            ntp: NTPTime.now(),
            isFirst: isFirst
        )
        try control.send(packet)
        statistics.syncPacketsSent += 1
    }

    /// Répond aux requêtes d'horloge du récepteur.
    ///
    /// C'est ce canal qui donnera, au jalon 4, la mesure de latence réelle par sortie
    /// (CDC 4.5). Ici il est simplement servi correctement pour que le récepteur puisse se
    /// caler.
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
            Task { await self?.countTimingResponse() }
        }
    }

    private func countTimingResponse() {
        statistics.timingResponsesSent += 1
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
