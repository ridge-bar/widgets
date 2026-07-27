#!/usr/bin/env bash
# Ridge tasks plugin: open-todo count badge from three sources - Things3
# "Today" list, NotePlan's today calendar note, and an Obsidian inbox folder -
# plus a per-source popup. Ported from sketchybar's
# items/tasks.sh + plugins/tasks.sh + plugins/tasks_rows.sh + plugins/tasks_popup.sh
# (see README.md). Talks to ridge over $RIDGE_SOCKET via the `ridge` CLI.
set -uo pipefail

ITEM_ID="tasks.status"
# Nerd Font "tasks" glyph (Font Awesome fa-tasks, U+F0AE). Ridge only attaches
# an icon PART to an item if --icon carries a non-empty value at `ridge add`
# time (an empty --icon leaves style.icon nil); every later `ridge set
# --icon-color ...` call then fails with "item has no icon" - see README.md.
TASKS_GLYPH=$''

THINGS_CACHE="${TMPDIR:-/tmp}/ridge_tasks_things"   # lines: id|title
NP_CACHE="${TMPDIR:-/tmp}/ridge_tasks_np"           # lines: title (display-ready)
INBOX_CACHE="${TMPDIR:-/tmp}/ridge_tasks_inbox"     # lines: obsidian-uri|title

_have() { command -v "$1" >/dev/null 2>&1; }

# `timeout` isn't shipped on macOS by default; alarm+exec is the standard
# shim (matches the sibling raycast_focus plugin). Wraps the Things3
# AppleScript call so a hung/slow script can never stall the poll loop.
_timeout() {
  local secs="$1"
  shift
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
}

# shellcheck disable=SC2034 # SETTING_* are consumed by main(), not within this function
load_settings() {
  local json="{}"
  if [[ -n "${RIDGE_PLUGIN_SETTINGS:-}" && -f "${RIDGE_PLUGIN_SETTINGS}" ]]; then
    json="$(cat "${RIDGE_PLUGIN_SETTINGS}")"
  fi
  SETTING_region="$(jq -r '.region // "right"' <<<"$json")"
  # Icon font: TASKS_GLYPH is a Nerd Font glyph, so it renders as tofu in
  # the system default font unless a Nerd Font family is set at `ridge add` time.
  SETTING_font="$(jq -r '.font // "Iosevka Nerd Font"' <<<"$json")"
  [[ -n "$SETTING_font" ]] || SETTING_font="Iosevka Nerd Font"
  # Poll interval in seconds. Must be a positive number, else default 60 - a
  # zero-equivalent value (0, 00, .0, 0.00) would make `sleep` return instantly
  # and turn the loop into a CPU-hammering tight loop. Stripping all dots and
  # zeros leaves nothing iff the value is zero-equivalent.
  SETTING_interval="$(jq -r '.interval // "60"' <<<"$json")"
  [[ "$SETTING_interval" =~ ^[0-9]*\.?[0-9]+$ && -n "${SETTING_interval//[.0]/}" ]] || SETTING_interval="60"

  SETTING_things_enabled="$(jq -r '.things_enabled // "true"' <<<"$json")"
  [[ "$SETTING_things_enabled" == "true" || "$SETTING_things_enabled" == "false" ]] || SETTING_things_enabled="true"
  SETTING_noteplan_enabled="$(jq -r '.noteplan_enabled // "true"' <<<"$json")"
  [[ "$SETTING_noteplan_enabled" == "true" || "$SETTING_noteplan_enabled" == "false" ]] || SETTING_noteplan_enabled="true"
  SETTING_obsidian_enabled="$(jq -r '.obsidian_enabled // "true"' <<<"$json")"
  [[ "$SETTING_obsidian_enabled" == "true" || "$SETTING_obsidian_enabled" == "false" ]] || SETTING_obsidian_enabled="true"

  # noteplan_dir/obsidian_inbox_dir default to a path built from $HOME, which
  # YAML cannot expand as a literal string in plugin.yaml. So plugin.yaml
  # leaves these unset (jq lookup yields "" via the // fallback below) and the
  # bash-expanded default is applied here instead; both keys still appear in
  # settings_schema so the GUI can show/override them.
  SETTING_noteplan_dir="$(jq -r '.noteplan_dir // ""' <<<"$json")"
  [[ -n "$SETTING_noteplan_dir" ]] || SETTING_noteplan_dir="${HOME}/Library/Containers/co.noteplan.NotePlan-setapp/Data/Library/Application Support/co.noteplan.NotePlan-setapp/Calendar"
  SETTING_obsidian_inbox_dir="$(jq -r '.obsidian_inbox_dir // ""' <<<"$json")"
  [[ -n "$SETTING_obsidian_inbox_dir" ]] || SETTING_obsidian_inbox_dir="${HOME}/Notes/Notes/00-INBOX"

  SETTING_obsidian_vault="$(jq -r '.obsidian_vault // "Notes"' <<<"$json")"
  [[ -n "$SETTING_obsidian_vault" ]] || SETTING_obsidian_vault="Notes"
  SETTING_obsidian_inbox_rel="$(jq -r '.obsidian_inbox_rel // "Notes/00-INBOX"' <<<"$json")"
  [[ -n "$SETTING_obsidian_inbox_rel" ]] || SETTING_obsidian_inbox_rel="Notes/00-INBOX"

  SETTING_max_rows="$(jq -r '.max_rows // "8"' <<<"$json")"
  [[ "$SETTING_max_rows" =~ ^[0-9]+$ && "$SETTING_max_rows" -ge 1 && "$SETTING_max_rows" -le 20 ]] || SETTING_max_rows="8"

  SETTING_icon_color="$(jq -r '.icon_color // "theme:primary"' <<<"$json")"
  SETTING_empty_color="$(jq -r '.empty_color // "theme:secondary"' <<<"$json")"
  # Sketchybar-style pill background, matching aerospace's workspace bubbles.
  SETTING_bg_color="$(jq -r '.bg_color // "theme:background"' <<<"$json")"
  SETTING_corner_radius="$(jq -r '.corner_radius // ""' <<<"$json")"
  if [[ -n "$SETTING_corner_radius" ]] && ! [[ "$SETTING_corner_radius" =~ ^[0-9]+$ && "$SETTING_corner_radius" -ge 0 && "$SETTING_corner_radius" -le 30 ]]; then
    SETTING_corner_radius=""
  fi
  # Empty (unset) means auto: ridge core adapts the pill height to the bar
  # height. bg_height stays a valid opt-in override; out-of-range or
  # non-numeric input resets to empty/auto rather than any fixed default.
  SETTING_bg_height="$(jq -r '.bg_height // ""' <<<"$json")"
  if [[ -n "$SETTING_bg_height" ]] && ! [[ "$SETTING_bg_height" =~ ^[0-9]+$ && "$SETTING_bg_height" -ge 16 && "$SETTING_bg_height" -le 48 ]]; then
    SETTING_bg_height=""
  fi
}

# Sketchybar-style pill background flags for the item's `ridge add` call -
# extracted so bats can assert the flags without invoking the real `ridge`
# CLI.
_pill_flags() {
  local out
  out="$(printf -- '--bg-color %s' "$SETTING_bg_color")"
  [[ -n "$SETTING_corner_radius" ]] && out+="$(printf -- ' --bg-corner-radius %s' "$SETTING_corner_radius")"
  [[ -n "$SETTING_bg_height" ]] && out+="$(printf -- ' --bg-height %s' "$SETTING_bg_height")"
  printf '%s' "$out"
}

# Percent-encode a string for use in an obsidian:// URI (canonical bash form,
# ported verbatim from the sketchybar source's urlencode()).
urlencode() {
  local LC_ALL=C str="$1" i char
  for (( i = 0; i < ${#str}; i++ )); do
    char="${str:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-]) printf '%s' "$char" ;;
      *) printf '%%%02X' "'$char" ;;
    esac
  done
}

# Extracts open ("- [ ]") task lines from a NotePlan note, stripping [[wikilink]]
# brackets. Factored out of refresh_caches so it's independently testable.
_tasks_parse_noteplan_note() {
  local note="$1"
  sed -nE 's/^[[:space:]]*[-*+] \[ \] *//p' "$note" | sed 's/\[\[//g; s/\]\]//g' | grep .
}

# Slow path: rebuild the three cache files from their live sources. A source
# left disabled has its cache cleared (not left stale), so it never
# contributes to the count or the popup.
refresh_caches() {
  if [[ "$SETTING_things_enabled" == "true" ]]; then
    if _timeout 5 osascript -e 'if application "Things3" is running then
      tell application "Things3"
        set out to ""
        repeat with t in to dos of list "Today"
          set out to out & (id of t) & "|" & (name of t) & linefeed
        end repeat
        return out
      end tell
    end if' 2>/dev/null | grep . > "${THINGS_CACHE}.tmp"; then
      mv "${THINGS_CACHE}.tmp" "$THINGS_CACHE"
    else
      rm -f "${THINGS_CACHE}.tmp"
      : > "$THINGS_CACHE"
    fi
  else
    : > "$THINGS_CACHE"
  fi

  if [[ "$SETTING_noteplan_enabled" == "true" ]]; then
    local today note="" ext
    today="$(date +%Y%m%d)"
    for ext in md txt; do
      if [[ -f "${SETTING_noteplan_dir}/${today}.${ext}" ]]; then
        note="${SETTING_noteplan_dir}/${today}.${ext}"
        break
      fi
    done
    if [[ -n "$note" ]] && _tasks_parse_noteplan_note "$note" > "${NP_CACHE}.tmp"; then
      mv "${NP_CACHE}.tmp" "$NP_CACHE"
    else
      rm -f "${NP_CACHE}.tmp"
      : > "$NP_CACHE"
    fi
  else
    : > "$NP_CACHE"
  fi

  if [[ "$SETTING_obsidian_enabled" == "true" ]]; then
    : > "${INBOX_CACHE}.tmp"
    shopt -s nullglob
    local f base enc
    for f in "${SETTING_obsidian_inbox_dir}"/*.md; do
      base="${f##*/}"
      enc="$(urlencode "${SETTING_obsidian_inbox_rel}/${base}")"
      printf '%s|%s\n' "obsidian://open?vault=${SETTING_obsidian_vault}&file=${enc}" "${base%.md}" >> "${INBOX_CACHE}.tmp"
    done
    shopt -u nullglob
    mv "${INBOX_CACHE}.tmp" "$INBOX_CACHE"
  else
    : > "$INBOX_CACHE"
  fi
}

# Reads the three cache files, prints "tcount<TAB>ncount<TAB>icount<TAB>total".
# grep -c prints "0" AND exits 1 on no-match, so a naive `|| echo 0` would
# append a second line and double-count; capturing via command substitution
# keeps only stdout regardless of exit status, so the count=${count:-0}
# fallback only fires when the file is missing entirely.
_tasks_counts() {
  local tcount ncount icount total
  tcount=$(grep -c . "$THINGS_CACHE" 2>/dev/null); tcount=${tcount:-0}
  ncount=$(grep -c . "$NP_CACHE" 2>/dev/null); ncount=${ncount:-0}
  icount=$(grep -c . "$INBOX_CACHE" 2>/dev/null); icount=${icount:-0}
  total=$((tcount + ncount + icount))
  printf '%s\t%s\t%s\t%s' "$tcount" "$ncount" "$icount" "$total"
}

# Builds one section's item-row array ({title, click} objects) from cache
# lines, via `jq -n --arg` per line then `jq -s` to collect - never one
# fragile jq expression over raw cache text.
_tasks_section_rows_json() {
  local cache="$1" uri_field="$2" max="$3" today click
  today="$(date +%Y%m%d)"
  local -a items=()
  local line id title uri
  # Cache file may not exist yet on the very first paint (refresh_caches
  # hasn't run) - `< "$cache"` would fail with "No such file or directory"
  # and print a spurious error, so guard it, not just try/catch it.
  if [[ -f "$cache" ]]; then
    while IFS= read -r line && [[ "${#items[@]}" -lt "$max" ]]; do
      [[ -z "$line" ]] && continue
      case "$uri_field" in
        things)
          id="${line%%|*}"; title="${line#*|}"
          click="open $(jq -rn --arg u "things:///show?id=${id}" '$u|@sh')"
          ;;
        noteplan)
          title="$line"
          click="open $(jq -rn --arg u "noteplan://x-callback-url/openNote?noteDate=${today}" '$u|@sh')"
          ;;
        obsidian)
          uri="${line%%|*}"; title="${line#*|}"
          click="open $(jq -rn --arg u "$uri" '$u|@sh')"
          ;;
      esac
      items+=("$(jq -n --arg title "$title" --arg click "$click" '{title: $title, click: $click}')")
    done < "$cache"
  fi
  if [[ "${#items[@]}" -eq 0 ]]; then
    printf '[]'
  else
    printf '%s\n' "${items[@]}" | jq -s '.'
  fi
}

# Builds the full popup rows JSON: a header + up to max_rows item rows per
# non-empty section (Things/NotePlan/Inbox), or a single "All clear" row when
# every section is empty.
_tasks_popup_rows_json() {
  local max="$1"
  local things_json np_json inbox_json
  things_json="$(_tasks_section_rows_json "$THINGS_CACHE" things "$max")"
  np_json="$(_tasks_section_rows_json "$NP_CACHE" noteplan "$max")"
  inbox_json="$(_tasks_section_rows_json "$INBOX_CACHE" obsidian "$max")"

  jq -n \
    --argjson things "$things_json" \
    --argjson noteplan "$np_json" \
    --argjson inbox "$inbox_json" \
    '
    def section(name; items):
      if (items | length) > 0 then
        [{type: "header", text: name}] + (items | map({text: .title, click: .click}))
      else
        []
      end;
    (section("Things"; $things) + section("NotePlan"; $noteplan) + section("Inbox"; $inbox)) as $rows
    | if ($rows | length) > 0 then $rows
      else [{icon: "", text: "All clear"}]
      end
    '
}

# Fast path: push the current (possibly stale) cache-derived count and popup
# rows to the bar. Cheap - only file reads + jq, no network/AppleScript.
paint() {
  local tcount ncount icount total
  IFS=$'\t' read -r tcount ncount icount total < <(_tasks_counts)

  if [[ "$total" -gt 0 ]]; then
    ridge set "$ITEM_ID" --text "$total" --icon-color "$SETTING_icon_color" 2>/dev/null || true
  else
    ridge set "$ITEM_ID" --text "" --icon-color "$SETTING_empty_color" 2>/dev/null || true
  fi

  local rows_json
  rows_json="$(_tasks_popup_rows_json "$SETTING_max_rows")"
  ridge popup set-rows "$ITEM_ID" --json "$rows_json" 2>/dev/null || true
}

main() {
  for dep in jq ridge osascript; do
    if ! _have "$dep"; then echo "tasks: required dependency '$dep' not found in PATH" >&2; exit 1; fi
  done
  if [[ -z "${RIDGE_SOCKET:-}" ]]; then echo "tasks: RIDGE_SOCKET is not set (run under ridge)" >&2; exit 1; fi
  load_settings

  # shellcheck disable=SC2046 # _pill_flags emits space-separated --flag value pairs with no embedded whitespace (hex colors/numbers only)
  ridge add "$ITEM_ID" --region "$SETTING_region" --text "" --icon "$TASKS_GLYPH" --icon-color "$SETTING_empty_color" --click "ridge popup toggle $ITEM_ID" --font "$SETTING_font" --icon-padding-right 8 $(_pill_flags) || true
  trap 'ridge remove "$ITEM_ID" 2>/dev/null; exit 0' TERM INT

  # Paint-refresh-paint sequentially, unlike the sketchybar source's
  # `&`-backgrounded refresh: that source is a short-lived script invoked
  # per-click/per-tick that must return fast, so it forks the slow refresh
  # into the background. This script IS the long-running loop process -
  # nothing waits on it to return - so refreshing inline and repainting
  # before the sleep is simpler and still never blocks a click (a click just
  # runs `ridge popup toggle`, which reads whatever rows this loop last
  # pushed; it never invokes this script synchronously).
  while true; do
    paint
    refresh_caches
    paint
    sleep "$SETTING_interval"
  done
}

# Guarded so sourcing (tests) is inert. Uses an if (not `[[ ]] && main`) so the
# guard is a no-op success when sourced, not a failing status that trips
# callers running under `set -e` (e.g. bats).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
