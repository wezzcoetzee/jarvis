# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

Recorded as `ios` so design work loads Apple-native guidance. The product is a native **macOS** app (SwiftUI, macOS 14+), not iOS. Read the guidance through a Mac lens: pointer, hover, keyboard, menu bar, multiple displays, non-activating panels.

## Users

Built for the owner's own workflow first; public releases exist and other people may use it later. When the two conflict, the owner's daily use decides, but nothing should assume a particular vault (see Constraints).

The user is a Mac user who keeps an Obsidian vault and has Claude Code installed and signed in. They are mid-task in another app (a call, a code editor, a browser) when a thought, todo, decision or question comes up. The job: get it into the vault, or get something back out of it, in a few keystrokes without leaving what they're doing.

## Product Purpose

Jarvis replaces the macOS Dock with one that has a capture box built in. ⌥Space opens the box from anywhere; the text goes to Claude Code running inside the vault, which uses the vault's own skills to save, find or answer. Jarvis also watches for new meeting recordings and drafts follow-ups and decisions for the user to approve.

Success is not losing things: the "I need to speak to Sam about that" from a call, the decision made in passing, the work shipped that will be wanted as evidence later.

## Positioning

The capture surface is the Dock itself, always present, so capturing costs no app switch and no window. Claude runs inside the user's vault with the vault's own skills, so Jarvis learns how *this* vault works instead of imposing a structure. Every AI edit is fenced by a fail-closed hook and can be undone.

## Operating Context

- Used all day, alongside other apps, on one or more displays. The Dock lives on one display at a time and follows the pointer.
- Often visible during screen shares and calls.
- Keyboard-first: ⌥Space, ⏎, ⌘⏎, ↑↓, ⎋, ⌘Z, ⌘1 to ⌘3, ⌘E. Every action has a key, and buttons show their keys while the box has focus.
- Meeting recordings arrive from a call recorder into a meetings folder; the user reviews drafts later from an orange pill in the Dock.
- Vaults are often cloud-synced (OneDrive, iCloud Drive, Dropbox), so file access can stall on macOS permission prompts.

## Capabilities and Constraints

Dock, capture, find, answers and meeting prompts are one product. None ranks above the others when they compete for space or attention.

- **Dock:** pinned and running apps, Downloads stack, Trash, badges, hover magnification and names, launch bounce, auto-hide, replacing the macOS Dock while running.
- **Capture box:** live local search as you type (no AI), ⏎ asks Claude, ⌘⏎ goes to the Inbox as is.
- **Progress:** live step lines while Claude works, with a timer.
- **Answer bubble:** headline, a few lines, links to notes; Undo; Done, Next, Reply, Try again, Open full answer; queued answers ("1 of 2"); put-away questions and failures.
- **Meeting prompts:** drafted todos and decisions, editable, include or leave out per line, save, or skip (undoable for 8 seconds). A red "Meetings paused" pill says why when the watcher keeps failing.
- **First run:** with no vault, the box asks which one (the vaults Obsidian knows), then "Do you record calls?" (vault folders that already hold recordings, or Not now), writes both to config.json (`jarvis setup`), and invites a first capture, pointing at ⌘⏎ when Claude Code isn't installed.
- **Open apps by name:** typing an app's name in the box puts "Open <app>" on top of the sheet; ⏎ opens it only once the whole name is typed or the row is picked, so ⏎ keeps meaning "ask".
- **Settings:** vault and meetings folder (or meetings off) can be changed any time, with the same choices first run offered.
- **Appearance:** follows Light and Dark mode, as the macOS Dock does.

Hard constraints (from README "Safety" and CLAUDE.md):

- Vault logic stays in the CLI (`src/`, Bun/TypeScript). The Dock (`dock/`, SwiftUI) only renders and shells out.
- Nothing about a particular vault goes in the code; paths, names and private folders come from `~/.config/jarvis/config.json`.
- Vault writes are append-only and follow each note's existing format. Every AI run can be undone.
- Private folders never appear on screen, since the Dock is visible during screen shares.
- Animations play once on change. Nothing redraws at the display's refresh rate; the only repeating motion is the working dots, three times a second, only while Claude works.
- Jarvis never asks for Accessibility, Input Monitoring or Screen Recording permissions.

Terminology: capture box, sheet (the matching notes above the box), bubble (the answer), meeting pill, meeting prompt, put away, Inbox, daily note, Work Log. Daily notes and meetings are named by day ("Today", "Yesterday", "Sun, 8 Nov").

## Brand Commitments

- Name: Jarvis. App icon: `assets/AppIcon.svg` (built to `assets/AppIcon.icns`).
- It should feel like the macOS Dock it replaces: same placement, magnification, bounce, badges and right-click menus.
- Voice: plain, short, concrete. Names the key and the outcome ("Added to Inbox", "Saved <meeting>", "Nothing to undo"). Failures get a plain headline and what to do next, never a generic error. No em dashes.

## Evidence on Hand

- `screenshots/`: every UI state (27 scenes), captured from the real app against fixtures by `scripts/screenshots.sh`.
- `assets/store/`: six 2880×1800 store images built from those screenshots by `scripts/store.sh`.
- `scripts/screenshots/fixtures`: a made-up vault, config, prompts and Downloads. Never put real vault content here.
- Releases: DMG and zip on GitHub Releases. The app is **not notarized**.
- No testimonials, user counts, reviews, press or App Store listing exist. Do not fabricate any.

## Product Principles

1. **Never leave what you're doing.** Capture and answers happen in the Dock; Obsidian is only pulled forward when the user asks.
2. **The vault is the user's.** Jarvis follows the vault's skills and formats, appends only, and can undo anything it did.
3. **Fail closed, fail legibly.** Anything that can't be checked is blocked, and a failure keeps what the user typed and says what to do.
4. **Native first.** Match what the macOS Dock and Mac conventions already taught the user before inventing anything.
5. **Calm on screen.** Motion plays once, nothing private shows, and the Dock stays out of the way until wanted.

## Accessibility & Inclusion

- Reduce Motion: every animation becomes a short fade with no movement; the auto-hidden Dock fades in place; the launch bounce is skipped.
- Fully keyboard-operable, with visible key hints on buttons.
- No continuously repainting animation.
