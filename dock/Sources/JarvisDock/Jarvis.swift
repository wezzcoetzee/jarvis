import Foundation

/// Bridge to the Bun CLI in this repo. Vault logic lives there so the Dock stays a thin UI.
enum Jarvis {
    /// The repo this binary was built from (dock/Sources/JarvisDock/Jarvis.swift → repo root). Only used in development.
    static let repo = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    /// The CLI: compiled into Jarvis.app by scripts/package.sh, or bun plus src/main.ts when run from the repo.
    static let command: [String] = {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "jarvis-cli") { return [bundled.path] }
        let bun = ProcessInfo.processInfo.environment["JARVIS_BUN"] ?? "\(NSHomeDirectory())/.bun/bin/bun"
        return [bun, repo.appending(path: "src/main.ts").path]
    }()
    /// Obsidian names a vault after its folder: the `vault` path in ~/.config/jarvis/config.json.
    static let vaultName: String = {
        if let path = ProcessInfo.processInfo.environment["JARVIS_VAULT"] { return URL(filePath: path).lastPathComponent }
        let config = URL(filePath: NSHomeDirectory()).appending(path: ".config/jarvis/config.json")
        let json = (try? Data(contentsOf: config)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (json?["vault"] as? String).map { URL(filePath: $0).lastPathComponent } ?? "Vault"
    }()
    static let stateDir = ProcessInfo.processInfo.environment["JARVIS_STATE"].map { URL(filePath: $0) }
        ?? URL(filePath: NSHomeDirectory()).appending(path: ".local/share/jarvis")
    static let pendingDir = stateDir.appending(path: "pending")

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Cancelling the calling Task terminates the process, so superseded searches stop.
    /// `onStep` gets each `step: ...` line the CLI prints while it works, on the main thread.
    static func run(_ args: [String], input: String? = nil, onStep: (@MainActor (String) -> Void)? = nil) async throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: command[0])
        process.arguments = Array(command.dropFirst()) + args
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // The pipe reads block, so keep them off Swift's cooperative thread pool.
                DispatchQueue.global().async {
                    continuation.resume(with: Result { try collect(process, input: input, onStep: onStep) })
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private static func collect(_ process: Process, input: String?, onStep: (@MainActor (String) -> Void)?) throws -> Data {
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin
        try process.run()

        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()

        // stderr is read as it arrives, on its own thread, so steps show up while stdout waits.
        var errors = Data()
        let stderrDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var pending = Data()
            while case let chunk = err.fileHandleForReading.availableData, !chunk.isEmpty {
                errors.append(chunk)
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                    pending.removeSubrange(...newline)
                    if line.hasPrefix("step: "), let onStep {
                        let step = String(line.dropFirst(6))
                        DispatchQueue.main.async { MainActor.assumeIsolated { onStep(step) } }
                    }
                }
            }
            stderrDone.signal()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        stderrDone.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            // The CLI reports failures as one `error: ...` line.
            let lines = String(decoding: errors, as: UTF8.self).split(separator: "\n")
            let message = lines.first { $0.hasPrefix("error: ") }.map { String($0.dropFirst(7)) }
            throw Failure(errorDescription: message ?? "jarvis exited \(process.terminationStatus)")
        }
        return data
    }
}

/// A vault note, from `search` (with a snippet) or from an `ask` result.
struct Note: Decodable, Identifiable {
    let path: String
    let title: String
    var snippet: String?
    var id: String { path }
}

/// What `jarvis ask` prints when Claude is done.
struct AskResult: Decodable {
    enum Kind: String, Decodable { case saved, found, answer, question }

    let runId: String
    let kind: Kind
    let message: String
    let detail: String
    let notes: [Note]
    /// A note Claude opened because the full answer was too long for the bubble.
    let open: String?
    let changed: [String]
}

/// One request typed into the box, from Enter until it's dismissed.
struct Activity: Identifiable {
    enum State {
        case running
        case done(AskResult)
        case failed(String)
        case undone
    }

    let id = UUID()
    let text: String
    let started = Date()
    var state = State.running
    /// What Claude is doing right now ("Reading 2026-10-29"), while it's running.
    var step: String?

    var isRunning: Bool {
        if case .running = state { true } else { false }
    }
}

struct Pending: Decodable, Identifiable {
    struct Proposal: Decodable {
        struct FollowUp: Decodable {
            let task: String
            let alreadyTracked: Bool
        }

        let title: String
        let followUps: [FollowUp]
        let decisions: [String]
    }

    let noteName: String
    let meetingDate: String
    let proposal: Proposal
    var id: String { noteName }
}

/// One editable row of a queued prompt. Serialises to the CLI's draft line format.
struct DraftLine: Identifiable {
    enum Kind { case todo, decision }

    let id = UUID()
    var kind: Kind
    var text: String
    var included: Bool
    var alreadyTracked = false

    var label: String { alreadyTracked ? "already listed" : kind == .todo ? "todo" : "work log" }
    var serialized: String { kind == .todo ? "[ ] \(text)" : "decision: \(text)" }

    static let blank = DraftLine(kind: .todo, text: "", included: true)

    /// A prompt with nothing proposed still asks, with one empty line to type into.
    static func lines(for pending: Pending) -> [DraftLine] {
        let lines = pending.proposal.followUps.map {
            DraftLine(kind: .todo, text: $0.task, included: !$0.alreadyTracked, alreadyTracked: $0.alreadyTracked)
        } + pending.proposal.decisions.map { DraftLine(kind: .decision, text: $0, included: true) }
        return lines.isEmpty ? [blank] : lines
    }
}
