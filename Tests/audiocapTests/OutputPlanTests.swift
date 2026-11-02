import AVFoundation
import AudioCore
import Foundation
import Testing

@testable import audiocap

@Suite("CLI : options répétées et sorties")
struct OutputPlanTests {
    @Test("Une option absente, donnée une fois, ou répétée une fois par cible")
    func distributeRule() throws {
        #expect(try RepeatedOption.distribute(
            [Float](), over: 3, default: -20, option: "--volume2", target: "--airplay2"
        ) == [-20, -20, -20])
        #expect(try RepeatedOption.distribute(
            [-12], over: 3, default: -20, option: "--volume2", target: "--airplay2"
        ) == [-12, -12, -12])
        #expect(try RepeatedOption.distribute(
            [-12, -15, -18], over: 3, default: -20, option: "--volume2", target: "--airplay2"
        ) == [-12, -15, -18])
        #expect(throws: CLIUsageError.self) {
            try RepeatedOption.distribute(
                [-12, -15], over: 3, default: -20, option: "--volume2", target: "--airplay2"
            )
        }
        #expect(throws: CLIUsageError.self) {
            try RepeatedOption.distribute(
                [-12], over: 0, default: -20, option: "--volume2", target: "--airplay2"
            )
        }
    }

    /// La mesure à trois enceintes : la Geneva et les deux HomePod du salon.
    @Test("La Geneva et deux HomePod, réglés dans l'ordre des --airplay2")
    func threeSpeakers() throws {
        let plan = try OutputPlan.make(
            raopTarget: "Geneva", raopVolumeDB: -25, raopDelayMs: 4, raopBassDB: 6,
            airplay2Targets: ["Salon", "Salon (2)"],
            airplay2Volumes: [-18, -22], airplay2DelaysMs: [1.5],
            airplay2Credentials: []
        )
        #expect(plan.outputs.map(\.id) == ["raop/Geneva", "airplay2/Salon", "airplay2/Salon (2)"])
        #expect(plan.outputs.map(\.deviceName) == ["Geneva", "Salon", "Salon (2)"])
        #expect(plan.outputs.map(\.volumeDB) == [-25, -18, -22])
        #expect(plan.outputs.map(\.manualDelayMs) == [4, 1.5, 1.5])
        #expect(plan.outputs.map(\.bassBoostDB) == [6, 0, 0])
        #expect(plan.outputs.map(\.proto) == [.raop, .airplay2, .airplay2])
        #expect(plan.outputs.allSatisfy { $0.credentialsPath == nil })
    }

    @Test("Sans option répétée, rien ne change pour une seule sortie AirPlay 2")
    func singleAirPlay2Defaults() throws {
        let plan = try OutputPlan.make(
            raopTarget: nil, raopVolumeDB: -20, raopDelayMs: 0, raopBassDB: nil,
            airplay2Targets: ["ApTV"], airplay2Volumes: [], airplay2DelaysMs: [25],
            airplay2Credentials: ["/chemin/credentials"]
        )
        #expect(plan.outputs.count == 1)
        let output = try #require(plan.outputs.first)
        #expect(output.id == "airplay2/ApTV")
        #expect(output.volumeDB == -20)
        #expect(output.manualDelayMs == 25)
        #expect(output.credentialsPath == "/chemin/credentials")
    }

    @Test("Un même HomePod demandé deux fois, ou --bass sans Geneva, sont refusés")
    func refusals() {
        #expect(throws: CLIUsageError.self) {
            try OutputPlan.make(
                raopTarget: nil, raopVolumeDB: -20, raopDelayMs: 0, raopBassDB: nil,
                airplay2Targets: ["Salon", "salon"], airplay2Volumes: [], airplay2DelaysMs: [],
                airplay2Credentials: []
            )
        }
        #expect(throws: CLIUsageError.self) {
            try OutputPlan.make(
                raopTarget: nil, raopVolumeDB: -20, raopDelayMs: 0, raopBassDB: 3,
                airplay2Targets: ["Salon"], airplay2Volumes: [], airplay2DelaysMs: [],
                airplay2Credentials: []
            )
        }
        #expect(throws: CLIUsageError.self) {
            try OutputPlan.make(
                raopTarget: "Geneva", raopVolumeDB: -20, raopDelayMs: 0, raopBassDB: nil,
                airplay2Targets: ["Salon", "Salon (2)"], airplay2Volumes: [-1, -2, -3],
                airplay2DelaysMs: [], airplay2Credentials: []
            )
        }
        // « Salon » et « Salon (2) » sont deux enceintes distinctes, pas un doublon.
        #expect(throws: Never.self) {
            try OutputPlan.make(
                raopTarget: nil, raopVolumeDB: -20, raopDelayMs: 0, raopBassDB: nil,
                airplay2Targets: ["Salon", "Salon (2)"], airplay2Volumes: [], airplay2DelaysMs: [],
                airplay2Credentials: []
            )
        }
    }
}

@Suite("CLI : JSON de mesure")
struct MeasurementDocumentTests {
    private let timebase = HostTimebase(numer: 125, denom: 3)

    /// Un enregistrement fictif : deux blocs mono datés, le premier à 1 000 s d'horloge hôte.
    private func recorder() throws -> TimedInputRecorder {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        ) else { throw CLIUsageError("format") }
        let recorder = try TimedInputRecorder(sourceFormat: format, anchorIntervalSeconds: 0.01)
        let consumer = recorder.makeConsumer()
        var block = [Float](repeating: 0.5, count: 480)
        let firstTicks = timebase.ticks(fromNanoseconds: 1_000_000_000_000)
        block.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress
                )
            )
            consumer(&list, 480, firstTicks)
            consumer(&list, 480, firstTicks + timebase.ticks(fromNanoseconds: 10_000_000))
        }
        recorder.drain { _ in }
        return recorder
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Le JSON date le premier échantillon et la trame 0 sur la même horloge hôte")
    func documentPublishesHostTimes() throws {
        let recorder = try recorder()
        let mapping = HostClockMapping(timebase: timebase, pairs: [
            WallHostPair(unixTime: 1_762_000_000, hostNanoseconds: 999_000_000_000, uncertaintyNanoseconds: 500),
            WallHostPair(unixTime: 1_762_000_060, hostNanoseconds: 1_059_000_000_000, uncertaintyNanoseconds: 500),
        ])
        let timeline = BridgeEngine.PlaybackTimeline(
            captureSampleRate: 48_000, playoutDelaySeconds: 2,
            frameZeroPresentationUnixTime: 1_762_000_003.5, interruptedSeconds: 0
        )
        let outputs = [
            MeasurementDocument.OutputInfo(
                id: "airplay2/Salon", protocole: "airplay2", nomDemande: "Salon", volumeDb: -20,
                delaiDemandeMs: 0, delaiManuelMs: 0, latenceRecepteurMs: 0, renfortBassesDb: nil,
                etatFinal: "diffusion", paquets: 10
            ),
            MeasurementDocument.OutputInfo(
                id: "raop/Geneva", protocole: "raop", nomDemande: "Geneva", volumeDb: -20,
                delaiDemandeMs: 7, delaiManuelMs: 7.5, latenceRecepteurMs: 92.88,
                renfortBassesDb: 0, etatFinal: "diffusion", paquets: 10
            ),
        ]
        let document = MeasurementDocument.make(
            wavFile: "mesure.wav", recorder: recorder, mapping: mapping,
            latency: InputDeviceCapture.InputLatency(
                deviceName: "Micro", presentationLatencySeconds: 0.001, deviceLatencyFrames: 12,
                safetyOffsetFrames: 24
            ),
            timeline: timeline, timelineChanges: [],
            source: .clicks(levelDBFS: -20), outputs: outputs
        )
        let json = try object(try document.encoded())

        let recording = try #require(json["enregistrement"] as? [String: Any])
        #expect(recording["premier_echantillon_hote_ns"] as? Int64 == 1_000_000_000_000)
        #expect(recording["premier_echantillon_extrapole"] as? Bool == false)
        let anchors = try #require(recording["ancrages"] as? [[Int64]])
        #expect(anchors == [[0, 1_000_000_000_000], [480, 1_000_010_000_000]])
        #expect(recording["trames_ecrites"] as? Int == 960)

        // 3,5 s après le premier relevé, à pente nulle : 999 s + 3,5 s d'horloge hôte.
        let common = try #require(json["horloge_commune"] as? [String: Any])
        #expect(common["trame0_restitution_hote_ns"] as? Int64 == 1_002_500_000_000)
        #expect(common["delai_restitution_s"] as? Double == 2)

        let source = try #require(json["source"] as? [String: Any])
        #expect(source["periode_trames"] as? Int == 96_000)
        #expect(source["repere_toutes_les"] as? Int == 5)
        #expect(source["repere_decalage_trames"] as? Int == 12_000)
        #expect(source["salve_trames"] as? Int == 240)

        // Par sortie : l'horloge commune plus le délai manuel appliqué.
        let sorties = try #require(json["sorties"] as? [[String: Any]])
        #expect(sorties.map { $0["id"] as? String } == ["airplay2/Salon", "raop/Geneva"])
        #expect(sorties[0]["trame0_attendue_hote_ns"] as? Int64 == 1_002_500_000_000)
        #expect(sorties[1]["trame0_attendue_hote_ns"] as? Int64 == 1_002_507_500_000)
        #expect(sorties[1]["latence_recepteur_ms"] as? Double == 92.88)

        let clock = try #require(json["horloge_hote"] as? [String: Any])
        #expect(clock["base_numer"] as? Int == 125)
        #expect((clock["releves"] as? [Any])?.count == 2)
    }

    @Test("Le JSON s'écrit à côté du WAV, sous le même nom")
    func jsonSitsNextToWav() {
        let url = MeasurementRecording.jsonURL(for: URL(fileURLWithPath: "/tmp/mesures/salon.wav"))
        #expect(url.path == "/tmp/mesures/salon.json")
    }
}
