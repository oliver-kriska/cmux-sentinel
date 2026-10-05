#!/bin/bash
# amp-bridge.sh — offline test for the Amp integration (hooks/amp-bridge.ts +
# the agent-agnostic knobs it drives in hooks/cmux-bridge.sh).
#
# Three layers, because each boundary fails differently:
#
#  A. BEHAVIOUR — drives the real bash bridge with the exact env the amp plugin
#     sets (CMUX_SENTINEL_SESSION_PID / _AGENT_LABEL / _LOG_SOURCE) against a
#     stubbed cmux, and asserts the markers, the "Amp" notification title, the
#     `amp` log source, and — the one that actually matters — CO-TENANCY: an Amp
#     session and a Claude session in the SAME workspace must ref-count against
#     each other, so one ending must not clear the other's ⚡. That property is
#     the whole reason the plugin shells out instead of reimplementing state.
#
#  B. ADAPTER — imports the JS-compatible .ts through Node and proves both the
#     current atomic terminal-error protocol and its ordered legacy fallback,
#     then statically checks event mappings and invariants.
#
#  C. AMP RUNTIME — when `amp` is available, runs one real `amp plugins exec`
#     event to prove Amp loads the plugin and invokes its handler.
#
# No real cmux, amp or bun needed for the required checks, so this runs in CI on
# Linux too.
#
# Run:  make test   (or:  bash tests/amp-bridge.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${BRIDGE:-$HERE/../hooks/cmux-bridge.sh}"
PLUGIN="${PLUGIN:-$HERE/../hooks/amp-bridge.ts}"
[ -f "$BRIDGE" ] || { echo "bridge not found: $BRIDGE" >&2; exit 2; }
[ -f "$PLUGIN" ] || { echo "plugin not found: $PLUGIN" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-amp-test.XXXXXX")"
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT
mkdir -p "$ROOT/bin"

# UUID-shaped, but BUILT AT RUNTIME so no literal id sits in the source for the
# secret guard to flag (same idiom as tests/bridge-state.sh). The bridge treats
# this as an opaque $WORKROOT dir name, so the actual value is irrelevant.
WS="$(printf '%08d-%04d-%04d-%04d-%012d' 0 0 0 0 1)"
echo "workspace" > "$ROOT/title"

# Fake cmux: ping ok; list-workspaces serves "<id>  <title>" from $ROOT/title;
# rename writes it back; notify/log/set-status/clear-status append to a ledger.
cat > "$ROOT/bin/cmux" <<FAKE
#!/bin/bash
ROOT="$ROOT"
WS="$WS"
FAKE
cat >> "$ROOT/bin/cmux" <<'FAKE'
case "$1" in
  ping) exit 0 ;;
  list-workspaces) printf '%s  %s\n' "$WS" "$(cat "$ROOT/title")"; exit 0 ;;
  rename-workspace)
    shift
    while [ $# -gt 1 ]; do shift; done
    printf '%s' "$1" > "$ROOT/title"; exit 0 ;;
  notify|log|set-status|clear-status)
    printf '%s\n' "$*" >> "$ROOT/ledger"; exit 0 ;;
esac
exit 0
FAKE
chmod +x "$ROOT/bin/cmux"

PATH="$ROOT/bin:$PATH"
export PATH

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }
title(){ cat "$ROOT/title"; }

# Drive the bridge exactly as hooks/amp-bridge.ts does.
amp_event() {
  local event="$1" pid="$2" payload="${3:-{\}}"
  printf '%s' "$payload" | \
  CMUX_WORKSPACE_ID="$WS" \
  TMPDIR="$ROOT" \
  CMUX_SENTINEL_SESSION_PID="$pid" \
  CMUX_SENTINEL_AGENT_LABEL="Amp" \
  CMUX_SENTINEL_LOG_SOURCE="amp" \
  bash "$BRIDGE" "$event" >/dev/null 2>&1
}

# Drive it as the Claude bridge does (default identity) — the co-tenant.
cc_event() {
  local event="$1" pid="$2" payload="${3:-{\}}"
  printf '%s' "$payload" | \
  CMUX_WORKSPACE_ID="$WS" \
  TMPDIR="$ROOT" \
  CMUX_SENTINEL_SESSION_PID="$pid" \
  bash "$BRIDGE" "$event" >/dev/null 2>&1
}

echo "amp-bridge: behaviour (stubbed cmux)"

# A live pid to own sessions with: this shell always passes kill -0.
LIVE=$$

caps="$(bash "$BRIDGE" --capabilities)"
has "bridge advertises atomic terminal-failure support" "$caps" "stop-failure-final"

# Execute the real adapter under Node (the .ts intentionally stays JS-compatible)
# against both bridge generations. This proves the compatibility behavior rather
# than grepping source: an old bridge says nothing for --capabilities and must see
# ordered SessionEnd→StopFailure; a new bridge advertises the token and sees one
# atomic StopFailureFinal event.
PLUGIN_MJS="$ROOT/amp-bridge.mjs"
cp "$PLUGIN" "$PLUGIN_MJS"
cat > "$ROOT/adapter-harness.mjs" <<'JS'
const handlers = new Map()
const { default: install } = await import(process.env.PLUGIN_URL)
install({ on: (event, handler) => handlers.set(event, handler) })
handlers.get("agent.end")({ status: "error" })
JS
cat > "$ROOT/bin/old-bridge" <<'SH'
#!/bin/bash
if [ "${1:-}" = "--capabilities" ]; then exit 0; fi
cat >/dev/null
printf '%s\n' "$1" >> "$ADAPTER_EVENTS"
SH
cat > "$ROOT/bin/new-bridge" <<'SH'
#!/bin/bash
if [ "${1:-}" = "--capabilities" ]; then printf '%s\n' "protocol=2 stop-failure-final"; exit 0; fi
cat >/dev/null
printf '%s\n' "$1" >> "$ADAPTER_EVENTS"
SH
chmod +x "$ROOT/bin/old-bridge" "$ROOT/bin/new-bridge"

run_adapter() { # $1=bridge $2=event-log
  : > "$2"
  PLUGIN_URL="file://$PLUGIN_MJS" CMUX_SENTINEL_BRIDGE="$1" CMUX_WORKSPACE_ID="$WS" \
    ADAPTER_EVENTS="$2" node "$ROOT/adapter-harness.mjs"
}
OLD_EVENTS="$ROOT/old-adapter-events"
NEW_EVENTS="$ROOT/new-adapter-events"
run_adapter "$ROOT/bin/old-bridge" "$OLD_EVENTS"
is "old bridge fallback clears first, then preserves the error pill" "$(cat "$OLD_EVENTS")" "$(printf 'SessionEnd\nStopFailure')"
run_adapter "$ROOT/bin/new-bridge" "$NEW_EVENTS"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$NEW_EVENTS" ] && break; sleep 0.1; done
is "new bridge gets one atomic terminal-error event" "$(cat "$NEW_EVENTS")" "StopFailureFinal"

# agent.end(done) hands the bridge the turn's final text, so a reply that ends on a
# question can show ❓. Run the real handler and capture the exact stdin payload.
cat > "$ROOT/adapter-end.mjs" <<'JS'
const handlers = new Map()
const { default: install } = await import(process.env.PLUGIN_URL)
install({ on: (event, handler) => handlers.set(event, handler) })
handlers.get(process.env.HANDLER || "agent.end")(JSON.parse(process.env.END_EVENT))
JS
cat > "$ROOT/bin/payload-bridge" <<'SH'
#!/bin/bash
if [ "${1:-}" = "--capabilities" ]; then printf '%s\n' "protocol=2 stop-failure-final"; exit 0; fi
cat > "$ADAPTER_PAYLOAD.tmp" && mv "$ADAPTER_PAYLOAD.tmp" "$ADAPTER_PAYLOAD"
SH
chmod +x "$ROOT/bin/payload-bridge"
end_payload() { # $1=event JSON [$2=handler, default agent.end] → the payload the bridge received
  local out="$ROOT/end-payload"; rm -f "$out"
  PLUGIN_URL="file://$PLUGIN_MJS" CMUX_SENTINEL_BRIDGE="$ROOT/bin/payload-bridge" \
    CMUX_WORKSPACE_ID="$WS" ADAPTER_PAYLOAD="$out" END_EVENT="$1" HANDLER="${2:-agent.end}" \
    node "$ROOT/adapter-end.mjs"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$out" ] && break; sleep 0.1; done
  cat "$out" 2>/dev/null
}
DONE_EVENT='{"status":"done","id":"m-7","messages":[
  {"role":"assistant","content":[{"type":"text","text":"An earlier turn?"}]},
  {"role":"user","content":[{"type":"text","text":"go"}]},
  {"role":"assistant","content":[{"type":"text","text":"Built it."},
    {"type":"tool_use","id":"t1","name":"Bash","input":{}},
    {"type":"text","text":"Should I deploy?"},{"type":"thinking","thinking":"hm"}]}]}'
p="$(end_payload "$DONE_EVENT")"
is "agent.end(done) → Stop" "$(printf '%s' "$p" | jq -r .hook_event_name)" "Stop"
is "…carrying the last text block of the last assistant message" \
  "$(printf '%s' "$p" | jq -r .last_assistant_message)" "Should I deploy?"
is "…and the turn id, so a late Stop can be told apart" "$(printf '%s' "$p" | jq -r .prompt_id)" "m-7"
p="$(end_payload '{"message":"go","id":"m-7"}' agent.start)"
is "agent.start → UserPromptSubmit with the same turn id" \
  "$(printf '%s' "$p" | jq -r '.hook_event_name + " " + .prompt_id')" "UserPromptSubmit m-7"
p="$(end_payload '{"status":"done","messages":[{"role":"assistant","content":[
  {"type":"text","text":"Should I deploy?"},{"type":"text","text":"\n\n"},{"type":"text","text":""}]}]}')"
is "trailing blank text blocks are skipped" "$(printf '%s' "$p" | jq -r .last_assistant_message)" "Should I deploy?"
p="$(end_payload '{"status":"done","messages":[{"role":"assistant","content":[{"type":"text","text":"  "}]}]}')"
is "only blank text → empty message" "$(printf '%s' "$p" | jq -r .last_assistant_message)" ""
p="$(end_payload '{"status":"cancelled","messages":[{"role":"assistant","content":[{"type":"text","text":"Deploy?"}]}]}')"
is "agent.end(cancelled) sends no message (you are at the keyboard)" \
  "$(printf '%s' "$p" | jq -r 'has("last_assistant_message")')" "false"
p="$(end_payload '{"status":"done"}')"
is "agent.end(done) without messages → empty message, not a crash" \
  "$(printf '%s' "$p" | jq -r .last_assistant_message)" ""

# ── turn lifecycle ────────────────────────────────────────────────────────
amp_event UserPromptSubmit "$LIVE"
is "agent.start → ⚡ working" "$(title)" "⚡workspace"

amp_event PreToolUse "$LIVE" '{"tool_name":"Bash"}'
is "tool.call keeps ⚡ (no double marker)" "$(title)" "⚡workspace"

amp_event Stop "$LIVE"
is "agent.end(done) → idle" "$(title)" "workspace"
has "agent.end notifies as Amp" "$(cat "$ROOT/ledger" 2>/dev/null)" "--title Amp"
hasnt "agent.end never says Claude Code" "$(cat "$ROOT/ledger" 2>/dev/null)" "Claude Code"
has "log source is amp" "$(cat "$ROOT/ledger" 2>/dev/null)" "--source amp"

# ── agent.end(error) is terminal: surfaces AND decrements atomically ──────
: > "$ROOT/ledger"
amp_event UserPromptSubmit "$LIVE"
amp_event StopFailureFinal "$LIVE" '{"error":"boom"}'
is "agent.end(error) → idle immediately" "$(title)" "workspace"
has "agent.end(error) uses amp status key" "$(cat "$ROOT/ledger")" "amp_error"
has "agent.end(error) notifies as Amp Error" "$(cat "$ROOT/ledger")" "--title Amp Error"

# ── opt-in ❓ waiting ─────────────────────────────────────────────────────
amp_event UserPromptSubmit "$LIVE"
amp_event PreToolUse "$LIVE" '{"tool_name":"AskUserQuestion"}'
is "ASK path → ❓ waiting outranks ⚡" "$(title)" "❓workspace"
amp_event PreToolUse "$LIVE" '{"tool_name":"Bash"}'
is "…answered → back to ⚡" "$(title)" "⚡workspace"
amp_event Stop "$LIVE"
is "…then idle" "$(title)" "workspace"

# ── a reply that ends on a question → ❓ until the next agent.start ───────
amp_event UserPromptSubmit "$LIVE"
amp_event Stop "$LIVE" '{"last_assistant_message":"Should I deploy?"}'
is "agent.end on a question → ❓" "$(title)" "❓workspace"
amp_event UserPromptSubmit "$LIVE"
is "…next agent.start → ⚡" "$(title)" "⚡workspace"
amp_event Stop "$LIVE" '{"last_assistant_message":"Deployed."}'
is "…a statement → idle" "$(title)" "workspace"

# ── CO-TENANCY: the reason the plugin shells out at all ──────────────────
# Amp and Claude Code in ONE workspace, each with its own session pid. Neither
# ending may clear the other's marker.
amp_event UserPromptSubmit "$LIVE"
# Use a second genuinely-live pid: a background sleep we control. Temporarily
# clear the parent cleanup BEFORE forking; some Bash versions propagate EXIT to
# an asynchronous child, which can delete $ROOT when the helper is killed.
trap - EXIT
sleep 30 & CO=$!
trap cleanup EXIT
cc_event  UserPromptSubmit "$CO"
is "two agents, one workspace → ⚡" "$(title)" "⚡workspace"
amp_event Stop "$LIVE"
is "Amp ends, Claude still working → ⚡ SURVIVES" "$(title)" "⚡workspace"
cc_event  Stop "$CO"
is "last agent ends → idle" "$(title)" "workspace"
kill "$CO" 2>/dev/null; wait "$CO" 2>/dev/null

# ── dead-session reaping ─────────────────────────────────────────────────
# Deliberately outside macOS/Linux PID ranges, avoiding another async helper and
# its inherited-trap race entirely.
DEAD=2147483647
amp_event UserPromptSubmit "$DEAD"
amp_event SessionStart "$LIVE" '{"source":"startup"}'
is "crashed Amp session is reaped by SessionStart" "$(title)" "workspace"

# ── not in a cmux workspace → total no-op ────────────────────────────────
printf '%s' "workspace" > "$ROOT/title"
printf '{}' | TMPDIR="$ROOT" CMUX_SENTINEL_SESSION_PID="$LIVE" \
  bash "$BRIDGE" UserPromptSubmit >/dev/null 2>&1
is "no CMUX_WORKSPACE_ID → title untouched" "$(title)" "workspace"

# ── default identity is unchanged (no regression for Claude Code) ────────
: > "$ROOT/ledger"
cc_event Stop "$LIVE"
has "default label still Claude Code" "$(cat "$ROOT/ledger")" "--title Claude Code"
has "default log source still cc" "$(cat "$ROOT/ledger")" "--source cc"

echo "amp-bridge: structure (static)"

SRC="$(cat "$PLUGIN")"
has "maps session.start"  "$SRC" 'amp.on("session.start"'
has "maps agent.start"    "$SRC" 'amp.on("agent.start"'
has "maps agent.end"      "$SRC" 'amp.on("agent.end"'
has "maps tool.call"      "$SRC" 'amp.on("tool.call"'
has "error end is one atomic bridge event" "$SRC" 'drive("StopFailureFinal"'
has "sets Amp label"      "$SRC" 'CMUX_SENTINEL_AGENT_LABEL: "Amp"'
has "sets amp log source" "$SRC" 'CMUX_SENTINEL_LOG_SOURCE: "amp"'
has "passes own pid"      "$SRC" "CMUX_SENTINEL_SESSION_PID"
has "gates on workspace"  "$SRC" "CMUX_WORKSPACE_ID"
has "❓ ask is opt-in"     "$SRC" "CMUX_SENTINEL_AMP_ASK"
has "detached spawn"      "$SRC" "detached: true"
# Amp emits no compaction event — the adapter must not invent one.
hasnt "never fakes PreCompact"  "$SRC" "PreCompact"
hasnt "never fakes PostCompact" "$SRC" "PostCompact"
# cmux owns cmux-session.ts and upgrades it in place; we must never target it.
hasnt "never writes cmux-session.ts" "$SRC" "cmux-session.ts\""
# tool.call is a request event: every path must return an action or amp stalls.
is "tool.call always returns an action" \
  "$(printf '%s' "$SRC" | grep -c 'return { action:')" "3"

# Installer must ship it under a name that cannot collide with cmux's plugin.
INSTALL="$HERE/../install.sh"
if [ -f "$INSTALL" ]; then
  ISRC="$(cat "$INSTALL")"
  has "installer targets amp plugin dir" "$ISRC" ".config/amp/plugins/cmux-sentinel-amp.ts"
  hasnt "installer never touches cmux-session.ts" "$ISRC" "plugins/cmux-session.ts"
fi

# ── live check, only when amp is actually installed ──────────────────────
# Drives the REAL amp runtime through the REAL plugin into a recorder standing in
# for the bridge, so this proves the whole chain: amp loads the TypeScript, fires
# the handler, and the handler spawns the bridge with the right event, identity
# and stdin payload. Nothing static can prove that.
#
# It must use `session.start`, and that is not arbitrary: `amp plugins exec` only
# actually INVOKES session.start. agent.start / agent.end / tool.call / tool.result
# all exit cleanly WITHOUT running the handler (they need a real thread context) —
# verified 2026-07-20 across all five events. An earlier version of this check used
# agent.start and passed by only looking for error text in the output, which made it
# a false positive: it proved the file parsed, not that anything ran.
if command -v amp >/dev/null 2>&1; then
  echo "amp-bridge: live (amp present)"
  REC="$ROOT/.recorded"
  cat > "$ROOT/bin/recorder" <<EOF
#!/bin/bash
{ echo "EVENT=\$1 LABEL=\$CMUX_SENTINEL_AGENT_LABEL SRC=\$CMUX_SENTINEL_LOG_SOURCE PID=\$CMUX_SENTINEL_SESSION_PID"; cat; } >> "$REC"
EOF
  chmod +x "$ROOT/bin/recorder"
  rm -f "$REC"
  ( cd "$ROOT" && CMUX_WORKSPACE_ID="$WS" CMUX_SENTINEL_BRIDGE="$ROOT/bin/recorder" \
      amp plugins exec "$PLUGIN" session.start --data '{"thread":{"id":"T-live"}}' ) >/dev/null 2>&1
  # The bridge spawn is detached and fire-and-forget, so give it a moment to land.
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$REC" ] && break; sleep 0.3; done
  rec="$(cat "$REC" 2>/dev/null)"
  if [ -z "$rec" ]; then
    bad "live: amp never invoked the plugin handler"
  else
    has "live: amp → plugin → bridge fires"    "$rec" "EVENT=SessionStart"
    has "live: identity is Amp"                "$rec" "LABEL=Amp"
    has "live: log source is amp"              "$rec" "SRC=amp"
    has "live: payload is the hook JSON"       "$rec" '"hook_event_name":"SessionStart"'
  fi
else
  echo "amp-bridge: live checks skipped (amp not on PATH)"
fi

echo
printf 'amp-bridge: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
