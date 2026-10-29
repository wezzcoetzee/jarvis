import AppKit
import Observation
import SwiftUI

/// Borderless and non-activating, like Spotlight: it can take keystrokes without pulling
/// your current app to the background.
private final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Places the Dock and, like the macOS Dock, keeps it on one display at a time: pushing the
/// pointer against the bottom edge of another display moves it there. With auto-hide on it
/// slides in at the bottom edge and slides out when the pointer leaves.
@MainActor
final class DockPanelController {
    private let panel = DockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let model: DockModel
    private let preferences: Preferences
    private var autohide: Bool { preferences.autoHide }
    private var size = CGSize.zero
    private var shown = true
    /// The display the Dock is on right now.
    private var screen: NSScreen
    /// Revealed because something arrived; stays up until the pointer has been over it.
    private var sticky = false
    private var hideTimer: Timer?
    private var monitors: [Any] = []

    init(model: DockModel, shelf: AppShelf, preferences: Preferences, openSettings: @escaping () -> Void) {
        self.model = model
        self.preferences = preferences
        screen = Self.screen(at: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens[0]
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        // Clicking an app icon shouldn't take keyboard focus; only the text fields need it.
        panel.becomesKeyOnlyIfNeeded = true
        // Without this AppKit never sends mouse-moved events to the panel while it isn't key.
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let hosting = NSHostingView(rootView: DockView(model: model, shelf: shelf, openSettings: openSettings) { [weak self] size in
            self?.resize(to: size)
        })
        panel.contentView = hosting
        size = hosting.fittingSize
        shown = !autohide
        panel.alphaValue = shown ? 1 : 0
        panel.setFrame(frame(shown: shown), display: true)

        model.onNeedsKey = { [weak self] in self?.focusPanel() }
        model.onFinish = { [weak self] in self?.yieldFocus() }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.lostFocus()
                self?.pointerMoved()
            }
        }
        // Displays plugged in or out, or rearranged: never leave the Dock on one that's gone.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        watchAttention()
        watchAutoHide()
    }

    func show() {
        if shown { panel.orderFrontRegardless() }
        // Global monitors for mouse movement need no Accessibility permission (key events would).
        let moved: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.pointerMoved() } }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: moved) as Any,
            NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { moved($0); return $0 } as Any,
            // Clicks in other apps put the current answer away, like a popover.
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.clickedAway() }
            } as Any,
        ]
    }

    /// ⌥Space. Opens on the display the pointer is on.
    func focus() {
        if let here = Self.screen(at: NSEvent.mouseLocation), !Self.same(here, screen) { place(on: here) }
        model.requestFocus()
    }

    private func focusPanel() {
        reveal()
        panel.makeKeyAndOrderFront(nil)
    }

    private func yieldFocus() {
        panel.makeFirstResponder(nil)
        if autohide, !pointerIsOver, !model.holdsOpen {
            hide()
        } else {
            dropKey()
        }
    }

    /// The frontmost app never stopped being active, so the panel only has to stop being key.
    /// Ordering out is what clears key status.
    private func dropKey() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        if shown { panel.orderFrontRegardless() }
    }

    // MARK: Displays and auto-hide

    private var pointerIsOver: Bool { shown && panel.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) }

    /// The display under `point`. Bottom edges count as inside, top edges don't, so a pointer on
    /// the line between two stacked displays belongs to the upper one.
    private static func screen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.minX <= point.x && point.x < $0.frame.maxX && $0.frame.minY <= point.y && point.y < $0.frame.maxY }
    }

    /// NSScreen objects are replaced when displays change, so compare by display ID.
    private static func same(_ a: NSScreen, _ b: NSScreen) -> Bool {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (a.deviceDescription[key] as? NSNumber) == (b.deviceDescription[key] as? NSNumber)
    }

    private func screensChanged() {
        if !NSScreen.screens.contains(where: { Self.same($0, screen) }) {
            screen = Self.screen(at: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens[0]
        } else if let current = NSScreen.screens.first(where: { Self.same($0, screen) }) {
            screen = current
        }
        panel.setFrame(frame(shown: shown), display: true)
    }

    /// Moves the Dock to another display, hidden, ready to come up from that display's edge.
    private func place(on newScreen: NSScreen) {
        hideTimer?.invalidate()
        panel.orderOut(nil)
        screen = newScreen
        shown = false
        panel.alphaValue = 0
        panel.setFrame(frame(shown: false), display: false)
    }

    private func pointerMoved() {
        let pointer = NSEvent.mouseLocation
        if pointerIsOver { sticky = false }

        // Pushing against the bottom of any display brings the Dock up there.
        if let edge = Self.screen(at: pointer), pointer.y <= edge.frame.minY + 1,
           abs(pointer.x - edge.frame.midX) <= size.width / 2 + 40 {
            if !Self.same(edge, screen) { place(on: edge) }
            reveal()
            return
        }
        guard autohide else { return }
        if shown, !pointerIsOver, !sticky, !model.holdsOpen {
            scheduleHide()
        } else {
            hideTimer?.invalidate()
        }
    }

    private func scheduleHide() {
        guard hideTimer?.isValid != true else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.pointerIsOver, !self.sticky, !self.model.holdsOpen else { return }
                self.hide()
            }
        }
    }

    private func reveal(sticky: Bool = false) {
        if sticky {
            self.sticky = true
            // Like an app bouncing in the Dock: it gets your attention, then gives up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.sticky = false
                self?.pointerMoved()
            }
        }
        hideTimer?.invalidate()
        guard !shown else { return }
        shown = true
        panel.orderFrontRegardless()
        slide()
    }

    private func hide() {
        hideTimer?.invalidate()
        guard autohide, shown else { return }
        shown = false
        // ⌥Space during the slide reveals it again; only order out if it really ended hidden.
        // Ordering out also drops key status, so keystrokes go back to your app.
        slide { [weak self] in if self?.shown == false { self?.panel.orderOut(nil) } }
    }

    private func slide(then completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: shown ? .easeOut : .easeIn)
            panel.animator().setFrame(frame(shown: shown), display: true)
            panel.animator().alphaValue = shown ? 1 : 0
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }

    /// Turning auto-hide off in Settings brings the Dock up and keeps it there.
    private func watchAutoHide() {
        withObservationTracking { _ = preferences.autoHide } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.autohide {
                    self.pointerMoved()
                } else {
                    self.reveal()
                }
                self.watchAutoHide()
            }
        }
    }

    private func watchAttention() {
        withObservationTracking { _ = model.attention } onChange: { [weak self] in
            Task { @MainActor in
                self?.reveal(sticky: true)
                self?.watchAttention()
            }
        }
    }

    // MARK: Placement

    /// The panel is exactly as big as its content, so it never swallows clicks meant for the
    /// windows behind it.
    private func resize(to newSize: CGSize) {
        guard newSize.width > 0 else { return }
        size = newSize
        panel.setFrame(frame(shown: shown), display: true)
    }

    private func frame(shown: Bool) -> CGRect {
        let bottom = autohide ? screen.frame.minY : screen.visibleFrame.minY
        let up = CGRect(x: screen.frame.midX - size.width / 2, y: bottom + 2, width: size.width, height: size.height)
        if shown { return up }
        // Hidden is just below the display's edge, unless another display is arranged below
        // this one: there the Dock would show up on it, so it only dips and fades out.
        let below = up.offsetBy(dx: 0, dy: screen.frame.minY - up.maxY - 2)
        let blocked = NSScreen.screens.contains { !Self.same($0, screen) && $0.frame.intersects(below) }
        return blocked ? up.offsetBy(dx: 0, dy: -16) : below
    }
}
