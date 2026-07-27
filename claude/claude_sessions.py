#!/usr/bin/env python3
# Adapted from ~/.config/sketchybar/plugins/claude_sessions.py (sketchybar config).
"""Per-session state for the Claude Code SketchyBar popup.

Reads candidate transcript paths on stdin, takes the N most-recently-modified
(N = argv[1] = running `claude` process count). For each, prints one tab-separated
line:  STATE\tPROJECT\tAGO

  STATE   = "working" if the last user/assistant message is NOT an assistant
            end_turn, else "waiting".  Reuses the tail-read logic from
            claude_working.py.
  PROJECT = basename of the `cwd` field found in the transcript; falls back to
            the transcript file's parent-directory name.
  AGO     = compact human-readable age of the file (e.g. "12s", "3m", "1h").

Prints at most N lines, most-recent first.
"""
import sys
import os
import json
import time
from typing import Optional

TAIL = 1 << 20  # same budget as claude_working.py


def _last_role_message(path: str) -> Optional[dict]:
    try:
        with open(path, "rb") as fh:
            fh.seek(0, 2)
            size = fh.tell()
            fh.seek(max(0, size - TAIL))
            data = fh.read()
    except OSError:
        return None
    for raw in reversed(data.splitlines()):
        raw = raw.strip()
        if not raw:
            continue
        try:
            rec = json.loads(raw)
        except ValueError:
            continue
        msg = rec.get("message") or {}
        if msg.get("role") in ("user", "assistant"):
            return msg
    return None


def _cwd_from_transcript(path: str) -> Optional[str]:
    """Return the first `cwd` value found in the transcript, scanning from the
    tail so we find it quickly for large files."""
    try:
        with open(path, "rb") as fh:
            fh.seek(0, 2)
            size = fh.tell()
            fh.seek(max(0, size - TAIL))
            data = fh.read()
    except OSError:
        return None
    # Scan forward (oldest-first within the tail) so we get a stable cwd.
    for raw in data.splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            rec = json.loads(raw)
        except ValueError:
            continue
        cwd = rec.get("cwd")
        if cwd:
            return cwd
    return None


def _ago(seconds: float) -> str:
    s = int(seconds)
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m"
    return f"{s // 3600}h"


def _project_name(path: str) -> str:
    cwd = _cwd_from_transcript(path)
    if cwd:
        return os.path.basename(cwd.rstrip("/")) or cwd
    # Fall back to the parent directory's name (the hashed project dir).
    return os.path.basename(os.path.dirname(path))


def main() -> None:
    n = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 0
    files = [p.strip() for p in sys.stdin if p.strip()]
    if n <= 0 or not files:
        return

    now = time.time()
    try:
        files.sort(key=os.path.getmtime, reverse=True)
    except OSError:
        pass

    for path in files[:n]:
        msg = _last_role_message(path)
        if msg is None:
            state = "waiting"
        elif msg.get("role") == "assistant" and msg.get("stop_reason") == "end_turn":
            state = "waiting"
        else:
            state = "working"

        project = _project_name(path)

        try:
            age = now - os.path.getmtime(path)
        except OSError:
            age = 0.0

        print(f"{state}\t{project}\t{_ago(age)}")


if __name__ == "__main__":
    main()
