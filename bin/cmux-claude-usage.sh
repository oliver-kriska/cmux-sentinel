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
# Display channel: each metric rides a dedicated idle "sentinel" workspace.
# `progress` reaches the custom sidebar once set, so every update writes a native
# progress value + compact label. It also renames the TITLE to a restart-proof
# fallback: "5h |39% (4h 35m)|█████░░░░░░░░░". The title survives bootstrap,
# offline clears, dropped writes, and restarts before the next poll, and its leading
# label remains the stable identity anchor. The sidebar matches "5h "/"7d " via
# `.hasPrefix`, renders human labels + native bars in the top panel, and hides the
# sentinels from the normal list. `|` separates fallback detail from fallback bar.
#
# Identity: cmux 0.64.15 removed stable workspace UUIDs from the model and from
# `workspace list --json` (id came back null) — leaving only a positional `ref`
# (workspace:N) that ROTATES across app restarts and reorders. So we can't store
# a sentinel id (the old SENTINEL_5H/7D UUID scheme broke on every restart); we
# re-resolve each sentinel's ref every run from its title label, the one stable
# anchor the sidebar also keys on. See resolve_ref().
#
# 0.64.22 populates `id` again (upstream #8437) and it matches $CMUX_WORKSPACE_ID.
# We deliberately still don't use it: populated is not the same as durable across a
# restart, the explicitly durable `stableId` is still not exposed, and re-resolving
# by title is restart-proof by construction — so an id buys nothing here. See CLAUDE.md.
#
# Modes:
#   --print     fetch + print parsed values (verification; no cmux writes)
#   --raw       fetch + print raw JSON (token NOT included)
#   --update    fetch + rename both sentinel workspaces with bars (for launchd)
#   --buckets   print the labels that have LIVE data (drives setup; fails open)
#
# Provider gating (which usage meters show, robustly): a provider's panel shows in
# the sidebar IFF its sentinels exist, and the sidebar hides any provider with
# none. This poller is the CLAUDE provider and SELF-GATES so an uninstalled or
# disabled Claude never crashes or spams the launchd .err. Existing sentinels are
# a separate concern: they keep a panel visible until closed, and doctor flags them.
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

# cmux prints a one-time deprecation notice for legacy verbs (rename-workspace →
# workspace rename) on STDERR. We capture stderr to explain a FAILED write, so that
# notice lands at the front of the reason and reads as though it caused the failure
# — it buried a real "Command timed out" once. cmux itself documents this switch.
export CMUX_QUIET=1

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
# Per-MODEL weekly meter (e.g. a Fable-scoped weekly cap). OPT-IN, off by default:
# a sentinel is an ordinary workspace, so this row costs one of the ⌘1…⌘9 keys —
# same rule that keeps the Amp orb meter behind AMP_ORB_METER. The label is fixed
# because the sidebar's .hasPrefix anchors must be static; the MODEL NAME comes
# from the payload at paint time, so an Opus-scoped account labels itself correctly.
LABEL_M7D="${SENTINEL_M7D_LABEL:-m7d}"
MODEL_METER="${CLAUDE_MODEL_METER:-0}"
# Extra-usage (overage) spend meter. NOT opt-in, unlike every other optional row —
# and that is deliberate. The opt-in rule exists because a dead meter still costs a
# ⌘ key to show nothing; this row costs nothing to LOOK at, because the sidebar
# hides it entirely while the spend is zero. It also has to be on by default to do
# its job at all: the whole point is to catch money you did NOT expect to be
# spending, which a flag you never set can't do.
LABEL_SPEND="${SENTINEL_SPEND_LABEL:-spend}"

# This poller's provider id and the enabled set. Default "claude" so it works
# zero-config; drop "claude" from USAGE_PROVIDERS to disable it without touching
# launchd (e.g. USAGE_PROVIDERS="codex").
PROVIDER_ID="claude"
USAGE_PROVIDERS="${USAGE_PROVIDERS:-claude}"
USAGE_STATE_DIR="${CMUX_SENTINEL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/cmux-sentinel}/usage"

die() { echo "ERR: $*" >&2; exit 1; }

# Record only a COMPLETE successful --update. The doctor reads the epoch payload
# instead of filesystem mtimes, which keeps the check portable and easy to stub.
# Failure here must not turn an already-painted meter into a failed poll.
record_success() {
  local tmp
  mkdir -p "$USAGE_STATE_DIR" || return 1
  tmp=$(mktemp "$USAGE_STATE_DIR/.${PROVIDER_ID}.XXXXXX") || return 1
  printf '%s\n' "$(date +%s)" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$USAGE_STATE_DIR/$PROVIDER_ID.last-success" || { rm -f "$tmp"; return 1; }
}

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

# Progress channel: resolve a sentinel by label ONCE, then write BOTH
#   1. its TITLE — still the restart-proof anchor resolve_ref()/isClaudeMeter() key
#      on, and the fallback text the sidebar shows if progress is ever absent; and
#   2. its PROGRESS bar — value (0..1) + a clean label — which cmux 0.64.17 passes
#      to the custom-sidebar interpreter (null-until-set, verified 2026-07-06). The
#      sidebar draws a NATIVE ProgressView from this instead of a unicode title bar.
# Return codes mirror _paint: 0 ok, 10 sentinel-not-found, 11 rename rejected.
# set-progress is best-effort (|| true): a native bar is a nice-to-have, the title
# already carries the numbers, so a dropped progress write must not fail the poll.
_meter_write() { # $1=label  $2=title  $3=progress_value(0..1)  $4=progress_label
  local rw ref win err wargs=()
  rw=$(resolve_ref "$1"); IFS=$'\t' read -r ref win <<<"$rw"
  [ -n "$ref" ] || return 10
  [ -n "$win" ] && wargs=(--window "$win")
  err=$(cmux rename-workspace --workspace "$ref" ${wargs[@]+"${wargs[@]}"} "$2" 2>&1 >/dev/null) || { printf '%s' "$err"; return 11; }
  cmux set-progress "$3" --label "$4" --workspace "$ref" ${wargs[@]+"${wargs[@]}"} >/dev/null 2>&1 || true
  return 0
}

# Paint ONE meter, recording WHY it failed instead of exiting on the spot.
# Load-bearing: a sentinel is an ordinary workspace users can close, and the old
# code wrote 5h first and died on the first failure — so one closed sentinel froze
# the OTHER meter at whatever it last said (an "⚠ offline" from some earlier blip,
# for days, because every 5-minute run aborted in the same place before it reached
# 7d). Collect, paint everything paintable, then report once.
MISSING=(); REJECTED=()
paint_meter() { # $1=label  $2=title  $3=progress_value(0..1)  $4=progress_label
  local err rc
  err=$(_meter_write "$1" "$2" "$3" "$4"); rc=$?
  case "$rc" in
    0)  return 0 ;;
    10) MISSING+=("$1") ;;
    *)  REJECTED+=("$1 (${err:-no detail})") ;;
  esac
  return 1
}

# Drop a sentinel's progress bar so the sidebar falls back to its TITLE text (e.g.
# the "⚠ offline" marker) instead of showing a stale native bar. Best-effort.
_clear_progress() { # $1 = label
  local rw ref win wargs=()
  rw=$(resolve_ref "$1"); IFS=$'\t' read -r ref win <<<"$rw"
  [ -n "$ref" ] || return 0
  [ -n "$win" ] && wargs=(--window "$win")
  cmux clear-progress --workspace "$ref" ${wargs[@]+"${wargs[@]}"} >/dev/null 2>&1 || true
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

# fetch_usage's EXIT STATUS is the failure class. A bare "it failed" is a guess-list,
# and the two failures that actually happen need OPPOSITE fixes (401 = let Claude
# Code mint a fresh token; 429 = poll less often), so the class drives both the error
# text and the marker the sidebar shows. It has to ride the exit status rather than a
# variable because the caller runs this inside a command substitution — a subshell,
# from which no assignment escapes.
FETCH_OK=0; FETCH_AUTH=2; FETCH_RATE=3; FETCH_SERVER=4; FETCH_NET=5; FETCH_HTTP=6

# Short-lived response cache. Every invocation is its own API call, so the natural
# way to use this tool — `--print` to look, then `--update` to paint — hits the
# endpoint TWICE within seconds, on top of the 5-minute launchd poll. That burst is
# what trips 429 (19 of them in one machine's log, and a second user hit one live
# doing exactly print-then-update). launchd's own 300s interval is far outside this
# TTL, so the daemon is unaffected — this only collapses human bursts.
#
# Cached is the RAW body of a validated 200. Failures are never cached — the next
# poll always retries the network rather than replaying an error. (What a row
# DISPLAYS while a fetch is failing is a separate question, answered by the grace
# window below, which reads these same bytes and labels their age.)
CACHE_TTL="${CMUX_SENTINEL_USAGE_CACHE_TTL:-60}"   # 0 disables burst suppression
CACHE_FILE="$USAGE_STATE_DIR/$PROVIDER_ID.last-response.json"

# How long a last-good response may keep PAINTING after a fetch fails, before the
# rows fall back to the bare "⚠ <reason>" marker. The rule this softens is real —
# never quietly serve stale numbers as if they were live — so the grace paint is
# never quiet: it drops the reset countdown and shows the data's AGE in its place,
# and it still exits non-zero and still refuses to stamp freshness. What it buys is
# that one throttled request no longer wipes three meters whose numbers were five
# minutes old, on windows that move over hours and days. 0 = old behaviour.
STALE_GRACE="${CMUX_SENTINEL_STALE_GRACE:-1800}"
STALE_AGE=""        # set only on a grace paint; drives meter_detail() + the exit
STALE_WHY=""
BACKOFF_FILE="$USAGE_STATE_DIR/$PROVIDER_ID.backoff"
BACKOFF_BASE="${CMUX_SENTINEL_BACKOFF_BASE:-600}"
BACKOFF_MAX="${CMUX_SENTINEL_BACKOFF_MAX:-3600}"

# GNU `stat -c` is probed FIRST, then BSD `stat -f` — the order is load-bearing.
# On Linux `-f` means --file-system, so a BSD-first probe prints a filesystem block
# (and fails on the `%m` operand), the `||` then appends the real mtime to it, and
# the digit check below rejects the concatenation: the cache reads cold forever.
# BSD stat rejects `-c` outright with an empty stdout, so GNU-first is safe on both.
# Age of the stored last-good response in seconds; empty if there isn't one.
_cache_age() {
  [ -f "$CACHE_FILE" ] || return 1
  local mtime now
  mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null) || mtime=$(stat -f %m "$CACHE_FILE" 2>/dev/null) || return 1
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  local age=$(( now - mtime ))
  # A clock that moved backwards would otherwise read as a negative age, which
  # passes every "younger than" test below and serves a body of unknown vintage.
  [ "$age" -lt 0 ] && age=0
  printf '%s' "$age"
}

_cache_read() {
  [ "${CACHE_TTL:-0}" -gt 0 ] 2>/dev/null || return 1
  local age; age=$(_cache_age) || return 1
  [ "$age" -lt "$CACHE_TTL" ] || return 1
  cat "$CACHE_FILE" 2>/dev/null
}

# The GRACE read: the same stored body, but judged against the much longer grace
# window instead of the burst TTL. Only --update uses it, and only after a fetch
# has already failed — a human running --print still gets the error immediately.
_stale_read() {
  [ "${STALE_GRACE:-0}" -gt 0 ] 2>/dev/null || return 1
  local age; age=$(_cache_age) || return 1
  [ "$age" -le "$STALE_GRACE" ] || return 1
  cat "$CACHE_FILE" 2>/dev/null
}

_cache_write() {
  # Stored whenever EITHER feature could want it: the burst cache reads it inside
  # CACHE_TTL, the grace paint reads the same bytes for far longer. Gating this on
  # CACHE_TTL alone would mean TTL=0 silently disabled the grace window too.
  { [ "${CACHE_TTL:-0}" -gt 0 ] || [ "${STALE_GRACE:-0}" -gt 0 ]; } 2>/dev/null || return 0
  local tmp
  mkdir -p "$USAGE_STATE_DIR" 2>/dev/null || return 0
  tmp=$(mktemp "$USAGE_STATE_DIR/.resp.XXXXXX") || return 0
  # 600: this is an account-scoped usage body, same class as --raw-full.
  if printf '%s' "$1" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$CACHE_FILE"; then
    return 0
  fi
  rm -f "$tmp"
  return 0
}

# --- 429 backoff -------------------------------------------------------------
# A 429 is the ONE failure class where retrying on schedule makes things worse:
# the endpoint is telling us this cadence is too fast, and launchd would ask again
# in 5 minutes regardless, which is how a meter stays throttled for days. So only
# 429 backs off. An expired token (401) or a dropped network costs the endpoint
# nothing to retry and recovers the instant the user fixes it — backing those off
# would keep a meter dark long after it could have come back.
#
# Deliberately --update only: the daemon is what earns the throttle, and a human
# who types --print wants an answer, not a refusal from a state file.
_backoff_active() {
  [ -f "$BACKOFF_FILE" ] || return 1
  local deadline now
  deadline=$(cut -d' ' -f1 < "$BACKOFF_FILE" 2>/dev/null)
  case "$deadline" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ "$now" -lt "$deadline" ]
}

_backoff_arm() {
  [ "${BACKOFF_BASE:-0}" -gt 0 ] 2>/dev/null || return 0   # 0 = backoff disabled
  local n delay deadline
  n=$(cut -d' ' -f2 < "$BACKOFF_FILE" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$(( n + 1 ))
  # Doubling from BACKOFF_BASE, capped: 10m, 20m, 40m, then hourly.
  delay="$BACKOFF_BASE"
  local i=1
  while [ "$i" -lt "$n" ] && [ "$delay" -lt "$BACKOFF_MAX" ]; do
    delay=$(( delay * 2 )); i=$(( i + 1 ))
  done
  [ "$delay" -gt "$BACKOFF_MAX" ] && delay="$BACKOFF_MAX"
  deadline=$(( $(date +%s) + delay ))
  mkdir -p "$USAGE_STATE_DIR" 2>/dev/null || return 0
  printf '%s %s\n' "$deadline" "$n" > "$BACKOFF_FILE" 2>/dev/null || true
  echo "ERR: backing off ${delay}s after a 429 (attempt $n) — not calling the endpoint again until then" >&2
}

_backoff_clear() { rm -f "$BACKOFF_FILE" 2>/dev/null || true; }

fetch_usage() { # $1 = token. Prints the body on success; else returns a FETCH_* class.
  local out rc code body cached
  cached=$(_cache_read) && [ -n "$cached" ] && { printf '%s' "$cached"; return "$FETCH_OK"; }
  # No -f: a 4xx must still yield its STATUS so it can be classified. The body of a
  # failed response is deliberately never printed or logged (same rule as the Codex
  # poller) — only the code is.
  out=$(curl -sS --max-time 15 -w '\n%{http_code}' \
    -H "Authorization: Bearer $1" \
    -H "anthropic-beta: $OAUTH_BETA" \
    -H "Content-Type: application/json" \
    "$USAGE_ENDPOINT" 2>/dev/null); rc=$?
  # -w appends the status as the last line; tolerate its absence (an old curl, a
  # test stub) by falling back to the exit status alone rather than misreading the
  # body's last line as a status.
  code="${out##*$'\n'}"
  case "$code" in
    [0-9][0-9][0-9]) body="${out%$'\n'*}" ;;
    *) code=""; body="$out" ;;
  esac
  case "$code" in
    ''|000)  [ "$rc" -eq 0 ] && { _cache_write "$body"; printf '%s' "$body"; return "$FETCH_OK"; }
             return "$FETCH_NET" ;;
    2??)     _cache_write "$body"; printf '%s' "$body"; return "$FETCH_OK" ;;
  esac
  # The status is useful in the launchd log; the response BODY never is (and could
  # carry account detail), so only the code is ever emitted.
  echo "usage endpoint returned HTTP $code" >&2
  case "$code" in
    401|403) return "$FETCH_AUTH" ;;
    429)     return "$FETCH_RATE" ;;
    5??)     return "$FETCH_SERVER" ;;
    *)       return "$FETCH_HTTP" ;;
  esac
}

# ISO8601 -> epoch seconds (BSD/macOS date). Handles Z, +00:00, fractional secs.
iso_to_epoch() {
  local iso="$1"
  if [ -z "$iso" ] || [ "$iso" = "null" ]; then echo ""; return; fi
  iso=$(printf '%s' "$iso" | sed -E 's/\.[0-9]+//; s/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')
  date -j -f "%Y-%m-%dT%H:%M:%S%z" "$iso" +%s 2>/dev/null || echo ""
}

# epoch -> compact "in" duration: "now" | "37m" | "4h 12m" | "2d 3h"
humanize_until() {
  local target="$1" now diff d h m
  [ -n "$target" ] || { echo "?"; return; }
  now=$(date +%s); diff=$(( target - now ))
  [ "$diff" -gt 0 ] || { echo "now"; return; }
  d=$(( diff/86400 )); h=$(( (diff%86400)/3600 )); m=$(( (diff%3600)/60 ))
  if   [ "$d" -gt 0 ]; then echo "${d}d ${h}h"
  elif [ "$h" -gt 0 ]; then echo "${h}h ${m}m"
  else echo "${m}m"; fi
}

# elapsed seconds -> compact age: "<1m" | "12m" | "1h 5m" | "2d 3h"
humanize_age() {
  local s="${1:-0}" d h m
  case "$s" in ''|*[!0-9]*) echo "?"; return ;; esac
  d=$(( s/86400 )); h=$(( (s%86400)/3600 )); m=$(( (s%3600)/60 ))
  if   [ "$d" -gt 0 ]; then echo "${d}d ${h}h"
  elif [ "$h" -gt 0 ]; then echo "${h}h ${m}m"
  elif [ "$m" -gt 0 ]; then echo "${m}m"
  else echo "<1m"; fi
}

# The detail segment of a meter row. Fresh: "4% (1h 53m)". Grace paint: "4% · 12m
# old". The reset countdown is DROPPED while stale, and not because it went wrong —
# resets_at is absolute, so it stays correct. The row has one narrow right-hand
# column, and between "when this window resets" and "how old this number is", only
# the second one can mislead you into thinking you have headroom you spent. So the
# age takes the space, and the row stays the same width it always was.
meter_detail() { # $1 = pct, $2 = parenthesized inner text when fresh
  if [ -n "$STALE_AGE" ]; then printf '%s%% · %s old' "$1" "$(humanize_age "$STALE_AGE")"
  else printf '%s%% (%s)' "$1" "$2"; fi
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
  _paint "$LABEL_5H" "$LABEL_5H |⚠ ${reason}|" >/dev/null 2>&1 || true
  _paint "$LABEL_7D" "$LABEL_7D |⚠ ${reason}|" >/dev/null 2>&1 || true
  [ "$MODEL_METER" = 1 ] && _paint "$LABEL_M7D" "$LABEL_M7D |⚠ ${reason}|" >/dev/null 2>&1
  _paint "$LABEL_SPEND" "$LABEL_SPEND |⚠ ${reason}|" >/dev/null 2>&1 || true
  # Drop any stale native bar so the "⚠ offline" title shows through (else the
  # sidebar keeps drawing the last good ProgressView on top of an offline title).
  _clear_progress "$LABEL_5H"; _clear_progress "$LABEL_7D"
  [ "$MODEL_METER" = 1 ] && _clear_progress "$LABEL_M7D"
  _clear_progress "$LABEL_SPEND"
  return 0
}

# The endpoint also returns a modern, self-describing `limits[]` array alongside the
# legacy top-level buckets: {kind, group, percent, severity, resets_at, scope}. The
# two existing meters deliberately keep reading five_hour/seven_day — that path is
# proven and adding a feature must not put a working meter at risk — so this reads
# `limits[]` ONLY for the per-model row, which has no legacy equivalent.
#
# NOTE the trap this walks past: `seven_day_opus` / `seven_day_sonnet` exist as
# top-level keys and are null here. Per CLAUDE.md, an empty read is never evidence
# of absence — the proof that per-model data is live is a non-null weekly_scoped
# row, which is what this parses. Never hardcode a model name: scope.model.id is
# null, so display_name is the only handle, and it differs per account.
# Prints "pct<TAB>resets_at<TAB>model_name", or nothing when there is no such row.
scoped_weekly() { # $1 = json
  printf '%s' "$1" | jq -r '
    (.limits // [])
    | map(select((.kind == "weekly_scoped") and ((.percent | type) == "number")))
    | first // empty
    | [ (.percent | tostring),
        (.resets_at // ""),
        (.scope.model.display_name // "model") ]
    | @tsv' 2>/dev/null
}

# `spend` is the account's extra-usage (overage) budget. It carries BOTH a used
# amount and a limit — unlike a bare credit balance, which is why the Amp `$`
# balance is deliberately not metered — so it has an honest 0-100% bar, and it even
# ships its own `percent`. (`extra_usage.utilization` sitting right next to it is
# null: read the wrong one and you'd conclude the data isn't there. Same trap as
# seven_day_opus.) Prints "pct<TAB>used_minor<TAB>limit_minor<TAB>exponent<TAB>currency",
# or nothing when the account has no such budget.
spend_row() { # $1 = json
  printf '%s' "$1" | jq -r '
    (.spend // empty)
    | select((.enabled // true) != false)
    | select((.used.amount_minor | type) == "number")
    | select((.limit.amount_minor | type) == "number")
    | select(.limit.amount_minor > 0)
    | [ ((.percent // 0) | tostring),
        (.used.amount_minor | tostring),
        (.limit.amount_minor | tostring),
        ((.used.exponent // 2) | tostring),
        (.used.currency // "") ]
    | @tsv' 2>/dev/null
}

# minor units → display string. Never GUESS a symbol for a currency we don't know:
# an unrecognised code is printed as the code itself, which is unambiguous
# everywhere. ASCII-led output is not possible here (the symbol leads), which is
# fine — the coalescer rule applies to the progress LABEL, and that starts with the
# percentage.
fmt_money() { # $1 = amount_minor  $2 = exponent  $3 = currency code
  local m="${1:-0}" e="${2:-2}" sym div=1 i=0
  case "$m" in ''|*[!0-9-]*) m=0 ;; esac
  [ "$m" -lt 0 ] && m=0
  case "$e" in ''|*[!0-9]*) e=2 ;; esac
  case "$3" in
    EUR) sym="€" ;; USD) sym="$" ;; GBP) sym="£" ;;
    "")  sym="" ;;
    *)   sym="$3 " ;;
  esac
  while [ "$i" -lt "$e" ]; do div=$((div * 10)); i=$((i + 1)); done
  if [ "$e" -gt 0 ]; then printf '%s' "$sym"; printf "%d.%0${e}d" "$((m / div))" "$((m % div))"
  else printf '%s%d' "$sym" "$m"; fi
}

# pull a bucket field, snake_case w/ camelCase fallback
bucket_field() { # $1=json $2=bucket_snake $3=bucket_camel $4=field_snake $5=field_camel
  printf '%s' "$1" | jq -r --arg bs "$2" --arg bc "$3" --arg fs "$4" --arg fc "$5" \
    '((.[$bs] // .[$bc]) // {}) | (.[$fs] // .[$fc] // empty)' 2>/dev/null
}

# Coerce a validated numeric field to a clamped integer percent (0-100), rounded.
# Done entirely in jq so untrusted API text is NEVER interpolated into a shell/awk
# program. Schema validation in main rejects missing/non-numeric values before
# this runs, so an upstream shape change can never become a plausible 0% meter.
to_pct() { # $1 = raw value (may be empty, null, or non-numeric)
  jq -rn --arg v "${1:-}" '
    (($v | tonumber?) // 0)
    | if . < 0 then 0 elif . > 100 then 100 else . end
    | round' 2>/dev/null || printf '0'
}

# clamped integer percent (0-100) -> fraction (0..1) for `set-progress`. $1 comes
# from to_pct (already a sanitized int), so argjson is safe; guard to 0 otherwise.
to_frac() { jq -rn --argjson p "${1:-0}" '$p / 100' 2>/dev/null || printf '0'; }

main() {
  local mode="${1:---print}" token json

  # Provider gate (robustness): never crash or error-spam for a provider that's
  # turned off or not installed. A clean exit does not remove existing sentinels;
  # panel visibility is determined by sentinel presence and doctor flags leftovers. An
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
  local marker why frc
  if [ "$mode" = "--update" ] && _backoff_active; then
    # Still inside a 429 backoff window: don't call the endpoint at all. The row
    # is painted below from the grace body (or falls back to the marker), so the
    # age keeps counting up and the panel still tells the truth.
    frc="$FETCH_RATE"; json=""
  else
    json=$(fetch_usage "$token"); frc=$?
    if [ "$frc" -eq "$FETCH_OK" ]; then _backoff_clear
    elif [ "$frc" -eq "$FETCH_RATE" ] && [ "$mode" = "--update" ]; then _backoff_arm
    fi
  fi
  if [ "$frc" -ne "$FETCH_OK" ]; then
    # The marker rides the TITLE, so it stays short; `why` is the recovery, and it
    # lands in the launchd .err where the doctor now surfaces it.
    case "$frc" in
      "$FETCH_AUTH")   marker="auth"; why="the usage endpoint rejected the OAuth token (401/403). This poller only READS the token — Claude Code refreshes it — so run Claude Code once to mint a fresh one. If it persists, the unofficial endpoint may have changed." ;;
      "$FETCH_RATE")   marker="rate limit"; why="the usage endpoint is throttling this account (429) — raise StartInterval in ~/Library/LaunchAgents/com.cmux-claude-usage.plist and reload the job" ;;
      "$FETCH_SERVER") marker="api down"; why="api.anthropic.com returned a server error — transient, the next poll retries" ;;
      "$FETCH_NET")    marker="offline"; why="couldn't reach api.anthropic.com (offline, DNS, or timeout)" ;;
      *)               marker="offline"; why="the usage endpoint returned an unexpected HTTP status (logged above)" ;;
    esac
    local stale=""
    [ "$mode" = "--update" ] && stale=$(_stale_read)
    if [ -n "$stale" ]; then
      # Inside the grace window: re-enter the NORMAL render with the last good
      # body, so every row (bar, severity dot, model name, spend) is built by the
      # one code path that is already proven. Only the detail text changes, and
      # only because STALE_AGE is set. No freshness stamp, non-zero exit.
      json="$stale"; STALE_AGE=$(_cache_age); STALE_WHY="$why"
    else
      [ "$mode" = "--update" ] && mark_offline "$marker"
      die "usage request failed: $why"
    fi
  fi

  if [ "$mode" = "--raw" ]; then
    printf '%s\n' "$json" | jq . 2>/dev/null || printf '%s\n' "$json"
    return
  fi

  # The endpoint is unofficial. Validate BOTH required buckets and utilization
  # values before converting anything: jq's `empty` plus to_pct's safety fallback
  # used to turn a renamed or missing bucket into a believable 0% meter. Reset
  # timestamps are optional presentation data; malformed/missing values honestly
  # degrade to "?" without hiding a valid percentage. Keep camelCase fallbacks
  # because both shapes have existed.
  if ! printf '%s' "$json" | jq -e '
      def valid_bucket($snake; $camel):
        (.[$snake] // .[$camel]) as $b
        | (($b | type) == "object")
          and (($b.utilization | type) == "number");
      valid_bucket("five_hour"; "fiveHour")
      and valid_bucket("seven_day"; "sevenDay")
    ' >/dev/null 2>&1; then
    [ "$mode" = "--update" ] && mark_offline "no data"
    die "usage response is missing required five_hour/seven_day fields (endpoint schema changed?)"
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

  # Per-model weekly row (opt-in). Parsed for --print and --buckets regardless of
  # the flag so `--print` can TELL you the row exists and is worth opting into.
  local m_pct="" m_reset="" m_name="" m_epoch m_human="" scoped
  scoped=$(scoped_weekly "$json")
  if [ -n "$scoped" ]; then
    m_pct=$(printf '%s' "$scoped" | cut -f1)
    m_reset=$(printf '%s' "$scoped" | cut -f2)
    m_name=$(printf '%s' "$scoped" | cut -f3)
    m_pct=$(to_pct "$m_pct")
    m_epoch=$(iso_to_epoch "$m_reset"); m_human=$(humanize_until "$m_epoch")
  fi

  local sp_pct="" sp_used="" sp_limit="" sp_exp="" sp_cur="" sp_row sp_used_txt="" sp_limit_txt=""
  sp_row=$(spend_row "$json")
  if [ -n "$sp_row" ]; then
    sp_pct=$(printf '%s' "$sp_row" | cut -f1)
    sp_used=$(printf '%s' "$sp_row" | cut -f2)
    sp_limit=$(printf '%s' "$sp_row" | cut -f3)
    sp_exp=$(printf '%s' "$sp_row" | cut -f4)
    sp_cur=$(printf '%s' "$sp_row" | cut -f5)
    sp_pct=$(to_pct "$sp_pct")
    sp_used_txt=$(fmt_money "$sp_used" "$sp_exp" "$sp_cur")
    sp_limit_txt=$(fmt_money "$sp_limit" "$sp_exp" "$sp_cur")
  fi

  # Which labels have LIVE data, for cmux-sentinel-setup.sh. Same contract as the
  # Codex/Amp pollers: a POSITIVE answer may suppress a sentinel, silence never
  # may — every can't-tell path above already exited before reaching here.
  if [ "$mode" = "--buckets" ]; then
    printf '%s\n' "$LABEL_5H" "$LABEL_7D"
    [ "$MODEL_METER" = 1 ] && [ -n "$m_pct" ] && printf '%s\n' "$LABEL_M7D"
    # The spend sentinel is created whenever the account HAS an overage budget — a
    # stable account property, not the fluctuating balance. Gating creation on
    # "spent > 0" would mean the meter can only appear after someone re-runs setup,
    # i.e. exactly never, since nobody re-runs setup because they suspect a charge.
    # The ZERO case is handled at render time instead: the row paints a `none`
    # marker and the sidebar hides it.
    [ -n "$sp_pct" ] && printf '%s\n' "$LABEL_SPEND"
    return 0
  fi

  if [ "$mode" = "--print" ]; then
    echo "5h  ${fh_pct}%  · resets ${fh_human}  (${fh_reset})"
    echo "7d  ${sd_pct}%  · resets ${sd_human}  (${sd_reset})"
    if [ -n "$sp_pct" ]; then
      echo "spend ${sp_pct}%  · ${sp_used_txt} of ${sp_limit_txt} extra usage$([ "$sp_used" != 0 ] || printf '%s' '  [zero — the sidebar hides this row until you spend]')"
    fi
    if [ -n "$m_pct" ]; then
      echo "m7d ${m_pct}%  · resets ${m_human}  (${m_reset})  [${m_name}-scoped weekly cap$([ "$MODEL_METER" = 1 ] || printf '%s' '; set CLAUDE_MODEL_METER=1 to meter it')]"
    fi
    return
  fi

  if [ "$mode" = "--update" ]; then
    # Needs socketControlMode=automation, which the cmux socket server reads at
    # startup — a broken-pipe rejection here means cmux is still on cmuxOnly and
    # must be restarted to apply the mode.
    cmux ping &>/dev/null || die "cmux socket rejected (restart cmux to apply socketControlMode=automation)"
    # Write both display channels: native progress is the normal render; the title
    # carries the compact detail + unicode bar fallback and the stable label anchor.
    # The label leads and the optional severity dot trails.
    local fh_bar sd_bar fh_dot sd_dot fh_frac sd_frac fh_lbl sd_lbl
    fh_bar=$(make_bar "$fh_pct" 14); fh_dot=$(sev_dot "$fh_pct"); fh_frac=$(to_frac "$fh_pct")
    sd_bar=$(make_bar "$sd_pct" 14); sd_dot=$(sev_dot "$sd_pct"); sd_frac=$(to_frac "$sd_pct")
    # Compact progress label = pct + parenthesized countdown. The native bar already
    # communicates "usage", so repeating "resets" wastes the narrow right column.
    # ASCII-led so cmux's multibyte-prefix coalescer bug can't eat it; the optional
    # severity dot only ever trails.
    fh_lbl="$(meter_detail "$fh_pct" "$fh_human")${fh_dot}"
    sd_lbl="$(meter_detail "$sd_pct" "$sd_human")${sd_dot}"
    # _meter_write resolves each sentinel FRESH by title label (across windows), then
    # writes BOTH the title (unicode-bar fallback + anchor) and the native progress
    # bar. The `ping` gate passing does NOT guarantee the write lands (socket auth
    # could drop mid-run, a ref could go stale, or the sentinel could be gone), so
    # check each: rc 10 = no sentinel (tell the user to create it), rc 11 = cmux
    # rejected the rename (surface its stderr).
    # Report only what actually LANDED — "updated:" is a claim about writes, not
    # about the fetch.
    local painted=0 wrote=""
    paint_meter "$LABEL_5H" "$LABEL_5H |${fh_lbl}|${fh_bar}" "$fh_frac" "$fh_lbl" \
      && { painted=$((painted + 1)); wrote="${wrote}${LABEL_5H}=${fh_pct}% (${fh_human})  "; }
    paint_meter "$LABEL_7D" "$LABEL_7D |${sd_lbl}|${sd_bar}" "$sd_frac" "$sd_lbl" \
      && { painted=$((painted + 1)); wrote="${wrote}${LABEL_7D}=${sd_pct}% (${sd_human})  "; }
    if [ "$MODEL_METER" = 1 ]; then
      if [ -n "$m_pct" ]; then
        # The MODEL NAME gets its OWN title segment, never the anchor and never the
        # detail. Not the anchor because that has to be a static .hasPrefix literal
        # in the sidebar, and Anthropic can rename or re-scope the capped model at
        # will (scope.model.id is null — display_name is the only handle there is).
        # Not the detail because the sidebar draws the name as the ROW LABEL, where
        # every other meter shows one word ("session", "week", "threads"); prefixing
        # the detail instead rendered "model  Fable 15% (3d 2h)", saying it twice.
        # A 4th `|` segment survives a name containing spaces, which splitting the
        # detail on its first space would not.
        local m_bar m_dot m_frac m_lbl
        m_bar=$(make_bar "$m_pct" 14); m_dot=$(sev_dot "$m_pct"); m_frac=$(to_frac "$m_pct")
        m_lbl="$(meter_detail "$m_pct" "$m_human")${m_dot}"
        paint_meter "$LABEL_M7D" "$LABEL_M7D |${m_lbl}|${m_bar}|${m_name}" "$m_frac" "$m_lbl" \
          && { painted=$((painted + 1)); wrote="${wrote}${LABEL_M7D}=${m_pct}% (${m_human})  "; }
      else
        # Opted in, but this account currently has no model-scoped cap. Not an error
        # (Anthropic adds and drops these), so don't die — just make the row honest
        # instead of leaving yesterday's bar frozen on it.
        _paint "$LABEL_M7D" "$LABEL_M7D |n/a|" >/dev/null 2>&1 || true
        _clear_progress "$LABEL_M7D"
      fi
    fi
    if [ -n "$sp_pct" ]; then
      if [ "$sp_used" != 0 ]; then
        local sp_bar sp_dot sp_frac sp_lbl
        sp_bar=$(make_bar "$sp_pct" 14); sp_dot=$(sev_dot "$sp_pct"); sp_frac=$(to_frac "$sp_pct")
        sp_lbl="$(meter_detail "$sp_pct" "${sp_used_txt} of ${sp_limit_txt}")${sp_dot}"
        paint_meter "$LABEL_SPEND" "$LABEL_SPEND |${sp_lbl}|${sp_bar}" "$sp_frac" "$sp_lbl" \
          && { painted=$((painted + 1)); wrote="${wrote}${LABEL_SPEND}=${sp_used_txt}  "; }
      else
        # Nothing spent: paint the marker the SIDEBAR keys on to hide the row, and
        # drop the bar. Written every run so the row disappears by itself when the
        # month rolls over, exactly as it appears by itself on the first charge.
        _paint "$LABEL_SPEND" "$LABEL_SPEND |none|" >/dev/null 2>&1 || true
        _clear_progress "$LABEL_SPEND"
      fi
    else
      # No overage budget on this account at all.
      _paint "$LABEL_SPEND" "$LABEL_SPEND |none|" >/dev/null 2>&1 || true
      _clear_progress "$LABEL_SPEND"
    fi
    # A REJECTED rename is a broken write path (socket dropped, ref went stale), not
    # a missing row — never claim freshness for it.
    [ "${#REJECTED[@]}" -gt 0 ] && die "cmux rejected the rename for: ${REJECTED[*]}"
    [ "$painted" -gt 0 ] || die "no Claude sentinel workspace exists in any window — create them: ~/bin/cmux-sentinel-setup.sh (or see install.sh)"
    # A meter that landed IS fresh data, so stamp it even when a sibling sentinel is
    # gone. Freshness answers "is data flowing"; the doctor's own sentinel check
    # answers "is the meter installed". Conflating them is what made one closed
    # workspace read as a dead poller — and made the stale line's "run --update"
    # advice fail with the very same error.
    # A grace paint is NOT fresh data: no stamp, non-zero exit, and the reason in
    # the launchd .err where the doctor replays it. The doctor's own stale warning
    # (default 900s) therefore still fires WHILE the rows are still showing numbers
    # — which is the intended overlap: the panel stays useful, the health report
    # stays honest, and neither one has to guess what the other means.
    if [ -n "$STALE_AGE" ]; then
      die "usage request failed: $STALE_WHY — kept the last good data ($(humanize_age "$STALE_AGE") old) on ${wrote:+the meters}${wrote:-nothing}; rows fall back to the marker after ${STALE_GRACE}s"
    fi
    record_success || echo "WARN: meters updated, but couldn't record Claude freshness in $USAGE_STATE_DIR" >&2
    echo "updated: ${wrote%  }"
    # Still an error — a missing sentinel is a meter nobody can see.
    [ "${#MISSING[@]}" -gt 0 ] && die "no sentinel workspace for: ${MISSING[*]} — create it: ~/bin/cmux-sentinel-setup.sh (a sentinel is titled with its label, e.g. \"${MISSING[0]}\")"
    return 0
  fi

  die "unknown mode '$mode' (use --print | --raw | --update | --buckets)"
}

main "$@"
