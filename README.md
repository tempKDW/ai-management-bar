# ai-management-bar

> A macOS menubar app that surfaces every Claude Code session running in iTerm2 — with auto-generated recaps so you can re-orient at a glance after stepping away.

## Goals

This tool solves two problems:

1. **Easier Claude Code tab management** — see every Claude Code session running across iTerm2 tabs in one menubar dropdown, click a row to jump to that tab, and read each session's state (running / awaiting input / done) at a glance.
2. **Catch up on AI work at a glance** — each row shows where the session is working (cwd · git branch · current task). When you've been AFK for 5+ minutes, the app runs `claude` in the background to produce a short recap so the dropdown is ready the moment you open it.

## At a glance

```
●  Claude Code (3)
─────────────────────────────────────────────────
🔵 🟢  ~/WorkSpace/my-wiki  ·  main          running    ▶
       Refactoring the notes-organizer script
─────────────────────────────────────────────────
   🔔  ~/WorkSpace/fleet-deploy  ·  feat/x   waiting    ▶
       Bash approval required
─────────────────────────────────────────────────
   ✅  ~/WorkSpace/docs-update   ·  main     done       ▶
       PR #423 merged
─────────────────────────────────────────────────
```

Expanding the `▶ chevron` reveals:

```
🌀 Auto recap (2m ago)
   Stripped the ineffective rules from the global CLAUDE.md so behavior
   and collaboration guidance lead. Validation of the wiki-ops rules in
   my-wiki/CLAUDE.md is still pending.

📋 Compact recap (previous context summary)    ← Claude Code's compact summary, when present
   Summary: 1. Primary Request: ...

📍 Location
   src/api.py (last edit)
   ~/WorkSpace/my-wiki · main
─────────────────────────────────────────────────
[Copy]  [iTerm tab]
```

Menubar icon is **state-aware**:
- all idle/done → grey outline bubble
- any running → filled bubble
- any waiting → **orange exclamation bubble** (catches the eye)

## How it works

```
┌──────────────────────────┐    file/event       ┌──────────────────────────┐
│  Claude Code session     │ ─────────────────▶  │   SwiftUI MenuBarExtra   │
│  (iTerm tab N)           │   state JSON        │   app (single process)   │
│                          │                     │                          │
│  lifecycle hooks         │                     │  • FSEvents directory    │
│  (SessionStart, Stop, …) │                     │    watcher               │
│                          │                     │  • row click → iTerm tab │
│                          │                     │  • 5 min AFK → claude    │
│                          │                     │    CLI recap (bg)        │
└──────────────────────────┘                     └──────────────────────────┘
```

Three components:

1. **Hook script** (`~/.claude/menubar/bin/hook.py`)
   - Claude Code sends a JSON payload on each lifecycle event via stdin.
   - The hook updates the state file at `~/.claude/menubar/sessions/<session_id>.json`.
2. **State directory** — one file per session (single source of truth).
3. **SwiftUI MenuBarExtra app**
   - Watches the state directory with FSEvents → instant UI updates.
   - Polls every 10 seconds to detect 5 min AFK + transcript change → calls `claude` CLI in the background.
   - Row click → `osascript` activates the iTerm2 tab (via `ITERM_SESSION_ID` mapping).

## Languages

UI labels and auto-recap output ship in **English and Korean**. A segmented picker in the footer (Auto / KO / EN) toggles the active language. **Auto** follows the macOS system language: Korean system → Korean, otherwise English. Toggling language re-triggers recap generation for all sessions so existing recaps switch to the new language.

## Quick start (built binary)

GitHub Actions builds a macOS `.app` bundle on every push to `main` and publishes it to [Releases → Latest](https://github.com/tempKDW/ai-management-bar/releases/latest).

1. **Download** `ClaudeMenubar.app.zip` and unzip it.
2. **Move** `ClaudeMenubar.app` to `/Applications` or `~/Applications`.
3. **Gatekeeper bypass (first launch only)** — the build is unsigned:
   - Option A: in Finder, right-click `ClaudeMenubar.app` → **Open** → click "Open" again on the warning.
   - Option B: in a terminal, `xattr -dr com.apple.quarantine /Applications/ClaudeMenubar.app`.
4. **iTerm2 automation permission** — macOS prompts the first time you click a row → allow.
5. **Notification permission** (banner on `waiting` transitions) — the bundled `NotifierHelper.app` raises its own permission prompt on the first waiting detection → allow. If you deny, the menubar icon + row 🔔 emphasis still work; only the banner is suppressed.
   - **Focus mode** suppresses banners by default. Settings → Focus → add `AI Management Bar Notifier` to "Allowed Apps" to let banners through.

Requirements: macOS 13+ · `claude` CLI on `PATH` for auto recap (`which claude` to confirm).

## Build from source

```sh
xcode-select --install   # Swift toolchain (skip if already installed)
which claude             # verify the claude CLI

# Build & run
cd app
swift build -c release
./.build/release/ClaudeMenubar

# Or produce a packaged .app bundle
bash scripts/make-app-bundle.sh --build
open dist/ClaudeMenubar.app
```

On startup the app automatically:

1. Writes `~/.claude/menubar/bin/hook.py` and `transcript_signals.py` to disk.
2. Backs up `~/.claude/settings.json` and merges the hook entries safely (preserving any other hooks).
3. Shows the icon in the menubar and discovers existing live sessions.

## Launch at login (optional)

Add `ClaudeMenubar.app` to System Settings → Login Items.

## Auto recap policy

**Trigger**: transcript jsonl's mtime is older than `now - 5 min` (AFK heuristic). Only fires if the transcript hash changed since the last recap.

**Once per quiet period**: after a recap is generated, no further calls until new activity → another 5 min quiet wait.

**Cost**: charged against your Claude subscription quota (`--model haiku` by default).

**Latency**: zero seconds when you open the dropdown — the call has already finished in the background.

## File layout

```
.
├── hook/
│   ├── hook.py                 ← canonical
│   ├── transcript_signals.py   ← jsonl signal extraction (last edit · compact recap)
│   ├── test_hook.py
│   └── test_transcript_signals.py
├── app/                        ← Swift Package Manager
│   ├── Package.swift
│   ├── Info.plist
│   ├── NotifierHelper-Info.plist     ← helper bundle Info.plist
│   └── Sources/
│       ├── ClaudeMenubar/
│       │   ├── ClaudeMenubarApp.swift     ← @main · MenuBarExtra
│       │   ├── SessionState.swift
│       │   ├── SessionStore.swift         ← FSEvents · polling · patch
│       │   ├── SessionRowView.swift       ← row · chevron · expand
│       │   ├── ReentryBriefView.swift     ← brief panel
│       │   ├── ITermActivator.swift       ← osascript iTerm2 tab activation
│       │   ├── ClaudeRecapGenerator.swift ← AFK auto recap
│       │   ├── HookInstaller.swift        ← settings.json safe merge
│       │   ├── SessionDiscovery.swift     ← discover sessions started before app launch
│       │   ├── Notifier.swift             ← waiting → banner (launches helper)
│       │   ├── Localizer.swift            ← AppLanguage + L10n keys (KO / EN)
│       │   └── EmbeddedHookSource.swift   ← embedded hook copy (single-binary distribution)
│       └── NotifierHelper/main.swift      ← UN banner sender with its own bundle ID
└── scripts/
    └── install.sh              ← CLI hook installer (optional)
```

## Development

### Python unit tests

```sh
python3 hook/test_hook.py
python3 hook/test_transcript_signals.py
```

### Verify hook canonical ↔ Swift embed sync

`hook/hook.py` and `hook/transcript_signals.py` are the source of truth; `app/Sources/ClaudeMenubar/EmbeddedHookSource.swift` embeds them as raw strings so the app can ship standalone. When you edit one, update the other:

```sh
# hook.py sync check
diff <(python3 -c "import re; s=open('app/Sources/ClaudeMenubar/EmbeddedHookSource.swift').read(); m=re.search(r'hookSource: String = #\"\"\"\n(.*?)\n\"\"\"#', s, re.S); print(m.group(1))") hook/hook.py

# transcript_signals.py sync check
diff <(python3 -c "import re; s=open('app/Sources/ClaudeMenubar/EmbeddedHookSource.swift').read(); m=re.search(r'transcriptSignalsSource: String = #\"\"\"\n(.*?)\n\"\"\"#', s, re.S); print(m.group(1))") hook/transcript_signals.py
```

No diff = in sync (a trailing-newline-only diff is benign).

## Reporting an issue

If the menubar icon disappears, the recap stalls, or anything else looks wrong, please share the following so it can be triaged quickly:

1. **macOS version** — `sw_vers -productVersion`.
2. **App build identity** — open the menubar dropdown → ⚙ Settings → the small grey line at the bottom (e.g. `v0.1.0 · build a1b2c3d · 2026-05-13`). If the build line shows `local`, mention that.
3. **What you were doing just before the issue** — sleep/wake, time passed, a specific click, switching network, etc.
4. **Is the process alive?** — open Activity Monitor and search for `ClaudeMenubar`. If the row exists but the menubar icon is gone, that points to a UI bug; if the row is gone, the process crashed.
5. **Crash log** — check `~/Library/Logs/DiagnosticReports/` for any file beginning with `ClaudeMenubar` and attach it.
6. **Session files on disk** — `ls ~/.claude/menubar/sessions/ | wc -l`. Zero is fine on its own, but useful context.

## Intentionally out of scope (YAGNI)

- Non-iTerm2 / non-VSCode terminals (VSCode click-jump is window-level only — VSCode exposes no external API for tab-level focus)
- A standalone dashboard window
- Remote sessions
- Cross-session linking
- Progress percentage (TodoWrite parsing)

If any of these become valuable, they earn their own phase.

## License

[MIT](LICENSE) © 2026 Dong-wook Kim ([@tempKDW](https://github.com/tempKDW))

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
