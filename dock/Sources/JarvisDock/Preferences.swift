import AppKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor @Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    var autoHide: Bool {
        didSet { defaults.set(autoHide, forKey: "autoHide") }
    }

    var replaceSystemDock: Bool {
        didSet {
            defaults.set(replaceSystemDock, forKey: "replaceSystemDock")
            // `defaults` and restarting the Dock take a moment; the toggle shouldn't freeze for it.
            // One at a time, in order: a quick off-and-on mustn't interleave the two.
            let replace = replaceSystemDock
            SystemDock.queue.async { if replace { SystemDock.replace() } else { SystemDock.restore() } }
        }
    }

    var openAtLogin: Bool {
        didSet {
            guard openAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Jarvis: couldn't change open at login: \(error)")
                openAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    func refreshOpenAtLogin() {
        let enabled = SMAppService.mainApp.status == .enabled
        if openAtLogin != enabled { openAtLogin = enabled }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // First launch copies the system Dock's auto-hide, and opens at login so the meeting
        // watcher is always running.
        let systemAutoHide = UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
        defaults.register(defaults: ["autoHide": systemAutoHide, "replaceSystemDock": true])
        autoHide = defaults.bool(forKey: "autoHide")
        replaceSystemDock = defaults.bool(forKey: "replaceSystemDock")
        openAtLogin = SMAppService.mainApp.status == .enabled
        if !defaults.bool(forKey: "registeredForLogin") {
            defaults.set(true, forKey: "registeredForLogin")
            openAtLogin = true
        }
    }
}

/// Hides the macOS Dock while Jarvis runs: auto-hide with a reveal delay nobody will wait out.
/// The original settings are saved first and put back when Jarvis quits.
enum SystemDock {
    /// Every change to the macOS Dock runs here, in order, so a quick toggle or a quit never
    /// interleaves a replace with a restore.
    static let queue = DispatchQueue(label: "jarvis.system-dock")
    private static let saved = "savedSystemDock"
    private static let hiddenDelay = 1000.0
    /// `Jarvis --restore-system-dock` restores and exits, without starting the Dock.
    static let restoreFlag = "--restore-system-dock"
    /// The write end of the guard's pipe. Only Jarvis holds it, so it closes when Jarvis ends.
    nonisolated(unsafe) private static var guardPipe: Pipe?

    /// A crash skips applicationWillTerminate, which would leave the macOS Dock hidden with no
    /// Jarvis in its place. So a shell waits on a pipe that closes however Jarvis ends (a crash,
    /// SIGKILL, a normal quit), then runs `Jarvis --restore-system-dock`. After a normal quit
    /// the settings are already restored, so that finds nothing saved and does nothing.
    static func guardAgainstCrashes() {
        guard let executable = Bundle.main.executablePath else { return }
        let pipe = Pipe()
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        // Logout's SIGTERM goes to Jarvis, which restores for itself; the guard outlives it.
        shell.arguments = ["-c", "trap '' HUP INT TERM; read -r _; exec \"$0\" \(restoreFlag)", executable]
        shell.standardInput = pipe
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        do {
            try shell.run()
            try? pipe.fileHandleForReading.close()
            guardPipe = pipe
        } catch {
            NSLog("Jarvis: couldn't start the macOS Dock guard: \(error)")
        }
    }

    static func replace() {
        let dock = UserDefaults(suiteName: "com.apple.dock")
        let autohide = dock?.bool(forKey: "autohide") ?? false
        let delay = dock?.object(forKey: "autohide-delay") as? Double
        if autohide, delay == hiddenDelay { return } // Already hidden; skip restarting the Dock.

        if UserDefaults.standard.dictionary(forKey: saved) == nil {
            var original: [String: Any] = ["autohide": autohide]
            if let delay { original["delay"] = delay }
            UserDefaults.standard.set(original, forKey: saved)
        }
        run(["write", "com.apple.dock", "autohide", "-bool", "true"])
        run(["write", "com.apple.dock", "autohide-delay", "-float", "\(hiddenDelay)"])
        restartDock()
    }

    static func restore() {
        guard let original = UserDefaults.standard.dictionary(forKey: saved) else { return }
        run(["write", "com.apple.dock", "autohide", "-bool", (original["autohide"] as? Bool ?? false) ? "true" : "false"])
        if let delay = original["delay"] as? Double {
            run(["write", "com.apple.dock", "autohide-delay", "-float", "\(delay)"])
        } else {
            run(["delete", "com.apple.dock", "autohide-delay"])
        }
        UserDefaults.standard.removeObject(forKey: saved)
        restartDock()
    }

    private static func restartDock() {
        launch("/usr/bin/killall", ["Dock"])
    }

    private static func run(_ args: [String]) {
        launch("/usr/bin/defaults", args)
    }

    private static func launch(_ tool: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = args
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

@MainActor
final class SettingsWindow {
    private let preferences: Preferences
    private var window: NSWindow?

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    @discardableResult func show() -> NSWindow {
        if window == nil {
            let window = SettingsPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Jarvis Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences))
            window.center()
            self.window = window
        }
        // Login Items can be changed in System Settings while Jarvis runs.
        preferences.refreshOpenAtLogin()
        NSApp.activate()
        window!.makeKeyAndOrderFront(nil)
        return window!
    }
}

/// Jarvis has no menu bar, so ⌘W and esc have nothing to reach; the window closes itself.
private final class SettingsPanel: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { performClose(nil) }
}

private struct SettingsView: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Toggle(isOn: $preferences.autoHide) {
                Text("Automatically hide and show Jarvis")
                Text("Slides away until you push the pointer against the bottom edge.")
            }
            Toggle(isOn: $preferences.replaceSystemDock) {
                Text("Replace the macOS Dock")
                Text("Hides it while Jarvis runs, and brings it back when you quit Jarvis.")
            }
            Toggle(isOn: $preferences.openAtLogin) {
                Text("Open at login")
                Text("Jarvis also runs the meeting watcher, so leave this on to catch every meeting.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}
