#!/usr/bin/env python3
"""Unit tests for hook.py.

Runs hook.py as a subprocess for each lifecycle event with a temporary HOME,
then asserts that the resulting state file matches expectations.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HOOK = Path(__file__).parent / "hook.py"


def run_hook(payload: dict, home: Path, env_extra: dict | None = None) -> int:
    env = os.environ.copy()
    env["HOME"] = str(home)
    if env_extra:
        env.update(env_extra)
    proc = subprocess.run(
        [sys.executable, str(HOOK)],
        input=json.dumps(payload),
        capture_output=True, text=True, env=env, timeout=5,
    )
    if proc.returncode != 0:
        print("STDERR:", proc.stderr, file=sys.stderr)
    return proc.returncode


def read_state(home: Path, session_id: str) -> dict | None:
    path = home / ".claude" / "menubar" / "sessions" / f"{session_id}.json"
    if not path.exists():
        return None
    return json.loads(path.read_text())


class HookTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.sid = "test-session-001"

    def tearDown(self):
        self.tmp.cleanup()

    def test_session_start_creates_file_in_idle(self):
        payload = {
            "hook_event_name": "SessionStart",
            "session_id": self.sid,
            "cwd": str(self.home),
            "transcript_path": "/tmp/fake.jsonl",
        }
        run_hook(payload, self.home, {"ITERM_SESSION_ID": "w0t0p0:UUID-A"})
        state = read_state(self.home, self.sid)
        self.assertIsNotNone(state)
        # 세션 시작 직후엔 사용자 입력 대기 — idle 이 정확 (running 아님)
        self.assertEqual(state["state"], "idle")
        self.assertIn("Session started", state["current_task"])
        self.assertEqual(state["iterm_session_id"], "w0t0p0:UUID-A")
        self.assertEqual(state["cwd_display"], "~")

    def test_user_prompt_sets_summary(self):
        # First start the session
        run_hook({"hook_event_name": "SessionStart", "session_id": self.sid,
                  "cwd": str(self.home)}, self.home)
        run_hook({
            "hook_event_name": "UserPromptSubmit",
            "session_id": self.sid,
            "cwd": str(self.home),
            "prompt": "메뉴바 앱의 상태 표시 로직을 작성해줘\n자세한 요구사항은 ...",
        }, self.home)
        state = read_state(self.home, self.sid)
        self.assertEqual(state["state"], "running")
        self.assertIn("메뉴바 앱", state["current_task"])
        self.assertIn("메뉴바 앱", state["last_prompt"])
        # Should be first line only
        self.assertNotIn("자세한", state["current_task"])

    def test_notification_action_needed_sets_waiting(self):
        run_hook({"hook_event_name": "SessionStart", "session_id": self.sid,
                  "cwd": str(self.home)}, self.home)
        run_hook({
            "hook_event_name": "Notification",
            "session_id": self.sid,
            "cwd": str(self.home),
            "message": "Bash 실행 허가 필요",
        }, self.home)
        state = read_state(self.home, self.sid)
        self.assertEqual(state["state"], "waiting")
        self.assertEqual(state["current_task"], "Bash 실행 허가 필요")

    def test_notification_routine_input_wait_sets_idle(self):
        run_hook({"hook_event_name": "SessionStart", "session_id": self.sid,
                  "cwd": str(self.home)}, self.home)
        # Stop 으로 마지막 assistant 텍스트가 current_task 에 기록되어 있다고 가정
        run_hook({
            "hook_event_name": "UserPromptSubmit",
            "session_id": self.sid,
            "cwd": str(self.home),
            "prompt": "구현해줘",
        }, self.home)
        # Claude Code 의 routine turn-end notification
        run_hook({
            "hook_event_name": "Notification",
            "session_id": self.sid,
            "cwd": str(self.home),
            "message": "Claude is waiting for your input",
        }, self.home)
        state = read_state(self.home, self.sid)
        self.assertEqual(state["state"], "idle")
        # current_task 는 직전 UserPromptSubmit 의 prompt 가 그대로 남아있어야 함
        self.assertEqual(state["current_task"], "구현해줘")

    def test_pre_tool_use_releases_waiting_state(self):
        """권한 요청 (waiting) 직후 사용자 허용 → tool 실행 (PreToolUse 발화) 시
        running 으로 자연 전환되어야 한다 (Phase 9). 이전엔 waiting 가드 때문에
        stuck 됐었음."""
        run_hook({"hook_event_name": "SessionStart", "session_id": self.sid,
                  "cwd": str(self.home)}, self.home)
        run_hook({"hook_event_name": "Notification", "session_id": self.sid,
                  "cwd": str(self.home), "message": "권한 필요"}, self.home)
        # 사용자 허용 → PreToolUse 발화 시 waiting 풀려야 함
        run_hook({"hook_event_name": "PreToolUse", "session_id": self.sid,
                  "cwd": str(self.home), "tool_name": "Bash"}, self.home)
        state = read_state(self.home, self.sid)
        self.assertEqual(state["state"], "running")
        self.assertIn("Bash", state["current_task"])

    def test_post_tool_use_sets_running(self):
        """tool 실행 종료 후 AI 가 다음 응답·도구 진행 중 — running 유지."""
        run_hook({"hook_event_name": "SessionStart", "session_id": self.sid,
                  "cwd": str(self.home)}, self.home)
        run_hook({"hook_event_name": "PostToolUse", "session_id": self.sid,
                  "cwd": str(self.home), "tool_name": "Bash"}, self.home)
        state = read_state(self.home, self.sid)
        self.assertEqual(state["state"], "running")

    def test_stop_uses_transcript(self):
        run_hook({"hook_event_name": "SessionStart", "session_id": self.sid,
                  "cwd": str(self.home)}, self.home)
        # Write a fake transcript
        transcript = self.home / "transcript.jsonl"
        transcript.write_text(
            json.dumps({"type": "user", "message": {"content": "안녕"}}) + "\n"
            + json.dumps({"type": "assistant", "message": {"content": [
                {"type": "text", "text": "첫 번째 응답"}
            ]}}) + "\n"
            + json.dumps({"type": "assistant", "message": {"content": [
                {"type": "text", "text": "최종 응답입니다"}
            ]}}) + "\n",
            encoding="utf-8",
        )
        run_hook({
            "hook_event_name": "Stop",
            "session_id": self.sid,
            "cwd": str(self.home),
            "transcript_path": str(transcript),
        }, self.home)
        state = read_state(self.home, self.sid)
        self.assertEqual(state["state"], "done")
        self.assertEqual(state["current_task"], "최종 응답입니다")

    def test_session_end_deletes_file(self):
        run_hook({"hook_event_name": "SessionStart", "session_id": self.sid,
                  "cwd": str(self.home)}, self.home)
        self.assertIsNotNone(read_state(self.home, self.sid))
        run_hook({"hook_event_name": "SessionEnd", "session_id": self.sid,
                  "cwd": str(self.home)}, self.home)
        self.assertIsNone(read_state(self.home, self.sid))

    def test_missing_session_id_is_noop(self):
        rc = run_hook({"hook_event_name": "SessionStart"}, self.home)
        self.assertEqual(rc, 0)
        sessions_dir = self.home / ".claude" / "menubar" / "sessions"
        self.assertEqual(list(sessions_dir.glob("*.json")), [])

    def test_invalid_json_is_noop(self):
        env = os.environ.copy()
        env["HOME"] = str(self.home)
        proc = subprocess.run(
            [sys.executable, str(HOOK)],
            input="not json{",
            capture_output=True, text=True, env=env, timeout=5,
        )
        self.assertEqual(proc.returncode, 0)

    def test_internal_env_marker_silent_exits(self):
        rc = run_hook({
            "hook_event_name": "SessionStart",
            "session_id": self.sid,
            "cwd": str(self.home),
        }, self.home, {"CLAUDE_MENUBAR_INTERNAL": "1"})
        self.assertEqual(rc, 0)
        # state file MUST NOT be created when the marker is present
        self.assertIsNone(read_state(self.home, self.sid))

    def test_long_prompt_truncated(self):
        run_hook({"hook_event_name": "SessionStart", "session_id": self.sid,
                  "cwd": str(self.home)}, self.home)
        long = "가" * 200
        run_hook({"hook_event_name": "UserPromptSubmit", "session_id": self.sid,
                  "cwd": str(self.home), "prompt": long}, self.home)
        state = read_state(self.home, self.sid)
        self.assertLessEqual(len(state["current_task"]), 80)
        self.assertTrue(state["current_task"].endswith("…"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
