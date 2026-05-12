#!/usr/bin/env bash
# Install / preview Claude Code menubar hooks into ~/.claude/settings.json
#
# Usage:
#   ./scripts/install.sh           # preview only (no changes)
#   ./scripts/install.sh --apply   # write changes (with a timestamped backup)
#
# The script ensures ~/.claude/menubar/sessions exists and patches the hooks
# section of ~/.claude/settings.json to call hook.py for each lifecycle event.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_PATH="$REPO_DIR/hook/hook.py"
SETTINGS="$HOME/.claude/settings.json"
SESSIONS_DIR="$HOME/.claude/menubar/sessions"
APPLY=false

if [[ "${1:-}" == "--apply" ]]; then
  APPLY=true
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required. Install with: brew install jq" >&2
  exit 1
fi

if [[ ! -x "$HOOK_PATH" ]]; then
  echo "Error: hook script not executable: $HOOK_PATH" >&2
  echo "Run: chmod +x $HOOK_PATH" >&2
  exit 1
fi

mkdir -p "$SESSIONS_DIR"
echo "[ok] sessions dir: $SESSIONS_DIR"

# Each lifecycle event maps to one hook entry that runs hook.py.
EVENTS=(SessionStart UserPromptSubmit PreToolUse Stop Notification SessionEnd)

# Build a JSON patch fragment.
patch=$(jq -n --arg cmd "$HOOK_PATH" '
  {
    SessionStart:      [ { hooks: [ { type: "command", command: $cmd } ] } ],
    UserPromptSubmit:  [ { hooks: [ { type: "command", command: $cmd } ] } ],
    PreToolUse:        [ { hooks: [ { type: "command", command: $cmd } ] } ],
    Stop:              [ { hooks: [ { type: "command", command: $cmd } ] } ],
    Notification:      [ { hooks: [ { type: "command", command: $cmd } ] } ],
    SessionEnd:        [ { hooks: [ { type: "command", command: $cmd } ] } ]
  }
')

if [[ -f "$SETTINGS" ]]; then
  current=$(cat "$SETTINGS")
else
  current="{}"
fi

merged=$(jq --argjson patch "$patch" '
  .hooks = ((.hooks // {}) * $patch)
' <<<"$current")

echo
echo "=== Preview: hooks section after merge ==="
jq '.hooks' <<<"$merged"
echo "=========================================="

if ! $APPLY; then
  echo
  echo "Preview only. To apply, re-run with --apply"
  exit 0
fi

# Apply with backup
ts=$(date +%Y%m%d-%H%M%S)
mkdir -p "$(dirname "$SETTINGS")"
if [[ -f "$SETTINGS" ]]; then
  cp "$SETTINGS" "$SETTINGS.bak.$ts"
  echo "[ok] backup: $SETTINGS.bak.$ts"
fi
printf '%s\n' "$merged" >"$SETTINGS"
echo "[ok] wrote: $SETTINGS"
