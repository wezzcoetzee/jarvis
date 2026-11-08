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
    /// The same overrides the CLI reads (src/config.ts), so the Dock and the CLI agree on where
    /// things are. `JARVIS_DOWNLOADS` is the Dock's own, for screenshots.
    private static func folder(_ variable: String, default path: String) -> URL {
        let value = ProcessInfo.processInfo.environment[variable] ?? path
        return URL(filePath: value.hasPrefix("~/") ? NSHomeDirectory() + value.dropFirst(1) : value)
    }
    static let configDir = folder("JARVIS_CONFIG", default: "~/.config/jarvis")
    static let stateDir = folder("JARVIS_STATE", default: "~/.local/share/jarvis")
    static let pendingDir = stateDir.appending(path: "pending")
    static let downloadsDir = folder("JARVIS_DOWNLOADS", default: "~/Downloads")
    /// Obsidian names a vault after its folder: `JARVIS_VAULT`, or the `vault` path in config.json.
    static let vaultName: String = {
        if let path = ProcessInfo.processInfo.environment["JARVIS_VAULT"] { return URL(filePath: path).lastPathComponent }
        let config = configDir.appending(path: "config.json")
        let json = (try? Data(contentsOf: config)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (json?["vault"] as? String).map { URL(filePath: $0).lastPathComponent } ?? "Vault"
    }()

    struct Failure: LocalizedError {
        let errorDescription: String?
        /// The CLI's `detail:` line, the raw cause behind the plain message.
        var detail: String?
    }

    /// Cancelling the calling Task terminates the process, so superseded searches stop.
    /// `onStep` gets each `step: ...` line the CLI prints while it works, on the main thread.
    /// `timeout` stops a write that's stuck (usually on a macOS prompt about the vault's cloud
    /// folder), so it fails where you can see it instead of holding up every write after it.
    static func run(_ args: [String], input: String? = nil, timeout: TimeInterval? = nil, onStep: (@MainActor (String) -> Void)? = nil) async throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: command[0])
        process.arguments = Array(command.dropFirst()) + args
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // The pipe reads block, so keep them off Swift's cooperative thread pool.
                DispatchQueue.global().async {
                    continuation.resume(with: Result { try collect(process, input: input, timeout: timeout, onStep: onStep) })
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private static func collect(_ process: Process, input: String?, timeout: TimeInterval?, onStep: (@MainActor (String) -> Void)?) throws -> Data {
        let started = Date()
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

        // Stopped by the timeout, not by a cancelled search.
        if process.terminationReason == .uncaughtSignal, let timeout, Date().timeIntervalSince(started) >= timeout {
            throw Failure(errorDescription: "Took too long", detail: "Check for a macOS prompt about your vault's folder; it may be on another display")
        }
        guard process.terminationStatus == 0 else {
            // The CLI reports failures as an `error: ...` line, and maybe a `detail: ...` line.
            let lines = String(decoding: errors, as: UTF8.self).split(separator: "\n")
            let line = { (prefix: String) in lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } }
            throw Failure(errorDescription: line("error: ") ?? "Jarvis stopped before it finished", detail: line("detail: "))
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

    /// What the Dock calls it: a daily note by its day ("Today's note"), anything else by its title.
    var name: String {
        let base = URL(filePath: path).deletingPathExtension().lastPathComponent
        return Day.name(base) == nil ? title : Day.note(path).capitalizedFirst
    }
    /// The folder it's in, to tell apart notes with the same name. Empty at the vault's root.
    var folder: String { path.split(separator: "/").dropLast().last.map(String.init) ?? "" }
}

/// Daily notes and meetings are named by date. The Dock says the day instead, one way
/// everywhere: "Today", "Yesterday" or "Sun, 8 Nov".
enum Day {
    private static let iso = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()

    static func name(_ text: String) -> String? {
        guard text.count == 10, let date = try? iso.parse(text) else { return nil }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// A note path in a sentence: "today's note", "Sun, 8 Nov", or "Garden shed".
    static func note(_ path: String) -> String {
        let base = URL(filePath: path).deletingPathExtension().lastPathComponent
        return spoken(base) ?? base
    }

    /// Dates inside text from the CLI ("Reading 2026-11-08") said the same way. Only a date that
    /// is a whole name: a recording's "2026-10-29 1057 Slack Huddle" keeps its date.
    static func inline(_ text: String) -> String {
        text.replacing(#/\d{4}-\d{2}-\d{2}(?! \d)/#) { spoken(String($0.output)) ?? String($0.output) }
    }

    private static func spoken(_ iso: String) -> String? {
        switch name(iso) {
        case "Today": "today's note"
        case "Yesterday": "yesterday's note"
        case let day: day
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// What `jarvis ask` prints when Claude is done.
struct AskResult: Decodable {
    enum Kind: String, Decodable { case saved, found, answer, question }

    let runId: String
    let kind: Kind
    let message: String
    /// For found: the words to search Obsidian for, rather than the sentence you typed.
    let search: String?
    let detail: String
    let notes: [Note]
    /// A note Claude opened because the full answer was too long for the bubble.
    let open: String?
    let changed: [String]
}

/// One request typed into the box, from Enter until it's dismissed, or a failure to show.
struct Activity: Identifiable {
    enum State {
        case running
        case done(AskResult)
        case failed(String)
    }

    /// What made it, and so what Try again repeats.
    enum Origin {
        /// ⏎: Claude.
        case ask
        /// ⌘⏎: straight to the Inbox.
        case inbox
        /// Something else failed (an undo, a meeting save); there's nothing to try again.
        case notice
    }

    enum Primary { case reply, retry, open, dismiss }

    let id = UUID()
    let text: String
    var origin = Origin.ask
    /// The CLI's own words for a failure, under the plain headline.
    var detail: String?
    /// Nothing went wrong, it just didn't happen (an undo that left your newer edits alone),
    /// so it isn't shown in red.
    var neutral = false
    let started = Date()
    var state = State.running
    /// What Claude is doing right now ("Reading today's note"), while it's running.
    var step: String?

    var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    var isFailed: Bool {
        if case .failed = state { true } else { false }
    }

    /// The bubble's white button, which ⏎ also presses.
    var primary: Primary {
        switch state {
        case .failed: origin == .notice ? .dismiss : .retry
        case .done(let result) where result.kind == .question: .reply
        case .done(let result) where result.open != nil: .open
        default: .dismiss
        }
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

    var meetingDay: String { Day.name(meetingDate) ?? meetingDate }
}

/// One editable row of a queued prompt. Serialises to the CLI's draft line format.
struct DraftLine: Identifiable {
    enum Kind { case todo, decision }

    let id = UUID()
    var kind: Kind
    var text: String
    var included: Bool
    var alreadyTracked = false

    /// Where the line goes when you save.
    var label: String { alreadyTracked ? "Already listed" : destination }
    /// Where it's written if you include it: todos go to today's note (even an already-listed
    /// one), decisions to the Work Log.
    var destination: String { kind == .todo ? "Today's note" : "Work Log" }
    /// One line of the CLI's draft format, so a pasted line break can't split it into more.
    var serialized: String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return kind == .todo ? "[ ] \(line)" : "decision: \(line)"
    }

    /// A new one each time: every line needs its own id.
    static var blank: DraftLine { DraftLine(kind: .todo, text: "", included: true) }

    /// In the CLI's draft order (src/review.ts): new todos, decisions, then what's already listed.
    /// A prompt with nothing proposed still asks, with one empty line to type into.
    static func lines(for pending: Pending) -> [DraftLine] {
        let followUps = pending.proposal.followUps
        let todo = { (f: Pending.Proposal.FollowUp) in
            DraftLine(kind: .todo, text: f.task, included: !f.alreadyTracked, alreadyTracked: f.alreadyTracked)
        }
        let lines = followUps.filter { !$0.alreadyTracked }.map(todo)
            + pending.proposal.decisions.map { DraftLine(kind: .decision, text: $0, included: true) }
            + followUps.filter(\.alreadyTracked).map(todo)
        return lines.isEmpty ? [blank] : lines
    }
}
