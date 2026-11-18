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
  hint-capsule:
    backgroundColor: "{colors.glass-fill}"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.capsule}"
    width: "88px"
    height: "20px"
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
- **Secondary Ink** (`ink-secondary`): headers, folders, key hints, timers, placeholder. About 4.5:1 or better on the glass at 11px.
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

**The Dimmed, Not Removed Rule.** A left-out meeting line drops to 0.45 ink rather than disappearing or striking through, so it can be brought back.

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
- **Inside panels:** 16px horizontal inset; rows pad 10px by 6px; sheet rows 2px apart; meeting lines 32px minimum height with 8px gaps, scrolling past seven lines.
- **Controls share a height.** Buttons and note chips are 26px tall so a row of both lines up. Capsules on the bar are 38px.
- **Glyphs get a fixed 16px column** so the text after them starts in the same place in every state.
- **Widths that change fade instead of reflowing.** The "+1" on the meeting pill stays in the layout and fades, so every icon after it keeps its place.

## Elevation & Depth

Depth comes from the material, not from stacking. The bar and every panel are the same behind-window blur, separated from the desktop by a 0.18 white rim and one soft shadow. There is no tonal layering of surfaces on top of the glass; fills on the glass are translucent white, not darker or lighter panels. Name tags (hover names, Downloads fan) are the exception: small near-opaque capsules (dark in Dark mode, near-white in Light) with no blur and no shadow, as in the macOS Dock. The `.hudWindow` material itself turns light in Light mode; nothing tints it by hand.

### Shadow Vocabulary
- **Bar** (`shadow(color: black 0.3, radius: 10, y: 5)`): the Dock bar and rounded glass surfaces.
- **Bubble** (`shadow(color: black 0.3, radius: 12, y: 6)`): the sheet, answer bubble and meeting card, a touch higher because they float above the bar.
- **Small control** (`shadow(color: black 0.35, radius: 3, y: 1)`): the Downloads fan's "open in Finder" button.

### Named Rules
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
- **Working:** Active Fill; Claude's current step replaces the placeholder and rolls up into place (in from the bottom, out through the top); sparkles glyph hops once per new step; three 4px dots and a timer at the right, "1 more" when others run.
- **Confirmation:** the outcome glyph (green checkmark for saved) and text ("Added to Inbox") for 4 seconds.
- **Hover:** only the pencil tilts (-18°), as if about to write. Fill does not change, so fill always means "has the keys or is working".
- **First run:** sparkles glyph, "Choose a vault", and "↑↓ ⏎" at the right while the setup bubble is open.
- **After a skip:** "Skipped <meeting>" with a clickable "Undo ⌘Z" at the right for the 8-second grace.

### Panels: Sheet, Answer Bubble, Meeting Card
- **Corner Style:** 18px with tail.
- **Background:** glass (see Elevation).
- **Internal Padding:** 16px horizontal, 13px top. The sheet is tighter (6px) because its rows pad themselves.
- **Answer bubble:** 11px secondary header (status glyph, what you typed, "1 of 2"), 15px semibold headline, optional detail, then note chips and buttons sharing one row when they fit.
- **Meeting card:** waveform glyph and 15px title, date and "1 of 2" at the right; checkbox lines with their destination ("Today's note", "Work Log") in 11px at the right, and on the focused line a Hint Capsule ("Leave out ⌥⏎" or "Include ⌥⏎", 88×20, overlaid so it never makes the line taller); Skip at the bottom left, Save ⌘⏎ at the bottom right.
- **Setup bubble:** rises from the box on first run. Sparkles header "Welcome to Jarvis", 15px "Which vault should I use?", then Obsidian's vaults as note rows (folder glyph, name, parent folder and ⏎ at the right) and "Choose another folder…" below a separator. Then, "2 of 2": "Do you record calls?" with the vault's folders that hold recordings (waveform glyph, name, "N recordings"), Choose another folder…, and Not now (⎋) below a separator. Once done: green check and the vault's name, "Ready. Try it now", one line of example, an 11px secondary line pointing at Settings ("Right-click the Dock any time for Settings and every key."), Done ⏎. Without Claude Code the headline becomes "Ready. Try ⌘⏎ for now" and a secondary "Install Claude Code" sits at the left.
- **Paused card:** rises from the red pill. 15px "Meetings paused", the CLI's line on why (selectable), Open log and Try again ⏎. ⏎ and ⎋ reach it through the box.

### Note Rows
- **Style:** SF Symbol in Secondary Ink (16px column), title in Body, folder and key hint right-aligned in Label.
- **App row:** when the typed word starts an app's name, "Open <app>" sits on top of the sheet with the app's own 16px icon in place of the symbol. ⏎ stays on Ask until the whole name is typed, so the app row carries "↑" as its key hint meanwhile.
- **Selected:** Row Highlight capsule (9px radius) slides between rows.

### Paused Pill
- **Style:** Paused Red capsule on the bar, before the meeting pill, warning triangle and "Meetings paused" in white 13px medium. Becomes a chevron while its card is open. Leaves by itself once the watcher has stayed up 10 seconds.

### Meeting Pill
- **Style:** Waiting Amber capsule on the bar, waveform glyph, title capped at 140px, "+1" for more waiting. Becomes a chevron while its card is open, and closes it.

### App Tiles
- **Style:** the app's own icon at 46px, 4px running dot below, badge at the top-right in Badge Red.
- **Hover:** magnifies to 1.16 and lifts 5px; the name appears at once in a Name Tag above.
- **Launch:** one bounce (16px lift) when an app opens. Skipped with Reduce Motion.
- **Menus:** right-click gives the macOS Dock's own menu (Open, Keep in Dock, Show in Finder, Hide, Quit). Right-click on the bar itself gives Settings…, Hidden Apps and Quit Jarvis.

### Downloads Stack
- **Tile:** the newest file's icon. While the fan is open the tile becomes a close button: a 10px-radius tile in the solid-control colour (`color(srgb 0.15 0.15 0.15 / 0.92)`, near-white in Light) with a Rim stroke and a 17px semibold ink chevron.down.
- **Fan:** rows rise from the tile, bottom up, each a Name Tag (highlighted under the pointer, long names truncated in the middle, 270px max) beside the file's 46px Quick Look thumbnail with the small-control shadow. Rows are 54px apart, tilt clockwise 4° plus 1.4° per row, and drift right (index^1.5 × 3.2px) the higher they go, like the macOS Dock's fan.
- **Last row:** "Open in Finder" (or "N More in Finder") on a 40px disc in the same solid-control colour with a Rim stroke and an ink arrow.forward.circle.fill glyph.
- **Motion:** opens with the shared spring, 0.022s per row; closes faster (response 0.24, damping 0.95), top row first. Reduce Motion fades the rows in where they belong.

### Settings
- A standard titled macOS window ("Jarvis Settings", 420px wide) with a grouped SwiftUI `Form`. First group: Vault and Meetings as native pop-up menus (title, one-line state under it: the vault's path truncated at the head, or "N recordings. Follow-ups are drafted from new ones."), offering what first run offered plus Choose another folder… and, for meetings, Off; a failed change shows in red under them. Second group: three toggles, each with a title and a one-line explanation. Last, "Keys": every shortcut as one compact two-column list (key in secondary, right-aligned; what it does), callout size, so the window fits a 13-inch display. No custom styling, no glass.

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
- **Don't** add a looping animation. The working dots (three times a second, only while Claude works) are the one repeating motion.
- **Don't** change the capture box's fill on hover; fill means it has the keys or is working.
- **Don't** reinvent the macOS Dock's behaviors (magnification, bounce, badges, right-click menus). Match them.
- **Don't** show anything from a `private` folder on screen, in any component.
