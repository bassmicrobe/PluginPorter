#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
DEST="${1:-$ROOT/dist}"
APP="$DEST/PluginPorter.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/bin/xcrun swiftc -swift-version 5 -O -target arm64-apple-macos12.0 \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/Inventory.swift" \
  "$ROOT/Sources/Engine.swift" "$ROOT/Sources/PresetModels.swift" "$ROOT/Sources/PresetEngine.swift" \
  "$ROOT/Sources/PresetWindow.swift" "$ROOT/Sources/App.swift" "$ROOT/Sources/main.swift" \
  -o "$APP/Contents/MacOS/PluginPorter"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>ja</string>
<key>CFBundleExecutable</key><string>PluginPorter</string>
<key>CFBundleIdentifier</key><string>local.pluginporter.app</string>
<key>CFBundleName</key><string>PluginPorter</string>
<key>CFBundleDisplayName</key><string>PluginPorter</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.music</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>PluginPorter — personal migration utility</string>
</dict></plist>
PLIST
# Finder/File Provider can attach FinderInfo to newly created .app folders.
# Remove only signing-incompatible metadata from this generated app.
/usr/bin/xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
/usr/bin/codesign --force --sign - "$APP"
print "Built: $APP"
