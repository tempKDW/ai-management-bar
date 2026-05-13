import Foundation

/// hook.py 와 transcript_signals.py 의 정본을 임베드한 사본입니다.
///
/// **동기화 주의**: `hook/hook.py` · `hook/transcript_signals.py` 가 진실 소스
/// (single source of truth) 이며, 그 내용을 그대로 여기 raw string 으로 복사해
/// 둡니다. 두 파일 중 어느 쪽이든 수정하면 이 파일도 같이 업데이트해야 합니다
/// (README 의 sync 안내 참조).
enum EmbeddedHookSource {
    static let hookSource: String = #"""
#!/usr/bin/env python3
"""Claude Code menubar hook.

Reads a JSON event payload from stdin and updates the session status file at
~/.claude/menubar/sessions/<session_id>.json. Designed to be wired into every
Claude Code lifecycle hook (SessionStart, UserPromptSubmit, PreToolUse, Stop,
Notification, SessionEnd).

Errors are swallowed (exit 0) so a broken hook never blocks Claude Code.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# transcript_signals lives next to this script (same install dir).
sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    from transcript_signals import extract_signals
except ImportError:
    def extract_signals(_path):
        return {}

SESSIONS_DIR = Path.home() / ".claude" / "menubar" / "sessions"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def to_display(path: str | None) -> str:
    if not path:
        return ""
    home = str(Path.home())
    if path == home:
        return "~"
    if path.startswith(home + "/"):
        return "~" + path[len(home):]
    return path


def get_branch(cwd: str | None) -> str | None:
    if not cwd:
        return None
    # symbolic-ref works even on a freshly-init'd repo without commits.
    try:
        r = subprocess.run(
            ["git", "-C", cwd, "symbolic-ref", "--short", "HEAD"],
            capture_output=True, text=True, timeout=2,
        )
        if r.returncode == 0:
            branch = r.stdout.strip()
            if branch:
                return branch
        # Detached HEAD: fall back to short SHA.
        r = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=2,
        )
        if r.returncode == 0:
            sha = r.stdout.strip()
            return f"({sha})" if sha else None
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None
    return None


def read_state(path: Path) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def write_state(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def truncate(s: str | None, limit: int) -> str | None:
    if s is None:
        return None
    s = str(s).strip().splitlines()[0] if str(s).strip() else ""
    if len(s) > limit:
        return s[: limit - 1] + "…"
    return s


def extract_last_assistant(transcript_path: str | None) -> str | None:
    if not transcript_path or not os.path.isfile(transcript_path):
        return None
    last_text = None
    try:
        with open(transcript_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if obj.get("type") != "assistant":
                    continue
                msg = obj.get("message", {})
                content = msg.get("content")
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "text":
                            text = block.get("text", "").strip()
                            if text:
                                last_text = text
                elif isinstance(content, str) and content.strip():
                    last_text = content.strip()
    except OSError:
        return None
    return last_text


def main() -> None:
    # 메뉴바 앱이 자체적으로 claude CLI 를 subprocess 로 호출할 때 (recap 용)
    # 그 spawn 한 claude 의 lifecycle hook 도 발화합니다. 그것은 사용자 세션이
    # 아니므로 즉시 종료해 state 파일을 만들지 않습니다.
    if os.environ.get("CLAUDE_MENUBAR_INTERNAL") == "1":
        sys.exit(0)

    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)

    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        sys.exit(0)

    event = payload.get("hook_event_name") or (sys.argv[1] if len(sys.argv) > 1 else "")
    session_id = payload.get("session_id")
    if not session_id:
        sys.exit(0)

    state_path = SESSIONS_DIR / f"{session_id}.json"

    if event == "SessionEnd":
        try:
            state_path.unlink()
        except FileNotFoundError:
            pass
        sys.exit(0)

    state = read_state(state_path)
    cwd = payload.get("cwd") or state.get("cwd") or os.getcwd()

    state.update({
        "claude_session_id": session_id,
        "cwd": cwd,
        "cwd_display": to_display(cwd),
        "branch": get_branch(cwd),
        "transcript_path": payload.get("transcript_path") or state.get("transcript_path"),
        "pid": os.getppid(),
        "updated_at": now_iso(),
    })

    iterm = os.environ.get("ITERM_SESSION_ID")
    if iterm:
        state["iterm_session_id"] = iterm

    if event == "SessionStart":
        # 세션 시작 직후엔 사용자 prompt 대기 중 — running 으로 표시하면
        # "AI 가 작업 중" 으로 오해. idle 이 정확.
        state["state"] = "idle"
        state["current_task"] = "세션 시작 · 입력 대기"

    elif event == "UserPromptSubmit":
        prompt = payload.get("prompt", "")
        state["state"] = "running"
        state["last_prompt"] = truncate(prompt, 100)
        state["current_task"] = truncate(prompt, 80) or "작업 중"

    elif event == "PreToolUse":
        # waiting 상태였더라도 PreToolUse 가 발화했다는 것 자체가 사용자가
        # 권한을 허용해 tool 실행이 시작됐다는 신호 — 무조건 running 으로.
        tool_name = payload.get("tool_name", "도구")
        state["state"] = "running"
        base = state.get("last_prompt") or ""
        state["current_task"] = (
            truncate(f"{tool_name} · {base}", 80) if base else f"{tool_name} 실행 중"
        )

    elif event == "PostToolUse":
        # tool 실행 직후 — AI 가 다음 응답·도구 호출을 준비 중. running 유지.
        state["state"] = "running"

    elif event == "Notification":
        message = payload.get("message", "")
        # 일반 turn 종료 후 사용자 차례를 알리는 routine notification 은 idle 로 분류.
        # 권한 요청·결정 요구 같은 명시적 action 필요는 waiting 으로 좁혀 유지.
        if "waiting for your input" in message.lower():
            state["state"] = "idle"
            # current_task 는 직전 Stop 에서 설정된 마지막 assistant 텍스트를 유지.
            # 만약 비어있으면 안내 문구로 fallback.
            if not state.get("current_task"):
                state["current_task"] = "사용자 차례"
        else:
            state["state"] = "waiting"
            state["current_task"] = truncate(message, 80) or "입력 대기"

    elif event == "Stop":
        state["state"] = "done"
        last_msg = extract_last_assistant(state.get("transcript_path"))
        if last_msg:
            state["current_task"] = truncate(last_msg, 80)
        elif state.get("last_prompt"):
            state["current_task"] = truncate(f"완료 · {state['last_prompt']}", 80)
        else:
            state["current_task"] = "완료"

    # Refresh re-entry signals on tool/turn boundaries. Cheap enough (single
    # pass over transcript) and keeps the menubar's expand panel fresh.
    if event in ("PostToolUse", "Stop", "UserPromptSubmit"):
        sig = extract_signals(state.get("transcript_path"))
        if sig:
            for k in ("last_edit", "recent_events", "signals", "last_recap"):
                if k in sig:
                    state[k] = sig[k]

    write_state(state_path, state)
    sys.exit(0)


if __name__ == "__main__":
    main()
"""#

    static let transcriptSignalsSource: String = #"""
#!/usr/bin/env python3
"""Heuristic signal extraction from a Claude Code transcript jsonl.

Produces fields used by the menubar app's re-entry brief panel:
  - last_edit: {"path": str} of most recent Edit/Write/NotebookEdit
  - recent_events: 5 most recent items (tool calls, user messages, tool errors)
  - signals: stop_reason, error_rate, repeated_tool

LLM-free; pure parsing of jsonl. Errors are swallowed (returns empty dict).
"""

from __future__ import annotations

import json
import os
from typing import Any

EDIT_TOOLS = {"Edit", "Write", "NotebookEdit"}
TEXT_PREVIEW_TOOLS = {"Read", "Glob", "Grep"}


def extract_signals(transcript_path: str | None) -> dict[str, Any]:
    if not transcript_path or not os.path.isfile(transcript_path):
        return {}
    try:
        return _scan(transcript_path)
    except OSError:
        return {}


def _scan(transcript_path: str) -> dict[str, Any]:
    events: list[dict] = []
    tool_uses: list[dict] = []
    user_results: list[dict] = []
    last_stop_reason: str | None = None
    last_edit: dict | None = None
    last_recap: dict | None = None

    with open(transcript_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            type_ = obj.get("type")
            ts = obj.get("timestamp")

            if type_ == "assistant":
                msg = obj.get("message", {}) or {}
                stop = msg.get("stop_reason")
                if stop is not None:
                    last_stop_reason = stop
                content = msg.get("content")
                if isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        btype = block.get("type")
                        if btype == "tool_use":
                            name = block.get("name", "")
                            inp = block.get("input", {}) or {}
                            tool_uses.append({"ts": ts, "name": name, "input": inp})
                            if name in EDIT_TOOLS:
                                fp = inp.get("file_path") or inp.get("notebook_path")
                                if fp:
                                    last_edit = {"path": fp}
                            events.append({
                                "ts": ts, "kind": "tool",
                                "text": _format_tool(name, inp),
                            })
                        elif btype == "text":
                            t = block.get("text") or ""
                            first = t.strip().splitlines()[0] if t.strip() else ""
                            if first:
                                events.append({
                                    "ts": ts, "kind": "assistant", "text": first[:120],
                                })

            elif type_ == "user":
                msg = obj.get("message", {}) or {}
                content = msg.get("content")
                # Claude Code 의 자동 compact summary 는 isCompactSummary=true 의
                # user message 로 transcript 에 들어옵니다. content 가 풍부한
                # recap 텍스트(이전 컨텍스트 요약)라 별도로 보존합니다.
                if obj.get("isCompactSummary"):
                    recap_text = content if isinstance(content, str) else _render_content_text(content)
                    if recap_text:
                        last_recap = {"ts": ts, "text": recap_text}
                if isinstance(content, str):
                    first = content.strip().splitlines()[0] if content.strip() else ""
                    if first:
                        events.append({
                            "ts": ts, "kind": "user", "text": first[:120],
                        })
                elif isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        if block.get("type") == "tool_result":
                            is_err = bool(block.get("is_error"))
                            user_results.append({"ts": ts, "is_error": is_err})
                            if is_err:
                                txt = _summarize_tool_result(block)
                                events.append({
                                    "ts": ts, "kind": "error",
                                    "text": txt or "tool error",
                                })
                        elif block.get("type") == "text":
                            t = block.get("text") or ""
                            first = t.strip().splitlines()[0] if t.strip() else ""
                            if first:
                                events.append({
                                    "ts": ts, "kind": "user", "text": first[:120],
                                })

    # recent_events: take the 5 most recent, then re-order chronologically
    # (oldest at top, newest at bottom — reads like a log).
    events.sort(key=lambda e: e.get("ts") or "", reverse=True)
    recent_events = list(reversed(events[:5]))

    # error_rate: last 20 tool_results
    user_results.sort(key=lambda r: r.get("ts") or "", reverse=True)
    last_n = user_results[:20]
    if last_n:
        err = sum(1 for r in last_n if r["is_error"])
        error_rate = round(err / len(last_n), 2)
    else:
        error_rate = 0.0

    # repeated_tool: among last 5 tool_uses, same name >=3
    tool_uses.sort(key=lambda t: t.get("ts") or "", reverse=True)
    recent_names = [t["name"] for t in tool_uses[:5]]
    repeated: str | None = None
    for name in set(recent_names):
        if name and recent_names.count(name) >= 3:
            repeated = name
            break

    signals = {
        "stop_reason": last_stop_reason,
        "error_rate": error_rate,
        "repeated_tool": repeated,
    }

    out: dict[str, Any] = {
        "last_edit": last_edit,
        "recent_events": recent_events,
        "signals": signals,
    }
    if last_recap:
        out["last_recap"] = last_recap
    return out


def _format_tool(name: str, inp: dict) -> str:
    if name in EDIT_TOOLS:
        fp = inp.get("file_path") or inp.get("notebook_path") or ""
        return f"{name} {_basename(fp)}".strip()
    if name in TEXT_PREVIEW_TOOLS:
        fp = inp.get("file_path") or inp.get("pattern") or ""
        return f"{name} {_basename(fp)}".strip()
    if name == "Bash":
        cmd = (inp.get("command") or "").splitlines()
        head = cmd[0] if cmd else ""
        return f"Bash · {head[:60]}"
    if name == "TodoWrite":
        todos = inp.get("todos") or []
        return f"TodoWrite ({len(todos)} todos)"
    return name or "(tool)"


def _basename(path: str) -> str:
    if not path:
        return ""
    return path.rsplit("/", 1)[-1]


def _render_content_text(content: Any) -> str:
    """content (str or list of blocks) 에서 평문 텍스트만 추출."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text":
                t = b.get("text")
                if isinstance(t, str):
                    parts.append(t)
        return "\n".join(parts)
    return ""


def _summarize_tool_result(block: dict) -> str:
    content = block.get("content")
    if isinstance(content, str):
        first = content.strip().splitlines()[0] if content.strip() else ""
        return first[:80]
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text":
                t = (b.get("text") or "").strip()
                if t:
                    return t.splitlines()[0][:80]
    return ""
"""#

    /// Backwards-compatible alias for older callers that referenced `source`.
    static var source: String { hookSource }
}
