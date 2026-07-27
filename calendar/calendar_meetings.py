#!/usr/bin/env python3
"""Apple Calendar meetings for the ridge calendar plugin's date-item popup.

Emits one JSON object on stdout: {"busy": <bool>, "rows": [<popup rows>]}.
Contract: ALWAYS print valid JSON and exit 0, whatever the DB contains. Any
DB access failure (missing file, no Full Disk Access, locked file) degrades
to a placeholder row; a malformed meeting row (e.g. an out-of-range
occurrence_date) is skipped individually; a top-level backstop covers
anything else - so the poll loop that invokes this script never freezes.
stdlib only, no third-party deps.

Ported from sketchybar's clock.sh (busy count query) and calendar_popup.sh
(meetings query + row formatting) - see README.md.
"""
import json
import os
import re
import shlex
import sqlite3
import sys
import time
from datetime import datetime

# CoreData reference date (2001-01-01 UTC) in Unix epoch seconds. Calendar's
# occurrence_date/occurrence_end_date columns are seconds since this epoch,
# not Unix epoch.
CORE_DATA_EPOCH = 978307200

DEFAULT_DB_PATH = os.path.expanduser(
    "~/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb"
)

BUSY_QUERY = """
    SELECT count(*) FROM OccurrenceCache oc
    JOIN CalendarItem ci ON oc.event_id = ci.ROWID
    WHERE oc.occurrence_date <= ? AND oc.occurrence_end_date >= ?
      AND ci.all_day = 0 AND ci.availability IS NOT 1
"""

# Meeting-link detection: fields are checked in this order (url_field,
# location, notes), first match wins; within a field, LINK_PATTERNS order
# breaks ties between providers. Schema-agnostic: which of those three
# fields is actually populated depends on _build_meetings_query's column
# probing below.
LINK_PATTERNS = [
    re.compile(r"https?://meet\.google\.com/\S+"),
    re.compile(r"https?://teams\.(?:microsoft|live)\.com/\S+"),
    re.compile(r"(?:https?://[\w.-]*zoom\.us/j/\S+|zoommtg://\S+)"),
    re.compile(r"(?:https?://facetime\.apple\.com/join\S*|facetime(?:-audio)?:\S+)"),
]

_TRAILING_PUNCT = ")>\"',."


def _strip_trailing_punct(url):
    while url and url[-1] in _TRAILING_PUNCT:
        url = url[:-1]
    return url


def extract_meeting_link(url_field, location, notes):
    """Returns the first meeting URL found in (url_field, location, notes),
    checked field-by-field in that order; within a field, LINK_PATTERNS
    order breaks ties between providers. None if no field is populated or
    none match."""
    fields = (url_field, location, notes)
    for field in fields:
        if not field:
            continue
        for pattern in LINK_PATTERNS:
            match = pattern.search(field)
            if match:
                return _strip_trailing_punct(match.group(0))
    return None


# \Z (not $) so a trailing newline can't sneak an extra char past the guard.
_IDENTIFIER = re.compile(r"^\w+\Z")


def _table_columns(cur, table):
    # PRAGMA doesn't support bind parameters for the table name, so it's
    # interpolated directly - only ever safe because callers pass hardcoded
    # literals ("CalendarItem", "Location"), enforced here as a guard.
    if not _IDENTIFIER.match(table):
        return set()
    try:
        cur.execute(f"PRAGMA table_info({table})")
        return {row[1] for row in cur.fetchall()}
    except Exception:
        return set()


def _table_exists(cur, table):
    try:
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name = ?", (table,))
        return cur.fetchone() is not None
    except Exception:
        return False


def _build_meetings_query(cur):
    """Builds the meetings SELECT, probing the schema via PRAGMA so a column
    or table missing on a given macOS version (url, conference_url_detected,
    description, the Location table) degrades to a literal NULL instead of
    raising - the file's always-valid-JSON/exit-0 contract applies here too."""
    ci_cols = _table_columns(cur, "CalendarItem")

    url_expr = "NULL"
    for col in ("url", "conference_url_detected"):
        if col in ci_cols:
            url_expr = f"ci.{col}"
            break

    notes_expr = "ci.description" if "description" in ci_cols else "NULL"

    location_expr = "NULL"
    join_clause = ""
    if "location_id" in ci_cols and _table_exists(cur, "Location"):
        loc_cols = _table_columns(cur, "Location")
        # "title"/"address" is a guess, unverified against a live macOS schema
        # dump; degrades to NULL location if neither column is present.
        loc_text_col = next((c for c in ("title", "address") if c in loc_cols), None)
        if loc_text_col:
            join_clause = "LEFT JOIN Location loc ON loc.ROWID = ci.location_id"
            location_expr = f"loc.{loc_text_col}"

    return f"""
        SELECT oc.occurrence_date, oc.occurrence_end_date, ci.availability, ci.summary,
               {url_expr} AS link_url, {location_expr} AS location, {notes_expr} AS notes
        FROM OccurrenceCache oc
        JOIN CalendarItem ci ON oc.event_id = ci.ROWID
        {join_clause}
        WHERE ci.all_day = 0
          AND oc.occurrence_end_date >= ?
          AND oc.occurrence_date <= ?
        ORDER BY oc.occurrence_date
        LIMIT ?
    """


def _int_env(name, default):
    try:
        n = int(os.environ.get(name) or default)
        return n if n > 0 else default
    except (TypeError, ValueError):
        return default


def _db_path():
    if len(sys.argv) > 1 and sys.argv[1]:
        return sys.argv[1]
    return os.environ.get("RIDGE_CAL_DB") or DEFAULT_DB_PATH


MAX_MEETINGS = _int_env("RIDGE_CAL_MAXROWS", 8)
CALENDAR_APP = os.environ.get("RIDGE_CAL_APP") or "BusyCal"
HEADER_COLOR = os.environ.get("RIDGE_CAL_HEADER_COLOR") or "#7DCFFF"
ROW_TEXT_COLOR = os.environ.get("RIDGE_CAL_ROW_TEXT") or "#C0CAF5"
ROW_ICON_COLOR = os.environ.get("RIDGE_CAL_ROW_ICON") or "#565F89"
IN_PROGRESS_COLOR = os.environ.get("RIDGE_CAL_INPROGRESS") or "#9ECE6A"


def _header_row():
    return {"type": "header", "text": datetime.now().strftime("%a %d %b %Y"), "color": HEADER_COLOR}


def _degraded_rows():
    return [
        _header_row(),
        {"text": "Calendar access needed - grant Full Disk Access", "color": ROW_TEXT_COLOR},
    ]


def _format_start(occurrence_date):
    dt = datetime.fromtimestamp(occurrence_date + CORE_DATA_EPOCH)
    return dt.strftime("%H:%M") if dt.date() == datetime.now().date() else dt.strftime("%a %H:%M")


def _truncate_title(summary):
    s = (summary or "").strip()
    return s[:26] + ("…" if len(s) > 26 else "")


def _meeting_row(occurrence_date, occurrence_end_date, availability, summary,
                  link_url, location, notes, now_cd):
    start = _format_start(occurrence_date)
    title = _truncate_title(summary)
    in_progress = occurrence_date <= now_cd <= occurrence_end_date
    busy = availability != 1
    if in_progress:
        icon, icon_color = ("●", IN_PROGRESS_COLOR) if busy else ("○", IN_PROGRESS_COLOR)
    else:
        icon, icon_color = "○", ROW_ICON_COLOR

    # Rows are run via /bin/sh -c, so a calendar_app with a space (e.g.
    # "Microsoft Outlook") must be quoted to reach `open -a` intact.
    click = f"open -a {shlex.quote(CALENDAR_APP)}"
    if in_progress:
        link = extract_meeting_link(link_url, location, notes)
        if link:
            click = f"open {shlex.quote(link)}"

    return {
        "icon": icon,
        "icon_color": icon_color,
        "text": f"{start}  {title}",
        "color": ROW_TEXT_COLOR,
        "click": click,
    }


def main():
    now_cd = int(time.time()) - CORE_DATA_EPOCH
    end_cd = now_cd + 86400

    try:
        conn = sqlite3.connect(f"file:{_db_path()}?mode=ro", uri=True)
        try:
            cur = conn.cursor()
            cur.execute(BUSY_QUERY, (now_cd, now_cd))
            busy_row = cur.fetchone()
            busy = bool(busy_row and busy_row[0] > 0)

            cur.execute(_build_meetings_query(cur), (now_cd, end_cd, MAX_MEETINGS))
            meetings = cur.fetchall()
        finally:
            conn.close()
    except Exception:
        print(json.dumps({"busy": False, "rows": _degraded_rows()}))
        return

    # Format each meeting in isolation: a single malformed row (e.g. an
    # out-of-range occurrence_date that raises in datetime.fromtimestamp)
    # is skipped, not fatal. A top-level backstop still guarantees valid
    # JSON on exit if anything unexpected slips through.
    try:
        rows = [_header_row()]
        for m in meetings:
            try:
                rows.append(_meeting_row(*m, now_cd))
            except Exception:
                continue
        if len(rows) == 1:
            rows.append({"text": "No upcoming meetings", "color": ROW_TEXT_COLOR})
        print(json.dumps({"busy": busy, "rows": rows}))
    except Exception:
        print(json.dumps({
            "busy": False,
            "rows": [_header_row(), {"text": "No upcoming meetings", "color": ROW_TEXT_COLOR}],
        }))


if __name__ == "__main__":
    main()
