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
# sentinels by their TITLE LABEL ("5h "/"7d ", via .hasPrefix) and renders their
# titles in a top USAGE panel, hidden from the normal list.
#
# Identity: cmux 0.64.15 removed stable workspace UUIDs from the model and from
# `workspace list --json` (id is null) — the only handle is a positional `ref`
# (workspace:N) that ROTATES across app restarts and reorders. So we can't store
# a sentinel id (the old SENTINEL_5H/7D UUID scheme broke on every restart); we
# re-resolve each sentinel's ref every run from its title label, the one stable
# anchor the sidebar also keys on. See resolve_ref().
#
# Modes:
#   --print     fetch + print parsed values (verification; no cmux writes)
#   --raw       fetch + print raw JSON (token NOT included)
#   --update    fetch + rename both sentinel workspaces with bars (for launchd)
#
# Provider gating (which usage meters show, robustly): a provider's panel shows in
# the sidebar IFF its sentinels exist, and the sidebar hides any provider with
# none. This poller is the CLAUDE provider and SELF-GATES so an uninstalled or
# disabled Claude never crashes, spams the launchd .err, or shows a broken panel:
#   * disabled (USAGE_PROVIDERS doesn't list "claude") → exit 0, do nothing.
#   * not installed (no Keychain item AND no ~/.claude/.credentials.json) → exit 0,
#     do nothing. "Not installed" ≠ "token expired": an EXPIRED token (creds exist
#     but the fetch fails) is a TRANSIENT state and still stamps "⚠ offline".
# So adding/removing a provider = run/stop its poller + create/close its sentinels;
# you never edit the sidebar. See examples/usage-sentinels.env.example.
#
# Config (overridable): ~/.config/cmux/usage-sentinels.env
#   SENTINEL_5H_LABEL=5h   SENTINEL_7D_LABEL=7d
#   USAGE_PROVIDERS="claude"   # space-separated; drop "claude" to disable this one

set -uo pipefail

USAGE_ENDPOINT="https://api.anthropic.com/api/oauth/usage"
OAUTH_BETA="oauth-2025-04-20"
KEYCHAIN_SERVICE="Claude Code-credentials"
SENTINELS_ENV="$HOME/.config/cmux/usage-sentinels.env"

# Title-label anchors for the two Claude sentinels (the poller writes each title
# starting with its label, and the sidebar matches the same prefix). Overridable
# via the env file; sane defaults so the poller works zero-config.
# shellcheck disable=SC1090
[ -f "$SENTINELS_ENV" ] && source "$SENTINELS_ENV"
LABEL_5H="${SENTINEL_5H_LABEL:-5h}"
LABEL_7D="${SENTINEL_7D_LABEL:-7d}"

# This poller's provider id and the enabled set. Default "claude" so it works
# zero-config; drop "claude" from USAGE_PROVIDERS to disable it without touching
# launchd (e.g. USAGE_PROVIDERS="codex").
PROVIDER_ID="claude"
USAGE_PROVIDERS="${USAGE_PROVIDERS:-claude}"

die() { echo "ERR: $*" >&2; exit 1; }

# Is THIS provider enabled in the configured set? (space-padded substring match)
provider_enabled() {
  case " $USAGE_PROVIDERS " in *" $PROVIDER_ID "*) return 0 ;; *) return 1 ;; esac
}

# Is Claude Code installed/logged in HERE? True iff a credential SOURCE exists
# (Keychain item OR creds file) — regardless of whether the token is currently
# valid. No source ⇒ Claude was never set up on this machine ⇒ nothing to meter
# (distinct from an EXPIRED token, which is a transient 'offline').
provider_available() {
  security find-generic-password -s "$KEYCHAIN_SERVICE" -w &>/dev/null && return 0
  [ -f "$HOME/.claude/.credentials.json" ] && return 0
  return 1
}

# Resolve a sentinel's CURRENT ref by its title label. cmux dropped stable
# workspace UUIDs (0.64.15), so refs (workspace:N) are the only handle — and they
# rotate across restarts/reorders. Re-resolving by title every run is what makes
# the poller survive a cmux restart (same reason the bridge reads a LIVE
# $CMUX_WORKSPACE_ID instead of storing one). Prints the ref, or empty if none.
resolve_ref() { # $1 = label (e.g. "5h")
  # Match a freshly-created sentinel titled EXACTLY the label ("5h") as well as one
  # already painted with a bar ("5h ████ …"). Bootstrap matters: install tells users
  # to name it just "5h", and startswith("5h ") alone never matches that (no trailing
  # space) — so the first --update could never resolve it and the meter never started.
  #
  # Multi-window: `workspace list` is window-scoped and launchd has NO window context,
  # so a sentinel parked in a non-default window would be invisible. Try the default
  # window first (the common single-window case — fast, one call), then fall back to
  # scanning every window. Prints "<ref>\t<window>" — the window is EMPTY for the
  # default window (a bare ref suffices) or the window id when found via fallback (so
  # the caller can pass --window, which makes the positional ref unambiguous). Empty
  # output means no sentinel anywhere.
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
# Centralises the resolve + optional --window so every writer (mark_offline and
# --update) gets multi-window targeting for free.
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
  if [ -z "$iso" ] || [ "$iso" = "null" ]; then echo ""; return; fi
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
# no indicator when you're fine, a dot only when a limit is getting close). It
# TRAILS the bar (leading space) so the title always starts with the label, which
# is what resolve_ref() and the sidebar both anchor on.
sev_dot() {
  local p="${1:-0}"
  if [ "$p" -ge 90 ]; then
    printf ' 🔴'
  elif [ "$p" -ge 70 ]; then
    printf ' 🟡'
  fi
}

# Best-effort: stamp both sentinels with an offline/stale marker so a frozen bar
# is obvious instead of silently showing the last good numbers. Needs the socket
# (same constraint as --update); silently no-ops if it can't reach cmux or if a
# sentinel can't be resolved. The "⚠ offline" title still starts with the label,
# so the sidebar keeps recognising it as a meter and resolve_ref still finds it.
mark_offline() {
  local reason="${1:-offline}"
  cmux ping &>/dev/null || return 0
  _paint "$LABEL_5H" "$LABEL_5H  ⚠ ${reason}" >/dev/null 2>&1 || true
  _paint "$LABEL_7D" "$LABEL_7D  ⚠ ${reason}" >/dev/null 2>&1 || true
}

# pull a bucket field, snake_case w/ camelCase fallback
bucket_field() { # $1=json $2=bucket_snake $3=bucket_camel $4=field_snake $5=field_camel
  printf '%s' "$1" | jq -r --arg bs "$2" --arg bc "$3" --arg fs "$4" --arg fc "$5" \
    '((.[$bs] // .[$bc]) // {}) | (.[$fs] // .[$fc] // empty)' 2>/dev/null
}

# Coerce an arbitrary field value to a clamped integer percent (0-100), rounded.
# Done entirely in jq so untrusted API text is NEVER interpolated into a shell/awk
# program (the endpoint is unofficial/beta — a malformed or hostile utilization
# value must not break or inject the script); null/missing/non-numeric → 0.
to_pct() { # $1 = raw value (may be empty, null, or non-numeric)
  jq -rn --arg v "${1:-}" '
    (($v | tonumber?) // 0)
    | if . < 0 then 0 elif . > 100 then 100 else . end
    | round' 2>/dev/null || printf '0'
}

main() {
  local mode="${1:---print}" token json

  # Provider gate (robustness): never crash, error-spam, or leave a broken panel
  # for a provider that's turned off or not installed. The sidebar hides a provider
  # whose sentinels are absent, so a clean exit 0 here = no panel, no noise. An
  # EXPIRED token is NOT caught here (creds still exist) — it falls through to the
  # transient '⚠ offline' path below, which is the genuinely useful signal.
  if ! provider_enabled; then
    echo "claude disabled (USAGE_PROVIDERS=\"$USAGE_PROVIDERS\") — nothing to do" >&2
    exit 0
  fi
  if ! provider_available; then
    echo "Claude Code not installed here (no Keychain item / ~/.claude/.credentials.json) — nothing to meter" >&2
    exit 0
  fi

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
  fh_pct=$(to_pct "$fh_pct")
  sd_pct=$(to_pct "$sd_pct")
  fh_human=$(humanize_until "$fh_epoch"); sd_human=$(humanize_until "$sd_epoch")

  if [ "$mode" = "--print" ]; then
    echo "5h  ${fh_pct}%  · resets ${fh_human}  (${fh_reset})"
    echo "7d  ${sd_pct}%  · resets ${sd_human}  (${sd_reset})"
    return
  fi

  if [ "$mode" = "--update" ]; then
    # Needs socketControlMode=automation, which the cmux socket server reads at
    # startup — a broken-pipe rejection here means cmux is still on cmuxOnly and
    # must be restarted to apply the mode.
    cmux ping &>/dev/null || die "cmux socket rejected (restart cmux to apply socketControlMode=automation)"
    # The custom sidebar's workspace data does NOT carry `progress` for idle
    # workspaces (only set on the active/agent workspace) — but the title always
    # propagates. So encode the bar + percent + reset directly in the title. The
    # label leads, the severity dot trails — both sides anchor on the label.
    local fh_bar sd_bar fh_dot sd_dot err rc
    fh_bar=$(make_bar "$fh_pct" 10); fh_dot=$(sev_dot "$fh_pct")
    sd_bar=$(make_bar "$sd_pct" 10); sd_dot=$(sev_dot "$sd_pct")
    # _paint resolves each sentinel FRESH by title label (across windows) and writes
    # the title — the actual user-visible change. The `ping` gate passing does NOT
    # guarantee a rename lands (socket auth could drop mid-run, a ref could go stale,
    # or the sentinel could be gone), so check each: rc 10 = no sentinel (tell the
    # user to create it), rc 11 = cmux rejected the rename (surface its stderr).
    err=$(_paint "$LABEL_5H" "$LABEL_5H ${fh_bar} ${fh_pct}% ${fh_human}${fh_dot}"); rc=$?
    [ "$rc" = 10 ] && die "no '$LABEL_5H' sentinel workspace (title \"$LABEL_5H\" or starting \"$LABEL_5H \") in any window — create it (~/bin/cmux-sentinel-setup.sh, or see install.sh)"
    [ "$rc" = 11 ] && die "rename rejected for $LABEL_5H sentinel: ${err:-no detail}"
    err=$(_paint "$LABEL_7D" "$LABEL_7D ${sd_bar} ${sd_pct}% ${sd_human}${sd_dot}"); rc=$?
    [ "$rc" = 10 ] && die "no '$LABEL_7D' sentinel workspace (title \"$LABEL_7D\" or starting \"$LABEL_7D \") in any window — create it (~/bin/cmux-sentinel-setup.sh, or see install.sh)"
    [ "$rc" = 11 ] && die "rename rejected for $LABEL_7D sentinel: ${err:-no detail}"
    echo "updated: ${LABEL_5H}=${fh_pct}% (${fh_human})  ${LABEL_7D}=${sd_pct}% (${sd_human})"
    return
  fi

  die "unknown mode '$mode' (use --print | --raw | --update)"
}

main "$@"
