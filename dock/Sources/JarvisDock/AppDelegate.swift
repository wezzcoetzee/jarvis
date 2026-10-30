import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = DockModel()
    private let shelf = AppShelf()
    private let preferences = Preferences()
    private let watcher = Watcher()
    private lazy var settings = SettingsWindow(preferences: preferences)
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
        // Demo mode (scripts/screenshots.sh) leaves the macOS Dock and the watcher alone.
        let demo = ProcessInfo.processInfo.environment["JARVIS_DEMO"]
        if demo == nil, preferences.replaceSystemDock { SystemDock.replace() }
        NSApp.mainMenu = Self.editMenu()
        if demo == nil { watcher.start() }

        let panel = DockPanelController(model: model, shelf: shelf, preferences: preferences) { [weak self] in
            self?.settings.show()
        }
        self.panel = panel
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak panel] in
            panel?.focus()
        }
        if hotKey == nil { NSLog("Jarvis: couldn't register ⌥Space, another app may own it") }
        model.start()
        shelf.start()
        panel.show()
        if let demo { model.demo(demo) }
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
        if ProcessInfo.processInfo.environment["JARVIS_DEMO"] == nil, preferences.replaceSystemDock { SystemDock.restore() }
    }
}
