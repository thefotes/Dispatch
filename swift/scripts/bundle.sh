#!/usr/bin/env bash
# Assemble MicroManager.app.
#
# SwiftPM cannot emit an .app bundle, and an unbundled binary is a poor
# background app: no LSUIElement, no stable identity for TCC, and SMAppService
# refuses to register it as a login item.
#
#   ./scripts/bundle.sh              build into swift/build/
#   ./scripts/bundle.sh --install    also copy to /Applications and launch
#
# Signing matters more than it looks. macOS keys the Input Monitoring grant to
# the code signature, so an ad-hoc signature - whose hash changes on every
# build - forces you to re-grant permission after every rebuild. A real
# identity gives a stable designated requirement and the grant sticks.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="MicroManager"
BUNDLE_ID="cc.worklouder.micromanager"
VERSION="0.1.0"
PRODUCT="WLMicroManager"
OUT_DIR="build"
APP="$OUT_DIR/$APP_NAME.app"

install=false
[[ "${1:-}" == "--install" ]] && install=true

echo "==> building $PRODUCT (release)"
swift build -c release --product "$PRODUCT"
BINARY=".build/release/$PRODUCT"
[[ -f "$BINARY" ]] || { echo "build produced no binary at $BINARY" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>Micro Manager</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <!-- Menu-bar only: no Dock icon, no app-switcher entry. -->
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string>Interoperability tool for the Work Louder Creator Micro 2.</string>
</dict>
</plist>
PLIST

echo "==> signing"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 -E '"(Apple Development|Developer ID Application)[^"]*"' \
    | sed -E 's/.*"(.*)"/\1/' || true)"

if [[ -n "$IDENTITY" ]]; then
    echo "    identity: $IDENTITY"
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
else
    echo "    WARNING: no signing identity found, falling back to ad-hoc." >&2
    echo "    The Input Monitoring grant will not survive rebuilds." >&2
    codesign --force --sign - "$APP"
fi
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

if $install; then
    echo "==> installing to /Applications"
    # Replacing a running app leaves a zombie in the menu bar.
    pkill -f "/Applications/$APP_NAME.app" 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    echo "==> launching"
    open "/Applications/$APP_NAME.app"
    echo
    echo "If this is the first launch, macOS will ask for Input Monitoring."
    echo "Grant it, then toggle the manager off and on from the menu bar."
else
    echo
    echo "built: $APP"
    echo "run:   open $APP        (or ./scripts/bundle.sh --install)"
fi
