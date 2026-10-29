import AppKit
import Observation

/// A card you opened above the Dock. Answers aren't cards: they bubble up on their own.
enum Card: Equatable {
    case meeting
}

@MainActor @Observable
final class DockModel {
    var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    private(set) var hits: [Note] = [] {
        // Results arrive after the keystroke that asked for them; keep the selection on a real row.
        didSet { selection = min(selection, rowCount - 1) }
    }
    /// 0 = ask Jarvis, 1 = add to Inbox as is, then search hits, then "search Obsidian".
    var selection = 0
    var isTyping = false
    private(set) var flash: String?
    private(set) var pending: [Pending] = []
    var lines: [DraftLine] = []
    private(set) var activities: [Activity] = []
    private(set) var card: Card?
    private(set) var captureFocus = 0
    private(set) var promptFocus = 0
    /// Bumped on every save, to bounce the Obsidian icon.
    private(set) var bounce = 0
    /// Bumped when something new needs your attention, so an auto-hidden Dock shows itself.
    private(set) var attention = 0

    /// The panel has to be key before a field inside it can take typing.
    @ObservationIgnored var onNeedsKey: () -> Void = {}
    /// Called when you're done, so focus goes back to your app and an auto-hidden Dock can hide.
    @ObservationIgnored var onFinish: () -> Void = {}
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var writes: Task<Void, Never>?
    /// Prompts being saved or skipped: already gone from the UI, still on disk until the CLI finishes.
    @ObservationIgnored private var resolving: Set<String> = []
    @ObservationIgnored private var pendingWatcher: DispatchSourceFileSystemObject?

    var reviewing: Pending? { pending.first }
    var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    var showsSheet: Bool { isTyping && !trimmedQuery.isEmpty && card == nil }
    /// Requests Claude is still working on, shown as a timer in the box.
    var working: [Activity] { activities.filter(\.isRunning) }
    /// Finished requests, oldest first. The bubble shows the first; the rest wait their turn.
    var answers: [Activity] { activities.filter { !$0.isRunning } }
    var bubble: Activity? { card == nil && !showsSheet ? answers.first : nil }
    /// While true, an auto-hidden Dock stays up: typing, a card open, Claude still working, or
    /// an answer waiting to be read.
    var holdsOpen: Bool { isTyping || card != nil || !activities.isEmpty }
    var searchRow: Int { 2 + hits.count }
    private var rowCount: Int { searchRow + 1 }

    func start() {
        let dir = Jarvis.pendingDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reloadPending() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        pendingWatcher = source
        reloadPending()
    }

    func requestFocus() {
        onNeedsKey()
        isTyping = true
        captureFocus += 1
    }

    func open(_ card: Card) {
        self.card = card
        onNeedsKey()
        if card == .meeting { promptFocus += 1 }
    }

    func closeCard() {
        card = nil
        onFinish()
    }

    /// You clicked into another app: put the box and any open card away, like the Dock would.
    func lostFocus() {
        isTyping = false
        card = nil
    }

    /// A click anywhere outside the Dock puts the current answer away, like a popover.
    func clickedAway() {
        if let bubble { dismiss(bubble.id) }
    }

    // MARK: The box

    func move(_ delta: Int) {
        selection = (selection + delta + rowCount) % rowCount
    }

    func submit(command: Bool) {
        let text = trimmedQuery
        guard !text.isEmpty else { return }
        let row = command ? 1 : selection
        switch row {
        case 0: ask(text)
        case 1: addToInbox(text)
        case searchRow:
            openSearch(text)
            reset()
        default:
            guard hits.indices.contains(row - 2) else { return }
            open(hits[row - 2])
            reset()
        }
    }

    func cancel() {
        if query.isEmpty { reset() } else { query = "" }
    }

    func open(_ note: Note) {
        openObsidian("open", ["vault": Jarvis.vaultName, "file": note.path])
    }

    func openSearch(_ text: String) {
        openObsidian("search", ["vault": Jarvis.vaultName, "query": text])
    }

    private func openObsidian(_ action: String, _ params: KeyValuePairs<String, String>) {
        // URLComponents leaves `&` unescaped in query values, and note names can contain it.
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+="))
        let query = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
        if let url = URL(string: "obsidian://\(action)?\(query.joined(separator: "&"))") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Hands the text to Claude with the vault's own skills. While it works the box shows a timer,
    /// and the answer bubbles up out of the box when it's done.
    func ask(_ text: String) {
        let app = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0.localizedName } ?? ""
        let activity = Activity(text: text)
        activities.append(activity)
        reset()
        Task {
            do {
                let data = try await Jarvis.run(["ask", "--app=\(app)", "--", text]) { step in
                    self.update(activity.id) { $0.step = step }
                }
                let result = try JSONDecoder().decode(AskResult.self, from: data)
                update(activity.id) { $0.state = .done(result) }
                // Too long for the bubble: Claude names the note that holds it, and it opens.
                if let path = result.open { open(Note(path: path, title: path)) }
                if result.kind == .saved {
                    bounce += 1
                    dismiss(activity.id, after: 8)
                }
            } catch {
                update(activity.id) { $0.state = .failed(error.localizedDescription) }
            }
            attention += 1
        }
    }

    func undo(_ id: Activity.ID) {
        guard let activity = activities.first(where: { $0.id == id }), case .done(let result) = activity.state else { return }
        serialized { [self] in
            do {
                struct Undone: Decodable { let skipped: [String] }
                let data = try await Jarvis.run(["undo", "--", result.runId])
                let undone = try JSONDecoder().decode(Undone.self, from: data)
                update(id) { $0.state = .undone }
                if !undone.skipped.isEmpty { show("Left \(undone.skipped.joined(separator: ", ")) alone: edited since") }
                dismiss(id, after: 3)
            } catch {
                show("couldn't undo: \(error.localizedDescription)")
            }
        }
    }

    func dismiss(_ id: Activity.ID) {
        activities.removeAll { $0.id == id }
        if answers.isEmpty { onFinish() }
    }

    func retry(_ id: Activity.ID) {
        guard let activity = activities.first(where: { $0.id == id }) else { return }
        dismiss(id)
        ask(activity.text)
    }

    /// Saves confirm and go. Only counts from when the bubble is actually on screen, so a save
    /// queued behind another answer still gets its moment.
    private func dismiss(_ id: Activity.ID, after seconds: Double) {
        Task {
            while bubble?.id != id, activities.contains(where: { $0.id == id }) { try? await Task.sleep(for: .seconds(1)) }
            try? await Task.sleep(for: .seconds(seconds))
            if activities.contains(where: { $0.id == id }) { dismiss(id) }
        }
    }

    private func update(_ id: Activity.ID, _ change: (inout Activity) -> Void) {
        if let index = activities.firstIndex(where: { $0.id == id }) { change(&activities[index]) }
    }

    private func addToInbox(_ text: String) {
        reset()
        serialized { [self] in
            do {
                _ = try await Jarvis.run(["capture", "--inbox", "--", text])
                bounce += 1
                show("Added to Inbox")
            } catch {
                // The failure bubble keeps the text, so a failed save never loses the thought.
                var failed = Activity(text: text)
                failed.state = .failed(error.localizedDescription)
                activities.append(failed)
                attention += 1
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        selection = 0
        let query = trimmedQuery
        guard !query.isEmpty else {
            hits = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled,
                  let data = try? await Jarvis.run(["search", "--", query]),
                  let hits = try? JSONDecoder().decode([Note].self, from: data),
                  !Task.isCancelled else { return }
            self.hits = Array(hits.prefix(3))
        }
    }

    private func reset() {
        query = ""
        hits = []
        selection = 0
        isTyping = false
        onFinish()
    }

    /// The CLI edits notes by read-modify-write, so vault writes from the Dock run one at a time.
    private func serialized(_ operation: @escaping @MainActor () async -> Void) {
        let previous = writes
        writes = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    // MARK: Meeting prompts

    func addLine() {
        lines.append(.blank)
    }

    /// Takes the prompt's id so a double-fired shortcut can't save the next prompt too.
    func savePrompt(_ id: Pending.ID) {
        let text = lines
            .filter { $0.included && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(\.serialized)
            .joined(separator: "\n")
        resolve(id, args: [], input: text, done: "Saved")
    }

    func skipPrompt(_ id: Pending.ID) {
        resolve(id, args: ["--skip"], input: nil, done: "Skipped")
    }

    private func resolve(_ id: Pending.ID, args: [String], input: String?, done: String) {
        guard let current = reviewing, current.id == id else { return }
        resolving.insert(id)
        pending.removeFirst()
        lines = reviewing.map(DraftLine.lines(for:)) ?? []
        if reviewing == nil { closeCard() } else { promptFocus += 1 }

        serialized { [self] in
            do {
                _ = try await Jarvis.run(["resolve"] + args + ["--", current.noteName], input: input)
                if args.isEmpty { bounce += 1 }
                show("\(done) \(current.proposal.title)")
            } catch {
                // Writes are planned before any commit, so a failure leaves nothing half-saved to retry over.
                show("couldn't save: \(error.localizedDescription)")
            }
            resolving.remove(id)
            reloadPending()
        }
    }

    private func reloadPending() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Jarvis.pendingDir, includingPropertiesForKeys: nil)) ?? []
        let loaded = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Pending.self, from: Data(contentsOf: $0)) }
            .filter { !resolving.contains($0.id) }
            .sorted { $0.noteName < $1.noteName }
        let arrived = Set(loaded.map(\.id)).subtracting(pending.map(\.id))
        let firstChanged = loaded.first?.id != pending.first?.id
        pending = loaded
        if firstChanged { lines = reviewing.map(DraftLine.lines(for:)) ?? [] }
        if card == .meeting, pending.isEmpty { closeCard() }
        if !arrived.isEmpty { attention += 1 }
    }

    private func show(_ message: String) {
        flash = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if flash == message { flash = nil }
        }
    }
}
