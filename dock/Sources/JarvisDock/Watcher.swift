import Foundation

/// Runs `jarvis watch` for as long as Jarvis is open, and restarts it if it dies, so there's no
/// separate login item for meetings. The CLI exits on its own if Jarvis goes away without
/// stopping it (see `watch` in src/main.ts).
///
/// A watcher that keeps dying means meeting prompts have stopped. `onProblem` hears why, in the
/// CLI's own words, so the Dock can say "Meetings paused"; and hears nil once a run has stayed
/// up long enough to count as working again.
@MainActor
final class Watcher {
    var onProblem: (String?) -> Void = { _ in }
    private var process: Process?
    private var stopping = false
    private var relaunch: DispatchWorkItem?
    private var restarting = false
    private var logStart: UInt64 = 0
    private var launchedAt = Date.distantPast
    private var stallCheck: Timer?
    private var stalled = false
    /// A running watcher that hasn't touched its heartbeat (src/state.ts) for this long is stuck,
    /// usually on a macOS prompt about a cloud folder. Long enough that a slow draft isn't one.
    private static let stall: TimeInterval = 5 * 60
    private static let heartbeat = Jarvis.stateDir.appending(path: "watch-heartbeat")
    /// A run that's still going after this long is working.
    private static let healthy: TimeInterval = 10
    private static let retryDelay: TimeInterval = 5

    /// Safe to call again: first run calls it once a vault is chosen.
    func start() {
        guard process == nil, relaunch == nil else { return }
        stopping = false
        // Once a minute is plenty to notice a five-minute stall; it draws nothing.
        stallCheck = stallCheck ?? Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStall() }
        }
        launch()
    }

    func stop() {
        stopping = true
        stallCheck?.invalidate()
        relaunch?.cancel()
        process?.terminate()
    }

    /// A fresh run, now: Settings changed the vault or meetings folder, or Try again on
    /// "Meetings paused", whether the watcher had died or is stuck.
    func restart() {
        guard !stopping else { return }
        relaunch?.cancel()
        relaunch = nil
        if let process {
            restarting = true
            process.terminate()
        } else {
            launch()
        }
    }

    private func launch() {
        guard !stopping else { return }
        relaunch = nil
        let log = Jarvis.watchLog
        let process = Process()
        process.executableURL = URL(filePath: Jarvis.command[0])
        process.arguments = Array(Jarvis.command.dropFirst()) + ["watch"]
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let output = try? FileHandle(forWritingTo: log) {
            // Where this run's output starts, so its error is never an older run's.
            logStart = output.seekToEndOfFile()
            process.standardOutput = output
            process.standardError = output
        }
        process.terminationHandler = { [weak self] ended in
            let failed = ended.terminationStatus != 0
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(ended, failed: failed) } }
        }
        do {
            try process.run()
            self.process = process
            launchedAt = Date()
            stalled = false
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.healthy) { [weak self, weak process] in
                MainActor.assumeIsolated {
                    guard let self, let process, process.isRunning, self.process === process else { return }
                    self.onProblem(nil)
                }
            }
        } catch {
            NSLog("Jarvis: couldn't start the meeting watcher: \(error)")
            onProblem("Couldn't start the meeting watcher: \(error.localizedDescription)")
            scheduleRelaunch()
        }
    }

    private func ended(_ ended: Process, failed: Bool) {
        guard process === ended else { return }
        process = nil
        guard !stopping else { return }
        // Stopped on purpose for new settings, so not a failure.
        if restarting {
            restarting = false
            return launch()
        }
        if failed { onProblem(lastError() ?? "The meeting watcher keeps stopping") }
        scheduleRelaunch()
    }

    private func scheduleRelaunch() {
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.launch() } }
        relaunch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay, execute: work)
    }

    private func checkStall() {
        guard let process, process.isRunning, Date().timeIntervalSince(launchedAt) > Self.stall else { return }
        let beat = (try? FileManager.default.attributesOfItem(atPath: Self.heartbeat.path)[.modificationDate]) as? Date ?? .distantPast
        let stuck = Date().timeIntervalSince(beat) > Self.stall
        guard stuck != stalled else { return }
        stalled = stuck
        onProblem(stuck ? "Meetings haven't been checked for a few minutes. Look for a macOS prompt about your vault's folder; it may be on another display." : nil)
    }

    /// The last `error:` line the run that just ended wrote: the CLI's one line on what went wrong.
    private func lastError() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: Jarvis.watchLog) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: max(logStart, end > 4096 ? end - 4096 : 0))
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        return tail.split(separator: "\n").last { $0.hasPrefix("error: ") }.map { String($0.dropFirst(7)) }
    }
}
