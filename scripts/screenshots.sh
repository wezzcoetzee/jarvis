#!/usr/bin/env bash
# Captures the README screenshots: runs the Dock in demo mode (JARVIS_DEMO) against a throwaway
# vault and state in /tmp, so your vault, the macOS Dock and the watcher are never touched.
# `-autoHide NO` is a launch argument, so it overrides your setting without saving over it.
# Needs Screen Recording permission for your terminal, and Chrome or Brave to frame them.
# Window captures go to screenshots/raw/, 2880x1800 Mac App Store images to screenshots/framed/.
set -euo pipefail
cd "$(dirname "$0")/.."

demo=$(mktemp -d /tmp/jarvis-demo.XXXXXX)
vault="$demo/Vault"
state="$demo/state"
mkdir -p "$vault/Daily" "$vault/Meetings" "$state/pending"
cat > "$vault/Launch plan.md" <<'EOF'
# Launch plan
Ship after the billing migration. Sam owns the release notes.
EOF
cat > "$vault/Daily/2026-10-29.md" <<'EOF'
## Todo
- [ ] Review the launch plan with Sam
EOF
cat > "$vault/Work Log.md" <<'EOF'
## Entries
- 2026-10-29 · #decision · Launch moves to 12 November · [[2026-10-29 1057 Slack Huddle]]
EOF
cat > "$state/pending/2026-10-30 1400 Zoom.json" <<'EOF'
{
  "noteName": "2026-10-30 1400 Zoom",
  "meetingDate": "2026-10-30",
  "proposal": {
    "title": "Pricing review",
    "followUps": [
      { "task": "Send Priya the revised tier table", "alreadyTracked": false },
      { "task": "Review the launch plan with Sam", "alreadyTracked": true }
    ],
    "decisions": ["Keep the free tier at 3 projects"]
  }
}
EOF

swift build --package-path dock >/dev/null
bin="$(swift build --package-path dock --show-bin-path)/JarvisDock"
mkdir -p screenshots/raw screenshots/framed
chrome=${CHROME:-}
for candidate in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"; do
  [[ -z $chrome && -x $candidate ]] && chrome=$candidate
done
[[ -n $chrome ]] || { echo "error: no Chrome or Brave; set CHROME" >&2; exit 1; }

# The Dock sits on the bottom edge, as it does on screen, under one line of copy.
frame() {
  local html="$demo/$1.html"
  cp "screenshots/raw/$1.png" "$demo/$1.png"
  cat > "$html" <<HTML
<!doctype html><meta charset="utf-8"><style>
* { margin: 0 }
body { width: 2880px; height: 1800px; background: #000; color: #fff; overflow: hidden;
  font-family: -apple-system, sans-serif; text-align: center; position: relative }
h1 { font-size: 132px; font-weight: 800; letter-spacing: -0.02em; padding-top: 170px }
h2 { font-size: 60px; font-weight: 500; opacity: 0.7; margin-top: 36px }
img { position: absolute; left: 50%; bottom: 0; transform: translateX(-50%); width: 2400px }
</style><h1>$2</h1><h2>$3</h2><img src="$1.png">
HTML
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --window-size=2880,1800 --screenshot="$PWD/screenshots/framed/$1.png" "file://$html" >/dev/null 2>&1
}

window_id() {
  swift -e 'import CoreGraphics
let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
let ids = list.filter { ($0[kCGWindowOwnerName as String] as? String) == "JarvisDock" }
  .max { (($0[kCGWindowBounds as String] as! [String: Double])["Height"] ?? 0) < (($1[kCGWindowBounds as String] as! [String: Double])["Height"] ?? 0) }
print(ids?[kCGWindowNumber as String] as? Int ?? "")'  </dev/null
}

while IFS='|' read -r screen headline subheadline; do
  JARVIS_DEMO=$screen JARVIS_VAULT="$vault" JARVIS_STATE="$state" "$bin" -autoHide NO -registeredForLogin YES </dev/null &
  pid=$!
  sleep "${SETTLE:-4}"
  screencapture -o -x -l "$(window_id)" "screenshots/raw/$screen.png"
  kill "$pid"
  wait "$pid" 2>/dev/null || true
  frame "$screen" "$headline" "$subheadline"
  echo "screenshots/framed/$screen.png"
done <<'SCREENS'
search|Find any note as you type|⌥Space from anywhere. Local search, no AI.
working|Hand it to Claude|It works inside your vault, with your vault's own skills.
answer|Answers rise out of the Dock|With links to the notes involved, and undo.
meeting|Meetings become todos|Follow-ups and decisions drafted for you to approve.
SCREENS
rm -rf "$demo"
