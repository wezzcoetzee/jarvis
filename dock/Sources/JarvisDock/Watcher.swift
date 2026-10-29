import Foundation

/// Runs `jarvis watch` for as long as Jarvis is open, and restarts it if it dies, so there's no
/// separate login item for meetings. The CLI exits on its own if Jarvis goes away without
/// stopping it (see `watch` in src/main.ts).
@MainActor
final class Watcher {
    private var process: Process?
    private var stopping = false
    private let log = Jarvis.stateDir.appending(path: "watch.log")

    func start() {
        stopping = false
        launch()
    }

    func stop() {
        stopping = true
        process?.terminate()
    }

    private func launch() {
        guard !stopping else { return }
        let process = Process()
        process.executableURL = URL(filePath: Jarvis.command[0])
        process.arguments = Array(Jarvis.command.dropFirst()) + ["watch"]
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let output = try? FileHandle(forWritingTo: log) {
            output.seekToEndOfFile()
            process.standardOutput = output
            process.standardError = output
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                MainActor.assumeIsolated { self?.launch() }
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            NSLog("Jarvis: couldn't start the meeting watcher: \(error)")
        }
    }
}
