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
FIXTURES="$ROOT/scripts/screenshots/fixtures"
OUT="$ROOT/screenshots"
ALL=(
  resting hover-box hover-icon typing search search-selected inbox
  working working-two saved found answer question queue failed undone
  meeting-pill meeting-prompt downloads settings answer-keys narrow reply undo-skipped
  open-answer meeting-skip waiting
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
  [[ $scene == meeting-* ]] && cp -R "$FIXTURES/state/pending" "$WORK/scene/state/"
  # One at a time, so each lands in Downloads after the last and the stack keeps this order.
  for file in "$FIXTURES"/downloads/*(On); do cp "$file" "$WORK/scene/downloads/"; done

  # Numbered by the scene's place in ALL, so a partial run replaces the same files.
  name="$(printf '%02d' ${ALL[(Ie)$scene]})-$scene.png"
  print "▸ $name"
  JARVIS_SCREENSHOT="$scene" JARVIS_SCREENSHOT_OUT="$OUT/$name" \
  JARVIS_CONFIG="$WORK/scene/config" JARVIS_VAULT="$WORK/scene/vault" JARVIS_STATE="$WORK/scene/state" \
  JARVIS_DOWNLOADS="$WORK/scene/downloads" \
  PATH="$ROOT/scripts/screenshots/bin:$HOME/.bun/bin:$PATH" \
    "$DOCK" || FAILED+=("$scene")
  pkill -f "$ROOT/scripts/screenshots/bin/claude" 2>/dev/null || true
done

if (( ${#FAILED} )); then
  print "✗ failed: ${FAILED[*]}"
  exit 1
fi
print "✓ $OUT"
