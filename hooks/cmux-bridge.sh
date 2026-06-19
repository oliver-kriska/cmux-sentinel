#!/bin/bash
# cmux-bridge.sh — Bridge Claude Code hooks to the cmux custom sidebar.
# All calls are fire-and-forget; this script must never block Claude.
#
# WORKING-STATE CHANNEL: cmux does NOT pass `progress`/`description`/`color` to
# custom-sidebar data on this build (proven by in-sidebar probe — progN=0). The
# ONLY field that reaches the sidebar is the TITLE. So agent activity rides a
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
#   <pid>              — a live working session (touched each turn)
#   .compacting.<pid>  — that session is compacting right now
#   .waiting.<pid>     — that session is blocked on the user right now
#   .marked            — fast-path flag: title already carries the ⚡ work marker
# Dead sessions are reaped by PID liveness (kill -0), so a crashed/zombie agent
# can't strand a marker. One agent's Stop never clears another's. Codex can reuse
# the same set via `cmux hooks codex` pointed at this script.
#
# KNOWN EDGE (matches upstream #4389/#2488): an Esc-interrupted but still-ALIVE
# session fires no Stop hook, so its ⚡ lingers until the next turn re-asserts or
# a real Stop clears it. PID-liveness reaps crashes, not interrupted-alive turns.

command -v cmux &>/dev/null || exit 0
cmux ping &>/dev/null || exit 0

input=$(cat)
event="${1:-$(echo "$input" | jq -r '.hook_event_name // "unknown"')}"

WORKMARK="⚡"
COMPMARK="⏳"
WAITMARK="❓"
WORKROOT="${TMPDIR:-/tmp}/cmux-sentinel-work"

_ws()    { printf '%s' "${CMUX_WORKSPACE_ID:-}"; }
_sess()  { printf '%s' "${CMUX_CLAUDE_PID:-$PPID}"; }
_alive() { kill -0 "$1" 2>/dev/null; }

# The .marked fast-path flag is trusted only while FRESH (< TTL old). This bounds
# how long a desync survives if the title is changed OUT from under the bridge
# (manual rename, cmux restart re-persisting an old title): the hot path stays
# cheap (skips the ~44ms title read) for TTL seconds, then re-verifies and
# self-heals. stat: GNU (-c) first, then BSD/macOS (-f) — runtime is macOS but the
# offline harness runs on Linux CI, and the numeric guard rejects either's garbage.
_MARK_TTL=30
_marked_fresh() {
  local m="$1/.marked" mt now
  [ -f "$m" ] || return 1
  mt=$(stat -c %Y "$m" 2>/dev/null || stat -f %m "$m" 2>/dev/null) || return 1
  case "$mt" in '' | *[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ $((now - mt)) -lt "$_MARK_TTL" ]
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

# Desired marker for a workspace dir, reaping dead PIDs as a side effect.
# Precedence: compacting > waiting > working > none.
_desired_mark() {
  local dir="$1" f pid live=0 comp=0 wait=0
  [ -d "$dir" ] || { printf ''; return 0; }
  for f in "$dir"/.compacting.*; do
    [ -e "$f" ] || continue
    pid="${f##*.compacting.}"
    if _alive "$pid"; then comp=1; else rm -f "$f"; fi
  done
  for f in "$dir"/.waiting.*; do
    [ -e "$f" ] || continue
    pid="${f##*.waiting.}"
    if _alive "$pid"; then wait=1; else rm -f "$f"; fi
  done
  for f in "$dir"/*; do # non-dotfiles only → working session pids
    [ -e "$f" ] || continue
    pid="${f##*/}"
    if _alive "$pid"; then live=1; else rm -f "$f"; fi
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
    cmux log --level info --source cc -- "Session $src" &>/dev/null
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
    cmux log --level info --source cc -- "Compacting context" &>/dev/null
    ;;

  PostCompact)
    _clear_compacting
    cmux log --level info --source cc -- "Context compacted" &>/dev/null
    ;;

  Stop)
    _clear_working
    cmux notify --title "Claude Code" --body "Finished responding" &>/dev/null
    cmux log --level success --source cc -- "Response complete" &>/dev/null
    ;;

  StopFailure)
    # Don't decrement on a (usually transient) failure: a retry re-asserts via
    # PreToolUse, and a truly-dead session is reaped by PID liveness. Just surface it.
    error=$(echo "$input" | jq -r '.error // "unknown error"' | head -c 100)
    cmux set-status cc_error "Error: $error" --icon exclamationmark.triangle --color "#FF3B30" &>/dev/null
    cmux notify --title "Claude Code Error" --body "$error" &>/dev/null
    cmux log --level error --source cc -- "Stop failure: $error" &>/dev/null
    (sleep 60 && cmux clear-status cc_error &>/dev/null) &
    ;;

  Notification)
    # MID-TURN block (a permission prompt) → flip to ❓ so the row stops claiming
    # "Working…". The idle "waiting for your input" notice that fires after Claude
    # has already finished is gated out by _notify_waiting (no live turn). Either
    # way, surface the OS notification. Known minor lag: a permission prompt
    # approved into a long-running tool keeps ❓ until that tool's next hook fires.
    _notify_waiting
    title=$(echo "$input" | jq -r '.title // "Claude Code"')
    message=$(echo "$input" | jq -r '.message // ""' | head -c 120)
    cmux notify --title "$title" --body "$message" &>/dev/null
    ;;

  PostToolUseFailure)
    tool=$(echo "$input" | jq -r '.tool_name // "unknown"')
    error=$(echo "$input" | jq -r '.error // ""' | head -c 80)
    cmux log --level error --source cc -- "$tool: $error" &>/dev/null
    ;;

  SessionEnd)
    cmux clear-status cc_error &>/dev/null
    _clear_working
    cmux log --level info --source cc -- "Session ended" &>/dev/null
    ;;
esac

exit 0
