import Foundation
import Testing

/// `run-mocks.sh stop` sur un faux mock, dans un dossier de journaux à part : ce test ne touche ni
/// aux vrais mocks, ni à leurs fichiers pid. Le script ne vise que le pid qu'on lui donne.
@Suite("run-mocks.sh")
struct RunMocksScriptTests {
    private struct Stopped {
        let output: String
        let mock: Process
        let pidFile: URL
    }

    /// Lance un faux `shairport-sync`, puis demande son arrêt au script.
    ///
    /// - Parameter ignoresTERM: se comporte comme le vrai, bloqué à sa sortie dans
    ///   `activity_monitor_stop` : port fermé, process encore là, à tourner sur un cœur.
    private func stopFakeMock(ignoresTERM: Bool, in folder: URL) async throws -> Stopped {
        let ready = folder.appendingPathComponent("ready")
        let fake = folder.appendingPathComponent("shairport-sync")
        let body = """
            \(ignoresTERM ? "trap '' TERM" : "")
            : > "$1"
            while :; do /bin/sleep 1; done
            """
        try body.write(to: fake, atomically: true, encoding: .utf8)

        let mock = Process()
        mock.executableURL = URL(fileURLWithPath: "/bin/bash")
        mock.arguments = [fake.path, ready.path]
        try mock.run()

        // Attendu, sinon SIGTERM pourrait arriver avant le `trap`.
        let started = await waitUntil { FileManager.default.fileExists(atPath: ready.path) }
        #expect(started)
        let pidFile = folder.appendingPathComponent("shairport-sync.pid")
        try "\(mock.processIdentifier)".write(to: pidFile, atomically: true, encoding: .utf8)

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/bash")
        script.arguments = [repository.appendingPathComponent("run-mocks.sh").path, "stop"]
        script.environment = ProcessInfo.processInfo.environment.merging([
            "MOCK_LOG_DIR": folder.path, "MOCK_STOP_TIMEOUT_SECONDS": "1",
        ]) { $1 }
        let pipe = Pipe()
        script.standardOutput = pipe
        script.standardError = pipe
        try script.run()

        // Hors du pool coopératif : la lecture bloque jusqu'à la fin du script. Elle suffit, la fin de
        // fichier disant que le script a terminé. `waitUntilExit()` en plus de cela a bloqué une
        // exécution à jamais (1 fois sur ~30), le process déjà récolté : cette attente tourne une
        // boucle d'événements qui peut manquer le signal de fin, ici sur un fil sans autre activité.
        let output = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
        return Stopped(output: output, mock: mock, pidFile: pidFile)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-mocks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Sans cela, le script annonçait « arrêté » devant un process toujours vivant, et perdait son
    /// pid : le `start` suivant concluait à « déjà lancé » devant un port fermé.
    @Test("Un mock qui ignore SIGTERM est réellement arrêté, comme le script l'annonce")
    func stuckMockIsKilled() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let stopped = try await stopFakeMock(ignoresTERM: true, in: folder)
        defer { if stopped.mock.isRunning { kill(stopped.mock.processIdentifier, SIGKILL) } }

        #expect(stopped.output.contains("ignore SIGTERM"), "\(stopped.output)")
        #expect(stopped.output.contains("shairport-sync arrêté"), "\(stopped.output)")
        #expect(await waitUntil { !stopped.mock.isRunning }, "\(stopped.output)")
        #expect(!FileManager.default.fileExists(atPath: stopped.pidFile.path))
    }

    @Test("Un mock qui obéit à SIGTERM n'a pas besoin de SIGKILL")
    func wellBehavedMockIsNotKilled() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let stopped = try await stopFakeMock(ignoresTERM: false, in: folder)
        defer { if stopped.mock.isRunning { kill(stopped.mock.processIdentifier, SIGKILL) } }

        #expect(!stopped.output.contains("SIGKILL"), "\(stopped.output)")
        #expect(stopped.output.contains("shairport-sync arrêté"), "\(stopped.output)")
        #expect(await waitUntil { !stopped.mock.isRunning })
    }
}
