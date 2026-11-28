import AppKit
import Observation

@MainActor @Observable
final class DockModel {
    var query = "" {
        didSet {
            // Emptying the box ends a reply; the next thing typed is something new.
            if trimmedQuery.isEmpty { replyingTo = nil; editingInbox = false } else { cleared = nil }
            // Typing over the paused card turns it back into the box, as ⌥Space does, so the
            // sheet shows and ⏎, ⌘⏎ and esc mean what they always mean.
            if pausedOpen, !trimmedQuery.isEmpty { pausedOpen = false }
            if query != oldValue {
                scheduleSearch()
                announceApp()
            }
        }
    }
    private(set) var hits: [Note] = [] {
        didSet { rowsMovedAt = Date() }
    }
    /// The sheet's rows, top to bottom: an app whose name you're typing, Ask, Inbox, the notes
    /// and "Search in Obsidian". A reply is only ever sent back to Claude, so it gets Ask alone
    /// (which reads "Reply").
    enum Row: Hashable {
        case app(DockApp.ID), ask, inbox, note(Note.ID), search
    }
    var rows: [Row] {
        guard replyingTo == nil else { return [.ask] }
        let app: [Row] = appMatch.map { [.app($0.id)] } ?? []
        return app + [.ask, .inbox] + hits.map { .note($0.id) } + [.search]
    }
    /// The row ⏎ presses, held by what it is rather than where: results arrive after the
    /// keystroke that asked for them and the rows move, but the pick stays put. Nil is the default.
    private var picked: Row?
    var selection: Int {
        get { picked.flatMap { rows.firstIndex(of: $0) } ?? rows.firstIndex(of: defaultRow) ?? 0 }
        set { picked = rows.indices.contains(newValue) ? rows[newValue] : nil }
    }
    /// ⏎ asks, and opens a matching app only once its whole name is typed, so a one-word capture
    /// like "music" never launches anything by accident. Arrowing up to the app row picks it too.
    private var defaultRow: Row {
        if let app = appMatch, app.name.lowercased() == trimmedQuery.lowercased() { .app(app.id) } else { .ask }
    }
    @ObservationIgnored private var announcedApp: DockApp.ID?
    /// Where the Dock's apps come from, and how one opens (Downloads opens its fan), for the
    /// sheet's "Open …" row.
    @ObservationIgnored var apps: () -> [DockApp] = { [] }
    @ObservationIgnored var onOpenApp: (DockApp) -> Void = { _ in }
    /// The app (or Downloads, the Trash) you're typing. A whole name wins ("safari" is Safari, not
    /// Safari Technology Preview); otherwise a prefix of one of its words, from two letters, so a
    /// capture that merely begins with an app's name stops matching at its first space.
    var appMatch: DockApp? {
        let typed = trimmedQuery.lowercased()
        guard typed.count >= 2, replyingTo == nil else { return nil }
        let apps = apps()
        if let exact = apps.first(where: { $0.name.lowercased() == typed }) { return exact }
        guard !typed.contains(" ") else { return nil }
        return apps.first { app in
            app.name.lowercased().split(separator: " ").contains { $0.hasPrefix(typed) }
        }
    }
    var isTyping = false
    /// A short confirmation in the box. Failures go to the bubble instead, where they fit.
    struct Flash: Equatable {
        /// `nothing` is an undo that found nothing to undo: neutral, not a success.
        enum Kind { case saved, skipped, undone, nothing, stopped }
        /// What the box's Undo (⌘Z) takes back while the confirmation shows.
        enum Undo: Equatable {
            /// A write ("Added to Inbox", "Saved <meeting>"): the CLI's run id, and what it was
            /// about, for the notice if the undo fails.
            case run(String, about: String)
            /// A stopped ask ("Stopped “…”"): its text goes back in the box.
            case text(String)
        }
        /// So the same confirmation twice in a row gets its own four seconds.
        let id = UUID()
        let text: String
        let kind: Kind
        var undo: Undo?
        /// Carries the box's Undo, so it stays when you focus the box to press ⌘Z.
        var offersUndo: Bool { kind == .skipped || undo != nil }
    }
    private(set) var flash: Flash?
    /// First run: no vault yet, so the Dock asks which one (`choose`), then invites a first
    /// capture (`ready`). Nil once Jarvis has a vault.
    enum Setup: Equatable {
        case choose([Vault])
        /// The vault is set: which folder, if any, the call recorder saves to.
        case meetings(Vault, [MeetingFolder])
        case ready(Vault)
    }
    private(set) var setup: Setup?
    /// The setup bubble is on show. esc or a click elsewhere puts it away until ⌥Space.
    private(set) var setupOpen = false
    /// The vault row ⏎ will pick; the last row is "Choose another folder…".
    var setupSelection = 0
    /// Why the vault you picked didn't take, under the setup bubble's question.
    private(set) var setupError: String?
    @ObservationIgnored private var settingUp = false
    /// Claude Code was found at first run. Without it, the invitation points at ⌘⏎ instead of ⏎.
    /// Settable so screenshots can stage it.
    var claudeFound = true
    /// ⌥Space couldn't be registered because another app holds it. Settings' Keys list can say so.
    private(set) var hotKeyTaken = false
    /// The CLI's `detail:` line under `meetingsPaused`: what to do about it.
    private(set) var pausedDetail: String?
    /// Why meeting prompts stopped, in the CLI's words, while `jarvis watch` keeps failing.
    private(set) var meetingsPaused: String? {
        didSet {
            if oldValue == nil, let meetingsPaused {
                attention += 1
                announce("Meetings paused. \(meetingsPaused)")
            }
            if meetingsPaused == nil { pausedOpen = false }
        }
    }
    private(set) var pausedOpen = false
    /// A skipped prompt, held back so Undo can put it back. It's only skipped for real when the
    /// grace runs out (or the next skip comes), so undoing never needs the CLI.
    private(set) var skipping: Pending?
    @ObservationIgnored private var skipTask: Task<Void, Never>?
    private static let skipGrace: Double = 8
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
    /// Jarvis has a vault, so the meeting watcher can start.
    @ObservationIgnored var onConfigured: () -> Void = {}
    /// Try again on "Meetings paused".
    @ObservationIgnored var onRetryWatcher: () -> Void = {}
    /// The paused card's Settings…, and ⌘, in the box.
    @ObservationIgnored var onOpenSettings: () -> Void = {}
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var writes: Task<Void, Never>?
    /// Prompts being saved or skipped: already gone from the UI, still on disk until the CLI finishes.
    @ObservationIgnored private var resolving: Set<String> = []
    /// A held or double-pressed ⌘⏎ would otherwise save the next prompt unread.
    @ObservationIgnored private var lastResolve = Date.distantPast
    /// Prompts whose Draft again is under way, so a second ⌘R doesn't queue another.
    @ObservationIgnored private var drafting: Set<Pending.ID> = []
    /// Answers whose undo is under way: Undo reads "Undoing…", can't run twice, and the save's
    /// countdown waits for it.
    private(set) var undoing: Set<Activity.ID> = []
    /// A write that isn't an ask (Inbox, a meeting save, an undo), shown in the box while it
    /// runs, with the same dots and timer as Claude's work.
    struct Busy: Equatable, Identifiable {
        let id = UUID()
        let text: String
        /// Still queued: behind another write, or behind Claude, and then the box says so.
        var waiting = true
        /// When it was queued, and then when it started, for the box's timer.
        var started = Date()
    }
    /// Queued as soon as you press the key, not when its turn comes, so a write waiting behind
    /// a slow one still shows.
    private(set) var writing: [Busy] = []
    var busy: Busy? { writing.first }
    /// Editing a failed Inbox save: ⏎ stays on the Inbox row while you type, as Try again would.
    @ObservationIgnored private var editingInbox = false
    /// What esc or Dismiss last cleared, so ⌘Z in the empty box can bring it back. Typing
    /// anything forgets it.
    @ObservationIgnored private var cleared: String?
    /// So "3 matching notes" is said when the count changes, not at every pause in typing.
    @ObservationIgnored private var announcedHits = 0
    /// Why the last search failed, in the CLI's words, until one works again.
    private(set) var searchError: String?
    private static let writeTimeout: TimeInterval = 60
    /// A search stuck on a macOS folder prompt gives up, so the last query's rows don't stay
    /// under new text.
    private static let searchTimeout: TimeInterval = 10
    @ObservationIgnored private var pendingWatcher: DispatchSourceFileSystemObject?
    /// Asks still running, which vault writes wait for (see `write`).
    @ObservationIgnored private var asking: [Activity.ID: Task<Void, Never>] = [:]

    var reviewing: Pending? { pending.first }
    var lines: [DraftLine] {
        get { reviewing.flatMap { drafts[$0.id] } ?? [] }
        set { if let id = reviewing?.id { drafts[id] = newValue } }
    }
    var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    /// While first run asks something (which vault, which meetings folder), ⏎ and ↑↓ belong to
    /// the setup bubble, not the sheet.
    var setupAsks: Bool {
        switch setup {
        case .choose, .meetings: true
        default: false
        }
    }
    var showsSheet: Bool { isTyping && !trimmedQuery.isEmpty && !reviewOpen && !pausedOpen && !setupAsks }
    var showsSetup: Bool { setup != nil && setupOpen && !reviewOpen && !pausedOpen && !showsSheet }
    var working: [Activity] { activities.filter(\.isRunning) }
    /// Finished requests, oldest first. The bubble shows the first; the rest wait their turn.
    var answers: [Activity] { activities.filter { !$0.isRunning } }
    var bubble: Activity? { !reviewOpen && !pausedOpen && !showsSheet && !showsSetup && !tucked ? answers.first : nil }
    /// The box has the keys and nothing typed, so ⏎, esc and ⌘Z reach the panel above it. Its
    /// buttons show their keys only meanwhile.
    var boxHasKeys: Bool { isTyping && query.isEmpty }
    /// ⏎ in the empty box, with no bubble or card in the way, opens a pill's card (see `submit`).
    private var enterOpensCard: Bool {
        isTyping && trimmedQuery.isEmpty && bubble == nil && setup == nil && !reviewOpen && !pausedOpen
    }
    /// ⏎ in the box would open "Meetings paused", so its pill says so. It comes before a waiting
    /// meeting prompt: while meetings are paused, that's the thing to fix.
    var enterOpensPaused: Bool { enterOpensCard && meetingsPaused != nil }
    /// ⏎ in the box would open the waiting meeting prompt, so its pill says so.
    var enterOpensReview: Bool { enterOpensCard && meetingsPaused == nil && reviewing != nil }
    /// While true, an auto-hidden Dock stays up: typing, a card open, Claude still working, or
    /// an answer on show.
    var holdsOpen: Bool { isTyping || reviewOpen || pausedOpen || showsSetup || !working.isEmpty || bubble != nil }

    func start() {
        watchPending()
        reloadPending()
    }

    /// Watches the prompt queue's folder. One deleted or moved (a reset of the state folder) is
    /// watched again where it's recreated; the old descriptor would hear nothing ever again.
    private func watchPending() {
        pendingWatcher?.cancel()
        let dir = Jarvis.pendingDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, unowned source] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !source.data.isDisjoint(with: [.delete, .rename]) { self.watchPending() }
                self.reloadPending()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        pendingWatcher = source
    }

    func requestFocus() {
        // Typing over an open meeting prompt would hide the sheet; its edits are kept.
        reviewOpen = false
        pausedOpen = false
        tucked = false
        // ⌥Space brings back a setup bubble you put away.
        if setup != nil { setupOpen = true }
        // A confirmation's text would sit under the caret, unless it carries the Undo you
        // focused the box to press.
        if flash?.offersUndo != true { flash = nil }
        onNeedsKey()
        isTyping = true
        captureFocus += 1
    }

    func openReview() {
        pausedOpen = false
        reviewOpen = true
        onNeedsKey()
        promptFocus += 1
        // Focus lands in the first line, so VoiceOver would otherwise hear only that.
        if let reviewing {
            announce("\(reviewing.proposal.title), meeting prompt, \(lines.count == 1 ? "1 line" : "\(lines.count) lines")")
        }
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
        pausedOpen = false
        putAwaySetup()
    }

    /// Picking a vault waits, put away, until ⌥Space; the "try it now" invitation just goes.
    private func putAwaySetup() {
        if case .ready = setup { setup = nil } else { setupOpen = false }
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
        if isTyping, query.isEmpty, !reviewOpen {
            putAwaySetup()
            pausedOpen = false
            reset()
        } else {
            requestFocus()
        }
    }

    // MARK: The box

    func move(_ delta: Int) {
        if setupAsks, setupOpen {
            let count = setupRows.count
            setupSelection = (setupSelection + delta + count) % count
            announce(setupRows[setupSelection])
            return
        }
        let count = rows.count
        selection = (selection + delta + count) % count
        // Focus stays in the box, so VoiceOver hears the row from here.
        if showsSheet { announce(rowTitle(rows[selection])) }
    }

    func rowTitle(_ row: Row) -> String {
        switch row {
        case .app: "Open \(appMatch?.name ?? "")"
        case .ask: replyingTo == nil ? "Ask Jarvis" : "Reply"
        case .inbox: "Add to Inbox as is"
        case .note(let path): hits.first { $0.path == path }?.name ?? ""
        // Clipped: a long paste would otherwise be read out in full at every ↑↓.
        case .search: "Search in Obsidian for “\(trimmedQuery.clipped())”"
        }
    }

    /// VoiceOver hears an app row when it appears, and how to reach it, since it changes what
    /// the sheet offers above Ask.
    private func announceApp() {
        let app = appMatch
        guard app?.id != announcedApp else { return }
        announcedApp = app?.id
        if let app { announce("Open \(app.name), \(rows[selection] == .app(app.id) ? "press Return" : "up arrow")") }
    }

    /// What the setup bubble's rows say, top to bottom, for VoiceOver and the row count.
    var setupRows: [String] {
        switch setup {
        case .choose(let vaults): vaults.map(\.name) + ["Choose another folder…"]
        case .meetings(_, let folders): folders.map(\.name) + [folders.isEmpty ? "Choose a folder…" : "Choose another folder…", "Not now"]
        default: []
        }
    }

    func submit(command: Bool) {
        // The box keeps the keys while the paused card is open: ⏎ is its Try again.
        if pausedOpen { return retryWatcher() }
        if setupAsks {
            // A held ⏎ repeats; one choice is enough. ⌘⏎ means the Inbox, so it never chooses.
            if command || Self.keyRepeats { return }
            if !setupOpen { setupOpen = true } else { pickSetupRow(setupSelection) }
            return
        }
        // The first thing you send, or Done on the invitation, finishes first run.
        if case .ready = setup {
            setup = nil
            if trimmedQuery.isEmpty { return reset() }
        }
        let text = trimmedQuery
        guard !text.isEmpty else {
            // ⌥Space then ⏎ presses the bubble's main button, so it walks through the answers,
            // and then opens "Meetings paused" or a waiting meeting prompt.
            // A held ⏎ repeats; it mustn't walk past answers you haven't seen.
            if command || Self.keyRepeats { return }
            if let bubble { primary(bubble) } else if meetingsPaused != nil { togglePaused() } else if reviewing != nil { openReview() }
            return
        }
        switch command ? .inbox : rows[selection] {
        case .ask: ask(text)
        case .inbox: addToInbox(text)
        case .search:
            openSearch(text)
            reset()
        case .note(let path):
            guard let note = hits.first(where: { $0.path == path }) else { return }
            open(note)
            reset()
        case .app:
            guard let app = appMatch else { return }
            // Opened first, so the Downloads fan holds an auto-hidden Dock up before the box lets go.
            onOpenApp(app)
            reset()
        }
    }

    func cancel() {
        if pausedOpen { return togglePaused() }
        if !query.isEmpty {
            cleared = query
            query = ""
            replyingTo = nil
        } else if showsSetup {
            // On the meetings question, esc is its "Not now". Not on a repeat, which would then
            // dismiss the invitation unread, nor while a chosen folder is still being written.
            if case .meetings(let vault, _) = setup {
                if !Self.keyRepeats, !settingUp { skipMeetings(vault) }
                return
            }
            putAwaySetup()
            reset()
        } else if let bubble {
            // A held esc repeats; it mustn't dismiss answers you haven't seen.
            if Self.keyRepeats { return }
            dismissKeepingText(bubble)
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

    /// Dismiss, by its button or esc. A bubble that holds what you typed (a failure, a question,
    /// an answer too long to show) keeps it, so ⌘Z in the empty box brings it back. With nothing
    /// left to read, the box goes away too.
    func dismissKeepingText(_ activity: Activity) {
        if activity.keepsText { cleared = activity.text }
        dismiss(activity.id)
        if answers.isEmpty { reset() }
    }

    /// ⌘Z in an empty box undoes the answer on show, if it changed anything, or what the box
    /// offers Undo for, or else brings back what esc or Dismiss just cleared.
    func undoBubble() -> Bool {
        if let bubble, case .done(let result) = bubble.state, !result.changed.isEmpty {
            undo(bubble.id)
            return true
        }
        if undoInBox() { return true }
        guard let text = cleared else { return false }
        cleared = nil
        query = text
        return true
    }

    /// The box's Undo: the write its confirmation shows ("Added to Inbox", "Saved <meeting>"), or
    /// else a skip still in its grace. False when it offers neither.
    @discardableResult func undoInBox() -> Bool {
        switch flash?.undo {
        case .run(let run, let about):
            flash = nil
            write(Self.undoingLabel) { [self] in
                _ = await undoRun(run, about: about)
                // An undone meeting save puts its prompt back.
                reloadPending()
            }
            return true
        case .text(let text):
            flash = nil
            if !isTyping { requestFocus() }
            query = text
            return true
        case nil: break
        }
        guard skipping != nil else { return false }
        undoSkip()
        return true
    }

    func openSettings() {
        onOpenSettings()
    }

    func open(_ note: Note) {
        openObsidian("open", ["vault": Jarvis.vaultName, "file": note.path])
    }

    /// The meeting card's title: the recording in Obsidian, which finds it by name, so the Dock
    /// never needs its path.
    func openCall(_ prompt: Pending) {
        openObsidian("open", ["vault": Jarvis.vaultName, "file": prompt.noteName])
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
        announce("Asking Jarvis. Press Command Period to stop.")
        // Assigned before the Task can start: it runs on the main actor, after this returns.
        asking[activity.id] = Task {
            defer { asking[activity.id] = nil }
            do {
                // Claude has 5 minutes (src/ask.ts); past that the CLI is stuck in the vault (a
                // macOS prompt), and stopping it frees the writes waiting on this ask.
                let data = try await Jarvis.run(["ask", "--app=\(app)", "--", text], timeout: 6 * 60) { step in
                    self.update(activity.id) { $0.step = step }
                }
                guard let result = try? JSONDecoder().decode(AskResult.self, from: data) else {
                    throw Jarvis.Failure(errorDescription: "Jarvis couldn't read Claude's answer")
                }
                // Stopped just as it finished: the answer still shows, so its Undo isn't lost.
                if !activities.contains(where: { $0.id == activity.id }) { activities.append(activity) }
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
                // Stopped (⌘.): the CLI's "Stopped" isn't a failure, and the box already said so.
                guard activities.contains(where: { $0.id == activity.id }) else { return }
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

    /// ⌘. in the box: stops the oldest ask. Cancelling its Task terminates `jarvis ask`, which
    /// undoes whatever the run had changed before it exits, so writes queued behind it wait for
    /// that. What you typed comes back with ⌘Z or the box's Undo, and after that with ⌘Z in the
    /// empty box, like text esc cleared. False when nothing is running.
    func stopAsk() -> Bool {
        guard let oldest = working.first, let task = asking[oldest.id] else { return false }
        task.cancel()
        activities.removeAll { $0.id == oldest.id }
        cleared = oldest.text
        // Named, so with two running you can tell which one went; clipped, so a pasted paragraph
        // isn't read out in full. The box cuts what's left in the middle. Undo brings back all of it.
        show("Stopped “\(oldest.text.clipped())”", .stopped, undo: .text(oldest.text))
        return true
    }

    func undo(_ id: Activity.ID) {
        guard let activity = activities.first(where: { $0.id == id }), case .done(let result) = activity.state else { return }
        guard !undoing.contains(id) else { return }
        undoing.insert(id)
        write(Self.undoingLabel) { [self] in
            defer { undoing.remove(id) }
            // Whatever it managed, the save's Undo has had its go: notes it left alone were
            // edited since, and trying again won't change that. A failed undo keeps it.
            if await undoRun(result.runId, about: activity.text) { dismiss(id) }
        }
    }

    /// What `jarvis undo` prints when piped: the notes it put back, and those edited since.
    private struct Undone: Decodable { let restored: [String]; let skipped: [String] }

    /// The Dock's right-click Undo Last Change, and ⌥⌘Z in the box: `jarvis undo --last`, the
    /// newest run whatever made it, queued like any other write. Ignored with a beep while an
    /// undo is queued or running, so two picks can't undo two runs.
    func undoLast() {
        guard !writing.contains(where: { $0.text == Self.undoingLabel }) else {
            NSSound.beep()
            announce("Already undoing")
            return
        }
        // Queued behind a running ask, `--last` would pick the ask's own save once it lands.
        guard asking.isEmpty else {
            NSSound.beep()
            show("Can't undo while Claude works", .nothing, spoken: "Can't undo while Claude works. Stop it with Command Period, or wait.")
            return
        }
        // The newest run as of this press: one an ask started meanwhile saves later isn't it.
        let pressed = Date()
        write(Self.undoingLabel) { [self] in
            _ = await undoRun(nil, before: pressed, about: "Undo Last Change")
        }
    }

    private static let undoingLabel = "Undoing"
    nonisolated(unsafe) private static let isoTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Runs `jarvis undo` for a run, or for the newest one made by `before` when `run` is nil, and
    /// says how it went. False when the undo itself failed.
    private func undoRun(_ run: String?, before: Date = Date(), about text: String) async -> Bool {
        let target = run.map { ["--", $0] } ?? ["--last", "--before=\(Self.isoTime.string(from: before))"]
        do {
            let data = try await Jarvis.run(["undo"] + target, timeout: Self.writeTimeout)
            let undone = try JSONDecoder().decode(Undone.self, from: data)
            if undone.skipped.isEmpty {
                if undone.restored.isEmpty {
                    show("Nothing to undo", .nothing)
                } else {
                    show("Put back \(undone.restored.count == 1 ? Day.note(undone.restored[0]) : "\(undone.restored.count) notes")", .undone)
                }
            } else {
                // Not a failure: the note is newer than the save, and that's yours.
                let them = undone.skipped.count > 1
                let undid = undone.restored.isEmpty ? "" : " Put back \(Self.names(undone.restored))."
                notice("Kept \(Self.names(undone.skipped)) as is",
                       detail: "You edited \(them ? "them" : "it") after Jarvis changed it, so Undo left \(them ? "them" : "it") alone." + undid
                           + (undone.restored.isEmpty ? " Undo Last Change now moves past it." : ""),
                       about: text, neutral: true)
            }
            return true
        } catch let error as Jarvis.Failure where ["Nothing to undo", "Already undone"].contains(error.errorDescription) {
            // No run left in the week's history, or one undone already (⌥⌘Z, then the bubble's
            // Undo), isn't a failure.
            show(error.errorDescription ?? "Nothing to undo", .nothing)
            return true
        } catch {
            notice("Couldn't undo", detail: Self.explain(error), about: text)
            return false
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
    private func notice(_ message: String, detail: String? = nil, about: String, origin: Activity.Origin = .notice, neutral: Bool = false) {
        fail(Activity(text: about, origin: origin, detail: detail, neutral: neutral), message)
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
                picked = .inbox
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
        // Back on the card, with that prompt in front and your edits, for another ⌘⏎.
        case .meeting(let prompt):
            guard pending.contains(where: { $0.id == prompt }) else { return }
            reviewOpen = true
            reloadPending(front: prompt)
            openReview()
        case .draft(let prompt): draftAgain(prompt)
        case .notice: break
        }
    }

    /// Saves confirm and go. Only counts while the bubble is on screen and you aren't reading it
    /// (pointer over it) or typing, so Undo stays as long as you're looking at it.
    private func dismiss(_ id: Activity.ID, after seconds: Double) {
        Task {
            let shown = await countDown(seconds, lasts: { activities.contains { $0.id == id } }) {
                bubble?.id != id || bubbleHovered || isTyping || undoing.contains(id)
            }
            if shown { dismiss(id) }
        }
    }

    /// Waits `seconds` in half-second steps, not counting the steps while `holds`: an Undo stays
    /// while you're on your way to press it. False if `lasts` stops being true first, or the
    /// task is cancelled.
    private func countDown(_ seconds: Double, lasts: () -> Bool = { true }, holds: () -> Bool) async -> Bool {
        var left = seconds
        while left > 0 {
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled, lasts() else { return false }
            if !holds() { left -= 0.5 }
        }
        return true
    }

    /// The box or the meeting card has the keys, so ⌘Z can reach the box's Undo.
    private var undoWithinReach: Bool { isTyping || reviewOpen }

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
                // `run` names the write for `jarvis undo`; an older CLI leaves it out, and then
                // there's no Undo to offer.
                struct Captured: Decodable { let run: String? }
                let data = try await Jarvis.run(["capture", "--inbox", "--", text], timeout: Self.writeTimeout)
                let run = (try? JSONDecoder().decode(Captured.self, from: data))?.run
                bounce += 1
                show("Added to Inbox", .saved, undo: run.map { .run($0, about: text) })
            } catch {
                // The failure bubble keeps the text, so a failed save never loses the thought.
                fail(Activity(text: text, origin: .inbox, detail: Self.explain(error)), "Couldn't add to Inbox")
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        picked = editingInbox ? .inbox : nil
        let query = trimmedQuery
        rowsMovedAt = Date()
        guard !query.isEmpty, replyingTo == nil else {
            hits = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let found: [Note]
            do {
                let data = try await Jarvis.run(["search", "--", query], timeout: Self.searchTimeout)
                found = (try? JSONDecoder().decode([Note].self, from: data)) ?? []
                guard !Task.isCancelled else { return }
                searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                // Said above the rows (a vault that's gone, say), once, until a search works again.
                let message = Day.inline(error.localizedDescription)
                if message != searchError { announce(message) }
                searchError = message
                found = []
            }
            // A failed search shows nothing rather than the last query's results.
            self.hits = Array(found.prefix(3))
            if hits.count != announcedHits, !hits.isEmpty { announce(hits.count == 1 ? "1 matching note" : "\(hits.count) matching notes") }
            announcedHits = hits.count
        }
    }

    private func reset() {
        replyingTo = nil
        query = ""
        hits = []
        picked = nil
        isTyping = false
        onFinish()
    }

    /// The CLI edits notes by read-modify-write, so vault writes from the Dock run one at a time,
    /// and only once no ask is running: a write that read a note while Claude edited it would put
    /// back the old note over Claude's edit. Asks run side by side; Claude Code's Edit already
    /// refuses a note that changed since it was read. Each write shows in the box from the moment
    /// it's queued until it's done.
    private func write(_ label: String, _ operation: @escaping @MainActor () async -> Void) {
        let entry = Busy(text: label)
        writing.append(entry)
        if !asking.isEmpty { announce("\(label) once Claude finishes") }
        let previous = writes
        writes = Task { @MainActor in
            await previous?.value
            // Until none is left, including asks started while this one waited.
            while let ask = asking.values.first { await ask.value }
            if let index = writing.firstIndex(where: { $0.id == entry.id }) {
                writing[index].waiting = false
                writing[index].started = Date()
            }
            await operation()
            writing.removeAll { $0.id == entry.id }
        }
    }

    /// Something would be lost or left half-done by quitting now: an ask running, or a write
    /// queued or under way.
    var hasWork: Bool { !asking.isEmpty || !writing.isEmpty }

    /// Quitting is waiting on `settle()`, and the box says so.
    private(set) var quitting = false

    /// Quitting: stops running asks as ⌘. does (`jarvis ask` undoes what it had changed before
    /// it exits), then lets every queued write finish, including any queued meanwhile. The box
    /// says it's finishing meanwhile.
    func settle() async {
        quitting = true
        announce("Finishing before quitting")

        asking.values.forEach { $0.cancel() }
        while let ask = asking.values.first { await ask.value }
        while let last = writes {
            await last.value
            if writes == last { break }
        }
    }

    // MARK: Meeting prompts

    func addLine() {
        lines.append(.blank)
    }

    /// By id, not index: ⌘⏎ mid-edit swaps in the next prompt's lines while the field is still
    /// editing, and a stale field must find nothing to change rather than run off the end.
    func updateLine(_ id: DraftLine.ID, _ change: (inout DraftLine) -> Void) {
        if let index = lines.firstIndex(where: { $0.id == id }) { change(&lines[index]) }
    }

    private var savedLines: [DraftLine] {
        lines.filter { $0.included && !$0.isBlank }
    }

    /// Every line left out or empty: Save would write nothing, so the card offers only Skip.
    var savesNothing: Bool { savedLines.isEmpty }

    /// Takes the prompt's id so a double-fired shortcut can't save the next prompt too.
    func savePrompt(_ id: Pending.ID) {
        // Read before `take`, which moves the card (and `lines`) on to the next prompt.
        let input = savedLines.map(\.serialized).joined(separator: "\n")
        guard !savesNothing, let current = take(id) else { return }
        write("Saving the meeting") { [self] in
            do {
                // `run` names the write for `jarvis undo`; it's there only when something was
                // written, and an older CLI leaves it out. Without it there's no Undo to offer.
                struct Resolved: Decodable { let run: String? }
                let data = try await Jarvis.run(["resolve", "--", current.noteName], input: input, timeout: Self.writeTimeout)
                let run = (try? JSONDecoder().decode(Resolved.self, from: data))?.run
                drafts[id] = nil
                bounce += 1
                let title = current.proposal.title
                show("Saved \(title)", .saved, undo: run.map { .run($0, about: title) })
            } catch {
                // Writes are planned before any commit, so a failure leaves nothing half-saved to retry over.
                // The prompt comes back (reloadPending below) with your edits, so you can try again.
                // The card closes so the failure shows instead of a different prompt swapping in.
                reviewOpen = false
                notice("Couldn't save the meeting", detail: Self.explain(error), about: current.proposal.title, origin: .meeting(id))
            }
            resolving.remove(id)
            reloadPending()
        }
    }

    /// The prompt leaves the queue at once, but is only skipped for real when the grace runs out,
    /// so Undo (⌘Z, or the box's Undo) puts it back with your edits.
    func skipPrompt(_ id: Pending.ID) {
        // Checked before anything commits, so a double-clicked Skip can't finalise its own grace,
        // and a held ⇧⌘⌫ can't skip the next prompt unread.
        guard reviewing?.id == id, !Self.keyRepeats, !resolvedJustNow() else { return }
        // A second skip inside the first's grace: the first one is final now.
        commitSkip()
        guard let current = take(id) else { return }
        skipping = current
        show("Skipped \(current.proposal.title)", .skipped, for: Self.skipGrace)
        // Paused like the box's Undo (see `show`), so the skip can't go final under your finger.
        skipTask = Task {
            if await countDown(Self.skipGrace, holds: { undoWithinReach }) { commitSkip() }
        }
    }

    func undoSkip() {
        guard let skipped = skipping else { return }
        skipTask?.cancel()
        skipping = nil
        resolving.remove(skipped.id)
        // Undone from the next prompt's card: the skipped one comes back onto it.
        reloadPending(front: skipped.id)
        show("\(skipped.proposal.title) is back", .undone)
    }

    private func commitSkip() {
        guard let skipped = skipping else { return }
        skipTask?.cancel()
        skipping = nil
        // Its Undo has nothing left to take back.
        if flash?.kind == .skipped { flash = nil }
        // Not a vault write, so it doesn't queue behind them or show in the box.
        Task {
            do {
                _ = try await Jarvis.run(["resolve", "--skip", "--", skipped.noteName], timeout: Self.writeTimeout)
                drafts[skipped.id] = nil
            } catch {
                notice("Couldn't skip the meeting", detail: Self.explain(error), about: skipped.proposal.title)
            }
            resolving.remove(skipped.id)
            reloadPending()
        }
    }

    /// Takes the open prompt off the queue for a save or skip, and moves the card on.
    private func take(_ id: Pending.ID) -> Pending? {
        guard let current = reviewing, current.id == id, !resolvedJustNow() else { return nil }
        lastResolve = Date()
        resolving.insert(id)
        pending.removeFirst()
        if reviewing == nil { closeReview() } else { promptFocus += 1 }
        return current
    }

    /// Half a second after a save or skip, ⌘⏎ and ⇧⌘⌫ are ignored, so a double press can't resolve
    /// the next prompt unread. It beeps, so a fast press isn't met with nothing.
    private func resolvedJustNow() -> Bool {
        guard Date().timeIntervalSince(lastResolve) <= 0.5 else { return false }
        NSSound.beep()
        return true
    }

    /// Draft again (⌘R) on a call Claude couldn't draft: `jarvis process` tries once more and
    /// queues the new draft over the empty one. Lines you'd typed meanwhile stay, after it.
    func draftAgain(_ id: Pending.ID) {
        guard let prompt = pending.first(where: { $0.id == id }), prompt.draftFailed == true, !drafting.contains(id) else { return }
        drafting.insert(id)
        let title = prompt.proposal.title
        write("Drafting \(title)") { [self] in
            defer { drafting.remove(id) }
            do {
                // Claude has 2 minutes for a draft (src/claude.ts); past that the CLI is stuck.
                _ = try await Jarvis.run(["process", "--", prompt.noteName], timeout: 4 * 60)
                let typed = (drafts[id] ?? []).filter { !$0.isBlank }
                drafts[id] = nil
                reloadPending()
                if !typed.isEmpty, let fresh = drafts[id] { drafts[id] = fresh.filter { !$0.isBlank } + typed }
                if reviewOpen, reviewing?.id == id { promptFocus += 1 }
            } catch {
                // Like a failed save: the card closes so the failure shows, and your lines wait.
                if reviewing?.id == id { reviewOpen = false }
                notice("Couldn't draft \(title)", detail: Self.explain(error), about: title, origin: .draft(id))
                reloadPending()
            }
        }
    }

    /// `front` puts that prompt on the open card, as an undone skip; otherwise the open card's
    /// prompt stays where it is.
    private func reloadPending(front: Pending.ID? = nil) {
        let files = (try? FileManager.default.contentsOfDirectory(at: Jarvis.pendingDir, includingPropertiesForKeys: nil)) ?? []
        var loaded = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Pending.self, from: Data(contentsOf: $0)) }
            .filter { !resolving.contains($0.id) }
            .sorted { $0.noteName < $1.noteName }
        // The open card's prompt stays first, so a late draft can't swap in under you.
        if reviewOpen, let open = loaded.firstIndex(where: { $0.id == front ?? reviewing?.id }) {
            loaded.insert(loaded.remove(at: open), at: 0)
        }
        let arrived = Set(loaded.map(\.id)).subtracting(pending.map(\.id))
        let shown = reviewing?.id
        pending = loaded
        if reviewOpen, reviewing != nil, reviewing?.id != shown { promptFocus += 1 }
        for prompt in loaded where drafts[prompt.id] == nil { drafts[prompt.id] = DraftLine.lines(for: prompt) }
        if reviewOpen, pending.isEmpty { closeReview() }
        if !arrived.isEmpty {
            attention += 1
            // The pill shows itself; VoiceOver is told. An undone skip or save coming back isn't news.
            if front == nil, let first = loaded.first(where: { arrived.contains($0.id) }) {
                announce(arrived.count == 1 ? "\(first.proposal.title), meeting prompt ready. Press Return in the empty box to open it."
                    : "\(arrived.count) meeting prompts ready. Press Return in the empty box to open them.")
            }
        }
    }

    /// A confirmation that offers Undo stays as long as a skip's grace, so there's time to
    /// press ⌥Space and then ⌘Z, and its countdown waits while the box or card has the keys.
    /// Meeting titles go in whole: the box truncates them by width, in the middle, so the
    /// person's name at the end still shows.
    /// `spoken` replaces the text for VoiceOver when the box's short line leaves out a next step
    /// that sighted users see elsewhere (Stop ⌘. in the box).
    private func show(_ text: String, _ kind: Flash.Kind, for seconds: Double? = nil, undo: Flash.Undo? = nil, spoken: String? = nil) {
        let message = Flash(text: text, kind: kind, undo: undo)
        flash = message
        announce(spoken ?? (message.offersUndo ? "\(text). Undo with Command Z." : text))
        // An auto-hidden Dock comes up for it: the box went away when you pressed ⏎.
        attention += 1
        Task {
            let seconds = seconds ?? (message.offersUndo ? Self.skipGrace : 4)
            if await countDown(seconds, lasts: { flash == message }, holds: { message.offersUndo && undoWithinReach }) { flash = nil }
        }
    }

    // MARK: First run

    /// Asks the CLI whether Jarvis has a vault. Without one, the setup bubble opens by itself and
    /// takes the keys: there's nothing else useful to do yet. If the check itself fails, or the
    /// chosen vault is missing (an unmounted drive at login), the watcher starts anyway:
    /// "Meetings paused" says what's wrong and retries, and first run stays out of it.
    func checkSetup() async {
        let status = try? JSONDecoder().decode(SetupStatus.self, from: await Jarvis.run(["setup"], timeout: Self.writeTimeout))
        guard let status, !status.ready, status.configured != true else {
            onConfigured()
            return
        }
        claudeFound = status.claude
        setup = .choose(status.vaults)
        setupSelection = 0
        requestFocus()
        attention += 1
    }

    func chooseVault(_ vault: Vault) {
        // One at a time: a second choice landing later would reopen a setup you'd finished.
        guard !settingUp else { return }
        settingUp = true
        setupError = nil
        write("Setting up") { [self] in
            defer { settingUp = false }
            do {
                _ = try await Jarvis.run(["setup", "--", vault.path], timeout: Self.writeTimeout)
                // Folders that already hold recordings, so the next question is usually one ⏎.
                let found = try? JSONDecoder().decode([MeetingFolder].self, from: await Jarvis.run(
                    ["setup", "--meetings", "--vault=\(vault.path)"], timeout: Self.writeTimeout))
                // Three at most, like the sheet's notes.
                setup = .meetings(vault, Array((found ?? []).prefix(3)))
                setupSelection = 0
                requestFocus()
                announce("Do you record calls?")
            } catch {
                setupError = Self.explain(error)
                announce(setupError ?? "")
                // The folder picker took focus and put the bubble away; bring it back to say why.
                requestFocus()
            }
        }
    }

    func pickSetupRow(_ index: Int) {
        switch setup {
        case .choose(let vaults):
            if index < vaults.count { chooseVault(vaults[index]) } else if let url = pickFolder("Use as Vault", "Choose the folder your notes are in.") {
                chooseVault(Vault(name: url.lastPathComponent, path: url.path))
            }
        case .meetings(let vault, let folders):
            if index < folders.count {
                chooseMeetings(folders[index].folder, in: vault)
            } else if index == folders.count {
                if let url = pickFolder("Use for Meetings", "Choose the folder your call recorder saves to.", in: vault) { chooseMeetings(url.path, in: vault) }
            } else if !settingUp {
                skipMeetings(vault)
            }
        default: break
        }
    }

    /// "Choose another folder…": a vault Obsidian doesn't list, or a meetings folder Jarvis
    /// didn't find. Cancelling puts the bubble back.
    private func pickFolder(_ prompt: String, _ message: String, in vault: Vault? = nil) -> URL? {
        let url = FolderPicker.pick(prompt: prompt, message: message, in: vault?.path)
        if url == nil { requestFocus() }
        return url
    }

    func chooseMeetings(_ folder: String, in vault: Vault) {
        guard !settingUp else { return }
        settingUp = true
        setupError = nil
        write("Setting up") { [self] in
            defer { settingUp = false }
            do {
                _ = try await Jarvis.run(["setup", "--meetings", "--vault=\(vault.path)", "--", folder], timeout: Self.writeTimeout)
                skipMeetings(vault)
            } catch {
                setupError = Self.explain(error)
                announce(setupError ?? "")
                requestFocus()
            }
        }
    }

    /// Not now, or the meetings folder is set: on to the invitation. Meetings start here, with
    /// the config as it'll stay; without a folder they wait quietly until one appears.
    func skipMeetings(_ vault: Vault) {
        setupError = nil
        setup = .ready(vault)
        onConfigured()
        requestFocus()
        announce(claudeFound ? "Ready. Type something to remember and press Return." : "Ready. Type something and press Command Return to add it to your Inbox.")
    }

    func finishSetup() {
        setup = nil
        reset()
    }

    // MARK: Meetings paused

    /// `detail` is the CLI's `detail:` line under its `error:`, when it wrote one.
    func watcherProblem(_ reason: String?, detail: String? = nil) {
        pausedDetail = reason == nil ? nil : detail
        meetingsPaused = reason
    }

    /// Called once ⌥Space is registered, or isn't. Taken: a neutral notice says how to capture
    /// without it, once, and Settings can say so too.
    func hotKeyRegistered(_ registered: Bool) {
        defer { hotKeyTaken = !registered }
        guard !registered, !hotKeyTaken else { return }
        notice("⌥Space is taken by another app", detail: "Click the box to capture. Free ⌥Space in that app, then reopen Jarvis.",
               about: "Keyboard shortcut", neutral: true)
    }

    /// Opening it gives the box the keys, by click or by ⏎: ⏎ is its Try again, esc closes it.
    func togglePaused() {
        if pausedOpen {
            pausedOpen = false
            isTyping = false
            onFinish()
        } else {
            reviewOpen = false
            pausedOpen = true
            onNeedsKey()
            isTyping = true
            captureFocus += 1
            if let meetingsPaused { announce([meetingsPaused, pausedDetail].compactMap(\.self).joined(separator: ". ")) }
        }
    }

    func retryWatcher() {
        pausedOpen = false
        isTyping = false
        onRetryWatcher()
        onFinish()
    }

    func openWatchLog() {
        NSWorkspace.shared.open(Jarvis.watchLog)
    }

    /// A held key repeating. `isARepeat` raises for anything but a key event, and ⏎ can arrive
    /// without one (a click, a scripted press), so ask only of key presses.
    private static var keyRepeats: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.isARepeat
    }

    /// The box's text isn't focused when it changes, so VoiceOver is told directly.
    func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
