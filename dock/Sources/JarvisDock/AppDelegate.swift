import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = DockModel()
    private let shelf = AppShelf(showsRunning: Screenshots.scene == nil)
    private let preferences = Preferences(defaults: Screenshots.scene == nil ? .standard : Screenshots.defaults())
    private let watcher = Watcher()
    /// A new vault or meetings folder from Settings restarts the watcher, so it reads the change.
    private lazy var settings = SettingsWindow(preferences: preferences, model: model) { [weak self] in
        if Screenshots.scene == nil { self?.watcher.restart() }
    }
    private var panel: DockPanelController?
    private var hotKey: HotKey?
    private var terminateSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: Jarvis.stateDir, withIntermediateDirectories: true)
        // `kill` and logout send SIGTERM, which would skip applicationWillTerminate and leave the
        // macOS Dock hidden. Turn it into a normal quit instead.
        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminate.setEventHandler { AppDelegate.quit() }
        terminate.resume()
        terminateSignal = terminate
        if preferences.replaceSystemDock { SystemDock.replace() }
        NSApp.mainMenu = mainMenu()
        // Screenshots pick their appearance rather than inheriting this Mac's.
        if let scene = Screenshots.scene { NSApp.appearance = Screenshots.appearance(of: scene) }

        let panel = DockPanelController(model: model, shelf: shelf, preferences: preferences) { [weak self] in
            self?.settings.show()
        }
        self.panel = panel
        model.start()
        shelf.start()
        panel.show()

        if let scene = Screenshots.scene {
            Task { await Screenshots(scene: scene, model: model, shelf: shelf, dock: panel, settings: settings).run() }
            return
        }
        // Meetings start once there's a vault: straight away, or when first run picks one.
        model.onConfigured = { [weak self] in self?.watcher.start() }
        model.onRetryWatcher = { [weak self] in self?.watcher.restart() }
        watcher.onProblem = { [weak self] in self?.model.watcherProblem($0, detail: $1) }
        Task { await model.checkSetup() }
        SystemDock.guardAgainstCrashes()
        registerHotKey()
    }

    /// ⌥Space. Another app may hold it; the Dock then says so, and opening Jarvis again (once
    /// you've freed it) tries again.
    private func registerHotKey() {
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            self?.panel?.focus()
        }
        if hotKey == nil { NSLog("Jarvis: couldn't register ⌥Space, another app may own it") }
        model.hotKeyRegistered(hotKey != nil)
    }

    /// Opening Jarvis again while it runs (from Finder, Spotlight or Launchpad) opens Settings,
    /// and has another go at ⌥Space if another app held it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard Screenshots.scene == nil else { return false }
        if hotKey == nil { registerHotKey() }
        settings.show()
        return false
    }

    /// Jarvis shows no menu bar, but the menu still gives every text field the standard editing
    /// shortcuts, and ⌘, and ⌘Q wherever Jarvis has the keys. The box and the meeting card handle
    /// ⌘, themselves first, so it never runs twice.
    private func mainMenu() -> NSMenu {
        let app = NSMenu(title: "Jarvis")
        app.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Jarvis", action: #selector(quitFromMenu), keyEquivalent: "q").target = self
        let appItem = NSMenuItem()
        appItem.submenu = app
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let menu = NSMenu()
        menu.addItem(appItem) // The app menu slot macOS expects first.
        menu.addItem(editItem)
        return menu
    }

    @objc private func showSettings() { settings.show() }

    /// One path for every quit: the safe one below.
    @objc private func quitFromMenu() { Self.quit() }

    /// Set once quitting has been answered, so the settle and its 10 s deadline reply only once.
    private var quitReplied = false

    /// Quitting mid-ask or mid-write would leave a note half-changed: running asks stop as ⌘.
    /// stops them (the CLI undoes them) and queued writes finish first, for up to 10 seconds.
    /// Quits from the run loop rather than from inside a main-queue block (a signal handler, a
    /// main-actor Task): `.terminateLater` below waits on main-actor work, which can't run while
    /// the main queue is still busy with the block that asked to quit.
    static func quit() {
        RunLoop.main.perform { NSApp.terminate(nil) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasWork else { return .terminateNow }
        Task {
            await model.settle()
            replyToQuit()
        }
        // A run-loop timer, not a Task: it fires even if a caller quit from a main-queue block and
        // the Task above can't run, so Jarvis always quits within 10 s.
        let fallback = Timer(timeInterval: 10, repeats: false) { _ in MainActor.assumeIsolated { self.replyToQuit() } }
        RunLoop.main.add(fallback, forMode: .common)
        return .terminateLater
    }

    private func replyToQuit() {
        guard !quitReplied else { return }
        quitReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// Never leave you without a Dock: the macOS one comes back whenever Jarvis quits.
    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
        // Waits for a replace still under way, then restores.
        if preferences.replaceSystemDock { SystemDock.queue.sync { SystemDock.restore() } }
    }
}
