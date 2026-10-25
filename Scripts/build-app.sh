#!/bin/bash
# Assembles bbMusic.app from the SwiftPM build, the Node runtime, and the sidecar package.
#
# Self-use build: no notarisation, ad-hoc signature. The bundle layout matters more than the
# signature here — the sidecar is found at Contents/Resources/sidecar and Node at
# Contents/Resources/sidecar/node/bin/node.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-debug}"
APP_NAME="bbMusic"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP="$ROOT/dist/$APP_NAME.app"
# Version stamped into Info.plist. The release workflow passes these from the git tag; a local build
# keeps the development defaults so `./Scripts/build-app.sh` needs no arguments.
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

echo "==> Building Swift target ($CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG"

echo "==> Preparing bundle at $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/bbMusic" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>bbMusic</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>local.bbmusic.app</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <!-- QQ Music streams come from media CDNs over plain http (aqqmusic.tc.qq.com, dl.stream.qqmusic.qq.com).
         iOS/macOS App Transport Security blocks those unless media loads are exempted. The app talks
         to nothing else in the clear: the sidecar is loopback and Last.fm is https. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
        <key>NSAllowsArbitraryLoadsInMedia</key><true/>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
</dict>
</plist>
PLIST

echo "==> Embedding icon"
cp "$ROOT/Assets/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Embedding sidecar"
SIDECAR_SRC="$ROOT/sidecar"
SIDECAR_DST="$APP/Contents/Resources/sidecar"
mkdir -p "$SIDECAR_DST"
cp "$SIDECAR_SRC/wrapper.js" "$SIDECAR_SRC/package.json" "$SIDECAR_DST/"
# Ship the already-installed dependency tree; rebuilding it inside the bundle would need npm at
# runtime, which the target machine may not have.
cp -R "$SIDECAR_SRC/node_modules" "$SIDECAR_DST/node_modules"

echo "==> Embedding Node runtime"
NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
if [ -z "$NODE_BIN" ]; then
    # nvm installs are not on PATH for non-interactive shells.
    NODE_BIN="$(ls -d "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | sort -V | tail -1)"
fi
if [ -z "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
    echo "error: no node runtime found; set NODE_BIN=/path/to/node" >&2
    exit 1
fi
echo "    node: $NODE_BIN ($("$NODE_BIN" --version))"
mkdir -p "$SIDECAR_DST/node/bin"
cp "$NODE_BIN" "$SIDECAR_DST/node/bin/node"
chmod +x "$SIDECAR_DST/node/bin/node"

echo "==> Signing (ad-hoc)"
# Sign nested code first, then the app, so the bundle seal is valid.
codesign --force --sign - --timestamp=none "$SIDECAR_DST/node/bin/node" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP ($(du -sh "$APP" | cut -f1), version $VERSION ($BUILD_NUMBER))"
