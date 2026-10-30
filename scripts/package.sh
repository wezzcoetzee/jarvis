#!/bin/zsh
# Builds dist/Jarvis.app and dist/Jarvis.dmg. Install by opening the DMG and dragging Jarvis
# onto the Applications shortcut, which points at ~/Applications so no admin rights are needed.
# First launch hides the macOS Dock, starts the meeting watcher and adds Jarvis to Login Items.
# If the vault is in a cloud-synced folder, macOS asks once to let Jarvis read it.
#
# The CLI is compiled into the app (Contents/MacOS/jarvis-cli), so the install doesn't need Bun
# or this repo. Ad-hoc signed, which is enough for a personal install on this Mac.
set -euo pipefail

ROOT="${0:A:h:h}"
DIST="$ROOT/dist"
APP="$DIST/Jarvis.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "▸ Compiling the CLI"
bun build "$ROOT/src/main.ts" --compile --outfile "$WORK/jarvis-cli" >/dev/null

echo "▸ Building the Dock"
swift build -c release --package-path "$ROOT/dock"

echo "▸ Assembling Jarvis.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/dock/.build/release/JarvisDock" "$APP/Contents/MacOS/Jarvis"
cp "$WORK/jarvis-cli" "$APP/Contents/MacOS/jarvis-cli"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Jarvis</string>
    <key>CFBundleIdentifier</key><string>com.wcoetzee.jarvis</string>
    <key>CFBundleExecutable</key><string>Jarvis</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSAppleEventsUsageDescription</key><string>Jarvis asks Finder to empty the Trash, and asks your browser which tab you're on when you capture.</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP/Contents/MacOS/jarvis-cli"
codesign --force --sign - "$APP"

echo "▸ Building Jarvis.dmg"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
mkdir -p "$HOME/Applications"
ln -s "$HOME/Applications" "$STAGE/Applications"
hdiutil create -volname Jarvis -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DIST/Jarvis.dmg" >/dev/null

echo "✓ $APP"
echo "✓ $DIST/Jarvis.dmg"
