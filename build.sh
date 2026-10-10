#!/bin/bash
# Builds Snag and installs the one copy at ~/Applications/Snag.app. Pass --run to launch it afterwards.
# The build is staged in the hidden .build folder so Spotlight only ever lists the installed app.
set -euo pipefail
cd "$(dirname "$0")"

APP=".build/app/Snag.app"
INSTALLED="$HOME/Applications/Snag.app"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Snag "$APP/Contents/MacOS/Snag"

# Icon. Intermediates live in the hidden .build folder so Spotlight doesn't list them.
ICON_DIR=".build/icon"
if [ ! -f "$ICON_DIR/Snag.icns" ]; then
    rm -rf "$ICON_DIR" && mkdir -p "$ICON_DIR/Snag.iconset"
    swift Scripts/make_icon.swift "$ICON_DIR/icon-1024.png"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$ICON_DIR/icon-1024.png" --out "$ICON_DIR/Snag.iconset/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) "$ICON_DIR/icon-1024.png" --out "$ICON_DIR/Snag.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICON_DIR/Snag.iconset" -o "$ICON_DIR/Snag.icns"
fi
cp "$ICON_DIR/Snag.icns" "$APP/Contents/Resources/Snag.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Snag</string>
    <key>CFBundleDisplayName</key><string>Snag</string>
    <key>CFBundleIdentifier</key><string>com.alborz.snag</string>
    <key>CFBundleExecutable</key><string>Snag</string>
    <key>CFBundleIconFile</key><string>Snag</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Finder metadata picked up along the way makes codesign refuse the bundle.
xattr -cr "$APP"

# A stable identity keeps the Screen Recording permission across rebuilds; ad-hoc loses it each time.
SIGN_ID="${SNAG_SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}"
codesign --force --sign "${SIGN_ID:--}" "$APP" || codesign --force --sign - "$APP"
# Ask the running copy to quit so it saves open edits; only force it if it doesn't go.
if pgrep -x Snag >/dev/null; then
    osascript -e 'tell application id "com.alborz.snag" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Snag >/dev/null || break; sleep 0.3; done
    pkill -x Snag 2>/dev/null || true
fi
mkdir -p "$HOME/Applications"
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
echo "Installed $INSTALLED"

if [ "${1:-}" = "--run" ]; then
    open "$INSTALLED"
fi
