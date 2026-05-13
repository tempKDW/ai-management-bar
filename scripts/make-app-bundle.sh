#!/usr/bin/env bash
# Package the release build into a macOS .app bundle.
#
# Usage:
#   bash scripts/make-app-bundle.sh           # uses existing app/.build/release binaries
#   bash scripts/make-app-bundle.sh --build   # runs swift build -c release first
#
# Output: dist/ClaudeMenubar.app
#   ├─ Contents/MacOS/ClaudeMenubar
#   └─ Contents/Helpers/NotifierHelper.app/
#       └─ Contents/MacOS/NotifierHelper      (UN banner sender, own bundleID)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/app/.build/release/ClaudeMenubar"
HELPER_BIN="$ROOT/app/.build/release/NotifierHelper"
PLIST="$ROOT/app/Info.plist"
HELPER_PLIST="$ROOT/app/NotifierHelper-Info.plist"
APP="$ROOT/dist/ClaudeMenubar.app"
HELPER_APP="$APP/Contents/Helpers/NotifierHelper.app"

if [[ "${1:-}" == "--build" ]]; then
    echo "[bundle] swift build -c release"
    (cd "$ROOT/app" && swift build -c release)
fi

for f in "$BIN" "$HELPER_BIN" "$PLIST" "$HELPER_PLIST"; do
    if [[ ! -e "$f" ]]; then
        echo "Error: missing $f" >&2
        echo "Run: $0 --build" >&2
        exit 1
    fi
done

echo "[bundle] cleaning $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "[bundle] main app: ClaudeMenubar"
cp "$BIN" "$APP/Contents/MacOS/ClaudeMenubar"
chmod +x "$APP/Contents/MacOS/ClaudeMenubar"
cp "$PLIST" "$APP/Contents/Info.plist"
printf 'APPL????' >"$APP/Contents/PkgInfo"

# Helper bundle: NotifierHelper.
# 메인 앱 (LSUIElement + 미서명) 에서 UNUserNotificationCenter 호출 시 권한 prompt 가
# silently dropped 되는 macOS 이슈가 있다. helper 를 별도 bundleID 의 .app 으로
# 분리하면 macOS 가 별개 앱으로 인식해 notification 등록 + 권한 흐름이 동작한다.
echo "[bundle] helper: NotifierHelper"
mkdir -p "$HELPER_APP/Contents/MacOS"
cp "$HELPER_BIN" "$HELPER_APP/Contents/MacOS/NotifierHelper"
chmod +x "$HELPER_APP/Contents/MacOS/NotifierHelper"
cp "$HELPER_PLIST" "$HELPER_APP/Contents/Info.plist"
printf 'APPL????' >"$HELPER_APP/Contents/PkgInfo"

# Ad-hoc 서명 — TCC 가 helper.app 의 identity 를 안정적으로 인식하려면 최소
# ad-hoc 서명이 필요하다. (재서명 없이도 unsigned 로 두면 codesign identity 가
# 매 실행 시 바뀌어 NotificationCenter 등록이 깨질 수 있음.)
echo "[bundle] ad-hoc sign helper"
codesign --force --sign - "$HELPER_APP" >/dev/null
echo "[bundle] ad-hoc sign main"
codesign --force --sign - "$APP" >/dev/null

echo "[bundle] done: $APP"
echo
echo "Verify:"
echo "  open $APP"
echo "Strip quarantine if downloaded:"
echo "  xattr -dr com.apple.quarantine $APP"
