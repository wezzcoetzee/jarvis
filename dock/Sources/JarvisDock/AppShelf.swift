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
/// Apps in its `hidden` list never show, even while running, so an app left open in the
/// background stays out of the way; "Hide from Dock" adds to it and "Hidden Apps" takes away.
@MainActor @Observable
final class AppShelf {
    private(set) var apps: [DockApp] = []
    private(set) var places: [DockApp] = []
    /// What "Hidden Apps" on the Dock's own menu lists, running or not.
    private(set) var hiddenApps: [DockApp] = []
    private(set) var trashFull: Bool?
    /// The badge each running app has set on its Dock icon ("2", "•"), by app id. Screenshots
    /// stage their own, since the shelf doesn't read real apps' badges for them.
    var badges: [String: String] = [:]
    /// The Downloads fan is open, so its tile shows the close button.
    var stackOpen = false
    @ObservationIgnored private var config = AppShelf.loadConfig()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var newestDownload: URL?
    @ObservationIgnored private var downloadsWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    /// Off for screenshots, so only the pinned apps show, never whatever happens to be running.
    @ObservationIgnored private let showsRunning: Bool

    init(showsRunning: Bool = true) {
        self.showsRunning = showsRunning
    }

    func start() {
        refresh()
        refreshDownloads()
        refreshTrash()
        watchDownloads()
        // Without Full Disk Access the Trash can't be watched, only checked, and a check is one
        // stat call. Badges can't be watched either. Icons redraw only when something changed.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshTrash()
                self?.refreshBadges()
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func isPinned(_ app: DockApp) -> Bool {
        config.pinned.contains(app.id)
    }

    /// Apps without a bundle id (rare command-line GUIs) can't be pinned or hidden.
    func canPin(_ app: DockApp) -> Bool {
        app.isApp && (app.running == nil || app.running?.bundleIdentifier == app.id)
    }

    func togglePin(_ app: DockApp) {
        if isPinned(app) { config.pinned.removeAll { $0 == app.id } } else { config.pinned.append(app.id) }
        save()
    }

    /// Takes the app off the Dock without quitting it. A pinned app is unpinned too, since a
    /// hidden app can't also be kept.
    func hide(_ app: DockApp) {
        config.pinned.removeAll { $0 == app.id }
        config.hidden.append(app.id)
        save()
    }

    func unhide(_ app: DockApp) {
        config.hidden.removeAll { $0 == app.id }
        save()
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

        func installed(_ id: String) -> DockApp? {
            guard let url = byID[id]?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                return nil
            }
            let name = url.deletingPathExtension().lastPathComponent
            return DockApp(id: id, name: name, icon: NSWorkspace.shared.icon(forFile: url.path), url: url, running: byID[id])
        }
        hiddenApps = config.hidden.compactMap(installed)
        let others = running
            .filter { app in
                guard showsRunning else { return false }
                let id = app.bundleIdentifier ?? ""
                return !config.pinned.contains(id) && !config.hidden.contains(id)
            }
            .map { app in
                DockApp(
                    id: app.bundleIdentifier ?? "\(app.processIdentifier)",
                    name: app.localizedName ?? "",
                    icon: app.icon ?? NSImage(),
                    url: app.bundleURL,
                    running: app
                )
            }
        apps = config.pinned.compactMap(installed) + others
        refreshBadges()
    }

    private func refreshBadges() {
        guard showsRunning else { return }
        var badges: [String: String] = [:]
        for app in apps {
            if let running = app.running, let label = DockBadge.label(of: running) { badges[app.id] = label }
        }
        if badges != self.badges { self.badges = badges }
    }

    static let downloadsFolder = Jarvis.downloadsDir

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

    private struct Config: Codable {
        var pinned: [String]
        var hidden: [String] = []

        init(pinned: [String]) { self.pinned = pinned }

        /// Either key may be missing: files written before `hidden` existed have only `pinned`.
        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: CodingKeys.self)
            pinned = try keys.decodeIfPresent([String].self, forKey: .pinned) ?? []
            hidden = try keys.decodeIfPresent([String].self, forKey: .hidden) ?? []
        }
    }
    private static let configURL = Jarvis.configDir.appending(path: "dock.json")

    /// Without a dock.json yet, starts from the apps kept in the macOS Dock, Finder first as it
    /// always is there, and saves them as Jarvis's own.
    private static func loadConfig() -> Config {
        if let data = try? Data(contentsOf: configURL) {
            if let config = try? JSONDecoder().decode(Config.self, from: data) { return config }
            // A hand edit gone wrong. Keep it, rather than overwrite it on the next pin.
            let kept = configURL.appendingPathExtension("invalid")
            try? FileManager.default.removeItem(at: kept)
            try? FileManager.default.moveItem(at: configURL, to: kept)
            NSLog("Jarvis: dock.json isn't valid; moved it to \(kept.lastPathComponent) and started again")
        }
        let kept = (UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]] ?? [])
            .compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String }
        let config = Config(pinned: ["com.apple.finder"] + kept.filter { $0 != "com.apple.finder" })
        save(config)
        return config
    }

    private func save() {
        Self.save(config)
        refresh()
    }

    private static func save(_ config: Config) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(config) else { return }
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: configURL, options: .atomic)
    }
}

/// The label an app puts on its Dock icon (`NSApp.dockTile.badgeLabel`). Launch Services keeps it
/// as the app's StatusLabel, which any process may read with no permission, but only through
/// private calls. Each is looked up at runtime, so if macOS drops one the Dock just shows no badges.
private enum DockBadge {
    private typealias CreateASN = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
    private typealias CopyItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private static let createASN = symbol("_LSASNCreateWithPid", as: CreateASN.self)
    private static let copyItem = symbol("_LSCopyApplicationInformationItem", as: CopyItem.self)
    /// kLSDefaultSessionID: the logged-in user's session.
    private static let session: Int32 = -2

    /// RTLD_DEFAULT, which Swift doesn't import: search every loaded image.
    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
    }

    static func label(of app: NSRunningApplication) -> String? {
        guard let createASN, let copyItem,
              let asn = createASN(nil, app.processIdentifier)?.takeRetainedValue(),
              let item = copyItem(session, asn, "StatusLabel" as CFString)?.takeRetainedValue(),
              let label = (item as? NSDictionary)?["label"] as? String, !label.isEmpty
        else { return nil }
        return label
    }
}
