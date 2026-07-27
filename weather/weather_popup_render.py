#!/usr/bin/env python3
"""Render the weather popup from wttr.in j1 JSON (stdin).

Prints one `row|icon|label` line per popup item: current conditions
(now/feels/humidity/wind) then a 3-day forecast (rows 1-3).
"""
import sys
import json
import datetime

data = json.load(sys.stdin)
cur = (data.get("current_condition") or [{}])[0]
desc = ((cur.get("weatherDesc") or [{}])[0].get("value") or "").strip()

print("now|Now|%s°C  %s" % (cur.get("temp_C", "?"), desc))
print("feels|Feels like|%s°C" % cur.get("FeelsLikeC", "?"))
print("humidity|Humidity|%s%%" % cur.get("humidity", "?"))
print("wind|Wind|%s km/h %s" % (cur.get("windspeedKmph", "?"), cur.get("winddir16Point", "")))


def _int(v: str) -> int:
    try:
        return int(v)
    except (TypeError, ValueError):
        return 0


def _float(v: str) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


# Rain outlook over the next ~6h (today's 3-hourly slots; falls back to the next
# few slots late at night when none remain for today).
hourly = (data.get("weather") or [{}])[0].get("hourly", [])
now_h = datetime.datetime.now().hour
near = [h for h in hourly if now_h <= _int(h.get("time", "0")) // 100 <= now_h + 6] or hourly[:3]
rain_chance = max([_int(h.get("chanceofrain")) for h in near] or [0])
precip = sum(_float(h.get("precipMM")) for h in near)
print("rainchance|Rain chance|%d%%" % rain_chance)
print("precip|Precip (6h)|%.1f mm" % precip)

names = {0: "Today", 1: "Tomorrow"}
for idx, day in enumerate((data.get("weather") or [])[:3]):
    hourly = day.get("hourly") or []
    dd = ((hourly[4].get("weatherDesc") or [{}])[0].get("value") or "").strip() if len(hourly) > 4 else ""
    label = names.get(idx)
    if not label:
        try:
            label = datetime.date.fromisoformat(day["date"]).strftime("%a")
        except (ValueError, KeyError):
            label = day.get("date", "")
    print("%d|%s|%s°/%s°  %s" % (idx + 1, label, day.get("maxtempC", "?"), day.get("mintempC", "?"), dd))
