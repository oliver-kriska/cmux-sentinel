#!/bin/bash
# cmux-codex-usage.sh — feed OpenAI Codex (ChatGPT-plan) rate-limit utilization
# into the cmux custom sidebar via two "sentinel" workspaces (cx5h + cx7d).
# Sibling of cmux-claude-usage.sh; same display channel, Codex app-server source.
#
# Data source: Codex's supported structured app-server RPC:
#   account/rateLimits/read
# The app server owns ChatGPT auth lookup/refresh, account headers, backend routing,
# and response normalization. That matters: reading ~/.codex/auth.json directly can
# use an expired token or miss credentials stored in the OS keyring. Under the hood
# current Codex still calls ChatGPT's internal wham/usage route, but this poller never
# handles the bearer token. The RPC response carries LIVE server-side utilization:
#   { "rateLimits": {
#       "primary":   { "usedPercent": 7, "windowDurationMins": 300,   "resetsAt": <epoch> },
#       "secondary": { "usedPercent": 3, "windowDurationMins": 10080, "resetsAt": <epoch> } } }
#   300m = 5h → cx5h; 10080m = weekly → cx7d. CRITICAL: route each window to a
#   sentinel by its ACTUAL windowDurationMins, NOT by primary/secondary POSITION.
#   OpenAI reshaped this live (2026-07-13): a Pro account returned the WEEKLY window
#   in primary_window with secondary_window=null, so the old position map dumped
#   weekly data into the 5h meter. A window may be absent for either bucket (renders
#   "n/a", not a fake 0%). Short (<1d) → cx5h; long (>=1d) → cx7d.
#
# WHY SERVER-SIDE RPC, not the old rollout files: up to codex-cli ~0.140 the CLI wrote a
# per-turn `rate_limits` snapshot into ~/.codex/sessions/**/rollout-*.jsonl and we
# read the newest (see .claude/research/2026-06-19-codex-usage-data-source.md).
# On codex-cli 0.142.x that source is DEAD for real usage: rollouts are only
# written by the interactive TUI (not `codex exec`, which is how Claude Code drives
# Codex — openai/codex#14880), and the fresh data moved into sqlite logs that don't
# expose the payload queryably. So a machine that uses Codex via Claude Code shows a
# weeks-stale bar. account/rateLimits/read is account-server-side, so it's correct
# for ANY usage pattern. Source audit: docs/usage-data-source-research.md.
#
# Modes:
#   --print     fetch + print parsed default + additional limits (no cmux writes)
#   --raw       print normalized JSON with opaque reset-credit ids removed
#   --raw-full  print complete normalized JSON (account-private; keep local)
#   --update    fetch + paint both sentinel workspaces (title + native progress bar)
#   --buckets   print the labels this account HAS a live window for (one per line);
#               prints NOTHING when it can't tell. For cmux-sentinel-setup.sh.
#   --status    print one stable JSON capability result for diagnostics:
#               available | unknown | disabled | uninstalled. Unlike --buckets,
#               this distinguishes a known bucket set from a can't-tell result.
#
# Provider gating: this is the CODEX provider; it SELF-GATES so Codex being absent
# or disabled never errors. The sidebar hides a provider only when its sentinels
# are absent; an existing sentinel remains visible and doctor flags it.
#   * disabled (USAGE_PROVIDERS doesn't list "codex"; default is "claude") → exit 0.
#   * Codex absent or not logged in on a ChatGPT plan (e.g. API-key users whom this
#     account allowance doesn't cover) → exit 0, do nothing.
#   * logged in but the fetch fails (expired token / offline) → transient "⚠ offline".
# Config: ~/.config/cmux/usage-sentinels.env
#   SENTINEL_CX5H_LABEL=cx5h   SENTINEL_CX7D_LABEL=cx7d
#   USAGE_PROVIDERS="claude codex"   # add "codex" to enable this poller

set -uo pipefail

# cmux prints a one-time deprecation notice for legacy verbs (rename-workspace →
# workspace rename) on STDERR. Anything that CAPTURES cmux stderr to explain a
# failure gets that notice at the front of the reason, where it reads as the cause
# — it buried a real "Command timed out" once. cmux documents this switch for it.
export CMUX_QUIET=1

SENTINELS_ENV="$HOME/.config/cmux/usage-sentinels.env"

# shellcheck disable=SC1090
[ -f "$SENTINELS_ENV" ] && source "$SENTINELS_ENV"
LABEL_CX5H="${SENTINEL_CX5H_LABEL:-cx5h}"
LABEL_CX7D="${SENTINEL_CX7D_LABEL:-cx7d}"

PROVIDER_ID="codex"
USAGE_PROVIDERS="${USAGE_PROVIDERS:-claude}"
USAGE_STATE_DIR="${CMUX_SENTINEL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/cmux-sentinel}/usage"

# App-server RPC process state. One short-lived process per poll keeps this Bash 3.2
# compatible without adding a daemon, Python, or another runtime dependency.
RPC_DIR=""; RPC_PID=""
RPC_INIT_INTERVALS="${CODEX_RPC_INIT_INTERVALS:-50}"
RPC_READ_INTERVALS="${CODEX_RPC_READ_INTERVALS:-300}"
case "$RPC_INIT_INTERVALS" in ''|*[!0-9]*) RPC_INIT_INTERVALS=50 ;; esac
case "$RPC_READ_INTERVALS" in ''|*[!0-9]*) RPC_READ_INTERVALS=300 ;; esac

die() { echo "ERR: $*" >&2; exit 1; }

# Record only a COMPLETE successful --update. Keep this best-effort: freshness
# diagnostics must never turn an already-painted meter into a failed launchd run.
record_success() {
  local tmp
  mkdir -p "$USAGE_STATE_DIR" || return 1
  tmp=$(mktemp "$USAGE_STATE_DIR/.${PROVIDER_ID}.XXXXXX") || return 1
  printf '%s\n' "$(date +%s)" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$USAGE_STATE_DIR/$PROVIDER_ID.last-success" || { rm -f "$tmp"; return 1; }
}

status_json() { # $1=status $2=reason $3=has-5h $4=has-7d $5=additional JSON $6=reset summary/null
  jq -cn --arg status "$1" --arg reason "$2" \
    --arg b5 "${3:-0}" --arg b7 "${4:-0}" \
    --arg l5 "$LABEL_CX5H" --arg l7 "$LABEL_CX7D" \
    --argjson additional "${5:-[]}" --argjson resetCredits "${6:-null}" '
      {status: $status,
       buckets: [if $b5 == "1" then $l5 else empty end,
                 if $b7 == "1" then $l7 else empty end],
       reason: $reason,
       additionalLimits: $additional,
       resetCredits: $resetCredits}'
}

provider_enabled() {
  case " $USAGE_PROVIDERS " in *" $PROVIDER_ID "*) return 0 ;; *) return 1 ;; esac
}

# Is Codex usable HERE? Ask Codex's own auth-storage abstraction rather than reading
# auth.json: current builds may use file or keyring storage. API-key users aren't
# covered by the ChatGPT-plan allowance, so they're treated as "nothing to meter".
# `login status` only reports stored mode (not token health); an expired ChatGPT
# login still falls through to the RPC and becomes the explicit transient offline state.
provider_available() {
  command -v codex >/dev/null 2>&1 || return 1
  # Codex 0.145 writes this status line to stderr; combine both streams so a
  # healthy login is not silently misclassified as uninstalled.
  codex login status 2>&1 | grep -q '^Logged in using ChatGPT$'
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

# Resolve a sentinel ONCE, then write BOTH its title (restart-proof anchor +
# unicode-bar fallback) and its native progress bar (value 0..1 + clean label),
# which cmux 0.64.17 passes to the sidebar interpreter. The sidebar draws a native
# ProgressView from it. Mirrors cmux-claude-usage.sh; see
# .claude/research/2026-07-06-conductor-sidebar-analysis.md. Return: 0/10/11 as _paint.
_meter_write() { # $1=label  $2=title  $3=progress_value(0..1)  $4=progress_label
  local rw ref win err wargs=()
  rw=$(resolve_ref "$1"); IFS=$'\t' read -r ref win <<<"$rw"
  [ -n "$ref" ] || return 10
  [ -n "$win" ] && wargs=(--window "$win")
  err=$(cmux rename-workspace --workspace "$ref" ${wargs[@]+"${wargs[@]}"} "$2" 2>&1 >/dev/null) || { printf '%s' "$err"; return 11; }
  cmux set-progress "$3" --label "$4" --workspace "$ref" ${wargs[@]+"${wargs[@]}"} >/dev/null 2>&1 || true
  return 0
}

# Drop a sentinel's progress bar so the sidebar falls back to its TITLE (e.g. the
# "⚠ offline" marker) instead of a stale native bar. Best-effort.
_clear_progress() { # $1 = label
  local rw ref win wargs=()
  rw=$(resolve_ref "$1"); IFS=$'\t' read -r ref win <<<"$rw"
  [ -n "$ref" ] || return 0
  [ -n "$win" ] && wargs=(--window "$win")
  cmux clear-progress --workspace "$ref" ${wargs[@]+"${wargs[@]}"} >/dev/null 2>&1 || true
}

# Close the app-server input, give it a moment to exit cleanly, then reap it and
# remove the private transport directory. Best-effort and safe to call after a
# partial startup.
_rpc_cleanup() {
  local i=0 state=""
  exec 3>&-
  if [ -n "$RPC_PID" ]; then
    while kill -0 "$RPC_PID" 2>/dev/null && [ "$i" -lt 20 ]; do
      state=$(ps -o stat= -p "$RPC_PID" 2>/dev/null | tr -d '[:space:]')
      case "$state" in ''|Z*) break ;; esac
      sleep 0.05; i=$((i + 1))
    done
    case "$state" in ''|Z*) : ;; *) kill "$RPC_PID" 2>/dev/null || true ;; esac
    wait "$RPC_PID" 2>/dev/null || true
  fi
  [ -z "$RPC_DIR" ] || rm -rf "$RPC_DIR"
  RPC_DIR=""; RPC_PID=""
}

_rpc_has_id() { # $1=output file  $2=response id
  jq -Re --argjson id "$2" 'fromjson? | select(.id == $id)' "$1" >/dev/null 2>&1
}

# Poll an append-only JSONL output file for one response id. Notifications may
# interleave, so position is never assumed. $3 is a count of 100ms intervals.
# Returns 2 when the process exits first and 3 on timeout, so diagnostics can say
# what actually failed without exposing Codex's response body.
_rpc_wait_for_id() { # $1=output file  $2=response id  $3=max intervals
  local out="$1" id="$2" max="$3" i=0 state
  while [ "$i" -lt "$max" ]; do
    # Read raw lines independently: an app-server notification may be mid-write
    # at EOF, and one torn line must not hide an earlier complete response.
    _rpc_has_id "$out" "$id" && return 0
    # Check once more after observing process death: the response can finish its
    # write between the first read and the liveness check.
    kill -0 "$RPC_PID" 2>/dev/null || { _rpc_has_id "$out" "$id" && return 0; return 2; }
    # A dead child remains visible to `kill -0` as a zombie until Bash reaps it,
    # and `jobs -pr` can still briefly report it as running in non-interactive
    # shells. `ps` gives us the process state without consuming its exit status.
    state=$(ps -o stat= -p "$RPC_PID" 2>/dev/null | tr -d '[:space:]')
    case "$state" in ''|Z*) _rpc_has_id "$out" "$id" && return 0; return 2 ;; esac
    sleep 0.1; i=$((i + 1))
  done
  return 3
}

_rpc_failure_json() { # $1=sanitized internal error code
  printf '{"_cmuxSentinelError":"%s"}' "$1"
}

_rpc_classify_response() { # $1=response JSON
  local message
  message=$(printf '%s' "$1" | jq -r '.error.message // ""' 2>/dev/null)
  case "$message" in
    *token_expired*|*"authentication token is expired"*|*"refresh token was already used"*|*"401 Unauthorized"*)
      printf 'login-expired' ;;
    *"error sending request"*|*"connection refused"*|*"failed to connect"*|*"dns error"*|*"network"*)
      printf 'network' ;;
    *) printf 'rpc-failed' ;;
  esac
}

failure_message() { # $1=sanitized internal error code
  case "$1" in
    login-expired) printf 'Codex login expired; run codex logout, then codex login' ;;
    network)       printf 'Codex backend is unreachable; check the network and retry' ;;
    timeout)       printf 'Codex app server timed out while reading rate limits' ;;
    app-server-exited) printf 'Codex app server exited before returning rate limits' ;;
    protocol)      printf 'Codex app-server response was not recognized; update Codex and retry' ;;
    *)             printf 'Codex rate-limit RPC failed' ;;
  esac
}

# Ask a short-lived Codex app server for its normalized account snapshot. A FIFO
# keeps stdin open until the id=1 response arrives; closing it early races the
# server's shutdown and can discard the response. OAuth never enters this script.
fetch_usage() {
  local fifo out err response rc=1 failure="app-server-exited" wait_rc=0
  # A server crash can close the FIFO between handshake writes. Ignore SIGPIPE so
  # printf returns failure and the normal offline + cleanup path still runs.
  trap '' PIPE
  trap '_rpc_cleanup' EXIT
  RPC_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cmux-codex-rpc.XXXXXX") \
    || { _rpc_failure_json "app-server-exited"; trap - EXIT; return 1; }
  fifo="$RPC_DIR/in"; out="$RPC_DIR/out"; err="$RPC_DIR/err"
  mkfifo "$fifo" || { _rpc_failure_json "app-server-exited"; _rpc_cleanup; trap - EXIT; return 1; }

  codex app-server --stdio <"$fifo" >"$out" 2>"$err" &
  RPC_PID=$!
  if exec 3>"$fifo"; then
    if printf '%s\n' \
      '{"id":0,"method":"initialize","params":{"clientInfo":{"name":"cmux-sentinel","version":"1"}}}' >&3 2>/dev/null; then
      _rpc_wait_for_id "$out" 0 "$RPC_INIT_INTERVALS"; wait_rc=$?
      case "$wait_rc" in 2) failure="app-server-exited" ;; 3) failure="timeout" ;; esac
      if [ "$wait_rc" = 0 ]; then
        response=$(jq -Rc 'fromjson? | select(.id == 0)' "$out" 2>/dev/null | tail -1)
        if printf '%s' "$response" | jq -e 'has("result")' >/dev/null 2>&1; then
          # Keep the two protocol writes separate. On Bash 3.2 a multi-argument
          # printf racing a closed FIFO can leak the unwritten second argument to
          # stdout, contaminating this function's JSON result.
          if printf '%s\n' '{"method":"initialized"}' >&3 2>/dev/null \
            && printf '%s\n' '{"id":1,"method":"account/rateLimits/read"}' >&3 2>/dev/null; then
            _rpc_wait_for_id "$out" 1 "$RPC_READ_INTERVALS"; wait_rc=$?
            case "$wait_rc" in 2) failure="app-server-exited" ;; 3) failure="timeout" ;; esac
            if [ "$wait_rc" = 0 ]; then
              response=$(jq -Rc 'fromjson? | select(.id == 1)' "$out" 2>/dev/null | tail -1)
              if printf '%s' "$response" | jq -e 'has("result")' >/dev/null 2>&1; then
                printf '%s' "$response" | jq -c '.result'
                rc=$?
              elif printf '%s' "$response" | jq -e 'has("error")' >/dev/null 2>&1; then
                failure=$(_rpc_classify_response "$response")
              else
                failure="protocol"
              fi
            fi
          fi
        else
          failure="protocol"
        fi
      fi
    fi
  fi

  [ "$rc" = 0 ] || _rpc_failure_json "$failure"
  _rpc_cleanup
  trap - EXIT
  return "$rc"
}

# epoch -> compact "in" duration: "now" | "37m" | "4h 12m" | "2d 3h"
humanize_until() {
  local target="$1" now diff d h m
  [ -n "$target" ] || { echo "?"; return; }
  case "$target" in '' | *[!0-9]*) echo "?"; return ;; esac
  now=$(date +%s); diff=$(( target - now ))
  [ "$diff" -gt 0 ] || { echo "now"; return; }
  d=$(( diff/86400 )); h=$(( (diff%86400)/3600 )); m=$(( (diff%3600)/60 ))
  if   [ "$d" -gt 0 ]; then echo "${d}d ${h}h"
  elif [ "$h" -gt 0 ]; then echo "${h}h ${m}m"
  else echo "${m}m"; fi
}

# A window's absolute reset epoch from Codex's normalized app-server response.
reset_epoch() { # $1 = window JSON
  local at
  at=$(printf '%s' "$1" | jq -r '.resetsAt // empty' 2>/dev/null)
  case "$at" in '' | null) : ;; *[!0-9]*) at="" ;; esac
  printf '%s' "$at"
}

duration_label() { # $1=window minutes
  local mins="${1:-0}"
  case "$mins" in ''|*[!0-9]*) printf '?'; return ;; esac
  if [ "$mins" -ge 1440 ] && [ $((mins % 1440)) = 0 ]; then printf '%dd' "$((mins / 1440))"
  elif [ "$mins" -ge 60 ] && [ $((mins % 60)) = 0 ]; then printf '%dh' "$((mins / 60))"
  else printf '%dm' "$mins"; fi
}

# Additional named limits are an open-ended backend map. Keep opaque ids as
# observation-local identity only, prefer limitName for display, validate each
# window independently, and never let one malformed extra invalidate the default
# Codex meter. These are diagnostics only — no extra sentinel/⌘ slot is created.
additional_limits_json() { # $1=full normalized response
  printf '%s' "$1" | jq -c '
    def clean: gsub("[\\r\\n\\t]"; " ") | .[0:80];
    if ((.rateLimitsByLimitId // null) | type) != "object" then []
    else [
      .rateLimitsByLimitId | to_entries[]
      | select((.value | type) == "object")
      | select(.key != "codex" and .value.limitId != "codex")
      | . as $entry
      | [
          ({kind: "primary", value: $entry.value.primary}),
          ({kind: "secondary", value: $entry.value.secondary})
        ]
        | map(select((.value | type) == "object"
                     and (.value.usedPercent | type) == "number"
                     and (.value.windowDurationMins | type) == "number"))
        | map({kind, usedPercent: .value.usedPercent,
               windowDurationMins: .value.windowDurationMins,
               resetsAt: (if (.value.resetsAt | type) == "number" then .value.resetsAt else null end)}) as $windows
      | select(($windows | length) > 0)
      | {id: (if ($entry.value.limitId | type) == "string" and ($entry.value.limitId | length) > 0
              then ($entry.value.limitId | clean) else ($entry.key | clean) end),
         name: (if ($entry.value.limitName | type) == "string" and (($entry.value.limitName | gsub("[\\r\\n\\t]"; " ") | length) > 0)
                then ($entry.value.limitName | clean)
                elif ($entry.value.limitId | type) == "string" and ($entry.value.limitId | length) > 0
                then ($entry.value.limitId | clean)
                else ($entry.key | clean) end),
         windows: $windows}
    ] end' 2>/dev/null || printf '[]'
}

reset_credits_json() { # $1=full normalized response
  printf '%s' "$1" | jq -c '
    def clean: gsub("[\\r\\n\\t]"; " ") | .[0:80];
    if ((.rateLimitResetCredits // null) | type) != "object" then null
    else .rateLimitResetCredits as $reset
      | {availableCount:
           (if ($reset.availableCount | type) == "number" and $reset.availableCount >= 0
            then ($reset.availableCount | floor) else null end),
         credits:
           [ $reset.credits[]?
             | select(type == "object")
             | {status: (if (.status | type) == "string" then (.status | clean) else null end),
                resetType: (if (.resetType | type) == "string" then (.resetType | clean) else null end),
                title: (if (.title | type) == "string" then (.title | clean) else null end),
                expiresAt: (if (.expiresAt | type) == "number" then .expiresAt else null end)} ]}
    end' 2>/dev/null || printf 'null'
}

print_additional_limits() { # $1=additional-limits JSON  $2=reset summary/null
  local name used mins resets human label count title
  while IFS=$'\t' read -r name used mins resets; do
    [ -n "$name" ] || continue
    label=$(duration_label "$mins")
    human=$(humanize_until "$resets")
    printf 'extra  %s  %s%% · %s window · resets %s\n' "$name" "$(to_pct "$used")" "$label" "$human"
  done < <(printf '%s' "$1" | jq -r '.[] | .name as $name | .windows[] | [$name, .usedPercent, .windowDurationMins, (.resetsAt // "")] | @tsv' 2>/dev/null)
  count=$(printf '%s' "$2" | jq -r '.availableCount // "null"' 2>/dev/null)
  title=$(printf '%s' "$2" | jq -r '[.credits[]? | select(.status == "available") | .title // empty] | first // empty' 2>/dev/null)
  [ -n "$title" ] && title=" · $title"
  case "$count" in ''|null|*[!0-9]*) : ;; 1) echo "reset  1 usage reset available${title} · redeem in Codex" ;;
    *) [ "$count" -gt 1 ] && echo "reset  $count usage resets available${title} · redeem in Codex" ;; esac
}

sanitized_raw_json() { # $1=full normalized response
  printf '%s' "$1" | jq '
    if (.rateLimitResetCredits.credits | type) == "array"
    then .rateLimitResetCredits.credits |= map(del(.id))
    else . end' 2>/dev/null
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

# Coerce a validated numeric value to a clamped integer percent (0-100), rounded.
# main rejects missing/null/string usedPercent before this runs, so schema drift
# becomes explicit no-data rather than a believable 0% meter.
to_pct() { # $1 = raw numeric value
  jq -rn --arg v "${1:-}" '
    (($v | tonumber?) // 0)
    | if . < 0 then 0 elif . > 100 then 100 else . end
    | round' 2>/dev/null || printf '0'
}

# clamped integer percent (0-100) -> fraction (0..1) for `set-progress`. $1 is a
# sanitized int from to_pct, so argjson is safe; guard to 0 otherwise.
to_frac() { jq -rn --argjson p "${1:-0}" '$p / 100' 2>/dev/null || printf '0'; }

# Amber/red dot only when a limit is getting close (TRAILS the bar so the title
# still starts with the label that resolve_ref + the sidebar anchor on).
sev_dot() {
  local p="${1:-0}"
  if [ "$p" -ge 90 ]; then printf ' 🔴'
  elif [ "$p" -ge 70 ]; then printf ' 🟡'; fi
}

# Best-effort: stamp both sentinels offline so a frozen bar is obvious, and drop the
# native bar so the "⚠ offline" title shows through. Needs the socket; no-ops if it
# can't reach cmux or resolve a sentinel. The marker still starts with the label, so
# the sidebar keeps recognising it and resolve_ref still finds it.
mark_offline() {
  local reason="${1:-offline}"
  cmux ping &>/dev/null || return 0
  _paint "$LABEL_CX5H" "$LABEL_CX5H |⚠ ${reason}|" >/dev/null 2>&1 || true
  _paint "$LABEL_CX7D" "$LABEL_CX7D |⚠ ${reason}|" >/dev/null 2>&1 || true
  _clear_progress "$LABEL_CX5H"; _clear_progress "$LABEL_CX7D"
}

# Failure ledger for --update. A sentinel is an ordinary workspace users can close,
# and writing meters in sequence with a `die` on the first failure meant ONE closed
# sentinel froze every meter after it at whatever it last said — for days, since
# each run aborted in the same place. Record instead of exiting, paint everything
# paintable, report once at the end.
MISSING=(); REJECTED=()

# Write ONE Codex sentinel for --update: a real meter (unicode-bar title fallback +
# native progress) when its window exists, or an honest "n/a" (no bar, progress
# cleared) when OpenAI didn't return that window (e.g. no 5h window on a Pro plan).
# Keeps the label prefix so resolve_ref + the sidebar anchor still match. Records a
# missing/rejected sentinel in the ledger and returns non-zero, so the OTHER bucket
# still gets its update.
_update_bucket() { # $1=label  $2=na(0/1)  $3=pct  $4=human_reset
  local label="$1" na="$2" pct="${3:-0}" human="${4:-?}" bar dot frac detail err rc
  if [ "$na" = 1 ]; then
    err=$(_paint "$label" "$label |n/a|"); rc=$?
    # No sentinel for a window the account doesn't HAVE is the intended steady state,
    # not a misconfiguration: setup deliberately skips creating one (see its
    # `ensure_live`), and OpenAI dropped the 5h window for Codex Pro. Dying here would
    # make the launchd poller fail every 5 min over a meter nobody asked for. A
    # missing sentinel for a LIVE window still dies below — that one IS a real error.
    [ "$rc" = 10 ] && return 0
    [ "$rc" = 11 ] && { REJECTED+=("$label (${err:-no detail})"); return 1; }
    _clear_progress "$label"
    return 0
  fi
  bar=$(make_bar "$pct" 14); dot=$(sev_dot "$pct"); frac=$(to_frac "$pct")
  detail="${pct}% (${human})${dot}"
  err=$(_meter_write "$label" "$label |${detail}|${bar}" "$frac" "$detail"); rc=$?
  [ "$rc" = 10 ] && { MISSING+=("$label"); return 1; }
  [ "$rc" = 11 ] && { REJECTED+=("$label (${err:-no detail})"); return 1; }
  return 0
}

main() {
  local mode="${1:---print}" json fetch_rc failure_code reason extras reset_summary

  # Provider gate (robustness): a disabled or not-logged-in provider is a clean
  # no-op — no error spam. Existing sentinels are not removed here, so panel
  # visibility still follows sentinel presence. `login status` does not validate
  # token health, so an expired login falls through to the transient '⚠ offline'.
  if ! provider_enabled; then
    if [ "$mode" = "--status" ]; then status_json "disabled" "provider disabled" 0 0; exit 0; fi
    echo "codex disabled (USAGE_PROVIDERS=\"$USAGE_PROVIDERS\") — nothing to do" >&2
    exit 0
  fi
  if ! provider_available; then
    if [ "$mode" = "--status" ]; then status_json "uninstalled" "ChatGPT-plan login unavailable" 0 0; exit 0; fi
    echo "Codex CLI not logged in on a ChatGPT plan — nothing to meter" >&2
    exit 0
  fi

  json=$(fetch_usage); fetch_rc=$?
  if [ "$fetch_rc" != 0 ]; then
    # Select only our internal marker if a dying FIFO emitted protocol debris.
    # Never surface the app-server response body in status or error output.
    failure_code=$(printf '%s' "$json" | jq -s -r \
      'map(select(type == "object" and has("_cmuxSentinelError"))) | last | ._cmuxSentinelError // "rpc-failed"' \
      2>/dev/null)
    [ -n "$failure_code" ] || failure_code="rpc-failed"
    reason=$(failure_message "$failure_code")
    if [ "$mode" = "--status" ]; then status_json "unknown" "$reason" 0 0; exit 0; fi
    [ "$mode" = "--update" ] && mark_offline "offline"
    die "$reason"
  fi

  if [ "$mode" = "--raw" ]; then
    sanitized_raw_json "$json" || die "couldn't sanitize Codex response"
    return
  fi
  if [ "$mode" = "--raw-full" ]; then
    echo "warning: --raw-full includes account-scoped reset-credit ids; keep this output local" >&2
    printf '%s\n' "$json" | jq . 2>/dev/null || printf '%s\n' "$json"
    return
  fi

  # Route each rate-limit window to a sentinel by its ACTUAL windowDurationMins,
  # NOT by primary/secondary POSITION (OpenAI reordered the shape — see the header).
  # Short window (<1 day) → cx5h; long (>=1 day) → cx7d. Either bucket may be empty
  # (that meter renders "n/a"); only both-empty is a hard error.
  local wins win5h win7d pct5 pct7 h5 h7 na5=0 na7=0
  wins=$(printf '%s' "$json" | jq -c '
      [ .rateLimits.primary, .rateLimits.secondary ] | map(select(. != null))' 2>/dev/null)
  # A missing/malformed duration is unknown, not zero seconds. Coercing it to 0
  # positively misclassified schema drift as cx5h in both --update and --buckets.
  win5h=$(printf '%s' "${wins:-[]}" | jq -c 'map(select((.windowDurationMins | type) == "number" and .windowDurationMins <  1440)) | first // empty' 2>/dev/null)
  win7d=$(printf '%s' "${wins:-[]}" | jq -c 'map(select((.windowDurationMins | type) == "number" and .windowDurationMins >= 1440)) | first // empty' 2>/dev/null)
  if [ -z "$win5h" ] && [ -z "$win7d" ]; then
    if [ "$mode" = "--status" ]; then status_json "unknown" "no recognized rate-limit windows" 0 0; return; fi
    [ "$mode" = "--update" ] && mark_offline "no data"
    die "Codex returned no recognized rate-limit windows (app-server schema changed?)"
  fi

  # A live, duration-routed window must carry a numeric usedPercent. The old
  # permissive conversion mapped string/null/missing values to 0%, turning an
  # upstream schema break into a healthy-looking meter. Treat the whole response
  # as unknown: the two windows are one account snapshot and stale sibling bars
  # are more misleading than an explicit no-data state.
  if { [ -n "$win5h" ] && ! printf '%s' "$win5h" | jq -e '(.usedPercent | type) == "number"' >/dev/null 2>&1; } \
    || { [ -n "$win7d" ] && ! printf '%s' "$win7d" | jq -e '(.usedPercent | type) == "number"' >/dev/null 2>&1; }; then
    if [ "$mode" = "--status" ]; then status_json "unknown" "invalid usedPercent" 0 0; return; fi
    [ "$mode" = "--update" ] && mark_offline "no data"
    die "Codex returned a missing or non-numeric usedPercent (app-server schema changed?)"
  fi
  if [ -n "$win5h" ]; then
    pct5=$(to_pct "$(printf '%s' "$win5h" | jq -r '.usedPercent // empty' 2>/dev/null)")
    h5=$(humanize_until "$(reset_epoch "$win5h")")
  else na5=1; fi
  if [ -n "$win7d" ]; then
    pct7=$(to_pct "$(printf '%s' "$win7d" | jq -r '.usedPercent // empty' 2>/dev/null)")
    h7=$(humanize_until "$(reset_epoch "$win7d")")
  else na7=1; fi

  extras=$(additional_limits_json "$json")
  reset_summary=$(reset_credits_json "$json")

  if [ "$mode" = "--status" ]; then
    status_json "available" "" "$((1 - na5))" "$((1 - na7))" "$extras" "$reset_summary"
    return
  fi

  # Which buckets does this account actually HAVE? Consumed by cmux-sentinel-setup.sh
  # so it only creates sentinels for real windows: OpenAI dropped the 5h window for
  # Pro, and a permanently-"n/a" cx5h isn't free — it's an ordinary workspace, so it
  # still eats one of the ⌘1…⌘9 keys to show nothing. Detected, never hardcoded, so
  # setup can recreate the sentinel if OpenAI restores the window.
  #
  # Prints ONLY on the paths that positively parsed a window; every can't-tell path
  # (disabled, not logged in, expired token, offline, schema change) exits earlier
  # with no stdout. That asymmetry IS the contract — the caller reads empty as "don't
  # know, create both", so a bad network can never silently delete a meter.
  if [ "$mode" = "--buckets" ]; then
    [ "$na5" = 1 ] || echo "$LABEL_CX5H"
    [ "$na7" = 1 ] || echo "$LABEL_CX7D"
    return
  fi

  if [ "$mode" = "--print" ]; then
    if [ "$na5" = 1 ]; then echo "cx5h  n/a  · no 5h window"; else echo "cx5h  ${pct5}%  · resets ${h5}"; fi
    if [ "$na7" = 1 ]; then echo "cx7d  n/a  · no weekly window"; else echo "cx7d  ${pct7}%  · resets ${h7}"; fi
    print_additional_limits "$extras" "$reset_summary"
    return
  fi

  if [ "$mode" = "--update" ]; then
    cmux ping &>/dev/null || die "cmux socket rejected (restart cmux to apply socketControlMode=automation)"
    # Each bucket writes a real meter, or an honest "n/a" when its window is absent.
    _update_bucket "$LABEL_CX5H" "$na5" "${pct5:-0}" "${h5:-?}" || true
    _update_bucket "$LABEL_CX7D" "$na7" "${pct7:-0}" "${h7:-?}" || true
    # A REJECTED rename is a broken write path, not a missing row — no freshness.
    [ "${#REJECTED[@]}" -gt 0 ] && die "cmux rejected the rename for: ${REJECTED[*]}"
    local sum5 sum7
    if [ "$na5" = 1 ]; then sum5="n/a"; else sum5="${pct5}% (${h5})"; fi
    if [ "$na7" = 1 ]; then sum7="n/a"; else sum7="${pct7}% (${h7})"; fi
    record_success || echo "WARN: meters updated, but couldn't record Codex freshness in $USAGE_STATE_DIR" >&2
    echo "updated: ${LABEL_CX5H}=${sum5}  ${LABEL_CX7D}=${sum7}"
    # Data flowed, so freshness is stamped above; a missing sentinel for a LIVE
    # window is still an error, just one that no longer costs the other meter.
    [ "${#MISSING[@]}" -gt 0 ] && die "no sentinel workspace for: ${MISSING[*]} — create it: ~/bin/cmux-sentinel-setup.sh"
    return 0
  fi

  die "unknown mode: $mode (use --print | --raw | --raw-full | --update | --buckets | --status)"
}

main "$@"
