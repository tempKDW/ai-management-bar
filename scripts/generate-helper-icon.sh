#!/usr/bin/env bash
# Convert app/Resources/NotifierHelper-AppIcon.png (>=1024px square) into a
# macOS .icns at the same path. Run once after editing the source PNG;
# the resulting .icns is committed so end users / CI don't need to run this.
#
# Usage:
#   bash scripts/generate-helper-icon.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/app/Resources/NotifierHelper-AppIcon.png"
ICONSET="$ROOT/app/Resources/NotifierHelper-AppIcon.iconset"
OUT="$ROOT/app/Resources/NotifierHelper-AppIcon.icns"

if [[ ! -f "$SRC" ]]; then
    echo "Error: source PNG not found at $SRC" >&2
    exit 1
fi

echo "[icon] source: $SRC"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Apple iconset 표준 사이즈 (16, 32, 128, 256, 512 와 각 @2x). 1024 는 @2x of 512.
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    set -- $spec
    size=$1
    name=$2
    echo "[icon] $name (${size}x${size})"
    sips -z "$size" "$size" "$SRC" --out "$ICONSET/${name}.png" >/dev/null
done

echo "[icon] iconutil → $OUT"
iconutil --convert icns "$ICONSET" -o "$OUT"

# iconset 디렉토리는 중간 산출물이라 generated icns 만 commit. 정리.
rm -rf "$ICONSET"

echo "[icon] done"
ls -lh "$OUT"
