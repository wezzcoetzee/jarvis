import AppKit
import QuickLookThumbnailing
import SwiftUI

/// The Downloads fan, like the macOS Dock's: clicking the tile fans the newest files up and off
/// to the right, and turns the tile into a close button. A click anywhere else or esc closes it
/// too, and the round arrow at the top opens the folder. The fan has the keyboard while open, so
/// ↑ ↓ move a highlight up and down the rows and ⏎ opens the highlighted one. It gets a window of
/// its own because it reaches past the Dock's edges.
@MainActor
final class DownloadsStack {
    private let panel = FanPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var monitors: [Any] = []
    private var closedAt = Date.distantPast
    private let state = FanState()
    /// What each row opens, bottom up: a file, or nil for the folder.
    private var targets: [URL?] = []
    /// Told when the fan opens or closes, so the tile can show its close button.
    var onChange: (Bool) -> Void = { _ in }
    /// Open, and not on its way back into the tile.
    var isShown: Bool { panel.isVisible && state.open }

    init() {
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.onCancel = { [weak self] in self?.close() }
        panel.onKey = { [weak self] in self?.handle($0) }
        // Clicking anywhere else takes the keyboard back, in any app. Unlike watching for those
        // clicks, that needs no permission.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    /// A click on the Downloads tile, whose frame is in screen points. `room` is the height
    /// above it.
    func toggle(tile: CGRect, room: CGFloat) {
        // While open the tile is the close button, and its mouse-down has already closed the fan
        // (see the monitors), so the tap that follows mustn't open it again.
        guard !isShown, Date().timeIntervalSince(closedAt) > 0.3 else { return close() }

        let files = AppShelf.newestDownloads()
        let fits = max(1, Int((room - Fan.row) / Fan.row) - 1)
        let shown = Array(files.prefix(fits))
        targets = shown.map(Optional.some) + [nil]
        state.selected = nil
        let fan = Fan(files: shown, more: max(0, files.count - fits), state: state) { [weak self] in self?.open($0) }
        let hosting = FirstClickHostingView(rootView: fan)
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)
        // The first icon sits just clear of the tile's icon, so the window never covers the
        // icons beside it.
        let iconTop = tile.maxY - 7
        panel.setFrame(CGRect(origin: CGPoint(x: tile.midX - fan.origin.x, y: iconTop + 16 - fan.origin.y), size: size), display: false)
        panel.contentView = hosting
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        panel.displayIfNeeded()
        // Open only once the closed fan has been laid out at its real size. Otherwise the
        // window settling into place animates too, which shows on the first open after launch.
        DispatchQueue.main.async { [weak self] in self?.state.open = true }

        let clicked: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { if event.window !== self?.panel { self?.close() } }
        }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: clicked) as Any,
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { clicked($0); return $0 } as Any,
        ]
        onChange(true)
    }

    /// A file, or the folder for nil.
    private func open(_ url: URL?) {
        NSWorkspace.shared.open(url ?? AppShelf.downloadsFolder)
        close()
    }

    /// Rows count up from the tile, so ↑ goes to the next one. Nothing is highlighted until the
    /// first arrow, so a click on the tile shows no highlight the pointer didn't put there.
    private func handle(_ key: FanKey) {
        switch key {
        case .up: state.selected = min((state.selected ?? -1) + 1, targets.count - 1)
        case .down: state.selected = max((state.selected ?? 1) - 1, 0)
        case .enter: if let row = state.selected { open(targets[row]) }
        }
    }

    func close() {
        guard isShown else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        closedAt = Date()
        state.open = false
        panel.ignoresMouseEvents = true
        onChange(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + Fan.closing) { [weak self] in
            // Reopened meanwhile: that fan owns the window now.
            guard let self, !self.state.open else { return }
            self.panel.orderOut(nil)
            self.panel.contentView = nil
        }
    }
}

/// Takes the keyboard while open, like the macOS Dock's fan, so that taking it away closes the
/// fan, and so esc and the arrow keys reach it.
private final class FanPanel: NSPanel {
    var onCancel: () -> Void = {}
    var onKey: (FanKey) -> Void = { _ in }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }

    override func keyDown(with event: NSEvent) {
        switch (event.keyCode, event.isARepeat) {
        case (126, _): onKey(.up)
        case (125, _): onKey(.down)
        // A held ⏎ repeats; it opens the file once.
        case (36, false), (76, false): onKey(.enter)
        case (36, true), (76, true): break
        default: super.keyDown(with: event)
        }
    }
}

private enum FanKey { case up, down, enter }

@MainActor @Observable
private final class FanState {
    var open = false
    /// The row the keyboard has highlighted, counting up from the tile. The pointer takes it back.
    var selected: Int?
}

/// Rows from the bottom up, each a label and an icon, rotating clockwise and drifting right the
/// higher they go. The last row opens Downloads in Finder.
private struct Fan: View {
    let files: [URL]
    let more: Int
    let state: FanState
    let open: (URL?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let row: CGFloat = 54
    /// How long the rows take to sweep back in, before the window can go.
    static let closing: TimeInterval = 0.4
    private static let icon: CGFloat = 46
    private static let rowWidth: CGFloat = 330

    private var count: Int { files.count + 1 }
    private static func shift(_ index: Int) -> CGFloat { pow(CGFloat(index), 1.5) * 3.2 }
    private static func angle(_ index: Int) -> Angle { .degrees(4 + Double(index) * 1.4) }
    /// The tilt lifts the left end of the top labels, hence the room above the last row.
    private var size: CGSize { CGSize(width: Self.rowWidth + Self.shift(count) + 30, height: CGFloat(count) * Self.row + 94) }

    /// The bottom of the first icon, from the window's bottom-left, so the controller can sit
    /// it on the Downloads icon.
    var origin: CGPoint { CGPoint(x: center(0).x, y: size.height - center(0).y - Self.icon / 2) }

    /// Centre of row `index`'s icon, top-left origin.
    private func center(_ index: Int) -> CGPoint {
        CGPoint(x: Self.rowWidth - Self.icon / 2 + Self.shift(index), y: size.height - 4 - Self.row / 2 - CGFloat(index) * Self.row)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(files.enumerated()), id: \.element) { index, url in
                place(index, row(index, name: url.lastPathComponent, icon: .file(url), target: url))
            }
            place(files.count, row(files.count, name: more > 0 ? "\(more) More in Finder" : "Open in Finder", icon: .finder, target: nil))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func row(_ index: Int, name: String, icon: FanRow.Icon, target: URL?) -> FanRow {
        FanRow(name: name, icon: icon, selected: state.selected == index, onPointer: { state.selected = nil }) { open(target) }
    }

    /// Rows start stacked flat in the tile, just below the window, and spring up into place
    /// one after another, tilting as they go, with a little overshoot. Closing sweeps them back
    /// down, top row first. Each plays once, then everything holds still.
    private func place(_ index: Int, _ row: FanRow) -> some View {
        let open = state.open
        // With Reduce Motion the rows fade in where they belong instead of flying up.
        let at = open || reduceMotion ? center(index) : CGPoint(x: center(0).x, y: center(0).y + 56)
        let motion: Animation = reduceMotion ? .easeOut(duration: 0.15) : open
            ? .spring(response: 0.42, dampingFraction: 0.74).delay(Double(index) * 0.022)
            : .spring(response: 0.24, dampingFraction: 0.95).delay(Double(count - 1 - index) * 0.008)
        return row
            .frame(width: Self.rowWidth, height: Self.row, alignment: .trailing)
            .rotationEffect(open || reduceMotion ? Self.angle(index) : .zero, anchor: UnitPoint(x: (Self.rowWidth - Self.icon / 2) / Self.rowWidth, y: 0.5))
            .scaleEffect(open || reduceMotion ? 1 : 0.55, anchor: .trailing)
            .opacity(open ? 1 : 0)
            .offset(x: at.x - (Self.rowWidth - Self.icon / 2), y: at.y - Self.row / 2)
            .animation(motion, value: open)
    }
}

private struct FanRow: View {
    enum Icon { case file(URL), finder }

    let name: String
    let icon: Icon
    /// Highlighted by the keyboard (see FanState.selected).
    let selected: Bool
    /// The pointer arrived, so the keyboard's highlight gives way to it.
    let onPointer: () -> Void
    let action: () -> Void
    @State private var hovering = false
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .truncationMode(.middle)
                // The same tag as an icon's name on hover.
                .nameTag(highlighted: hovering || selected)
                // Long names shorten in the middle; the pill hugs the rest.
                .frame(maxWidth: 270, alignment: .trailing)
            image.frame(width: 46, height: 46)
        }
        .contentShape(Rectangle())
        .onHover {
            hovering = $0
            if $0 { onPointer() }
        }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .task { await loadThumbnail() }
    }

    @ViewBuilder private var image: some View {
        switch icon {
        case .finder:
            Circle()
                .fill(Color.solidControl)
                .overlay(Circle().strokeBorder(Color.rim))
                .overlay(Image(systemName: "arrow.forward.circle.fill").font(.system(size: 18)).foregroundStyle(Color.ink))
                .padding(3)
        case .file(let url):
            Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        }
    }

    /// A preview of the file's contents where Quick Look has one, as the macOS Dock shows.
    private func loadThumbnail() async {
        guard case .file(let url) = icon else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 46, height: 46), scale: 2, representationTypes: .thumbnail)
        thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
