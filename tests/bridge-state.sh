#!/bin/bash
# bridge-state.sh — offline state-machine test for hooks/cmux-bridge.sh.
#
# Stubs `cmux` with a fake that serves list-workspaces from a title file and
# records renames, then drives the bridge through every activity lifecycle and
# asserts the resulting title marker. No real cmux needed, so this runs in CI on
# Linux too (the bridge's BSD `stat -f` path falls back to GNU `stat -c`).
#
# Run:  make test   (or:  bash tests/bridge-state.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${BRIDGE:-$HERE/../hooks/cmux-bridge.sh}"
[ -f "$BRIDGE" ] || { echo "bridge not found: $BRIDGE" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-bridge-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin"

# Fake cmux: ping ok; list-workspaces emits "<id>  <title>"; rename writes title.
cat > "$ROOT/bin/cmux" <<'FAKE'
#!/bin/bash
T="$BRIDGETEST/.title"
case "$1" in
  ping) exit 0 ;;
  list-workspaces) printf 'ws  %s  %s\n' "$FAKE_WS" "$(cat "$T" 2>/dev/null)"; exit 0 ;;
  rename-workspace)
    shift; title=""
    while [ $# -gt 0 ]; do case "$1" in --workspace) shift 2 ;; *) title="$1"; shift ;; esac; done
    printf '%s' "$title" > "$T"; exit 0 ;;
  *) exit 0 ;; # log/notify/set-status/clear-status → no-op
esac
FAKE
chmod +x "$ROOT/bin/cmux"

# UUID-shaped id so the orphan-sweep's UUID regex matches — assembled at runtime
# so no literal UUID lands in this file (the secret guard would flag one).
FAKE_WS="$(printf '%08d-%04d-%04d-%04d-%012d' 0 0 0 0 0)"
export BRIDGETEST="$ROOT" FAKE_WS CMUX_WORKSPACE_ID="$FAKE_WS"
export TMPDIR="$ROOT"
PATH="$ROOT/bin:$PATH"
WORKDIR="$ROOT/cmux-sentinel-work/$FAKE_WS"

pass=0; fail=0
title() { cat "$ROOT/.title" 2>/dev/null; }
fire()  { echo '{}' | CMUX_CLAUDE_PID="$2" bash "$BRIDGE" "$1"; }
# fire a PreToolUse carrying a tool_name (for the AskUserQuestion/ExitPlanMode path)
firet() { printf '{"tool_name":"%s"}' "$3" | CMUX_CLAUDE_PID="$2" bash "$BRIDGE" "$1"; }
ck()    { if [ "$(title)" = "$2" ]; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
          else fail=$((fail + 1)); printf '  ✗ %s — got [%s] want [%s]\n' "$1" "$(title)" "$2"; fi; }

sleep 300 & PID2=$!
trap 'kill "$PID2" 2>/dev/null; rm -rf "$ROOT"' EXIT
A=$$

echo "A: working → compact → resume → stop"
printf 'cmux-sentinel' > "$ROOT/.title"
fire PreToolUse  "$A"; ck "PreToolUse → ⚡"        "⚡cmux-sentinel"
fire PreToolUse  "$A"; ck "PreToolUse idempotent" "⚡cmux-sentinel"
fire PreCompact  "$A"; ck "PreCompact → ⏳"        "⏳cmux-sentinel"
fire PostCompact "$A"; ck "PostCompact → ⚡"       "⚡cmux-sentinel"
fire Stop        "$A"; ck "Stop → idle"           "cmux-sentinel"

echo "B: manual /compact while IDLE"
printf 'Scriptorium' > "$ROOT/.title"; rm -rf "$WORKDIR"
fire PreCompact  "$A"; ck "idle PreCompact → ⏳"   "⏳Scriptorium"
fire PostCompact "$A"; ck "idle PostCompact → idle" "Scriptorium"

echo "C: crash during compact (no PostCompact) → SessionStart reaps"
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
: > "$WORKDIR/.compacting.999999"; printf '⏳Gettext' > "$ROOT/.title"
fire SessionStart "$A"; ck "dead compacting pid reaped → idle" "Gettext"

echo "D: two agents, one stops, other keeps working"
printf 'multi' > "$ROOT/.title"; rm -rf "$WORKDIR"
fire PreToolUse "$A";    ck "A works → ⚡"          "⚡multi"
fire PreToolUse "$PID2"; ck "B works → ⚡"          "⚡multi"
fire Stop       "$A";    ck "A stops, B alive → ⚡" "⚡multi"
fire Stop       "$PID2"; ck "B stops → idle"       "multi"

echo "E: restart wiped \$TMPDIR but title kept ⚡ → SessionStart sweep strips it"
rm -rf "$WORKDIR"; printf '⚡orphan' > "$ROOT/.title"
fire SessionStart "$A"; ck "orphan marker (no live session) stripped → idle" "orphan"

echo "F: asking a question (AskUserQuestion) → ❓, answered → ⚡, stop → idle"
printf 'enaia' > "$ROOT/.title"; rm -rf "$WORKDIR"
fire  PreToolUse "$A";                  ck "working → ⚡"             "⚡enaia"
firet PreToolUse "$A" AskUserQuestion;  ck "AskUserQuestion → ❓"     "❓enaia"
firet PreToolUse "$A" ExitPlanMode;     ck "ExitPlanMode also → ❓"   "❓enaia"
fire  PreToolUse "$A";                  ck "answered, next tool → ⚡" "⚡enaia"
fire  Stop       "$A";                  ck "Stop → idle"             "enaia"

echo "G: MID-TURN Notification (permission prompt) → ❓, then resume → ⚡"
printf 'enaia' > "$ROOT/.title"; rm -rf "$WORKDIR"
fire PreToolUse   "$A"; ck "working → ⚡"                  "⚡enaia"
fire Notification "$A"; ck "permission prompt → ❓ (asking)" "❓enaia"
fire PreToolUse   "$A"; ck "user responded → ⚡"           "⚡enaia"
fire Stop         "$A"; ck "Stop → idle"                  "enaia"

echo "G2: idle Notification AFTER Stop must NOT flip a finished workspace to ❓"
printf 'enaia' > "$ROOT/.title"; rm -rf "$WORKDIR"
fire PreToolUse   "$A"; ck "working → ⚡"                  "⚡enaia"
fire Stop         "$A"; ck "Stop → idle"                  "enaia"
fire Notification "$A"; ck "idle 'waiting for input' notice ignored → still idle" "enaia"
fire Notification "$A"; ck "repeat idle notice still ignored → idle"              "enaia"

echo "H: compacting outranks a waiting flag"
printf 'enaia' > "$ROOT/.title"; rm -rf "$WORKDIR"
firet PreToolUse "$A" AskUserQuestion; ck "asks → ❓"           "❓enaia"
fire  PreCompact "$A";                 ck "compact wins → ⏳"   "⏳enaia"
fire  PostCompact "$A";                ck "after compact, still waiting → ❓" "❓enaia"

echo "I: restart wiped \$TMPDIR but title kept ❓ → SessionStart sweep strips it"
rm -rf "$WORKDIR"; printf '❓orphan' > "$ROOT/.title"
fire SessionStart "$A"; ck "orphan ❓ (no live session) stripped → idle" "orphan"

echo "J: two agents — A asks, B works → ❓ until A answers"
printf 'multi' > "$ROOT/.title"; rm -rf "$WORKDIR"
fire  PreToolUse "$A";                  ck "A works → ⚡"                  "⚡multi"
fire  PreToolUse "$PID2";               ck "B works → ⚡"                  "⚡multi"
firet PreToolUse "$A" AskUserQuestion;  ck "A asks → ❓ (outranks B work)" "❓multi"
fire  PreToolUse "$PID2";               ck "B works on, A still waiting → ❓" "❓multi"
fire  PreToolUse "$A";                  ck "A answered → ⚡ (B alive)"     "⚡multi"
fire  Stop "$A"; fire Stop "$PID2";     ck "both stop → idle"             "multi"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
