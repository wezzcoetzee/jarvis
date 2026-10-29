import AppKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor @Observable
final class Preferences {
    @ObservationIgnored private let defaults = UserDefaults.standard

    var autoHide: Bool {
        didSet { defaults.set(autoHide, forKey: "autoHide") }
    }

    var replaceSystemDock: Bool {
        didSet {
            defaults.set(replaceSystemDock, forKey: "replaceSystemDock")
            if replaceSystemDock { SystemDock.replace() } else { SystemDock.restore() }
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

    init() {
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
    private static let saved = "savedSystemDock"
    private static let hiddenDelay = 1000.0

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

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Jarvis"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Toggle("Automatically hide and show the Dock", isOn: $preferences.autoHide)
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
