import AVFoundation
import Foundation
import OSLog

/// État observable d'un sender AirPlay 2.
public enum AirPlay2SenderState: String, Sendable {
    case idle
    case connecting
    case streaming
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

    public private(set) var state: AirPlay2SenderState = .idle

    private let device: AirPlay2Device
    private let ring: AudioRingBuffer
    private let captureFormat: AVAudioFormat
    private let log = AudioLog.airplay2

    private var rtsp: RTSPClient?
    private var session: AirPlay2Session?
    private var encoder: ALACEncoder?
    private var resampler: RAOPResampler?
    private var streamCipher: ChaChaPoly1305?

    private var audioChannel: UDPChannel?

    private let ssrc: UInt32 = UInt32.random(in: .min ... .max)
    private var sequenceNumber = UInt16.random(in: 0...UInt16.max / 2)
    private var rtpTimestamp: UInt32 = UInt32.random(in: 0...UInt32.max / 2)
    private var packetsSent = 0
    private var streamTask: Task<Void, Never>?

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
    public init(device: AirPlay2Device, ring: AudioRingBuffer, captureFormat: AVAudioFormat) {
        self.device = device
        self.ring = ring
        self.captureFormat = captureFormat
        self.readScratch = [Float](
            repeating: 0, count: 8_192 * Int(captureFormat.channelCount)
        )
    }

    // MARK: - Session

    /// Établit la session (pairing compris) et démarre la diffusion.
    public func start(volume: Float = -20) async throws {
        guard state == .idle else { return }
        state = .connecting

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
        // Photographie du compteur de refus au démarrage réel de la diffusion : tout ce qui
        // précède est imputable à la fenêtre de négociation, pendant laquelle la capture
        // tourne sans consommateur.
        statistics.droppedBeforeStreaming = ring.droppedFrames

        state = .streaming
        streamTask = Task { [weak self] in
            await self?.streamLoop()
        }
        log.info("Diffusion AirPlay 2 démarrée vers \(self.device.serviceName, privacy: .public)")
    }

    /// Arrête la diffusion et libère la session.
    public func stop() async {
        streamTask?.cancel()
        streamTask = nil
        if state == .streaming, let session {
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

        // 1. Pair-setup transitoire. Refuse d'emblée si le récepteur ne l'annonce pas,
        //    plutôt que d'échouer plus loin sur un message cryptographique obscur.
        let pairing = AirPlay2PairingSession(client: client, device: device)
        let keys = try await pairing.performTransientPairSetup()

        // 2. Tout ce qui suit passe en chiffré. À activer seulement une fois la réponse M4
        //    entièrement lue : le récepteur ne chiffre qu'à partir du message suivant.
        try await client.enableEncryption(keys: keys)

        // 3. Les deux SETUP, puis le volume et le RECORD.
        let session = AirPlay2Session(client: client, device: device)
        self.session = session
        let endpoints = try await session.setup()

        // Le canal audio est un socket UDP dont le port local est choisi par le système :
        // contrairement à RAOP, le récepteur n'exige pas ici un port annoncé à l'avance.
        let audio = try UDPChannel(label: "airplay2-audio")
        try audio.setDestination(host: device.host, port: endpoints.dataPort)
        audioChannel = audio

        encoder = ALACEncoder()
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

        while !Task.isCancelled {
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

            guard pendingSamples.count >= Self.framesPerPacket * Self.streamChannelCount else {
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
                nextDeadline += packetDuration
            } catch {
                log.error(
                    "Erreur d'émission AirPlay 2 : \(String(describing: error), privacy: .public)")
                statistics.errors += 1
                nextDeadline += packetDuration
            }
        }
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
    /// paquet, et non AES-CBC. L'en-tête RTP sert de données associées, ce qui empêche de le
    /// modifier en transit.
    private func sendNextPacket() throws {
        guard let encoder, let cipher = streamCipher, let audio = audioChannel else { return }
        let sampleCount = Self.framesPerPacket * Self.streamChannelCount
        let block = Array(pendingSamples[0..<sampleCount])
        pendingSamples.removeFirst(sampleCount)

        let payload = Data(encoder.encode(block, frameCount: Self.framesPerPacket))

        // Le bit marker signale le premier paquet du flux : le récepteur y réinitialise
        // ses tampons.
        let header = RTPPacketBuilder.audioHeader(
            sequenceNumber: sequenceNumber,
            timestamp: rtpTimestamp,
            ssrc: ssrc,
            marker: packetsSent == 0
        )
        // Nonce : 4 octets nuls puis le compteur de paquets sur 64 bits little-endian.
        // Il ne se répète jamais tant que la session vit, condition de sûreté de l'AEAD.
        var nonce = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: UInt64(packetsSent).littleEndian) { nonce.append(contentsOf: $0) }

        let sealed = try cipher.seal(payload, nonce: nonce, additionalData: header)
        try audio.send(header + sealed)

        sequenceNumber &+= 1
        rtpTimestamp &+= UInt32(Self.framesPerPacket)
        packetsSent += 1
        statistics.packetsSent = packetsSent
    }

    /// Ferme les ressources réseau. Idempotent : appelable après un échec partiel.
    private func teardown() async {
        audioChannel?.stop()
        audioChannel = nil
        await rtsp?.disconnect()
        rtsp = nil
        session = nil
        encoder = nil
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

    public init() {}
}
