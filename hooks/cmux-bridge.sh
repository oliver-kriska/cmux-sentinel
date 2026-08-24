#!/bin/bash
# cmux-bridge.sh — Bridge Claude Code hooks to the cmux custom sidebar.
# All calls are fire-and-forget; this script must never block Claude.
#
# WORKING-STATE CHANNEL: agent activity rides the TITLE, and that is a PERSISTENCE
# + PRECEDENCE choice, not a channel limit — `progress`/`description`/`color` do
# all reach custom-sidebar data (re-probed 2026-07-20; the older "they don't" note
# here was wrong, it read workspaces where they were simply never set). The title
# is used because it survives restarts, is what `resolve_ref` anchors on, and
# collapses three mutually-exclusive states into one ordered slot. cmux's own
# `set-status` pills are NOT an option: they never reach a custom sidebar at all.
# So agent activity rides a
# STATIC marker kept at the FRONT of the workspace title; the sidebar detects it
# (`title.hasPrefix(...)`), styles the row, and strips the glyph for display:
#
#   ⚡  working    — an agent is mid-turn
#   ⏳  compacting — an agent is compacting its context (PreCompact→PostCompact)
#   ❓  waiting    — an agent is BLOCKED on you (asked a question / needs a
#                   permission) and isn't actually running right now
#
# Precedence: compacting > waiting > working. Waiting outranks working because a
# session that asked AskUserQuestion / ExitPlanMode (or hit a MID-TURN permission
# Notification) is alive but parked on YOU — showing it as "Working…" would hide
# that it needs an answer. (The idle "waiting for input" Notification that fires
# ~60s AFTER a turn ends is gated out — see _notify_waiting — so a finished
# workspace never flips to ❓.) Compacting still wins (it's a transient busy state).
# The marker is STATIC by design: an animated/spinner glyph in the title floods
# cmux's title coalescer and freezes the sidebar (upstream #6291). cmux trims a
# leading zero-width space, so the marker is visible — it shows in cmux's tab bar
# too. All three are single Unicode scalars so .hasPrefix/.split stay safe.
#
# MULTIPLE AGENTS per workspace are REFERENCE-COUNTED via per-workspace state
# files under $WORKROOT/<workspace_id>/:
#   <pid>              — a live working session (touched each turn; expires, below)
#   .compacting.<pid>  — that session is compacting right now
#   .waiting.<pid>     — that session is blocked on the user right now
#   .marked            — fast-path flag: title already carries the ⚡ work marker
# Dead sessions are reaped by PID liveness (kill -0), so a crashed/zombie agent
# can't strand a marker. One agent's Stop never clears another's. Codex can reuse
# the same set via `cmux hooks codex` pointed at this script.
#
# STALENESS: liveness alone is NOT enough. `kill -0` reaps CRASHES, but says
# nothing about a turn that ended without ever firing Stop — an Esc-interrupted
# but still-ALIVE session (upstream #4389/#2488), or an adapter whose host
# process outlives the turn. The latter bit for real: Amp's plugin runtime is one
# process per amp SESSION, not per turn, so an abandoned amp thread kept a ⚡
# pinned on a workspace for DAYS while `kill -0` truthfully answered "alive" and
# every SessionStart reconcile faithfully re-asserted it. So a working pid file
# must also be FRESH: _set_working touches it on every turn event, so one left
# untouched for _WORK_TTL seconds belongs to a turn that is over, and gets reaped.
# Compacting flags expire the same way (PreCompact→PostCompact is bounded by
# minutes). `.waiting.<pid>` deliberately does NOT expire — nothing refreshes it
# while a session sits blocked on YOU, and "needs you" is the last signal that
# should vanish on a timer. Tune with CMUX_SENTINEL_WORK_TTL (0 → pure liveness).

# Capability query for adapters that may be newer than the installed bridge. It
# intentionally runs before the cmux/socket gates and returns a token, not merely
# exit 0: older bridges ignore unknown events and also exit successfully.
if [ "${1:-}" = "--capabilities" ]; then
  printf '%s\n' "protocol=2 stop-failure-final"
  exit 0
fi

command -v cmux &>/dev/null || exit 0
cmux ping &>/dev/null || exit 0

input=$(cat)
event="${1:-$(echo "$input" | jq -r '.hook_event_name // "unknown"')}"

WORKMARK="⚡"
COMPMARK="⏳"
WAITMARK="❓"
WORKROOT="${TMPDIR:-/tmp}/cmux-sentinel-work"

# AGENT-AGNOSTIC IDENTITY. The state machine below is not Claude-specific — the
# markers, ref-counting and precedence apply to any agent that can emit these
# events. Three knobs let another agent's adapter (hooks/amp-bridge.ts, or
# `cmux hooks codex` pointed here) reuse it verbatim, sharing ONE $WORKROOT so
# co-tenant agents in the same workspace ref-count against each other correctly:
#   CMUX_SENTINEL_SESSION_PID   this session's pid (liveness/reap key)
#   CMUX_SENTINEL_AGENT_LABEL   notification title
#   CMUX_SENTINEL_LOG_SOURCE    `cmux log --source` tag + status-key prefix
# Defaults keep Claude Code's existing behaviour byte-identical.
AGENT_LABEL="${CMUX_SENTINEL_AGENT_LABEL:-Claude Code}"
LOG_SOURCE="${CMUX_SENTINEL_LOG_SOURCE:-cc}"

_ws()    { printf '%s' "${CMUX_WORKSPACE_ID:-}"; }
_sess()  { printf '%s' "${CMUX_SENTINEL_SESSION_PID:-${CMUX_CLAUDE_PID:-$PPID}}"; }
_alive() { kill -0 "$1" 2>/dev/null; }

# mtime of $1 in epoch seconds, or FAIL when it can't be read. stat: GNU (-c)
# first, then BSD/macOS (-f) — runtime is macOS but the offline harness runs on
# Linux CI, and the numeric guard rejects either's garbage.
_mtime() {
  local mt
  mt=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null) || return 1
  case "$mt" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s' "$mt"
}

# The .marked fast-path flag is trusted only while FRESH (< TTL old). This bounds
# how long a desync survives if the title is changed OUT from under the bridge
# (manual rename, cmux restart re-persisting an old title): the hot path stays
# cheap (skips the ~44ms title read) for TTL seconds, then re-verifies and
# self-heals. Any doubt → not fresh, i.e. fall through to the cold path, which
# re-reads the title and is always correct.
_MARK_TTL=30
_marked_fresh() {
  local m="$1/.marked" mt
  [ -f "$m" ] || return 1
  mt=$(_mtime "$m") || return 1
  [ $(($(date +%s) - mt)) -lt "$_MARK_TTL" ]
}

# How long a working/compacting state file is trusted without a refresh. See the
# STALENESS note in the header for why liveness alone strands markers. Generous
# by default: _set_working only refreshes on turn EVENTS, and one tool call can
# legitimately run for a long time (a build, a full test suite). Overshooting
# costs a stale row for a while; undershooting drops ⚡ mid-turn until the next
# hook re-asserts it, so err long.
_WORK_TTL="${CMUX_SENTINEL_WORK_TTL:-3600}"

# True when $1 has not been touched for _WORK_TTL seconds → its turn is over.
# Every uncertain path (TTL disabled, non-numeric TTL, unreadable mtime) answers
# "not expired": the safe failure direction is keeping a marker we might reap,
# never reaping one belonging to a live turn.
_expired() {
  local mt
  [ "$_WORK_TTL" -gt 0 ] 2>/dev/null || return 1
  mt=$(_mtime "$1") || return 1
  [ $(($(date +%s) - mt)) -ge "$_WORK_TTL" ]
}

# Strip any leading activity marker (at most one is present).
_strip_marks() {
  local t="$1"
  t="${t#"$WORKMARK"}"
  t="${t#"$COMPMARK"}"
  t="${t#"$WAITMARK"}"
  printf '%s' "$t"
}

# Effective (displayed) title for a workspace uuid, matched BY ID. (current-workspace
# caller-resolution is unreliable from async hooks; list-workspaces + id is exact.)
_title_of() {
  cmux list-workspaces --id-format uuids 2>/dev/null \
    | grep -F -- "$1" | head -1 \
    | sed -E "s/^.*${1}[[:space:]]+//; s/[[:space:]]*\[selected\]\$//"
}

# Desired marker for a workspace dir, reaping dead AND stale entries as a side
# effect. Precedence: compacting > waiting > working > none.
_desired_mark() {
  local dir="$1" f pid live=0 comp=0 wait=0
  [ -d "$dir" ] || { printf ''; return 0; }
  for f in "$dir"/.compacting.*; do
    [ -e "$f" ] || continue
    pid="${f##*.compacting.}"
    if _alive "$pid" && ! _expired "$f"; then comp=1; else rm -f "$f"; fi
  done
  for f in "$dir"/.waiting.*; do # NO staleness check — see the header
    [ -e "$f" ] || continue
    pid="${f##*.waiting.}"
    if _alive "$pid"; then wait=1; else rm -f "$f"; fi
  done
  for f in "$dir"/*; do # non-dotfiles only → working session pids
    [ -e "$f" ] || continue
    pid="${f##*/}"
    if _alive "$pid" && ! _expired "$f"; then live=1; else rm -f "$f"; fi
  done
  if [ "$comp" = 1 ]; then printf '%s' "$COMPMARK"
  elif [ "$wait" = 1 ]; then printf '%s' "$WAITMARK"
  elif [ "$live" = 1 ]; then printf '%s' "$WORKMARK"
  else printf ''; fi
}

# Reconcile ONE workspace's title marker against its live state (single source of
# truth; used by every clear/heal path). Keeps .marked in sync for the hot path.
_reconcile_ws() {
  local ws="$1" dir="$WORKROOT/$1" desired t want
  desired=$(_desired_mark "$dir")
  t=$(_title_of "$ws")
  if [ -z "$t" ]; then
    [ -n "$desired" ] || rmdir "$dir" 2>/dev/null
    return 0
  fi
  want="${desired}$(_strip_marks "$t")"
  [ "$t" = "$want" ] || cmux rename-workspace --workspace "$ws" "$want" &>/dev/null
  if [ "$desired" = "$WORKMARK" ]; then : > "$dir/.marked"; else rm -f "$dir/.marked"; fi
  [ -n "$desired" ] || rmdir "$dir" 2>/dev/null
}

# Mark THIS session working (hot path: the .marked flag skips the title read on
# every turn after the first). Never overrides a compacting marker. Also clears
# this session's waiting flag — a fresh prompt or a (non-question) tool call means
# the user already responded, so we're running again.
_set_working() {
  local ws sess dir t; ws=$(_ws); [ -n "$ws" ] || return 0
  sess=$(_sess); dir="$WORKROOT/$ws"
  mkdir -p "$dir" 2>/dev/null; : > "$dir/$sess"
  rm -f "$dir/.waiting.$sess"                           # this session resumed → not waiting
  _marked_fresh "$dir" && return 0                     # hot path: trust a fresh flag
  t=$(_title_of "$ws"); [ -n "$t" ] || return 0
  case "$t" in "$COMPMARK"*) return 0 ;; esac          # compacting wins; recorded the pid
  case "$t" in "$WORKMARK"*) : > "$dir/.marked"; return 0 ;; esac
  # Title still shows ❓: don't downgrade a co-tenant agent that's STILL blocked —
  # only claim ⚡ once no live waiting session remains (cold path; re-derive).
  case "$t" in "$WAITMARK"*) [ "$(_desired_mark "$dir")" = "$WAITMARK" ] && return 0 ;; esac
  cmux rename-workspace --workspace "$ws" "${WORKMARK}$(_strip_marks "$t")" &>/dev/null
  : > "$dir/.marked"
}

# Out-of-window alert on the ❓ transition (OPT-IN, empty = off).
#
# This is the one moment worth interrupting someone for: an agent is alive but
# parked on YOU. Everything else — working, idle, finished — is passive status you
# read off the sidebar when you look, which is exactly why the ✅ "done" marker was
# rejected (see CLAUDE.md). So there is deliberately no notification for any other
# transition; adding one would make the alert ignorable, which costs you the ❓.
#
# Fires from _set_waiting AFTER its already-waiting guard, so you get exactly one
# alert per transition into ❓, not one per hook event.
#
# Contract: CMUX_SENTINEL_NOTIFY_CMD runs via `sh -c` with the workspace label as
# $1 and the event as $2, and CMUX_SENTINEL_WORKSPACE / _EVENT in the environment.
#   export CMUX_SENTINEL_NOTIFY_CMD='curl -sfd "$1 needs you" ntfy.sh/YOUR-TOPIC'
#
# DETACHED with output discarded, on purpose: this runs on the agent's hot path
# (a hook, before a tool call), so a notifier that blocks — curl to an unreachable
# host — or fails must never stall a turn or break the marker. Consequence to
# accept: a notifier that hangs forever leaks one process; keep it a quick fire.
NOTIFY_CMD="${CMUX_SENTINEL_NOTIFY_CMD:-}"
_notify() { # $1 = event  $2 = workspace label
  [ -n "$NOTIFY_CMD" ] || return 0
  ( CMUX_SENTINEL_EVENT="$1" CMUX_SENTINEL_WORKSPACE="$2" \
      sh -c "$NOTIFY_CMD" cmux-sentinel-notify "$2" "$1" >/dev/null 2>&1 & )
  return 0
}

# Mark THIS session waiting-on-you (asked a question / needs a permission): swap
# ⚡→❓. The session stays alive (its pid file remains) but is BLOCKED, so waiting
# outranks working until the user responds. Compacting still wins. No .marked
# fast-path: waiting is rare and self-heals via _set_working/_reconcile_ws.
_set_waiting() {
  local ws sess dir t; ws=$(_ws); [ -n "$ws" ] || return 0
  sess=$(_sess); dir="$WORKROOT/$ws"
  mkdir -p "$dir" 2>/dev/null
  : > "$dir/$sess"                                      # session is alive…
  : > "$dir/.waiting.$sess"                             # …but parked on the user
  rm -f "$dir/.marked"                                  # ⚡ fast-path no longer valid
  t=$(_title_of "$ws"); [ -n "$t" ] || return 0
  case "$t" in "$COMPMARK"* | "$WAITMARK"*) return 0 ;; esac  # compacting wins; already waiting
  cmux rename-workspace --workspace "$ws" "${WAITMARK}$(_strip_marks "$t")" &>/dev/null
  _notify waiting "$(_strip_marks "$t")"   # past the guard = a real transition into ❓
}

# Notification-gated waiting. The Notification hook fires for TWO unrelated things:
# a MID-TURN permission prompt (genuinely blocked → asking) AND the idle "waiting
# for your input" notice that arrives ~60s AFTER Claude already finished (Stop
# cleared the session → idle). Only the former is "asking", so flip to ❓ ONLY when
# a live turn is in flight — i.e. this session still has its working pid file
# (created on UserPromptSubmit/PreToolUse, removed by Stop). Without this gate, a
# finished/idle workspace wrongly flips to ❓ a minute after it's done.
_notify_waiting() {
  local ws sess; ws=$(_ws); [ -n "$ws" ] || return 0
  sess=$(_sess)
  [ -f "$WORKROOT/$ws/$sess" ] || return 0   # session already stopped → idle notice, ignore
  _set_waiting
}

# Mark THIS session compacting (swap ⚡→⏳; survives PostCompact via reconcile).
_set_compacting() {
  local ws sess dir t; ws=$(_ws); [ -n "$ws" ] || return 0
  sess=$(_sess); dir="$WORKROOT/$ws"
  mkdir -p "$dir" 2>/dev/null; : > "$dir/.compacting.$sess"
  rm -f "$dir/.marked"                                  # ⚡ fast-path no longer valid
  t=$(_title_of "$ws"); [ -n "$t" ] || return 0
  case "$t" in "$COMPMARK"*) return 0 ;; esac
  cmux rename-workspace --workspace "$ws" "${COMPMARK}$(_strip_marks "$t")" &>/dev/null
}

# This session finished compacting → drop its flag, re-derive (→ ⚡ if its turn
# continues, else idle).
_clear_compacting() {
  local ws; ws=$(_ws); [ -n "$ws" ] || return 0
  rm -f "$WORKROOT/$ws/.compacting.$(_sess)" 2>/dev/null
  _reconcile_ws "$ws"
}

# This session stopped → drop it (and any waiting flag) and re-derive the marker.
_clear_working() {
  local ws sess; ws=$(_ws); [ -n "$ws" ] || return 0
  sess=$(_sess)
  rm -f "$WORKROOT/$ws/$sess" "$WORKROOT/$ws/.waiting.$sess" "$WORKROOT/$ws/.marked" 2>/dev/null
  _reconcile_ws "$ws"
}

# Global self-heal: reconcile every known workspace (clears crash-stranded markers).
_reconcile_all() {
  local d
  [ -d "$WORKROOT" ] || return 0
  for d in "$WORKROOT"/*/; do [ -d "$d" ] || continue; _reconcile_ws "$(basename "$d")"; done
}

# Restart self-heal: $WORKROOT lives in $TMPDIR, which a reboot can wipe while a
# workspace TITLE still carries a persisted ⚡/⏳. _reconcile_all only visits
# existing WORKROOT dirs, so it can't see those orphans. Scan every title and
# strip a marker whose workspace has NO live session. One list-workspaces; only
# the (rare) marked rows do any work, so this stays cheap on SessionStart.
_sweep_orphan_marks() {
  local line id t
  cmux list-workspaces --id-format uuids 2>/dev/null | while IFS= read -r line; do
    case "$line" in *"$WORKMARK"* | *"$COMPMARK"* | *"$WAITMARK"*) : ;; *) continue ;; esac
    id=$(printf '%s' "$line" | grep -oE '[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}' | head -1)
    [ -n "$id" ] || continue
    t=$(printf '%s' "$line" | sed -E "s/^.*${id}[[:space:]]+//; s/[[:space:]]*\[selected\]\$//")
    case "$t" in "$WORKMARK"* | "$COMPMARK"* | "$WAITMARK"*) : ;; *) continue ;; esac
    [ -n "$(_desired_mark "$WORKROOT/$id")" ] && continue # has a live session → keep
    cmux rename-workspace --workspace "$id" "$(_strip_marks "$t")" &>/dev/null
    rm -rf "${WORKROOT:?}/$id" 2>/dev/null
  done
}

case "$event" in
  SessionStart)
    src=$(echo "$input" | jq -r '.source // "startup"')
    cmux log --level info --source "$LOG_SOURCE" -- "Session $src" &>/dev/null
    _reconcile_all       # re-derive markers for workspaces we still track
    _sweep_orphan_marks  # strip markers stranded by a $TMPDIR wipe (reboot)
    ;;

  UserPromptSubmit) _set_working ;;
  PreToolUse)
    # AskUserQuestion / ExitPlanMode block on the user the moment they're invoked,
    # so flip straight to ❓ instead of ⚡. Every other tool is real work.
    tool=$(echo "$input" | jq -r '.tool_name // ""')
    case "$tool" in
      AskUserQuestion | ExitPlanMode) _set_waiting ;;
      *) _set_working ;;
    esac
    ;;

  PreCompact)
    _set_compacting
    cmux log --level info --source "$LOG_SOURCE" -- "Compacting context" &>/dev/null
    ;;

  PostCompact)
    _clear_compacting
    cmux log --level info --source "$LOG_SOURCE" -- "Context compacted" &>/dev/null
    ;;

  Stop)
    _clear_working
    cmux notify --title "$AGENT_LABEL" --body "Finished responding" &>/dev/null
    cmux log --level success --source "$LOG_SOURCE" -- "Response complete" &>/dev/null
    ;;

  StopFailure)
    # Don't decrement on a (usually transient) failure: a retry re-asserts via
    # PreToolUse, and a truly-dead session is reaped by PID liveness. Just surface it.
    error=$(echo "$input" | jq -r '.error // "unknown error"' | head -c 100)
    cmux set-status "${LOG_SOURCE}_error" "Error: $error" --icon exclamationmark.triangle --color "#FF3B30" &>/dev/null
    cmux notify --title "$AGENT_LABEL Error" --body "$error" &>/dev/null
    cmux log --level error --source "$LOG_SOURCE" -- "Stop failure: $error" &>/dev/null
    (sleep 60 && cmux clear-status "${LOG_SOURCE}_error" &>/dev/null) &
    ;;

  StopFailureFinal)
    # Amp's agent.end(error) is terminal, unlike Claude Code's retryable
    # StopFailure. Report + clear in ONE ordered bridge process so two detached
    # adapter calls can never reorder and strand a working marker.
    error=$(echo "$input" | jq -r '.error // "unknown error"' | head -c 100)
    cmux set-status "${LOG_SOURCE}_error" "Error: $error" --icon exclamationmark.triangle --color "#FF3B30" &>/dev/null
    cmux notify --title "$AGENT_LABEL Error" --body "$error" &>/dev/null
    cmux log --level error --source "$LOG_SOURCE" -- "Stop failure: $error" &>/dev/null
    _clear_working
    (sleep 60 && cmux clear-status "${LOG_SOURCE}_error" &>/dev/null) &
    ;;

  Notification)
    # MID-TURN block (a permission prompt) → flip to ❓ so the row stops claiming
    # "Working…". The idle "waiting for your input" notice that fires after Claude
    # has already finished is gated out by _notify_waiting (no live turn). Either
    # way, surface the OS notification. Known minor lag: a permission prompt
    # approved into a long-running tool keeps ❓ until that tool's next hook fires.
    _notify_waiting
    title=$(echo "$input" | jq -r ".title // \"$AGENT_LABEL\"")
    message=$(echo "$input" | jq -r '.message // ""' | head -c 120)
    cmux notify --title "$title" --body "$message" &>/dev/null
    ;;

  PostToolUseFailure)
    tool=$(echo "$input" | jq -r '.tool_name // "unknown"')
    error=$(echo "$input" | jq -r '.error // ""' | head -c 80)
    cmux log --level error --source "$LOG_SOURCE" -- "$tool: $error" &>/dev/null
    ;;

  SessionEnd)
    cmux clear-status "${LOG_SOURCE}_error" &>/dev/null
    _clear_working
    cmux log --level info --source "$LOG_SOURCE" -- "Session ended" &>/dev/null
    ;;
esac

exit 0
