#!/usr/bin/env bash
# Publishes what script/package_dmg.sh built in dist/release as OpenTraffic <version>:
#   1. creates the GitHub Release in the public Medda-systems/OpenTraffic-releases with the disk
#      image, its checksum, appcast.xml (the update feed every installed copy checks), and the
#      one-line installer;
#   2. points the Homebrew cask in Medda-systems/homebrew-tap at the new disk image.
# Runs in CI (.github/workflows/release.yml) when a v<version> tag is pushed; the tag must point at
# the commit that was built. Needs the GitHub CLI (gh) with write access to those repositories.
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
[[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] || fail "the working tree has uncommitted changes"
[[ "$(git -C "$ROOT_DIR" rev-parse "$TAG^{commit}" 2>/dev/null)" == "$(git -C "$ROOT_DIR" rev-parse HEAD)" ]] \
  || fail "tag $TAG must point at the commit being released (push the tag; CI does the rest)"
built="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$OUT_DIR/OpenTraffic.app/Contents/Info.plist")"
[[ "$built" == "$(git -C "$ROOT_DIR" rev-list --count HEAD)" ]] || fail "dist/release was built from another commit; run script/package_dmg.sh again"

# 1. The public release: this version's changelog, then how to install.
NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
{
  awk -v version="$VERSION" '$0 == "## " version { found = 1; next } /^## / && found { exit } found' "$ROOT_DIR/CHANGELOG.md"
  cat <<TEXT

## Install

\`\`\`sh
curl -fsSL https://github.com/$RELEASES_REPO/releases/latest/download/install.sh | sh
\`\`\`

Or with Homebrew:

\`\`\`sh
brew tap medda-systems/tap
brew trust --cask medda-systems/tap/opentraffic
brew install --cask opentraffic
\`\`\`

Or download \`OpenTraffic-$VERSION.dmg\` below, open it, and drag OpenTraffic into Applications. Installed copies update themselves.

This build isn't notarized yet, so when installed from the disk image or Homebrew the first launch is blocked: on macOS 15 or later, open **System Settings → Privacy & Security** and click **Open Anyway**; on macOS 14, Control-click the app and choose **Open**. Check the download with \`shasum -a 256 -c OpenTraffic-$VERSION.dmg.sha256\`.

Universal (Apple silicon and Intel), macOS 14 or later.
TEXT
} > "$NOTES"
gh release create "$TAG" "$DMG" "$DMG.sha256" "$OUT_DIR/appcast.xml" "$ROOT_DIR/script/install.sh" \
  --repo "$RELEASES_REPO" --title "OpenTraffic $VERSION" --notes-file "$NOTES" --latest

# 2. The Homebrew cask.
TAP="$(mktemp -d)"
trap 'rm -f "$NOTES"; rm -rf "$TAP"' EXIT
gh repo clone "$TAP_REPO" "$TAP" -- -q
mkdir -p "$TAP/Casks"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$(cut -d' ' -f1 "$DMG.sha256")/" \
  "$ROOT_DIR/script/opentraffic.rb.in" > "$TAP/Casks/opentraffic.rb"
git -C "$TAP" add Casks/opentraffic.rb
git -C "$TAP" -c user.name="${GIT_AUTHOR_NAME:-OpenTraffic release}" \
  -c user.email="${GIT_AUTHOR_EMAIL:-54272777+araz-95@users.noreply.github.com}" commit -q -m "opentraffic $VERSION"
git -C "$TAP" push -q

echo "Published OpenTraffic $VERSION:"
echo "  https://github.com/$RELEASES_REPO/releases/tag/$TAG"
echo "  brew tap medda-systems/tap && brew trust --cask medda-systems/tap/opentraffic && brew install --cask opentraffic"
