# claude plugin

An icon that tints green while Claude Code is working, plus a details popup
listing active sessions, live subagents, and token usage.

## What it does

- One item (`claude.status`): a static Nerd Font glyph (`󰚩`) whose
  icon/background color reflect whether Claude Code is "working" - any
  running session mid-turn (thinking/streaming/running a tool), or any
  subagent transcript modified in the last minute.
- Clicking the item opens a popup with:
  - A title row.
  - Up to `max_sessions` session rows (project name + how long since the
    transcript last changed; a green dot when that session is mid-turn, an
    orange dot when it's waiting on you).
  - Up to `max_subagents` live-subagent rows (green dot + the first 8
    characters of the subagent's id).
  - Three token rows: `5h` (computed fresh every poll), `24h` and `7d`
    (served from a state-dir cache, refreshed in the background when stale).
- "Working" detection, session listing, and token summation are delegated to
  three vendored Python helpers (`claude_working.py`, `claude_sessions.py`,
  `claude_tokens.py`) that read candidate transcript paths on stdin.

## Requirements

| Dependency | Notes |
|---|---|
| `jq` | JSON parsing of plugin settings and popup row payloads |
| `python3` (stdlib only) | Runs the vendored working/sessions/tokens helpers |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |

## Install

1. Copy this directory to `~/.config/ridge/plugins/claude/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/claude/`).
2. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: claude
       enabled: true
       settings:
         interval: "10"
   ```

## Settings

All optional; override per-key under `plugins[].settings` in `ridge.yaml`.

| Key | Default | Description |
|---|---|---|
| `font` | `Iosevka Nerd Font` | Icon font; must be a Nerd Font for the glyph to render. |
| `interval` | `10` | Seconds between polls. Non-numeric or zero-equivalent falls back to `10`. |
| `projects_dir` | `~/.claude/projects` | Directory of Claude Code transcript files (YAML can't expand `$HOME`, so this is applied at runtime). |
| `process_pattern` | `local/bin/claude` | `pgrep -f` match string for a running Claude Code CLI process. The default matches a typical install path - override for other installs (e.g. an npm-global `claude`). |
| `idle_icon_color` | `theme:warning` | Icon color while idle. |
| `busy_icon_color` | `#12161D` | Icon color while working (fixed dark ink for contrast on the green background). |
| `idle_bg_color` | `theme:background` | Pill background while idle. |
| `busy_bg_color` | `theme:success` | Pill background while working. |
| `corner_radius` | _(unset)_ | Pill corner radius; unset inherits the bar's global `item_corner_radius`. |
| `bg_height` | _(auto)_ | Pill height; adapts to the bar height unless set. |
| `max_sessions` | `5` | Max session rows shown in the popup. |
| `max_subagents` | `4` | Max subagent rows shown in the popup. |
| `cache_stale_seconds` | `300` | How old the 24h/7d token cache may get before a background refresh is kicked off. |

## Items it owns

| Id | What |
|---|---|
| `claude.status` | The glyph item; its popup carries the session/subagent/token rows. |

## Permissions

Enforced at the socket per `plugin.yaml`'s `owns: claude.` and
`permissions.ops: [add, set, remove, popup]`. `popup` covers both
`ridge popup toggle` (opening the details popup) and
`ridge popup set-rows` (rebuilding its rows) - the wire protocol maps both to
the single `popup` op.

## Design notes

- **No lazy popup-row bootstrap.** Ridge's `popup set-rows` attaches and
  replaces the full row set in one call, so this plugin just rebuilds the
  full rows array every poll tick, like `battery.sh`/`weather.sh`.
- **Dynamic row count, no empty placeholder rows.** Ridge rebuilds the whole
  array each tick, so unused slots are simply omitted rather than padded with
  hidden rows (matches `tasks.sh`'s variable section-row approach).
- **Token cache lives under `$XDG_STATE_HOME`.** This plugin follows
  `mindfulness.sh`'s state-dir convention:
  `${XDG_STATE_HOME:-$HOME/.local/state}/ridge/claude/`.
- **Background refresh is lock-guarded.** This plugin adds a `mkdir`-based
  lock directory so at most one refresh runs at a time, since a slow refresh
  could otherwise overlap a second one.
- **`process_pattern` is a setting**, not a hardcoded `local/bin/claude`
  match string, since the match string is specific to each install's
  `claude` binary location.
