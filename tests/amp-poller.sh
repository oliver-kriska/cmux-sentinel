#!/bin/bash
# amp-poller.sh — offline test for bin/cmux-amp-usage.sh.
#
# The Amp poller scrapes `amp usage` PROSE (Amp ships no --json), so the value of
# this test is mostly in the parser: it pins the REMAINING→USED inversion, the
# phrase-anchored (not position-anchored) extraction, and the rule that anything
# unparseable becomes "offline" rather than a fabricated 0%. Stubs `amp`, `cmux`
# and a throwaway $HOME, so it runs in CI on Linux with no Amp installed.
#
# Run:  make test   (or:  bash tests/amp-poller.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLER="${POLLER:-$HERE/../bin/cmux-amp-usage.sh}"
[ -f "$POLLER" ] || { echo "poller not found: $POLLER" >&2; exit 2; }

JQ="$(command -v jq)" || { echo "jq required for this test" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-amp-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/home/.config/cmux" "$ROOT/home/.local/share/amp"

# Fake cmux: ping ok; workspace list serves both amp sentinels with their BARE
# labels (the real first-run state the poller must resolve to bootstrap them);
# rename + set-progress log what they were given.
cat > "$ROOT/bin/cmux" <<'FAKE'
#!/bin/bash
LOG="$AMPTEST/.renames"
PLOG="$AMPTEST/.progress"
case "$1" in
  ping) [ "${STUB_CMUX_DOWN:-0}" != "1" ]; exit ;;
  list-windows) exit 0 ;;
  workspace)
    if [ "$2" = "list" ]; then
      if [ -n "${STUB_NO_AMPO:-}" ]; then
        printf '{"workspaces":[{"title":"ampu","ref":"workspace:1"}]}\n'
      else
        printf '{"workspaces":[{"title":"ampu","ref":"workspace:1"},{"title":"ampo","ref":"workspace:2"}]}\n'
      fi
    fi
    exit 0 ;;
  rename-workspace)
    shift; title=""
    while [ $# -gt 0 ]; do case "$1" in --workspace|--window) shift 2 ;; *) title="$1"; shift ;; esac; done
    printf '%s\n' "$title" >> "$LOG"; exit 0 ;;
  set-progress)
    shift; value="$1"; shift; label=""
    while [ $# -gt 0 ]; do case "$1" in --label) label="$2"; shift 2 ;; --workspace|--window) shift 2 ;; *) shift ;; esac; done
    printf '%s | %s\n' "$value" "$label" >> "$PLOG"; exit 0 ;;
  clear-progress) printf 'CLEARED\n' >> "$PLOG"; exit 0 ;;
esac
exit 0
FAKE
chmod +x "$ROOT/bin/cmux"

# Fake amp: prints whatever fixture $AMP_FIXTURE names; exit 1 for "logged out".
cat > "$ROOT/bin/amp" <<'FAKE'
#!/bin/bash
[ "${AMP_FAIL:-0}" = "1" ] && exit 1
[ "$1" = "usage" ] || exit 0
printf '%s\n' "$AMP_FIXTURE"
FAKE
chmod +x "$ROOT/bin/amp"

ln -sf "$JQ" "$ROOT/bin/jq"
export AMPTEST="$ROOT"
PATH="$ROOT/bin:/usr/bin:/bin"
export PATH

# Credentials present = "logged in" (existence only; never read).
echo '{"stub":"not-a-real-secret"}' > "$ROOT/home/.local/share/amp/secrets.json"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }
STAMP="$ROOT/home/.local/state/cmux-sentinel/usage/amp.last-success"
nostamp() { if [ ! -e "$STAMP" ]; then ok "$1"; else bad "$1 (unexpected success stamp)"; fi; }

# Real-world fixtures, byte-for-byte the shape amp 0.0.1784… prints. The "$0"/"$14"
# are literal dollar AMOUNTS in amp's own output, not shell expansions — single
# quotes keep them literal, which is exactly what we want.
# shellcheck disable=SC2016
FRESH='Signed in as user@example.com (someone)
Subscription Gigawatt: 100% other usage and 100% orb usage remaining - resets upon renewal in 1 month
Workspace demo: $0 remaining - https://ampcode.com/workspaces/demo'

# shellcheck disable=SC2016
PARTIAL='Signed in as user@example.com (someone)
Subscription Gigawatt: 23% other usage and 71% orb usage remaining - resets upon renewal in 12 days
Workspace demo: $14 remaining - https://ampcode.com/workspaces/demo'

run() { # $1=mode  ... env passed by caller
  HOME="$ROOT/home" \
  AMP_SECRETS_JSON="$ROOT/home/.local/share/amp/secrets.json" \
  AMPTEST="$ROOT" \
  bash "$POLLER" "$1" 2>&1
}
# STDOUT ONLY. --buckets' fail-open contract is specifically about stdout: every
# can't-tell path must print no LABELS there, while still explaining itself on
# stderr. Merging the two (as run() does) would hide a real regression behind the
# diagnostic text, so bucket assertions must use this.
run_out() { # $1=mode
  HOME="$ROOT/home" \
  AMP_SECRETS_JSON="$ROOT/home/.local/share/amp/secrets.json" \
  AMPTEST="$ROOT" \
  bash "$POLLER" "$1" 2>/dev/null
}
cfg() { printf '%s\n' "$@" > "$ROOT/home/.config/cmux/usage-sentinels.env"; }
reset_logs() { : > "$ROOT/.renames"; : > "$ROOT/.progress"; rm -f "$STAMP"; }

echo "amp-poller: gating"

cfg 'USAGE_PROVIDERS="claude"'
out=$(AMP_FIXTURE="$FRESH" run --print); rc=$?
is  "disabled provider exits 0" "$rc" "0"
has "disabled provider says so" "$out" "amp disabled"
hasnt "disabled provider draws nothing" "$out" "%"
nostamp "disabled provider records no freshness"

cfg 'USAGE_PROVIDERS="claude amp"'
mv "$ROOT/home/.local/share/amp/secrets.json" "$ROOT/secrets.bak"
out=$(AMP_FIXTURE="$FRESH" run --print); rc=$?
is  "no credentials exits 0" "$rc" "0"
has "no credentials says so"  "$out" "nothing to meter"
mv "$ROOT/secrets.bak" "$ROOT/home/.local/share/amp/secrets.json"

echo "amp-poller: parsing (the REMAINING→USED inversion)"

# The bug this test exists to prevent: a brand-new subscription is 100% REMAINING,
# which must render as 0% USED — an empty bar, not a full one.
out=$(AMP_FIXTURE="$FRESH" run --print)
has "fresh 100% remaining → 0% used" "$out" "ampu: 0% used"
hasnt "fresh subscription is NOT 100% used" "$out" "ampu: 100% used"

out=$(AMP_FIXTURE="$PARTIAL" run --print)
has "23% remaining → 77% used"  "$out" "ampu: 77% used"
has "71% orb remaining → 29% used" "$out" "ampo: 29% used"
has "reset phrase is amp's own" "$out" "resets in 12 days"
nostamp "--print records no freshness"

echo "amp-poller: parsing is phrase-anchored, not position-anchored"

# Same numbers, sentence reworded and reordered. A position/field-index parser
# breaks here; a phrase-anchored one does not. This is the whole defence against
# Amp rewording its own output in a release.
REWORDED='Signed in as user@example.com (someone)
Plan Terawatt — you still have 71% orb usage and 23% other usage remaining, resets upon renewal in 12 days'
out=$(AMP_FIXTURE="$REWORDED" run --print)
has "reworded+reordered still 77% used" "$out" "ampu: 77% used"
has "reworded+reordered orb still 29%"  "$out" "ampo: 29% used"

# The title fallback uses `|` as its field delimiter. Upstream prose must never
# inject a third field or turn reset text into the fallback bar.
DELIMITED='Subscription X: 23% other usage and 71% orb usage remaining - resets upon renewal in 12|days'
reset_logs
AMP_FIXTURE="$DELIMITED" run --update >/dev/null
renames="$(cat "$ROOT/.renames")"
has "reset prose cannot inject the title delimiter" "$renames" "77% (12days)"
is "fallback retains exactly two structural delimiters" "$(printf '%s' "$renames" | tr -cd '|' | wc -c | tr -d ' ')" "2"

# Decimals must not blow up the integer math.
DECIMAL='Subscription X: 99.5% other usage and 0.4% orb usage remaining - resets upon renewal in 3 days'
out=$(AMP_FIXTURE="$DECIMAL" run --print)
has "decimal remaining rounds"      "$out" "ampu: 0% used"
has "decimal orb rounds to 100 used" "$out" "ampo: 100% used"

echo "amp-poller: the 2026-09 reworded shape (number AFTER the phrase)"

# Byte-for-byte the shape amp 0.0.1789… prints (email/workspace replaced). The old
# parser read NOTHING from this — every Amp meter sat on "⚠ no data" for two weeks.
# shellcheck disable=SC2016
CURRENT='Signed in as user@example.com (someone)
**Amp Megawatt Tier:** agent usage $5.27 of $20 remaining (26%), orb usage 288.8h of 750h a1.small orb hours remaining (39%) - period 2026-08-20 to 2026-09-20, resets upon renewal in 5 days
**Workspace demo:** $49.96 remaining (set up auto-reload to avoid running out) - https://ampcode.com/workspaces/demo

# Run `amp usage --details` for more detailed information.'
out=$(AMP_FIXTURE="$CURRENT" run --print); rc=$?
is  "current shape parses (exit 0)"      "$rc" "0"
has "agent usage 26% remaining → 74% used" "$out" "ampu: 74% used (26% remaining)"
has "orb usage 39% remaining → 61% used"   "$out" "ampo: 61% used (39% remaining)"
has "current shape keeps amp's reset phrase" "$out" "resets in 5 days"
hasnt "workspace \$ balance is never metered" "$out" "49"

reset_logs
AMP_FIXTURE="$CURRENT" run --update >/dev/null
has "current shape paints a compact title" "$(cat "$ROOT/.renames")" "ampu |74% (5d) 🟡|"
is  "current shape progress fraction"      "$(head -1 "$ROOT/.progress" | cut -d' ' -f1)" "0.74"

out=$(AMP_FIXTURE="$CURRENT" run_out --buckets)
is  "current shape buckets = ampu" "$out" "ampu"

# An agent clause with NO percentage must not reach across into the orb clause and
# steal its number — that would paint the orb allowance on the agent meter.
# shellcheck disable=SC2016
NOAGENTPCT='**Amp X Tier:** agent usage $5 of $20 remaining, orb usage 10h of 750h orb hours remaining (39%) - resets upon renewal in 5 days'
out=$(AMP_FIXTURE="$NOAGENTPCT" run --print)
has "agent clause cannot steal the orb percentage" "$out" "ampu: n/a"
has "orb still parses on its own"                  "$out" "ampo: 61% used"

# The inversion is only safe on a REMAINING number. If Amp ever flips to "used",
# we must go offline rather than invert it into the opposite bar.
# shellcheck disable=SC2016
USEDPCT='**Amp X Tier:** agent usage $15 of $20 used (74%) - resets upon renewal in 5 days'
out=$(AMP_FIXTURE="$USEDPCT" run --print); rc=$?
is  "a 'used (N%)' shape is not parsed" "$rc" "1"
hasnt "a 'used (N%)' shape is never inverted" "$out" "26% used"

echo "amp-poller: unparseable → offline, never a fake 0%"

# shellcheck disable=SC2016
NOSUB='Signed in as user@example.com (someone)
Workspace demo: $14 remaining - https://ampcode.com/workspaces/demo'
out=$(AMP_FIXTURE="$NOSUB" run --print); rc=$?
is  "no subscription line exits non-zero" "$rc" "1"
has "no subscription line explains why"   "$out" "could not parse"
hasnt "no subscription line never says 0% used" "$out" "0% used"

reset_logs
out=$(AMP_FIXTURE="$NOSUB" run --update)
has "unparseable --update marks offline" "$(cat "$ROOT/.renames")" "⚠ no data"
has "unparseable --update clears the bar" "$(cat "$ROOT/.progress")" "CLEARED"

reset_logs
out=$(AMP_FIXTURE="$FRESH" AMP_FAIL=1 run --update)
has "amp usage failure marks offline" "$(cat "$ROOT/.renames")" "⚠ offline"
nostamp "offline paint is not a successful refresh"

echo "amp-poller: --update paints the meter"

reset_logs
out=$(STUB_CMUX_DOWN=1 AMP_FIXTURE="$PARTIAL" run --update); rc=$?
is "dead cmux socket exits non-zero before sentinel writes" "$rc" "1"
has "dead cmux socket has the actionable diagnostic" "$out" "cmux socket rejected"
is "dead cmux socket attempts no misleading rename" "$(cat "$ROOT/.renames")" ""

reset_logs
AMP_FIXTURE="$PARTIAL" run --update >/dev/null
renames="$(cat "$ROOT/.renames")"
has "title keeps the label anchor"  "$renames" "ampu "
has "title carries the used pct"    "$renames" "77%"
has "title compacts the reset"      "$renames" "12d"
hasnt "title omits the long reset"  "$renames" "12 days"
has "title has a unicode bar"       "$renames" "█"
has "77% used gets the amber dot"   "$renames" "🟡"
has "fallback title uses the detail/bar delimiter" "$renames" "|"
is  "progress fraction is 0..1"     "$(head -1 "$ROOT/.progress" | cut -d' ' -f1)" "0.77"
has "native label uses compact parenthesized countdown" "$(head -1 "$ROOT/.progress")" "77% (12d)"
hasnt "native label omits redundant resets wording" "$(head -1 "$ROOT/.progress")" "resets"
if [ -s "$STAMP" ] && grep -Eq '^[0-9]+$' "$STAMP"; then ok "complete update records freshness"
else bad "complete update records freshness (no valid stamp)"; fi

# Severity thresholds ride USED, so a nearly-exhausted allowance goes red.
CRIT='Subscription X: 3% other usage and 100% orb usage remaining - resets upon renewal in 2 days'
reset_logs
AMP_FIXTURE="$CRIT" run --update >/dev/null
has "97% used gets the red dot" "$(cat "$ROOT/.renames")" "🔴"

echo "amp-poller: the orb meter costs a ⌘ key, so it is opt-in"

out=$(AMP_FIXTURE="$FRESH" run_out --buckets)
is  "default buckets = ampu only" "$out" "ampu"
out=$(cfg 'USAGE_PROVIDERS="claude amp"' 'AMP_ORB_METER=1'; AMP_FIXTURE="$FRESH" run_out --buckets)
is  "AMP_ORB_METER=1 adds ampo" "$out" "$(printf 'ampu\nampo')"

# With orb off, the ampo sentinel must never be painted even though it exists.
cfg 'USAGE_PROVIDERS="claude amp"'
reset_logs
AMP_FIXTURE="$PARTIAL" run --update >/dev/null
hasnt "orb off → ampo never painted" "$(cat "$ROOT/.renames")" "ampo"

# A missing sentinel for a bucket we don't meter is the intended steady state.
cfg 'USAGE_PROVIDERS="claude amp"'
reset_logs
out=$(STUB_NO_AMPO=1 AMP_FIXTURE="$PARTIAL" run --update); rc=$?
is "missing ampo sentinel is a quiet no-op" "$rc" "0"

echo "amp-poller: --buckets fails open (a flaky run may never delete a meter)"

out=$(AMP_FIXTURE="$FRESH" AMP_FAIL=1 run_out --buckets)
is "amp failure prints NO buckets" "$out" ""
out=$(AMP_FIXTURE="$NOSUB" run_out --buckets)
is "unparseable prints NO buckets" "$out" ""
cfg 'USAGE_PROVIDERS="claude"'
out=$(AMP_FIXTURE="$FRESH" run_out --buckets)
is "disabled prints NO buckets" "$out" ""

echo "amp-poller: --raw"

cfg 'USAGE_PROVIDERS="claude amp"'
out=$(AMP_FIXTURE="$PARTIAL" run --raw)
has "--raw passes output through" "$out" "23% other usage"
reset_logs
AMP_FIXTURE="$PARTIAL" run --raw >/dev/null
is "--raw makes no cmux writes" "$(cat "$ROOT/.renames")" ""

echo
printf 'amp-poller: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
