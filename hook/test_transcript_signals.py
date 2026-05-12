#!/usr/bin/env python3
"""Tests for transcript_signals.extract_signals."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from transcript_signals import extract_signals


def write_jsonl(rows: list[dict]) -> Path:
    tmp = tempfile.NamedTemporaryFile(
        mode="w", suffix=".jsonl", delete=False, encoding="utf-8",
    )
    for r in rows:
        tmp.write(json.dumps(r) + "\n")
    tmp.close()
    return Path(tmp.name)


def assistant_tool_use(ts: str, name: str, **input_) -> dict:
    return {
        "type": "assistant",
        "timestamp": ts,
        "message": {
            "stop_reason": "tool_use",
            "content": [{"type": "tool_use", "name": name, "input": input_}],
        },
    }


def assistant_end(ts: str, text: str = "done") -> dict:
    return {
        "type": "assistant",
        "timestamp": ts,
        "message": {
            "stop_reason": "end_turn",
            "content": [{"type": "text", "text": text}],
        },
    }


def user_text(ts: str, text: str) -> dict:
    return {
        "type": "user", "timestamp": ts,
        "message": {"content": text},
    }


def user_tool_result(ts: str, is_error: bool, text: str = "ok") -> dict:
    return {
        "type": "user", "timestamp": ts,
        "message": {
            "content": [{
                "type": "tool_result",
                "is_error": is_error,
                "content": [{"type": "text", "text": text}],
            }],
        },
    }


class SignalTests(unittest.TestCase):

    def test_empty_or_missing(self):
        self.assertEqual(extract_signals(None), {})
        self.assertEqual(extract_signals("/tmp/does-not-exist.jsonl"), {})

    def test_last_edit_picks_latest(self):
        p = write_jsonl([
            assistant_tool_use("2026-05-12T01:00:00Z", "Read",
                               file_path="/repo/a.py"),
            assistant_tool_use("2026-05-12T01:01:00Z", "Edit",
                               file_path="/repo/a.py", old_string="x", new_string="y"),
            assistant_tool_use("2026-05-12T01:02:00Z", "Write",
                               file_path="/repo/b.py", content="..."),
        ])
        s = extract_signals(str(p))
        self.assertEqual(s["last_edit"], {"path": "/repo/b.py"})

    def test_recent_events_chronological_newest_last(self):
        p = write_jsonl([
            user_text("2026-05-12T01:00:00Z", "first prompt"),
            assistant_tool_use("2026-05-12T01:01:00Z", "Bash", command="ls"),
            user_tool_result("2026-05-12T01:02:00Z", False, "file1"),
            user_text("2026-05-12T01:03:00Z", "next prompt"),
            assistant_tool_use("2026-05-12T01:04:00Z", "Edit",
                               file_path="/repo/a.py", old_string="x", new_string="y"),
        ])
        s = extract_signals(str(p))
        events = s["recent_events"]
        self.assertGreaterEqual(len(events), 3)
        # newest at the bottom (chronological)
        self.assertEqual(events[-1]["kind"], "tool")
        self.assertIn("Edit", events[-1]["text"])

    def test_error_rate(self):
        rows = [user_tool_result(f"2026-05-12T01:{i:02d}:00Z", i % 3 == 0)
                for i in range(10)]
        p = write_jsonl(rows)
        s = extract_signals(str(p))
        # 4 of 10 are errors (indices 0, 3, 6, 9)
        self.assertAlmostEqual(s["signals"]["error_rate"], 0.4, places=2)

    def test_repeated_tool_detection(self):
        rows = [
            assistant_tool_use(f"2026-05-12T01:0{i}:00Z", "Bash", command=f"echo {i}")
            for i in range(5)
        ]
        p = write_jsonl(rows)
        s = extract_signals(str(p))
        self.assertEqual(s["signals"]["repeated_tool"], "Bash")

    def test_no_repeated_tool_when_varied(self):
        rows = [
            assistant_tool_use("2026-05-12T01:00:00Z", "Bash", command="ls"),
            assistant_tool_use("2026-05-12T01:01:00Z", "Edit",
                               file_path="/x", old_string="a", new_string="b"),
            assistant_tool_use("2026-05-12T01:02:00Z", "Read", file_path="/y"),
        ]
        p = write_jsonl(rows)
        s = extract_signals(str(p))
        self.assertIsNone(s["signals"]["repeated_tool"])

    def test_stop_reason_latest(self):
        p = write_jsonl([
            assistant_tool_use("2026-05-12T01:00:00Z", "Bash", command="ls"),
            assistant_end("2026-05-12T01:05:00Z", "complete"),
        ])
        s = extract_signals(str(p))
        self.assertEqual(s["signals"]["stop_reason"], "end_turn")

    def test_assistant_text_included_in_events(self):
        p = write_jsonl([
            user_text("2026-05-12T01:00:00Z", "테스트 실패 원인 찾아줘"),
            assistant_tool_use("2026-05-12T01:01:00Z", "Read", file_path="/a.py"),
            {
                "type": "assistant",
                "timestamp": "2026-05-12T01:02:00Z",
                "message": {
                    "stop_reason": "tool_use",
                    "content": [
                        {"type": "text", "text": "Read 결과를 보니 line 12 에서 누락된 import 가 원인입니다."},
                        {"type": "tool_use", "name": "Edit",
                         "input": {"file_path": "/a.py", "old_string": "x", "new_string": "y"}},
                    ],
                },
            },
        ])
        s = extract_signals(str(p))
        kinds = [e["kind"] for e in s["recent_events"]]
        self.assertIn("assistant", kinds)
        assistant_ev = next(e for e in s["recent_events"] if e["kind"] == "assistant")
        self.assertIn("Read 결과", assistant_ev["text"])

    def test_compact_summary_captured_as_last_recap(self):
        rows = [
            user_text("2026-05-12T01:00:00Z", "first prompt"),
            assistant_tool_use("2026-05-12T01:01:00Z", "Bash", command="ls"),
            {
                "type": "user",
                "timestamp": "2026-05-12T01:30:00Z",
                "isCompactSummary": True,
                "isVisibleInTranscriptOnly": True,
                "message": {
                    "role": "user",
                    "content": "Summary:\n1. Primary Request: ...\n2. Key context: ...",
                },
            },
            user_text("2026-05-12T01:31:00Z", "ok continue"),
        ]
        p = write_jsonl(rows)
        s = extract_signals(str(p))
        self.assertIn("last_recap", s)
        self.assertEqual(s["last_recap"]["ts"], "2026-05-12T01:30:00Z")
        self.assertIn("Primary Request", s["last_recap"]["text"])

    def test_debugging_loop_signal_shape(self):
        rows = []
        for i in range(5):
            ts_a = f"2026-05-12T01:{i*2:02d}:00Z"
            ts_b = f"2026-05-12T01:{i*2+1:02d}:00Z"
            rows.append(assistant_tool_use(ts_a, "Bash", command=f"pytest run {i}"))
            rows.append(user_tool_result(ts_b, True, "Test failure"))
        p = write_jsonl(rows)
        s = extract_signals(str(p))
        sig = s["signals"]
        self.assertEqual(sig["stop_reason"], "tool_use")
        self.assertGreaterEqual(sig["error_rate"], 0.5)
        self.assertEqual(sig["repeated_tool"], "Bash")


if __name__ == "__main__":
    unittest.main(verbosity=2)
