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
/// "Keep in Dock" on an icon's menu edits the same file.
@MainActor @Observable
final class AppShelf {
    private(set) var apps: [DockApp] = []
    private(set) var places: [DockApp] = []
    @ObservationIgnored private var pinned = AppShelf.loadPinned()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func start() {
        refresh()
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

    func open(_ app: DockApp) {
        if let running = app.running {
            running.activate()
        } else if let url = app.url, app.isApp {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
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
        places = Self.places()
    }

    private static func places() -> [DockApp] {
        let files = FileManager.default
        var places: [DockApp] = []
        if let downloads = files.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            places.append(DockApp(id: "downloads", name: "Downloads", icon: NSWorkspace.shared.icon(forFile: downloads.path), url: downloads))
        }
        if let trash = try? files.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            // Listing the Trash needs Full Disk Access, which Jarvis doesn't ask for. Without it
            // the icon simply stays empty.
            let full = ((try? files.contentsOfDirectory(atPath: trash.path)) ?? []).contains { $0 != ".DS_Store" }
            // The same artwork the macOS Dock uses.
            let artwork = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(full ? "FullTrashIcon" : "TrashIcon").icns"
            let icon = NSImage(contentsOfFile: artwork) ?? NSImage(named: full ? NSImage.trashFullName : NSImage.trashEmptyName) ?? NSImage()
            places.append(DockApp(id: "trash", name: "Trash", icon: icon, url: trash))
        }
        return places
    }

    private struct Config: Codable { var pinned: [String] }
    private static let configURL = URL(filePath: NSHomeDirectory()).appending(path: ".config/jarvis/dock.json")

    private static func loadPinned() -> [String] {
        guard let data = try? Data(contentsOf: configURL) else { return [] }
        return (try? JSONDecoder().decode(Config.self, from: data).pinned) ?? []
    }

    private func savePinned() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Config(pinned: pinned)) else { return }
        try? FileManager.default.createDirectory(at: Self.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.configURL, options: .atomic)
    }
}
