#!/bin/bash
# cmux-codex-usage.sh — feed OpenAI Codex CLI rate-limit utilization into the cmux
# custom sidebar via two "sentinel" workspaces' titles (cx5h + cx7d). Sibling of
# cmux-claude-usage.sh; same display channel, different data source.
#
# Data source: LOCAL, no token, no network. Codex CLI writes a per-turn rate-limit
# snapshot into its session rollout files:
#   ~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<ts>-<uuid>.jsonl
# Each populated snapshot carries a "rate_limits" object:
#   { "primary":   { "used_percent": 8.0, "window_minutes": 300,   "resets_at": <epoch> },
#     "secondary": { "used_percent": 1.0, "window_minutes": 10080, "resets_at": <epoch> } }
# primary = 300 min = the rolling 5-hour window; secondary = 10080 min = the weekly
# window — the same two windows the Claude meter shows. We read the LATEST non-null
# snapshot (newest file first) and paint the bars.
#
# CAVEATS (researched — see .claude/research/2026-06-19-codex-usage-data-source.md):
#   * This schema is COMMUNITY-OBSERVED, not an OpenAI-documented contract — so we
#     parse defensively (recursive search for rate_limits; tolerate missing keys;
#     accept resets_at OR resets_in_seconds).
#   * rate_limits is frequently `null`, especially in `codex exec`/non-interactive
#     runs (openai/codex #14880, #14728). So we scan newest-first for the latest
#     NON-null snapshot and stamp "⚠ stale" if none is found.
#   * The snapshot only advances when Codex makes a request — when Codex is idle the
#     numbers are last-known. That's fine (usage only changes with use); a very old
#     snapshot is surfaced as "⚠ stale".
#
# Display channel: same as the Claude meter — the sidebar can't read idle-workspace
# progress, so we encode a unicode-block bar in the sentinel TITLE via
# rename-workspace ("cx5h ███░░░░░░░ 8% 4h50m") and the sidebar matches by the
# title label ("cx5h "/"cx7d ", via .hasPrefix). cmux 0.64.15 dropped stable
# workspace UUIDs, so we re-resolve each sentinel's ref by title every run.
#
# Modes:
#   --print     parse + print values (no cmux writes)
#   --raw       print the latest raw rate_limits JSON snapshot
#   --update    rename both sentinel workspaces with bars (for launchd)
#
# Provider gating: this is the CODEX provider; it SELF-GATES so it never errors or
# shows a panel when Codex is absent/disabled (the sidebar hides a provider whose
# sentinels are missing):
#   * disabled (USAGE_PROVIDERS doesn't list "codex"; default is "claude") → exit 0.
#   * not installed (no `codex` binary AND no ~/.codex/sessions) → exit 0.
#   * installed but no usable snapshot → "⚠ stale" (like the Claude offline stamp).
# Config: ~/.config/cmux/usage-sentinels.env
#   SENTINEL_CX5H_LABEL=cx5h   SENTINEL_CX7D_LABEL=cx7d
#   USAGE_PROVIDERS="claude codex"   # add "codex" to enable this poller

set -uo pipefail

SESSIONS_DIR="$HOME/.codex/sessions"
SENTINELS_ENV="$HOME/.config/cmux/usage-sentinels.env"
# How many of the newest rollout files to scan before giving up (bounds work — the
# newest file almost always carries the latest snapshot).
CODEX_SCAN_MAX="${CODEX_SCAN_MAX:-8}"

# shellcheck disable=SC1090
[ -f "$SENTINELS_ENV" ] && source "$SENTINELS_ENV"
LABEL_CX5H="${SENTINEL_CX5H_LABEL:-cx5h}"
LABEL_CX7D="${SENTINEL_CX7D_LABEL:-cx7d}"

PROVIDER_ID="codex"
USAGE_PROVIDERS="${USAGE_PROVIDERS:-claude}"

die() { echo "ERR: $*" >&2; exit 1; }

provider_enabled() {
  case " $USAGE_PROVIDERS " in *" $PROVIDER_ID "*) return 0 ;; *) return 1 ;; esac
}

# Is Codex installed/used HERE? True iff the CLI is on PATH or it has written
# sessions. No source ⇒ nothing to meter (distinct from "no snapshot yet").
provider_available() {
  command -v codex >/dev/null 2>&1 && return 0
  [ -d "$SESSIONS_DIR" ] && return 0
  return 1
}

# Resolve a sentinel's current ref by its title label (refs rotate across cmux
# restarts — same scheme as the Claude poller). Matches the BARE label too: a
# freshly-created sentinel is titled just "cx5h" (no bar yet), and
# startswith("cx5h ") alone would never match it, so the first --update could
# never bootstrap it. Multi-window: `workspace list` is window-scoped and launchd
# has no window context, so try the default window first, then scan every window.
# Prints "<ref>\t<window>" — window EMPTY for the default window, else the window
# id so the caller can pass --window (makes the positional ref unambiguous). Empty
# output means no sentinel in any window.
resolve_ref() { # $1 = label
  local lbl="$1" ref w
  ref=$(cmux workspace list --json 2>/dev/null \
    | jq -r --arg l "$lbl" '.workspaces[] | select(.title == $l or (.title | startswith($l + " "))) | .ref' 2>/dev/null | head -1)
  [ -n "$ref" ] && { printf '%s\t' "$ref"; return; }
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    ref=$(cmux workspace list --window "$w" --json 2>/dev/null \
      | jq -r --arg l "$lbl" '.workspaces[] | select(.title == $l or (.title | startswith($l + " "))) | .ref' 2>/dev/null | head -1)
    [ -n "$ref" ] && { printf '%s\t%s' "$ref" "$w"; return; }
  done < <(cmux list-windows --json 2>/dev/null | jq -r '.[].id // empty' 2>/dev/null)
}

# Resolve a sentinel by label (across windows) and rename it to $2. Echoes cmux's
# stderr on a rejected rename. Return: 0 ok, 10 sentinel-not-found, 11 rejected.
_paint() { # $1 = label  $2 = new title
  local rw ref win err wargs=()
  rw=$(resolve_ref "$1"); IFS=$'\t' read -r ref win <<<"$rw"
  [ -n "$ref" ] || return 10
  [ -n "$win" ] && wargs=(--window "$win")
  # ${wargs[@]+"${wargs[@]}"} expands to nothing when the array is empty — required
  # under `set -u` on bash 3.2 (macOS /bin/bash), where a bare "${wargs[@]}" errors.
  err=$(cmux rename-workspace --workspace "$ref" ${wargs[@]+"${wargs[@]}"} "$2" 2>&1 >/dev/null) || { printf '%s' "$err"; return 11; }
  return 0
}

# Latest NON-null rate_limits snapshot across the newest rollout files. Recursive
# (`.. | objects`) so we don't depend on the (unofficial) nesting path. Prints the
# rate_limits JSON object, or empty + non-zero if none found.
latest_snapshot() {
  local f rl
  [ -d "$SESSIONS_DIR" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rl=$(jq -c '[.. | objects | select(has("rate_limits")) | .rate_limits | select(.primary != null)] | last // empty' "$f" 2>/dev/null | tail -1)
    if [ -n "$rl" ]; then printf '%s' "$rl"; return 0; fi
  done < <(find "$SESSIONS_DIR" -name 'rollout-*.jsonl' 2>/dev/null | sort -r | head -n "$CODEX_SCAN_MAX")
  return 1
}

# epoch -> compact "in" duration: "now" | "37m" | "4h12m" | "2d3h"
humanize_until() {
  local target="$1" now diff d h m
  [ -n "$target" ] || { echo "?"; return; }
  case "$target" in '' | *[!0-9]*) echo "?"; return ;; esac
  now=$(date +%s); diff=$(( target - now ))
  [ "$diff" -gt 0 ] || { echo "now"; return; }
  d=$(( diff/86400 )); h=$(( (diff%86400)/3600 )); m=$(( (diff%3600)/60 ))
  if   [ "$d" -gt 0 ]; then echo "${d}d${h}h"
  elif [ "$h" -gt 0 ]; then echo "${h}h${m}m"
  else echo "${m}m"; fi
}

# A window's reset epoch: prefer resets_at (absolute), else now + resets_in_seconds.
reset_epoch() { # $1 = window JSON
  local at rel
  at=$(printf '%s' "$1" | jq -r '.resets_at // empty' 2>/dev/null)
  case "$at" in '' | null) : ;; *[!0-9]*) at="" ;; esac
  if [ -n "$at" ]; then printf '%s' "$at"; return; fi
  rel=$(printf '%s' "$1" | jq -r '.resets_in_seconds // empty' 2>/dev/null)
  case "$rel" in '' | *[!0-9]*) printf ''; return ;; esac
  printf '%s' "$(( $(date +%s) + rel ))"
}

# integer percent (0-100) -> unicode block bar with 1/8-cell resolution.
make_bar() {
  local pct="${1:-0}" width="${2:-10}" eighths cell rem i bar="" start
  [ "$pct" -lt 0 ] && pct=0
  [ "$pct" -gt 100 ] && pct=100
  eighths=$(( pct * width * 8 / 100 ))
  cell=$(( eighths / 8 )); rem=$(( eighths % 8 ))
  for ((i = 0; i < cell; i++)); do bar+="█"; done
  if [ "$cell" -lt "$width" ]; then
    case "$rem" in
      1) bar+="▏" ;; 2) bar+="▎" ;; 3) bar+="▍" ;; 4) bar+="▌" ;;
      5) bar+="▋" ;; 6) bar+="▊" ;; 7) bar+="▉" ;; *) bar+="░" ;;
    esac
    start=$(( cell + 1 ))
    for ((i = start; i < width; i++)); do bar+="░"; done
  fi
  printf '%s' "$bar"
}

# Coerce an arbitrary value to a clamped integer percent (0-100), rounded, entirely
# in jq — the rate_limits schema is community-observed, so a missing/null/string
# used_percent must clamp to 0 rather than break or inject the shell.
to_pct() { # $1 = raw value (may be empty, null, or non-numeric)
  jq -rn --arg v "${1:-}" '
    (($v | tonumber?) // 0)
    | if . < 0 then 0 elif . > 100 then 100 else . end
    | round' 2>/dev/null || printf '0'
}

# Amber/red dot only when a limit is getting close (TRAILS the bar so the title
# still starts with the label that resolve_ref + the sidebar anchor on).
sev_dot() {
  local p="${1:-0}"
  if [ "$p" -ge 90 ]; then printf ' 🔴'
  elif [ "$p" -ge 70 ]; then printf ' 🟡'; fi
}

# Stamp both sentinels stale so a frozen bar is obvious. Needs the socket; no-ops
# if it can't reach cmux or resolve a sentinel. "⚠ stale" still starts with the
# label, so the sidebar keeps recognising it and resolve_ref still finds it.
mark_stale() {
  local reason="${1:-stale}"
  cmux ping &>/dev/null || return 0
  _paint "$LABEL_CX5H" "$LABEL_CX5H  ⚠ ${reason}" >/dev/null 2>&1 || true
  _paint "$LABEL_CX7D" "$LABEL_CX7D  ⚠ ${reason}" >/dev/null 2>&1 || true
}

main() {
  local mode="${1:---print}" rl

  # Provider gate (robustness): a disabled or not-installed provider is a clean
  # no-op — no error spam, no broken panel. The sidebar hides a provider whose
  # sentinels are absent, so exit 0 here = no panel.
  if ! provider_enabled; then
    echo "codex disabled (USAGE_PROVIDERS=\"$USAGE_PROVIDERS\") — nothing to do" >&2
    exit 0
  fi
  if ! provider_available; then
    echo "Codex not installed here (no \`codex\` binary / ~/.codex/sessions) — nothing to meter" >&2
    exit 0
  fi

  rl=$(latest_snapshot) || {
    [ "$mode" = "--update" ] && mark_stale "no data"
    die "no usable rate_limits snapshot in the newest $CODEX_SCAN_MAX rollout files (codex exec only? see #14880)"
  }

  if [ "$mode" = "--raw" ]; then
    printf '%s\n' "$rl" | jq . 2>/dev/null || printf '%s\n' "$rl"
    return
  fi

  local p5 p7 e5 e7 pct5 pct7 h5 h7
  p5=$(printf '%s' "$rl" | jq -c '.primary')
  p7=$(printf '%s' "$rl" | jq -c '.secondary')
  pct5=$(to_pct "$(printf '%s' "$p5" | jq -r '.used_percent // empty' 2>/dev/null)")
  pct7=$(to_pct "$(printf '%s' "$p7" | jq -r '.used_percent // empty' 2>/dev/null)")
  e5=$(reset_epoch "$p5"); e7=$(reset_epoch "$p7")
  h5=$(humanize_until "$e5"); h7=$(humanize_until "$e7")

  if [ "$mode" = "--print" ]; then
    echo "cx5h  ${pct5}%  · resets ${h5}"
    echo "cx7d  ${pct7}%  · resets ${h7}"
    return
  fi

  if [ "$mode" = "--update" ]; then
    cmux ping &>/dev/null || die "cmux socket rejected (restart cmux to apply socketControlMode=automation)"
    local bar5 bar7 dot5 dot7 err rc
    bar5=$(make_bar "$pct5" 10); bar7=$(make_bar "$pct7" 10)
    dot5=$(sev_dot "$pct5"); dot7=$(sev_dot "$pct7")
    # _paint resolves each sentinel by label (across windows) and writes the title;
    # rc 10 = sentinel missing (tell the user to create it), rc 11 = cmux rejected.
    err=$(_paint "$LABEL_CX5H" "$LABEL_CX5H ${bar5} ${pct5}% ${h5}${dot5}"); rc=$?
    [ "$rc" = 10 ] && die "no '$LABEL_CX5H' sentinel workspace (title \"$LABEL_CX5H\" or starting \"$LABEL_CX5H \") in any window — create it (~/bin/cmux-sentinel-setup.sh, or see install.sh)"
    [ "$rc" = 11 ] && die "rename rejected for $LABEL_CX5H sentinel: ${err:-no detail}"
    err=$(_paint "$LABEL_CX7D" "$LABEL_CX7D ${bar7} ${pct7}% ${h7}${dot7}"); rc=$?
    [ "$rc" = 10 ] && die "no '$LABEL_CX7D' sentinel workspace (title \"$LABEL_CX7D\" or starting \"$LABEL_CX7D \") in any window — create it (~/bin/cmux-sentinel-setup.sh, or see install.sh)"
    [ "$rc" = 11 ] && die "rename rejected for $LABEL_CX7D sentinel: ${err:-no detail}"
    echo "updated: ${LABEL_CX5H}=${pct5}% (${h5})  ${LABEL_CX7D}=${pct7}% (${h7})"
    return
  fi

  die "unknown mode: $mode (use --print | --raw | --update)"
}

main "$@"
