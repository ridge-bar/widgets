# notifications plugin

Colorizes the clock item's background while macOS Notification Center
has unread notifications, and restores it when they're cleared. The plugin
owns no items: it re-styles the clock plugin's `clock.time` item
through an explicit `permissions.styles` grant in its manifest (style-only
`set`, enforced at the socket).

## What it does

- Every poll, runs `notifications_unseen.py` against
  `~/Library/Group Containers/group.com.apple.usernoted/db2/db` (the same
  sqlite database Notification Center itself writes to) and counts the
  notifications currently in the Notification Center list, per app - the
  `displayed` blob, which holds exactly what's on screen now.
- Not `delivered` (which retains dismissed and banner-only Calendar/Photos
  alerts, so it would tint for notifications the user cannot see) and not
  `record.presented` (0 for every row on macOS 26.5.2, so unusable).
  `displayed` also covers Focus/DND: a suppressed notification still sits
  in NC, so it counts.
- A recency safety net still applies: only UUIDs with a matching `record`
  row delivered in the last 3 days count, so a desynced/stale row can never
  pin the tint forever.
- Count greater than zero: sets the target item's background to
  `tint_bg_color` and its label to `tint_label_color`.
- Zero (or a query error): restores `normal_bg_color`/`normal_label_color`.
- Only touches the wire on a state change, and restores the normal colors
  on shutdown (TERM/INT).

## Requirements

| Dependency | Notes |
|---|---|
| `python3` | stdlib only; runs `notifications_unseen.py` against the Notification Center database |
| `jq` | JSON parsing of plugin settings |
| `ridge` CLI | On `PATH`; used to reach the running bar over `$RIDGE_SOCKET` |

The target item must exist - by default the [clock plugin](../clock)'s
`clock.time` clock, so enable that plugin too.

### Full Disk Access

This plugin reads a protected database under `~/Library/Group Containers/`,
which requires **Full Disk Access** to be granted (System Settings > Privacy
& Security > Full Disk Access) to whatever process runs `ridge`/this plugin.

Without Full Disk Access, the query fails and the clock keeps its **normal
colors** - no crash, no retry spin, never stuck tinted. A warning is logged
to stderr once per process lifetime. This is intentional graceful
degradation, not a bug.

## Install

1. Copy this directory to `~/.config/ridge/plugins/notifications/` (or
   `$XDG_CONFIG_HOME/ridge/plugins/notifications/`).
2. Grant Full Disk Access as described above.
3. Add to your `ridge.yaml`:

   ```yaml
   plugins:
     - name: notifications
       enabled: true
       settings:
         interval: "10"
   ```

## Settings

All optional; override per-key under `plugins[].settings` in `ridge.yaml`.

| Key | Default | Description |
|---|---|---|
| `interval` | `10` | Seconds between polls. Non-numeric or zero falls back to `10`. |
| `target_item` | `clock.time` | Item id to tint. Changing it also requires editing `plugin.yaml`'s `permissions.styles` list - the grant is deliberately manifest-only. |
| `tint_bg_color` | `theme:warning` | Background color while notifications are pending. |
| `tint_label_color` | `#12161D` | Label color while notifications are pending (fixed dark ink for contrast on the tint bg). |
| `normal_bg_color` | `theme:background` | Background color restored when cleared. |
| `normal_label_color` | `theme:primary` | Label color restored when cleared. |

`plugin.yaml`'s `settings_schema` maps each key above to a typed control
(slider or color picker) in the GUI Settings window's Plugins pane -
cosmetic only, the plugin script still reads plain strings.

## Items it owns

None. The `owns: notifications.` prefix is reserved but currently unused;
the plugin only re-styles `clock.time` via its styles grant.

## Permissions

Enforced at the socket per `plugin.yaml`: `permissions.ops: [set]` plus
`permissions.styles: [clock.time]` - a style-only escape hatch from the
`owns` prefix. The socket rejects any `set` on `clock.time` carrying a
non-style field (text, click, visible, ...) and every other op on it.
