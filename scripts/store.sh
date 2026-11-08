#!/bin/zsh
# App Store images: one headline and one real screenshot per frame, at 2880×1800 (the Mac App
# Store's largest 16:10 size). Built from screenshots/, so run scripts/screenshots.sh first.
# Renders with headless Chrome, like scripts/icon.sh.
set -euo pipefail

ROOT="${0:A:h:h}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SHOTS="$ROOT/screenshots"
OUT="$ROOT/assets/store"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# name | screenshot | headline | line under it (<kbd> marks a key)
FRAMES=(
  "01-capture|05-search|Capture without switching apps|Press <kbd>⌥Space</kbd> anywhere and type. Notes that match show as you type."
  "02-saved|21-answer-keys|Saved in the right note|Claude files it with your vault's own skills. <kbd>⌘Z</kbd> undoes it."
  "03-found|11-found|Find anything you wrote down|Ask in plain words, then open a note with <kbd>⌘1</kbd>."
  "04-answer|12-answer|Answers right above your Dock|A headline, a few lines, and the note they came from."
  "05-meetings|18-meeting-prompt|Follow-ups from every meeting|Jarvis drafts the todos and decisions from each recording. You approve them."
  "06-dock|19-downloads|Still your Dock|Your apps, a Downloads stack and the Trash, the way the macOS Dock does them."
)

mkdir -p "$OUT"
for frame in "${FRAMES[@]}"; do
  IFS='|' read -r name shot headline line <<< "$frame"
  [[ -f "$SHOTS/$shot.png" ]] || { print "✗ no screenshots/$shot.png; run scripts/screenshots.sh"; exit 1; }
  cat > "$WORK/$name.html" <<EOF
<!doctype html><meta charset="utf-8">
<style>
  html, body { margin: 0; width: 1440px; height: 900px; background: #000; overflow: hidden; }
  body { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 60px;
         font-family: -apple-system, "SF Pro Display", "Helvetica Neue", sans-serif; color: #fff; }
  h1 { margin: 0; font-size: 68px; font-weight: 700; letter-spacing: -0.02em; text-align: center; }
  p { margin: 18px 0 0; font-size: 27px; color: rgba(255,255,255,.72); text-align: center; }
  kbd { font: inherit; color: #fff; padding: 1px 10px; border: 1.5px solid rgba(255,255,255,.3); border-radius: 8px; }
  /* Screenshots are 2× captures: shown at their point size, so nothing is scaled up. */
  img { max-width: 1260px; max-height: 560px; border-radius: 20px; border: 1px solid rgba(255,255,255,.14); }
</style>
<header><h1>$headline</h1><p>$line</p></header>
<img srcset="file://$SHOTS/$shot.png 2x" alt="">
EOF
  "$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --window-size=1440,900 --screenshot="$OUT/$name.png" "file://$WORK/$name.html" 2>/dev/null
  print "▸ assets/store/$name.png"
done
print "✓ $OUT"
