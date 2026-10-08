#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS_DIR="$ROOT_DIR/Assets"
BUILD_DIR="$ROOT_DIR/.build/icon-generation"
ICONSET_DIR="$BUILD_DIR/OpenTraffic.iconset"
PACKER="$BUILD_DIR/pack_icns"
# 1024 × 1024 with transparency around the icon tile.
MASTER_PNG="$ASSETS_DIR/opentraffic-app-icon.png"

mkdir -p "$BUILD_DIR" "$ICONSET_DIR"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"
/usr/bin/swiftc "$ROOT_DIR/script/pack_icns.swift" -o "$PACKER"

make_icon() {
  local size="$1"
  local name="$2"
  /usr/bin/sips -z "$size" "$size" "$MASTER_PNG" --out "$ICONSET_DIR/$name" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
cp "$MASTER_PNG" "$ICONSET_DIR/icon_512x512@2x.png"

"$PACKER" "$ASSETS_DIR/OpenTraffic.icns" \
  icp4 "$ICONSET_DIR/icon_16x16.png" \
  ic11 "$ICONSET_DIR/icon_16x16@2x.png" \
  icp5 "$ICONSET_DIR/icon_32x32.png" \
  ic12 "$ICONSET_DIR/icon_32x32@2x.png" \
  ic07 "$ICONSET_DIR/icon_128x128.png" \
  ic13 "$ICONSET_DIR/icon_128x128@2x.png" \
  ic08 "$ICONSET_DIR/icon_256x256.png" \
  ic14 "$ICONSET_DIR/icon_256x256@2x.png" \
  ic09 "$ICONSET_DIR/icon_512x512.png" \
  ic10 "$ICONSET_DIR/icon_512x512@2x.png"
