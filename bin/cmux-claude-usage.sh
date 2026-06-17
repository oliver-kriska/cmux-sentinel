#!/bin/bash
# cmux-claude-usage.sh — feed Claude Code rate-limit utilization into the cmux
# custom sidebar via two "sentinel" workspaces' progress bars (5h + 7d).
#
# Data source: Anthropic's (unofficial/beta) OAuth usage endpoint — the same one
# `ccusage statusline` calls. Returns real server-side utilization (0-100) and
# reset timestamps for the rolling 5-hour and 7-day windows. No official/stable
# API; the `anthropic-beta: oauth-2025-04-20` header may change.
#
# The OAuth token is read FRESH from the macOS Keychain each run (Claude Code
# refreshes it there ~hourly). It is never printed or persisted.
#
# Display channel: each metric rides a dedicated idle "sentinel" workspace, but
# the custom sidebar's workspace data does NOT carry `progress` for idle
# workspaces (only the active/agent workspace) — the TITLE, however, always
# propagates. So we encode a unicode-block bar directly in the title via
# `rename-workspace`: "5h ████░░░░░░ 39% 4h35m". The sidebar matches the two
# sentinels by exact id (its interpreter has no working String .contains) and
# renders their titles in a top USAGE panel, hidden from the normal list.
#
# Modes:
#   --print     fetch + print parsed values (verification; no cmux writes)
#   --raw       fetch + print raw JSON (token NOT included)
#   --update    fetch + rename both sentinel workspaces with bars (for launchd)
#
# Sentinel ids: ~/.config/cmux/usage-sentinels.env  (SENTINEL_5H=, SENTINEL_7D=)

set -uo pipefail

USAGE_ENDPOINT="https://api.anthropic.com/api/oauth/usage"
OAUTH_BETA="oauth-2025-04-20"
KEYCHAIN_SERVICE="Claude Code-credentials"
SENTINELS_ENV="$HOME/.config/cmux/usage-sentinels.env"

die() { echo "ERR: $*" >&2; exit 1; }

read_token() {
  local raw=""
  if raw=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null) && [ -n "$raw" ]; then
    :
  elif [ -f "$HOME/.claude/.credentials.json" ]; then
    raw=$(cat "$HOME/.claude/.credentials.json")
  else
    die "no Claude credentials (keychain '$KEYCHAIN_SERVICE' or ~/.claude/.credentials.json)"
  fi
  local tok
  tok=$(printf '%s' "$raw" | jq -r '.claudeAiOauth.accessToken // .accessToken // empty' 2>/dev/null)
  [ -n "$tok" ] || die "could not extract accessToken from credential JSON"
  printf '%s' "$tok"
}

fetch_usage() {
  curl -fsS --max-time 15 "$USAGE_ENDPOINT" \
    -H "Authorization: Bearer $1" \
    -H "anthropic-beta: $OAUTH_BETA" \
    -H "Content-Type: application/json"
}

# ISO8601 -> epoch seconds (BSD/macOS date). Handles Z, +00:00, fractional secs.
iso_to_epoch() {
  local iso="$1"
  [ -n "$iso" ] && [ "$iso" != "null" ] || { echo ""; return; }
  iso=$(printf '%s' "$iso" | sed -E 's/\.[0-9]+//; s/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')
  date -j -f "%Y-%m-%dT%H:%M:%S%z" "$iso" +%s 2>/dev/null || echo ""
}

# epoch -> compact "in" duration: "now" | "37m" | "4h12m" | "2d3h"
humanize_until() {
  local target="$1" now diff d h m
  [ -n "$target" ] || { echo "?"; return; }
  now=$(date +%s); diff=$(( target - now ))
  [ "$diff" -gt 0 ] || { echo "now"; return; }
  d=$(( diff/86400 )); h=$(( (diff%86400)/3600 )); m=$(( (diff%3600)/60 ))
  if   [ "$d" -gt 0 ]; then echo "${d}d${h}h"
  elif [ "$h" -gt 0 ]; then echo "${h}h${m}m"
  else echo "${m}m"; fi
}

# integer percent (0-100) -> unicode block bar with 1/8-cell resolution for a
# smooth leading edge: make_bar 24 10 -> "██▍░░░░░░░". Track = ░, fill = █ plus a
# partial glyph (▏▎▍▌▋▊▉) so even low single-digit % shows a visible sliver.
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

# Severity dot for the title — ONLY amber/red, nothing below 70% (Linear-clean:
# no indicator when you're fine, a dot only when a limit is getting close).
sev_dot() {
  local p="${1:-0}"
  if [ "$p" -ge 90 ]; then
    printf '🔴 '
  elif [ "$p" -ge 70 ]; then
    printf '🟡 '
  fi
}

# Best-effort: stamp both sentinels with an offline/stale marker so a frozen bar
# is obvious instead of silently showing the last good numbers. Needs the socket
# (same constraint as --update); silently no-ops if it can't reach cmux.
mark_offline() {
  local reason="${1:-offline}"
  [ -f "$SENTINELS_ENV" ] || return 0
  # shellcheck disable=SC1090
  source "$SENTINELS_ENV"
  [ -n "${SENTINEL_5H:-}" ] && [ -n "${SENTINEL_7D:-}" ] || return 0
  cmux ping &>/dev/null || return 0
  cmux rename-workspace --workspace "$SENTINEL_5H" "5h  ⚠ ${reason}" &>/dev/null
  cmux rename-workspace --workspace "$SENTINEL_7D" "7d  ⚠ ${reason}" &>/dev/null
}

# pull a bucket field, snake_case w/ camelCase fallback
bucket_field() { # $1=json $2=bucket_snake $3=bucket_camel $4=field_snake $5=field_camel
  printf '%s' "$1" | jq -r --arg bs "$2" --arg bc "$3" --arg fs "$4" --arg fc "$5" \
    '((.[$bs] // .[$bc]) // {}) | (.[$fs] // .[$fc] // empty)' 2>/dev/null
}

main() {
  local mode="${1:---print}" token json
  token=$(read_token) || { [ "$mode" = "--update" ] && mark_offline "no token"; exit 1; }
  json=$(fetch_usage "$token") || {
    [ "$mode" = "--update" ] && mark_offline "offline"
    die "usage request failed (token expired? endpoint changed? offline?)"
  }

  if [ "$mode" = "--raw" ]; then
    printf '%s\n' "$json" | jq . 2>/dev/null || printf '%s\n' "$json"
    return
  fi

  local fh_pct fh_reset sd_pct sd_reset fh_epoch sd_epoch fh_human sd_human
  fh_pct=$(bucket_field "$json" five_hour fiveHour utilization utilization)
  fh_reset=$(bucket_field "$json" five_hour fiveHour resets_at resetsAt)
  sd_pct=$(bucket_field "$json" seven_day sevenDay utilization utilization)
  sd_reset=$(bucket_field "$json" seven_day sevenDay resets_at resetsAt)
  fh_epoch=$(iso_to_epoch "$fh_reset"); sd_epoch=$(iso_to_epoch "$sd_reset")
  fh_pct=$(awk "BEGIN{printf \"%d\", ${fh_pct:-0}+0.5}")
  sd_pct=$(awk "BEGIN{printf \"%d\", ${sd_pct:-0}+0.5}")
  fh_human=$(humanize_until "$fh_epoch"); sd_human=$(humanize_until "$sd_epoch")

  if [ "$mode" = "--print" ]; then
    echo "5h  ${fh_pct}%  · resets ${fh_human}  (${fh_reset})"
    echo "7d  ${sd_pct}%  · resets ${sd_human}  (${sd_reset})"
    return
  fi

  if [ "$mode" = "--update" ]; then
    [ -f "$SENTINELS_ENV" ] || die "no sentinel config at $SENTINELS_ENV (run setup first)"
    # shellcheck disable=SC1090
    source "$SENTINELS_ENV"
    [ -n "${SENTINEL_5H:-}" ] && [ -n "${SENTINEL_7D:-}" ] || die "SENTINEL_5H/SENTINEL_7D not set in $SENTINELS_ENV"
    # Needs socketControlMode=automation, which the cmux socket server reads at
    # startup — a broken-pipe rejection here means cmux is still on cmuxOnly and
    # must be restarted to apply the mode.
    cmux ping &>/dev/null || die "cmux socket rejected (restart cmux to apply socketControlMode=automation)"
    # The custom sidebar's workspace data does NOT carry `progress` for idle
    # workspaces (only set on the active/agent workspace) — but the title always
    # propagates. So encode the bar + percent + reset directly in the title.
    local fh_bar sd_bar fh_dot sd_dot
    fh_bar=$(make_bar "$fh_pct" 10); fh_dot=$(sev_dot "$fh_pct")
    sd_bar=$(make_bar "$sd_pct" 10); sd_dot=$(sev_dot "$sd_pct")
    cmux rename-workspace --workspace "$SENTINEL_5H" "${fh_dot}5h ${fh_bar} ${fh_pct}% ${fh_human}" &>/dev/null
    cmux rename-workspace --workspace "$SENTINEL_7D" "${sd_dot}7d ${sd_bar} ${sd_pct}% ${sd_human}" &>/dev/null
    echo "updated: 5h=${fh_pct}% (${fh_human})  7d=${sd_pct}% (${sd_human})"
    return
  fi

  die "unknown mode '$mode' (use --print | --raw | --update)"
}

main "$@"
