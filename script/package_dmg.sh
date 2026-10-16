#!/usr/bin/env bash
# Builds a release OpenTraffic.app and packages it as dist/release/OpenTraffic-<version>.dmg.
#
# Signing: ad-hoc by default (on first launch macOS asks people to confirm in System Settings →
# Privacy & Security → Open Anyway). For releases, sign with Medda Systems' Developer ID and notarize,
# so it opens without any warning:
#   OPENTRAFFIC_SIGNING_IDENTITY="Developer ID Application: Medda Systems AB (TEAMID)"
# and Apple notary credentials, either
#   OPENTRAFFIC_NOTARY_PROFILE=<keychain profile from `xcrun notarytool store-credentials`>
# or an App Store Connect API key (CI):
#   OPENTRAFFIC_NOTARY_KEY_FILE=<AuthKey_….p8>  OPENTRAFFIC_NOTARY_KEY_ID=…  OPENTRAFFIC_NOTARY_ISSUER=…
# The app is notarized and stapled, then the disk image around it is signed, notarized, and stapled.
# OPENTRAFFIC_REQUIRE_NOTARIZATION=1 fails instead of packaging anything that isn't (releases).
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

# A disk image for other people always uses the real update feed and key.
if [[ -n "${OPENTRAFFIC_UPDATE_FEED_URL:-}${OPENTRAFFIC_UPDATE_PUBLIC_KEY:-}" ]]; then
  echo "Unset OPENTRAFFIC_UPDATE_FEED_URL and OPENTRAFFIC_UPDATE_PUBLIC_KEY (they're for local update tests)." >&2
  exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# Never pick up a personal Apple Development certificate for a build meant for other people.
export OPENTRAFFIC_SIGNING_IDENTITY="${OPENTRAFFIC_SIGNING_IDENTITY:--}"

NOTARY_ARGS=()
if [[ -n "${OPENTRAFFIC_NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$OPENTRAFFIC_NOTARY_PROFILE")
elif [[ -n "${OPENTRAFFIC_NOTARY_KEY_FILE:-}" ]]; then
  NOTARY_ARGS=(--key "$OPENTRAFFIC_NOTARY_KEY_FILE" --key-id "${OPENTRAFFIC_NOTARY_KEY_ID:?}" --issuer "${OPENTRAFFIC_NOTARY_ISSUER:?}")
fi
NOTARIZE=0
if [[ "$OPENTRAFFIC_SIGNING_IDENTITY" == "Developer ID Application"* && ${#NOTARY_ARGS[@]} -gt 0 ]]; then
  NOTARIZE=1
elif [[ "${OPENTRAFFIC_REQUIRE_NOTARIZATION:-}" == "1" ]]; then
  echo "Releases must be signed with a Developer ID Application identity and notarized; set the signing identity and notary credentials." >&2
  exit 1
fi

export OPENTRAFFIC_CONFIGURATION=release
export OPENTRAFFIC_ARCHS="${OPENTRAFFIC_ARCHS:-arm64 x86_64}"
export OPENTRAFFIC_DIST_DIR="$OUT_DIR"
"$ROOT_DIR/script/build_and_run.sh" --build-only

/usr/bin/codesign --verify --deep --strict "$APP"

# Sends a file to Apple's notary service and waits; prints Apple's log if it's rejected.
notarize() {
  local result
  result="$(/usr/bin/xcrun notarytool submit "$1" "${NOTARY_ARGS[@]}" --wait --output-format json)" || true
  if [[ "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("status",""))' "$result" 2>/dev/null)" != "Accepted" ]]; then
    echo "Notarization of $(basename "$1") failed: $result" >&2
    local id
    id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("id",""))' "$result" 2>/dev/null || true)"
    [[ -n "$id" ]] && /usr/bin/xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" >&2 || true
    exit 1
  fi
  echo "Notarized $(basename "$1")"
}

if [[ $NOTARIZE == 1 ]]; then
  # The app first, stapled, so a copy dragged out of the disk image opens offline too.
  /usr/bin/ditto -c -k --keepParent "$APP" "$OUT_DIR/OpenTraffic-notarize.zip"
  notarize "$OUT_DIR/OpenTraffic-notarize.zip"
  rm "$OUT_DIR/OpenTraffic-notarize.zip"
  /usr/bin/xcrun stapler staple "$APP"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$APP"
fi
echo "Built $APP ($(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist") build $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist"))"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT_DIR/LICENSE" "$STAGING/License.txt"
UNNOTARIZED_NOTE=""
if [[ $NOTARIZE != 1 ]]; then
  UNNOTARIZED_NOTE=$'\nThis build is not notarized by Apple. If macOS says it can\'t verify the developer:
  - Open System Settings → Privacy & Security.
  - Scroll to "OpenTraffic was blocked…" and click Open Anyway, then confirm.
You only need to do this once.\n'
fi
cat > "$STAGING/How to install.txt" <<TEXT
OpenTraffic $VERSION

1. Drag OpenTraffic into Applications.
2. Open OpenTraffic from Applications.
${UNNOTARIZED_NOTE}
OpenTraffic lives in the menu bar, and the opentraffic command for Terminal comes with it.
It uses cloudflared (brew install cloudflared), and optionally ngrok, Tailscale, or OpenTunnel,
which you install separately.
TEXT

# hdiutil sometimes reports "Resource busy" on build machines; it succeeds on a retry.
for attempt in 1 2 3; do
  /usr/bin/hdiutil create -quiet -volname "OpenTraffic $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" && break
  [[ $attempt == 3 ]] && exit 1
  sleep 5
done

if [[ $NOTARIZE == 1 ]]; then
  /usr/bin/codesign --force --timestamp --sign "$OPENTRAFFIC_SIGNING_IDENTITY" "$DMG"
  notarize "$DMG"
  /usr/bin/xcrun stapler staple "$DMG"
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
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
section = re.search(r"^## " + re.escape(version) + r"(?: \([^)\n]*\))?\n(.*?)(?=^## |\Z)", open(changelog).read(), re.S | re.M)
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
