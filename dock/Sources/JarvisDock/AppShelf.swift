import AppKit
import Observation

struct DockApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    let url: URL?
    var running: NSRunningApplication?

    /// Apps bounce when launched; folders like Downloads and the Trash just open.
    var isApp: Bool { url?.pathExtension == "app" }
}

/// Pinned apps from `~/.config/jarvis/dock.json` (`{"pinned": ["com.google.Chrome"]}`),
/// followed by every other running app, then Downloads and the Trash like the macOS Dock.
/// Pinned apps stay when quit, with no running dot; the rest leave when they quit. The first
/// launch fills the file from the macOS Dock, and "Keep in Dock" on an icon's menu edits it.
@MainActor @Observable
final class AppShelf {
    private(set) var apps: [DockApp] = []
    private(set) var places: [DockApp] = []
    private(set) var trashFull: Bool?
    /// The Downloads fan is open, so its tile shows the close button.
    var stackOpen = false
    @ObservationIgnored private var pinned = AppShelf.loadPinned()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var trashTimer: Timer?
    @ObservationIgnored private var newestDownload: URL?
    @ObservationIgnored private var downloadsWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)

    func start() {
        refresh()
        refreshDownloads()
        refreshTrash()
        watchDownloads()
        // Without Full Disk Access the Trash can't be watched, only checked, and a check is one
        // stat call. The icon redraws only when it goes between empty and full.
        trashTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTrash() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func isPinned(_ app: DockApp) -> Bool {
        pinned.contains(app.id)
    }

    /// Apps without a bundle id (rare command-line GUIs) can't be pinned.
    func canPin(_ app: DockApp) -> Bool {
        app.isApp && (app.running == nil || app.running?.bundleIdentifier == app.id)
    }

    func togglePin(_ app: DockApp) {
        if isPinned(app) { pinned.removeAll { $0 == app.id } } else { pinned.append(app.id) }
        savePinned()
        refresh()
    }

    func reveal(_ app: DockApp) {
        if let url = app.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// Running apps go through Launch Services too, like the macOS Dock: `activate()` alone
    /// leaves a hidden app hidden and a windowless one without a window.
    func open(_ app: DockApp) {
        if let url = app.url, app.isApp {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else if let running = app.running {
            running.activate()
        } else if let url = app.url {
            NSWorkspace.shared.open(url)
        }
    }

    private func refresh() {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0 != NSRunningApplication.current
        }
        let byID = Dictionary(running.compactMap { app in app.bundleIdentifier.map { ($0, app) } }) { first, _ in first }

        let pinnedApps = pinned.compactMap { id -> DockApp? in
            guard let url = byID[id]?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                return nil
            }
            let name = url.deletingPathExtension().lastPathComponent
            return DockApp(id: id, name: name, icon: NSWorkspace.shared.icon(forFile: url.path), url: url, running: byID[id])
        }
        let others = running
            .filter { !pinned.contains($0.bundleIdentifier ?? "") }
            .map { app in
                DockApp(
                    id: app.bundleIdentifier ?? "\(app.processIdentifier)",
                    name: app.localizedName ?? "",
                    icon: app.icon ?? NSImage(),
                    url: app.bundleURL,
                    running: app
                )
            }
        apps = pinnedApps + others
    }

    static let downloadsFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    /// Newest first, by when each file landed in Downloads: the macOS Dock's default.
    static func newestDownloads() -> [URL] {
        let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: downloadsFolder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        func added(_ url: URL) -> Date {
            let values = try? url.resourceValues(forKeys: keys)
            return values?.addedToDirectoryDate ?? values?.creationDate ?? .distantPast
        }
        return urls.map { ($0, added($0)) }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// The tile shows the newest download, like a stack in the macOS Dock, so it follows the
    /// folder. Watching needs the Downloads access macOS asks for once; without it the tile
    /// keeps the folder icon.
    private func watchDownloads() {
        let folder = Darwin.open(Self.downloadsFolder.path, O_EVTONLY)
        guard folder >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folder, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.refreshDownloads() } }
        source.setCancelHandler { Darwin.close(folder) }
        source.resume()
        downloadsWatcher = source
    }

    private func refreshDownloads() {
        let newest = Self.newestDownloads().first
        guard places.isEmpty || newest != newestDownload else { return }
        newestDownload = newest
        buildPlaces()
    }

    private func refreshTrash() {
        let full = trash.map(Self.isFull)
        guard full != trashFull else { return }
        trashFull = full
        buildPlaces()
    }

    private func buildPlaces() {
        let downloadsIcon = NSWorkspace.shared.icon(forFile: (newestDownload ?? Self.downloadsFolder).path)
        var places = [DockApp(id: "downloads", name: "Downloads", icon: downloadsIcon, url: Self.downloadsFolder)]
        if let trash {
            // The same artwork the macOS Dock uses.
            let full = trashFull == true
            let artwork = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(full ? "FullTrashIcon" : "TrashIcon").icns"
            let icon = NSImage(contentsOfFile: artwork) ?? NSImage(named: full ? NSImage.trashFullName : NSImage.trashEmptyName) ?? NSImage()
            places.append(DockApp(id: "trash", name: "Trash", icon: icon, url: trash))
        }
        self.places = places
    }

    /// Listing the Trash needs Full Disk Access, but its link count doesn't: on APFS a folder has
    /// two links plus one per item. Finder's .DS_Store is one of them and doesn't count.
    private static func isFull(_ trash: URL) -> Bool {
        var info = stat()
        guard stat(trash.path, &info) == 0 else { return false }
        let dsStore = FileManager.default.fileExists(atPath: trash.appending(path: ".DS_Store").path)
        return Int(info.st_nlink) - 2 - (dsStore ? 1 : 0) > 0
    }

    /// Asks first, like the macOS Dock, because it can't be undone. Finder does the emptying
    /// (macOS asks once to let Jarvis control Finder), off the main thread so a big Trash
    /// doesn't freeze the Dock.
    func emptyTrash() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to permanently erase the items in the Trash?"
        alert.informativeText = "You can't undo this action."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let finder = Process()
        finder.executableURL = URL(filePath: "/usr/bin/osascript")
        finder.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        finder.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.refreshTrash() }
        }
        do { try finder.run() } catch { NSLog("Jarvis: couldn't empty the Trash: \(error)") }
    }

    private struct Config: Codable { var pinned: [String] }
    private static let configURL = URL(filePath: NSHomeDirectory()).appending(path: ".config/jarvis/dock.json")

    /// Without a dock.json yet, starts from the apps kept in the macOS Dock, Finder first as it
    /// always is there, and saves them as Jarvis's own.
    private static func loadPinned() -> [String] {
        if let data = try? Data(contentsOf: configURL) {
            return (try? JSONDecoder().decode(Config.self, from: data).pinned) ?? []
        }
        let kept = (UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]] ?? [])
            .compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String }
        let pinned = ["com.apple.finder"] + kept.filter { $0 != "com.apple.finder" }
        save(pinned)
        return pinned
    }

    private func savePinned() {
        Self.save(pinned)
    }

    private static func save(_ pinned: [String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Config(pinned: pinned)) else { return }
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: configURL, options: .atomic)
    }
}
