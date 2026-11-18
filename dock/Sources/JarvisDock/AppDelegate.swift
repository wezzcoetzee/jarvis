import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = DockModel()
    private let shelf = AppShelf(showsRunning: Screenshots.scene == nil)
    private let preferences = Preferences(defaults: Screenshots.scene == nil ? .standard : Screenshots.defaults())
    private let watcher = Watcher()
    /// A new vault or meetings folder from Settings restarts the watcher, so it reads the change.
    private lazy var settings = SettingsWindow(preferences: preferences) { [weak self] in
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
        terminate.setEventHandler { NSApp.terminate(nil) }
        terminate.resume()
        terminateSignal = terminate
        if preferences.replaceSystemDock { SystemDock.replace() }
        NSApp.mainMenu = Self.editMenu()
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
        watcher.onProblem = { [weak self] in self?.model.watcherProblem($0) }
        Task { await model.checkSetup() }
        SystemDock.guardAgainstCrashes()
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak panel] in
            panel?.focus()
        }
        if hotKey == nil { NSLog("Jarvis: couldn't register ⌥Space, another app may own it") }
    }

    /// Opening Jarvis again while it runs (from Finder, Spotlight or Launchpad) opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Screenshots.scene == nil { settings.show() }
        return false
    }

    /// Jarvis shows no menu bar, but the menu still gives every text field the standard editing
    /// shortcuts.
    private static func editMenu() -> NSMenu {
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
        menu.addItem(NSMenuItem()) // The app menu slot macOS expects first.
        menu.addItem(editItem)
        return menu
    }

    /// Never leave you without a Dock: the macOS one comes back whenever Jarvis quits.
    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
        // Waits for a replace still under way, then restores.
        if preferences.replaceSystemDock { SystemDock.queue.sync { SystemDock.restore() } }
    }
}
