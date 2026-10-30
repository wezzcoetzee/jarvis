#!/bin/zsh
# Rebuilds assets/AppIcon.icns from assets/AppIcon.svg. Only needed after editing the SVG;
# the .icns is checked in so packaging doesn't depend on a browser. Renders with headless
# Chrome, because nothing built into macOS draws SVG filters.
set -euo pipefail

ROOT="${0:A:h:h}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$CHROME" --headless --disable-gpu --hide-scrollbars --default-background-color=00000000 \
  --window-size=1024,1024 --screenshot="$WORK/1024.png" "file://$ROOT/assets/AppIcon.svg" 2>/dev/null

SET="$WORK/AppIcon.iconset"
mkdir "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$WORK/1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ROOT/assets/AppIcon.icns"
echo "✓ $ROOT/assets/AppIcon.icns"
