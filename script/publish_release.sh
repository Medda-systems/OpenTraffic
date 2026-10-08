#!/usr/bin/env bash
# Publishes what script/package_dmg.sh built in dist/release as OpenTraffic <version>:
#   1. tags the current commit v<version> in this (source) repository and pushes the tag;
#   2. creates the GitHub Release in the public Medda-systems/OpenTraffic-releases with the disk
#      image, its checksum, and appcast.xml, the update feed every installed copy checks;
#   3. points the Homebrew cask in Medda-systems/homebrew-tap at the new disk image.
# Needs the GitHub CLI (gh), signed in with access to those repositories.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
OUT_DIR="$ROOT_DIR/dist/release"
DMG="$OUT_DIR/OpenTraffic-$VERSION.dmg"
RELEASES_REPO="Medda-systems/OpenTraffic-releases"
TAP_REPO="Medda-systems/homebrew-tap"
TAG="v$VERSION"

fail() { echo "publish_release: $1" >&2; exit 1; }
[[ -f "$DMG" && -f "$DMG.sha256" && -f "$OUT_DIR/appcast.xml" ]] || fail "run script/package_dmg.sh first"
grep -q "<sparkle:shortVersionString>$VERSION<" "$OUT_DIR/appcast.xml" || fail "appcast.xml isn't for $VERSION"
grep -q "releases/download/$TAG/" "$OUT_DIR/appcast.xml" || fail "appcast.xml doesn't point at the $TAG release (OPENTRAFFIC_DOWNLOAD_BASE set?)"
[[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] || fail "commit your changes first"
git -C "$ROOT_DIR" fetch -q origin
[[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" == "$(git -C "$ROOT_DIR" rev-parse '@{upstream}')" ]] || fail "push this commit first"
built="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$OUT_DIR/OpenTraffic.app/Contents/Info.plist")"
[[ "$built" == "$(git -C "$ROOT_DIR" rev-list --count HEAD)" ]] || fail "dist/release was built from another commit; run script/package_dmg.sh again"

# 1. The source tag.
git -C "$ROOT_DIR" tag -a "$TAG" -m "OpenTraffic $VERSION"
git -C "$ROOT_DIR" push -q origin "$TAG"

# 2. The public release: this version's changelog, then how to install.
NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
{
  awk -v version="$VERSION" '$0 == "## " version { found = 1; next } /^## / && found { exit } found' "$ROOT_DIR/CHANGELOG.md"
  cat <<TEXT

## Install

\`\`\`sh
brew tap medda-systems/tap
brew trust --cask medda-systems/tap/opentraffic
brew install --cask opentraffic
\`\`\`

Or download \`OpenTraffic-$VERSION.dmg\` below, open it, and drag OpenTraffic into Applications. Installed copies update themselves.

This build isn't notarized yet, so the first launch is blocked: on macOS 15 or later, open **System Settings → Privacy & Security** and click **Open Anyway**; on macOS 14, Control-click the app and choose **Open**. Check the download with \`shasum -a 256 -c OpenTraffic-$VERSION.dmg.sha256\`.

Universal (Apple silicon and Intel), macOS 14 or later.
TEXT
} > "$NOTES"
gh release create "$TAG" "$DMG" "$DMG.sha256" "$OUT_DIR/appcast.xml" \
  --repo "$RELEASES_REPO" --title "OpenTraffic $VERSION" --notes-file "$NOTES" --latest

# 3. The Homebrew cask.
TAP="$(mktemp -d)"
trap 'rm -f "$NOTES"; rm -rf "$TAP"' EXIT
gh repo clone "$TAP_REPO" "$TAP" -- -q
mkdir -p "$TAP/Casks"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$(cut -d' ' -f1 "$DMG.sha256")/" \
  "$ROOT_DIR/script/opentraffic.rb.in" > "$TAP/Casks/opentraffic.rb"
git -C "$TAP" add Casks/opentraffic.rb
git -C "$TAP" commit -q -m "opentraffic $VERSION"
git -C "$TAP" push -q

echo "Published OpenTraffic $VERSION:"
echo "  https://github.com/$RELEASES_REPO/releases/tag/$TAG"
echo "  brew tap medda-systems/tap && brew trust --cask medda-systems/tap/opentraffic && brew install --cask opentraffic"
