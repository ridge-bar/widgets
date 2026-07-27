#!/usr/bin/env python3
"""Parse Clockify time-entries (hydrated, newest first) into bar + popup state.

Reads the raw JSON array on stdin. Writes a cache (running flag, current label,
and the recent distinct tasks with the ids needed to resume them) to argv[1].
Prints, one per line: state (RUNNING/IDLE), current label, then each recent
task's label -- consumed by clockify.sh to set the popup rows.

Adapted from ~/.config/sketchybar/plugins/clockify_parse.py (sketchybar config).
"""
import sys
import json

MAXLEN = 26


def label(e):
    desc = (e.get("description") or "").strip().replace("\n", " ").replace("\t", " ")
    proj = ((e.get("project") or {}).get("name") or "").strip()
    if desc and proj:
        s = f"{proj} · {desc}"
    elif desc:
        s = desc
    elif proj:
        s = proj
    else:
        s = "(no description)"
    return s if len(s) <= MAXLEN else s[: MAXLEN - 1] + "…"


def main():
    cache_path = sys.argv[1]
    maxrows = int(sys.argv[2])
    try:
        entries = json.load(sys.stdin)
    except Exception:
        sys.exit(1)
    if not isinstance(entries, list):
        sys.exit(1)

    # Clockify does not guarantee the running entry is first in this list, so
    # find it anywhere (the one with no end time) rather than assuming index 0.
    running_entry = next((e for e in entries if e.get("timeInterval", {}).get("end") is None), None)
    running = running_entry is not None
    current_label = label(running_entry) if running else "Not tracking"

    seen = set()
    run_id = None
    if running_entry is not None:
        run_id = running_entry.get("id")
        seen.add(((running_entry.get("description") or ""), running_entry.get("projectId")))

    history = []
    for e in entries:
        if run_id is not None and e.get("id") == run_id:
            continue
        key = ((e.get("description") or ""), e.get("projectId"))
        if key in seen:
            continue
        seen.add(key)
        history.append({
            "description": e.get("description") or "",
            "projectId": e.get("projectId"),
            "taskId": e.get("taskId"),
            "tagIds": e.get("tagIds") or [],
            "label": label(e),
        })
        if len(history) >= maxrows:
            break

    with open(cache_path, "w") as f:
        json.dump({"running": running, "currentLabel": current_label, "history": history}, f)

    print("\n".join(["RUNNING" if running else "IDLE", current_label] + [h["label"] for h in history]))


main()
