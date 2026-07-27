# clockify plugin

Clockify time-tracking status (green=tracking, orange=idle), with a popup for
stopping the current task, opening the desktop app/calendar/reports, and
resuming a recent task. Ported from sketchybar's
`items/clockify.sh` + `plugins/clockify*.sh`.

## What it does

- One item (`clockify.status`): a stopwatch glyph whose pill background is
  `tracking_color` while a timer is running, `idle_color` while idle.
- Left-click toggles: stops the running timer, or starts a blank ("cleared")
  entry if idle.
- Right-click opens a popup: the current task (click to stop), "Open Clockify
  Desktop"/"Open Calendar"/"Open Reports", then up to `max_rows` recent tasks
  (click to resume - reposts the same description/project/task/tags with a
  fresh start time).
- Polls Clockify every `interval` seconds: fetches the 25 most recent time
  entries, parses them via the vendored `clockify_parse.py`, and repaints the
  bar + popup rows.

## Token file

The Clockify API token is read from `token_file` **only** - it is never
written to `ridge.yaml`, any plugin setting, the state-dir cache, or a log
line. It is read into a shell variable in-process for each request and
discarded when that process exits.

The default (`~/.config/sketchybar/.clockify_token`) intentionally matches
the sketchybar config's token file path, so an existing sketchybar setup's
token file keeps working unmodified - no `ridge.yaml` change is needed to
migrate. Point `token_file` elsewhere if you'd rather keep it outside the
sketchybar directory.

### Warn state

If `token_file` is missing, unreadable, or empty (after trimming whitespace),
the item paints `warn_color` (icon and background) and a warning is logged to
stderr once per process run - no repeated logging, and no network calls are
attempted while the token is unavailable. The poll loop keeps running (in
case the file appears later); each tick just skips the network branch until
it does.

## Requirements

| Dependency | Notes |
|---|---|
| `curl` | Talks to the Clockify API (`https://api.clockify.me/api/v1`) |
| `jq` | JSON parsing of settings, API responses, and popup row payloads |
| `python3` (stdlib only) | Runs the vendored `clockify_parse.py` |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |
| A Clockify API token | In the file at `token_file`; get it from Clockify's profile settings |

## Install

1. Copy this directory to `~/.config/ridge/plugins/clockify/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/clockify/`).
2. Ensure your Clockify API token is saved at `~/.config/sketchybar/.clockify_token`
   (or set `token_file` to wherever it lives).
3. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: clockify
       enabled: true
       settings:
         interval: "30"
   ```

## Settings

All optional; override per-key under `plugins[].settings` in `ridge.yaml`.

| Key | Default | Description |
|---|---|---|
| `region` | `right` | Bar region for the item. |
| `font` | `Iosevka Nerd Font` | Icon font; must be a Nerd Font for the glyph to render. |
| `interval` | `30` | Seconds between polls. Non-numeric or zero-equivalent falls back to `30`. |
| `token_file` | `~/.config/sketchybar/.clockify_token` | Path to the Clockify API token file. Never put the token in this setting's value directly - `ridge.yaml` is plain text on disk. |
| `max_rows` | `10` | Max recent-task rows shown in the popup (1-10). |
| `request_timeout` | `8` | `curl --max-time` in seconds for every Clockify API call. |
| `tracking_color` | `theme:success` | Pill background while a timer is running. |
| `idle_color` | `theme:warning` | Pill background while idle. |
| `warn_color` | `theme:secondary` | Icon + pill background while the token file is missing/unreadable/empty. |
| `icon_color` | `#12161D` | Glyph color (fixed dark ink for contrast on any background). |
| `corner_radius` | _(unset)_ | Pill corner radius; unset inherits the bar's global `item_corner_radius`. |
| `bg_height` | _(auto)_ | Pill height; adapts to the bar height unless set. |

## State/cache

Runtime data - never settings, never the token - lives under
`${XDG_STATE_HOME:-$HOME/.local/state}/ridge/clockify/`:

| File | Contents |
|---|---|
| `ids` | Cached `WORKSPACE_ID USER_ID`, fetched once from `$API/user` and reused until a subsequent time-entries fetch fails outright. |
| `entries.json` | The last poll's parsed state (`running`, `currentLabel`, and up to `max_rows` resumable `history` entries), written atomically (tmp file + `mv -f`). |

Delete this directory to force a full re-fetch on the next poll.

## Items it owns

| Id | What |
|---|---|
| `clockify.status` | The glyph item; its popup carries the current-task/open/recent rows. |

## Permissions

Enforced at the socket per `plugin.yaml`'s `owns: clockify.` and
`permissions.ops: [add, set, remove, popup]`. `popup` covers
`ridge popup toggle`, `ridge popup hide`, and `ridge popup set-rows` - the
wire protocol maps all three to the single `popup` op.

## Credit

`clockify_parse.py` is adapted from
`~/.config/sketchybar/plugins/clockify_parse.py`; parsing logic is unchanged.

## Deviations from the sketchybar source

- **No lazy popup-row build step.** The sketchybar source built its ~14
  popup rows on first right-click only, to avoid the per-row WindowServer
  cost of ~100 startup-built rows across the whole config. Ridge's
  `ridge popup set-rows` replaces the whole row list every call and has no
  such per-row window cost, so this plugin rebuilds the full row array on
  every poll instead - simpler, and the popup is always fresh the instant
  it's opened.
- **Ids re-fetch trigger.** The sketchybar source never re-fetches cached
  workspace/user ids at all. This port re-fetches when the cache is missing
  or empty, and also clears the cache (forcing a re-fetch next tick) if a
  time-entries request made with those cached ids fails outright - a
  pragmatic guess at "the cached ids may be stale," since curl's exit status
  doesn't distinguish an auth failure from a network blip.
- **Atomic cache write around a verbatim vendored script.** `clockify_parse.py`
  writes its cache file directly (non-atomically) in the original source.
  This port keeps the script unmodified and instead passes it a temp path,
  then `mv -f`s that into place from `clockify.sh` - the file the poll loop
  and click handlers read is always a complete write, never a torn one.
- **Index lookup via `jq`, not a `python3 -c` heredoc.** The sketchybar
  source's clockify_start.sh looks up `history[<index>]` with an inline
  Python heredoc. This port uses `jq` instead, for consistency with the rest
  of this codebase's jq-based JSON handling; the lookup and POST body shape
  are otherwise identical.
