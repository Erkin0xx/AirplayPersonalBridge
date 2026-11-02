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
/// PCM L16 pour la charge utile (ALAC en repli, pour un récepteur qui n'accepterait que lui).
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
/// `ANNOUNCE` (SDP : format, clé AES chiffrée et IV si chiffrement) → `SETUP` (ports UDP) →
/// `POST /feedback` (sonde de maintien de session) → `RECORD` (départ du flux) →
/// `SET_PARAMETER` (volume) → paquets RTP → `TEARDOWN`.
///
/// C'est celle de pyatv, à deux écarts près, tous deux acceptés par la vraie Geneva : pyatv
/// fait précéder l'`ANNOUNCE` d'un `GET /info` et suivre le `RECORD` d'un `FLUSH`. Ni lui ni ce
/// sender n'envoient d'`OPTIONS` : macOS le fait pour passer un défi `Apple-Challenge`, qu'un
/// flux en clair n'a pas à relever.
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
    /// avant que le tampon du récepteur ne se vide. Le Wi-Fi rend couramment `ENOBUFS` sur
    /// quelques dizaines de paquets en cas de congestion : à 20 paquets (0,16 s), ce sursaut
    /// coûtait une renégociation complète, bien plus audible que la perte elle-même.
    private static let lostSessionErrorThreshold = 50
    /// Toute notre profondeur d'échantillon : le rééchantillonneur et les deux formats de charge
    /// utile sont en 16 bits, quoi que le récepteur annonce savoir faire en `ss`.
    private static let bitsPerSample = 16
    /// Délai accordé à une requête de maintien de session (valeur de pyatv).
    private static let keepAliveTimeout: Duration = .seconds(4)
    /// Délai accordé à la sonde : au-delà, le récepteur est réputé ne pas gérer `/feedback`.
    /// Plus court que pour le maintien, car il retarde le départ du son.
    private static let keepAliveProbeTimeout: Duration = .seconds(2)
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

    /// Le récepteur. Seuls son adresse et son port bougent, voir ``refreshAddress()``.
    private var device: RAOPDevice
    /// Relit l'annonce du récepteur, quand une perte de session se prolonge. `nil` : jamais.
    private let rediscover: (@Sendable () async -> RAOPDevice?)?
    /// Échecs de reconnexion consécutifs entre deux relectures.
    private let rediscoveryInterval: Int
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
    /// Codec retenu à la négociation : PCM brut (`L16`) plutôt qu'ALAC. Voir `negotiate`.
    private var usesPCM = false
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
    /// Tâche de maintien de session, propre à la session en cours.
    private var keepAliveTask: Task<Void, Never>?
    /// Période du maintien de session. 25 s comme pyatv ; injectable pour les tests.
    private let keepAliveInterval: Duration
    /// Le récepteur a-t-il accepté la sonde `/feedback` de cette session ?
    private var keepAliveAccepted = false
    /// Répond aux demandes de retransmission, hors de l'acteur : voir sa documentation.
    private let retransmitter = RAOPRetransmitResponder()
    /// Renfort de basses (ADR-002), appliqué à la copie propre à ce sender. Transparent à 0 dB.
    private var bassBoost: LowShelfFilter
    /// Avance à chaque `stop()`. Une négociation qui se termine sous une autre valeur que celle
    /// de son départ a été rendue caduque, et ne doit surtout pas démarrer le flux.
    private var sessionGeneration = 0
    /// Avance à chaque négociation. Une perte signalée par la connexion d'une session précédente
    /// ne doit pas faire tomber la suivante.
    private var connectionEpoch = 0
    /// Valeur de l'en-tête `Session` rendu par le `SETUP`, reprise au `TEARDOWN`.
    private var receiverSession: String?
    /// Réservé aux tests : un paquet sur N n'est pas émis, mais reste dans l'historique. Une perte
    /// réelle ne se provoque pas à la demande sur la boucle locale, et c'est le seul moyen de
    /// vérifier qu'un vrai récepteur accepte nos retransmissions.
    private var simulatedLossInterval = 0
    /// Volume courant, à réappliquer après une reconnexion.
    private var currentVolume: Float = -20
    /// Rétablissement automatique après perte réseau (CDC section 8). Désactivable pour les
    /// tests, qui ne doivent pas voir un sender ressusciter une session volontairement close.
    private let reconnects: Bool
    /// Vrai quand la boucle de diffusion a conclu à une perte de session.
    private var sessionLost = false
    /// Connexion dont la rupture a déjà été signalée. Voir ``noteControlConnectionLost(epoch:)``.
    private var lostConnectionEpoch: Int?
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

    private var counters = RAOPStatistics()

    /// Statistiques exposées pour la validation du jalon.
    public var statistics: RAOPStatistics {
        var snapshot = counters
        let retransmissions = retransmitter.snapshot
        snapshot.retransmitRequests = retransmissions.requests
        snapshot.packetsRetransmitted = retransmissions.packetsResent
        snapshot.retransmitMisses = retransmissions.packetsMissing
        snapshot.retransmitsThrottled = retransmissions.packetsThrottled
        return snapshot
    }

    /// Dernière erreur de session, rédigée pour l'affichage. `nil` tant que tout va bien, y
    /// compris après une reconnexion réussie. Lue avec ``state`` : en `.reconnecting`, elle dit
    /// ce qui retarde le rétablissement (« récepteur occupé… ») ; en `.failed`, pourquoi le
    /// sender a renoncé.
    public private(set) var lastErrorMessage: String?

    /// - Parameters:
    ///   - device: le récepteur, tel que la découverte Bonjour l'a résolu.
    ///   - ring: le ring buffer **propre à cette sortie** (invariant section 12).
    ///   - captureFormat: format livré par la capture.
    ///   - clock: horloge de restitution commune (CDC 4.5). Par défaut une horloge propre à
    ///     ce sender, ce qui laisse le comportement du jalon 2 inchangé quand une seule
    ///     sortie diffuse ; l'alignement inter-sorties suppose de passer **la même** aux deux.
    ///   - reconnects: rétablissement automatique de la session après perte réseau.
    ///   - keepAliveInterval: période du maintien de session.
    ///   - rediscover: relit l'annonce du récepteur quand les reconnexions échouent. Ne contacte
    ///     aucun appareil : ce ne sont que des questions mDNS.
    ///   - rediscoveryInterval: échecs de reconnexion entre deux relectures.
    public init(
        device: RAOPDevice,
        ring: AudioRingBuffer,
        captureFormat: AVAudioFormat,
        clock: PlaybackClockProtocol? = nil,
        reconnects: Bool = true,
        keepAliveInterval: Duration = .seconds(25),
        rediscover: (@Sendable () async -> RAOPDevice?)? = nil,
        rediscoveryInterval: Int = 3
    ) {
        self.device = device
        self.rediscover = rediscover
        self.rediscoveryInterval = max(1, rediscoveryInterval)
        self.ring = ring
        self.captureFormat = captureFormat
        self.reconnects = reconnects
        self.keepAliveInterval = keepAliveInterval
        self.bassBoost = LowShelfFilter(
            sampleRate: captureFormat.sampleRate,
            channelCount: Int(captureFormat.channelCount)
        )
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

    /// Renfort de basses de cette sortie, en dB (ADR-002 : plateau grave à 80 Hz, 0 à +12 dB).
    ///
    /// Applicable à tout moment, avant comme pendant la diffusion, et conservé d'une reconnexion
    /// à l'autre. Le changement glisse sans clic, et 0 dB est strictement transparent. Il n'agit
    /// que sur la copie propre à ce sender : les autres sorties reçoivent le flux intact
    /// (invariant section 12). Voir ``LowShelfFilter`` pour la gestion de l'écrêtage.
    public func setBassBoost(decibels: Float) {
        bassBoost.setGain(decibels: Double(decibels))
        counters.bassBoostDecibels = Float(bassBoost.gainDecibels)
    }

    /// Voir ``simulatedLossInterval``. Interne : uniquement accessible aux tests.
    func simulateLoss(everyNthPacket interval: Int) {
        simulatedLossInterval = interval
    }

    /// Négociation en cours ou dernière en date. Interne : uniquement lu par les tests, pour
    /// livrer un signal de perte à un instant précis de la négociation.
    var currentConnectionEpoch: Int { connectionEpoch }

    // MARK: - Session

    /// Établit la session RTSP et démarre la diffusion.
    ///
    /// Annuler la tâche appelante abandonne la négociation sans attendre ses délais. Un
    /// ``stop()`` concurrent aussi, et `start` lève alors `CancellationError`.
    public func start(volume: Float = -20) async throws {
        guard state == .idle else { return }
        state = .connecting
        currentVolume = volume
        lastErrorMessage = nil
        let generation = sessionGeneration

        do {
            try await negotiate()
            guard generation == sessionGeneration else { throw CancellationError() }
        } catch {
            guard generation == sessionGeneration else {
                // `stop()` est passé pendant la négociation et a rendu le sender au repos. Il
                // ne reste qu'à libérer ce que la négociation a pu ouvrir depuis.
                if state == .idle { await teardown() }
                throw CancellationError()
            }
            if error is CancellationError {
                state = .idle
            } else {
                state = .failed
                lastErrorMessage = String(describing: error)
                log.error("Établissement de la session RAOP en échec : \(String(describing: error), privacy: .public)")
            }
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
        // Rien de ce qui a précédé ne sera plus joué : ni la queue du filtre, ni les paquets de
        // la session d'avant. La numérotation continuant d'une session à l'autre, un paquet resté
        // dans l'historique répondrait à une demande sur un numéro qui n'est plus le sien.
        bassBoost.reset()
        retransmitter.clear()
        if firstSession {
            // Photographie du compteur de refus au moment précis où la diffusion démarre.
            // Tout ce qui précède est imputable à la négociation (découverte Bonjour +
            // RTSP), pendant laquelle la capture tourne sans consommateur ; seul l'écart
            // mesuré ensuite signale un vrai sous-dimensionnement du tampon en régime établi.
            counters.droppedBeforeStreaming = ring.droppedFrames
        }
        packetsInSession = 0
        consecutiveSendErrors = 0
        // Pas un simple `false` : la connexion a pu tomber à la toute fin de la négociation.
        sessionLost = lostConnectionEpoch == connectionEpoch
        lastTimingRequestUnix = nil
        timingSilenceReported = false
        // Ancre le flux sur l'horloge de capture commune aux deux sorties.
        synchronizer.beginStreaming(atCaptureFrame: ring.totalFramesRead)
        startKeepAlive()
    }

    /// Surveille la diffusion et rétablit la session après une perte réseau (CDC section 8).
    ///
    /// La reconnexion est **isolée** : elle ne touche ni la capture, ni le ring buffer, ni
    /// l'autre sortie, qui n'a aucun moyen de savoir que celle-ci a décroché (invariant
    /// section 12). Le repli exponentiel évite de marteler un récepteur absent : une perte qui
    /// dure ne coûte qu'une tentative toutes les 15 s, sans rien accumuler d'une à l'autre.
    private func supervise() async {
        while !Task.isCancelled {
            await streamLoop()
            guard !Task.isCancelled, sessionLost else { break }
            stopKeepAlive()
            guard reconnects else {
                state = .failed
                lastErrorMessage = "session perdue avec le récepteur"
                await teardown()
                break
            }

            state = .reconnecting
            counters.reconnections += 1
            log.error("Session RAOP perdue — tentative de rétablissement")
            await teardown()

            var delay: Duration = .seconds(1)
            var reconnected = false
            var failedAttempts = 0
            while !Task.isCancelled && !reconnected {
                do {
                    try await Task.sleep(for: delay)
                    try await negotiate()
                    reconnected = true
                } catch is CancellationError {
                    return
                } catch {
                    counters.reconnectionAttempts += 1
                    lastErrorMessage = String(describing: error)
                    log.error(
                        "Reconnexion RAOP en échec : \(String(describing: error), privacy: .public)"
                    )
                    await teardown()
                    guard Self.isWorthRetrying(error) else {
                        state = .failed
                        return
                    }
                    delay = Self.reconnectDelay(after: error, current: delay)
                    failedAttempts += 1
                    if failedAttempts % rediscoveryInterval == 0 { await refreshAddress() }
                }
            }
            guard reconnected, !Task.isCancelled else { break }
            lastErrorMessage = nil
            beginStreaming(firstSession: false)
            state = .streaming
            log.info("Session RAOP rétablie")
        }
    }

    /// Relit l'adresse et le port annoncés, quand les reconnexions s'enchaînent en échec.
    ///
    /// Un récepteur redémarré peut revenir sous une autre adresse (bail DHCP) ou un autre port, et
    /// la seule chose que le sender en connaît date de la découverte initiale : sans cette relecture,
    /// il l'appellerait à l'ancienne adresse jusqu'à l'arrêt de la diffusion.
    ///
    /// Rien ne change tant que la session vit, et une relecture sans réponse ne coûte rien. Seuls
    /// l'adresse et le port sont repris : les capacités ont servi à bâtir la session et le
    /// synchroniseur, et rien ne dit qu'un TXT lu à ce moment soit complet.
    private func refreshAddress() async {
        guard let rediscover else { return }
        let found = try? await untilCancelled { await rediscover() }
        guard let found, found.host != device.host || found.port != device.port,
            BonjourAddressResolver.canReplace(known: device.host, with: found.host)
        else { return }
        log.info(
            "\(self.device.displayName, privacy: .public) : nouvelle adresse \(found.host, privacy: .public):\(found.port)"
        )
        device = RAOPDevice(
            serviceName: device.serviceName, host: found.host, port: found.port, txt: device.txt
        )
    }

    /// Un refus définitif ne se corrigera pas en réessayant : mot de passe exigé, ou format que
    /// le récepteur n'annonce pas. Le reste (réseau, occupé, redémarrage) peut se résoudre seul.
    static func isWorthRetrying(_ error: Error) -> Bool {
        if let raop = error as? RAOPSenderError { return !raop.isPermanent }
        if let rtsp = error as? RTSPError, rtsp.requiresPassword { return false }
        return true
    }

    /// Délai avant la prochaine tentative, doublé à chaque échec.
    ///
    /// Un récepteur **occupé** ne se libérera pas en quelques secondes : soit un autre appareil
    /// diffuse, soit il garde notre ancienne session jusqu'à l'expiration de son délai. Il a donc
    /// droit à une attente nettement plus longue, sans quoi on l'interrogerait pour rien.
    static func reconnectDelay(after error: Error, current: Duration) -> Duration {
        if let rtsp = error as? RTSPError, rtsp.isReceiverBusy {
            return min(max(current * 2, .seconds(10)), .seconds(30))
        }
        return min(current * 2, .seconds(15))
    }

    /// Arrête la diffusion et libère la session. Ne reste jamais bloqué : la négociation en
    /// cours est abandonnée sur-le-champ, et le `TEARDOWN` a droit à 2 s au plus.
    public func stop() async {
        sessionGeneration &+= 1
        let supervision = streamTask
        streamTask = nil
        supervision?.cancel()
        stopKeepAlive()
        // Attendre que la supervision ait lâché la session : elle pourrait sinon être en train
        // de rouvrir sockets et connexion, qui survivraient à cet arrêt.
        await supervision?.value

        if state == .streaming || state == .reconnecting {
            await sendTeardown()
        }
        await teardown()
        state = .idle
        log.info("Diffusion RAOP arrêtée (\(self.packetsSent) paquets émis)")
    }

    private func negotiate() async throws {
        // Le choix vit dans `RAOPDevice`, pour que `--browse` dise ce qui sera vraiment employé.
        switch device.plannedCodec {
        case .pcm: usesPCM = true
        case .alac: usesPCM = false
        case nil: throw RAOPSenderError.alacUnsupported(device.serviceName)
        }
        let crypto: RAOPCrypto?
        switch device.plannedEncryption {
        case .clear: crypto = nil
        case .rsaAES: crypto = try RAOPCrypto()
        case nil: throw RAOPSenderError.encryptionUnsupported(device.serviceName)
        }
        // Contrôlé avant tout échange : les canaux UDP et le SDP ne savent viser que de l'IPv4.
        // Découvert seulement après le `SETUP`, l'échec laisserait une session ouverte en face.
        guard UDPChannel.isIPv4Literal(device.host) else {
            throw RAOPSenderError.ipv4Required(device.host)
        }
        self.crypto = crypto
        self.encoder = usesPCM
            ? nil
            : ALACEncoder(framesPerPacket: Self.framesPerPacket, channelCount: device.channelCount)
        self.resampler = try RAOPResampler(
            inputFormat: captureFormat,
            outputSampleRate: Double(device.sampleRate),
            channelCount: AVAudioChannelCount(device.channelCount)
        )

        connectionEpoch &+= 1
        let epoch = connectionEpoch
        receiverSession = nil
        keepAliveAccepted = false

        // Rendu visible avant de se connecter : c'est ce qui permet à `stop()` d'interrompre
        // l'établissement, au lieu d'attendre son délai.
        let client = RTSPClient(host: device.host, port: device.port)
        self.rtsp = client
        try await client.connect(honoringCancellation: true)

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
        installRetransmitResponder(on: control)
        control.startReceiving()
        timing.startReceiving()

        // Comme pyatv : la sonde précède le `RECORD`, et décide du maintien de session.
        keepAliveAccepted = try await probeKeepAlive(client: client)

        try await record(client: client, uri: uri)
        do {
            try await setVolume(currentVolume, client: client, uri: uri, honoringCancellation: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Un refus du volume ne vaut pas la perte du son. Une vraie rupture de connexion,
            // elle, sera vue par le signal posé juste après.
            counters.errors += 1
            log.error("Volume de départ refusé : \(String(describing: error), privacy: .public)")
        }

        // Signal franc de perte de session, posé une fois la négociation terminée : le flux
        // audio étant en UDP, la rupture de cette connexion TCP est la seule indication
        // fiable qu'un récepteur a disparu (CDC section 8).
        await client.onConnectionLost { [weak self] in
            Task { await self?.noteControlConnectionLost(epoch: epoch) }
        }
    }

    /// Sonde du maintien de session : `POST /feedback`, une fois, comme pyatv.
    ///
    /// Un refus ou un silence ne sont pas des erreurs : le récepteur n'en a simplement pas
    /// besoin, et aucune requête périodique ne lui sera envoyée. Le délai reste bref : la
    /// réponse tardive, s'il y en a une, sera écartée par son `CSeq`.
    private func probeKeepAlive(client: RTSPClient) async throws -> Bool {
        do {
            try await client.send(
                RTSPRequest(method: "POST", uri: "/feedback"),
                timeout: Self.keepAliveProbeTimeout,
                honoringCancellation: true
            )
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.info("Pas de maintien de session : \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Lance le maintien de session, si le récepteur a accepté la sonde.
    ///
    /// Un récepteur peut fermer une session sans nouvelle de son client au bout de quelques
    /// minutes, le flux UDP ne comptant pas pour lui comme un signe de vie sur la connexion RTSP.
    /// **Toute erreur reste confinée ici** : un maintien refusé ne dit rien de l'état de la
    /// session, et la perte réelle de la connexion a son propre signal.
    private func startKeepAlive() {
        stopKeepAlive()
        counters.keepAliveSupported = keepAliveAccepted
        guard keepAliveAccepted, let client = rtsp else { return }
        let interval = keepAliveInterval
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                    try await client.send(
                        RTSPRequest(method: "POST", uri: "/feedback"),
                        timeout: Self.keepAliveTimeout,
                        honoringCancellation: true
                    )
                    await self?.noteKeepAlive(failure: nil)
                } catch is CancellationError {
                    return
                } catch {
                    await self?.noteKeepAlive(failure: error)
                }
            }
        }
    }

    private func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    private func noteKeepAlive(failure: Error?) {
        if let failure {
            counters.keepAliveFailures += 1
            log.info("Maintien de session sans réponse : \(String(describing: failure), privacy: .public)")
        } else {
            counters.keepAlivesSent += 1
        }
    }

    /// `ANNOUNCE` : décrit le flux en SDP, clé AES chiffrée comprise.
    private func announce(
        client: RTSPClient, uri: String, crypto: RAOPCrypto?, sessionID: UInt32
    ) async throws {
        let localAddress = await client.localAddress

        // Les paramètres `fmtp` sont ceux du décodeur ALAC, dans l'ordre imposé par le
        // protocole : frameLength, compatibleVersion, bitDepth, pb, mb, kb, channels,
        // maxRun, maxFrameBytes, avgBitRate, sampleRate.
        //
        // Un flux L16 n'en a aucun besoin, mais pyatv envoie quand même cette ligne, et la
        // Geneva n'a jamais été validée sans : elle reste. Elle est retirée dans un seul cas,
        // face à un récepteur qui annonce **aussi** ALAC. shairport-sync jusqu'à 5.2.1 au moins
        // choisit son décodeur ALAC dès qu'il la voit, quel que soit le `rtpmap`, et décode alors
        // du PCM jusqu'à en mourir (`Bus error`, en moins de 30 s). Corrigé depuis en amont.
        let carriesDecoderParameters = !usesPCM || !device.supportsALAC
        let fmtp = [
            "\(Self.framesPerPacket)", "0", "\(Self.bitsPerSample)", "40", "10", "14",
            "\(device.channelCount)", "255", "0", "0", "\(device.sampleRate)",
        ].joined(separator: " ")

        // Les lignes sont assemblées plutôt qu'écrites dans un littéral multiligne : les deux
        // dernières n'existent qu'en mode chiffré. Un `a=rsaaeskey` présent alors que le
        // récepteur ne sait pas déchiffrer le laisse partir sur des paramètres par défaut.
        var lines = [
            "v=0",
            "o=iTunes \(sessionID) 0 IN IP4 \(localAddress)",
            "s=iTunes",
            "c=IN IP4 \(device.host)",
            "t=0 0",
            "m=audio 0 RTP/AVP 96",
            usesPCM
                ? "a=rtpmap:96 L16/\(device.sampleRate)/\(device.channelCount)"
                : "a=rtpmap:96 AppleLossless",
        ]
        if carriesDecoderParameters {
            lines.append("a=fmtp:96 \(fmtp)")
        }
        if let crypto {
            lines.append("a=rsaaeskey:\(RAOPCrypto.base64Unpadded(try crypto.encryptedSessionKey()))")
            lines.append("a=aesiv:\(RAOPCrypto.base64Unpadded(crypto.aesIV))")
        }
        let sdp = lines.joined(separator: "\r\n") + "\r\n"

        try await client.send(
            RTSPRequest(
                method: "ANNOUNCE",
                uri: uri,
                headers: [("Content-Type", "application/sdp")],
                body: Data(sdp.utf8)
            ),
            honoringCancellation: true
        )
    }

    /// `SETUP` : annonce les ports locaux, récupère ceux du récepteur.
    private func setup(
        client: RTSPClient, uri: String, control: UDPChannel, timing: UDPChannel
    ) async throws -> RTPPorts {
        let transport = [
            "RTP/AVP/UDP", "unicast", "interleaved=0-1", "mode=record",
            "control_port=\(control.localPort)", "timing_port=\(timing.localPort)",
        ].joined(separator: ";")

        let response = try await client.send(
            RTSPRequest(method: "SETUP", uri: uri, headers: [("Transport", transport)]),
            honoringCancellation: true
        )

        // PIÈGE : ce sont les ports **de la réponse** qui font foi, jamais ceux demandés.
        let parameters = response.transportParameters
        guard let serverPort = Self.port(from: parameters["server_port"]) else {
            throw RTSPError.missingHeader("Transport/server_port")
        }
        let controlPort = Self.port(from: parameters["control_port"]) ?? serverPort
        let timingPort = Self.port(from: parameters["timing_port"]) ?? serverPort
        // `Session: 1234;timeout=60` : seul l'identifiant est à reprendre.
        receiverSession = response.headers["session"]?
            .split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces) }

        log.info("Ports du récepteur — audio \(serverPort), control \(controlPort), timing \(timingPort)")
        return RTPPorts(audio: serverPort, control: controlPort, timing: timingPort)
    }

    /// Lit un port du `Transport`, y compris sous sa forme d'intervalle RTSP (`6000-6001`).
    private static func port(from value: String?) -> UInt16? {
        guard let value else { return nil }
        return UInt16(value.prefix { $0.isNumber })
    }

    /// `RECORD` : démarre le flux. `RTP-Info` porte la séquence et l'estampille de départ.
    private func record(client: RTSPClient, uri: String) async throws {
        let response = try await client.send(
            RTSPRequest(
                method: "RECORD",
                uri: uri,
                headers: [
                    ("Range", "npt=0-"),
                    ("RTP-Info", "seq=\(sequenceNumber);rtptime=\(rtpTimestamp)"),
                ]
            ),
            honoringCancellation: true
        )
        // Latence annoncée par le récepteur : sa profondeur de tampon interne, en trames.
        // C'est précisément la grandeur qu'une mesure de trajet réseau ne verrait pas (CDC
        // 4.5) — elle vaut ici des centaines de millisecondes là où un aller-retour sur un
        // réseau local se compte en dizaines de microsecondes.
        if let audioLatency = response.headers["audio-latency"] {
            log.info("Latence annoncée par le récepteur : \(audioLatency, privacy: .public) trames")
            let frames = Int(audioLatency) ?? 0
            counters.reportedLatencyFrames = frames
            synchronizer.declaredReceiverLatencyFrames = frames
        }
    }

    /// `SET_PARAMETER` : volume, en dB. RAOP attend −144 (silence) ou −30…0.
    ///
    /// Pendant une négociation, la valeur est simplement retenue : elle partira à la fin de
    /// celle-ci. Un réglage fait pendant une coupure ne doit ni échouer ni être oublié, sans
    /// quoi la reprise se ferait à l'ancien volume.
    public func setVolume(_ volume: Float) async throws {
        currentVolume = volume
        if state == .connecting || state == .reconnecting { return }
        guard let client = rtsp, let uri = sessionURI else { throw RTSPError.notConnected }
        try await setVolume(volume, client: client, uri: uri)
    }

    private func setVolume(
        _ volume: Float, client: RTSPClient, uri: String, honoringCancellation: Bool = false
    ) async throws {
        let clamped = volume <= -144 ? -144 : min(max(volume, -30), 0)
        let body = "volume: \(String(format: "%.6f", clamped))\r\n"
        try await client.send(
            RTSPRequest(
                method: "SET_PARAMETER",
                uri: uri,
                headers: [("Content-Type", "text/parameters")],
                body: Data(body.utf8)
            ),
            honoringCancellation: honoringCancellation
        )
        counters.volume = clamped
    }

    /// `TEARDOWN`, en portant l'identifiant que le `SETUP` a rendu, comme pyatv : sans lui, un
    /// récepteur peut ne pas reconnaître la session, la garder ouverte et répondre `453` à la
    /// reconnexion suivante.
    private func sendTeardown() async {
        guard let client = rtsp, let uri = sessionURI else { return }
        var headers: [(name: String, value: String)] = []
        if let receiverSession { headers.append(("Session", receiverSession)) }
        let request = RTSPRequest(method: "TEARDOWN", uri: uri, headers: headers)

        // Détaché, parce que l'appelant est le plus souvent une tâche **déjà annulée** : c'est
        // ainsi que `BridgeEngine` arrête une sortie. Le récepteur doit recevoir ce message
        // quoi qu'il arrive, sous peine de rester occupé.
        //
        // Délai court : beaucoup de récepteurs ferment la connexion dès le TEARDOWN reçu,
        // sans jamais répondre — c'est le cas du mock shairport-sync, qui quitte. Attendre
        // les 10 s par défaut retarderait l'arrêt sans rien apporter : à ce stade la
        // diffusion est terminée et la réponse n'est plus exploitable.
        await Task.detached {
            _ = try? await client.send(request, timeout: .seconds(2))
        }.value
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
                counters.errors += 1
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
                counters.resyncs += 1
            }

            do {
                try sendNextPacket()
                consecutiveSendErrors = 0
                nextDeadline += packetDuration
            } catch {
                log.error("Erreur d'émission RAOP : \(String(describing: error), privacy: .public)")
                counters.errors += 1
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
    ///
    /// Le signal arrive par une tâche, et peut donc précéder le passage en `.streaming` quand la
    /// connexion tombe à la toute fin de la négociation. Il est conservé pour
    /// ``beginStreaming(firstSession:)`` : ignoré, il laissait le sender diffuser dans le vide,
    /// le flux UDP n'échouant jamais, sans plus rien pour lui signaler la perte.
    func noteControlConnectionLost(epoch: Int) {
        guard epoch == connectionEpoch else { return }
        lostConnectionEpoch = epoch
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
                // Sur `readScratch`, donc sur la copie propre à ce sender. Avant la conversion
                // en 16 bits, où un dépassement serait déjà un écrêtage. Sans effet à 0 dB.
                bassBoost.process(base, frameCount: read)
                return try resampler.convert(base, frameCount: read)
            }
            guard !converted.isEmpty else { break }
            pendingSamples.append(contentsOf: converted)
            counters.framesRead += frames
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
        guard let audio = audioChannel else { return }
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
            counters.framesRemoved += 1
        case .insertFrame:
            consumedFrames = Self.framesPerPacket - 1
            block = SampleSplice.insertingOneFrame(
                into: Array(pendingSamples[0..<(sampleCount - channels)]),
                channelCount: channels
            )
            counters.framesInserted += 1
        }
        // L'ancrage doit décrire **le paquet qu'on émet**, donc être calculé avant d'avancer
        // la position du flux.
        let anchor = synchronizer.syncAnchorUnixTime(latencyFrames: Self.latencyFrames)
        pendingSamples.removeFirst(consumedFrames * channels)
        synchronizer.didConsume(outputFrames: consumedFrames)

        // En PCM, la charge utile est la suite des échantillons en **big-endian** : c'est
        // l'ordre réseau qu'impose L16, et l'inverser donne du bruit blanc à pleine échelle.
        var payload: [UInt8]
        if let encoder {
            payload = encoder.encode(block, frameCount: Self.framesPerPacket)
        } else {
            payload = []
            payload.reserveCapacity(block.count * 2)
            for sample in block {
                let bits = UInt16(bitPattern: sample)
                payload.append(UInt8(truncatingIfNeeded: bits >> 8))
                payload.append(UInt8(truncatingIfNeeded: bits))
            }
        }
        // `crypto` est nil en mode clair (`et=0`) : la charge utile part telle quelle.
        try crypto?.encryptAudioInPlace(&payload)

        // Le bit marker signale le premier paquet du flux : le récepteur y réinitialise
        // ses tampons. Compteur de session, pas compteur global : après une reconnexion, le
        // récepteur doit repartir sur des tampons neufs.
        let isFirstOfSession = packetsInSession == 0
        let isSyncDue = packetsInSession % Self.syncInterval == 0
        let timestamp = rtpTimestamp
        let packet = RTPPacketBuilder.audio(
            sequenceNumber: sequenceNumber,
            timestamp: timestamp,
            ssrc: ssrc,
            marker: isFirstOfSession,
            payload: payload
        )
        // Mémorisé avant l'émission : une demande peut arriver avant même que `send` ne rende
        // la main, et un paquet dont l'émission échoue reste récupérable de cette façon.
        retransmitter.record(sequence: sequenceNumber, packet: packet)

        // La position du flux avance **quoi qu'il arrive à l'émission**. Ces échantillons sont
        // consommés et le synchroniseur les a comptés : ne pas avancer ferait partir l'audio
        // suivant sous le numéro et l'estampille de celui-ci, décalant cette sortie de 8 ms sur
        // l'horloge commune à chaque paquet perdu localement. Vu du récepteur, c'est une perte
        // ordinaire, qu'une retransmission répare.
        sequenceNumber &+= 1
        rtpTimestamp &+= UInt32(Self.framesPerPacket)
        packetsInSession += 1

        var failure: Error?
        do {
            let isSimulatedLoss = simulatedLossInterval > 0 && !isFirstOfSession
                && packetsInSession % simulatedLossInterval == 0
            if !isSimulatedLoss { try audio.send(packet) }
            packetsSent += 1
            counters.packetsSent = packetsSent
        } catch {
            failure = error
        }
        if isSyncDue {
            do {
                try sendSync(
                    rtpTimestamp: timestamp, isFirst: isFirstOfSession, anchorUnixTime: anchor
                )
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
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
    private func sendSync(
        rtpTimestamp: UInt32, isFirst: Bool, anchorUnixTime: TimeInterval?
    ) throws {
        guard let control = controlChannel else { return }
        let ntp = anchorUnixTime.map { NTPTime(unixTime: $0) } ?? NTPTime.now()
        let packet = RTPPacketBuilder.sync(
            rtpTimestamp: rtpTimestamp,
            latencyFrames: Self.latencyFrames,
            ntp: ntp,
            isFirst: isFirst
        )
        try control.send(packet)
        counters.syncPacketsSent += 1
        if anchorUnixTime != nil { counters.anchoredSyncPackets += 1 }
    }

    /// Répond aux requêtes d'horloge du récepteur **et** en tire la mesure de décalage.
    ///
    /// Double rôle, et c'est le cœur du jalon 4 côté AirPlay 1 :
    /// 1. répondre fidèlement, pour que le récepteur puisse caler son horloge sur la nôtre —
    ///    c'est ce qui rend l'ancrage des annonces de synchro exploitable ;
    /// 2. relever l'estampille d'émission du récepteur, qui donne le décalage entre son
    ///    horloge et la nôtre (voir ``TimingEstimator``) et sert de signal de vie.
    private nonisolated func installTimingResponder(on timing: UDPChannel) {
        timing.onReceive = { [weak self, weak timing] data, _ in
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
            try? timing?.send(response)
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

    /// Branche le répondeur de retransmission sur le canal de contrôle.
    ///
    /// La réponse repart vers **l'expéditeur de la demande**, depuis ce même socket, comme chez
    /// pyatv : c'est le port depuis lequel le récepteur écoute ses retransmissions, pas
    /// nécessairement celui qu'il a annoncé.
    private nonisolated func installRetransmitResponder(on control: UDPChannel) {
        let responder = retransmitter
        control.onReceive = { [weak control] data, source in
            responder.handle(datagram: data) { response in
                try control?.send(response, to: source)
            }
        }
    }

    private func countTimingResponse(at unixTime: TimeInterval) {
        counters.timingResponsesSent += 1
        lastTimingRequestUnix = unixTime
    }

    private func teardown() async {
        stopKeepAlive()
        retransmitter.clear()
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
        receiverSession = nil
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
    /// Demandes de retransmission reçues, paquets renvoyés, paquets réclamés mais plus dans
    /// l'historique, et paquets non renvoyés faute de débit disponible.
    public var retransmitRequests = 0
    public var packetsRetransmitted = 0
    public var retransmitMisses = 0
    public var retransmitsThrottled = 0
    /// Le récepteur a-t-il accepté la sonde de maintien de session (`POST /feedback`) ?
    public var keepAliveSupported = false
    public var keepAlivesSent = 0
    public var keepAliveFailures = 0
    /// Consigne du renfort de basses.
    public var bassBoostDecibels: Float = 0
}

public enum RAOPSenderError: Error, CustomStringConvertible {
    case alacUnsupported(String)
    case encryptionUnsupported(String)
    case ipv4Required(String)

    /// Réessayer sans intervention ne servira à rien.
    ///
    /// Vrai des refus de capacité, annoncés par le récepteur lui-même. Pas de ``ipv4Required`` : une
    /// résolution rendue à l'échéance avec le seul AAAA parce que le A a tardé sur le réseau décrit
    /// un instant, pas l'appareil. Une nouvelle découverte le retrouvera avec son IPv4.
    public var isPermanent: Bool {
        switch self {
        case .alacUnsupported, .encryptionUnsupported: return true
        case .ipv4Required: return false
        }
    }

    public var description: String {
        switch self {
        case let .alacUnsupported(name):
            return "\(name) n'annonce aucun format audio pris en charge (ni PCM ni ALAC)"
        case let .encryptionUnsupported(name):
            return "\(name) exige un chiffrement non pris en charge (ni flux en clair ni RSA-AES)"
        case let .ipv4Required(host):
            return "le récepteur n'a pas d'adresse IPv4 utilisable (\(host)), requise par RAOP"
        }
    }
}
