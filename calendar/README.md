# calendar plugin

A date item whose popup lists the next 24h of Apple Calendar meetings. The
clock (time) item lives in the sibling [clock plugin](../clock).

## What it does

- `calendar.date`: a date item. Clicking it toggles a popup listing timed
  meetings starting in the next 24h (header row = today's date; up to
  `max_meetings` rows; a placeholder row when there are none). Its background
  turns orange while a busy (non-free) meeting is in progress, and reverts
  once it ends. Both the popup rows and the busy indicator refresh every
  `date_interval` seconds.
- In the popup, an in-progress meeting shows a solid dot (busy) or hollow dot
  (free); upcoming meetings show a hollow dot. Clicking a meeting row opens
  `calendar_app` - except an in-progress meeting with a detected meeting
  link, which opens that link directly instead.

### Meeting-link detection

Only for the currently-happening occurrence (`occurrence_date <= now <=
occurrence_end_date`). Fields are checked in this order (first match wins):
url, location, notes. Within a field, these providers break ties in order:

1. Google Meet (`meet.google.com`)
2. Microsoft Teams (`teams.microsoft.com` / `teams.live.com`)
3. Zoom (any `zoom.us` subdomain, or `zoommtg:`)
4. FaceTime (`facetime.apple.com/join`, or `facetime:` / `facetime-audio:`)

Upcoming/past events and events with no detected link keep the default
`open -a calendar_app` click.

## Requirements

| Dependency | Notes |
|---|---|
| `jq` | JSON parsing of settings and popup-row payloads |
| `python3` (stdlib only) | Runs `calendar_meetings.py`; needed for CoreData-epoch time formatting and code-point-safe title truncation that plain shell/`date` can't do portably |
| `sqlite3` | On `PATH`; not directly invoked (python's `sqlite3` module is used), but expected to be present on macOS |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |

### Full Disk Access

The meetings popup and the busy indicator read Apple Calendar's SQLite
database directly:

```
~/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb
```

This requires **Full Disk Access** granted to the ridge app (System
Settings > Privacy & Security > Full Disk Access). Without it, the date item
still works normally - the popup instead shows a "Calendar access needed -
grant Full Disk Access" placeholder row and the busy indicator stays off.
`calendar_meetings.py` never crashes on a DB-access failure (missing file,
no permission, locked file); it degrades gracefully every time.

Timestamps in the database are in the CoreData epoch (seconds since
2001-01-01 UTC, offset `978307200` from Unix time), not Unix epoch -
`calendar_meetings.py` converts on both read (querying) and write (labels).

## Install

1. Copy this directory to `~/.config/ridge/plugins/calendar/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/calendar/`).
2. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: calendar
       enabled: true
       region: right          # placement is set here, not in settings
   ```

## Settings

| Key | Default | Description |
|---|---|---|
| `font` | `Iosevka Nerd Font` | Icon font; must be a Nerd Font for the date glyph to render. |
| `date_format` | `%a %d/%m/%Y` | `date`-style format for the date item. |
| `date_interval` | `30` | Seconds between date/busy/popup refreshes. Non-numeric or zero-equivalent falls back to `30`. |
| `label_color` | `theme:primary` | Text color when not busy. |
| `icon_color` | `theme:system` | Date item icon color when not busy. |
| `date_icon` | `󰃭` | Date item glyph. |
| `bg_color` | `theme:background` | Item background when not busy. |
| `busy_bg_color` | `theme:warning` | Date item background while a busy meeting is in progress. |
| `busy_fg_color` | `#12161D` | Date item icon/text color while busy (fixed dark ink for contrast against `busy_bg_color`). |
| `corner_radius` | _(unset)_ | Pill corner radius; unset inherits the bar's global `item_corner_radius`. |
| `bg_height` | _(auto)_ | Pill height; adapts to the bar height unless set. |
| `calendar_app` | `BusyCal` | App opened by clicking a meeting row (`open -a <calendar_app>`). |
| `max_meetings` | `8` | Max meeting rows shown in the popup. |
| `popup_header_color` | `theme:system` | Popup header (today's date) row color. |
| `row_text_color` | `theme:primary` | Meeting row text color. |
| `row_icon_color` | `theme:secondary` | Upcoming (not-in-progress) meeting row dot color. |
| `in_progress_color` | `theme:success` | In-progress meeting row dot color (busy or free). |

## Items it owns

| Id | What |
|---|---|
| `calendar.date` | The date item; click opens the meetings popup. |

## Permissions

Enforced at the socket per `plugin.yaml`'s `owns: calendar.` and
`permissions.ops: [add, set, remove, popup]`. `popup` covers both
`ridge popup toggle` (opening the popup) and `ridge popup set-rows`
(rebuilding its rows) - the wire protocol maps both to the single `popup` op.
