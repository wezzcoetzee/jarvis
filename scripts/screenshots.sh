#!/bin/zsh
# Screenshots of the Dock in every state, from fixtures only: a made-up vault, meeting prompts,
# Downloads and pinned apps under scripts/screenshots/fixtures, and a stand-in `claude`
# (scripts/screenshots/bin/claude). Your config, vault, state, Downloads and running apps are
# never read, and the Dock draws over its own backdrop, so nothing else on screen gets in.
#
#   scripts/screenshots.sh              # every scene, into screenshots/
#   scripts/screenshots.sh saved found  # just these
#
# Each scene opens the Dock on the display under the pointer for a few seconds. Leave the mouse
# and keyboard alone until it finishes.
set -euo pipefail

ROOT="${0:A:h:h}"
# Each scene gets its own HOME (so paths in Settings read ~/…); bun and the PATH use the real one.
REAL_HOME="$HOME"
FIXTURES="$ROOT/scripts/screenshots/fixtures"
OUT="$ROOT/screenshots"
ALL=(
  resting hover-box hover-icon typing search search-selected inbox
  working working-two saved found answer question queue failed undone
  meeting-pill meeting-prompt downloads settings answer-keys narrow reply undo-skipped
  open-answer meeting-skip waiting first-run setup-ready paused paused-open skip-undo light
  setup-meetings setup-no-claude open-app light-meeting stop draft-failed
)
SCENES=("${@:-${ALL[@]}}")

swift build --package-path "$ROOT/dock" >/dev/null
DOCK="$(swift build --package-path "$ROOT/dock" --show-bin-path)/JarvisDock"
mkdir -p "$OUT"

WORK="$(mktemp -d)"
FAILED=()
cleanup() {
  pkill -f "$ROOT/scripts/screenshots/bin/claude" 2>/dev/null || true
  defaults delete jarvis-screenshots 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/jarvis-screenshots.plist"
  rm -rf "$WORK"
}
trap cleanup EXIT

for scene in $SCENES; do
  (( ${ALL[(Ie)$scene]} )) || { print "✗ no scene called $scene"; FAILED+=("$scene"); continue; }
  # A fresh copy per scene: asks edit the vault, undo writes run manifests.
  rm -rf "$WORK/scene" && mkdir "$WORK/scene"
  cp -R "$FIXTURES/vault" "$FIXTURES/config" "$WORK/scene/"
  mv "$WORK/scene/vault/Daily/TODAY.md" "$WORK/scene/vault/Daily/$(date +%F).md"
  mkdir -p "$WORK/scene/state" "$WORK/scene/downloads"
  # Meeting prompts only where they're the subject, so the pill doesn't sit in every shot.
  [[ $scene == meeting-* || $scene == skip-undo || $scene == light-meeting ]] && cp -R "$FIXTURES/state/pending" "$WORK/scene/state/"
  # A call Claude couldn't draft, queued on its own so the card shows its one empty line.
  [[ $scene == draft-failed ]] && cp -R "$FIXTURES/state/draft-failed" "$WORK/scene/state/pending"
  # First run: no vault yet, and a made-up Obsidian that knows two. Every scene gets its own
  # Obsidian folder, so the CLI never reads the real list of vaults.
  mkdir -p "$WORK/scene/obsidian"
  vault="$WORK/scene/vault"
  if [[ $scene == first-run || $scene == setup-* || $scene == settings ]]; then
    # Settings shows the vault in use. First run has none: an empty JARVIS_VAULT means unset,
    # so `jarvis setup` reports it unconfigured (a set but missing one is a vault gone missing).
    [[ $scene == settings ]] && vault="$WORK/scene/Documents/Personal" || vault=""
    mkdir -p "$WORK/scene/Documents" "$WORK/scene/OneDrive/Work/.obsidian"
    cp -R "$WORK/scene/vault" "$WORK/scene/Documents/Personal"
    print -r -- "{\"vaults\":{\"a\":{\"path\":\"$WORK/scene/Documents/Personal\",\"ts\":2},\"b\":{\"path\":\"$WORK/scene/OneDrive/Work\",\"ts\":1}}}" > "$WORK/scene/obsidian/obsidian.json"
  fi
  # One at a time, so each lands in Downloads after the last and the stack keeps this order.
  for file in "$FIXTURES"/downloads/*(On); do cp "$file" "$WORK/scene/downloads/"; done

  # Numbered by the scene's place in ALL, so a partial run replaces the same files.
  name="$(printf '%02d' ${ALL[(Ie)$scene]})-$scene.png"
  print "▸ $name"
  JARVIS_SCREENSHOT="$scene" JARVIS_SCREENSHOT_OUT="$OUT/$name" \
  JARVIS_CONFIG="$WORK/scene/config" JARVIS_VAULT="$vault" JARVIS_STATE="$WORK/scene/state" \
  JARVIS_DOWNLOADS="$WORK/scene/downloads" JARVIS_OBSIDIAN="$WORK/scene/obsidian" \
  HOME="$WORK/scene" JARVIS_BUN="$REAL_HOME/.bun/bin/bun" \
  PATH="$ROOT/scripts/screenshots/bin:$REAL_HOME/.bun/bin:$PATH" \
    "$DOCK" || FAILED+=("$scene")
  pkill -f "$ROOT/scripts/screenshots/bin/claude" 2>/dev/null || true
done

if (( ${#FAILED} )); then
  print "✗ failed: ${FAILED[*]}"
  exit 1
fi
print "✓ $OUT"
