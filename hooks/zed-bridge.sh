#!/bin/bash
# zed-bridge.sh — Bridge Claude Code hooks to Zed (and any OSC-title terminal).
# The Zed counterpart of hooks/cmux-bridge.sh. All calls are fire-and-forget;
# this script must never block Claude, and it has NO cmux dependency.
#
# WHY THIS EXISTS: in Zed the user runs each agent as a TERMINAL process (not as a
# Zed ACP thread). Zed has no writable "workspace title" channel like cmux, but its
# terminal HONOURS the OSC-2 title escape (`\e]2;…\a`) and shows it on the tab. So
# agent activity rides a STATIC marker at the FRONT of the terminal-tab title, the
# same vocabulary as the cmux sidebar:
#
#   ⚡  working    — this session is mid-turn
#   ⏳  compacting — this session is compacting its context (PreCompact→PostCompact)
#   ❓  waiting    — this session is BLOCKED on you (asked a question / needs a
#                   permission) and isn't actually running right now
#
# Precedence: compacting > waiting > working > idle. Waiting outranks working for
# the same reason as the cmux bridge: a session parked on AskUserQuestion /
# ExitPlanMode (or a MID-TURN permission Notification) is alive but needs YOU, so
# "Working…" would hide that. The idle "waiting for input" Notification that fires
# ~60s AFTER a turn ends is gated out (_notify_waiting checks a live-turn flag).
#
# TWO SINKS, independently toggleable:
#   OSC  (default on; ZED_SENTINEL_OSC=0 to disable) — set the terminal-tab title
#        on the controlling tty (ZED_SENTINEL_TTY, default /dev/tty). This is the
#        no-fork path: status shows on the Zed terminal tab today.
#   FILE (default on; ZED_SENTINEL_FILE=0 to disable) — write a per-session JSON
#        status file under ZED_SENTINEL_STATE_DIR. This is the data channel a
#        future native Zed "Workspaces" panel watches (via Fs::watch) to render a
#        per-project status row. See docs/zed-fork-research.md.
#
# UNLIKE the cmux bridge there is NO cross-session ref-counting: each agent owns its
# own terminal tab (its own tty), so per-session state is per-agent. A future panel
# aggregates by project by globbing the JSON files and reaping dead PIDs (kill -0).
#
# KNOWN EDGE: Claude Code also sets the terminal title itself, so between hook
# events it may transiently overwrite our marker; the marker re-asserts on the next
# event. Set a stable base with ZED_SENTINEL_TITLE to avoid churn if desired.

input=$(cat)
event="${1:-$(printf '%s' "$input" | jq -r '.hook_event_name // "unknown"' 2>/dev/null)}"

WORKMARK="⚡"
COMPMARK="⏳"
WAITMARK="❓"

_STATE_DIR="${ZED_SENTINEL_STATE_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/zed-sentinel}"

# Stable per-session key. Claude Code passes session_id in the hook payload; fall
# back to the parent pid so distinct shells never collide.
_sid() {
  local s
  s=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
  [ -n "$s" ] || s="pid$PPID"
  printf '%s' "$s"
}
sid=$(_sid)

_file_on() { [ "${ZED_SENTINEL_FILE:-1}" = 1 ]; }

# Repo/branch label for the tab, e.g. "cmux-sentinel:main". Overridable so it stays
# stable if the user prefers. Falls back to the cwd basename outside a repo.
_base_title() {
  if [ -n "${ZED_SENTINEL_TITLE:-}" ]; then printf '%s' "$ZED_SENTINEL_TITLE"; return 0; fi
  local root name branch
  root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$root" ]; then
    name=$(basename "$root")
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -n "$branch" ] && [ "$branch" != HEAD ]; then printf '%s:%s' "$name" "$branch"
    else printf '%s' "$name"; fi
  else
    printf '%s' "${PWD##*/}"
  fi
}

_project() { git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD"; }

# Emit the OSC-2 title to the terminal. Writes only if the target is openable (a
# real tty, or a test file); a missing controlling terminal is a silent no-op.
_emit_osc() {
  [ "${ZED_SENTINEL_OSC:-1}" = 0 ] && return 0
  local tty="${ZED_SENTINEL_TTY:-/dev/tty}"
  { : >>"$tty"; } 2>/dev/null || return 0
  printf '\033]2;%s\007' "$1" >>"$tty" 2>/dev/null || true
}

# Live-turn flag (internal bookkeeping, independent of the FILE sink): set while a
# turn is in flight, cleared on Stop/SessionEnd. Gates the idle Notification so a
# finished session never flips to ❓.
_turn_begin() { mkdir -p "$_STATE_DIR" 2>/dev/null; : >"$_STATE_DIR/.turn.$sid"; }
_turn_end()   { rm -f "$_STATE_DIR/.turn.$sid" 2>/dev/null; }
_turn_live()  { [ -f "$_STATE_DIR/.turn.$sid" ]; }

_write_json() { # <state> <marker> <base>
  local now; now=$(date +%s)
  mkdir -p "$_STATE_DIR" 2>/dev/null
  jq -cn \
    --arg s "$1" --arg m "$2" --arg t "$3" --arg proj "$(_project)" \
    --arg sid "$sid" --argjson pid "${PPID:-0}" --argjson now "$now" \
    '{state:$s,marker:$m,title:$t,project:$proj,session:$sid,pid:$pid,updated:$now}' \
    >"$_STATE_DIR/$sid.json" 2>/dev/null || true
}

# Apply a state word (working|waiting|compacting|idle): paint the tab title and
# sync the JSON status file. idle clears the marker and removes the JSON.
_apply() {
  local word="$1" marker base titled
  case "$word" in
    working)    marker="$WORKMARK" ;;
    waiting)    marker="$WAITMARK" ;;
    compacting) marker="$COMPMARK" ;;
    *)          marker="" ;;
  esac
  base=$(_base_title)
  if [ -n "$marker" ]; then titled="$marker $base"; else titled="$base"; fi
  _emit_osc "$titled"
  _file_on || return 0
  if [ -n "$marker" ]; then _write_json "$word" "$marker" "$base"
  else rm -f "$_STATE_DIR/$sid.json" 2>/dev/null; fi
}

case "$event" in
  SessionStart)
    _apply idle ;;                           # clean tab on a fresh session

  UserPromptSubmit)
    _turn_begin; _apply working ;;

  PreToolUse)
    # AskUserQuestion / ExitPlanMode block on the user the moment they're invoked,
    # so flip straight to ❓ (still a live turn — keep the turn flag). Every other
    # tool is real work.
    tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)
    case "$tool" in
      AskUserQuestion | ExitPlanMode) _turn_begin; _apply waiting ;;
      *)                              _turn_begin; _apply working ;;
    esac ;;

  PreCompact)  _turn_begin; _apply compacting ;;
  PostCompact) _apply working ;;             # turn resumes; Stop will clear it

  Notification)
    # MID-TURN permission prompt → ❓, but ONLY if a turn is live. The idle
    # "waiting for your input" notice (fires ~60s after Stop) has no live turn and
    # is ignored, so a finished tab never flips to ❓.
    _turn_live && _apply waiting ;;

  Stop | SessionEnd)
    _turn_end; _apply idle ;;

  # StopFailure is usually transient (a retry re-asserts via PreToolUse); leave the
  # marker as-is rather than flapping the tab.
esac

exit 0
