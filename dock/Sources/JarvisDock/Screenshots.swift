import AppKit
import SwiftUI

/// `JARVIS_SCREENSHOT=<scene>` runs the real Dock, stages one scene through the same calls the
/// UI makes, saves it to `JARVIS_SCREENSHOT_OUT` and quits. scripts/screenshots.sh points every
/// path at fixtures and runs each scene. The Dock draws over its own backdrop, so nothing else
/// on screen ends up in a shot. Nothing here touches the macOS Dock, login items or ⌥Space.
@MainActor
struct Screenshots {
    static let scene = ProcessInfo.processInfo.environment["JARVIS_SCREENSHOT"]

    /// Throwaway settings: the Dock stays up, the macOS Dock is left alone, and login counts as
    /// already handled so nothing registers.
    static func defaults() -> UserDefaults {
        let name = "jarvis-screenshots"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(false, forKey: "autoHide")
        defaults.set(false, forKey: "replaceSystemDock")
        defaults.set(true, forKey: "registeredForLogin")
        return defaults
    }

    let scene: String
    let model: DockModel
    let shelf: AppShelf
    let dock: DockPanelController
    let settings: SettingsWindow

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Above everything at the Dock's own level, including a copy of Jarvis that's running. Not
    /// higher: raising the Downloads fan to screen-saver level takes its key status, which closes it.
    private static let backdropLevel = NSWindow.Level(NSWindow.Level.statusBar.rawValue + 1)
    private static let level = NSWindow.Level(NSWindow.Level.statusBar.rawValue + 2)

    /// Every path the Dock and the CLI read, which scripts/screenshots.sh points at fixtures.
    /// `JARVIS_OBSIDIAN` too: first run lists Obsidian's vaults, and yours must never show.
    private static let fixtures = ["JARVIS_CONFIG", "JARVIS_VAULT", "JARVIS_STATE", "JARVIS_DOWNLOADS", "JARVIS_OBSIDIAN"]

    /// Dark, unless the scene is a Light mode one.
    static func appearance(of scene: String) -> NSAppearance? {
        NSAppearance(named: scene.hasPrefix("light") ? .aqua : .darkAqua)
    }

    /// Called before anything loads: without the fixtures a scene would read, show and write to
    /// your real vault, config and Downloads.
    /// Set isn't enough: each has to be in the temp folder screenshots.sh makes, so variables
    /// exported for CLI testing can't point a scene at the real vault.
    static func requireFixtures() {
        guard let scene else { return }
        // `mktemp -d` uses $TMPDIR, or /tmp without one.
        let temps = [NSTemporaryDirectory(), "/tmp"].map { URL(filePath: $0).resolvingSymlinksInPath().path + "/" }
        let env = ProcessInfo.processInfo.environment
        let wrong = fixtures.filter { name in
            // First run leaves JARVIS_VAULT empty (unset to the CLI), which falls back to
            // ~/Documents/Vault: safe only when HOME is the temp folder too.
            let value = name == "JARVIS_VAULT" && env[name] == "" ? env["HOME"] : env[name]
            guard let path = value else { return true }
            let resolved = URL(filePath: path).standardized.resolvingSymlinksInPath().path
            return !temps.contains { resolved.hasPrefix($0) }
        }
        guard !wrong.isEmpty else { return }
        FileHandle.standardError.write(Data("screenshot \(scene): run it from scripts/screenshots.sh (\(wrong.joined(separator: ", ")) unset or not in a temp folder)\n".utf8))
        exit(1)
    }

    func run() async {
        let pointer = Self.topLeft(NSEvent.mouseLocation)
        let backdrop = Self.backdrop(on: dock.window.screen ?? NSScreen.screens[0])
        backdrop.orderFrontRegardless()
        dock.window.level = Self.level
        dock.window.orderFrontRegardless()
        do {
            // The shelf's icons and the first layout settle before anything is staged.
            try await pause(0.8)
            let window = try await stage()
            // The Downloads fan opens its own window at the Dock's usual level.
            for window in shown(besides: backdrop) { window.level = Self.level }
            try await pause(1.2) // Every spring and stagger has finished.
            // The panel can lose key to another app mid-scene, which closes an open card or fan,
            // and the shot would show the wrong state. Fail instead, so it gets re-run.
            if ["meeting-prompt", "meeting-skip", "light-meeting", "draft-failed", "skip-undo"].contains(scene), !model.reviewOpen { throw Failure(description: "the card closed before capture; run it again") }
            if scene == "downloads", !dock.stackShown { throw Failure(description: "the fan closed before capture; run it again") }
            if ["search", "search-selected"].contains(scene), !model.showsSheet { throw Failure(description: "the box lost focus before capture; run it again") }
            if scene == "search-selected", !notePicked { throw Failure(description: "the picked note moved before capture; run it again") }
            if scene == "open-app", !model.showsSheet { throw Failure(description: "the box lost focus before capture (typing \(model.isTyping), query \"\(model.query)\", review \(model.reviewOpen), paused \(model.pausedOpen)); run it again") }
            if scene == "typing", model.query != "Call Sam about" || !model.isTyping { throw Failure(description: "the box lost its text or focus before capture; run it again") }
            if scene == "stop", !model.isTyping || model.working.isEmpty { throw Failure(description: "the box lost focus or the ask ended before capture; run it again") }
            if scene == "paused-open", !model.pausedOpen { throw Failure(description: "the card closed before capture; run it again") }
            // A key pressed on the real keyboard lands in the focused box, and the sheet would
            // cover the bubble.
            if scene == "answer-keys", !model.query.isEmpty { throw Failure(description: "something was typed in the box (\"\(model.query)\"); leave the keyboard alone and run it again") }
            if scene == "first-run" || scene.hasPrefix("setup-"), !model.showsSetup { throw Failure(description: "the setup bubble closed before capture; run it again") }
            try capture(window, behind: backdrop)
        } catch {
            CGWarpMouseCursorPosition(pointer)
            FileHandle.standardError.write(Data("screenshot \(scene): \(error)\n".utf8))
            exit(1)
        }
        CGWarpMouseCursorPosition(pointer)
        AppDelegate.quit()
    }

    /// Puts the Dock in the scene's state. Returns a window to capture on its own, if the scene
    /// is one, rather than the Dock.
    private func stage() async throws -> NSWindow? {
        switch scene {
        case "resting":
            shelf.badges = ["com.apple.mail": "3"]
        case "hover-box":
            try hover("capture")
        case "hover-icon":
            try hover("com.apple.Notes")
        case "typing":
            // Focused, with text in the box and no results yet to show.
            try await type("Call Sam about", hits: false)
            try await until("the box to be typed in") { model.isTyping && model.query == "Call Sam about" }
        case "search":
            try await type("shed")
        case "search-selected":
            // `type` waits for the hits, so the rows below Inbox exist before the selection moves.
            try await type("shed")
            try await until("a note to pick") { !model.hits.isEmpty }
            model.move(1)
            model.move(1)
            try await until("the sheet with a note picked") { model.showsSheet && notePicked }
        case "inbox":
            try await type("Ask Sam about borrowing the ladder", hits: false)
            model.submit(command: true)
            try await until("the confirmation") { model.flash != nil }
        case "working":
            model.ask("What did I decide about the shed roof?")
            try await until("a step") { model.working.first?.step?.hasPrefix("Searching") == true }
        case "stop":
            // While Claude works and the box has focus, Stop ⌘. sits beside the timer.
            model.ask("What did I decide about the shed roof?")
            try await until("a step") { model.working.first?.step?.hasPrefix("Searching") == true }
            model.requestFocus()
            try await until("the box to have focus") { model.isTyping }
        case "working-two":
            model.ask("What did I decide about the shed roof?")
            model.ask("When is the plumber coming back?")
            try await until("two steps") { model.working.count == 2 && model.working.allSatisfy { $0.step != nil } }
        case "saved", "found", "answer", "question", "failed", "open-answer":
            model.ask(Self.asks[scene]!)
            try await until("the answer") { !model.answers.isEmpty }
        case "queue":
            model.ask(Self.asks["found"]!)
            try await until("the first answer") { model.answers.count == 1 }
            model.ask(Self.asks["answer"]!)
            try await until("the second answer") { model.answers.count == 2 }
        case "undone":
            model.ask(Self.asks["saved"]!)
            try await until("the save") { !model.answers.isEmpty }
            model.undo(model.answers[0].id)
            try await until("the undo") { model.flash?.kind == .undone }
        case "reply":
            model.ask(Self.asks["question"]!)
            try await until("the question") { !model.answers.isEmpty }
            model.edit(model.answers[0].id)
            try await pause(0.2)
            model.query += "to Thursday"
            (dock.window.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
        case "undo-skipped":
            // You edit the note after the save, so undo leaves it alone and says so.
            model.ask(Self.asks["saved"]!)
            try await until("the save") { !model.answers.isEmpty }
            guard case .done(let result) = model.answers[0].state, let changed = result.changed.first else {
                throw Failure(description: "the save changed nothing")
            }
            let note = URL(filePath: ProcessInfo.processInfo.environment["JARVIS_VAULT"]!).appending(path: changed)
            try (String(contentsOf: note, encoding: .utf8) + "- [ ] Typed after the save\n").write(to: note, atomically: true, encoding: .utf8)
            model.undo(model.answers[0].id)
            try await until("the notice") {
                if case .failed = model.answers.first?.state { true } else { false }
            }
        case "answer-keys":
            model.ask(Self.asks["saved"]!)
            try await until("the answer") { !model.answers.isEmpty }
            // The keys show while the empty box has focus; `run` fails the scene if anything got typed.
            model.requestFocus()
            try await until("the box to have focus") { model.isTyping }
        case "narrow":
            // A display too narrow for every icon at full size: they shrink to fit.
            model.screenWidth = 760
        case "meeting-pill":
            try await until("the meeting prompt") { model.reviewing != nil }
        case "meeting-prompt", "light-meeting", "draft-failed":
            // `light-meeting` is the same card in Light mode (see `appearance`). `draft-failed`
            // is a call Claude couldn't draft (scripts/screenshots.sh queues only that one).
            try await until("the meeting prompt") { model.reviewing != nil }
            model.openReview()
        case "meeting-skip":
            // Every line left out: Skip is the only button, and takes a click.
            try await until("the meeting prompt") { model.reviewing != nil }
            model.openReview()
            model.lines = model.lines.map { line in
                var line = line
                line.included = false
                return line
            }
        case "waiting":
            // A click elsewhere puts a question away without dropping it; the box says so.
            model.ask(Self.asks["question"]!)
            try await until("the question") { !model.answers.isEmpty }
            try await pause(2.2)
            model.clickedAway()
            try await until("the question tucked away") { model.tucked }
        case "first-run":
            // No vault yet (scripts/screenshots.sh leaves JARVIS_VAULT empty), so the CLI
            // offers the fixture's made-up Obsidian vaults.
            await model.checkSetup()
            try await until("the vaults") { model.setupAsks }
        case "setup-meetings", "setup-ready", "setup-no-claude":
            await model.checkSetup()
            try await until("the vaults") { model.setupAsks }
            // ⏎ on the first vault, then (past the meetings question) on the folder it found.
            model.submit(command: false)
            try await until("the meetings question") { if case .meetings = model.setup { true } else { false } }
            if scene == "setup-meetings" { break }
            // The stand-in `claude` is always on PATH, so a missing one is staged.
            if scene == "setup-no-claude" { model.claudeFound = false }
            model.submit(command: false)
            try await until("the invitation") { if case .ready = model.setup { true } else { false } }
        case "open-app":
            // Typing an app's name offers it at the top of the sheet. The sheet only shows while
            // the box has focus, which `appMatch` alone doesn't wait for.
            try await type("saf", hits: false)
            try await until("the box to be typed in") { model.isTyping }
            try await until("the app row") { model.showsSheet && model.appMatch != nil }
        case "paused", "paused-open":
            // What `jarvis watch` says when the vault has moved (src/main.ts). A missing meetings
            // folder isn't breakage: the watcher waits for it quietly.
            model.watcherProblem("Can't find your vault at ~/Documents/Personal", detail: "Move it back, or choose it again in Settings.")
            if scene == "paused-open" {
                try await pause(0.3)
                model.togglePaused()
            }
        case "skip-undo":
            try await until("the meeting prompt") { model.reviewing != nil }
            model.openReview()
            try await pause(0.6)
            guard let id = model.reviewing?.id else { throw Failure(description: "no prompt to skip") }
            model.skipPrompt(id)
            try await until("the skip") { model.skipping != nil }
        case "light":
            // Light mode (see `appearance`): a save, the bubble and the bar on light glass.
            model.ask(Self.asks["saved"]!)
            try await until("the answer") { !model.answers.isEmpty }
        case "downloads":
            try click("downloads")
        case "settings":
            return settings.show()
        default:
            throw Failure(description: "no scene called \(scene)")
        }
        return nil
    }

    /// ↓↓ from Ask lands on the first note.
    private var notePicked: Bool {
        if case .note = model.rows[model.selection] { true } else { false }
    }

    /// What each answer scene types. scripts/screenshots/bin/claude answers each one.
    private static let asks = [
        "saved": "Remind me to order cedar boards on Friday",
        "found": "Where are my notes on the Lisbon trip?",
        "answer": "What's left on the shed?",
        "question": "Move the dentist",
        "failed": "Book a table at Taberna for Saturday",
        "open-answer": "Plan my week around the shed",
    ]

    // MARK: Driving the real UI

    private func type(_ text: String, hits: Bool = true) async throws {
        model.requestFocus()
        try await pause(0.3)
        model.query = text
        // Set all at once, the text arrives selected; typed, the caret sits after it.
        try await pause(0.1)
        (dock.window.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
        if hits { try await until("search results") { !model.hits.isEmpty } }
    }

    /// An icon by app id, or the box ("capture").
    private func frame(of id: String) throws -> CGRect {
        guard let frame = dock.screenFrame(of: id) else { throw Failure(description: "nothing on the Dock called \(id)") }
        return frame
    }

    /// Mouse events go straight to the Dock's window, so the real pointer never moves.
    private func event(_ type: NSEvent.EventType, at screenPoint: CGPoint) -> NSEvent? {
        let window = dock.window
        return NSEvent.mouseEvent(
            with: type, location: window.convertPoint(fromScreen: screenPoint), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    private func send(_ type: NSEvent.EventType, at screenPoint: CGPoint) {
        if let event = event(type, at: screenPoint) { dock.window.sendEvent(event) }
    }

    /// SwiftUI asks where the real pointer is, so the hover scenes move it there. `run` puts it
    /// back afterwards.
    private func hover(_ id: String) throws {
        let target = try frame(of: id)
        let point = CGPoint(x: target.midX, y: target.midY)
        CGWarpMouseCursorPosition(Self.topLeft(point))
        if let moved = event(.mouseMoved, at: point) {
            for area in dock.window.contentView?.trackingAreas ?? [] { (area.owner as? NSResponder)?.mouseMoved(with: moved) }
        }
    }

    private func click(_ id: String) throws {
        let target = try frame(of: id)
        let point = CGPoint(x: target.midX, y: target.midY)
        dock.window.ignoresMouseEvents = false
        send(.leftMouseDown, at: point)
        send(.leftMouseUp, at: point)
    }

    private func until(_ what: String, timeout: Double = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw Failure(description: "timed out waiting for \(what)") }
            try await pause(0.1)
        }
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    // MARK: Capturing

    /// Quartz and screencapture measure from the top left of the main display; AppKit from its
    /// bottom left.
    private static func topLeft(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: NSScreen.screens[0].frame.maxY - point.y)
    }

    /// A wallpaper of its own behind the Dock's whole area, so the glass has something to blur
    /// and no other window can show through.
    private static func backdrop(on screen: NSScreen) -> NSWindow {
        let frame = CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: min(screen.frame.height, 900))
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = backdropLevel
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: Wallpaper())
        return window
    }

    /// The Dock and any window it opened (the Downloads fan), with room for their shadows.
    private func shown(besides backdrop: NSWindow) -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0.level >= .statusBar && $0 !== dock.window && $0 !== backdrop }
    }

    private func captureRect(behind backdrop: NSWindow) -> CGRect {
        let union = shown(besides: backdrop).reduce(dock.contentFrame) { $0.union($1.frame) }
        return union.insetBy(dx: -28, dy: -20).intersection(dock.window.screen?.frame ?? union)
    }

    private func capture(_ window: NSWindow?, behind backdrop: NSWindow) throws {
        guard let out = ProcessInfo.processInfo.environment["JARVIS_SCREENSHOT_OUT"] else {
            throw Failure(description: "JARVIS_SCREENSHOT_OUT isn't set")
        }
        var args = ["-x"]
        if let window {
            args += ["-l", "\(window.windowNumber)"]
        } else {
            let rect = captureRect(behind: backdrop)
            let origin = Self.topLeft(CGPoint(x: rect.minX, y: rect.maxY))
            args += ["-R", "\(Int(origin.x)),\(Int(origin.y)),\(Int(rect.width)),\(Int(rect.height))"]
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = args + [out]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(description: "screencapture exited \(process.terminationStatus)") }
    }
}

/// Dusk colours, soft enough that the frosted glass reads the way it does on a real desktop. In
/// Light mode, the same shapes at midday.
private struct Wallpaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let light = scheme == .light
        ZStack {
            LinearGradient(colors: light
                ? [Color(red: 0.86, green: 0.89, blue: 0.95), Color(red: 0.76, green: 0.82, blue: 0.9)]
                : [Color(red: 0.10, green: 0.12, blue: 0.22), Color(red: 0.04, green: 0.05, blue: 0.09)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.55, green: 0.30, blue: 0.55).opacity(light ? 0.25 : 0.55), .clear], center: UnitPoint(x: 0.3, y: 0.85), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.20, green: 0.45, blue: 0.65).opacity(light ? 0.3 : 0.5), .clear], center: UnitPoint(x: 0.72, y: 0.7), startRadius: 0, endRadius: 600)
        }
        .ignoresSafeArea()
    }
}
