#!/bin/bash
# zed-bridge.sh — offline state-machine test for hooks/zed-bridge.sh.
#
# Points the OSC sink at a file (ZED_SENTINEL_TTY) and the FILE sink at a temp dir,
# pins the base title (ZED_SENTINEL_TITLE), then drives the bridge through every
# lifecycle and asserts BOTH the emitted terminal-title marker and the JSON status
# file. No cmux, no real terminal — runs in CI on Linux too.
#
# Run:  make test   (or:  bash tests/zed-bridge.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${BRIDGE:-$HERE/../hooks/zed-bridge.sh}"
[ -f "$BRIDGE" ] || { echo "bridge not found: $BRIDGE" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zed-bridge-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

TTY="$ROOT/tty"; STATE="$ROOT/state"
# ZED_SENTINEL=1 is the opt-in master gate; the lifecycle tests need it enabled.
export ZED_SENTINEL=1 ZED_SENTINEL_TTY="$TTY" ZED_SENTINEL_STATE_DIR="$STATE" ZED_SENTINEL_TITLE="TEST"
P='{"session_id":"S1"}'                    # base payload (fixed session key)

pass=0; fail=0
# last OSC title emitted: BEL-split the stream, drop everything up to the ]2; intro.
osc()   { tr '\007' '\n' <"$TTY" 2>/dev/null | sed -n 's/.*]2;//p' | tail -1; }
jstate(){ jq -r '.state' "$STATE/S1.json" 2>/dev/null; }
fire()  { : >"$TTY"; printf '%s' "${2:-$P}" | bash "$BRIDGE" "$1"; }
ck()    { if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
          else fail=$((fail + 1)); printf '  ✗ %s — got [%s] want [%s]\n' "$1" "$2" "$3"; fi; }

echo "A: full working lifecycle (title marker + JSON state)"
fire SessionStart;                                      ck "SessionStart → clean tab" "$(osc)" "TEST"
ck "SessionStart → no JSON"                              "$(jstate)" ""
fire UserPromptSubmit;                                   ck "UserPromptSubmit → ⚡"    "$(osc)" "⚡ TEST"
ck "  …JSON state working"                              "$(jstate)" "working"
fire PreToolUse '{"session_id":"S1","tool_name":"Edit"}';ck "PreToolUse(Edit) → ⚡"    "$(osc)" "⚡ TEST"
fire PreCompact;                                         ck "PreCompact → ⏳"          "$(osc)" "⏳ TEST"
ck "  …JSON state compacting"                           "$(jstate)" "compacting"
fire PostCompact;                                        ck "PostCompact → ⚡"         "$(osc)" "⚡ TEST"
fire Stop;                                               ck "Stop → idle tab"         "$(osc)" "TEST"
ck "  …JSON removed on idle"                            "$(jstate)" ""

echo "B: waiting-on-you (question / plan)"
fire UserPromptSubmit
fire PreToolUse '{"session_id":"S1","tool_name":"AskUserQuestion"}'
ck "AskUserQuestion → ❓"                               "$(osc)" "❓ TEST"
ck "  …JSON state waiting"                              "$(jstate)" "waiting"
fire PreToolUse '{"session_id":"S1","tool_name":"ExitPlanMode"}'
ck "ExitPlanMode → ❓"                                  "$(osc)" "❓ TEST"
fire UserPromptSubmit;                                   ck "user replied → ⚡"        "$(osc)" "⚡ TEST"
fire Stop

echo "C: Notification gating (mid-turn asks; idle notice ignored)"
fire UserPromptSubmit                                   # live turn in flight
fire Notification;                                       ck "mid-turn Notification → ❓" "$(osc)" "❓ TEST"
fire Stop                                                # turn ends
fire Notification;                                       ck "idle Notification → no paint" "$(osc)" ""
ck "  …still no JSON after idle notice"                 "$(jstate)" ""

echo "D: sink toggles"
fire Stop; rm -f "$STATE/S1.json"                       # clean slate
: >"$TTY"; printf '%s' "$P" | ZED_SENTINEL_OSC=0 bash "$BRIDGE" UserPromptSubmit
ck "ZED_SENTINEL_OSC=0 → no title emitted"             "$(osc)" ""
ck "  …but JSON still written"                          "$(jstate)" "working"
fire Stop; rm -f "$STATE/S1.json"
: >"$TTY"; printf '%s' "$P" | ZED_SENTINEL_FILE=0 bash "$BRIDGE" UserPromptSubmit
ck "ZED_SENTINEL_FILE=0 → title still painted"         "$(osc)" "⚡ TEST"
ck "ZED_SENTINEL_FILE=0 → no JSON written"             "$(jstate)" ""

echo "E: opt-in master gate (default disabled)"
fire Stop; rm -f "$STATE/S1.json"; : >"$TTY"
printf '%s' "$P" | env -u ZED_SENTINEL bash "$BRIDGE" UserPromptSubmit   # gate unset → no-op
ck "ZED_SENTINEL unset → no title painted"             "$(osc)" ""
ck "ZED_SENTINEL unset → no JSON written"              "$(jstate)" ""
: >"$TTY"; printf '%s' "$P" | ZED_SENTINEL=0 bash "$BRIDGE" UserPromptSubmit  # explicit 0 → no-op
ck "ZED_SENTINEL=0 → no title painted"                 "$(osc)" ""

echo
echo "zed-bridge: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
