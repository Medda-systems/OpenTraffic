#!/usr/bin/env bash
# Builds a release OpenTraffic.app and packages it as dist/release/OpenTraffic-<version>.dmg.
#
# Signing: ad-hoc by default (free; on first launch macOS asks people to confirm in
# System Settings → Privacy & Security → Open Anyway). With a paid Apple Developer account, set
#   OPENTRAFFIC_SIGNING_IDENTITY="Developer ID Application: …"
#   OPENTRAFFIC_NOTARY_PROFILE=<keychain profile created with `xcrun notarytool store-credentials`>
# to sign with the hardened runtime, notarize, and staple, so it opens without any warning.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
OUT_DIR="$ROOT_DIR/dist/release"
APP="$OUT_DIR/OpenTraffic.app"
DMG="$OUT_DIR/OpenTraffic-$VERSION.dmg"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# Never pick up a personal Apple Development certificate for a build meant for other people.
export OPENTRAFFIC_SIGNING_IDENTITY="${OPENTRAFFIC_SIGNING_IDENTITY:--}"
export OPENTRAFFIC_CONFIGURATION=release
export OPENTRAFFIC_ARCHS="${OPENTRAFFIC_ARCHS:-arm64 x86_64}"
export OPENTRAFFIC_DIST_DIR="$OUT_DIR"
"$ROOT_DIR/script/build_and_run.sh" --build-only

/usr/bin/codesign --verify --deep --strict "$APP"
echo "Built $APP ($(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist") build $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist"))"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT_DIR/LICENSE" "$STAGING/License.txt"
cat > "$STAGING/How to install.txt" <<TEXT
OpenTraffic $VERSION

1. Drag OpenTraffic into Applications.
2. Open OpenTraffic from Applications.

OpenTraffic is open source and isn't signed with a paid Apple Developer ID, so the first time
macOS says it can't verify the developer:
  - Open System Settings → Privacy & Security.
  - Scroll to "OpenTraffic was blocked…" and click Open Anyway, then confirm.
You only need to do this once.

OpenTraffic lives in the menu bar. It uses cloudflared (brew install cloudflared), and optionally
ngrok or Tailscale, which you install separately.
TEXT

/usr/bin/hdiutil create -quiet -volname "OpenTraffic $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"

if [[ -n "${OPENTRAFFIC_NOTARY_PROFILE:-}" ]]; then
  /usr/bin/codesign --force --sign "$OPENTRAFFIC_SIGNING_IDENTITY" "$DMG"
  /usr/bin/xcrun notarytool submit "$DMG" --keychain-profile "$OPENTRAFFIC_NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$DMG"
fi

(cd "$OUT_DIR" && /usr/bin/shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Packaged $DMG"
cat "$DMG.sha256"
