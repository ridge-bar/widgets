#!/usr/bin/env python3
"""Parse wttr.in j1 JSON (stdin) for the bar: prints `temp<TAB>desc<TAB>near`.

`near` is the worst weather happening now or within ~6h (clear|rain|storm),
used to decide the widget background highlight.

Adapted from ~/.config/sketchybar/plugins/weather_parse.py.
"""
import sys
import json
from datetime import datetime


def severity(text: str, rain_chance: int = 0, thunder_chance: int = 0) -> int:
    t = text.lower()
    if "thunder" in t or "storm" in t or thunder_chance >= 50:
        return 2
    if "rain" in t or "drizzle" in t or "shower" in t or "sleet" in t or rain_chance >= 50:
        return 1
    return 0


def as_int(v: str) -> int:
    try:
        return int(v)
    except (TypeError, ValueError):
        return 0


data = json.load(sys.stdin)
cur = (data.get("current_condition") or [{}])[0]
temp = "%s°C" % cur.get("temp_C", "?")
desc = ((cur.get("weatherDesc") or [{}])[0].get("value") or "").strip()

rank = severity(desc)
now_h = datetime.now().hour
for h in (data.get("weather") or [{}])[0].get("hourly", []):
    hh = as_int(h.get("time", "0")) // 100
    if hh < now_h or hh > now_h + 6:
        continue
    hd = (h.get("weatherDesc") or [{}])[0].get("value") or ""
    rank = max(rank, severity(hd, as_int(h.get("chanceofrain")), as_int(h.get("chanceofthunder"))))

near = {0: "clear", 1: "rain", 2: "storm"}[rank]
print("%s\t%s\t%s" % (temp, desc, near))
