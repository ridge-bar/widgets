#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/aerospace-workspaces-plugin.sh"
  load_settings
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

# ITEM columns: id, display, monitor, text, color, click.
# BRACKET columns: id, members, bg-color, border-color, border-width.

@test "reconcile adds a new workspace's number, glyph, and bracket" {
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  printf 'ITEM\taerospace_ws.1.app.1\tDELL\tDELL\tK\t#565F89\taerospace workspace 1\n' >>"$TMP/desired"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num,aerospace_ws.1.app.1\t#7AA2F7\n' >>"$TMP/desired"
  : >"$TMP/current"

  run reconcile "$TMP/desired" "$TMP/current"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^ridge add aerospace_ws\.1\.num '
  echo "$output" | grep -qE '^ridge add aerospace_ws\.1\.app\.1 '
  echo "$output" | grep -q 'ridge bracket add aerospace_ws.1 --members aerospace_ws.1.num,aerospace_ws.1.app.1 --bg-color'
  # default corner_radius and height are unset -> flags omitted, ridge's global defaults apply.
  ! (echo "$output" | grep -q -- '--bg-corner-radius')
  ! (echo "$output" | grep -q -- '--bg-height')
  echo "$output" | grep -E '^ridge bracket add aerospace_ws\.1 ' | grep -q -- '--margin 6'
  echo "$output" | grep -E '^ridge add aerospace_ws\.1\.num ' | grep -q -- '--padding-left 8 --padding-right 4'
  echo "$output" | grep -E '^ridge add aerospace_ws\.1\.app\.1 ' | grep -q -- '--padding-left 8 --padding-right 8'
}

@test "reconcile passes --bg-corner-radius when corner_radius is explicitly set" {
  local f; f="$(mktemp)"
  printf '%s' '{"corner_radius":"12"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  rm -f "$f"
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num\t#7AA2F7\n' >>"$TMP/desired"
  : >"$TMP/current"

  run reconcile "$TMP/desired" "$TMP/current"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '--bg-corner-radius 12'
}

@test "reconcile passes --bg-height when height is explicitly set" {
  local f; f="$(mktemp)"
  printf '%s' '{"height":"20"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  rm -f "$f"
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num\t#7AA2F7\n' >>"$TMP/desired"
  : >"$TMP/current"

  run reconcile "$TMP/desired" "$TMP/current"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '--bg-height 20'
}

@test "reconcile routes only the first ws item into the aerospace_ws container" {
  # ws ids are monitor-keyed (aerospace_ws.<monSan>.<wsSan>.*); this fixture's
  # ids carry the "DELL" monitor segment so sort/first-item logic (which
  # parses that segment) sees a realistic id.
  printf 'ITEM\taerospace_ws.DELL.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  printf 'ITEM\taerospace_ws.DELL.1.app.1\tDELL\tDELL\tK\t#565F89\taerospace workspace 1\n' >>"$TMP/desired"
  printf 'ITEM\taerospace_ws.DELL.2.num\tDELL\tDELL\t2\t#A9B1D6\taerospace workspace 2\n' >>"$TMP/desired"
  : >"$TMP/current"

  run reconcile "$TMP/desired" "$TMP/current"
  [ "$status" -eq 0 ]
  # The first ws item carries --container aerospace_ws...
  echo "$output" | grep -E '^ridge add aerospace_ws\.DELL\.1\.num ' | grep -q -- '--container aerospace_ws'
  # ...and the following ws items do NOT (they chain via --after).
  ! ( echo "$output" | grep -E '^ridge add aerospace_ws\.DELL\.1\.app\.1 ' | grep -q -- '--container' )
  ! ( echo "$output" | grep -E '^ridge add aerospace_ws\.DELL\.2\.num ' | grep -q -- '--container' )
}

# The ws pill id is keyed by monitor AND workspace, so a workspace that remaps
# to a different monitor produces a DIFFERENT desired id - reconcile's
# generic stale-item removal drops the old (wrong-monitor) pill and the
# generic insert path adds the new one, self-healing --display instead of a
# name-keyed pill silently keeping a stale --display.
@test "reconcile removes a workspace's old-monitor pill and re-adds it under the new monitor's id" {
  # Desired: workspace 1 is now on DELL2.
  printf 'ITEM\taerospace_ws.DELL2.1.num\tDELL2\tDELL2\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  printf 'BRACKET\taerospace_ws.DELL2.1\taerospace_ws.DELL2.1.num\t#292E42\t#292E42\t0\n' >>"$TMP/desired"
  printf 'HL\taerospace_ws.DELL2.1.num\ton\n' >>"$TMP/desired"
  # Current: workspace 1's pill still lives under its OLD monitor, DELL1.
  printf 'ITEM\taerospace_ws.DELL1.1.num\t\t\t1\t#A9B1D6\t\n' >"$TMP/current"
  printf 'BRACKET\taerospace_ws.DELL1.1\taerospace_ws.DELL1.1.num\t\n' >>"$TMP/current"

  run reconcile "$TMP/desired" "$TMP/current"
  [ "$status" -eq 0 ]
  # Old-monitor id removed (item + bracket)...
  echo "$output" | grep -q '^ridge remove aerospace_ws\.DELL1\.1\.num$'
  echo "$output" | grep -q '^ridge bracket remove aerospace_ws\.DELL1\.1$'
  # ...new-monitor id added fresh, --display targeting the new monitor.
  echo "$output" | grep -E '^ridge add aerospace_ws\.DELL2\.1\.num ' | grep -q -- '--display DELL2'
  echo "$output" | grep -q '^ridge bracket add aerospace_ws\.DELL2\.1 '
}

@test "reconcile emits a border-color/border-width on the focused bracket and keeps its bg dark, not blue" {
  # ws1 focused, ws2 unfocused - mirrors the fixture the other bracket tests use.
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  printf 'ITEM\taerospace_ws.2.num\tDELL\tDELL\t2\t#A9B1D6\taerospace workspace 2\n' >>"$TMP/desired"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num\t#292E42\t#7AA2F7\t2\n' >>"$TMP/desired"
  printf 'BRACKET\taerospace_ws.2\taerospace_ws.2.num\t#292E42\t#292E42\t0\n' >>"$TMP/desired"
  : >"$TMP/current"

  run reconcile "$TMP/desired" "$TMP/current"
  [ "$status" -eq 0 ]
  focused_line="$(echo "$output" | grep -E '^ridge bracket add aerospace_ws\.1 ')"
  unfocused_line="$(echo "$output" | grep -E '^ridge bracket add aerospace_ws\.2 ')"
  [ -n "$focused_line" ]
  [ -n "$unfocused_line" ]
  # focused bg stays the dark bg_color, NOT the blue focused color.
  # colors are %q-quoted, so '#' arrives as '\#' (optional backslash in the pattern).
  echo "$focused_line" | grep -qE -- '--bg-color \\?#292E42'
  echo "$focused_line" | grep -qE -- '--border-color \\?#7AA2F7 --border-width 2'
  echo "$unfocused_line" | grep -q -- '--border-width 0'
}

@test "reconcile %q-quotes a shell-special border_focused_color value so eval stays safe" {
  # The border color reaches reconcile via the desired-state bracket line
  # (as bg-color/margin do), so the hostile value is embedded there.
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num\t#292E42\t#7AA2F7; touch %s/pwned #\t2\n' "$TMP" >>"$TMP/desired"
  : >"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  bracket_line="$(echo "$output" | grep '^ridge bracket add aerospace_ws\.1 ')"
  [ -n "$bracket_line" ]

  ridge() { printf '%s\n' "$@" >"$TMP/argv"; }
  eval "$bracket_line"

  # The ';' must never reach eval as a separator, nor the '#' comment out the line.
  [ ! -f "${TMP}/pwned" ]
  run cat "$TMP/argv"
  echo "$output" | grep -A1 -- '--border-color' | tail -1 | grep -qxF "#7AA2F7; touch ${TMP}/pwned #"
}

@test "reconcile inserts a new workspace and removes a stale one without touching a common one" {
  # desired {ws1,ws2}; current {ws2,ws9} - ws1 is new, ws9 is stale, ws2 is
  # common to both (same relative order) so it is left alone (no remove/re-add).
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  printf 'ITEM\taerospace_ws.2.num\tDELL\tDELL\t2\t#A9B1D6\taerospace workspace 2\n' >>"$TMP/desired"
  printf 'ITEM\taerospace_ws.2.num\t\t\t2\t#A9B1D6\t\n' >"$TMP/current"
  printf 'ITEM\taerospace_ws.9.num\t\t\t9\t#A9B1D6\t\n' >>"$TMP/current"

  run reconcile "$TMP/desired" "$TMP/current"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'ridge remove aerospace_ws.9.num'
  ! echo "$output" | grep -q 'ridge remove aerospace_ws.2.num'
  echo "$output" | grep -qE '^ridge add aerospace_ws\.1\.num '
  ! echo "$output" | grep -qE '^ridge add aerospace_ws\.2\.num '
}

@test "reconcile re-adds items in natural workspace order (1,2,10 not 1,10,2)" {
  printf 'ITEM\taerospace_ws.10.num\tDELL\tDELL\t10\t#A9B1D6\taerospace workspace 10\n' >"$TMP/desired"
  printf 'ITEM\taerospace_ws.2.num\tDELL\tDELL\t2\t#A9B1D6\taerospace workspace 2\n' >>"$TMP/desired"
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >>"$TMP/desired"
  : >"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  # Extract only the id being added (not any id mentioned in a trailing anchor).
  order="$(echo "$output" | grep -oE '^ridge add aerospace_ws\.[0-9]+\.num ' | grep -oE 'aerospace_ws\.[0-9]+\.num' | tr '\n' ' ')"
  [ "$order" = "aerospace_ws.1.num aerospace_ws.2.num aerospace_ws.10.num " ]
}

@test "reconcile number-first then glyphs within a workspace when inserting" {
  printf 'ITEM\taerospace_ws.DELL.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  printf 'ITEM\taerospace_ws.DELL.1.app.1\tDELL\tDELL\tK\t#565F89\taerospace workspace 1\n' >>"$TMP/desired"
  printf 'ITEM\taerospace_ws.DELL.1.app.2\tDELL\tDELL\tC\t#565F89\taerospace workspace 1\n' >>"$TMP/desired"
  : >"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  # Extract only the id being added (not any id mentioned in a trailing anchor).
  order="$(echo "$output" | grep -oE '^ridge add aerospace_ws\.DELL\.1\.(num|app\.[0-9]+) ' | grep -oE 'aerospace_ws\.DELL\.1\.(num|app\.[0-9]+)' | tr '\n' ' ')"
  [ "$order" = "aerospace_ws.DELL.1.num aerospace_ws.DELL.1.app.1 aerospace_ws.DELL.1.app.2 " ]
}

@test "reconcile patches color in place on a focus move across workspaces" {
  # Same ids and order in both; focus moves ws1 -> ws2. Only glyph colors and
  # bracket bg-colors change, so it patches in place (no remove/add).
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  printf 'ITEM\taerospace_ws.1.app.1\tDELL\tDELL\tK\t#565F89\taerospace workspace 1\n' >>"$TMP/desired"
  printf 'ITEM\taerospace_ws.2.num\tDELL\tDELL\t2\t#A9B1D6\taerospace workspace 2\n' >>"$TMP/desired"
  printf 'ITEM\taerospace_ws.2.app.1\tDELL\tDELL\tS\t#C0CAF5\taerospace workspace 2\n' >>"$TMP/desired"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num,aerospace_ws.1.app.1\t#292E42\n' >>"$TMP/desired"
  printf 'BRACKET\taerospace_ws.2\taerospace_ws.2.num,aerospace_ws.2.app.1\t#7AA2F7\n' >>"$TMP/desired"
  # current: ws1 was focused (glyph #C0CAF5, bracket #7AA2F7), ws2 not.
  printf 'ITEM\taerospace_ws.1.num\t\t\t1\t#A9B1D6\t\n' >"$TMP/current"
  printf 'ITEM\taerospace_ws.1.app.1\t\t\tK\t#C0CAF5\t\n' >>"$TMP/current"
  printf 'ITEM\taerospace_ws.2.num\t\t\t2\t#A9B1D6\t\n' >>"$TMP/current"
  printf 'ITEM\taerospace_ws.2.app.1\t\t\tS\t#565F89\t\n' >>"$TMP/current"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num,aerospace_ws.1.app.1\t#7AA2F7\n' >>"$TMP/current"
  printf 'BRACKET\taerospace_ws.2\taerospace_ws.2.num,aerospace_ws.2.app.1\t#292E42\n' >>"$TMP/current"

  run reconcile "$TMP/desired" "$TMP/current"
  ! echo "$output" | grep -q 'ridge remove'
  ! echo "$output" | grep -q 'ridge add aerospace_ws'
  # same ids, same order in both - a pure color/focus change must not emit a move.
  ! echo "$output" | grep -qE '^ridge move '
  # colors/bg are %q-quoted, so '#' arrives as '\#' (optional backslash in the pattern).
  echo "$output" | grep -qE 'ridge set aerospace_ws\.1\.app\.1 --text K --color \\?#565F89'
  echo "$output" | grep -qE 'ridge set aerospace_ws\.2\.app\.1 --text S --color \\?#C0CAF5'
  # the set path re-applies padding too (not just add), so a glyph_pad change lands
  # without a manual re-add.
  echo "$output" | grep -E '^ridge set aerospace_ws\.1\.app\.1 ' | grep -q -- '--padding-left 8 --padding-right 8'
  echo "$output" | grep -qE 'ridge bracket set aerospace_ws\.1 --members aerospace_ws\.1\.num,aerospace_ws\.1\.app\.1 --bg-color \\?#292E42'
  echo "$output" | grep -qE 'ridge bracket set aerospace_ws\.2 --members aerospace_ws\.2\.num,aerospace_ws\.2\.app\.1 --bg-color \\?#7AA2F7'
}

@test "reconcile leaves an unchanged bubble alone" {
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num\t#7AA2F7\n' >>"$TMP/desired"
  printf 'ITEM\taerospace_ws.1.num\t\t\t1\t#A9B1D6\t\n' >"$TMP/current"
  # current_state() cannot read bracket bg-color back (ridge query brackets has
  # no bg-color column), so the current bg field is always empty in practice.
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num\t\n' >>"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  ! echo "$output" | grep -q 'ridge add'
  ! echo "$output" | grep -q 'ridge set aerospace_ws.1'
  ! echo "$output" | grep -q 'ridge remove'
  # The bracket bg can never round-trip through current_state, so reconcile
  # can't tell the bg is unchanged and re-emits the set every time. ItemStore's
  # replaceBracket guard (unchanged-value no-op) is what makes this cheap.
  echo "$output" | grep -qE 'ridge bracket set aerospace_ws\.1 --members aerospace_ws\.1\.num --bg-color \\?#7AA2F7'
}

@test "reconcile's bracket set line for an already-existing bracket carries border-color/border-width on a focus change" {
  # Both brackets already exist in current (id present in c_bmem), so this must
  # emit `bracket set`, not `bracket add` - the add path is covered elsewhere.
  # Focus moves ws1 -> ws2; desired border-color/border-width flip accordingly.
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  printf 'ITEM\taerospace_ws.2.num\tDELL\tDELL\t2\t#A9B1D6\taerospace workspace 2\n' >>"$TMP/desired"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num\t#292E42\t#292E42\t0\n' >>"$TMP/desired"
  printf 'BRACKET\taerospace_ws.2\taerospace_ws.2.num\t#292E42\t#7AA2F7\t2\n' >>"$TMP/desired"
  # current_state() never round-trips bg/border (query brackets has neither
  # column), so the current bracket lines carry only id + members, as they
  # would in production.
  printf 'ITEM\taerospace_ws.1.num\t\t\t1\t#A9B1D6\t\n' >"$TMP/current"
  printf 'ITEM\taerospace_ws.2.num\t\t\t2\t#A9B1D6\t\n' >>"$TMP/current"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num\t\n' >>"$TMP/current"
  printf 'BRACKET\taerospace_ws.2\taerospace_ws.2.num\t\n' >>"$TMP/current"

  run reconcile "$TMP/desired" "$TMP/current"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'ridge bracket add'
  set1_line="$(echo "$output" | grep -E '^ridge bracket set aerospace_ws\.1 ')"
  set2_line="$(echo "$output" | grep -E '^ridge bracket set aerospace_ws\.2 ')"
  [ -n "$set1_line" ]
  [ -n "$set2_line" ]
  # colors are %q-quoted, so '#' arrives as '\#' (optional backslash in the pattern).
  echo "$set1_line" | grep -qE -- '--border-color \\?#292E42 --border-width 0'
  echo "$set2_line" | grep -qE -- '--border-color \\?#7AA2F7 --border-width 2'
}

@test "reconcile removes a vanished workspace's items and bracket" {
  # ws2 vanished; ws1 stays untouched (common, unchanged, no move) - only ws2's
  # items and bracket are removed as stale.
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num\t#7AA2F7\n' >>"$TMP/desired"
  printf 'ITEM\taerospace_ws.1.num\t\t\t1\t#A9B1D6\t\n' >"$TMP/current"
  printf 'ITEM\taerospace_ws.2.num\t\t\t2\t#A9B1D6\t\n' >>"$TMP/current"
  printf 'ITEM\taerospace_ws.2.app.1\t\t\tS\t#565F89\t\n' >>"$TMP/current"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num\t#7AA2F7\n' >>"$TMP/current"
  printf 'BRACKET\taerospace_ws.2\taerospace_ws.2.num,aerospace_ws.2.app.1\t#292E42\n' >>"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  echo "$output" | grep -q 'ridge remove aerospace_ws.2.num'
  echo "$output" | grep -q 'ridge remove aerospace_ws.2.app.1'
  echo "$output" | grep -q 'ridge bracket remove aerospace_ws.2'
  # ws2 must NOT be re-added.
  ! echo "$output" | grep -qE '^ridge add aerospace_ws\.2'
}

@test "reconcile removes a closed window's glyph item" {
  # ws1 lost its 2nd window; membership shrinks -> app.2 removed, not re-added.
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  printf 'ITEM\taerospace_ws.1.app.1\tDELL\tDELL\tK\t#565F89\taerospace workspace 1\n' >>"$TMP/desired"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num,aerospace_ws.1.app.1\t#7AA2F7\n' >>"$TMP/desired"
  printf 'ITEM\taerospace_ws.1.num\t\t\t1\t#A9B1D6\t\n' >"$TMP/current"
  printf 'ITEM\taerospace_ws.1.app.1\t\t\tK\t#565F89\t\n' >>"$TMP/current"
  printf 'ITEM\taerospace_ws.1.app.2\t\t\tC\t#565F89\t\n' >>"$TMP/current"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num,aerospace_ws.1.app.1,aerospace_ws.1.app.2\t#7AA2F7\n' >>"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  echo "$output" | grep -q 'ridge remove aerospace_ws.1.app.2'
  ! echo "$output" | grep -qE '^ridge add aerospace_ws\.1\.app\.2'
}

@test "reconcile's emitted add line survives eval without dropping color or click" {
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  : >"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  add_line="$(echo "$output" | grep '^ridge add aerospace_ws\.1\.num ')"
  [ -n "$add_line" ]

  # Stub `ridge` so eval-ing the emitted line records the argv it would receive,
  # one arg per line, the way run_reconcile calls it.
  ridge() { printf '%s\n' "$@" >"$TMP/argv"; }
  eval "$add_line"

  run cat "$TMP/argv"
  # A leading '#' color must not be swallowed as a comment.
  echo "$output" | grep -A1 -- '--color' | tail -1 | grep -qx '#A9B1D6'
  echo "$output" | grep -A1 -- '--click' | tail -1 | grep -qx 'aerospace workspace 1'
}

@test "reconcile's emitted add line %q-quotes a shell-special region setting" {
  SETTING_region="left;touch ${TMP}/pwned #"
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  : >"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  add_line="$(echo "$output" | grep '^ridge add aerospace_ws\.1\.num ')"
  [ -n "$add_line" ]

  ridge() { printf '%s\n' "$@" >"$TMP/argv"; }
  eval "$add_line"

  # The ';' must never reach eval as a separator, nor the '#' comment out the line.
  [ ! -f "${TMP}/pwned" ]
  run cat "$TMP/argv"
  echo "$output" | grep -A1 -- '--region' | tail -1 | grep -qxF "left;touch ${TMP}/pwned #"
}

@test "reconcile %q-quotes a shell-special padding setting so eval stays safe" {
  SETTING_num_pad_left="8;touch ${TMP}/pwned #"
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  : >"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  add_line="$(echo "$output" | grep '^ridge add aerospace_ws\.1\.num ')"
  [ -n "$add_line" ]

  ridge() { printf '%s\n' "$@" >"$TMP/argv"; }
  eval "$add_line"

  # The ';' must never reach eval as a separator, nor the '#' comment out the line.
  [ ! -f "${TMP}/pwned" ]
  run cat "$TMP/argv"
  echo "$output" | grep -A1 -- '--padding-left' | tail -1 | grep -qxF "8;touch ${TMP}/pwned #"
}

@test "reconcile %q-quotes a shell-special bubble_margin setting so eval stays safe" {
  SETTING_bubble_margin="6; touch ${TMP}/pwned #"
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num\t#7AA2F7\n' >>"$TMP/desired"
  : >"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  bracket_line="$(echo "$output" | grep '^ridge bracket add aerospace_ws\.1 ')"
  [ -n "$bracket_line" ]

  ridge() { printf '%s\n' "$@" >"$TMP/argv"; }
  eval "$bracket_line"

  # The ';' must never reach eval as a separator, nor the '#' comment out the line.
  [ ! -f "${TMP}/pwned" ]
  run cat "$TMP/argv"
  echo "$output" | grep -A1 -- '--margin' | tail -1 | grep -qxF "6; touch ${TMP}/pwned #"
}

@test "reconcile's click for a hostile workspace name is safe through both the plugin eval and ridge's sh -c layers" {
  # desired_state bakes the click with the ws name single-quoted (shq); here we
  # feed that baked click and check reconcile's outer %q plus the sh -c layer.
  local ws="w; touch ${TMP}/pwned x"
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace %s\n' "'${ws}'" >"$TMP/desired"
  : >"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  add_line="$(echo "$output" | grep '^ridge add aerospace_ws\.1\.num ')"
  [ -n "$add_line" ]

  # Layer 1 (plugin eval): stub `ridge`, record the exact --click string stored.
  ridge() { for a in "$@"; do printf '%s\n' "$a"; done >"$TMP/argv"; }
  eval "$add_line"
  run cat "$TMP/argv"
  click_value="$(echo "$output" | grep -A1 -- '^--click$' | tail -1)"
  [ -n "$click_value" ]

  # Layer 2 (ridge core): the stored click runs via `/bin/sh -c "<click>"`.
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/aerospace" <<'EOF'
#!/bin/sh
for a in "$@"; do printf 'ARG:%s\n' "$a"; done
EOF
  chmod +x "$TMP/bin/aerospace"
  PATH="$TMP/bin:$PATH" sh -c "$click_value" >"$TMP/aerospace_argv"

  [ ! -f "${TMP}/pwned" ]
  run cat "$TMP/aerospace_argv"
  [ "${lines[0]}" = "ARG:workspace" ]
  [ "${lines[1]}" = "ARG:${ws}" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "a new middle workspace inserts in place without a whole-strip rebuild" {
  # current: ws1, ws2. desired: ws1, ws2, ws3 (sorts between ws2 and ws10-less set).
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\tws1\n'  >"$TMP/desired"
  printf 'ITEM\taerospace_ws.2.num\tDELL\tDELL\t2\t#A9B1D6\tws2\n' >>"$TMP/desired"
  printf 'ITEM\taerospace_ws.3.num\tDELL\tDELL\t3\t#A9B1D6\tws3\n' >>"$TMP/desired"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num\t#292E42\t#292E42\t0\n' >>"$TMP/desired"
  printf 'BRACKET\taerospace_ws.2\taerospace_ws.2.num\t#292E42\t#292E42\t0\n' >>"$TMP/desired"
  printf 'BRACKET\taerospace_ws.3\taerospace_ws.3.num\t#292E42\t#292E42\t0\n' >>"$TMP/desired"
  printf 'ITEM\taerospace_ws.1.num\t\t\t1\t#A9B1D6\t\n'  >"$TMP/current"
  printf 'ITEM\taerospace_ws.2.num\t\t\t2\t#A9B1D6\t\n' >>"$TMP/current"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num\t\n' >>"$TMP/current"
  printf 'BRACKET\taerospace_ws.2\taerospace_ws.2.num\t\n' >>"$TMP/current"

  run reconcile "$TMP/desired" "$TMP/current"
  # ws3 inserted at its position (after ws2's item, or before whatever follows)
  echo "$output" | grep -E '^ridge add aerospace_ws\.3\.num ' | grep -qE -- '--(after|before) aerospace_ws\.'
  # NO whole-strip rebuild: existing ws1/ws2 items are NOT removed
  ! echo "$output" | grep -q 'ridge remove aerospace_ws.1.num'
  ! echo "$output" | grep -q 'ridge remove aerospace_ws.2.num'
}

@test "a reordered glyph within a bubble emits move, not a rebuild" {
  # current order app.1 then app.2; desired swaps them.
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\tws1\n'   >"$TMP/desired"
  printf 'ITEM\taerospace_ws.1.app.1\tDELL\tDELL\tB\t#565F89\tws1\n' >>"$TMP/desired"
  printf 'ITEM\taerospace_ws.1.app.2\tDELL\tDELL\tA\t#565F89\tws1\n' >>"$TMP/desired"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num,aerospace_ws.1.app.2,aerospace_ws.1.app.1\t#292E42\t#292E42\t0\n' >>"$TMP/desired"
  # current has them in the OTHER order (c_seq drives order): num, app.2, app.1
  printf 'ITEM\taerospace_ws.1.num\t\t\t1\t#A9B1D6\t\n'   >"$TMP/current"
  printf 'ITEM\taerospace_ws.1.app.2\t\t\tA\t#565F89\t\n' >>"$TMP/current"
  printf 'ITEM\taerospace_ws.1.app.1\t\t\tB\t#565F89\t\n' >>"$TMP/current"
  printf 'BRACKET\taerospace_ws.1\taerospace_ws.1.num,aerospace_ws.1.app.2,aerospace_ws.1.app.1\t\n' >>"$TMP/current"

  run reconcile "$TMP/desired" "$TMP/current"
  echo "$output" | grep -qE '^ridge move aerospace_ws\.1\.app\.'
  ! echo "$output" | grep -qE '^ridge remove aerospace_ws\.1\.num'
}

@test "reconcile passes --font on add when the font setting is set" {
  SETTING_font="Hack Nerd Font"; SETTING_font_size="14"
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  : >"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  echo "$output" | grep -q -- "--font"
  echo "$output" | grep -q -- "--font-size 14"
  line="$(echo "$output" | grep '^ridge add aerospace_ws.1.num')"
  ridge() { local p=""; for a in "$@"; do [ "$p" = "--font" ] && printf 'FONT:%s\n' "$a"; p="$a"; done; }
  eval "$line" | grep -q '^FONT:Hack Nerd Font$'
}

@test "reconcile omits --font on add when the font setting is empty" {
  SETTING_font=""; SETTING_font_size=""
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  : >"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  ! echo "$output" | grep -q -- "--font"
}

@test "reconcile passes the app font (family/style/size) on add for an app-glyph item" {
  SETTING_app_font="TestAppFont"
  printf 'ITEM\taerospace_ws.1.app.1\tDELL\tDELL\t:kitty:\t#565F89\taerospace workspace 1\n' >"$TMP/desired"
  : >"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  line="$(echo "$output" | grep '^ridge add aerospace_ws\.1\.app\.1 ')"
  [ -n "$line" ]
  echo "$line" | grep -q -- '--font TestAppFont --font-style Regular --font-size 14'
}

@test "reconcile omits app font flags for an app-glyph item when app_font is empty" {
  SETTING_app_font=""
  printf 'ITEM\taerospace_ws.1.app.1\tDELL\tDELL\t:kitty:\t#565F89\taerospace workspace 1\n' >"$TMP/desired"
  : >"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  line="$(echo "$output" | grep '^ridge add aerospace_ws\.1\.app\.1 ')"
  [ -n "$line" ]
  ! echo "$line" | grep -q -- '--font'
}

@test "reconcile does not apply the app font to the number item" {
  SETTING_app_font="TestAppFont"
  printf 'ITEM\taerospace_ws.1.num\tDELL\tDELL\t1\t#A9B1D6\taerospace workspace 1\n' >"$TMP/desired"
  : >"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  line="$(echo "$output" | grep '^ridge add aerospace_ws\.1\.num ')"
  [ -n "$line" ]
  ! echo "$line" | grep -q -- 'TestAppFont'
}

# _item_sortkey now parses the monitor segment out of a ws id
# (aerospace_ws.<monSan>.<wsSan>.*) and groups by monitor first, then
# workspace-natural - direct coverage of the parsing itself, independent of
# the full reconcile() diff exercised above.
@test "_item_sortkey groups ws items by monitor, then workspace-natural, number before glyphs" {
  [ "$(_item_sortkey "aerospace_ws.DELL.2.num")" = "$(printf 'DELL\t2\t0\t0')" ]
  [ "$(_item_sortkey "aerospace_ws.DELL.10.app.3")" = "$(printf 'DELL\t10\t1\t3')" ]
  [ "$(_item_sortkey "aerospace_ws.Built-in.1.num")" = "$(printf 'Built-in\t1\t0\t0')" ]
}

@test "reconcile sorts ws pills by monitor group, then workspace-natural, across monitors" {
  printf 'ITEM\taerospace_ws.DELL.2.num\tDELL\tDELL\t2\t#A9B1D6\taerospace workspace 2\n' >"$TMP/desired"
  printf 'ITEM\taerospace_ws.Built-in.1.num\tBuilt-in\tBuilt-in\t1\t#A9B1D6\taerospace workspace 1\n' >>"$TMP/desired"
  printf 'ITEM\taerospace_ws.DELL.10.num\tDELL\tDELL\t10\t#A9B1D6\taerospace workspace 10\n' >>"$TMP/desired"
  : >"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  order="$(echo "$output" | grep -oE '^ridge add aerospace_ws\.[A-Za-z-]+\.[0-9]+\.num ' | grep -oE 'aerospace_ws\.[A-Za-z-]+\.[0-9]+\.num' | tr '\n' ' ')"
  # "Built-in" < "DELL" alphabetically, so Built-in's ws1 group comes first;
  # within DELL, ws2 sorts before ws10 (natural, not lexical).
  [ "$order" = "aerospace_ws.Built-in.1.num aerospace_ws.DELL.2.num aerospace_ws.DELL.10.num " ]
}
