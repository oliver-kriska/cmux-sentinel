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

# Fake sleep for the bridge's ❓→❔ fade timer: record how long it was asked to
# wait, then fail, so the timer never fires mid-test (back-dating the flag and
# firing Reconcile drives the fade instead). The harness's own waits use the real
# binary, resolved before the stubs go on PATH.
REALSLEEP="$(command -v sleep)"
cat > "$ROOT/bin/sleep" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$BRIDGETEST/.slept"; exit 1
FAKE
chmod +x "$ROOT/bin/sleep"

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
# fire with an explicit staleness TTL ($3 seconds; 0 disables expiry)
firel() { echo '{}' | CMUX_CLAUDE_PID="$2" CMUX_SENTINEL_WORK_TTL="$3" bash "$BRIDGE" "$1"; }
# Back-date a state file well past any TTL. `-t CCYYMMDDhhmm` is the one form both
# BSD/macOS and GNU touch accept, so the K block needs no sleeps to age a file.
stale() { touch -t 200001010000 "$1"; }
ck()    { if [ "$(title)" = "$2" ]; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
          else fail=$((fail + 1)); printf '  ✗ %s — got [%s] want [%s]\n' "$1" "$(title)" "$2"; fi; }

"$REALSLEEP" 300 & PID2=$!
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

echo "K: turn ended without Stop while its process stayed ALIVE → staleness reaps it"
# The real-world bug: Amp's plugin runtime is one process per amp SESSION, not per
# turn, so an abandoned thread left a ⚡ pinned for days — kill -0 answered "alive"
# and every SessionStart reconcile faithfully re-asserted it. PID2 stands in for
# that long-lived host. Uses the SHIPPED default TTL, not a test-only short one.
printf 'Scribe' > "$ROOT/.title"; rm -rf "$WORKDIR"
fire PreToolUse  "$PID2"; ck "long-lived host works → ⚡"              "⚡Scribe"
stale "$WORKDIR/$PID2"
fire SessionStart "$A";   ck "abandoned turn (pid ALIVE, file stale) → idle" "Scribe"

echo "K2: a FRESH working file is never reaped (no over-eager expiry)"
printf 'Scribe' > "$ROOT/.title"; rm -rf "$WORKDIR"
fire PreToolUse   "$PID2"; ck "works → ⚡"                     "⚡Scribe"
fire SessionStart "$A";    ck "within TTL → ⚡ kept"           "⚡Scribe"
fire Stop         "$PID2"; ck "Stop → idle"                   "Scribe"

echo "K3: CMUX_SENTINEL_WORK_TTL=0 opts back out to pure PID liveness"
printf 'Scribe' > "$ROOT/.title"; rm -rf "$WORKDIR"
fire PreToolUse "$PID2"; ck "works → ⚡"                       "⚡Scribe"
stale "$WORKDIR/$PID2"
firel SessionStart "$A" 0; ck "TTL=0 → stale file still counts → ⚡" "⚡Scribe"
fire  Stop "$PID2";        ck "Stop → idle"                   "Scribe"

echo "K4: compaction that never finished (pid alive) expires → ⏳ reaped"
printf 'Gettext' > "$ROOT/.title"; rm -rf "$WORKDIR"
fire PreCompact "$PID2"; ck "compacting → ⏳"                  "⏳Gettext"
stale "$WORKDIR/.compacting.$PID2"
fire SessionStart "$A";  ck "stale compacting flag → idle"     "Gettext"

echo "K5: ❓ waiting must NOT expire — nothing refreshes it while you're away"
printf 'enaia' > "$ROOT/.title"; rm -rf "$WORKDIR"
firet PreToolUse "$PID2" AskUserQuestion; ck "asks → ❓"       "❓enaia"
stale "$WORKDIR/$PID2"; stale "$WORKDIR/.waiting.$PID2"
fire SessionStart "$A";  ck "blocked-on-you survives any age → ❓" "❓enaia"
fire Stop        "$PID2"; ck "Stop → idle"                    "enaia"

echo "L: ❓ notifier — opt-in, once per transition, and never able to break a hook"
# The notifier runs DETACHED on the agent's hot path, so every assertion here waits
# for the recorder file rather than assuming the child already ran.
NOTED="$ROOT/.notified"
notewait() { # $1 = expected line count; returns as soon as it is reached
  # 20s, not 5. _notify DETACHES and discards output on purpose (it runs on the
  # agent's hot path), so the test has no handle on the child and no way to make it
  # faster — waiting longer is the only correct move. 5s was enough on an idle Mac
  # and lost twice under `make ci` load, blocking a push both times; the wait costs
  # nothing when it passes, because it returns the moment the file appears.
  local i=0
  while [ "$i" -lt 100 ]; do
    # `<` on a missing file fails in the SHELL, before wc runs, so 2>/dev/null on
    # wc can't silence it — test existence first.
    [ -f "$NOTED" ] && [ "$(wc -l < "$NOTED")" -ge "$1" ] && return 0
    i=$((i + 1)); "$REALSLEEP" 0.2
  done
  return 1
}
cknote() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
           else fail=$((fail + 1)); printf '  ✗ %s — got [%s] want [%s]\n' "$1" "$2" "$3"; fi; }

printf 'enaia' > "$ROOT/.title"; rm -rf "$WORKDIR"; rm -f "$NOTED"
# shellcheck disable=SC2016  # $1/$2 belong to the notifier's `sh -c`, not to us
export CMUX_SENTINEL_NOTIFY_CMD='printf "%s|%s\n" "$1" "$2" >> '"$NOTED"
firet PreToolUse "$PID2" AskUserQuestion; ck "asks → ❓ (notifier armed)" "❓enaia"
notewait 1
cknote "notifier fires on the ❓ transition" "$(cat "$NOTED" 2>/dev/null)" "enaia|waiting"

# Still waiting: _set_waiting returns at its guard, so no second alert. This is the
# property that makes the alert worth keeping — one per transition, not per event.
firet PreToolUse "$PID2" AskUserQuestion
firet PreToolUse "$PID2" ExitPlanMode
"$REALSLEEP" 0.3
cknote "already-waiting fires no duplicate" "$(wc -l < "$NOTED" | tr -d ' ')" "1"

# Resume, then block again → a genuinely new transition, so a second alert is right.
fire Stop "$PID2"; ck "Stop → idle" "enaia"
firet PreToolUse "$PID2" AskUserQuestion; ck "asks again → ❓" "❓enaia"
notewait 2
cknote "a NEW transition alerts again" "$(wc -l < "$NOTED" | tr -d ' ')" "2"

# A notifier that fails must not cost the marker — it is on the hot path.
fire Stop "$PID2"; printf 'enaia' > "$ROOT/.title"; rm -rf "$WORKDIR"
CMUX_SENTINEL_NOTIFY_CMD='exit 7' firet PreToolUse "$PID2" AskUserQuestion
ck "a failing notifier still leaves ❓" "❓enaia"

# Unset = completely off, the default for everyone who never opts in.
unset CMUX_SENTINEL_NOTIFY_CMD
fire Stop "$PID2"; printf 'enaia' > "$ROOT/.title"; rm -rf "$WORKDIR"; rm -f "$NOTED"
firet PreToolUse "$PID2" AskUserQuestion; ck "no notifier configured → ❓ unchanged" "❓enaia"
"$REALSLEEP" 0.2
cknote "unset notifier writes nothing" "$([ -e "$NOTED" ] && echo present || echo absent)" "absent"

echo "M: a turn that ENDS on a plain-text question → ❓ (quiets later, see M7)"
# Stop carrying the agent's final reply (Claude Code's last_assistant_message; the
# Amp adapter sends the same field). jq builds the JSON so quotes and newlines survive.
fires() { jq -n --arg m "$3" '{last_assistant_message: $m}' \
            | CMUX_CLAUDE_PID="$2" bash "$BRIDGE" "$1"; }
fire Stop "$PID2"; printf 'enaia' > "$ROOT/.title"; rm -rf "$WORKDIR"; rm -f "$NOTED"
fire PreToolUse "$PID2";                                  ck "working → ⚡"              "⚡enaia"
fires Stop "$PID2" "Should I continue with the deploy?";  ck "ends on a question → ❓"   "❓enaia"
# ~60s later Claude sends its idle "waiting for your input" Notification. The turn
# is over (no pid file), so _notify_waiting ignores it and the ❓ stays put.
fire Notification "$PID2";                                ck "idle notice keeps ❓"      "❓enaia"
fire SessionStart "$A";                                   ck "reconcile keeps ❓"        "❓enaia"
fire UserPromptSubmit "$PID2";                            ck "you reply → ⚡"            "⚡enaia"
fires Stop "$PID2" "Done. Deployed to staging.";          ck "ends on a statement → idle" "enaia"

fire PreToolUse "$PID2"
fires Stop "$PID2" "$(printf 'Two options:\n\n**Proceed with A?**\n')"; ck "markdown-wrapped question → ❓" "❓enaia"
fire UserPromptSubmit "$PID2"
fires Stop "$PID2" "$(printf 'Was it the cache? Yes.\n\nAll green now.')"; ck "question mid-reply, then a statement → idle" "enaia"
fire PreToolUse "$PID2"
fires Stop "$PID2" "$(printf 'Ship it (y/n)?\n\n   \n')"; ck "trailing blank lines ignored → ❓" "❓enaia"
fire SessionEnd "$PID2";                                  ck "session closed → idle"     "enaia"
fire PreToolUse "$PID2"
fires Stop "$PID2" '続けますか？';                          ck "full-width ？ → ❓"         "❓enaia"
fire UserPromptSubmit "$PID2"; fire Stop "$PID2";         ck "no message field → idle (older agents)" "enaia"
# Only markdown emphasis is peeled: a `?` inside a code span or quotes ends a statement.
fire PreToolUse "$PID2"
# shellcheck disable=SC2016  # literal markdown backticks, not a command substitution
fires Stop "$PID2" 'Renamed the button to `Continue?`';   ck "code span ending in ? → idle" "enaia"
fire PreToolUse "$PID2"
fires Stop "$PID2" 'Renamed it to "Continue?"';           ck "quoted ? → idle"              "enaia"

echo "M2: co-tenants — a text question outranks another session's work"
fire PreToolUse "$A"; fire PreToolUse "$PID2";            ck "two sessions working → ⚡" "⚡enaia"
fires Stop "$PID2" "Which branch should I use?";          ck "one asks → ❓"             "❓enaia"
fires Stop "$A" "Tests pass.";                            ck "the other finishing keeps ❓" "❓enaia"
fire UserPromptSubmit "$PID2";                            ck "reply → ⚡"                "⚡enaia"
fire Stop "$PID2";                                        ck "Stop → idle"               "enaia"

echo "M3: a dead session's question is reaped, and the transition alerts once"
fires Stop 999999 "Anything else?";                       ck "dead pid → idle"           "enaia"
rm -rf "$WORKDIR"; rm -f "$NOTED"
# shellcheck disable=SC2016  # $1/$2 belong to the notifier's `sh -c`, not to us
export CMUX_SENTINEL_NOTIFY_CMD='printf "%s|%s\n" "$1" "$2" >> '"$NOTED"
fire PreToolUse "$PID2"
fires Stop "$PID2" "Should I merge it?";                  ck "asks in text → ❓ (notifier armed)" "❓enaia"
notewait 1
cknote "notifier fires on the text-question transition" "$(cat "$NOTED" 2>/dev/null)" "enaia|waiting"
fires Stop "$PID2" "Should I merge it?"
"$REALSLEEP" 0.3
cknote "already ❓ fires no duplicate" "$(wc -l < "$NOTED" | tr -d ' ')" "1"
unset CMUX_SENTINEL_NOTIFY_CMD
fire SessionEnd "$PID2";                                  ck "SessionEnd → idle"         "enaia"

echo "M4: a late Stop from an earlier turn can't end the next one"
# Hooks are async, so a prompt you queued can start turn 2 before turn 1's Stop
# runs. prompt_id ties a Stop to its turn; only UserPromptSubmit records it.
firep() { # $1=event $2=pid $3=prompt_id [$4=last_assistant_message]
  jq -n --arg id "$3" --arg m "${4-}" \
    '{prompt_id: $id} + (if $m == "" then {} else {last_assistant_message: $m} end)' \
    | CMUX_CLAUDE_PID="$2" bash "$BRIDGE" "$1"; }
rm -rf "$WORKDIR"; printf 'enaia' > "$ROOT/.title"
firep UserPromptSubmit "$PID2" t1;                        ck "turn 1 → ⚡"               "⚡enaia"
firep UserPromptSubmit "$PID2" t2;                        ck "queued prompt starts turn 2 first → ⚡" "⚡enaia"
firep Stop "$PID2" t1 "Should I deploy?";                 ck "turn 1's late question is ignored → ⚡" "⚡enaia"
firep Stop "$PID2" t1 "Done.";                            ck "turn 1's late statement is ignored → ⚡" "⚡enaia"
firep Stop "$PID2" t2 "Done.";                            ck "turn 2's own Stop → idle"  "enaia"
firep UserPromptSubmit "$PID2" t3
firep PreToolUse "$PID2" sub9                             # a subagent's call, another id
firep Stop "$PID2" t3 "Done.";                            ck "a subagent's id can't make the turn's Stop stale" "enaia"

echo "M5: background work after a turn-ending question keeps ❓; your prompt clears it"
firep UserPromptSubmit "$PID2" t4
firep Stop "$PID2" t4 "Want me to merge it?";             ck "ends on a question → ❓"   "❓enaia"
fire PreToolUse "$PID2";                                  ck "a background agent's tool call keeps ❓" "❓enaia"
fire Notification "$PID2";                                ck "so does a permission prompt meanwhile" "❓enaia"
firep UserPromptSubmit "$PID2" t5;                        ck "your prompt → ⚡"          "⚡enaia"
firep Stop "$PID2" t5 "Merged.";                          ck "→ idle"                    "enaia"
# A question DIALOG is still answered by the next tool call, as before.
firet PreToolUse "$PID2" AskUserQuestion;                 ck "dialog → ❓"               "❓enaia"
fire PreToolUse "$PID2";                                  ck "next tool call → ⚡"       "⚡enaia"
fire Stop "$PID2";                                        ck "→ idle"                    "enaia"

echo "M6: a question hidden behind a co-tenant's ⏳ alerts when it surfaces"
rm -rf "$WORKDIR"; rm -f "$NOTED"; printf 'enaia' > "$ROOT/.title"
# shellcheck disable=SC2016  # $1/$2 belong to the notifier's `sh -c`, not to us
export CMUX_SENTINEL_NOTIFY_CMD='printf "%s|%s\n" "$1" "$2" >> '"$NOTED"
fire PreToolUse "$A"; fire PreCompact "$A";               ck "co-tenant compacting → ⏳" "⏳enaia"
fire PreToolUse "$PID2"
fires Stop "$PID2" "Should I merge it?";                  ck "question under ⏳ stays ⏳" "⏳enaia"
"$REALSLEEP" 0.3
cknote "no alert while hidden" "$([ -e "$NOTED" ] && echo present || echo absent)" "absent"
fire PostCompact "$A";                                    ck "compaction ends → ❓"      "❓enaia"
notewait 1
cknote "alert when ❓ surfaces" "$(cat "$NOTED" 2>/dev/null)" "enaia|waiting"
unset CMUX_SENTINEL_NOTIFY_CMD
fire Stop "$A"; fire SessionEnd "$PID2";                  ck "both done → idle"          "enaia"

echo "M7: a text question quiets ❓ → ❔ after CMUX_SENTINEL_ASK_TTL; work outranks ❔"
# The fade timer is detached, so wait briefly for the fake sleep to record it.
sleptwait() { local i=0; while [ ! -s "$ROOT/.slept" ] && [ "$i" -lt 50 ]; do
                i=$((i + 1)); "$REALSLEEP" 0.1; done; }
rm -rf "$WORKDIR"; rm -f "$NOTED" "$ROOT/.slept"; printf 'enaia' > "$ROOT/.title"
# shellcheck disable=SC2016  # $1/$2 belong to the notifier's `sh -c`, not to us
export CMUX_SENTINEL_NOTIFY_CMD='printf "%s|%s\n" "$1" "$2" >> '"$NOTED"
fire PreToolUse "$PID2"
fires Stop "$PID2" "Want me to open a PR?";               ck "asks → ❓"                 "❓enaia"
sleptwait
cknote "fade timer armed just past the 600s default" "$(cat "$ROOT/.slept" 2>/dev/null)" "601"
fire Reconcile "$PID2";                                   ck "timer before the TTL → still ❓" "❓enaia"
stale "$WORKDIR/.asking.$PID2"
fire Reconcile "$PID2";                                   ck "timer past the TTL → ❔"   "❔enaia"
fire Notification "$PID2";                                ck "idle notice keeps ❔"      "❔enaia"
fire SessionStart "$A";                                   ck "reconcile keeps ❔"        "❔enaia"
notewait 1; "$REALSLEEP" 0.3
cknote "quieting to ❔ sends no second alert" "$(wc -l < "$NOTED" | tr -d ' ')" "1"
fire PreToolUse "$A";                                     ck "a co-tenant's work outranks ❔ → ⚡" "⚡enaia"
fire Reconcile "$A";                                      ck "and a reconcile agrees → ⚡" "⚡enaia"
fire Stop "$A";                                           ck "co-tenant done → ❔ again" "❔enaia"
fire UserPromptSubmit "$PID2";                            ck "you reply → ⚡"            "⚡enaia"
fires Stop "$PID2" "Should I merge it too?";              ck "a new question → ❓"       "❓enaia"
notewait 2
cknote "❔ → ❓ is a new transition, so it alerts" "$(wc -l < "$NOTED" | tr -d ' ')" "2"
unset CMUX_SENTINEL_NOTIFY_CMD
fire UserPromptSubmit "$PID2"; fire Stop "$PID2";         ck "→ idle"                    "enaia"

echo "M8: a dialog during a faded question is ❓, and the question outlives it"
fires Stop "$PID2" "Want me to open a PR?"; stale "$WORKDIR/.asking.$PID2"
fire Reconcile "$PID2";                                   ck "faded → ❔"                "❔enaia"
fire PreToolUse "$PID2";                                  ck "a background agent works → ⚡" "⚡enaia"
fire Notification "$PID2";                                ck "and hits a permission prompt → ❓" "❓enaia"
fire PreToolUse "$PID2";                                  ck "granted → ⚡"              "⚡enaia"
stale "$WORKDIR/$PID2"
fire Reconcile "$PID2";                                   ck "its work goes stale → ❔ (still unanswered)" "❔enaia"
fire SessionEnd "$PID2";                                  ck "SessionEnd → idle"         "enaia"

echo "M9: CMUX_SENTINEL_ASK_TTL=0 never quiets, and ❔ orphans are swept"
export CMUX_SENTINEL_ASK_TTL=0
rm -f "$ROOT/.slept"
fire PreToolUse "$PID2"
fires Stop "$PID2" "Want me to open a PR?";               ck "asks → ❓"                 "❓enaia"
stale "$WORKDIR/.asking.$PID2"
fire Reconcile "$PID2";                                   ck "any age → still ❓"        "❓enaia"
"$REALSLEEP" 0.3
cknote "no fade timer armed" "$([ -e "$ROOT/.slept" ] && echo present || echo absent)" "absent"
unset CMUX_SENTINEL_ASK_TTL
fire SessionEnd "$PID2";                                  ck "SessionEnd → idle"         "enaia"
rm -rf "$WORKDIR"; printf '❔orphan' > "$ROOT/.title"
fire SessionStart "$A";                                   ck "orphan ❔ (no live session) stripped" "orphan"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
