# tasks plugin

Open-todo count badge from three sources - Things3's "Today" list, NotePlan's
today calendar note, and an Obsidian inbox folder - plus a per-source popup.
Ported from sketchybar's `items/tasks.sh` + `plugins/tasks.sh` +
`plugins/tasks_rows.sh` + `plugins/tasks_popup.sh`.

## What it does

- One item (`tasks.status`): a count badge summing open items across all
  enabled sources. `icon_color` when the total is greater than 0,
  `empty_color` when it's 0.
- Each source is independently toggle-able (`things_enabled`,
  `noteplan_enabled`, `obsidian_enabled`) - a disabled source contributes 0
  to the count and shows no popup section.
- Clicking the item opens a popup with up to 3 sections (Things, NotePlan,
  Inbox), up to `max_rows` rows each. Clicking a row opens the item in its
  source app via a URI scheme (`things:///show?id=...`,
  `noteplan://x-callback-url/openNote?noteDate=...`,
  `obsidian://open?vault=...&file=...`). When every enabled source is empty,
  the popup shows a single "All clear" row.
- Two-phase render each poll: paint the bar/popup from the on-disk cache
  first (cheap - file reads only), then refresh the caches from the live
  sources (AppleScript/file scans), then paint again with fresh data. A
  completed task elsewhere can lag behind by up to one poll `interval`
  before the badge/popup catch up.

## Requirements

| Dependency | Notes |
|---|---|
| `jq` | JSON parsing of settings and building popup-row JSON |
| `osascript` | Queries Things3's "Today" list via AppleScript, wrapped in a 5s timeout |
| `perl` | Backs the `timeout`-shim used to bound the AppleScript call (macOS ships no `timeout` binary) |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |

### Permissions per source

| Source | Requirement |
|---|---|
| Things3 | Automation/AppleScript access granted to whatever process runs `ridge` - System Settings > Privacy & Security > Automation. Only queried when Things3.app is running; a denied/missing grant just yields 0 items from that source. |
| NotePlan | No special permission - the configured `noteplan_dir` just needs to exist and be readable. |
| Obsidian | No special permission - the configured `obsidian_inbox_dir` just needs to exist and be readable. |

## Install

1. Copy this directory to `~/.config/ridge/plugins/tasks/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/tasks/`).
2. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: tasks
       enabled: true
       settings:
         obsidian_vault: "MyVault"
         obsidian_inbox_rel: "MyVault/00-INBOX"
   ```

## Settings

All optional; override per-key under `plugins[].settings` in `ridge.yaml`.

| Key | Default | Description |
|---|---|---|
| `region` | `right` | Bar region for the item. |
| `font` | `Iosevka Nerd Font` | Icon font; must be a Nerd Font for the glyph to render. |
| `interval` | `60` | Seconds between polls. Non-numeric or zero-equivalent falls back to `60`. |
| `things_enabled` | `true` | Query Things3's "Today" list. |
| `noteplan_enabled` | `true` | Scan NotePlan's today calendar note. |
| `noteplan_dir` | (unset) | Folder holding NotePlan's daily calendar notes. Empty/unset falls back to `~/Library/Containers/co.noteplan.NotePlan-setapp/Data/Library/Application Support/co.noteplan.NotePlan-setapp/Calendar`. |
| `obsidian_enabled` | `true` | Scan the Obsidian inbox folder. |
| `obsidian_inbox_dir` | (unset) | Folder scanned for `.md` notes. Empty/unset falls back to `~/Notes/Notes/00-INBOX`. |
| `obsidian_vault` | `Notes` | Obsidian vault name, used in the `obsidian://` click URI. |
| `obsidian_inbox_rel` | `Notes/00-INBOX` | Inbox folder path relative to the vault root, used in the `obsidian://` click URI. |
| `max_rows` | `8` | Max popup rows per section. Out-of-range (not 1-20) or non-numeric falls back to `8`. |
| `icon_color` | `theme:primary` | Item color when the total open-task count is greater than 0. |
| `empty_color` | `theme:secondary` | Item color when the total is 0. |
| `bg_color` | `theme:background` | Pill background color (sketchybar-style bubble, matching aerospace). |
| `corner_radius` | _(unset)_ | Pill corner radius; unset inherits the bar's global `item_corner_radius`. |
| `bg_height` | _(auto)_ | Pill height; adapts to the bar height unless set. |

`noteplan_dir`/`obsidian_inbox_dir` default to a path under `$HOME`, which
YAML cannot expand as a literal string - so `plugin.yaml` ships them unset and
the script resolves the `$HOME`-based default at runtime instead.

## Items it owns

| Id | What |
|---|---|
| `tasks.status` | The count-badge item; its popup carries the per-source rows. |

## Permissions (wire protocol)

Enforced at the socket per `plugin.yaml`'s `owns: tasks.` and
`permissions.ops: [add, set, remove, popup]`. `popup` covers both
`ridge popup toggle` (opening the popup) and `ridge popup set-rows`
(rebuilding its rows) - the wire protocol maps both to the single `popup` op.

### Known limitation: popup requires a static `ridge.yaml` item stub

`ridge popup toggle`/`ridge popup set-rows` only work on an item whose
`.popup` was declared in `ridge.yaml`'s top-level `items:` block - a plugin's
own `ridge add` call can never attach a popup (this is a ridge-core
limitation shared by every popup-owning plugin: battery, weather,
mindfulness, tasks). Until ridge core gains a way to create a popup at
runtime, `tasks.status`'s popup calls fail with `unknown item id or no
popup` unless you declare a matching stub yourself:

```yaml
items:
  - id: tasks.status
    region: right
    popup: {}
```
