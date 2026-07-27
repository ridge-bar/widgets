#!/usr/bin/env python3
# Adapted from ~/.config/sketchybar/plugins/claude_working.py (sketchybar config).
"""Detect whether any active Claude Code session is actively working (mid-turn).

A session is "working" when its last user/assistant message is NOT an assistant
end_turn -- i.e. the user just sent a message, or the assistant is mid-turn
(thinking / streaming / running a tool, whose tool_result is a user-role entry).
Reads candidate transcript paths on stdin, takes the N most-recently modified
(N = argv[1] = running session count). Prints 1 if any is working, else 0.
"""
import sys
import os
import json

TAIL = 1 << 20

n = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 0
files = [p.strip() for p in sys.stdin if p.strip()]
if n <= 0 or not files:
    print(0)
    sys.exit(0)

try:
    files.sort(key=os.path.getmtime, reverse=True)
except OSError:
    pass


def last_role_message(path):
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


working = 0
for path in files[:n]:
    msg = last_role_message(path)
    if not msg:
        continue
    if not (msg.get("role") == "assistant" and msg.get("stop_reason") == "end_turn"):
        working = 1
        break

print(working)
