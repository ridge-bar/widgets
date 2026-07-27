# Ridge widgets

Widgets for [Ridge](https://github.com/ridge-bar), a macOS menu bar. Every widget here is open
source and free.

A widget is a self-contained directory: a `plugin.yaml` manifest, an executable (usually bash), and
its own tests. Ridge runs it as a long-lived process that talks to the bar over a local socket.
Nothing here depends on anything else in this repo - a widget is a directory you can copy anywhere.

## Layout

```
battery/            one directory per widget
  plugin.yaml       manifest: name, version, settings, permissions
  battery.sh        the executable
  README.md         what it does, its settings, its dependencies
  tests/            bats tests
catalog.json        the store index
```

## Installing

Widgets install from Ridge's Settings > Widgets > Store pane, which reads `catalog.json` over
https. No backend and no accounts are involved.

**The catalog is not installable yet.** Its entries carry placeholder checksums pending a release
pipeline that publishes one versioned tarball per widget. Until that lands, copy a widget directory
into `~/.config/ridge/plugins/` by hand.

## Catalog format

```json
{
  "version": 1,
  "entries": [
    {
      "id": "battery",
      "name": "Battery",
      "description": "One sentence, plain text.",
      "version": "0.1.0",
      "download_url": "https://.../battery-0.1.0.tar.gz",
      "screenshot_url": "https://.../battery.png",
      "category": "system",
      "sha256": "..."
    }
  ]
}
```

| Field | Required | Notes |
|---|---|---|
| `id` | yes | Matches the widget's `plugin.yaml` `name` and its directory name exactly. |
| `name` | yes | Display name in the Store pane. |
| `description` | yes | One sentence. |
| `version` | yes | Matches the widget's `plugin.yaml` `version`. |
| `download_url` | yes | A `.tar.gz` containing `plugin.yaml` at its root. https only. |
| `screenshot_url` | no | Preview image. |
| `category` | yes | Grouping label shown as a pill in the Store pane. |
| `sha256` | yes | 64-character hex digest of the artifact. Verified before extraction; any mismatch aborts the install. |

Both the catalog fetch and the artifact download reject plain HTTP and any redirect to a non-https
URL.

## Placement

Where a widget's items sit on the bar is the host's decision, not the widget's. A widget ships a
sensible default and passes it as `--region` on `ridge add`, but `ridge.yaml` overrides it:

```yaml
plugins:
  - name: aerospace_workspaces
    enabled: true
    region: left
    items:
      aerospace_ws.status: right   # per-item, for widgets whose items differ
```

Do not add a `region` setting to a widget. It would appear in the Settings UI as a control the host
config silently overrides.

## Versioning

Each widget carries its own version in its `plugin.yaml` and is released independently, so fixing
one widget never churns the others.

| Bump | When |
|---|---|
| patch | Bug fix. No settings change. |
| minor | New settings key with a default. Existing configs keep working. |
| major | A settings key removed or renamed, or the widget's item ids changed. |

A major bump breaks existing user configuration - the `owns:` prefix in `plugin.yaml` determines the
item ids a user references in their own `ridge.yaml`.

## Contributing

Add or update a widget by pull request. A widget needs:

- `plugin.yaml` whose `name` matches its directory
- an executable that exits cleanly on `SIGTERM`
- a `README.md` documenting its settings and any external dependencies
- `tests/` covering settings parsing and any pure helper functions
- a `catalog.json` entry, if it should appear in the Store

Run a widget's tests with `bats <widget>/tests`.

Widgets may depend on external tools, but must say so in their README and must not fail silently
when one is missing. Prefer degrading visibly over doing nothing.

## License

MIT - see [LICENSE](LICENSE). Contributions are accepted under the same terms.
