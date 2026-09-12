#!/bin/bash
# Build and install DSH Launcher.app.
#
# Step order matters: the bundle is code-signed LAST. Modifying a bundle after
# signing (swapping an icon, editing Info.plist) invalidates the signature, and
# macOS then refuses to treat it as an application — Finder draws it as a plain
# folder and the icon never appears.
#
# Usage:
#   ./build.sh              build and install to /Applications
#   ./build.sh --dev        build to ./build only (does not install)
#   ./build.sh --uninstall  remove the installed app

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DSH Launcher"
BUNDLE_ID="io.github.dsh-launcher"
VERSION="1.4.2"

if [ "${1:-}" = "--uninstall" ]; then
    pkill -f "$APP_NAME.app/Contents/MacOS/DSHLauncher" 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    echo "removed /Applications/$APP_NAME.app"
    echo "note: config at ~/.config/dsh-launcher/ was left in place"
    exit 0
fi

DEST="/Applications"
[ "${1:-}" = "--dev" ] && DEST="./build"
APP="$DEST/$APP_NAME.app"

command -v swiftc >/dev/null || {
    echo "error: swiftc not found. Install the Xcode Command Line Tools:" >&2
    echo "  xcode-select --install" >&2
    exit 1
}

echo "==> compiling"
mkdir -p build
swiftc -O Sources/DSHLauncher.swift -o build/DSHLauncher

echo "==> assembling $APP"
pkill -f "$APP_NAME.app/Contents/MacOS/DSHLauncher" 2>/dev/null || true
sleep 0.5
mkdir -p "$DEST"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/DSHLauncher "$APP/Contents/MacOS/DSHLauncher"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>DSHLauncher</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- The interface ships in English and Simplified Chinese. The app draws its
       own strings (see the L enum in DSHLauncher.swift) rather than using
       .lproj bundles, but declaring the languages still matters: it is what macOS
       reads for the Finder "Languages" list, and what makes system-supplied
       text in our alerts (the OK button, for one) follow the same language
       instead of defaulting to English. -->
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
  </array>
  <!-- Menu bar utility: no Dock icon and no Cmd-Tab entry. The status item is
       the app; closing the panel leaves it running in the menu bar. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo "==> signing (must come last)"
codesign --force --deep --sign - "$APP"
codesign -v "$APP" && echo "    signature valid"

if [ "$DEST" = "/Applications" ]; then
    echo "==> refreshing caches"
    touch "$APP"
    LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    [ -x "$LSREG" ] && "$LSREG" -f "$APP" 2>/dev/null || true
    rm -rf "$HOME/Library/Caches/com.apple.iconservices.store" 2>/dev/null || true
    killall Dock 2>/dev/null || true
fi

echo "==> done: $APP"
