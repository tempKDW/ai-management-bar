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
