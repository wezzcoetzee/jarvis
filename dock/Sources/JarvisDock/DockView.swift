import AppKit
import SwiftUI

/// Every Dock animation uses this spring, and only runs when something changes. Nothing loops.
private let spring = Animation.spring(response: 0.42, dampingFraction: 0.74)

private extension Color {
    static let pill = Color.white.opacity(0.14)
    static let pillActive = Color.white.opacity(0.22)
    static let edge = Color.white.opacity(0.16)
    static let secondary = Color.white.opacity(0.55)
    static let saved = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let found = Color(red: 0.04, green: 0.52, blue: 1)
    static let waiting = Color(red: 0.88, green: 0.52, blue: 0.12)
    static let failed = Color(red: 1, green: 0.27, blue: 0.23)
}

/// The system Dock's frosted glass: a real behind-window blur, clipped by a stretchable mask.
private struct Glass: NSViewRepresentable {
    let mask: NSImage

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = mask
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// Draws `shape` into a small image whose middle stretches, so one image fits any size.
    static func mask(_ shape: some Shape, caps: NSEdgeInsets) -> NSImage {
        let size = NSSize(width: caps.left + 1 + caps.right, height: caps.top + 1 + caps.bottom)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.black.setFill()
            NSBezierPath(cgPath: shape.path(in: rect).cgPath).fill()
            return true
        }
        image.capInsets = caps
        image.resizingMode = .stretch
        return image
    }
}

/// A rounded rect with a tail at the bottom left, pointing down at the capture box.
private struct BubbleShape: Shape {
    static let radius: CGFloat = 18
    static let tail: CGFloat = 9
    static let tailX: CGFloat = 32

    func path(in rect: CGRect) -> Path {
        let r = Self.radius, t = Self.tail, x = rect.minX + Self.tailX
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - t)
        var path = Path()
        path.move(to: CGPoint(x: body.minX + r, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: r)
        path.addLine(to: CGPoint(x: x + t, y: body.maxY))
        path.addLine(to: CGPoint(x: x, y: rect.maxY))
        path.addLine(to: CGPoint(x: x - t, y: body.maxY))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.minY), radius: r)
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: r)
        path.closeSubpath()
        return path
    }

    static let mask = Glass.mask(BubbleShape(), caps: NSEdgeInsets(top: radius, left: tailX + tail + 2, bottom: radius + tail, right: radius))
}

private extension View {
    func glass(_ radius: CGFloat) -> some View {
        let caps = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        return background(Glass(mask: Glass.mask(RoundedRectangle(cornerRadius: radius), caps: caps)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.18)))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
    }

    func bubbleGlass() -> some View {
        background(Glass(mask: BubbleShape.mask))
            .overlay(BubbleShape().stroke(Color.white.opacity(0.18)))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }

    func capsule(_ fill: Color) -> some View {
        frame(height: 38)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(Color.edge))
            .contentShape(Capsule())
    }

    /// Rows that slide up one after another when a card opens.
    func stagger(_ index: Int) -> some View {
        modifier(Stagger(index: index))
    }
}

private struct Stagger: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
            .onAppear { withAnimation(spring.delay(Double(index) * 0.05)) { shown = true } }
    }
}

struct DockView: View {
    @Bindable var model: DockModel
    let shelf: AppShelf
    let openSettings: () -> Void
    let resize: (CGSize) -> Void

    var body: some View {
        // Leading, so the sheet and the answer bubble rise out of the box on the left.
        VStack(alignment: .leading, spacing: 10) {
            above
                .padding(.leading, 9)
                .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity).combined(with: .offset(y: 12)))
            bar
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(14)
        .fixedSize()
        .animation(spring, value: model.showsSheet)
        .animation(spring, value: model.card)
        .animation(spring, value: model.bubble?.id)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { resize($0) }
    }

    @ViewBuilder private var above: some View {
        if model.card == .meeting, let pending = model.reviewing {
            MeetingCard(model: model, pending: pending)
        } else if model.showsSheet {
            Sheet(model: model)
        } else if let answer = model.bubble {
            AnswerBubble(model: model, activity: answer).id(answer.id)
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.22)).frame(width: 1, height: 36).padding(.horizontal, 2)
    }

    private func tiles(_ apps: [DockApp]) -> some View {
        HStack(spacing: 6) {
            ForEach(apps) { app in
                AppTile(app: app, bounce: app.id == "md.obsidian" ? model.bounce : 0) { shelf.open(app) }
                    // The icon's own menu, like the macOS Dock, instead of Jarvis's.
                    .contextMenu { AppMenu(app: app, shelf: shelf) }
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Group {
                CapturePill(model: model)
                if let pending = model.reviewing {
                    Button { model.open(.meeting) } label: {
                        Label(model.pending.count > 1 ? "\(pending.proposal.title) · \(model.pending.count)" : pending.proposal.title,
                              systemImage: "waveform")
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .capsule(.waiting)
                    }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                divider
            }
            // Line up with the icons, not with the icons plus their running dots.
            .padding(.bottom, AppTile.dotRow)
            tiles(shelf.apps)
            divider.padding(.bottom, AppTile.dotRow)
            tiles(shelf.places)
        }
        .padding(.horizontal, 9)
        .padding(.top, 7)
        .padding(.bottom, 6)
        .glass(20)
        .contextMenu {
            Button("Settings…", action: openSettings)
            Divider()
            Button("Quit Jarvis") { NSApp.terminate(nil) }
        }
        .animation(spring, value: model.pending.map(\.id))
    }
}

// MARK: The box

private struct CapturePill: View {
    @Bindable var model: DockModel

    private var icon: String {
        if model.flash != nil { return "checkmark" }
        return model.working.isEmpty ? "pencil" : "sparkles"
    }

    /// While Claude works, the box shows its current step instead of the placeholder.
    private var showsStep: Bool { !model.working.isEmpty && model.query.isEmpty && !model.isTyping && model.flash == nil }

    private var step: String {
        let current = model.working.first?.step ?? "Thinking"
        return model.working.count > 1 ? "\(model.working.count) · \(current)" : current
    }

    private var placeholder: String {
        if showsStep { return "" }
        return model.flash ?? "Capture or ask"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                // One hop per new step; nothing moves between steps.
                .symbolEffect(.bounce, value: model.working.first?.step)
            CaptureField(
                text: $model.query,
                placeholder: placeholder,
                focusCount: model.captureFocus,
                onFocus: { model.isTyping = true },
                onMove: model.move,
                onSubmit: model.submit,
                onCancel: model.cancel
            )
            .overlay(alignment: .leading) {
                if showsStep {
                    // Each new step rolls up into place, like a departures board.
                    Text(step)
                        .lineLimit(1)
                        .id(step)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                }
            }
            .clipped()
            .animation(spring, value: step)
            if !model.isTyping {
                if let oldest = model.working.first {
                    WorkingBeat(started: oldest.started)
                } else {
                    Text("⌥Space").font(.system(size: 11)).foregroundStyle(Color.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        // Grows to make room for typing, and for the step text while Claude works.
        .frame(width: model.isTyping ? 300 : showsStep ? 330 : 190)
        .capsule(model.isTyping || showsStep ? .pillActive : .pill)
        .onTapGesture { model.requestFocus() }
        .animation(spring, value: model.isTyping)
        .animation(spring, value: showsStep)
    }
}

private struct Sheet: View {
    @Bindable var model: DockModel
    @Namespace private var highlight

    var body: some View {
        VStack(spacing: 2) {
            row(0, "Ask Jarvis", icon: "sparkles", hint: "⏎")
            row(1, "Add to Inbox as is", icon: "tray.and.arrow.down", hint: "⌘⏎")
            ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, note in
                row(index + 2, note.title, icon: "doc.text", hint: "open")
            }
            row(model.searchRow, "Search Obsidian for “\(model.trimmedQuery)”", icon: "magnifyingglass", hint: "")
        }
        .padding(6)
        .frame(width: 420)
        .glass(16)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.selection)
    }

    private func row(_ index: Int, _ title: String, icon: String, hint: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 16).foregroundStyle(Color.secondary)
            Text(title).lineLimit(1)
            Spacer(minLength: 12)
            Text(hint).font(.system(size: 12)).foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            if index == model.selection {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.16))
                    .matchedGeometryEffect(id: "selection", in: highlight)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = index
            model.submit(command: false)
        }
    }
}

/// Three dots lighting in turn, and the elapsed time. Redraws three times a second, and only
/// while Claude is working, so it never runs at the display's full refresh rate.
private struct WorkingBeat: View {
    let started: Date

    var body: some View {
        TimelineView(.periodic(from: started, by: 1.0 / 3)) { context in
            let beat = Int(context.date.timeIntervalSince(started) * 3) % 3
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    ForEach(0..<3) { dot in
                        Circle()
                            .fill(Color.white.opacity(dot == beat ? 0.95 : 0.3))
                            .frame(width: 4, height: 4)
                    }
                }
                Text(started, style: .timer).monospacedDigit()
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.secondary)
        }
    }
}

// MARK: Answers

/// Claude's answer, rising out of the box in a speech bubble. It stays until it's dismissed or
/// you click somewhere else; saves confirm and go by themselves.
private struct AnswerBubble: View {
    @Bindable var model: DockModel
    let activity: Activity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(activity.text).lineLimit(1)
                Spacer(minLength: 12)
                if model.answers.count > 1 { Text("1 of \(model.answers.count)") }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.secondary)
            .stagger(0)

            content

            HStack(spacing: 8) {
                Spacer()
                actions
            }
            .padding(.top, 6)
            .stagger(3)
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 13 + BubbleShape.tail)
        .frame(width: 440, alignment: .leading)
        .bubbleGlass()
        .onExitCommand { model.dismiss(activity.id) }
    }

    @ViewBuilder private var content: some View {
        switch activity.state {
        case .running:
            EmptyView()
        case .failed(let message):
            headline("Couldn't do that")
            paragraph(message)
        case .undone:
            headline("Put back the way it was")
        case .done(let result):
            headline(result.message)
            if !result.detail.isEmpty { paragraph(result.detail) }
            if !result.notes.isEmpty {
                HStack(spacing: 6) {
                    ForEach(result.notes.prefix(3)) { note in
                        Button { model.open(note) } label: {
                            Label(note.title, systemImage: "doc.text")
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.pill))
                                .overlay(Capsule().strokeBorder(Color.edge))
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: 190, alignment: .leading)
                    }
                }
                .padding(.top, 4)
                .stagger(2)
            }
            if !result.changed.isEmpty {
                Text("Changed " + result.changed.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .stagger(2)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if case .done(let result) = activity.state {
            if !result.changed.isEmpty { button("Undo") { model.undo(activity.id) } }
            if result.kind == .found { button("Search in Obsidian") { model.openSearch(activity.text) } }
        }
        if case .failed = activity.state { button("Try again") { model.retry(activity.id) } }
        button(model.answers.count > 1 ? "Next" : "Done", primary: true) { model.dismiss(activity.id) }
            .keyboardShortcut(.defaultAction)
    }

    private func headline(_ text: String) -> some View {
        Text(text).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true).stagger(1)
    }

    /// Claude writes lists as "- item"; show them as bullets.
    private func paragraph(_ text: String) -> some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasPrefix("- ") ? "•  " + line.dropFirst(2) : String(line)
        }
        return Text(lines.joined(separator: "\n")).foregroundStyle(Color.white.opacity(0.82)).fixedSize(horizontal: false, vertical: true).stagger(1)
    }
}

// MARK: Meeting prompts

private struct MeetingCard: View {
    @Bindable var model: DockModel
    let pending: Pending
    @FocusState private var focused: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(pending.proposal.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(model.pending.count > 1 ? "1 of \(model.pending.count)" : pending.meetingDate).foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ForEach(Array($model.lines.enumerated()), id: \.element.id) { index, $line in
                HStack(spacing: 10) {
                    Button { withAnimation(spring) { line.included.toggle() } } label: {
                        Image(systemName: line.included ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(line.included ? Color.found : Color.secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    TextField("", text: $line.text)
                        .textFieldStyle(.plain)
                        .focused($focused, equals: line.id)
                        .onSubmit { model.savePrompt(pending.id) }
                        .foregroundStyle(line.included ? Color.white : Color.secondary)
                        .strikethrough(!line.included)
                    Text(line.label).font(.system(size: 11)).foregroundStyle(Color.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .stagger(index)
            }

            Button {
                model.addLine()
                focused = model.lines.last?.id
            } label: {
                Label("Add a line", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            HStack(spacing: 8) {
                Spacer()
                button("Skip") { model.skipPrompt(pending.id) }
                button("Save", primary: true) { model.savePrompt(pending.id) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520)
        .glass(18)
        .onExitCommand(perform: model.closeCard)
        .onAppear { focused = model.lines.first?.id }
        .onChange(of: model.promptFocus) { focused = model.lines.first?.id }
    }
}

private func button(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title)
            .font(.system(size: 13, weight: primary ? .semibold : .regular))
            .foregroundStyle(primary ? Color.black : Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Capsule().fill(primary ? Color.white : Color.pill))
    }
    .buttonStyle(.plain)
}

// MARK: Apps

/// The right-click menu on an icon: what the macOS Dock offers, minus window lists (those need
/// Screen Recording, which Jarvis doesn't ask for).
private struct AppMenu: View {
    let app: DockApp
    let shelf: AppShelf

    var body: some View {
        Text(app.name)
        Divider()
        if app.running == nil || !app.isApp { Button("Open") { shelf.open(app) } }
        if app.isApp, shelf.canPin(app) {
            Toggle("Keep in Dock", isOn: Binding(get: { shelf.isPinned(app) }, set: { _ in shelf.togglePin(app) }))
        }
        Button("Show in Finder") { shelf.reveal(app) }
        if let running = app.running {
            Divider()
            Button(running.isHidden ? "Show" : "Hide") {
                if running.isHidden { running.unhide() } else { running.hide() }
            }
            Button("Quit") { running.terminate() }
        }
    }
}

private struct AppTile: View {
    let app: DockApp
    let bounce: Int
    let action: () -> Void
    @State private var hovering = false
    @State private var lift: CGFloat = 0

    /// Room under each icon for its running dot, so the dot never sits on the Dock's edge.
    static let dotRow: CGFloat = 8

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 46, height: 46)
                .scaleEffect(hovering ? 1.16 : 1, anchor: .bottom)
                .offset(y: (hovering ? -5 : 0) + lift)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hovering)
            Circle()
                .fill(Color.white.opacity(app.running == nil ? 0 : 0.8))
                .frame(width: 4, height: 4)
        }
        .onHover { hovering = $0 }
        .onTapGesture {
            if app.running == nil, app.isApp { hop() }
            action()
        }
        .onChange(of: bounce) { hop() }
        .help(app.name)
    }

    /// The Dock's launch bounce, played once.
    private func hop() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { lift = -16 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.45)) { lift = 0 }
        }
    }
}

/// An AppKit text field, because SwiftUI's TextField can't reliably see ↑/↓, ⌘⏎ and esc.
private struct CaptureField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusCount: Int
    let onFocus: () -> Void
    let onMove: (Int) -> Void
    let onSubmit: (Bool) -> Void
    let onCancel: () -> Void

    final class Field: NSTextField {
        var onFocus: () -> Void = {}

        /// Only counts once the panel is key: AppKit also hands the field focus when the window
        /// first appears, and that would hold an auto-hidden Dock open.
        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became, window?.isKeyWindow == true { onFocus() }
            return became
        }

        /// ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z come from an app's Edit menu, and Jarvis has no menu bar, so the
        /// field handles them itself.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard currentEditor() != nil, flags == .command || flags == [.command, .shift] else {
                return super.performKeyEquivalent(with: event)
            }
            let action: Selector? = switch event.charactersIgnoringModifiers?.lowercased() {
            case "x": #selector(NSText.cut(_:))
            case "c": #selector(NSText.copy(_:))
            case "v": #selector(NSText.paste(_:))
            case "a": #selector(NSText.selectAll(_:))
            case "z": flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
            return super.performKeyEquivalent(with: event)
        }
    }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .white
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.onFocus = onFocus
        if field.stringValue != text { field.stringValue = text }
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor(white: 1, alpha: 0.55),
            .font: NSFont.systemFont(ofSize: 13),
        ])
        if context.coordinator.focusCount != focusCount {
            context.coordinator.focusCount = focusCount
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CaptureField
        var focusCount: Int

        init(_ parent: CaptureField) {
            self.parent = parent
            focusCount = parent.focusCount
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let command = NSApp.currentEvent?.modifierFlags.contains(.command) == true
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(command)
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            // ⌘⏎ arrives as noop: rather than insertNewline:. So does any other unhandled ⌘ key,
            // so check it really is Return (or keypad Enter) before treating it as a submit.
            case NSSelectorFromString("noop:") where command && [36, 76].contains(NSApp.currentEvent?.keyCode):
                parent.onSubmit(true)
            default: return false
            }
            return true
        }
    }
}
