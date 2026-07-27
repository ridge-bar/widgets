#!/usr/bin/env python3
"""Ridge notifications plugin: counts notifications currently sitting in the
macOS Notification Center list, across every app in the usernoted database.

The signal is the `displayed.list` blob: it holds exactly the notifications
present in the Notification Center list right now. Verified against a live
macOS 26.5.2 db on 2026-07-22 - a notification the user was looking at in NC
appeared in `displayed`, while notifications no longer in NC (delivered but
dismissed, or banner-only Calendar/Photos alerts) were in `delivered` only.
So `delivered` accumulates and is NOT what's on screen; `displayed` is.

Why not `record.presented`: on macOS 26.5.2 `presented` is 0 for every row,
even banners that were shown - it is unusable as a signal. Why not
`delivered`: it retains dismissed/auto-delivered entries, so counting it (or
`delivered - displayed`) tints the clock for notifications the user cannot
see. `displayed` also covers the Focus/DND case: a suppressed notification
still sits silently in NC, so it is in `displayed` and counts correctly.

Blob format: `displayed.list` is NOT a plist - it is a flat concatenation of
16-byte UUIDs (the same byte layout NSUUID uses), one per notification for
that app_id. No plistlib needed.

Recency safety net: the count is restricted to UUIDs with a matching
`record` row whose delivered_date falls within the cutoff passed by the
caller (RIDGE_NOTIF_CUTOFF, Core Data epoch seconds - see notifications.sh's
`_notif_cut`). This drops a UUID stuck in `displayed.list` by a usernoted
desync (crash, schema quirk) with no matching recent `record` row so it
cannot pin the tint forever.

Contract: always print a single integer (the unseen count) on success,
print nothing on any error (missing DB, locked file, schema drift, corrupt
blob) and always exit 0 - the bash poll loop degrades to normal colors on
empty output, exactly like a failed sqlite3 query. stdlib only, no
third-party deps.
"""
import os
import sqlite3
import sys
import time

CORE_DATA_EPOCH = 978307200
DEFAULT_CUTOFF_WINDOW = 259200  # 3 days, seconds - matches notifications.sh's _notif_cut

DEFAULT_DB_PATH = os.path.expanduser(
    "~/Library/Group Containers/group.com.apple.usernoted/db2/db"
)


def _db_path():
    return os.environ.get("RIDGE_NOTIF_DB") or DEFAULT_DB_PATH


def _db_uri(path):
    # No mode=ro: the live -wal must be read too, and mode=ro can't take the
    # WAL read-lock - same reasoning as notifications.sh's _notif_db_uri.
    return f"file:{path}"


def _cutoff():
    raw = os.environ.get("RIDGE_NOTIF_CUTOFF")
    if raw is not None:
        try:
            return float(raw)
        except ValueError:
            pass
    return int(time.time()) - DEFAULT_CUTOFF_WINDOW - CORE_DATA_EPOCH


def _uuid_chunks(blob):
    """Splits a raw UUID-list blob into 16-byte chunks; a trailing partial
    chunk (a corrupt/short blob) is dropped rather than raised."""
    if not blob:
        return []
    whole = len(blob) - (len(blob) % 16)
    return [bytes(blob[i:i + 16]) for i in range(0, whole, 16)]


def _load_uuid_sets(cur, table):
    sets = {}
    cur.execute(f"SELECT app_id, list FROM {table}")
    for app_id, blob in cur.fetchall():
        sets.setdefault(app_id, set()).update(_uuid_chunks(blob))
    return sets


def main():
    path = _db_path()
    # sqlite3.connect() with no mode param CREATES an empty file when the DB
    # is absent but its parent dir exists - would pollute Apple's usernoted
    # container. Check existence first so a missing DB never touches connect().
    if not os.path.exists(path):
        return

    cutoff = _cutoff()
    unseen = set()
    try:
        conn = sqlite3.connect(_db_uri(path), uri=True)
        try:
            conn.execute("PRAGMA query_only=1")
            cur = conn.cursor()
            displayed = _load_uuid_sets(cur, "displayed")
            for app_id, uuids in displayed.items():
                for u in uuids:
                    unseen.add((app_id, u))

            if unseen:
                # Strict >, matching the old bash SQL's cutoff boundary exactly
                # (same 3-day window, not off by the one-second edge).
                cur.execute(
                    "SELECT app_id, uuid FROM record WHERE uuid IS NOT NULL AND delivered_date > ?",
                    (cutoff,),
                )
                recent = {(app_id, bytes(u)) for app_id, u in cur.fetchall()}
                unseen &= recent
        finally:
            conn.close()
    except Exception:
        return

    print(len(unseen))


if __name__ == "__main__":
    main()
