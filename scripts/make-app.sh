#!/bin/sh
# Builds "Vlog Editor.app" into ./build. Run on a Mac with Xcode 15 or later.
set -eu
cd "$(dirname "$0")/.."

swift build -c release --product VlogEditor
BIN="$(swift build -c release --show-bin-path)/VlogEditor"

APP="build/Vlog Editor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VlogEditor"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Vlog Editor</string>
    <key>CFBundleDisplayName</key><string>Vlog Editor</string>
    <key>CFBundleIdentifier</key><string>app.vlogeditor.mac</string>
    <key>CFBundleExecutable</key><string>VlogEditor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
