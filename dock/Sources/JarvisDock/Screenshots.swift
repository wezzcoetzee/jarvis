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
    let dock: DockPanelController
    let settings: SettingsWindow

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Above everything at the Dock's own level, including a copy of Jarvis that's running.
    private static let backdropLevel = NSWindow.Level(NSWindow.Level.statusBar.rawValue + 1)
    private static let level = NSWindow.Level(NSWindow.Level.statusBar.rawValue + 2)

    /// Every path the Dock and the CLI read, which scripts/screenshots.sh points at fixtures.
    private static let fixtures = ["JARVIS_CONFIG", "JARVIS_VAULT", "JARVIS_STATE", "JARVIS_DOWNLOADS"]

    /// Called before anything loads: without the fixtures a scene would read, show and write to
    /// your real vault, config and Downloads.
    static func requireFixtures() {
        guard let scene else { return }
        let unset = fixtures.filter { ProcessInfo.processInfo.environment[$0] == nil }
        guard !unset.isEmpty else { return }
        FileHandle.standardError.write(Data("screenshot \(scene): run it from scripts/screenshots.sh (\(unset.joined(separator: ", ")) unset)\n".utf8))
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
            try capture(window, behind: backdrop)
        } catch {
            CGWarpMouseCursorPosition(pointer)
            FileHandle.standardError.write(Data("screenshot \(scene): \(error)\n".utf8))
            exit(1)
        }
        CGWarpMouseCursorPosition(pointer)
        NSApp.terminate(nil)
    }

    /// Puts the Dock in the scene's state. Returns a window to capture on its own, if the scene
    /// is one, rather than the Dock.
    private func stage() async throws -> NSWindow? {
        switch scene {
        case "resting":
            break
        case "hover-box":
            try hover("capture")
        case "hover-icon":
            try hover("com.apple.Notes")
        case "typing":
            model.requestFocus()
        case "search":
            try await type("shed")
        case "search-selected":
            try await type("shed")
            model.move(1)
            model.move(1)
        case "inbox":
            try await type("Ask Sam about borrowing the ladder", hits: false)
            model.submit(command: true)
            try await until("the confirmation") { model.flash != nil }
        case "working":
            model.ask("What did I decide about the shed roof?")
            try await until("a step") { model.working.first?.step?.hasPrefix("Searching") == true }
        case "working-two":
            model.ask("What did I decide about the shed roof?")
            model.ask("When is the plumber coming back?")
            try await until("two steps") { model.working.count == 2 && model.working.allSatisfy { $0.step != nil } }
        case "saved", "found", "answer", "question", "failed":
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
            try await until("the undo") {
                if case .undone = model.answers.first?.state { true } else { false }
            }
        case "meeting-pill":
            try await until("the meeting prompt") { model.reviewing != nil }
        case "meeting-prompt":
            try await until("the meeting prompt") { model.reviewing != nil }
            model.openReview()
        case "downloads":
            try click("downloads")
        case "settings":
            return settings.show()
        default:
            throw Failure(description: "no scene called \(scene)")
        }
        return nil
    }

    /// What each answer scene types. scripts/screenshots/bin/claude answers each one.
    private static let asks = [
        "saved": "Remind me to order cedar boards on Friday",
        "found": "Where are my notes on the Lisbon trip?",
        "answer": "What's left on the shed?",
        "question": "Move the dentist",
        "failed": "Book a table at Taberna for Saturday",
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
    /// Windows the Dock opened over the desktop, like the Downloads fan.
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

/// Dusk colours, soft enough that the frosted glass reads the way it does on a real desktop.
private struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.22), Color(red: 0.04, green: 0.05, blue: 0.09)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.55, green: 0.30, blue: 0.55).opacity(0.55), .clear], center: UnitPoint(x: 0.3, y: 0.85), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.20, green: 0.45, blue: 0.65).opacity(0.5), .clear], center: UnitPoint(x: 0.72, y: 0.7), startRadius: 0, endRadius: 600)
        }
        .ignoresSafeArea()
    }
}
