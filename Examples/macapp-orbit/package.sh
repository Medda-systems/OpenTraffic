#!/bin/sh
# Builds dist/Orbit.app, a finished debug app like Xcode would make: the SwiftPM executable in
# Contents/MacOS, an Info.plist with the bundle identifier se.medda.orbit, signed ad hoc.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
app="$here/dist/Orbit.app"

swift build --package-path "$here" -c debug --product Orbit
bin="$(swift build --package-path "$here" -c debug --show-bin-path)"

rm -rf "$here/dist"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Orbit" "$app/Contents/MacOS/Orbit"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Orbit</string>
	<key>CFBundleExecutable</key>
	<string>Orbit</string>
	<key>CFBundleIdentifier</key>
	<string>se.medda.orbit</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Orbit</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.business</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$app/Contents/PkgInfo"

codesign --force --sign - "$app" 2>/dev/null
echo "Built $app"
