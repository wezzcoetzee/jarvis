import AppKit
import SwiftUI

/// Every Dock animation uses this spring, and only runs when something changes. Nothing loops.
/// With Reduce Motion on it's a short fade instead, with no movement or overshoot.
@MainActor private var spring: Animation {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.74)
}

extension Color {
    static let pill = Color.white.opacity(0.14)
    static let pillActive = Color.white.opacity(0.22)
    static let edge = Color.white.opacity(0.16)
    /// About 4.5:1 or better on the Dock's dark glass, at 11pt.
    static let secondary = Color.white.opacity(0.75)
    static let saved = Color(red: 0.19, green: 0.82, blue: 0.35)
    /// Dark enough for white text on it (about 4.8:1).
    static let waiting = Color(red: 0.69, green: 0.37, blue: 0.03)
    static let failed = Color(red: 1, green: 0.27, blue: 0.23)
    /// The macOS Dock's badge red.
    static let badge = Color(red: 1, green: 0.23, blue: 0.19)
}

/// Every button on the glass: brighter under the pointer (a white button, a touch darker),
/// dimmer while pressed.
private struct GlassButton: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View { Hovered(configuration: configuration, primary: primary) }

    private struct Hovered: View {
        let configuration: Configuration
        let primary: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .brightness(hovering ? (primary ? -0.1 : 0.08) : 0)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hovering = $0 }
        }
    }
}

extension View {
    /// A key that presses something: ⏎, ⌘⏎, ⌘Z. One size and weight wherever one shows.
    func keyHint() -> some View {
        font(.system(size: 11)).opacity(0.75).fixedSize()
    }

    /// A name on a dark capsule: icon names on hover, and the Downloads fan's file names.
    func nameTag(highlighted: Bool = false) -> some View {
        font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(highlighted ? Color(white: 0.34) : Color(white: 0.16).opacity(0.94)))
            .overlay(Capsule().strokeBorder(Color.edge))
            .foregroundStyle(.white)
    }
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

/// One width, corner radius and inset for everything that rises above the bar.
private enum Panel {
    static let width: CGFloat = 480
    static let radius: CGFloat = 18
    static let inset: CGFloat = 16
}

/// A rounded rect with a tail at the bottom left, pointing down at the control it came from.
private struct BubbleShape: Shape {
    static let radius = Panel.radius
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

    func capsule(_ fill: Color, edge: Color = .edge) -> some View {
        frame(height: 38)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(edge))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            // Capped, so a long list (or a line you just added) isn't left waiting its turn.
            .onAppear {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : spring.delay(Double(min(index, 4)) * 0.05)) { shown = true }
            }
    }
}

struct DockView: View {
    @Bindable var model: DockModel
    let shelf: AppShelf
    let openSettings: () -> Void
    /// Opens or closes the Downloads fan.
    let openStack: () -> Void
    /// Where each icon (by app id) and the box ("capture") are, in the window, top-left origin.
    let placed: (String, CGRect) -> Void
    let resize: (CGSize) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The bar's width less its icons and the box: the meeting pill, dividers and padding.
    @State private var chrome: CGFloat = 0
    /// Where the meeting pill starts, so the meeting card can rise out of it.
    @State private var pillX: CGFloat = 0

    private var tileCount: Int { shelf.apps.count + shelf.places.count }
    /// What the box and the icons can share on this display.
    private var room: CGFloat { model.screenWidth - 28 - chrome }

    /// On a narrow display the box gives up some width first, then the icons shrink, as the
    /// macOS Dock's do.
    private var boxWidth: CGFloat {
        min(CapturePill.width, max(CapturePill.narrowest, room - CGFloat(tileCount) * (AppTile.icon + AppTile.gap)))
    }

    private var iconSize: CGFloat {
        min(AppTile.icon, max(24, ((room - boxWidth) / CGFloat(max(tileCount, 1)) - AppTile.gap).rounded(.down)))
    }

    var body: some View {
        // Leading, so the sheet and the answer bubble rise out of the box on the left.
        VStack(alignment: .leading, spacing: 10) {
            above
                // The meeting card rises out of the pill that opened it, the rest out of the box.
                .padding(.leading, model.reviewOpen ? pillX : 9)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity).combined(with: .offset(y: 12)))
            bar
        }
        .coordinateSpace(.named("dock"))
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        // Room for the name above a hovered icon.
        .padding(.top, 14 + AppTile.labelRoom)
        // The panel sits on the screen edge; the tiles reach down through this.
        .padding(.bottom, AppTile.reach)
        .fixedSize()
        .animation(spring, value: model.showsSheet)
        .animation(spring, value: model.reviewOpen)
        .animation(spring, value: model.bubble?.id)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { resize($0) }
        // The window shrinks only after the content has (see DockPanelController.resize), so
        // until then the content sits on the bottom edge rather than floating in the middle.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    @ViewBuilder private var above: some View {
        if model.reviewOpen, let pending = model.reviewing {
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
        // No spacing: each tile pads itself, so there's no gap between icons that misses.
        HStack(spacing: 0) {
            ForEach(apps) { app in
                AppTile(app: app, size: iconSize, badge: shelf.badges[app.id], bounce: app.id == "md.obsidian" ? model.bounce : 0, closes: app.id == "downloads" && shelf.stackOpen) {
                    if app.id == "downloads" { openStack() } else { shelf.open(app) }
                }
                // The icon's own menu, like the macOS Dock, instead of Jarvis's.
                .contextMenu { AppMenu(app: app, shelf: shelf) }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { placed(app.id, $0) }
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Group {
                CapturePill(model: model, width: boxWidth)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { placed("capture", $0) }
                if let pending = model.reviewing {
                    // Opens and closes the card, like the Downloads tile and its fan.
                    Button { model.toggleReview() } label: {
                        HStack(spacing: 6) {
                            // While its card is open the pill closes it, like the Downloads tile.
                            Image(systemName: model.reviewOpen ? "chevron.down" : "waveform")
                                .contentTransition(.symbolEffect(.replace))
                            // Capped, so a long meeting title can't push the icons off the screen.
                            Text(pending.proposal.title).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
                            // How many more meetings wait behind this one. The open card says
                            // "1 of 2" itself.
                            // It stays in the layout and only fades, so the pill (and every icon
                            // after it) keeps its width.
                            if model.pending.count > 1 { Text("+\(model.pending.count - 1)").foregroundStyle(.white.opacity(0.8)).opacity(model.reviewOpen ? 0 : 1) }
                        }
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .capsule(.waiting)
                    }
                    .buttonStyle(GlassButton())
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("dock")).minX } action: { pillX = $0 }
                    .accessibilityLabel(model.reviewOpen ? "Close review"
                        : model.pending.count > 1 ? "Review \(pending.proposal.title), and \(model.pending.count - 1) more" : "Review \(pending.proposal.title)")
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                }
                divider
            }
            // Line up with the icons, not with the icons plus their running dots.
            .padding(.top, 7)
            .padding(.bottom, 6 + AppTile.dotRow)
            tiles(shelf.apps)
            divider.padding(.top, 7).padding(.bottom, 6 + AppTile.dotRow)
            tiles(shelf.places)
        }
        // The tiles carry the bar's vertical padding themselves, so it's clickable.
        .padding(.horizontal, 9)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            chrome = (width - CGFloat(tileCount) * (iconSize + AppTile.gap) - boxWidth).rounded()
        }
        .glass(20)
        .contextMenu {
            Button("Settings…", action: openSettings)
            // Hidden apps have no icon to right-click, so this is the way back.
            if !shelf.hiddenApps.isEmpty {
                Menu("Hidden Apps") {
                    ForEach(shelf.hiddenApps) { app in Button(app.name) { shelf.unhide(app) } }
                }
            }
            Divider()
            Button("Quit Jarvis") { NSApp.terminate(nil) }
        }
        .animation(spring, value: model.pending.map(\.id))
    }
}

// MARK: The box

private struct CapturePill: View {
    @Bindable var model: DockModel
    /// One width in every state, so the icons beside it never move. Narrower only when the
    /// display is.
    let width: CGFloat
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 300
    static let narrowest: CGFloat = 220

    /// Hovering the resting box previews a click: the pencil tilts as if about to write.
    private var invites: Bool { hovering && !model.isTyping && !showsStep && !reduceMotion }

    /// The same glyphs as the bubble's header, so an outcome looks the same wherever it shows.
    /// A confirmation's glyph only while it's the box's text, not over what you're typing.
    private var flash: DockModel.Flash.Kind? { model.query.isEmpty ? model.flash?.kind : nil }

    private var icon: String {
        switch flash {
        case .saved: "checkmark.circle.fill"
        case .skipped: "forward.end"
        case .undone: "arrow.uturn.backward"
        case nil: tucked?.header.icon ?? (model.working.isEmpty ? "pencil" : "sparkles")
        }
    }

    /// A question or failure you clicked away from, until ⌥Space brings it back. The box shows
    /// its header glyph, so a failure stays red while it's out of sight.
    private var tucked: Activity? { model.tucked && !model.isTyping ? model.answers.first : nil }

    private var iconColor: Color { flash == .saved ? .saved : flash == nil ? tucked?.header.color ?? .white : .white }

    /// While Claude works, the box shows its current step instead of the placeholder.
    private var showsStep: Bool { !model.working.isEmpty && model.query.isEmpty && !model.isTyping && model.flash == nil && tucked == nil }

    /// What the box says when you aren't typing: a confirmation, what's waiting for you, Claude's
    /// current step, a write under way, or nothing.
    private var status: String? {
        guard model.query.isEmpty else { return nil }
        if let flash = model.flash { return flash.text }
        if tucked != nil { return model.tuckedSummary }
        if showsStep { return model.working.first?.step.map(Day.inline) ?? "Thinking" }
        if !model.isTyping, let busy = model.busy { return busy.text + "…" }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                // A fixed width, so the text after it starts in the same place in every state.
                .frame(width: 16)
                .rotationEffect(.degrees(invites ? -18 : 0))
                .offset(x: invites ? -1 : 0, y: invites ? -2 : 0)
                .contentTransition(.symbolEffect(.replace))
                // The field says what the glyph shows.
                .accessibilityHidden(true)
                // One hop per new step; nothing moves between steps.
                .symbolEffect(.bounce, value: reduceMotion ? nil : model.working.first?.step)
            CaptureField(
                text: $model.query,
                placeholder: status == nil ? "Capture or ask" : "",
                status: status,
                focusCount: model.captureFocus,
                // Opening the meeting prompt also makes the panel key; that isn't typing.
                onFocus: { if !model.reviewOpen { model.isTyping = true } },
                onMove: model.move,
                onSubmit: model.submit,
                onCancel: model.cancel,
                onUndo: model.undoBubble
            )
            .overlay(alignment: .leading) {
                if let status {
                    // Each new step rolls up into place, like a departures board.
                    Text(status)
                        .lineLimit(1)
                        .id(status)
                        // The field's placeholder value carries it for VoiceOver.
                        .accessibilityHidden(true)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                }
            }
            .clipped()
            .animation(spring, value: status)
            // The timer stays while you type the next thing, or read a confirmation, so the
            // first request isn't forgotten.
            if let oldest = model.working.first {
                WorkingBeat(started: oldest.started, more: model.working.count - 1, dots: width >= 260)
            } else if let busy = model.busy, model.flash == nil {
                WorkingBeat(started: busy.started, dots: width >= 260)
            } else if !model.isTyping, model.flash == nil {
                Text("⌥Space").font(.system(size: 11)).foregroundStyle(invites ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: width)
        // Typing also brightens the edge, so a focused box reads as focused from across the room.
        // Hover only tilts the pencil, so the active fill means the box has the keys or is working.
        .capsule(model.isTyping || showsStep ? .pillActive : .pill, edge: model.isTyping ? .white.opacity(0.4) : .edge)
        .help(model.working.map(\.text).joined(separator: "\n"))
        .onTapGesture { model.requestFocus() }
        .onHover { hovering = $0 }
        .animation(spring, value: invites)
        .animation(spring, value: model.isTyping)
        .animation(spring, value: showsStep)
        .animation(spring, value: model.flash)
    }
}

private struct Sheet: View {
    @Bindable var model: DockModel
    @Namespace private var highlight

    var body: some View {
        VStack(spacing: 2) {
            // Replying to a question: keep it in sight while you type the answer.
            if let question = model.replyingTo {
                Label(question, systemImage: "questionmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            row(0, icon: "sparkles")
            row(1, icon: "tray.and.arrow.down")
            if model.replyingTo == nil {
                // What you can do, then what's in the vault.
                if !model.hits.isEmpty { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 3) }
                ForEach(Array(model.hits.indices), id: \.self) { index in
                    row(index + 2, icon: "doc.text")
                }
                row(model.searchRow, icon: "magnifyingglass")
            }
        }
        .padding(6)
        .padding(.bottom, BubbleShape.tail)
        .frame(width: Panel.width)
        // A tail down at the box, like the bubble's: the sheet is the box's too.
        .bubbleGlass()
        .animation(spring, value: model.selection)
    }

    /// ⏎ sits on whichever row it will press, after a note's folder; ⌘⏎ always means the Inbox.
    private func hint(_ index: Int) -> String {
        let folder = model.hits.indices.contains(index - 2) ? model.hits.folder(index - 2) : ""
        let key = index == model.selection ? "⏎" : index == 1 ? "⌘⏎" : ""
        return [folder, key].filter { !$0.isEmpty }.joined(separator: "  ")
    }

    private func row(_ index: Int, icon: String) -> some View {
        let title = model.rowTitle(index)
        return Button {
            model.selection = index
            model.submit(command: false)
        } label: {
            NoteRow(icon: icon, title: title, hint: hint(index)).background {
                if index == model.selection { NoteRow.fill.matchedGeometryEffect(id: "selection", in: highlight) }
            }
        }
        .buttonStyle(.plain)
        // The pointer picks a row the way ↑↓ do, so the highlight and ⏎ follow it, as in a menu.
        // Not while the rows are still moving under a pointer that hasn't.
        .onHover { if $0, Date().timeIntervalSince(model.rowsMovedAt) > 0.4 { model.selection = index } }
        .accessibilityLabel(title)
        .accessibilityValue(model.hits.indices.contains(index - 2) ? model.hits[index - 2].folder : "")
        .accessibilityAddTraits(index == model.selection ? .isSelected : [])
    }
}

extension Activity {
    /// How it went, before you read a word: the bubble's header glyph, and the box's while the
    /// bubble is put away.
    var header: (icon: String, color: Color, spoken: String) {
        switch state {
        case .failed where neutral: ("arrow.uturn.backward", Color.secondary, "Not undone")
        case .failed, .running: ("exclamationmark.triangle.fill", Color.failed, "Failed")
        case .done(let result):
            switch result.kind {
            case .saved: ("checkmark.circle.fill", Color.saved, "Saved")
            case .found: ("magnifyingglass", Color.secondary, "Found")
            case .question: ("questionmark.circle", Color.secondary, "Question")
            case .answer: ("sparkles", Color.secondary, "Answer")
            }
        }
    }
}

/// A row of the sheet, or of a find's notes: icon, name, then its folder and key at the right.
private struct NoteRow: View {
    let icon: String
    let title: String
    let hint: String

    /// Under the row ⏎ or the pointer is on.
    static let fill = RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.16))

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 16).foregroundStyle(Color.secondary)
            Text(title).lineLimit(1)
            Spacer(minLength: 12)
            Text(hint).keyHint()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private extension [Note] {
    /// A note's folder, when the list spans more than one; otherwise it would only repeat.
    func folder(_ index: Int) -> String {
        Set(map(\.folder)).count > 1 ? self[index].folder : ""
    }
}

/// Three dots lighting in turn, and the elapsed time. Redraws three times a second, and only
/// while Claude is working, so it never runs at the display's full refresh rate.
private struct WorkingBeat: View {
    let started: Date
    /// Other requests still running behind the oldest.
    var more = 0
    /// Off in a narrow box, to leave the step room; the timer still says it's working.
    var dots = true

    var body: some View {
        TimelineView(.periodic(from: started, by: 1.0 / 3)) { context in
            let beat = Int(context.date.timeIntervalSince(started) * 3) % 3
            HStack(spacing: 6) {
                if dots { HStack(spacing: 3) {
                    ForEach(0..<3) { dot in
                        Circle()
                            .fill(Color.white.opacity(dot == beat ? 0.95 : 0.3))
                            .frame(width: 4, height: 4)
                    }
                } }
                Text(started, style: .timer).monospacedDigit()
                // Words, not "+1", which beside a timer reads as a time.
                if more > 0 { Text("\(more) more") }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(more > 0 ? "Working, and \(more) more" : "Working")
    }
}

// MARK: Answers

/// Claude's answer, rising out of the box in a speech bubble. It stays until it's dismissed or
/// you click somewhere else; saves confirm and go by themselves. With the box focused and
/// empty, ⏎ and esc dismiss it and ⌘Z undoes it, and the buttons show those keys.
private struct AnswerBubble: View {
    @Bindable var model: DockModel
    let activity: Activity

    /// The keys only reach the bubble through the box, so they're shown only while it has them.
    private var keys: Bool { model.isTyping && model.query.isEmpty }
    @State private var hoveredNote: Note.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: header.icon).foregroundStyle(header.color).frame(width: 16).accessibilityLabel(header.spoken)
                // A failure holds the only copy of what you typed, so more of it shows.
                Text(activity.text).lineLimit(activity.isFailed ? 3 : 1)
                Spacer(minLength: 12)
                if model.answers.count > 1 { Text("1 of \(model.answers.count)") }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.secondary)
            .stagger(0)

            content

            // Note links and buttons share a row when they fit, rather than leaving a gap.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    chips(fit: true)
                    Spacer(minLength: 12)
                    actions
                }
                VStack(alignment: .leading, spacing: 10) {
                    chips(fit: false)
                    HStack(spacing: 8) {
                        Spacer()
                        actions
                    }
                }
            }
            .padding(.top, 6)
            .stagger(2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 13 + BubbleShape.tail)
        .frame(width: Panel.width, alignment: .leading)
        .bubbleGlass()
        .onHover { model.bubbleHovered = $0 }
        .onAppear { model.bubbleAppeared(activity.id) }
        .onDisappear { model.bubbleHovered = false }
        // ⌘1 to ⌘3 open the note chips, and ⌘E edits a failure, while the box has the keys.
        .background {
            if keys, activity.primary == .retry {
                Button("") { model.edit(activity.id) }.keyboardShortcut("e", modifiers: .command).hidden()
            }
            if keys, case .done(let result) = activity.state {
                ForEach(Array(result.notes.prefix(3).enumerated()), id: \.offset) { index, note in
                    Button("") { model.open(note) }.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command).hidden()
                }
            }
        }
    }

    private var header: (icon: String, color: Color, spoken: String) { activity.header }

    @ViewBuilder private var content: some View {
        switch activity.state {
        case .running:
            EmptyView() // The bubble only shows finished requests.
        case .failed(let message):
            headline(message).lineLimit(4)
            // What the CLI said, for when the headline isn't enough.
            if let detail = activity.detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(Color.secondary).lineLimit(3).textSelection(.enabled).stagger(1)
            }
        case .done(let result):
            headline(result.message).lineLimit(3)
            // Claude is asked for six lines; anything much longer scrolls rather than growing the
            // bubble off the top of the display.
            if result.detail.count > 600 || result.detail.split(separator: "\n").count > 8 {
                ScrollView { paragraph(result.detail) }.frame(height: 200)
            } else if !result.detail.isEmpty {
                paragraph(result.detail)
            }
            // A save's chips already name the notes it changed; list only the others.
            if result.kind == .found { found(result.notes) }
            let others = result.changed.filter { path in !result.notes.contains { $0.path == path } }
            if !others.isEmpty {
                let also = "Also changed " + others.map(Day.note).joined(separator: ", ")
                Text(also)
                    .lineLimit(2)
                    .help(also)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .stagger(1)
            }
        }
    }

    /// A find's notes, as the sheet's rows: whole names, folders, ⌘1 to ⌘3, and the same fill
    /// under the pointer.
    private func found(_ notes: [Note]) -> some View {
        let notes = Array(notes.prefix(3))
        return VStack(spacing: 0) {
            ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                Button { model.open(note) } label: {
                    NoteRow(icon: "doc.text", title: note.name,
                            hint: [notes.folder(index), keys ? "⌘\(index + 1)" : ""].filter { !$0.isEmpty }.joined(separator: "  "))
                        .background { if hoveredNote == note.id { NoteRow.fill } }
                }
                .buttonStyle(GlassButton())
                .onHover { hoveredNote = $0 ? note.id : hoveredNote == note.id ? nil : hoveredNote }
                .help([note.name, note.folder].filter { !$0.isEmpty }.joined(separator: ", "))
                .accessibilityLabel("Open \(note.name)")
                .accessibilityValue(note.folder)
            }
        }
        // The rows' icons line up with the header's, as the sheet's line up with the box's, and
        // the last row's padding doesn't add to the gap above the buttons.
        .padding(.horizontal, -10)
        .padding(.top, 2)
        .padding(.bottom, -6)
        .stagger(2)
    }

    /// Note links, drawn like the sheet's note rows (no capsule: capsules are actions), with the
    /// same fill under the pointer. `fit` is the one-row layout, where every title shows in full
    /// or the row doesn't fit; otherwise they get a row of their own and only the long titles
    /// shorten.
    @ViewBuilder private func chips(fit: Bool) -> some View {
        if case .done(let result) = activity.state, result.kind != .found, !result.notes.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(result.notes.prefix(3).enumerated()), id: \.element.id) { index, note in
                    Button { model.open(note) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text").foregroundStyle(Color.secondary)
                            Text(note.name)
                            if keys { Text("⌘\(index + 1)").keyHint() }
                        }
                        .lineLimit(1)
                        .fixedSize(horizontal: fit, vertical: false)
                        .padding(.horizontal, 10)
                        .frame(height: Control.height)
                        .background { if hoveredNote == note.id { NoteRow.fill } }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(GlassButton())
                    .onHover { hoveredNote = $0 ? note.id : hoveredNote == note.id ? nil : hoveredNote }
                    .help([note.name, note.folder].filter { !$0.isEmpty }.joined(separator: ", "))
                    .accessibilityLabel("Open \(note.name)")
                }
            }
            // Icons line up with the header's, as a find's rows do.
            .padding(.leading, -10)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if case .done(let result) = activity.state {
                if !result.changed.isEmpty {
                    button(model.undoing.contains(activity.id) ? "Undoing…" : "Undo", hint: keys ? "⌘Z" : nil) { model.undo(activity.id) }
                }
                if result.kind == .found { button("Search in Obsidian") { model.openSearch(result.search.flatMap { $0.isEmpty ? nil : $0 } ?? activity.text) } }
            }
            // Done or Next only for what went fine; ⎋, and a failure's only button, say Dismiss.
            let done = activity.isFailed && !activity.neutral ? "Dismiss" : model.answers.count > 1 ? "Next" : "Done"
            // The white button is what ⏎ presses (DockModel.primary).
            switch activity.primary {
            case .reply:
                button("Dismiss", hint: keys ? "⎋" : nil) { model.dismiss(activity.id) }
                button("Reply", hint: keys ? "⏎" : nil, primary: true) { model.edit(activity.id) }
            case .retry:
                // This bubble holds the only copy of what you typed: Edit keeps it, Dismiss
                // (⎋) is the deliberate way to let it go.
                button("Dismiss", hint: keys ? "⎋" : nil) { model.dismiss(activity.id) }
                button("Edit", hint: keys ? "⌘E" : nil) { model.edit(activity.id) }
                button("Try again", hint: keys ? "⏎" : nil, primary: true) { model.retry(activity.id) }
            case .open:
                // Too long for the bubble: the note that holds it, opened when you ask.
                button("Dismiss", hint: keys ? "⎋" : nil) { model.dismiss(activity.id) }
                button("Open full answer", hint: keys ? "⏎" : nil, primary: true) { model.primary(activity) }
            case .dismiss:
                button(done, hint: keys ? "⏎" : nil, primary: true) { model.dismiss(activity.id) }
            }
        }
        .fixedSize()
    }

    private func headline(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true).stagger(1)
    }

    /// Claude writes lists as "- item" or "1. item"; wrapped lines hang under the text.
    private func paragraph(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                if let item = line.firstMatch(of: #/^(-|\d+\.) (.*)/#) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.1 == "-" ? "•" : item.1).monospacedDigit()
                        Text(item.2)
                    }
                } else {
                    Text(line)
                }
            }
        }
        .foregroundStyle(Color.white.opacity(0.82))
        .fixedSize(horizontal: false, vertical: true)
        // So an answer can be copied.
        .textSelection(.enabled)
        .stagger(1)
    }
}

// MARK: Meeting prompts

private struct MeetingCard: View {
    @Bindable var model: DockModel
    let pending: Pending
    @FocusState private var focused: UUID?

    /// More lines than this scroll, so Save and Skip never leave the screen.
    private static let lineHeight: CGFloat = 32
    private static let maxHeight = 7 * lineHeight
    /// A left-out line's text and destination, dimmer than secondary text so it reads as off.
    private static let leftOut = 0.45
    /// Lines wrap, so whether they overflow is a matter of height, not count.
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.system(size: 13)).foregroundStyle(Color.secondary).accessibilityHidden(true)
                Text(pending.proposal.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 12)
                Text(model.pending.count > 1 ? "\(pending.meetingDay) · 1 of \(model.pending.count)" : pending.meetingDay)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, Panel.inset)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // Always a scroll view, capped, so crossing the cap never rebuilds the rows. Its bar
            // only shows once there's something to scroll.
            ScrollViewReader { scroller in
                ScrollView {
                    rows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                }
                .scrollIndicators(rowsHeight > Self.maxHeight ? .automatic : .never)
                .frame(maxHeight: Self.maxHeight)
                // A line you move to or add below the fold scrolls into view.
                .onChange(of: focused) { _, line in
                    if let line { withAnimation(spring) { scroller.scrollTo(line) } }
                }
            }

            Button {
                // An empty last line is already the new line.
                if model.lines.last?.text.trimmingCharacters(in: .whitespaces).isEmpty != true { model.addLine() }
                focused = model.lines.last?.id
            } label: {
                Label("Add a line", systemImage: "plus")
            }
            .buttonStyle(GlassButton())
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, Panel.inset)
            .padding(.vertical, 6)

            HStack(spacing: 8) {
                Spacer()
                // With every line left out, Save would be a skip, so it says so. Skipping can't be
                // undone, so it takes a click, never ⌘⏎.
                // Not white either: white is the button a key presses.
                if model.savesNothing {
                    button("Skip") { model.skipPrompt(pending.id) }
                } else {
                    button("Skip") { model.skipPrompt(pending.id) }
                    button("Save", hint: "⌘⏎", primary: true) { model.savePrompt(pending.id) }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, Panel.inset)
            .padding(.top, 8)
            .padding(.bottom, 12 + BubbleShape.tail)
            // ⌥⏎ on the line you're editing, so including one never needs the mouse.
            .background {
                Button("") { toggleFocused() }.keyboardShortcut(.return, modifiers: .option).hidden()
            }
        }
        .frame(width: Panel.width)
        // A tail down at the pill that opened it, like the answer bubble's at the box.
        .bubbleGlass()
        .onExitCommand(perform: model.closeReview)
        .onAppear(perform: focusFirstLine)
        .onChange(of: model.promptFocus, focusFirstLine)
        .onChange(of: focused) { caretToEnd() }
    }

    private func toggleFocused() {
        guard let focused else { return }
        withAnimation(spring) { model.updateLine(focused) { $0.included.toggle() } }
    }

    /// Bound by the line's id (see `updateLine`), never by its index in the prompt.
    private func text(of line: DraftLine) -> Binding<String> {
        Binding {
            model.lines.first { $0.id == line.id }?.text ?? line.text
        } set: { text in
            model.updateLine(line.id) { $0.text = text }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.lines.enumerated()), id: \.element.id) { index, line in
                HStack(spacing: 10) {
                    Button { withAnimation(spring) { model.updateLine(line.id) { $0.included.toggle() } } } label: {
                        // Square, like a macOS checkbox; the round check means "saved" elsewhere.
                        Image(systemName: line.included ? "checkmark.square.fill" : "square")
                            .font(.system(size: 16))
                            .foregroundStyle(line.included ? Color.white : Color.secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(line.text.isEmpty ? "Include new line" : "Include \(line.text)")
                    .accessibilityValue(line.included ? "on" : "off")
                    .accessibilityAddTraits(.isToggle)
                    // Long lines wrap so you can read them. ⏎ moves down the lines, and on the
                    // last one adds another; ⌘⏎ saves.
                    TextField(line.kind == .todo ? "Todo" : "Decision", text: text(of: line), prompt: Text(line.kind == .todo ? "New todo" : "New decision"), axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.plain)
                        .focused($focused, equals: line.id)
                        .onSubmit { next(after: line.id) }
                        .foregroundStyle(Color.white.opacity(line.included ? 1 : Self.leftOut))
                        .accessibilityHint(line.alreadyTracked ? "Already on your list. Goes to the \(line.destination) if included" : "Goes to the \(line.destination)")
                    // ⌥⏎ sits on the line it will include or leave out, after its label, the way ⏎
                    // follows a note's folder in the sheet.
                    // Every row keeps the hint's room, so labels don't shift as focus moves.
                    HStack(spacing: 6) {
                        Text(line.label).font(.system(size: 11)).foregroundStyle(Color.white.opacity(line.included ? 0.75 : Self.leftOut))
                        Text("⌥⏎").keyHint().opacity(focused == line.id ? 1 : 0)
                    }
                    .accessibilityHidden(true)
                }
                .id(line.id)
                .frame(minHeight: Self.lineHeight)
                .padding(.horizontal, Panel.inset)
                .stagger(index)
            }
        }
    }

    private func next(after id: DraftLine.ID) {
        guard let index = model.lines.firstIndex(where: { $0.id == id }) else { return }
        if model.lines.indices.contains(index + 1) {
            focused = model.lines[index + 1].id
        } else if !model.lines[index].text.trimmingCharacters(in: .whitespaces).isEmpty {
            model.addLine()
            focused = model.lines.last?.id
        }
    }

    private func focusFirstLine() {
        focused = model.lines.first?.id
        caretToEnd()
    }

    /// A field selects all its text when it takes focus, so the first key you pressed would
    /// replace the todo. Put the caret at the end instead, on every move between lines.
    private func caretToEnd() {
        DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil) }
    }
}

/// Buttons and note chips share a height, so a row of both lines up.
private enum Control {
    static let height: CGFloat = 26
}

/// A capsule button. `hint` names the key that presses it.
private func button(_ title: String, hint: String? = nil, primary: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: primary ? .semibold : .regular))
            if let hint { Text(hint).keyHint() }
        }
        .foregroundStyle(primary ? Color.black : Color.white)
        .padding(.horizontal, 14)
        .frame(height: Control.height)
        .background(Capsule().fill(primary ? Color.white : Color.pill))
        .overlay(Capsule().strokeBorder(primary ? Color.clear : Color.edge))
    }
    .buttonStyle(GlassButton(primary: primary))
    // The key hint is for sighted keyboard use; VoiceOver hears the name.
    .accessibilityLabel(title)
}

// MARK: Apps

/// The right-click menu on an icon: what the macOS Dock offers, minus window lists (those need
/// Screen Recording, which Jarvis doesn't ask for).
private struct AppMenu: View {
    let app: DockApp
    let shelf: AppShelf

    var body: some View {
        if app.id == "trash" {
            Button("Open") { shelf.open(app) }
            Divider()
            Button("Empty Trash") { shelf.emptyTrash() }.disabled(shelf.trashFull != true)
        } else {
            menu
        }
    }

    @ViewBuilder private var menu: some View {
        Text(app.name)
        Divider()
        if app.running == nil || !app.isApp { Button("Open") { shelf.open(app) } }
        if app.isApp, shelf.canPin(app) {
            Toggle("Keep in Dock", isOn: Binding(get: { shelf.isPinned(app) }, set: { _ in shelf.togglePin(app) }))
            Button("Hide from Dock") { shelf.hide(app) }
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
    /// The icon's side; smaller when the bar would otherwise run off the display.
    var size = AppTile.icon
    var badge: String?
    let bounce: Int
    /// The Downloads tile while its fan is open: a button that closes it, as in the macOS Dock.
    var closes = false
    let action: () -> Void
    @State private var hovering = false
    @State private var lift: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let icon: CGFloat = 46
    /// The space each tile adds beside its icon.
    static let gap: CGFloat = 6
    /// Above the bar, for the name of the icon under the pointer.
    static let labelRoom: CGFloat = 30
    /// Room under each icon for its running dot, so the dot never sits on the Dock's edge.
    static let dotRow: CGFloat = 8
    /// From the bottom of the bar down to the screen edge.
    static let reach: CGFloat = 16

    var body: some View {
        VStack(spacing: 4) {
            icon
                .frame(width: size, height: size)
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Badge(label: badge, size: size)
                            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    }
                }
                .animation(spring, value: badge)
                .scaleEffect(hovering ? 1.16 : 1, anchor: .bottom)
                .offset(y: (hovering ? -5 : 0) + lift)
                // The name shows straight away, above the magnified icon, like the macOS Dock's.
                .overlay(alignment: .top) {
                    if hovering, !closes {
                        Text(app.name)
                            .fixedSize()
                            .nameTag()
                            // Clear of the icon at its magnified, lifted size.
                            .offset(y: -(22 + 8 + size * 0.16))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6), value: hovering)
            Circle()
                .fill(Color.white.opacity(app.running == nil ? 0 : 0.8))
                .frame(width: 4, height: 4)
        }
        // Like the macOS Dock, the whole column is the target: the gaps beside the icon, the
        // bar's padding and the strip below the bar, down to the screen edge. The window
        // server passes clicks on fully clear pixels to the window behind, so the column
        // carries a fill too faint to see.
        .padding(.horizontal, 3)
        .padding(.top, 7)
        .padding(.bottom, 6 + Self.reach)
        .background(Color.black.opacity(0.01))
        .contentShape(Rectangle())
        .padding(.bottom, -Self.reach)
        .onHover { hovering = $0 }
        .onTapGesture {
            if app.running == nil, app.isApp { hop() }
            action()
        }
        .onChange(of: bounce) { hop() }
        // One button per icon for VoiceOver, named like the macOS Dock's.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(closes ? "Close \(app.name)" : app.name)
        .accessibilityValue([app.running == nil ? nil : "running", badge].compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }

    /// The Downloads tile crossfades between its file and the close button as the fan moves.
    private var icon: some View {
        face
            .id(closes)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.8)))
            .animation(.easeOut(duration: 0.18), value: closes)
    }

    @ViewBuilder private var face: some View {
        if closes {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.12).opacity(0.9))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.18)))
                .overlay(Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white))
                .padding(4)
        } else {
            Image(nsImage: app.icon).resizable()
        }
    }

    /// The app's own count or mark, over the icon's corner like the macOS Dock's, and magnified
    /// with it.
    private struct Badge: View {
        let label: String
        let size: CGFloat

        var body: some View {
            Text(label)
                .font(.system(size: size * 0.27, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize()
                .padding(.horizontal, size * 0.1)
                .frame(minWidth: size * 0.42, minHeight: size * 0.42)
                .background(Capsule().fill(Color.badge))
                .offset(x: size * 0.1, y: -size * 0.08)
                .allowsHitTesting(false)
        }
    }

    /// The Dock's launch bounce, played once.
    private func hop() {
        guard !reduceMotion else { return }
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
    /// What the box shows in the placeholder's place (a step, a confirmation), for VoiceOver.
    let status: String?
    let focusCount: Int
    let onFocus: () -> Void
    let onMove: (Int) -> Void
    let onSubmit: (Bool) -> Void
    let onCancel: () -> Void
    /// ⌘Z with nothing typed; returns false when there's nothing for it to undo.
    let onUndo: () -> Bool

    final class Field: NSTextField {
        var onFocus: () -> Void = {}
        var onUndo: () -> Bool = { false }
        private var keyObserver: NSObjectProtocol?

        /// AppKit hands the field focus as soon as the panel appears, before it's key. A click on
        /// the field then only makes the panel key, so focus never changes again. So a click on
        /// the field that makes the panel key counts as typing. Only that click: other things
        /// make the panel key too, and ⌥Space marks typing itself.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            keyObserver = window.map { window in
                NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.currentEditor() != nil, let click = NSApp.currentEvent,
                              click.type == .leftMouseDown, click.window === self.window,
                              self.bounds.contains(self.convert(click.locationInWindow, from: nil)) else { return }
                        self.onFocus()
                    }
                }
            }
        }

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
            let key = event.charactersIgnoringModifiers?.lowercased()
            // Only once there's nothing of your own typing to undo.
            if key == "z", flags == .command, stringValue.isEmpty, currentEditor()?.undoManager?.canUndo != true, onUndo() { return true }
            let action: Selector? = switch key {
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
        // The placeholder turns into steps and confirmations, so VoiceOver gets a fixed name.
        field.setAccessibilityLabel("Capture or ask")
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        // What the box says in place of its placeholder, so VoiceOver on the box hears it too.
        field.setAccessibilityPlaceholderValue(status ?? placeholder)
        field.onFocus = onFocus
        field.onUndo = onUndo
        if field.stringValue != text { field.stringValue = text }
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor(white: 1, alpha: 0.7),
            .font: NSFont.systemFont(ofSize: 13),
        ])
        if context.coordinator.focusCount != focusCount {
            context.coordinator.focusCount = focusCount
            // Focus selects the field's text; a reply prefills it, so put the caret after it.
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                field.currentEditor()?.moveToEndOfDocument(nil)
            }
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
