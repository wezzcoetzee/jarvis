---
name: Jarvis
description: A macOS Dock replacement with a capture box, drawn as one pane of frosted glass.
colors:
  ink: "#FFFFFF"
  ink-secondary: "rgba(255, 255, 255, 0.75)"
  glass-fill: "rgba(255, 255, 255, 0.14)"
  glass-fill-active: "rgba(255, 255, 255, 0.22)"
  glass-fill-row: "rgba(255, 255, 255, 0.16)"
  glass-edge: "rgba(255, 255, 255, 0.16)"
  glass-rim: "rgba(255, 255, 255, 0.18)"
  glass-edge-focused: "rgba(255, 255, 255, 0.40)"
  divider: "rgba(255, 255, 255, 0.22)"
  separator: "rgba(255, 255, 255, 0.10)"
  name-tag: "color(srgb 0.16 0.16 0.16 / 0.94)"
  name-tag-highlighted: "color(srgb 0.34 0.34 0.34)"
  saved-green: "color(srgb 0.19 0.82 0.35)"
  waiting-amber: "color(srgb 0.69 0.37 0.03)"
  failed-red: "color(srgb 1 0.27 0.23)"
  badge-red: "color(srgb 1 0.23 0.19)"
  paused-red: "color(srgb 0.72 0.16 0.13)"
  primary-fill: "#FFFFFF"
  on-primary: "#000000"
  ink-light: "rgba(0, 0, 0, 0.88)"
  ink-secondary-light: "rgba(0, 0, 0, 0.60)"
  glass-fill-light: "rgba(0, 0, 0, 0.06)"
  glass-fill-active-light: "rgba(0, 0, 0, 0.10)"
  glass-edge-light: "rgba(0, 0, 0, 0.10)"
  glass-rim-light: "rgba(0, 0, 0, 0.10)"
  primary-fill-light: "color(srgb 0.11 0.11 0.11)"
  on-primary-light: "#FFFFFF"
  name-tag-light: "color(srgb 0.97 0.97 0.97 / 0.96)"
  saved-green-light: "color(srgb 0.14 0.6 0.27)"
  failed-red-light: "color(srgb 0.86 0.16 0.12)"
typography:
  headline:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "15px"
    fontWeight: 600
  body:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "13px"
    fontWeight: 400
  body-strong:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "13px"
    fontWeight: 600
  name:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "12px"
    fontWeight: 500
  label:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "11px"
    fontWeight: 400
rounded:
  row: "9px"
  tile: "10px"
  panel: "18px"
  bar: "20px"
  capsule: "9999px"
spacing:
  hairline: "2px"
  xs: "4px"
  sm: "6px"
  md: "8px"
  lg: "10px"
  xl: "14px"
  panel-inset: "16px"
components:
  bar:
    backgroundColor: "{colors.glass-fill}"
    rounded: "{rounded.bar}"
    padding: "0 9px"
  panel:
    backgroundColor: "{colors.glass-fill}"
    textColor: "{colors.ink}"
    rounded: "{rounded.panel}"
    padding: "13px 16px"
    width: "480px"
  capture-box:
    backgroundColor: "{colors.glass-fill}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.capsule}"
    padding: "0 14px"
    height: "38px"
    width: "300px"
  capture-box-active:
    backgroundColor: "{colors.glass-fill-active}"
    textColor: "{colors.ink}"
    rounded: "{rounded.capsule}"
    height: "38px"
  button-primary:
    backgroundColor: "{colors.primary-fill}"
    textColor: "{colors.on-primary}"
    typography: "{typography.body-strong}"
    rounded: "{rounded.capsule}"
    padding: "0 14px"
    height: "26px"
  button-secondary:
    backgroundColor: "{colors.glass-fill}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.capsule}"
    padding: "0 14px"
    height: "26px"
  meeting-pill:
    backgroundColor: "{colors.waiting-amber}"
    textColor: "{colors.ink}"
    rounded: "{rounded.capsule}"
    padding: "0 14px"
    height: "38px"
  note-row-selected:
    backgroundColor: "{colors.glass-fill-row}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.row}"
    padding: "6px 10px"
  paused-pill:
    backgroundColor: "{colors.paused-red}"
    textColor: "#FFFFFF"
    rounded: "{rounded.capsule}"
    padding: "0 14px"
    height: "38px"
  name-tag:
    backgroundColor: "{colors.name-tag}"
    textColor: "{colors.ink}"
    typography: "{typography.name}"
    rounded: "{rounded.capsule}"
    padding: "0 10px"
    height: "22px"
  badge:
    backgroundColor: "{colors.badge-red}"
    textColor: "{colors.ink}"
    rounded: "{rounded.capsule}"
  app-tile:
    size: "46px"
    padding: "7px 3px 6px"
---

# Design System: Jarvis

Source of truth: `dock/Sources/JarvisDock/DockView.swift` (tokens at the top of the file: `Color` extension, `Panel`, `Control`, `AppTile`, `CapturePill`, `BubbleShape`, and the shared `spring`) and `DownloadsStack.swift`. Rendered truth: `screenshots/`. Values are SwiftUI points written as px. Colors are written as `color(srgb …)` so they equal the Swift `Color(red:green:blue:)` and `Color(white:)` components exactly; translucent whites are `Color.white.opacity(…)`.

## Overview

**Creative North Star: "One Pane of Glass"**

Jarvis is the macOS Dock, and everything it adds is made of the same glass. The bar, the sheet of matching notes, the answer bubble and the meeting card are all real behind-window blur (`NSVisualEffectView`, `.hudWindow` material) with a faint rim and one soft shadow. Nothing sits on the glass as a separate card. The only things above the bar that aren't glass are borrowed from the macOS Dock itself: an icon's name on hover and the Downloads fan, both name tags floating free. Like the macOS Dock, the glass follows Light and Dark mode: white ink on dark glass, black ink on light. A panel grows out of the control that opened it: the sheet and the bubble rise from the capture box, the meeting card and the paused card rise from their pills, and each keeps a tail pointing back down at its source.

The system is native and restrained. Type is San Francisco at the sizes the macOS Dock and HUD windows use. Icons are SF Symbols. Color is almost entirely ink at different opacities over the glass (white in Dark mode, black in Light); the only hues are status (green saved, amber waiting, red failed or paused) and the system badge red. Brand lives in the details: the speech-bubble tail, the step that rolls up in the box like a departures board, the pencil that tilts when you hover the box.

Density is a Dock's: one 38px row of controls at rest, panels capped at 480px wide, and every state reached by keyboard with the key printed beside the thing it presses.

**Key Characteristics:**
- One material. Every surface is the same frosted glass with a 0.18 white rim.
- Panels rise out of their source and point back at it with a tail.
- Ink at opacity is the whole neutral palette, white or black by appearance; hue means status.
- San Francisco and SF Symbols only. Nothing branded.
- Key hints sit beside what they press, at one size everywhere.
- Motion is one spring, played once per change.

## Colors

Ink at stepped opacities over the glass, with status hues and the system badge red. Every token has a Dark and a Light value (the `-light` keys), resolved by the panel's appearance through `Color.adaptive` at the top of `DockView.swift`.

### Primary
- **Glass Ink** (`ink`, `ink-light`): all primary text and glyphs.
- **Primary Fill** (`primary-fill`, `primary-fill-light`): the one button per panel a key presses (Done, Save, Try again, Next). White with black text on dark glass, near-black with white text on light: the most contrast the glass allows is how the eye finds the default action.

### Secondary
- **Waiting Amber** (`waiting-amber`): the meeting pill only, meaning "a meeting prompt is waiting for you". Dark enough for white text at about 4.8:1, in both appearances.
- **Paused Red** (`paused-red`): the "Meetings paused" pill only. The failure red darkened for white text (about 6:1), in both appearances.

### Tertiary
- **Saved Green** (`saved-green`): the saved checkmark glyph, in the bubble header and in the box's confirmation. Glyph only, never a fill.
- **Failed Red** (`failed-red`): the failure triangle glyph. Stays on the box's glyph while a failure is put away, so it remains red out of sight.
- **Badge Red** (`badge-red`): the unread badge on app icons. Matches the macOS Dock's badge.

### Neutral
- **Secondary Ink** (`ink-secondary`): headers, folders, key hints, timers, placeholder, and the neutral notice glyph (`info.circle`: an undo that kept your edit, ⌥Space taken by another app). About 4.5:1 or better on the glass at 11px.
- **Glass Fill** (`glass-fill`): resting capture box and secondary buttons.
- **Active Fill** (`glass-fill-active`): the capture box while it has the keys or Claude is working.
- **Row Highlight** (`glass-fill-row`): under the row that ⏎ or the pointer is on.
- **Edge** (`glass-edge`): stroke on capsules and secondary buttons. **Focused Edge** (`glass-edge-focused`) replaces it while typing, so a focused box reads as focused from across the room.
- **Rim** (`glass-rim`): stroke around every glass surface (bar, panels, Downloads tile).
- **Divider** (`divider`): the 1×36 vertical rules between the box, apps and places.
- **Separator** (`separator`): the horizontal rule between actions and notes in the sheet.
- **Name Tag** (`name-tag`, `name-tag-highlighted`): the dark capsule behind an icon's name on hover and the Downloads fan's file names.

### Named Rules
**The Hue Means Status Rule.** Color other than ink appears only to say saved, waiting, failed, paused or unread. A decorative hue is a bug.

**The One Primary Button Rule.** Each panel has at most one primary-fill button (white in Dark mode, near-black in Light). Every other action is a translucent capsule.

**The Dimmed, Not Removed Rule.** A left-out meeting line's text drops to 0.55 ink (0.65 under Increase Contrast) rather than disappearing or striking through, so it can be brought back. Its destination label stays Secondary Ink, so it stays readable at 11px.

**The Increase Contrast Rule.** With Increase Contrast on, text and edges step up and fills stay put: Secondary Ink goes to 0.9 (Light 0.8), key hints to 0.9, a left-out line to 0.65, the answer body to 0.95 (Light 0.88) and the Edge to 0.4 (Light 0.3). The Rim goes to 0.5 (Light 0.4), the Divider to 0.45 (Light 0.35) and the Separator to 0.3 (Light 0.22), so the shapes the fills define stay findable. The capture field's placeholder follows (0.9, Light 0.8). Every ink goes through `ink(…)` in `DockView.swift`, so a new one says its own step.

## Typography

**Body Font:** San Francisco (system font, `.system(size:)`)

**Character:** The Mac's own voice. No display face, no brand font; hierarchy comes from size and weight steps that match the macOS Dock and HUD windows.

### Hierarchy
- **Headline** (600, 15px): the answer's one-line headline, the meeting card title.
- **Body** (400, 13px): the default for the whole Dock. Capture text, note rows, button labels.
- **Body Strong** (600, 13px): the primary button's label. The meeting pill uses 500 at 13px.
- **Name** (500, 12px): icon names on hover, Downloads file names.
- **Label** (400, 11px): bubble headers, folders, key hints (⏎, ⌘⏎, ⌥Space at 0.75 opacity), timers (monospaced digits), "1 of 2", "Already listed". This is the floor; nothing is smaller.

### Named Rules
**The One Key Hint Rule.** A key that presses something is always 11px at 0.75 opacity, via `keyHint()`. Never bolder, never a keycap graphic.

**The Eleven Floor Rule.** 11px is the smallest text in the Dock. The badge scales with the icon (0.27 of its side) and is the only exception.

## Layout

The Dock is a single horizontal bar pinned to the bottom edge of one display: capture box, optional meeting pill, divider, apps, divider, places (Downloads, Trash). The bar pads 9px horizontally and the window pads 14px around it, with 30px of room above for hover names and 16px below for the tiles to reach the screen edge.

- **Fixed widths so nothing jumps.** The capture box is 300px in every state (220px minimum on a narrow display). App icons are 46px with 6px between tiles. On a narrow display the box gives up width first, then icons shrink (24px minimum), as the macOS Dock's do.
- **Panels are 480px wide**, left-aligned to the box (9px in) or to the meeting pill, and stack 10px above the bar.
- **Inside panels:** 16px horizontal inset; rows pad 10px by 6px; sheet rows 2px apart; meeting lines as tall as their text with one 14px gap between them, scrolling past seven lines.
- **Controls share a height.** Buttons and note chips are 26px tall so a row of both lines up. Capsules on the bar are 38px.
- **Glyphs get a fixed 16px column plus an 8px gap** (`GlyphColumn`, shared by the box, sheet, bubbles and cards), so the text after them starts in the same place in every state.
- **Widths that change fade instead of reflowing.** The "+1" on the meeting pill stays in the layout and fades, so every icon after it keeps its place.

## Elevation & Depth

Depth comes from the material, not from stacking. The bar and every panel are the same behind-window blur, separated from the desktop by a 0.18 white rim and one soft shadow. There is no tonal layering of surfaces on top of the glass; fills on the glass are translucent white, not darker or lighter panels. Name tags (hover names, Downloads fan) are the exception: small near-opaque capsules (dark in Dark mode, near-white in Light) with no blur and no shadow, as in the macOS Dock. The `.hudWindow` material itself turns light in Light mode; nothing tints it by hand.

### Shadow Vocabulary
Each shadow is drawn outside its shape only (`glassShadow`), never under the glass. A shadow on the whole view also falls beneath the translucent fill, and Light glass shows it as a grey band inside the side edges.

- **Bar** (`shadow(color: black 0.3, radius: 10, y: 5)`): the Dock bar and rounded glass surfaces.
- **Bubble** (`shadow(color: black 0.3, radius: 12, y: 6)`): the sheet, answer bubble and meeting card, a touch higher because they float above the bar.
- **Small control** (`shadow(color: black 0.35, radius: 3, y: 1)`): the Downloads fan's "open in Finder" button.

### Named Rules
**The Shadow Outside Rule.** A glass surface's shadow is masked to everything but its own shape, via `glassShadow`. Never put `.shadow` straight on glass.

**The One Material Rule.** A panel is glass: `.hudWindow` behind-window blur, 0.18 rim, bubble shadow, via `glass(_:)` or `bubbleGlass()`. Never an opaque card, never a hand-tinted translucent rectangle. Name tags are not panels and stay solid capsules.

## Shapes

Continuous (squircle) corners throughout, and capsules for anything you press.

- **Bar:** 20px radius.
- **Panels:** 18px radius, with a speech-bubble tail (9px tall, centered 32px from the left edge) pointing down at the control the panel came from.
- **Capsules:** capture box, meeting pill, buttons, name tags, badges.
- **Rows:** 9px radius highlight under the selected note row.
- **Tiles:** the Downloads close tile uses 10px.
- **Dots:** 4px circles for running apps and the working beat.

**The Tail Points Home Rule.** Every panel (sheet, answer bubble, setup bubble, meeting card, paused card) has a tail pointing down at the control it rose from: the box, or its pill. A new panel gets the same tail, aimed at its own source.

## Components

Native and restrained. Controls read as Apple's own HUD controls; nothing is branded.

### Buttons
- **Shape:** capsule, 26px tall, 14px horizontal padding. Key hint inline after the label with 6px gap.
- **Primary:** Primary Fill, On Primary 13px semibold label, no stroke. One per panel.
- **Secondary:** Glass Fill with an Edge stroke, white 13px regular label.
- **Hover / Pressed:** brightness +0.08 under the pointer (primary darkens by 0.1 instead); opacity 0.7 while pressed. No scale, no glow.
- **Accessibility:** VoiceOver hears the title; the key hint is for sighted keyboard use.

### Capture Box (signature)
- **Style:** 38px capsule, Glass Fill, Edge stroke. Pencil glyph, "Capture or ask" placeholder, "⌥Space" hint at the right.
- **Typing:** Active Fill and Focused Edge.
- **Working:** Active Fill; Claude's current step replaces the placeholder and rolls up into place (in from the bottom, out through the top); sparkles glyph hops once per new step; three 4px dots and a timer at the right, "1 more" when others run. Under Reduce Motion the dots hide and the timer stays. While the box has focus and is empty, the placeholder is the oldest ask's text in quotes (middle-truncated), so you can see which ask Stop would stop.
- **Stop:** while Claude works, a 26px secondary capsule "Stop" sits beside the timer. With the box focused it carries "⌘." (⌘. reaches it only through the box); under the pointer alone it shows without the key. VoiceOver hears "Stop asking <text>". Text is clipped to 60 characters in the label, flash and tooltip. It stops the oldest ask; the box then flashes "Stopped “<text>”" (middle-truncated) with the `stop.circle` glyph in Secondary Ink (neither saved nor failed) and the Undo capsule, ⌘Z, which puts the ask's text back in the box. VoiceOver hears it with the Undo hint, and starting an ask announces "Asking Jarvis. Press Command Period to stop."
- **Confirmation:** the outcome glyph (green checkmark for saved) and text ("Added to Inbox") for 4 seconds, or 8 when it offers Undo. "Added to Inbox" and "Saved <meeting>" do: a 26px secondary capsule button, "Undo", at the right. Its ⌘Z hint shows only while the box or the meeting card has the keys, since those are the only places ⌘Z reaches it, and the countdown waits while they do. "Undone" reads "Put back today's note" (or "Put back 3 notes").
- **Queued:** a write waiting behind a running ask reads "Waiting for Claude to finish", with the same dots and timer.
- **Hover:** only the pencil tilts (-18°), as if about to write. Fill does not change, so fill always means "has the keys or is working".
- **First run:** sparkles glyph, "Choose a vault", and "↑↓ ⏎" at the right while the setup bubble is open.
- **After a skip:** "Skipped <meeting>" with the same Undo capsule for the 8-second grace. When the name doesn't fit the box it reads just "Skipped".
- **Failed search:** the sheet puts the error on a line of its own, triangle glyph and 11px secondary text, above its rows.

### Panels: Sheet, Answer Bubble, Meeting Card
- **Corner Style:** 18px with tail.
- **Background:** glass (see Elevation).
- **Internal Padding:** 16px horizontal, 13px top. The sheet is tighter (6px) because its rows pad themselves.
- **Answer bubble:** 11px secondary header (status glyph, what you typed, "1 of 2"), 15px semibold headline, optional detail, then note chips and buttons sharing one row when they fit. A list in the answer puts its bullets and numbers in the glyph column, so item text starts where a note row's does. A failure whose detail names Settings gets a Settings… button beside Try again, as the paused card does.
- **Meeting card:** waveform glyph and 15px title, date and "1 of 2" at the right; checkbox lines with their destination ("Today's note", "Work Log") in 11px at the right, a left-out line's text dims, its label doesn't. The checkbox sits in the shared glyph column (16px wide, under the header's waveform) with a 24px hit area, and "Add a line" uses the same column. The checkbox is laid out one 13px text line tall (16px), so a line is as tall as its text and the step from one line's baseline to the next is the same wrapped or not, focused or not. The title is a button that opens the call in Obsidian (⌘O hint inline). A call with nothing proposed says "Nothing came out of this call. Add a todo, or skip." as a secondary reason line under the title, past the glyph column, with the empty line below as an ordinary one; one that couldn't be drafted (`draftFailed`) gives "Couldn't draft this call. Read it (⌘O) and add todos here, draft it again (⌘R), or skip." there, in the same 13px secondary detail style as a failure. A blank line is not yet a line: it shows unticked and gets no Leave out or Include. The footer is one row: Skip ⇧⌘⌫ at the far left (secondary; not ⌘⌫, which deletes to the start of the line the caret is in), then one secondary button for the focused line with text, "Leave out ⌥⏎" or "Include ⌥⏎", then, on a draft-failed card, a secondary Draft again ⌘R, and Save ⌘⏎ (primary) at the right. When nothing would be saved Save stays in place at 0.4 opacity and disabled; ⌘⏎ then beeps and a 13px secondary line above the footer says "Nothing to save. Skip with ⇧⌘⌫ if you're done." until the lines change. Lines never carry a button of their own, so a line never grows taller.
- **Setup bubble:** rises from the box on first run. Sparkles header "Welcome to Jarvis" with "1 of 2", 15px "Which vault should I use?", then Obsidian's vaults as note rows (folder glyph, name, parent folder and ⏎ at the right) and "Choose another folder…" below a separator. A step's detail line under its question (why a choice didn't take) is 13px secondary, like a failure's detail. Then, "2 of 2": "Do you record calls?" with the vault's folders that hold recordings (waveform glyph, name, "N recordings"), Choose another folder…, and Not now (esc) below a separator. Once done: green check and the vault's name, "All set: try it now", one line of example, an 11px secondary line pointing at Settings ("Settings and every key: right-click the Dock or press ⌘,"), Done ⏎. The example line says ⌘⏎ adds it to your Inbox as is. Without Claude Code the headline becomes "All set: your Inbox works now", the line below points at ⌘⏎ ("Asking (⏎) needs Claude Code, which isn't on this Mac yet.") and a secondary "Install Claude Code" sits at the left.
- **Paused card:** rises from the red pill and is laid out like a failure bubble. An 11px secondary header row (failed triangle, "Meeting watcher"), the CLI's line on why as the 15px semibold headline (selectable), a 13px secondary detail on what to do (up to three lines, selectable), then Settings…, Open log and Try again (primary) at the right. Opening it, by click or by ⏎, gives the box the keys, so Try again always shows ⏎ while the card is open, and ⏎ and esc reach it through the box. The box hides its ⌥Space hint meanwhile, and does the same while the meeting card has the keys. Typing in the box closes the card, so the sheet takes its place.

### Note Rows
- **Style:** SF Symbol in Secondary Ink (16px column), title in Body, folder and key hint right-aligned in Label.
- **App row:** when the typed word starts an app's name, "Open <app>" sits on top of the sheet with the app's own 16px icon in place of the symbol. ⏎ stays on Ask until the whole name is typed, so the app row carries "↑" as its key hint meanwhile.
- **Selected:** Row Highlight capsule (9px radius) slides between rows.

### Paused Pill
- **Style:** Paused Red capsule on the bar, before the meeting pill, warning triangle and "Meetings paused" in white 13px medium. Shows "⏎" after the label when ⏎ in the empty box would open its card (it comes before a waiting meeting prompt); the hint keeps its room and fades. Becomes a chevron while its card is open. Leaves by itself once the watcher has stayed up 10 seconds. It also shows at login when a chosen vault's folder is missing (first run stays closed), saying so with Try again.

### Meeting Pill
- **Style:** Waiting Amber capsule on the bar, waveform glyph (`waveform.badge.exclamationmark` for a call Claude couldn't draft; VoiceOver adds "couldn't draft"), title capped at 140px, "+1" for more waiting, and "⏎" while the box is focused and empty and ⏎ would open the card. Both keep their room and fade. Becomes a chevron while its card is open, and closes it.

### App Tiles
- **Style:** the app's own icon at 46px, 4px running dot below, badge at the top-right in Badge Red.
- **Hover:** magnifies to 1.16 and lifts 5px; the name appears at once in a Name Tag above.
- **Launch:** one bounce (16px lift) when an app opens. Skipped with Reduce Motion.
- **Menus:** right-click gives the macOS Dock's own menu (Open, Keep in Dock, Show in Finder, Hide, Quit). Right-click on the bar itself gives Settings…, Hidden Apps, Undo Last Change (⌥⌘Z, shown on the item; it reports in the bubble's words: "Put back …" and "Nothing to undo" show as a short confirmation in the box, "Kept … as is" opens the info bubble with its detail; picking it again while one runs beeps, and while Claude works it says "Can't undo while Claude works") and Quit Jarvis (⌘Q while Jarvis has the keys), which stops running asks and lets queued writes finish first (10 seconds at most), the box reading "Finishing before quitting".

### Downloads Stack
- **Tile:** the newest file's icon. While the fan is open the tile becomes a close button: a 10px-radius tile in the solid-control colour (`color(srgb 0.15 0.15 0.15 / 0.92)`, near-white in Light) with a Rim stroke and a 17px semibold ink chevron.down.
- **Keyboard:** the fan has the keys while open. ↑↓ move a highlight (the Name Tag's highlighted state, as under the pointer) up and down the rows, starting on the first arrow, and ⏎ opens the highlighted row. The pointer takes the highlight back. Esc closes the fan.
- **Fan:** rows rise from the tile, bottom up, each a Name Tag (highlighted under the pointer, long names truncated in the middle, 270px max) beside the file's 46px Quick Look thumbnail with the small-control shadow. Rows are 54px apart, tilt clockwise 4° plus 1.4° per row, and drift right (index^1.5 × 3.2px) the higher they go, like the macOS Dock's fan.
- **Last row:** "Open in Finder" (or "N More in Finder") on a 40px disc in the same solid-control colour with a Rim stroke and an ink arrow.forward.circle.fill glyph.
- **Motion:** opens with the shared spring, 0.022s per row; closes faster (response 0.24, damping 0.95), top row first. Reduce Motion fades the rows in where they belong.

### Settings
- A standard titled macOS window ("Jarvis Settings", 420px wide) with a grouped SwiftUI `Form`. First group: Vault and Meetings as native pop-up menus (title, a short state under it: the vault's path truncated at the head, or "N recordings. Follow-ups are drafted from new ones."), offering what first run offered plus Choose another folder… and, for meetings, Off; a failed change shows in red under them, and a vault folder that's gone says "Can't find this folder. Move it back, or choose another." under Vault. If `jarvis setup` can't load, its error shows in that red line in place of both rows. Second group: three toggles, each with a title and a short explanation. Last, "Keys": every shortcut as one compact two-column list under four group titles (Capture box, Answers, Meeting prompt, Downloads; 11px medium, secondary), key in secondary and right-aligned, then what it does, callout size, so the window fits a 13-inch display. The empty-box row reads "⏎  Empty box: open the meeting or paused pill"; Meeting prompt also lists ⌘O "Open the call in Obsidian" and ⌘R "Draft again, when Claude couldn't". When another app owns ⌥Space, its row says so in Failed Red. No custom styling, no glass.

## Do's and Don'ts

### Do:
- **Do** build every new panel with `glass(_:)` or `bubbleGlass()`: `.hudWindow` blur, 0.18 rim, bubble shadow.
- **Do** use `nameTag()` for a floating label, as hover names and the Downloads fan do.
- **Do** make new panels 480px wide (`Panel.width`), 18px radius, with a tail pointing at their source.
- **Do** animate with the shared `spring` (response 0.42, damping 0.74), only on a state change. With Reduce Motion it becomes a 0.15s ease-out fade with no movement.
- **Do** stagger rows as a panel opens: 0.05s apart, capped at four, rising 8px.
- **Do** put the key that presses a control beside it with `keyHint()`.
- **Do** use SF Symbols, and reuse the same glyph for an outcome everywhere it shows (bubble header and box).
- **Do** keep widths fixed across states; fade content that comes and goes instead of reflowing the bar.

### Don't:
- **Don't** use a true black or opaque background for the Dock, or pin its appearance. It replaces the macOS Dock, so it matches the macOS material in Light and Dark mode.
- **Don't** add a color that doesn't mean saved, waiting, failed, paused or unread.
- **Don't** put more than one primary-fill button in a panel, or hard-code `.white`/`.black` on the glass: use the adaptive tokens.
- **Don't** set text below 11px, or use a font other than San Francisco.
- **Don't** add a looping animation. The working dots (three times a second, only while Claude works, hidden under Reduce Motion) are the one repeating motion.
- **Don't** change the capture box's fill on hover; fill means it has the keys or is working.
- **Don't** reinvent the macOS Dock's behaviors (magnification, bounce, badges, right-click menus). Match them.
- **Don't** show anything from a `private` folder on screen, in any component.
