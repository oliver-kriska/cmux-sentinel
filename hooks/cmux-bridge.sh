#!/bin/bash
# cmux-bridge.sh — Bridge Claude Code hooks to cmux sidebar status & notifications
# All calls are fire-and-forget; this script should never block Claude.
#
# cmux natively tracks Claude Code status via CMUX_CLAUDE_PID
# (Running/Needs input). This hook adds notifications, logging,
# progress bars, and error indicators.

# Skip if cmux CLI is missing or no live socket.
# cmux auto-discovers ~/.local/state/cmux/cmux.sock (and honors CMUX_SOCKET_PATH
# when set inside a cmux terminal). `ping` tests a LIVE socket — unlike `[ -S ]`,
# which passes on stale leftover socket files from older cmux versions.
command -v cmux &>/dev/null || exit 0
cmux ping &>/dev/null || exit 0

# Event name is passed as $1 on hot paths (PreToolUse) so we can skip jq;
# otherwise read it from the hook's JSON on stdin. Always drain stdin so the
# writer never sees EPIPE.
input=$(cat)
event="${1:-$(echo "$input" | jq -r '.hook_event_name // "unknown"')}"

case "$event" in
  SessionStart)
    source=$(echo "$input" | jq -r '.source // "startup"')
    cmux log --level info --source cc -- "Session $source" &>/dev/null
    ;;

  UserPromptSubmit)
    # Claude starts working on this workspace. Progress is the only channel a
    # custom sidebar can read, so we use it as the live "working" signal.
    # Cleared by Stop / StopFailure / SessionEnd (real turn endings only).
    cmux set-progress 0.5 --label "Working…" &>/dev/null
    ;;

  PreToolUse)
    # Re-assert "working" on every tool call. This is what makes the signal
    # robust: it survives mid-turn permission prompts (Notification) and
    # compaction, and it lights up sessions that started before this hook
    # existed — the next tool use flips them to "working" with no restart.
    # Registered async in settings.json, so it never blocks the tool.
    cmux set-progress 0.5 --label "Working…" &>/dev/null
    ;;

  Stop)
    cmux clear-progress &>/dev/null
    cmux notify --title "Claude Code" --body "Finished responding" &>/dev/null
    cmux log --level success --source cc -- "Response complete" &>/dev/null
    ;;

  StopFailure)
    # API errors, rate limits, auth failures
    error=$(echo "$input" | jq -r '.error // "unknown error"' | head -c 100)
    cmux clear-progress &>/dev/null
    cmux set-status cc_error "Error: $error" --icon exclamationmark.triangle --color "#FF3B30" &>/dev/null
    cmux notify --title "Claude Code Error" --body "$error" &>/dev/null
    cmux log --level error --source cc -- "Stop failure: $error" &>/dev/null
    # Auto-clear error status after 60 seconds
    (sleep 60 && cmux clear-status cc_error &>/dev/null) &
    ;;

  Notification)
    # Claude is waiting for the user (permission / idle prompt). Do NOT clear
    # progress here: a permission prompt fires MID-TURN while Claude is still
    # working, and clearing stranded the workspace showing "idle" until the
    # next user prompt (the Gettext false-idle bug). Real turn endings are
    # handled by Stop / StopFailure / SessionEnd; PreToolUse re-asserts on
    # resume. We only surface the OS notification here.
    title=$(echo "$input" | jq -r '.title // "Claude Code"')
    message=$(echo "$input" | jq -r '.message // ""' | head -c 120)
    cmux notify --title "$title" --body "$message" &>/dev/null
    ;;

  PostToolUseFailure)
    tool=$(echo "$input" | jq -r '.tool_name // "unknown"')
    error=$(echo "$input" | jq -r '.error // ""' | head -c 80)
    cmux log --level error --source cc -- "$tool: $error" &>/dev/null
    ;;

  PreCompact)
    cmux set-progress 0.5 --label "Compacting context..." &>/dev/null
    ;;

  PostCompact)
    cmux clear-progress &>/dev/null
    cmux log --level info --source cc -- "Context compacted" &>/dev/null
    ;;

  SessionEnd)
    cmux clear-status cc_state &>/dev/null
    cmux clear-status cc_error &>/dev/null
    cmux clear-progress &>/dev/null
    cmux log --level info --source cc -- "Session ended" &>/dev/null
    ;;
esac

exit 0
