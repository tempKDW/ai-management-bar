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
