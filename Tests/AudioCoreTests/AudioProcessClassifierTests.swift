import CoreAudio
import Foundation
import Testing

@testable import AudioCore

/// Ce qui compte comme une application qui joue, pour diagnostiquer un silence strict.
///
/// Les processus sont décrits par leur chemin, dans une arborescence factice : seuls les Info.plist
/// des applications y sont écrits, rien n'est lancé. Les chemins reprennent le relevé
/// `audiocap --list` du 2026-11-09.
@Suite("Capture : un flux ouvert ne fait pas une application qui joue")
struct AudioProcessClassifierTests {
    /// Une arborescence de paquets dans un dossier temporaire, effacée à la fin du test.
    final class FakeVolume {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("apb-classifier-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// Écrit l'Info.plist de l'application `relative` et rend le chemin de `executable`, qui
        /// peut être un auxiliaire logé plus profond.
        func application(
            _ relative: String, info: [String: Any] = [:], executable: String
        ) throws -> String {
            let contents = root.appendingPathComponent(relative).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: info.merging(["CFBundlePackageType": "APPL"]) { $1 },
                format: .xml, options: 0
            )
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return path(executable)
        }

        func path(_ relative: String) -> String { root.appendingPathComponent(relative).path }
    }

    static func process(_ bundleID: String, path: String?, pid: pid_t = 1_000) -> AudioProcessInfo {
        AudioProcessInfo(
            id: AudioObjectID(pid), pid: pid, bundleID: bundleID, isPlaying: true,
            executablePath: path
        )
    }

    /// Les faux joueurs relevés : un démon système, l'interpréteur des mocks, un outil, un agent de
    /// la barre des menus.
    static func falsePlayers(on volume: FakeVolume) throws -> [AudioProcessInfo] {
        // Un `Python.app` d'apparence ordinaire : seul le cadriciel qui le loge l'écarte.
        let python = try volume.application(
            "opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/"
                + "Resources/Python.app",
            executable: "opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/"
                + "Versions/3.14/Resources/Python.app/Contents/MacOS/Python"
        )
        let agent = try volume.application(
            "System/Library/CoreServices/ControlCenter.app", info: ["LSUIElement": true],
            executable: "System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"
        )
        return [
            process(
                "com.apple.CoreSpeech",
                path: volume.path("System/Library/PrivateFrameworks/CoreSpeech.framework/corespeechd"),
                pid: 1_023
            ),
            process("org.python.python", path: python, pid: 17_420),
            process("", path: volume.path("usr/bin/afplay"), pid: 2_001),
            process("com.apple.controlcenter", path: agent, pid: 1_292),
            // Processus disparu entre la liste et la lecture de son chemin.
            process("", path: nil, pid: 2_002),
        ]
    }

    /// Le défaut corrigé : un démon et des `python` au flux ouvert et muet faisaient diagnostiquer
    /// « SILENCE STRICT alors qu'une application joue — autorisation perdue ? ».
    @Test("Des démons et des outils au flux ouvert : aucune application ne joue, et non « inconnu »")
    func falsePlayersMeanNothingPlaying() async throws {
        let volume = try FakeVolume()
        let expected = ProcessTapCapture.isAudioExpected(
            mode: .globalExcluding(pids: []), playing: try Self.falsePlayers(on: volume),
            ownPID: 1, classifier: BundleLocationClassifier()
        )
        #expect(expected == false)

        // Jusqu'au diagnostic du moteur, sans tap : la source rend ce qu'aurait rendu le tap.
        let source = ManualCaptureSource()
        source.expectation = expected
        let engine = makeEngine(source: source, factory: FakeSenderFactory())
        try await engine.start(
            source: .tone(frequency: 440, levelDBFS: -50), outputs: [request("a")]
        )
        source.pushSilence(frames: 48_000 * 4)
        await engine.tickHealth(now: Date())
        #expect(await engine.captureHealth.diagnosis == .silentNothingPlaying)
        await engine.stop()
    }

    /// Le vrai cas, à ne pas perdre : une application de l'utilisateur joue, la capture reste muette.
    @Test("Une application de l'utilisateur parmi eux : le silence redevient suspect")
    func userApplicationAmongFalsePlayers() throws {
        let volume = try FakeVolume()
        let music = try volume.application(
            "System/Applications/Music.app",
            executable: "System/Applications/Music.app/Contents/MacOS/Music"
        )
        let expected = ProcessTapCapture.isAudioExpected(
            mode: .globalExcluding(pids: []),
            playing: try Self.falsePlayers(on: volume) + [Self.process("com.apple.Music", path: music)],
            ownPID: 1, classifier: BundleLocationClassifier()
        )
        #expect(expected)
    }

    @Test("Notre propre processus et les processus exclus ne comptent pas, même applications")
    func ownAndExcludedProcessesDoNotCount() throws {
        let volume = try FakeVolume()
        let music = try volume.application(
            "System/Applications/Music.app",
            executable: "System/Applications/Music.app/Contents/MacOS/Music"
        )
        let own = Self.process("com.apple.Music", path: music, pid: 42)
        let excluded = Self.process("com.apple.Music", path: music, pid: 43)
        #expect(!ProcessTapCapture.isAudioExpected(
            mode: .globalExcluding(pids: [43]), playing: [own, excluded], ownPID: 42,
            classifier: BundleLocationClassifier()
        ))
    }

    /// L'utilisateur a désigné ces processus : leur nature n'entre pas en compte.
    @Test("En mode application, un processus désigné compte tel quel")
    func chosenProcessesCountAsIs() throws {
        let volume = try FakeVolume()
        let python = try #require(
            try Self.falsePlayers(on: volume).first { $0.bundleID == "org.python.python" }
        )
        #expect(ProcessTapCapture.isAudioExpected(
            mode: .processes(pids: [python.pid]), playing: [python], ownPID: 1,
            classifier: BundleLocationClassifier()
        ))
    }

    @Test("Un navigateur joue depuis un auxiliaire invisible : c'est l'application qui le loge qui compte")
    func browserHelpersCount() throws {
        let volume = try FakeVolume()
        let helperApp = "Applications/Dia.app/Contents/Frameworks/ArcCore.framework/Helpers/"
            + "Browser Helper (Aperitif).app"
        _ = try volume.application(helperApp, info: ["LSUIElement": true], executable: "")
        let helper = try volume.application(
            "Applications/Dia.app",
            executable: helperApp + "/Contents/MacOS/Browser Helper (Aperitif)"
        )
        // Chrome loge ses auxiliaires sous un dossier de version qui porte des points.
        let chrome = try volume.application(
            "Applications/Google Chrome.app",
            executable: "Applications/Google Chrome.app/Contents/Frameworks/"
                + "Google Chrome Framework.framework/Versions/157.0.8103.38/Helpers/"
                + "Google Chrome Helper (Aperitif).app/Contents/MacOS/Google Chrome Helper (Aperitif)"
        )
        let classifier = BundleLocationClassifier()
        #expect(classifier.isUserApplication(
            Self.process("company.thebrowser.browser.helper", path: helper)
        ))
        #expect(classifier.isUserApplication(Self.process("com.google.Chrome.helper", path: chrome)))
    }

    /// Safari joue depuis un service XPC de WebKit, que rien ne rattache à Safari.
    @Test("Le processus média de WebKit compte comme l'application qui affiche la page")
    func webKitMediaProcessCounts() {
        let gpu = Self.process(
            "com.apple.WebKit.GPU",
            path: "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/"
                + "Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
        )
        #expect(BundleLocationClassifier().isUserApplication(gpu))
    }

    @Test("LSUIElement et LSBackgroundOnly écartent une application, sous toutes leurs écritures")
    func agentFlagsInEveryForm() throws {
        let volume = try FakeVolume()
        let classifier = BundleLocationClassifier()
        let forms: [(String, Any, Bool)] = [
            ("LSUIElement", true, false), ("LSUIElement", "1", false), ("LSUIElement", 1, false),
            ("LSBackgroundOnly", "YES", false), ("LSUIElement", false, true),
            ("LSUIElement", "0", true),
        ]
        for (index, (key, value, counts)) in forms.enumerated() {
            let path = try volume.application(
                "Applications/App\(index).app", info: [key: value],
                executable: "Applications/App\(index).app/Contents/MacOS/App"
            )
            #expect(
                classifier.isUserApplication(Self.process("app\(index)", path: path)) == counts,
                "\(key) = \(value)"
            )
        }
    }

    /// Les chemins réels de cette machine, présents sur tout macOS 27 : aucune arborescence factice.
    @Test("Relevé réel : Musique compte, Centre de contrôle et CoreSpeech non")
    func systemPaths() {
        let classifier = BundleLocationClassifier()
        #expect(classifier.isUserApplication(Self.process(
            "com.apple.Music", path: "/System/Applications/Music.app/Contents/MacOS/Music"
        )))
        #expect(!classifier.isUserApplication(Self.process(
            "com.apple.controlcenter",
            path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"
        )))
        #expect(!classifier.isUserApplication(Self.process(
            "com.apple.CoreSpeech",
            path: "/System/Library/PrivateFrameworks/CoreSpeech.framework/corespeechd"
        )))
    }

    @Test("Le chemin de l'exécutable se lit pour un autre processus, pas pour un PID inexistant")
    func executablePathLookup() {
        let own = AudioProcessList.executablePath(of: getpid())
        #expect(own.map { FileManager.default.isExecutableFile(atPath: $0) } == true)
        #expect(AudioProcessList.executablePath(of: launchdPID).map { $0.hasSuffix("/launchd") } == true)
        #expect(AudioProcessList.executablePath(of: Int32.max) == nil)
    }

    private let launchdPID: pid_t = 1
}
