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

/// The open panel for "Choose another folder…", in first run and in Settings.
@MainActor
enum FolderPicker {
    static func pick(prompt: String, message: String, in folder: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        panel.directoryURL = folder.map { URL(filePath: $0) }
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Settings' vault and meetings rows: what first run chose, and the same choices again. Reads
/// and writes go through `jarvis setup`, so the vault logic stays in the CLI.
@MainActor @Observable
final class VaultSettings {
    private(set) var vault: String?
    private(set) var vaultLabel = ""
    private(set) var vaults: [Vault] = []
    /// Vault-relative; nil when meetings are off.
    private(set) var meetings: String?
    private(set) var folders: [MeetingFolder] = []
    /// Why the last change didn't take, under the rows.
    private(set) var error: String?
    /// A change landed, so the meeting watcher should start again with it.
    @ObservationIgnored var onChange: () -> Void = {}
    /// Changes run one after another: each rewrites config.json, and a meetings folder belongs
    /// to whichever vault the change before it chose.
    @ObservationIgnored private var changes: Task<Void, Never>?

    /// On every show, so an old error doesn't linger.
    func load() async {
        error = nil
        guard let status = try? JSONDecoder().decode(SetupStatus.self, from: await Jarvis.run(["setup"], timeout: 30)) else { return }
        vault = status.vault
        vaultLabel = status.vaultLabel
        vaults = status.vaults
        meetings = status.meetings
        folders = (try? JSONDecoder().decode([MeetingFolder].self, from: await Jarvis.run(["setup", "--meetings", "--vault=\(status.vault)"], timeout: 30))) ?? []
    }

    func chooseVault(_ path: String) { change { ["--", path] } }
    func chooseMeetings(_ folder: String) { change { ["--meetings", "--vault=\(self.vault ?? "")", "--", folder] } }
    func turnMeetingsOff() { change { ["--meetings", "--off"] } }

    /// `args` is read when the change's turn comes, after any change queued before it.
    private func change(_ args: @escaping () -> [String]) {
        let previous = changes
        changes = Task {
            await previous?.value
            do {
                _ = try await Jarvis.run(["setup"] + args(), timeout: 60)
                error = nil
                onChange()
                await load()
            } catch {
                self.error = [error.localizedDescription, (error as? Jarvis.Failure)?.detail].compactMap(\.self).joined(separator: ". ")
            }
        }
    }
}

@MainActor
final class SettingsWindow {
    private let preferences: Preferences
    private let vaultSettings = VaultSettings()
    private var window: NSWindow?

    init(preferences: Preferences, onConfigChange: @escaping () -> Void = {}) {
        self.preferences = preferences
        vaultSettings.onChange = onConfigChange
    }

    @discardableResult func show() -> NSWindow {
        if window == nil {
            let window = SettingsPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Jarvis Settings"
            window.isReleasedWhenClosed = false
            // Otherwise the window stays on the Space it first opened in (another desktop or a
            // full-screen app), and opening Jarvis from anywhere else sends you back there.
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, vault: vaultSettings))
            window.center()
            self.window = window
        }
        // Login Items can be changed in System Settings while Jarvis runs, and the vault by hand.
        preferences.refreshOpenAtLogin()
        Task { await vaultSettings.load() }
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
    let vault: VaultSettings

    var body: some View {
        Form {
            VaultSection(settings: vault)
            Section {
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
            KeysSection()
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}

/// Vault and Meetings, as pop-up menus offering what first run offered.
private struct VaultSection: View {
    let settings: VaultSettings
    /// The menus' extra items, which aren't folders.
    private static let other = "\u{0}other", off = "\u{0}off"

    private var vaultChoice: Binding<String> {
        Binding {
            settings.vault ?? ""
        } set: { choice in
            if choice != Self.other {
                settings.chooseVault(choice)
            } else if let url = FolderPicker.pick(prompt: "Use as Vault", message: "Choose the folder your notes are in.") {
                settings.chooseVault(url.path)
            }
        }
    }

    private var meetingsChoice: Binding<String> {
        Binding {
            settings.meetings ?? Self.off
        } set: { choice in
            switch choice {
            case Self.off: settings.turnMeetingsOff()
            case Self.other:
                if let url = FolderPicker.pick(prompt: "Use for Meetings", message: "Choose the folder your call recorder saves to.", in: settings.vault) {
                    settings.chooseMeetings(url.path)
                }
            default: settings.chooseMeetings(choice)
            }
        }
    }

    /// The current folder's recordings, or what it's waiting for.
    private var meetingsDetail: String {
        guard let folder = settings.meetings else { return "Off. Nothing is drafted until you choose a folder." }
        guard let found = settings.folders.first(where: { $0.folder == folder }) else { return "Waiting for recordings in \(folder)." }
        return "\(found.recordings == 1 ? "1 recording" : "\(found.recordings) recordings"). Follow-ups are drafted from new ones."
    }

    var body: some View {
        // Once loaded, so the menus never show an empty choice.
        if settings.vault != nil { rows }
    }

    private var rows: some View {
        Section {
            Picker(selection: vaultChoice) {
                ForEach(settings.vaults) { Text($0.name).tag($0.path) }
                // The vault in use, even if Obsidian doesn't list it.
                if let vault = settings.vault, !settings.vaults.contains(where: { $0.path == vault }) {
                    Text(URL(filePath: vault).lastPathComponent).tag(vault)
                }
                Divider()
                Text("Choose another folder…").tag(Self.other)
            } label: {
                Text("Vault")
                Text(settings.vaultLabel).lineLimit(1).truncationMode(.head)
            }
            Picker(selection: meetingsChoice) {
                // The count is in the line under "Meetings", so the button stays a folder name.
                ForEach(settings.folders) { Text($0.folder).tag($0.folder) }
                if let folder = settings.meetings, !settings.folders.contains(where: { $0.folder == folder }) {
                    Text(folder).tag(folder)
                }
                Divider()
                Text("Choose another folder…").tag(Self.other)
                Text("Off").tag(Self.off)
            } label: {
                Text("Meetings")
                Text(meetingsDetail)
            }
            if let error = settings.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
        .pickerStyle(.menu)
    }
}

/// Every key the Dock answers to, in one place: on screen they only show while the box has them.
private struct KeysSection: View {
    private static let keys = [
        ("Open or close the box, from anywhere", "⌥Space"),
        ("Ask Jarvis", "⏎"),
        ("Add to your Inbox as is", "⌘⏎"),
        ("Pick a note, or an app above Ask", "↑ ↓"),
        ("Clear, then close", "⎋"),
        ("Undo a save or skip, or bring back what ⎋ cleared", "⌘Z"),
        ("Open an answer's notes", "⌘1 to ⌘3"),
        ("Edit a failed request", "⌘E"),
        ("Include or leave out a meeting line", "⌥⏎"),
        ("Save a meeting prompt", "⌘⏎"),
    ]

    var body: some View {
        // One tight list rather than a row each, so the window still fits a small display.
        Section("Keys") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                ForEach(Self.keys, id: \.0) { does, key in
                    GridRow {
                        Text(key).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(does)
                    }
                }
            }
            .font(.callout)
            .padding(.vertical, 4)
        }
    }
}
