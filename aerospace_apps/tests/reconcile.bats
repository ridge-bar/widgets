#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  source "${PLUGIN_DIR}/aerospace-apps-plugin.sh"
  load_settings
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

# ITEM columns: id, display, monitor, text, color, click.
# BRACKET columns: id, members, bg-color, border-color, border-width.

@test "reconcile inserts a new bubble (icon in center + app font, label, bracket)" {
  SETTING_app_font="TestAppFont"
  printf 'ITEM\taerospace_apps.DELL_U2720Q.1.icon\tDELL U2720Q\tDELL U2720Q\t:ghostty:\t#565F89\taerospace focus --window-id 200\n' >"$TMP/desired"
  printf 'ITEM\taerospace_apps.DELL_U2720Q.1.label\tDELL U2720Q\tDELL U2720Q\tGhostty\t#565F89\taerospace focus --window-id 200\n' >>"$TMP/desired"
  printf 'BRACKET\taerospace_apps.DELL_U2720Q.1\taerospace_apps.DELL_U2720Q.1.icon,aerospace_apps.DELL_U2720Q.1.label\t#292E42\t#292E42\t0\n' >>"$TMP/desired"
  : >"$TMP/current"

  run reconcile "$TMP/desired" "$TMP/current"
  [ "$status" -eq 0 ]
  # icon lands in the configured region (center by default) with the app font + the ligature.
  icon_line="$(echo "$output" | grep '^ridge add aerospace_apps\.DELL_U2720Q\.1\.icon ')"
  [ -n "$icon_line" ]
  echo "$icon_line" | grep -q -- '--region center'
  echo "$icon_line" | grep -q 'ghostty'
  echo "$icon_line" | grep -q -- '--font TestAppFont --font-style Regular --font-size 14'
  # label lands in center too, plain app name, no app-font override.
  label_line="$(echo "$output" | grep '^ridge add aerospace_apps\.DELL_U2720Q\.1\.label ')"
  [ -n "$label_line" ]
  echo "$label_line" | grep -q -- '--region center'
  echo "$label_line" | grep -q 'Ghostty'
  ! echo "$label_line" | grep -q -- '--font TestAppFont'
  # bracket wraps both members.
  echo "$output" | grep -qE '^ridge bracket add aerospace_apps\.DELL_U2720Q\.1 --members aerospace_apps\.DELL_U2720Q\.1\.icon,aerospace_apps\.DELL_U2720Q\.1\.label '
}

@test "reconcile's click focuses the window by id through eval" {
  printf 'ITEM\taerospace_apps.DELL_U2720Q.1.icon\tDELL U2720Q\tDELL U2720Q\t:ghostty:\t#565F89\taerospace focus --window-id 200\n' >"$TMP/desired"
  : >"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  add_line="$(echo "$output" | grep '^ridge add aerospace_apps\.DELL_U2720Q\.1\.icon ')"
  [ -n "$add_line" ]
  ridge() { printf '%s\n' "$@" >"$TMP/argv"; }
  eval "$add_line"
  run cat "$TMP/argv"
  echo "$output" | grep -A1 -- '--click' | tail -1 | grep -qx 'aerospace focus --window-id 200'
}

@test "reconcile borders the focused bracket and clears the others" {
  # Both brackets already exist (members present, bg/border never round-trip);
  # desired focuses bubble .2. Its set carries the border; .1's set clears it.
  printf 'ITEM\taerospace_apps.DELL_U2720Q.1.icon\tDELL\tDELL\t:kitty:\t#565F89\taerospace focus --window-id 100\n' >"$TMP/desired"
  printf 'ITEM\taerospace_apps.DELL_U2720Q.2.icon\tDELL\tDELL\t:ghostty:\t#C0CAF5\taerospace focus --window-id 200\n' >>"$TMP/desired"
  printf 'BRACKET\taerospace_apps.DELL_U2720Q.1\taerospace_apps.DELL_U2720Q.1.icon\t#292E42\t#292E42\t0\n' >>"$TMP/desired"
  printf 'BRACKET\taerospace_apps.DELL_U2720Q.2\taerospace_apps.DELL_U2720Q.2.icon\t#292E42\t#7AA2F7\t2\n' >>"$TMP/desired"
  printf 'ITEM\taerospace_apps.DELL_U2720Q.1.icon\t\t\t:kitty:\t#565F89\t\n' >"$TMP/current"
  printf 'ITEM\taerospace_apps.DELL_U2720Q.2.icon\t\t\t:ghostty:\t#C0CAF5\t\n' >>"$TMP/current"
  printf 'BRACKET\taerospace_apps.DELL_U2720Q.1\taerospace_apps.DELL_U2720Q.1.icon\t\n' >>"$TMP/current"
  printf 'BRACKET\taerospace_apps.DELL_U2720Q.2\taerospace_apps.DELL_U2720Q.2.icon\t\n' >>"$TMP/current"

  run reconcile "$TMP/desired" "$TMP/current"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'ridge bracket add'
  set1="$(echo "$output" | grep -E '^ridge bracket set aerospace_apps\.DELL_U2720Q\.1 ')"
  set2="$(echo "$output" | grep -E '^ridge bracket set aerospace_apps\.DELL_U2720Q\.2 ')"
  # colors are %q-quoted, so '#' arrives as '\#' (optional backslash in the pattern).
  echo "$set1" | grep -qE -- '--border-color \\?#292E42 --border-width 0'
  echo "$set2" | grep -qE -- '--border-color \\?#7AA2F7 --border-width 2'
  # corner_radius is unset by default -> flag omitted from the bracket's set.
  ! (echo "$set2" | grep -q -- '--bg-corner-radius')
}

@test "reconcile passes --bg-corner-radius when corner_radius is explicitly set" {
  local f; f="$(mktemp)"
  printf '%s' '{"corner_radius":"9"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  rm -f "$f"
  printf 'ITEM\taerospace_apps.DELL_U2720Q.1.icon\tDELL\tDELL\t:kitty:\t#565F89\taerospace focus --window-id 100\n' >"$TMP/desired"
  printf 'BRACKET\taerospace_apps.DELL_U2720Q.1\taerospace_apps.DELL_U2720Q.1.icon\t#292E42\t#292E42\t0\n' >>"$TMP/desired"
  : >"$TMP/current"

  run reconcile "$TMP/desired" "$TMP/current"
  [ "$status" -eq 0 ]
  echo "$output" | grep -E '^ridge bracket add aerospace_apps\.DELL_U2720Q\.1 ' | grep -q -- '--bg-corner-radius 9'
}

@test "reconcile passes --bg-height when height is explicitly set" {
  local f; f="$(mktemp)"
  printf '%s' '{"height":"20"}' >"$f"
  RIDGE_PLUGIN_SETTINGS="$f" load_settings
  rm -f "$f"
  printf 'ITEM\taerospace_apps.DELL_U2720Q.1.icon\tDELL\tDELL\t:kitty:\t#565F89\taerospace focus --window-id 100\n' >"$TMP/desired"
  printf 'BRACKET\taerospace_apps.DELL_U2720Q.1\taerospace_apps.DELL_U2720Q.1.icon\t#292E42\t#292E42\t0\n' >>"$TMP/desired"
  : >"$TMP/current"

  run reconcile "$TMP/desired" "$TMP/current"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '--bg-height 20'
}

@test "reconcile removes a closed window's items and bracket" {
  # bubble .2 vanished (its window closed); bubble .1 stays untouched.
  printf 'ITEM\taerospace_apps.DELL_U2720Q.1.icon\tDELL\tDELL\t:kitty:\t#565F89\taerospace focus --window-id 100\n' >"$TMP/desired"
  printf 'ITEM\taerospace_apps.DELL_U2720Q.1.label\tDELL\tDELL\tkitty\t#565F89\taerospace focus --window-id 100\n' >>"$TMP/desired"
  printf 'BRACKET\taerospace_apps.DELL_U2720Q.1\taerospace_apps.DELL_U2720Q.1.icon,aerospace_apps.DELL_U2720Q.1.label\t#292E42\t#292E42\t0\n' >>"$TMP/desired"
  printf 'ITEM\taerospace_apps.DELL_U2720Q.1.icon\t\t\t:kitty:\t#565F89\t\n' >"$TMP/current"
  printf 'ITEM\taerospace_apps.DELL_U2720Q.1.label\t\t\tkitty\t#565F89\t\n' >>"$TMP/current"
  printf 'ITEM\taerospace_apps.DELL_U2720Q.2.icon\t\t\t:ghostty:\t#565F89\t\n' >>"$TMP/current"
  printf 'ITEM\taerospace_apps.DELL_U2720Q.2.label\t\t\tGhostty\t#565F89\t\n' >>"$TMP/current"
  printf 'BRACKET\taerospace_apps.DELL_U2720Q.1\taerospace_apps.DELL_U2720Q.1.icon,aerospace_apps.DELL_U2720Q.1.label\t\n' >>"$TMP/current"
  printf 'BRACKET\taerospace_apps.DELL_U2720Q.2\taerospace_apps.DELL_U2720Q.2.icon,aerospace_apps.DELL_U2720Q.2.label\t\n' >>"$TMP/current"

  run reconcile "$TMP/desired" "$TMP/current"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'ridge remove aerospace_apps.DELL_U2720Q.2.icon'
  echo "$output" | grep -q 'ridge remove aerospace_apps.DELL_U2720Q.2.label'
  echo "$output" | grep -q 'ridge bracket remove aerospace_apps.DELL_U2720Q.2'
  ! echo "$output" | grep -q 'ridge remove aerospace_apps.DELL_U2720Q.1'
}

@test "reconcile applies the app font to the icon and the label font to the label" {
  SETTING_app_font="TestAppFont"
  printf 'ITEM\taerospace_apps.DELL.1.icon\tDELL\tDELL\t:kitty:\t#565F89\taerospace focus --window-id 100\n' >"$TMP/desired"
  printf 'ITEM\taerospace_apps.DELL.1.label\tDELL\tDELL\tkitty\t#565F89\taerospace focus --window-id 100\n' >>"$TMP/desired"
  : >"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  icon_line="$(echo "$output" | grep '^ridge add aerospace_apps\.DELL\.1\.icon ')"
  label_line="$(echo "$output" | grep '^ridge add aerospace_apps\.DELL\.1\.label ')"
  echo "$icon_line" | grep -q -- '--font TestAppFont'
  echo "$label_line" | grep -q -- '--font Iosevka'      # bar font, not the app glyph font
  ! echo "$label_line" | grep -q -- 'TestAppFont'
}

@test "reconcile omits the label font when the font setting is empty (bar default)" {
  SETTING_font=""
  printf 'ITEM\taerospace_apps.DELL.1.label\tDELL\tDELL\tkitty\t#565F89\taerospace focus --window-id 100\n' >"$TMP/desired"
  : >"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  label_line="$(echo "$output" | grep '^ridge add aerospace_apps\.DELL\.1\.label ')"
  ! echo "$label_line" | grep -q -- '--font'
}

@test "reconcile omits app font flags when app_font is empty" {
  SETTING_app_font=""
  printf 'ITEM\taerospace_apps.DELL.1.icon\tDELL\tDELL\t:kitty:\t#565F89\taerospace focus --window-id 100\n' >"$TMP/desired"
  : >"$TMP/current"
  run reconcile "$TMP/desired" "$TMP/current"
  line="$(echo "$output" | grep '^ridge add aerospace_apps\.DELL\.1\.icon ')"
  [ -n "$line" ]
  ! echo "$line" | grep -q -- '--font'
}

@test "a reordered bubble emits move, not a rebuild" {
  printf 'ITEM\taerospace_apps.DELL.1.icon\tDELL\tDELL\t:b:\t#565F89\taerospace focus --window-id 200\n' >"$TMP/desired"
  printf 'ITEM\taerospace_apps.DELL.2.icon\tDELL\tDELL\t:a:\t#565F89\taerospace focus --window-id 100\n' >>"$TMP/desired"
  # current has them in the OTHER order.
  printf 'ITEM\taerospace_apps.DELL.2.icon\t\t\t:a:\t#565F89\t\n' >"$TMP/current"
  printf 'ITEM\taerospace_apps.DELL.1.icon\t\t\t:b:\t#565F89\t\n' >>"$TMP/current"

  run reconcile "$TMP/desired" "$TMP/current"
  echo "$output" | grep -qE '^ridge move aerospace_apps\.DELL\.'
}

# Window pills use POSITIONAL ids (aerospace_apps.<mon>.<index>); the real
# window-id lives only in the --click command. current_state has no click
# column, so an id whose underlying window swapped (close/reopen, reorder)
# would otherwise keep firing its stale --window-id forever. The 3rd
# reconcile arg is a click-map file (id -> click last applied) that lets
# reconcile() see the drift current_state can't.
@test "reconcile re-sets a stale pill's click when the window behind its positional id changes" {
  printf 'ITEM\taerospace_apps.DELL.1.icon\tDELL\tDELL\t\t#565F89\taerospace focus --window-id 200\n' >"$TMP/desired"
  # current: same text/color already applied - only the click is stale.
  printf 'ITEM\taerospace_apps.DELL.1.icon\t\t\t\t#565F89\t\n' >"$TMP/current"
  # click map: this id was last painted pointing at window 100.
  printf 'aerospace_apps.DELL.1.icon\taerospace focus --window-id 100\n' >"$TMP/clickmap"

  run reconcile "$TMP/desired" "$TMP/current" "$TMP/clickmap"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'ridge add'
  ! echo "$output" | grep -q 'ridge remove'
  # No text/color set (those are unchanged) - only the click needs re-setting.
  ! echo "$output" | grep -q -- '--text'
  echo "$output" | grep -qE "ridge set aerospace_apps\.DELL\.1\.icon --click aerospace\\\\ focus\\\\ --window-id\\\\ 200"
}

# Same-app case: two windows of the same app have IDENTICAL text and color, so
# a diff keyed on text/color alone can't see one pill's window-id changing
# while its sibling's holds. Both pills must be checked independently against
# the click map.
@test "reconcile re-sets click on identical-text same-app pills independently when only one window-id changes" {
  printf 'ITEM\taerospace_apps.DELL.1.icon\tDELL\tDELL\t\t#565F89\taerospace focus --window-id 111\n' >"$TMP/desired"
  printf 'ITEM\taerospace_apps.DELL.2.icon\tDELL\tDELL\t\t#565F89\taerospace focus --window-id 200\n' >>"$TMP/desired"
  printf 'ITEM\taerospace_apps.DELL.1.icon\t\t\t\t#565F89\t\n' >"$TMP/current"
  printf 'ITEM\taerospace_apps.DELL.2.icon\t\t\t\t#565F89\t\n' >>"$TMP/current"
  # pill 1's window-id is unchanged (111); pill 2's window swapped from 199 to 200.
  printf 'aerospace_apps.DELL.1.icon\taerospace focus --window-id 111\n' >"$TMP/clickmap"
  printf 'aerospace_apps.DELL.2.icon\taerospace focus --window-id 199\n' >>"$TMP/clickmap"

  run reconcile "$TMP/desired" "$TMP/current" "$TMP/clickmap"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'ridge set aerospace_apps\.DELL\.1\.icon --click'
  echo "$output" | grep -qE "ridge set aerospace_apps\.DELL\.2\.icon --click aerospace\\\\ focus\\\\ --window-id\\\\ 200"
}

@test "reconcile emits no click sets when the strip is unchanged" {
  printf 'ITEM\taerospace_apps.DELL.1.icon\tDELL\tDELL\t\t#565F89\taerospace focus --window-id 100\n' >"$TMP/desired"
  printf 'ITEM\taerospace_apps.DELL.1.icon\t\t\t\t#565F89\t\n' >"$TMP/current"
  printf 'aerospace_apps.DELL.1.icon\taerospace focus --window-id 100\n' >"$TMP/clickmap"

  run reconcile "$TMP/desired" "$TMP/current" "$TMP/clickmap"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q -- '--click'
}

@test "reconcile omits click sets entirely when no click map is provided (cold start, back-compat)" {
  printf 'ITEM\taerospace_apps.DELL.1.icon\tDELL\tDELL\t\t#565F89\taerospace focus --window-id 200\n' >"$TMP/desired"
  printf 'ITEM\taerospace_apps.DELL.1.icon\t\t\t\t#565F89\t\n' >"$TMP/current"

  run reconcile "$TMP/desired" "$TMP/current"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q -- '--click'
}

# Upgrade/restart path: the click map is per-run scratch, so a cold start over
# a live bar (plugin restart, or first run over a store painted by a buggy
# version) has existing items whose applied clicks are unknown - and possibly
# stale. With the map file PROVIDED but empty, every existing item with a
# desired click gets one corrective set.
@test "reconcile re-sets clicks for existing items on a cold start with an empty click map" {
  printf 'ITEM\taerospace_apps.DELL.1.icon\tDELL\tDELL\t\t#565F89\taerospace focus --window-id 200\n' >"$TMP/desired"
  printf 'ITEM\taerospace_apps.DELL.1.icon\t\t\t\t#565F89\t\n' >"$TMP/current"
  : >"$TMP/clickmap"

  run reconcile "$TMP/desired" "$TMP/current" "$TMP/clickmap"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "ridge set aerospace_apps\.DELL\.1\.icon --click aerospace\\\\ focus\\\\ --window-id\\\\ 200"
}

@test "_item_sortkey groups items by monitor, then position, icon before label" {
  [ "$(_item_sortkey "aerospace_apps.DELL.2.icon")" = "$(printf 'DELL\t2\t0\t0')" ]
  [ "$(_item_sortkey "aerospace_apps.DELL.2.label")" = "$(printf 'DELL\t2\t1\t0')" ]
}
