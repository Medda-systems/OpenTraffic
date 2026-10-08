#!/usr/bin/env bash
# Builds a release OpenTraffic.app and packages it as dist/release/OpenTraffic-<version>.dmg.
#
# Signing: ad-hoc by default (free; on first launch macOS asks people to confirm in
# System Settings → Privacy & Security → Open Anyway). With a paid Apple Developer account, set
#   OPENTRAFFIC_SIGNING_IDENTITY="Developer ID Application: …"
#   OPENTRAFFIC_NOTARY_PROFILE=<keychain profile created with `xcrun notarytool store-credentials`>
# to sign with the hardened runtime, notarize, and staple, so it opens without any warning.
#
# Updates: the disk image is also signed for Sparkle, and dist/release/appcast.xml (the update feed,
# itself signed) points at it. The key is the "Private key for signing Sparkle updates" Keychain item
# (account medda-systems), or OPENTRAFFIC_UPDATE_KEY_FILE (an exported key, for CI).
# OPENTRAFFIC_DOWNLOAD_BASE overrides where the feed says the disk image is (for testing).
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

# hdiutil sometimes reports "Resource busy" on build machines; it succeeds on a retry.
for attempt in 1 2 3; do
  /usr/bin/hdiutil create -quiet -volname "OpenTraffic $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" && break
  [[ $attempt == 3 ]] && exit 1
  sleep 5
done

if [[ -n "${OPENTRAFFIC_NOTARY_PROFILE:-}" ]]; then
  /usr/bin/codesign --force --sign "$OPENTRAFFIC_SIGNING_IDENTITY" "$DMG"
  /usr/bin/xcrun notarytool submit "$DMG" --keychain-profile "$OPENTRAFFIC_NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$DMG"
fi

(cd "$OUT_DIR" && /usr/bin/shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Packaged $DMG"
cat "$DMG.sha256"

# Sparkle's command-line tools, matching the version the app is built with.
SPARKLE_VERSION="$(python3 -c 'import json,sys; pins=json.load(open(sys.argv[1]))["pins"]; print(next(p["state"]["version"] for p in pins if p["identity"]=="sparkle"))' "$ROOT_DIR/Package.resolved")"
SPARKLE_TOOLS="$ROOT_DIR/.build/sparkle-tools-$SPARKLE_VERSION"
if [[ ! -x "$SPARKLE_TOOLS/bin/sign_update" ]]; then
  mkdir -p "$SPARKLE_TOOLS"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" | tar -xJ -C "$SPARKLE_TOOLS" ./bin
fi
KEY_ARGS=(--account medda-systems)
[[ -n "${OPENTRAFFIC_UPDATE_KEY_FILE:-}" ]] && KEY_ARGS=(--ed-key-file "$OPENTRAFFIC_UPDATE_KEY_FILE")
SIGNATURE="$("$SPARKLE_TOOLS/bin/sign_update" "${KEY_ARGS[@]}" "$DMG")"

BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
MINIMUM_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
DOWNLOAD_BASE="${OPENTRAFFIC_DOWNLOAD_BASE:-https://github.com/Medda-systems/OpenTraffic-releases/releases/download/v$VERSION}"
python3 - "$ROOT_DIR/CHANGELOG.md" "$VERSION" "$BUILD" "$MINIMUM_SYSTEM" "$DOWNLOAD_BASE/$(basename "$DMG")" "$SIGNATURE" > "$OUT_DIR/appcast.xml" <<'PYTHON'
import html, re, sys
from email.utils import formatdate
changelog, version, build, minimum, url, signature = sys.argv[1:]
# This version's section of the changelog, as simple HTML for Sparkle's update window.
section = re.search(r"^## " + re.escape(version) + r"\n(.*?)(?=^## |\Z)", open(changelog).read(), re.S | re.M)
notes = []
for line in (section.group(1) if section else "").splitlines():
    text = html.escape(line.strip())
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", re.sub(r"`(.+?)`", r"<code>\1</code>", text))
    if line.lstrip().startswith("- "):
        notes.append(f"<li>{text[2:]}</li>")
    elif text:
        notes.append(f"<p>{text}</p>")
print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>OpenTraffic</title>
    <item>
      <title>OpenTraffic {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>{"".join(notes)}</ul>]]></description>
      <enclosure url="{html.escape(url)}" {signature} type="application/octet-stream"/>
    </item>
  </channel>
</rss>""")
PYTHON
"$SPARKLE_TOOLS/bin/sign_update" "${KEY_ARGS[@]}" "$OUT_DIR/appcast.xml"
echo "Wrote $OUT_DIR/appcast.xml (build $BUILD)"
