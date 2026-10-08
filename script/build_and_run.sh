#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="OpenTraffic"
BUNDLE_ID="se.medda.opentraffic"
# Updates (Sparkle): the feed every release publishes, and the public half of the signing key
# (the private half is in the release maintainer's Keychain; see script/package_dmg.sh).
UPDATE_FEED_URL="https://github.com/Medda-systems/OpenTraffic-releases/releases/latest/download/appcast.xml"
UPDATE_PUBLIC_KEY="aTnLSOMC0+XmcukPKUV0UCZeBOJ29DKP+jREbOihW5A="
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# OPENTRAFFIC_CONFIGURATION=release for distributable builds (script/package_dmg.sh sets it);
# OPENTRAFFIC_DIST_DIR puts the bundle elsewhere than dist/.
CONFIGURATION="${OPENTRAFFIC_CONFIGURATION:-debug}"
# OPENTRAFFIC_ARCHS="arm64 x86_64" builds a universal app (Apple silicon and Intel).
ARCH_ARGS=()
for arch in ${OPENTRAFFIC_ARCHS:-}; do ARCH_ARGS+=(--arch "$arch"); done
DIST_DIR="${OPENTRAFFIC_DIST_DIR:-$ROOT_DIR/dist}"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
BUILD_NUMBER="${OPENTRAFFIC_BUILD_NUMBER:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)}"
COPYRIGHT_YEAR="$(date +%Y)"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

if [[ "$MODE" != "--build-only" && "$MODE" != "build-only" ]]; then
  pkill -TERM -x "$APP_NAME" >/dev/null 2>&1 || true
  for _ in {1..80}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  pkill -KILL -x "$APP_NAME" >/dev/null 2>&1 || true
fi

export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"
# Regenerate the app icon only when its artwork changed, so builds don't touch tracked files.
if [[ ! -f "$ROOT_DIR/Assets/OpenTraffic.icns" || "$ROOT_DIR/Assets/opentraffic-app-icon.png" -nt "$ROOT_DIR/Assets/OpenTraffic.icns" ]]; then
  "$ROOT_DIR/script/generate_icons.sh"
fi
swift build --package-path "$ROOT_DIR" --disable-sandbox -c "$CONFIGURATION" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BUILD_BIN="$(swift build --package-path "$ROOT_DIR" --disable-sandbox -c "$CONFIGURATION" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"
BUILD_BINARY="$BUILD_BIN/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
# The stdio MCP bridge (Integrations/README.md); inside the bundle so it's signed with the app.
cp "$BUILD_BIN/opentraffic-mcp" "$APP_MACOS/opentraffic-mcp"
chmod +x "$APP_MACOS/opentraffic-mcp"
# Sparkle, for updates. The app finds it in Contents/Frameworks, never in the build folder.
mkdir -p "$APP_CONTENTS/Frameworks"
ditto "$BUILD_BIN/Sparkle.framework" "$APP_CONTENTS/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY"
while read -r rpath; do
  install_name_tool -delete_rpath "$rpath" "$APP_BINARY"
done < <(otool -l "$APP_BINARY" | awk '/LC_RPATH/ { getline; getline; print $2 }' | grep "^$ROOT_DIR/" || true)
cp "$ROOT_DIR/Assets/OpenTraffic.icns" "$APP_RESOURCES/OpenTraffic.icns"
cp "$ROOT_DIR/Sources/OpenTraffic/Resources/opentraffic-menu.svg" "$APP_RESOURCES/opentraffic-menu.svg"
# The opentraffic command-line tool, which drives the app through opentraffic:// links.
cp "$ROOT_DIR/Sources/OpenTraffic/Resources/opentraffic" "$APP_RESOURCES/opentraffic"
cp "$ROOT_DIR/Sources/OpenTraffic/Resources/collab.js" "$APP_RESOURCES/collab.js"
cp "$ROOT_DIR/Sources/OpenTraffic/Resources/bridge.js" "$APP_RESOURCES/bridge.js"
chmod +x "$APP_RESOURCES/opentraffic"
# Provider marks from Simple Icons (CC0); trademarks belong to their owners.
for provider in cloudflare ngrok tailscale; do
  cp "$ROOT_DIR/Sources/OpenTraffic/Resources/provider-$provider.svg" "$APP_RESOURCES/provider-$provider.svg"
done
# OpenTraffic's license and those of the libraries it includes travel with the app.
mkdir -p "$APP_RESOURCES/Licenses"
cp "$ROOT_DIR/LICENSE" "$APP_RESOURCES/Licenses/OpenTraffic-LICENSE.txt"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_RESOURCES/Licenses/THIRD_PARTY_NOTICES.md"
cp "$ROOT_DIR"/Licenses/*.txt "$APP_RESOURCES/Licenses/"
if [[ -n "${OPENTRAFFIC_PROVISIONING_PROFILE_PATH:-}" ]]; then
  if [[ ! -f "$OPENTRAFFIC_PROVISIONING_PROFILE_PATH" ]]; then
    echo "OPENTRAFFIC_PROVISIONING_PROFILE_PATH does not name a file" >&2
    exit 1
  fi
  cp "$OPENTRAFFIC_PROVISIONING_PROFILE_PATH" "$APP_CONTENTS/embedded.provisionprofile"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>OpenTraffic</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>NSHumanReadableCopyright</key>
  <string>© $COPYRIGHT_YEAR Medda Systems. MIT License.</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>SUFeedURL</key>
  <string>$UPDATE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$UPDATE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SURequireSignedFeed</key>
  <true/>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>$BUNDLE_ID</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>opentraffic</string>
      </array>
    </dict>
  </array>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>OpenTraffic connects to web servers on your network when you share one through a tunnel.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# A stable signing identity keeps the app's code identity constant across rebuilds, so a Keychain
# "Always Allow" sticks. Without OPENTRAFFIC_SIGNING_IDENTITY, use an installed Apple Development
# certificate (free with any Apple ID). Set OPENTRAFFIC_SIGNING_IDENTITY=- to force ad-hoc signing.
if [[ -z "${OPENTRAFFIC_SIGNING_IDENTITY:-}" ]]; then
  OPENTRAFFIC_SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development: / { print $2; exit }')"
  if [[ -n "$OPENTRAFFIC_SIGNING_IDENTITY" ]]; then
    echo "Signing with Apple Development identity $OPENTRAFFIC_SIGNING_IDENTITY"
  fi
fi
if [[ "${OPENTRAFFIC_SIGNING_IDENTITY:-}" == "-" ]]; then
  OPENTRAFFIC_SIGNING_IDENTITY=""
fi

# The MCP helper is signed on its own (with its own identifier) before the app that contains it.
if [[ -n "${OPENTRAFFIC_SIGNING_IDENTITY:-}" ]]; then
  SIGNING_ARGS=(--force --options runtime --sign "$OPENTRAFFIC_SIGNING_IDENTITY")
  # Notarization requires a secure timestamp on Developer ID signatures.
  if [[ "$OPENTRAFFIC_SIGNING_IDENTITY" == "Developer ID"* ]]; then SIGNING_ARGS+=(--timestamp); fi
else
  SIGNING_ARGS=(--force --sign -)
fi
/usr/bin/codesign "${SIGNING_ARGS[@]}" --identifier "$BUNDLE_ID.mcp" "$APP_MACOS/opentraffic-mcp"
# Sparkle's helpers inside out, then the framework (the order Sparkle documents for Developer ID).
SPARKLE="$APP_CONTENTS/Frameworks/Sparkle.framework"
for helper in "$SPARKLE"/Versions/B/XPCServices/*.xpc "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app"; do
  if [[ "$helper" == *Downloader.xpc ]]; then
    /usr/bin/codesign "${SIGNING_ARGS[@]}" --preserve-metadata=entitlements "$helper"
  else
    /usr/bin/codesign "${SIGNING_ARGS[@]}" "$helper"
  fi
done
/usr/bin/codesign "${SIGNING_ARGS[@]}" "$SPARKLE"
APP_SIGNING_ARGS=("${SIGNING_ARGS[@]}" --identifier "$BUNDLE_ID")
if [[ -n "${OPENTRAFFIC_ENTITLEMENTS_PATH:-}" ]]; then
  APP_SIGNING_ARGS+=(--entitlements "$OPENTRAFFIC_ENTITLEMENTS_PATH")
fi
/usr/bin/codesign "${APP_SIGNING_ARGS[@]}" "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --build-only|build-only)
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--build-only]" >&2
    exit 2
    ;;
esac
