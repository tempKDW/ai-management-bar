#!/usr/bin/env bash
# Package the release build into a macOS .app bundle.
#
# Usage:
#   bash scripts/make-app-bundle.sh           # uses existing app/.build/release binary
#   bash scripts/make-app-bundle.sh --build   # runs swift build -c release first
#
# Output: dist/ClaudeMenubar.app

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/app/.build/release/ClaudeMenubar"
PLIST="$ROOT/app/Info.plist"
APP="$ROOT/dist/ClaudeMenubar.app"

if [[ "${1:-}" == "--build" ]]; then
    echo "[bundle] swift build -c release"
    (cd "$ROOT/app" && swift build -c release)
fi

if [[ ! -x "$BIN" ]]; then
    echo "Error: binary not found at $BIN" >&2
    echo "Run: $0 --build" >&2
    exit 1
fi
if [[ ! -f "$PLIST" ]]; then
    echo "Error: Info.plist not found at $PLIST" >&2
    exit 1
fi

echo "[bundle] cleaning $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "[bundle] copying binary"
cp "$BIN" "$APP/Contents/MacOS/ClaudeMenubar"
chmod +x "$APP/Contents/MacOS/ClaudeMenubar"

echo "[bundle] copying Info.plist"
cp "$PLIST" "$APP/Contents/Info.plist"

# PkgInfo: 4-byte type code + 4-byte creator (optional but conventional).
printf 'APPL????' >"$APP/Contents/PkgInfo"

echo "[bundle] done: $APP"
echo
echo "Verify:"
echo "  open $APP"
echo "Strip quarantine if downloaded:"
echo "  xattr -dr com.apple.quarantine $APP"
