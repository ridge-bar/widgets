#!/usr/bin/env python3
"""Sum Claude Code real-work token usage inside a time window.

Reads candidate transcript paths from stdin (a `find ... -mmin -N` list) and sums
"real work" tokens (input + output + cache_creation, excluding the huge but cheap
cache_read) for messages timestamped within the window. The window in seconds is
argv[1] (default 5h = 18000). Prints the total, abbreviated (e.g. 12M).
"""
import sys
import json
import time
from datetime import datetime

WINDOW: int = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 5 * 3600
CUTOFF = time.time() - WINDOW
total = 0

for path in sys.stdin:
    path = path.strip()
    if not path:
        continue
    try:
        with open(path, errors="ignore") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                ts = rec.get("timestamp", "")
                try:
                    when = datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
                except ValueError:
                    continue
                if when < CUTOFF:
                    continue
                usage = (rec.get("message") or {}).get("usage") or {}
                if usage:
                    total += (
                        usage.get("input_tokens", 0)
                        + usage.get("output_tokens", 0)
                        + usage.get("cache_creation_input_tokens", 0)
                    )
    except OSError:
        continue


def abbreviate(n):
    if n >= 1e9:
        return "%.1fB" % (n / 1e9)
    if n >= 1e6:
        return "%.0fM" % (n / 1e6)
    if n >= 1e3:
        return "%.0fK" % (n / 1e3)
    return str(int(n))


print(abbreviate(total))
