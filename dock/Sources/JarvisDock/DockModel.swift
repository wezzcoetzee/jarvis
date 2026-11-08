import AppKit
import Observation

@MainActor @Observable
final class DockModel {
    var query = "" {
        didSet {
            // Emptying the box ends a reply; the next thing typed is something new.
            if trimmedQuery.isEmpty { replyingTo = nil; editingInbox = false } else { cleared = nil }
            if query != oldValue { scheduleSearch() }
        }
    }
    private(set) var hits: [Note] = [] {
        // Results arrive after the keystroke that asked for them, and the rows move. Keep the
        // selection on the row you picked, never on whatever now sits at its old index.
        didSet {
            rowsMovedAt = Date()
            if selection == 2 + oldValue.count {
                selection = searchRow
            } else if selection >= 2 {
                let picked = oldValue.indices.contains(selection - 2) ? oldValue[selection - 2].path : nil
                selection = hits.firstIndex { $0.path == picked }.map { $0 + 2 } ?? 0
            }
        }
    }
    /// 0 = ask Jarvis, 1 = add to Inbox as is, then search hits, then "search Obsidian".
    var selection = 0
    var isTyping = false
    /// A short confirmation in the box. Failures go to the bubble instead, where they fit.
    struct Flash: Equatable {
        enum Kind { case saved, skipped, undone }
        /// So the same confirmation twice in a row gets its own four seconds.
        let id = UUID()
        let text: String
        let kind: Kind
    }
    private(set) var flash: Flash?
    private(set) var pending: [Pending] = []
    /// Your edits to each queued prompt, kept until it's saved or skipped, so a failed save or
    /// another prompt arriving never throws them away.
    private var drafts: [Pending.ID: [DraftLine]] = [:]
    private(set) var activities: [Activity] = []
    /// The meeting prompt is open above the Dock. Answers aren't opened: they bubble up on their own.
    private(set) var reviewOpen = false
    private(set) var captureFocus = 0
    private(set) var promptFocus = 0
    /// Bumped on every save, to bounce the Obsidian icon.
    private(set) var bounce = 0
    /// Bumped when something new needs your attention, so an auto-hidden Dock shows itself, and
    /// a bubble you clicked away from comes back with it.
    private(set) var attention = 0 {
        didSet { tucked = false }
    }
    /// You clicked away from a question or a failure. It isn't dropped (it holds what you typed),
    /// just put away: the box says it's waiting, and ⌥Space brings it back.
    private(set) var tucked = false
    /// The width of the display the Dock is on, so the icons can shrink to fit it.
    var screenWidth: CGFloat = .greatestFiniteMagnitude
    /// The pointer is over the answer bubble: a save's countdown waits while you read it.
    var bubbleHovered = false
    /// The question you're replying to, shown above the sheet while you type the answer. A reply
    /// isn't a search, so the sheet drops its note and search rows meanwhile.
    private(set) var replyingTo: String?
    /// When the bubble on show appeared, so a click a moment later doesn't put it away unread.
    @ObservationIgnored private var bubbleSince: (id: Activity.ID, at: Date)?
    /// When the sheet's rows last moved under the pointer (typing, results), so hovering only
    /// picks a row once you actually move to it.
    @ObservationIgnored private(set) var rowsMovedAt = Date.distantPast

    /// The panel has to be key before a field inside it can take typing.
    @ObservationIgnored var onNeedsKey: () -> Void = {}
    /// Called when you're done, so focus goes back to your app and an auto-hidden Dock can hide.
    @ObservationIgnored var onFinish: () -> Void = {}
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var writes: Task<Void, Never>?
    /// Prompts being saved or skipped: already gone from the UI, still on disk until the CLI finishes.
    @ObservationIgnored private var resolving: Set<String> = []
    /// A held or double-pressed ⌘⏎ would otherwise save the next prompt unread.
    @ObservationIgnored private var lastResolve = Date.distantPast
    /// Answers whose undo is under way: Undo reads "Undoing…", can't run twice, and the save's
    /// countdown waits for it.
    private(set) var undoing: Set<Activity.ID> = []
    /// A write that isn't an ask (Inbox, a meeting save, an undo), shown in the box while it
    /// runs, with the same dots and timer as Claude's work.
    struct Busy: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let started = Date()
    }
    /// Queued as soon as you press the key, not when its turn comes, so a write waiting behind
    /// a slow one still shows.
    private(set) var writing: [Busy] = []
    var busy: Busy? { writing.first }
    /// Editing a failed Inbox save: ⏎ stays on the Inbox row while you type, as Try again would.
    @ObservationIgnored private var editingInbox = false
    /// What ⎋ last cleared from the box, so ⌘Z can bring it back. Typing anything forgets it.
    @ObservationIgnored private var cleared: String?
    /// So "3 matching notes" is said when the count changes, not at every pause in typing.
    @ObservationIgnored private var announcedHits = 0
    /// Writes that aren't asks give up after this, and say so.
    private static let writeTimeout: TimeInterval = 60
    /// A search stuck on a macOS folder prompt gives up, so the last query's rows don't stay
    /// under new text.
    private static let searchTimeout: TimeInterval = 10
    @ObservationIgnored private var pendingWatcher: DispatchSourceFileSystemObject?

    var reviewing: Pending? { pending.first }
    /// The open prompt's lines.
    var lines: [DraftLine] {
        get { reviewing.flatMap { drafts[$0.id] } ?? [] }
        set { if let id = reviewing?.id { drafts[id] = newValue } }
    }
    var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    var showsSheet: Bool { isTyping && !trimmedQuery.isEmpty && !reviewOpen }
    /// Requests Claude is still working on, shown as a timer in the box.
    var working: [Activity] { activities.filter(\.isRunning) }
    /// Finished requests, oldest first. The bubble shows the first; the rest wait their turn.
    var answers: [Activity] { activities.filter { !$0.isRunning } }
    var bubble: Activity? { !reviewOpen && !showsSheet && !tucked ? answers.first : nil }
    /// While true, an auto-hidden Dock stays up: typing, a prompt open, Claude still working, or
    /// an answer on show.
    var holdsOpen: Bool { isTyping || reviewOpen || !working.isEmpty || bubble != nil }
    var searchRow: Int { 2 + hits.count }
    /// Ask, Inbox, then (unless replying) the notes and "Search in Obsidian".
    var rowCount: Int { replyingTo == nil ? searchRow + 1 : 2 }

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
        // Typing over an open meeting prompt would hide the sheet; its edits are kept.
        reviewOpen = false
        tucked = false
        // A confirmation's text would sit under the caret.
        flash = nil
        onNeedsKey()
        isTyping = true
        captureFocus += 1
    }

    func openReview() {
        reviewOpen = true
        onNeedsKey()
        promptFocus += 1
    }

    func toggleReview() {
        if reviewOpen { closeReview() } else { openReview() }
    }

    func closeReview() {
        reviewOpen = false
        onFinish()
    }

    /// You clicked into another app: put the box and any open prompt away, like the Dock would.
    func lostFocus() {
        isTyping = false
        reviewOpen = false
    }

    /// A click anywhere outside the Dock puts the bubble away, like a popover. Answers and finds
    /// go. Failures hold the text you typed and questions wait for a reply, so they're only
    /// tucked away until ⌥Space. Saves keep Undo until they go by themselves.
    func clickedAway() {
        guard let bubble, let since = bubbleSince, since.id == bubble.id, Date().timeIntervalSince(since.at) > 2 else { return }
        switch bubble.state {
        case .done(let result) where result.kind == .answer || result.kind == .found: dismiss(bubble.id)
        case .done(let result) where result.kind == .saved: break
        default:
            tucked = true
            announce("\(tuckedSummary) put away. Option Space brings it back.")
            onFinish()
        }
    }

    /// What's put away, for the box and VoiceOver: "1 question", "1 failed, 1 question".
    var tuckedSummary: String {
        var counts: [(noun: String, count: Int)] = []
        for answer in answers {
            let noun = switch answer.state {
            case .failed where answer.neutral: "notice"
            case .failed, .running: "failed"
            case .done(let result): result.kind == .question ? "question" : "answer"
            }
            if let index = counts.firstIndex(where: { $0.noun == noun }) { counts[index].count += 1 } else { counts.append((noun, 1)) }
        }
        return counts.map { "\($0.count) \($0.noun)\($0.count > 1 && $0.noun != "failed" ? "s" : "")" }.joined(separator: ", ")
    }

    func bubbleAppeared(_ id: Activity.ID) {
        bubbleSince = (id, Date())
    }

    /// ⌥Space: opens the box, or closes it again if you haven't typed anything, like Spotlight.
    func hotKey() {
        if isTyping, query.isEmpty, !reviewOpen { reset() } else { requestFocus() }
    }

    // MARK: The box

    func move(_ delta: Int) {
        selection = (selection + delta + rowCount) % rowCount
        // Focus stays in the box, so VoiceOver hears the row from here.
        if showsSheet { announce(rowTitle(selection)) }
    }

    /// The sheet's rows, top to bottom: see `selection`.
    func rowTitle(_ row: Int) -> String {
        switch row {
        case 0: "Ask Jarvis"
        case 1: "Add to Inbox as is"
        // Clipped: a long paste would otherwise be read out in full at every ↑↓.
        case searchRow: "Search in Obsidian for “\(trimmedQuery.count > 60 ? trimmedQuery.prefix(59) + "…" : trimmedQuery)”"
        default: hits.indices.contains(row - 2) ? hits[row - 2].name : ""
        }
    }

    func submit(command: Bool) {
        let text = trimmedQuery
        guard !text.isEmpty else {
            // ⌥Space then ⏎ presses the bubble's main button, so it walks through the answers,
            // and then opens a waiting meeting prompt.
            // A held ⏎ repeats; it mustn't walk past answers you haven't seen.
            if command || NSApp.currentEvent?.isARepeat == true { return }
            if let bubble { primary(bubble) } else if reviewing != nil { openReview() }
            return
        }
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
        if !query.isEmpty {
            cleared = query
            query = ""
            replyingTo = nil
        } else if bubble != nil {
            // A held ⎋ repeats; it mustn't dismiss answers you haven't seen.
            if NSApp.currentEvent?.isARepeat == true { return }
            dismissBubble()
        } else {
            reset()
        }
    }

    /// What the bubble's white button does: reply to a question, try a failure again, or move on.
    func primary(_ activity: Activity) {
        switch activity.primary {
        case .reply: edit(activity.id)
        case .open:
            if case .done(let result) = activity.state, let path = result.open { open(Note(path: path, title: path)) }
            dismiss(activity.id)
        case .retry: retry(activity.id)
        case .dismiss:
            dismiss(activity.id)
            if answers.isEmpty, isTyping { reset() }
        }
    }

    /// Done from the keyboard. With nothing left to read, the box goes away too.
    private func dismissBubble() {
        guard let bubble else { return }
        // A failure holds the only copy of what you typed: ⌘Z in the box brings it back.
        if bubble.isFailed, bubble.origin != .notice { cleared = bubble.text }
        dismiss(bubble.id)
        if answers.isEmpty { reset() }
    }

    /// ⌘Z in an empty box undoes the answer on show, if it changed anything, or else brings back
    /// what ⎋ just cleared.
    func undoBubble() -> Bool {
        if let bubble, case .done(let result) = bubble.state, !result.changed.isEmpty {
            undo(bubble.id)
            return true
        }
        guard let text = cleared else { return false }
        cleared = nil
        query = text
        return true
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
                guard let result = try? JSONDecoder().decode(AskResult.self, from: data) else {
                    throw Jarvis.Failure(errorDescription: "Jarvis couldn't read Claude's answer")
                }
                finish(activity.id) { $0.state = .done(result) }
                // The bubble isn't focused, so VoiceOver hears all of it from here.
                announce([result.message, result.detail, result.changed.isEmpty ? "" : "Undo with Command Z."]
                    .filter { !$0.isEmpty }.joined(separator: ". "))
                // Too long for the bubble: Claude names the note that holds it, and the bubble
                // offers it. Not opened by itself: you may be typing in another app.
                if result.kind == .saved {
                    bounce += 1
                    dismiss(activity.id, after: 8)
                }
            } catch {
                let message = Day.inline(error.localizedDescription)
                finish(activity.id) {
                    $0.state = .failed(message)
                    $0.detail = (error as? Jarvis.Failure)?.detail.map(Day.inline)
                }
                announce(message)
            }
            attention += 1
        }
    }

    func undo(_ id: Activity.ID) {
        guard let activity = activities.first(where: { $0.id == id }), case .done(let result) = activity.state else { return }
        guard !undoing.contains(id) else { return }
        undoing.insert(id)
        write("Undoing") { [self] in
            defer { undoing.remove(id) }
            do {
                struct Undone: Decodable { let restored: [String]; let skipped: [String] }
                let data = try await Jarvis.run(["undo", "--", result.runId], timeout: Self.writeTimeout)
                let undone = try JSONDecoder().decode(Undone.self, from: data)
                // Whatever it managed, the save's Undo has had its go: notes it left alone were
                // edited since, and trying again won't change that.
                dismiss(id)
                if undone.skipped.isEmpty {
                    show(undone.restored.isEmpty ? "Nothing to undo" : "Undone", .undone)
                } else {
                    let undid = undone.restored.isEmpty ? "" : ". Undid \(Self.names(undone.restored))"
                    notice("Kept \(Self.names(undone.skipped)) as is", detail: "Edited after the save" + undid,
                           about: activity.text, neutral: true)
                }
            } catch {
                notice("Couldn't undo", detail: Self.explain(error), about: activity.text)
            }
        }
    }

    private static func names(_ paths: [String]) -> String {
        paths.map(Day.note).joined(separator: ", ")
    }

    /// Under a write's own headline ("Couldn't undo"), what the CLI said and why.
    private static func explain(_ error: Error) -> String {
        [error.localizedDescription, (error as? Jarvis.Failure)?.detail].compactMap { $0 }.joined(separator: ". ")
    }

    /// A failure that isn't an ask's own, like an undo or a meeting save. It goes to the front of
    /// the queue so you see it now, in full, and stays until you dismiss it.
    private func notice(_ message: String, detail: String? = nil, about: String, neutral: Bool = false) {
        fail(Activity(text: about, origin: .notice, detail: detail, neutral: neutral), message)
    }

    /// Failures go first in the queue, so they show now rather than behind other answers.
    private func fail(_ activity: Activity, _ message: String) {
        var failed = activity
        failed.detail = failed.detail.map(Day.inline)
        failed.state = .failed(message)
        activities.insert(failed, at: 0)
        announce(message)
        attention += 1
    }

    /// Puts what you typed back in the box: to add the answer to a question (Reply), or to fix
    /// a failed request before sending it again (Edit).
    func edit(_ id: Activity.ID) {
        guard let activity = activities.first(where: { $0.id == id }) else { return }
        if case .done(let result) = activity.state, result.kind == .question {
            replyingTo = result.message
            query = activity.text + " "
        } else {
            query = activity.text
            // A failed Inbox save goes back to the Inbox on ⏎, as Try again would.
            if activity.origin == .inbox {
                editingInbox = true
                selection = 1
            }
        }
        requestFocus()
        dismiss(id)
    }

    func dismiss(_ id: Activity.ID) {
        activities.removeAll { $0.id == id }
        // A save's timer can run out while you type the next thing; that isn't you being done.
        if answers.isEmpty, !isTyping, !reviewOpen { onFinish() }
    }

    /// Tries what you chose again: a failed Inbox save goes back to the Inbox, not to Claude.
    func retry(_ id: Activity.ID) {
        guard let activity = activities.first(where: { $0.id == id }) else { return }
        dismiss(id)
        switch activity.origin {
        case .ask: ask(activity.text)
        case .inbox: addToInbox(activity.text)
        case .notice: break
        }
    }

    /// Saves confirm and go. Only counts while the bubble is on screen and you aren't reading it
    /// (pointer over it) or typing, so Undo stays as long as you're looking at it.
    private func dismiss(_ id: Activity.ID, after seconds: Double) {
        Task {
            var left = seconds
            while left > 0 {
                try? await Task.sleep(for: .seconds(0.5))
                guard activities.contains(where: { $0.id == id }) else { return }
                if bubble?.id == id, !bubbleHovered, !isTyping, !undoing.contains(id) { left -= 0.5 }
            }
            dismiss(id)
        }
    }

    private func update(_ id: Activity.ID, _ change: (inout Activity) -> Void) {
        if let index = activities.firstIndex(where: { $0.id == id }) { change(&activities[index]) }
    }

    /// A finished ask joins the end of the queue, so a quick one finishing first never gets
    /// replaced on screen by a slow one that started earlier.
    private func finish(_ id: Activity.ID, _ change: (inout Activity) -> Void) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        var activity = activities.remove(at: index)
        change(&activity)
        activities.append(activity)
    }

    private func addToInbox(_ text: String) {
        reset()
        write("Adding to Inbox") { [self] in
            do {
                _ = try await Jarvis.run(["capture", "--inbox", "--", text], timeout: Self.writeTimeout)
                bounce += 1
                show("Added to Inbox", .saved)
            } catch {
                // The failure bubble keeps the text, so a failed save never loses the thought.
                fail(Activity(text: text, origin: .inbox, detail: Self.explain(error)), "Couldn't add to Inbox")
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        selection = editingInbox ? 1 : 0
        let query = trimmedQuery
        rowsMovedAt = Date()
        guard !query.isEmpty, replyingTo == nil else {
            hits = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let found = try? JSONDecoder().decode([Note].self, from: await Jarvis.run(["search", "--", query], timeout: Self.searchTimeout))
            guard !Task.isCancelled else { return }
            // A failed search shows nothing rather than the last query's results.
            self.hits = Array((found ?? []).prefix(3))
            if hits.count != announcedHits, !hits.isEmpty { announce(hits.count == 1 ? "1 matching note" : "\(hits.count) matching notes") }
            announcedHits = hits.count
        }
    }

    private func reset() {
        replyingTo = nil
        query = ""
        hits = []
        selection = 0
        isTyping = false
        onFinish()
    }

    /// The CLI edits notes by read-modify-write, so vault writes from the Dock run one at a time.
    /// Each shows in the box from the moment it's queued until it's done.
    private func write(_ label: String, _ operation: @escaping @MainActor () async -> Void) {
        let entry = Busy(text: label)
        writing.append(entry)
        let previous = writes
        writes = Task { @MainActor in
            await previous?.value
            await operation()
            writing.removeAll { $0.id == entry.id }
        }
    }

    // MARK: Meeting prompts

    func addLine() {
        lines.append(.blank)
    }

    private var savedLines: [DraftLine] {
        lines.filter { $0.included && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Every line left out or empty: Save would write nothing, so the card offers only Skip,
    /// which can't be undone and so has no shortcut.
    var savesNothing: Bool { savedLines.isEmpty }

    /// Takes the prompt's id so a double-fired shortcut can't save the next prompt too.
    func savePrompt(_ id: Pending.ID) {
        guard !savesNothing else { return }
        resolve(id, args: [], input: savedLines.map(\.serialized).joined(separator: "\n"))
    }

    func skipPrompt(_ id: Pending.ID) {
        resolve(id, args: ["--skip"], input: nil)
    }

    private func resolve(_ id: Pending.ID, args: [String], input: String?) {
        guard let current = reviewing, current.id == id, Date().timeIntervalSince(lastResolve) > 0.5 else { return }
        lastResolve = Date()
        let skip = !args.isEmpty
        resolving.insert(id)
        pending.removeFirst()
        if reviewing == nil { closeReview() } else { promptFocus += 1 }

        write(skip ? "Skipping the meeting" : "Saving the meeting") { [self] in
            do {
                _ = try await Jarvis.run(["resolve"] + args + ["--", current.noteName], input: input, timeout: Self.writeTimeout)
                drafts[id] = nil
                if !skip { bounce += 1 }
                // Clipped like a step, so it fits the box beside the timer.
                let title = current.proposal.title.count > 20 ? current.proposal.title.prefix(19) + "…" : current.proposal.title
                show("\(skip ? "Skipped" : "Saved") \(title)", skip ? .skipped : .saved)
            } catch {
                // Writes are planned before any commit, so a failure leaves nothing half-saved to retry over.
                // The prompt comes back (reloadPending below) with your edits, so you can try again.
                // The card closes so the failure shows instead of a different prompt swapping in.
                reviewOpen = false
                notice("Couldn't \(skip ? "skip" : "save") the meeting", detail: Self.explain(error), about: current.proposal.title)
            }
            resolving.remove(id)
            reloadPending()
        }
    }

    private func reloadPending() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Jarvis.pendingDir, includingPropertiesForKeys: nil)) ?? []
        var loaded = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Pending.self, from: Data(contentsOf: $0)) }
            .filter { !resolving.contains($0.id) }
            .sorted { $0.noteName < $1.noteName }
        // The open card's prompt stays first, so a late draft can't swap in under you.
        if reviewOpen, let open = loaded.firstIndex(where: { $0.id == reviewing?.id }) {
            loaded.insert(loaded.remove(at: open), at: 0)
        }
        let arrived = Set(loaded.map(\.id)).subtracting(pending.map(\.id))
        pending = loaded
        for prompt in loaded where drafts[prompt.id] == nil { drafts[prompt.id] = DraftLine.lines(for: prompt) }
        if reviewOpen, pending.isEmpty { closeReview() }
        if !arrived.isEmpty { attention += 1 }
    }

    private func show(_ text: String, _ kind: Flash.Kind) {
        let message = Flash(text: text, kind: kind)
        flash = message
        announce(text)
        // An auto-hidden Dock comes up for it: the box went away when you pressed ⏎.
        attention += 1
        Task {
            try? await Task.sleep(for: .seconds(4))
            if flash == message { flash = nil }
        }
    }

    /// The box's text isn't focused when it changes, so VoiceOver is told directly.
    func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
