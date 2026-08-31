#!/bin/bash
# poller-gate.sh — offline test for bin/cmux-claude-usage.sh PROVIDER GATING.
#
# Stubs security (Keychain), curl (network) and cmux, with a throwaway $HOME, so
# it runs in CI on Linux too. Asserts the four gate outcomes that decide whether
# a usage panel shows — the robustness contract from the README "Usage meters"
# section: a provider that's disabled or not installed must exit 0 cleanly (no
# panel, no error spam), while an installed-but-unreachable provider stamps the
# transient "⚠ offline" so a frozen bar is obvious.
#
# Run:  make test   (or:  bash tests/poller-gate.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLER="${POLLER:-$HERE/../bin/cmux-claude-usage.sh}"
[ -f "$POLLER" ] || { echo "poller not found: $POLLER" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-poller-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/home/.claude" "$ROOT/home/.config/cmux"

# Fake cmux: ping ok; `workspace list --json` serves two sentinels; rename logs
# the resulting title so we can assert what (if anything) the poller wrote.
cat > "$ROOT/bin/cmux" <<'FAKE'
#!/bin/bash
LOG="$POLLERTEST/.renames"
PLOG="$POLLERTEST/.progress"
case "$1" in
  ping) exit 0 ;;
  workspace)
    if [ "$2" = "list" ]; then
      # STUB_BARE=1 → sentinels titled with the BARE label (a freshly-created,
      # never-updated sentinel) to exercise the bootstrap resolve path.
      # STUB_M7D=1 → the opt-in per-model sentinel also exists.
      extra=""
      [ -n "${STUB_M7D:-}" ] && extra=',{"title":"m7d init","ref":"workspace:3"}'
      [ -n "${STUB_SPEND_WS:-}" ] && extra="$extra"',{"title":"spend init","ref":"workspace:4"}'
      if [ -n "${STUB_NO_5H:-}" ]; then
        # The 5h sentinel was closed — an ordinary workspace anyone can close.
        printf '{"workspaces":[{"title":"7d init","ref":"workspace:2"}%s]}\n' "$extra"
      elif [ -n "${STUB_BARE:-}" ]; then
        printf '{"workspaces":[{"title":"5h","ref":"workspace:1"},{"title":"7d","ref":"workspace:2"}%s]}\n' "$extra"
      else
        printf '{"workspaces":[{"title":"5h init","ref":"workspace:1"},{"title":"7d init","ref":"workspace:2"}%s]}\n' "$extra"
      fi
    fi
    exit 0 ;;
  rename-workspace)
    shift; title=""
    while [ $# -gt 0 ]; do case "$1" in --workspace) shift 2 ;; *) title="$1"; shift ;; esac; done
    printf '%s\n' "$title" >> "$LOG"; exit 0 ;;
  set-progress)   # set-progress <value> --label <t> --workspace <ref> [--window <w>]
    shift; val="$1"; shift; label=""
    while [ $# -gt 0 ]; do case "$1" in --label) label="$2"; shift 2 ;; --workspace|--window) shift 2 ;; *) shift ;; esac; done
    printf 'PROG %s | %s\n' "$val" "$label" >> "$PLOG"; exit 0 ;;
  clear-progress) printf 'CLEAR\n' >> "$PLOG"; exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$ROOT/bin/cmux"

# Fake security: always "not found" — the test controls "installed" via the creds
# file only, so there's no machine-Keychain dependency.
printf '#!/bin/bash\nexit 1\n' > "$ROOT/bin/security"; chmod +x "$ROOT/bin/security"

# Fake curl: STUB_CURL=ok → emit usage JSON; otherwise fail (simulates a transport
# error, which is what curl's non-zero exit means). Utilization values are injected
# RAW via STUB_FH/STUB_SH (default 7/42), so tests can feed malformed numbers/
# strings/null and assert the poller clamps, not crashes.
#
# STUB_HTTP sets the status the poller reads from its `-w '\n%{http_code}'`; an
# error status also emits a server error BODY, because the poller must classify by
# code and never let a response body reach a workspace title. STUB_NO_CODE drops the
# status line entirely — the old-curl path, which must still work off the exit code.
cat > "$ROOT/bin/curl" <<'FAKE'
#!/bin/bash
echo x >> "$POLLERTEST/.curlcalls"      # every real API call leaves a mark
[ "${STUB_CURL:-fail}" = "ok" ] || exit 1
code="${STUB_HTTP:-200}"
if [ "$code" != "200" ]; then
  body='{"error":{"message":"stub error body"}}'
elif [ -n "${STUB_MISSING_BUCKET:-}" ]; then
  body='{"five_hour":{"utilization":7,"resets_at":"2026-06-19T20:00:00Z"}}'
elif [ -n "${STUB_BAD_RESET:-}" ]; then
  body='{"five_hour":{"utilization":7,"resets_at":null},"seven_day":{"utilization":42,"resets_at":{"unexpected":true}}}'
else
  # STUB_SCOPED=<pct> adds the modern self-describing limits[] array with a
  # per-model weekly cap. STUB_SCOPED_NAME proves the model name is read from the
  # payload rather than hardcoded anywhere.
  # STUB_SPEND=<used_minor> adds the extra-usage budget object (limit 9000 = €90.00
  # unless STUB_SPEND_LIMIT says otherwise). STUB_SPEND_CUR / STUB_SPEND_EXP drive
  # the currency formatting cases.
  spend=""
  if [ -n "${STUB_SPEND:-}" ]; then
    exp="${STUB_SPEND_EXP:-2}"; cur="${STUB_SPEND_CUR:-EUR}"; lim="${STUB_SPEND_LIMIT:-9000}"
    pct=$(( STUB_SPEND * 100 / lim ))
    spend=$(printf ',"spend":{"used":{"amount_minor":%s,"currency":"%s","exponent":%s},"limit":{"amount_minor":%s,"currency":"%s","exponent":%s},"percent":%s,"enabled":true}'       "$STUB_SPEND" "$cur" "$exp" "$lim" "$cur" "$exp" "$pct")
  fi
  limits=""
  if [ -n "${STUB_SCOPED:-}" ]; then
    limits=$(printf ',"limits":[{"kind":"five_hour","group":"session","percent":7},{"kind":"weekly_scoped","group":"weekly","percent":%s,"resets_at":"2026-06-25T00:00:00Z","scope":{"model":{"id":null,"display_name":"%s"},"surface":null}}]' "$STUB_SCOPED" "${STUB_SCOPED_NAME:-Fable}")
  fi
  body=$(printf '{"five_hour":{"utilization":%s,"resets_at":"2026-06-19T20:00:00Z"},"seven_day":{"utilization":%s,"resets_at":"2026-06-25T00:00:00Z"}%s%s}' "${STUB_FH:-7}" "${STUB_SH:-42}" "$limits" "$spend")
fi
printf '%s' "$body"
[ -n "${STUB_NO_CODE:-}" ] || printf '\n%s' "$code"
exit 0
FAKE
chmod +x "$ROOT/bin/curl"

# Fake stat: makes the cache's mtime probe reproducible on the OTHER platform.
# STUB_STAT=gnu|bsd impersonates that flavour's flag handling; unset delegates to
# the real one, so every other test is untouched. The asymmetry is the whole point
# and it is invisible on a single OS: BSD REJECTS `-c` outright (a clean fallback),
# but GNU's `-f` is a valid flag (--file-system) that prints a filesystem block
# instead of failing, so a BSD-first probe reads garbage on Linux only.
cat > "$ROOT/bin/stat" <<'FAKE'
#!/bin/bash
case "${STUB_STAT:-}" in
  gnu)  # -c <fmt> is the mtime; -f is --file-system and errors on the format operand
        [ "$1" = "-c" ] && { date +%s; exit 0; }
        printf '  File: "/"\n    ID: 0 Namelen: 255 Type: ext2/ext3\n'; exit 1 ;;
  bsd)  # -f <fmt> is the mtime; anything else is an illegal option, stdout empty
        [ "$1" = "-f" ] && { date +%s; exit 0; }
        echo "stat: illegal option -- ${1#-}" >&2; exit 1 ;;
esac
REAL=/usr/bin/stat; [ -x "$REAL" ] || REAL=/bin/stat
exec "$REAL" "$@"
FAKE
chmod +x "$ROOT/bin/stat"

export POLLERTEST="$ROOT" HOME="$ROOT/home" TMPDIR="$ROOT"
PATH="$ROOT/bin:$PATH"
CREDS="$ROOT/home/.claude/.credentials.json"
RENAMES="$ROOT/.renames"
PROGRESS="$ROOT/.progress"
STAMP="$ROOT/home/.local/state/cmux-sentinel/usage/claude.last-success"
CACHE="$ROOT/home/.local/state/cmux-sentinel/usage/claude.last-response.json"
BACKOFF="$ROOT/home/.local/state/cmux-sentinel/usage/claude.backoff"
CURLCALLS="$ROOT/.curlcalls"
TOKEN_JSON='{"claudeAiOauth":{"accessToken":"faketoken"}}'

pass=0; fail=0
ckcode() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  ✓ %s (exit %s)\n' "$1" "$2"
           else fail=$((fail + 1)); printf '  ✗ %s — exit got %s want %s\n' "$1" "$2" "$3"; fi; }
ckno()   { if [ ! -s "$RENAMES" ]; then pass=$((pass + 1)); printf '  ✓ %s (wrote nothing)\n' "$1"
           else fail=$((fail + 1)); printf '  ✗ %s — unexpected renames:\n%s\n' "$1" "$(cat "$RENAMES")"; fi; }
ckhas()  { if grep -q -- "$2" "$RENAMES" 2>/dev/null; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
           else fail=$((fail + 1)); printf '  ✗ %s — [%s] not in:\n%s\n' "$1" "$2" "$(cat "$RENAMES" 2>/dev/null)"; fi; }
cknothas(){ if grep -q -- "$2" "$RENAMES" 2>/dev/null; then fail=$((fail + 1)); printf '  ✗ %s — unexpected [%s] in:\n%s\n' "$1" "$2" "$(cat "$RENAMES" 2>/dev/null)"
           else pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; fi; }
ckprog() { if grep -q -- "$2" "$PROGRESS" 2>/dev/null; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
           else fail=$((fail + 1)); printf '  ✗ %s — [%s] not in progress log:\n%s\n' "$1" "$2" "$(cat "$PROGRESS" 2>/dev/null)"; fi; }
ckprognothas() { if grep -q -- "$2" "$PROGRESS" 2>/dev/null; then fail=$((fail + 1)); printf '  ✗ %s — unexpected [%s] in progress log:\n%s\n' "$1" "$2" "$(cat "$PROGRESS" 2>/dev/null)"
                else pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; fi; }
ckstamp() { if [ -s "$STAMP" ] && grep -Eq '^[0-9]+$' "$STAMP"; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
            else fail=$((fail + 1)); printf '  ✗ %s — no valid success stamp\n' "$1"; fi; }
cknostamp() { if [ ! -e "$STAMP" ]; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
              else fail=$((fail + 1)); printf '  ✗ %s — unexpected success stamp\n' "$1"; fi; }
# Drop the response cache too: each test feeds curl a DIFFERENT payload, so a body
# cached by the previous test would be served instead and quietly assert nothing.
reset()  { rm -f "$RENAMES" "$PROGRESS" "$STAMP" "$CACHE" "$CURLCALLS" "$BACKOFF"; }
# Same, but KEEPS a warm cache — for asserting what a cached body does next.
reset_warm() { rm -f "$RENAMES" "$PROGRESS" "$STAMP" "$CURLCALLS" "$BACKOFF"; }
OUT=""
ckout()    { if printf '%s' "$OUT" | grep -q -- "$2"; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
             else fail=$((fail + 1)); printf '  ✗ %s — [%s] not in stdout:\n%s\n' "$1" "$2" "$OUT"; fi; }
ckoutnot() { if printf '%s' "$OUT" | grep -q -- "$2"; then fail=$((fail + 1)); printf '  ✗ %s — unexpected [%s] in stdout:\n%s\n' "$1" "$2" "$OUT"
             else pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; fi; }

echo "T1: disabled (USAGE_PROVIDERS without claude) → exit 0, writes nothing"
reset; printf '%s' "$TOKEN_JSON" > "$CREDS"          # installed, but explicitly disabled
USAGE_PROVIDERS="codex" bash "$POLLER" --update; ckcode "disabled --update" "$?" 0
ckno "disabled is a no-op"
cknostamp "disabled update records no freshness"

echo "T2: not installed (no creds, no Keychain) → exit 0, writes nothing"
reset; rm -f "$CREDS"
bash "$POLLER" --update; ckcode "not-installed --update" "$?" 0
ckno "not-installed is a no-op"

echo "T3: installed + offline (creds present, fetch fails) → exit 1, ⚠ offline stamped"
reset; printf '%s' "$TOKEN_JSON" > "$CREDS"
STUB_CURL="fail" bash "$POLLER" --update; ckcode "installed+offline --update" "$?" 1
ckhas "offline stamps ⚠" "⚠"
ckprog "offline clears the native bar so the ⚠ title shows through" "CLEAR"
cknostamp "offline paint is not a successful refresh"

echo "T4: installed + reachable → exit 0, bars + native progress written"
reset
STUB_CURL="ok" bash "$POLLER" --update; ckcode "installed+ok --update" "$?" 0
ckhas "5h sentinel renamed" "5h "
ckhas "5h utilization" "7%"
ckhas "7d utilization" "42%"
ckprog "5h native progress value (7% → 0.07)" "PROG 0.07"
ckprog "7d native progress value (42% → 0.42)" "PROG 0.42"
ckprog "native labels use compact parenthesized countdowns" "% ("
ckprognothas "native labels omit redundant resets wording" "resets"
ckhas "fallback title separates detail from the second-row bar" "|"
ckstamp "complete update records freshness"

echo "T4b: read-only modes never record freshness"
reset
STUB_CURL="ok" bash "$POLLER" --print >/dev/null
cknostamp "--print records no freshness"

echo "T5: malformed utilization (over-100 / negative) → clamped, exit 0, no crash"
reset
STUB_CURL="ok" STUB_FH="150" STUB_SH="-5" bash "$POLLER" --update; ckcode "over/under --update" "$?" 0
ckhas "over-100 clamped to 100%" "100%"
ckhas "negative clamped to 0%" "0%"

echo "T5b: non-numeric / null utilization → no data, never a plausible 0%"
reset
STUB_CURL="ok" STUB_FH='"abc"' STUB_SH="null" bash "$POLLER" --update; ckcode "string/null --update" "$?" 1
ckhas "malformed utilization stamps no data" "⚠ no data"
cknothas "malformed utilization never paints 0%" "0%"
ckprog "malformed utilization clears stale native bars" "CLEAR"

echo "T5c: malformed reset timestamps preserve valid percentages with an honest unknown countdown"
reset
STUB_CURL="ok" STUB_BAD_RESET=1 bash "$POLLER" --update; ckcode "bad-reset --update" "$?" 0
ckhas "bad reset keeps valid 5h percentage" "5h |7% (?)|"
ckhas "bad reset keeps valid 7d percentage" "7d |42% (?)|"
ckprog "bad reset keeps native progress" "PROG 0.07 | 7% (?)"

echo "T5d: missing required bucket → no data, never a plausible 0%"
reset
STUB_CURL="ok" STUB_MISSING_BUCKET=1 bash "$POLLER" --update; ckcode "missing-bucket --update" "$?" 1
ckhas "missing bucket stamps no data" "⚠ no data"
cknothas "missing bucket never paints 0%" "0%"
ckprog "missing bucket clears stale native bars" "CLEAR"

echo "T6: BARE sentinel titles → poller still resolves + renames (bootstrap path)"
reset
STUB_CURL="ok" STUB_BARE="1" bash "$POLLER" --update; ckcode "bare-label --update" "$?" 0
ckhas "bare 5h resolved + renamed" "5h "
ckhas "bare 7d resolved + renamed" "7d "

echo "T7: a CLOSED sentinel must not freeze the other meter"
# Regression: the poller wrote 5h first and died on the first failure, so one closed
# workspace left 7d frozen on whatever it last said — for days, because every
# 5-minute run aborted in the same place. Freshness tracks DATA (which is flowing);
# the missing meter is reported separately, and doctor's sentinel check names it.
reset
STUB_CURL="ok" STUB_NO_5H=1 bash "$POLLER" --update; ckcode "closed-5h --update" "$?" 1
ckhas "7d still gets live data while 5h is gone" "7d |42%"
cknothas "nothing is written for the missing sentinel" "5h |"
ckprog "7d native progress still lands" "PROG 0.42"
ckstamp "a meter that landed still counts as fresh data"

echo "T8: HTTP failures are classified, never guessed at"
reset
STUB_CURL="ok" STUB_HTTP=401 bash "$POLLER" --update; ckcode "401 --update" "$?" 1
ckhas "401 marks the meters ⚠ auth" "⚠ auth"
cknothas "an error response body never reaches a title" "stub error body"
cknostamp "an auth failure is not a successful refresh"
reset
STUB_CURL="ok" STUB_HTTP=429 bash "$POLLER" --update; ckcode "429 --update" "$?" 1
ckhas "429 marks the meters ⚠ rate limit" "⚠ rate limit"
reset
STUB_CURL="ok" STUB_HTTP=503 bash "$POLLER" --update; ckcode "503 --update" "$?" 1
ckhas "5xx marks the meters ⚠ api down" "⚠ api down"
reset
STUB_CURL="fail" bash "$POLLER" --update >/dev/null 2>&1
ckhas "a transport failure stays ⚠ offline" "⚠ offline"

echo "T9: a response with no -w status line still parses (old curl / proxy)"
reset
STUB_CURL="ok" STUB_NO_CODE=1 bash "$POLLER" --update; ckcode "no-status-line --update" "$?" 0
ckhas "body-only response still paints 5h" "5h |7%"
ckhas "body-only response still paints 7d" "7d |42%"

echo "T10: the response cache collapses a human burst, but never a failure"
# print-then-update is the natural way to use this and it used to be two API calls
# seconds apart, on top of the 5-minute poll — that burst is what trips 429.
reset
STUB_CURL="ok" CMUX_SENTINEL_USAGE_CACHE_TTL=600 bash "$POLLER" --print >/dev/null
STUB_CURL="ok" CMUX_SENTINEL_USAGE_CACHE_TTL=600 bash "$POLLER" --update >/dev/null
ckcode "cached print+update still succeeds" "$?" 0
calls=$(wc -l < "$CURLCALLS" 2>/dev/null | tr -d ' ')
if [ "$calls" = "1" ]; then pass=$((pass + 1)); printf '  ✓ two invocations, one API call\n'
else fail=$((fail + 1)); printf '  ✗ two invocations made %s API calls (want 1)\n' "$calls"; fi
ckhas "the cached body still paints" "5h |7%"

# The mtime probe is the cache's one portability contract, and getting it backwards
# is INVISIBLE on whichever OS you develop on: probing BSD-first still works on
# macOS, while on Linux GNU's `-f` (--file-system) prints a block the digit check
# then rejects, so the cache reads cold forever and every burst is two API calls.
# That shipped — CI was red for ten commits while every local run passed. Pin BOTH.
for flavor in gnu bsd; do
  reset
  STUB_STAT="$flavor" STUB_CURL="ok" CMUX_SENTINEL_USAGE_CACHE_TTL=600 bash "$POLLER" --print >/dev/null
  STUB_STAT="$flavor" STUB_CURL="ok" CMUX_SENTINEL_USAGE_CACHE_TTL=600 bash "$POLLER" --update >/dev/null
  calls=$(wc -l < "$CURLCALLS" 2>/dev/null | tr -d ' ')
  if [ "$calls" = "1" ]; then pass=$((pass + 1)); printf '  ✓ %s stat: the burst still collapses to one call\n' "$flavor"
  else fail=$((fail + 1)); printf '  ✗ %s stat: two invocations made %s API calls (want 1)\n' "$flavor" "$calls"; fi
done

reset
STUB_CURL="ok" CMUX_SENTINEL_USAGE_CACHE_TTL=0 bash "$POLLER" --print >/dev/null
STUB_CURL="ok" CMUX_SENTINEL_USAGE_CACHE_TTL=0 bash "$POLLER" --print >/dev/null
calls=$(wc -l < "$CURLCALLS" 2>/dev/null | tr -d ' ')
if [ "$calls" = "2" ]; then pass=$((pass + 1)); printf '  ✓ TTL=0 disables the cache\n'
else fail=$((fail + 1)); printf '  ✗ TTL=0 made %s API calls (want 2)\n' "$calls"; fi

# A failure must never be WRITTEN to the cache: a 429 has to stay visible as
# ⚠ rate limit, and the next poll must retry the network rather than replay the
# error. (Within the TTL a warm cache means the 429 is never even reached — that
# is the point of the cache, and it's covered by the burst case above.)
reset
STUB_CURL="ok" STUB_HTTP=429 CMUX_SENTINEL_USAGE_CACHE_TTL=600 bash "$POLLER" --update >/dev/null 2>&1
ckcode "a cold-cache 429 fails" "$?" 1
ckhas "429 surfaces as ⚠ rate limit" "⚠ rate limit"
reset_warm   # keep whatever the failed run left behind
STUB_CURL="ok" STUB_HTTP=429 CMUX_SENTINEL_USAGE_CACHE_TTL=600 CMUX_SENTINEL_BACKOFF_BASE=0 bash "$POLLER" --update >/dev/null 2>&1
ckcode "the next poll fails again — the error was not cached" "$?" 1
calls=$(wc -l < "$CURLCALLS" 2>/dev/null | tr -d ' ')
if [ "$calls" = "1" ]; then pass=$((pass + 1)); printf '  ✓ a failed response is never served from cache\n'
else fail=$((fail + 1)); printf '  ✗ failed response made %s API calls (want 1 — a retry)\n' "$calls"; fi

echo "T11: the per-model weekly cap (opt-in m7d) — visible in --print, metered only on request"
# Anthropic publishes a model-scoped weekly cap in the modern limits[] array. It is
# NOT metered by default: a sentinel is an ordinary workspace, so the row would cost
# one of the ⌘1…⌘9 keys (same rule as the Amp orb meter).
reset
OUT=$(STUB_CURL="ok" STUB_SCOPED=15 bash "$POLLER" --print)
ckout "--print surfaces the cap even when it isn't metered" "m7d 15%"
ckout "--print says how to turn it on" "CLAUDE_MODEL_METER=1"
OUT=$(STUB_CURL="ok" STUB_SCOPED=15 CLAUDE_MODEL_METER=1 bash "$POLLER" --print)
ckoutnot "--print drops the hint once it IS metered" "CLAUDE_MODEL_METER=1"

# --buckets drives setup. Only a POSITIVE answer may suppress a sentinel.
reset
OUT=$(STUB_CURL="ok" STUB_SCOPED=15 bash "$POLLER" --buckets)
ckout "--buckets always lists the account-wide windows" "7d"
ckoutnot "--buckets omits m7d while the meter is off" "m7d"
reset
OUT=$(STUB_CURL="ok" STUB_SCOPED=15 CLAUDE_MODEL_METER=1 bash "$POLLER" --buckets)
ckout "--buckets lists m7d once opted in AND the cap exists" "m7d"
reset
OUT=$(STUB_CURL="ok" CLAUDE_MODEL_METER=1 bash "$POLLER" --buckets)
ckoutnot "--buckets omits m7d when the account has no such cap" "m7d"
reset
OUT=$(STUB_CURL="fail" CLAUDE_MODEL_METER=1 bash "$POLLER" --buckets 2>/dev/null)
if [ -z "$OUT" ]; then pass=$((pass + 1)); printf '  ✓ --buckets fails OPEN (silent when it cannot tell)\n'
else fail=$((fail + 1)); printf '  ✗ --buckets spoke up on a failed fetch: %s\n' "$OUT"; fi

# --update: off = never touch the row; on = paint it from the PAYLOAD's model name.
reset
STUB_CURL="ok" STUB_SCOPED=15 STUB_M7D=1 bash "$POLLER" --update >/dev/null
ckcode "opt-out update ignores the m7d sentinel entirely" "$?" 0
cknothas "opt-out update writes no m7d title" "m7d"
reset
STUB_CURL="ok" STUB_SCOPED=15 STUB_M7D=1 CLAUDE_MODEL_METER=1 bash "$POLLER" --update >/dev/null
ckcode "opted-in update succeeds" "$?" 0
# The sidebar draws the model name as the ROW LABEL and reads it from the 4th "|"
# segment, so the position is a contract, not cosmetics: put the name back in the
# detail and the row renders "model  Fable 15% (3d 2h)", saying it twice.
ckhas "m7d detail segment is pure metrics" "^m7d |15% ("
ckhas "…and the model name is the LAST segment, where the sidebar reads it" "|Fable$"
cknothas "the model name is NOT prefixed onto the detail" "|Fable 15%"
ckprog "m7d native progress value (15% → 0.15)" "PROG 0.15"
ckprognothas "the native label is pure metrics — the name is the row label" "Fable"
# The model name must come from the payload — Anthropic re-scopes which model is
# capped, and scope.model.id is null, so display_name is the only handle there is.
reset
STUB_CURL="ok" STUB_SCOPED=88 STUB_SCOPED_NAME="Zephyr" STUB_M7D=1 CLAUDE_MODEL_METER=1 bash "$POLLER" --update >/dev/null
ckhas "a renamed model follows the payload, not a hardcoded name" "|Zephyr$"
cknothas "no stale model name leaks into the row" "Fable"

# Opted in, but this account has no model-scoped cap: honest 'n/a', never a
# fabricated 0%, and never a hard failure (Anthropic adds and drops these).
reset
STUB_CURL="ok" STUB_M7D=1 CLAUDE_MODEL_METER=1 bash "$POLLER" --update >/dev/null
ckcode "a vanished cap is not an error" "$?" 0
ckhas "an unmetered m7d row reads n/a" "m7d |n/a|"
cknothas "a vanished cap never fabricates 0%" "m7d |.*0%"
ckhas "the account-wide meters still paint" "5h |7%"

# A missing m7d sentinel is a real broken install — but it must not cost the two
# account-wide meters (the ledger property T7 pins for 5h/7d).
reset
STUB_CURL="ok" STUB_SCOPED=15 CLAUDE_MODEL_METER=1 bash "$POLLER" --update >/dev/null 2>&1
ckcode "a missing m7d sentinel still reports failure" "$?" 1
ckhas "…but 5h still painted" "5h |7%"
ckhas "…and 7d still painted" "7d |42%"
ckstamp "a landed meter is still fresh data"

echo "T12: extra-usage SPEND — the row that hides itself"
# Money you have not spent is not information, and a permanent €0.00 row would train
# you to ignore the one row that matters when it finally moves. So the poller writes
# a marker the SIDEBAR keys on, rather than gating creation on the balance: gating
# creation would mean the meter can only appear after a setup re-run, and nobody
# re-runs setup because they suspect a charge they don't know about.
reset
STUB_CURL="ok" STUB_SPEND=1260 STUB_SPEND_WS=1 bash "$POLLER" --update >/dev/null
ckcode "a non-zero balance paints" "$?" 0
ckhas "spend row shows money against its budget" "spend |14% (€12.60 of €90.00)"
ckprog "spend gets a native bar too" "PROG 0.14"

reset
STUB_CURL="ok" STUB_SPEND=0 STUB_SPEND_WS=1 bash "$POLLER" --update >/dev/null
ckcode "a zero balance is not an error" "$?" 0
ckhas "a zero balance paints the hide marker" "spend |none|"
cknothas "a zero balance shows no money at all" "€0.00"
ckprog "a zero balance drops the native bar" "CLEAR"

reset
STUB_CURL="ok" STUB_SPEND_WS=1 bash "$POLLER" --update >/dev/null
ckcode "an account with no overage budget is not an error" "$?" 0
ckhas "no budget also hides the row" "spend |none|"

# --print is the diagnostic surface: it shows the money whether or not the sidebar
# would, so "why don't I see a spend row" has an answer that isn't guesswork.
reset
OUT=$(STUB_CURL="ok" STUB_SPEND=0 bash "$POLLER" --print)
ckout "--print shows a zero balance the sidebar hides" "€0.00 of €90.00"
ckout "--print explains the hidden row" "the sidebar hides this row"
reset   # else the 60s response cache replays the zero-balance body above
OUT=$(STUB_CURL="ok" STUB_SPEND=4500 bash "$POLLER" --print)
ckoutnot "--print drops the hint once there IS spend" "the sidebar hides this row"

# The sentinel tracks whether the ACCOUNT has a budget, not what the balance is —
# otherwise the row could never appear on its own.
reset
OUT=$(STUB_CURL="ok" STUB_SPEND=0 bash "$POLLER" --buckets)
ckout "--buckets lists spend even at a zero balance" "spend"
reset
OUT=$(STUB_CURL="ok" bash "$POLLER" --buckets)
ckoutnot "--buckets omits spend with no budget at all" "spend"

# Currency: never GUESS a symbol. An unrecognised code prints as the code.
reset
STUB_CURL="ok" STUB_SPEND=1260 STUB_SPEND_CUR="CZK" STUB_SPEND_WS=1 bash "$POLLER" --update >/dev/null
ckhas "an unknown currency prints its ISO code" "CZK 12.60"
reset
STUB_CURL="ok" STUB_SPEND=1260 STUB_SPEND_CUR="USD" STUB_SPEND_WS=1 bash "$POLLER" --update >/dev/null
ckhas "a known currency prints its symbol" "\$12.60"
# A zero-decimal currency (JPY, HUF) must not grow a fake decimal point.
reset
STUB_CURL="ok" STUB_SPEND=1260 STUB_SPEND_EXP=0 STUB_SPEND_LIMIT=9000 STUB_SPEND_CUR="JPY" STUB_SPEND_WS=1 bash "$POLLER" --update >/dev/null
ckhas "a zero-decimal currency has no decimal point" "JPY 1260 of JPY 9000"

# Real spend with no sentinel is a broken install — but it must not cost the other
# meters (the ledger property).
reset
STUB_CURL="ok" STUB_SPEND=1260 bash "$POLLER" --update >/dev/null 2>&1
ckcode "a missing spend sentinel reports failure" "$?" 1
ckhas "…but 5h still painted" "5h |7%"
ckhas "…and 7d still painted" "7d |42%"

echo "T13: a throttled poll keeps the meters, and stops hammering the endpoint"
# Reported from a second install: every Claude row sat on "⚠ rate limit" while
# Claude Code's own /usage showed real numbers. One 429 wiped three meters whose
# data was five minutes old, on windows that move over hours and days — and the
# next poll asked again on the same cadence that earned the 429.
reset
STUB_CURL="ok" bash "$POLLER" --update >/dev/null 2>&1     # a good body to fall back on
rm -f "$RENAMES" "$PROGRESS" "$STAMP" "$CURLCALLS"
STUB_CURL="ok" STUB_HTTP=429 CMUX_SENTINEL_USAGE_CACHE_TTL=0 bash "$POLLER" --update >/dev/null 2>&1
ckcode "a throttled poll still fails" "$?" 1
ckhas "the row keeps its number" "5h |7%"
ckhas "…and says how old it is" "old"
ckhas "the stale detail stays one | segment (the sidebar splits on it)" "5h |7% ·"
cknothas "no ⚠ marker while inside the grace window" "⚠ rate limit"
ckprog "the native bar is kept, not cleared" "PROG 0.07"
ckprognothas "a grace paint never clears progress" "CLEAR"
cknostamp "a grace paint is not fresh data"

# Backoff: the SECOND consecutive 429 must not reach the network at all. This is
# the half that lets a throttle clear instead of being renewed every 5 minutes.
rm -f "$CURLCALLS"
STUB_CURL="ok" STUB_HTTP=429 CMUX_SENTINEL_USAGE_CACHE_TTL=0 bash "$POLLER" --update >/dev/null 2>&1
calls=0; [ -f "$CURLCALLS" ] && calls=$(wc -l < "$CURLCALLS" | tr -d ' ')
if [ "${calls:-0}" = "0" ]; then pass=$((pass + 1)); printf '  ✓ a backed-off poll makes no API call\n'
else fail=$((fail + 1)); printf '  ✗ a backed-off poll still called the endpoint %s time(s)\n' "$calls"; fi
ckhas "…and still repaints the aged row" "5h |7%"

# An EXPIRED backoff window resumes fetching, and a success clears the state.
printf '1 3\n' > "$BACKOFF"          # deadline in 1970 = window already over
rm -f "$CURLCALLS" "$RENAMES"
STUB_CURL="ok" CMUX_SENTINEL_USAGE_CACHE_TTL=0 bash "$POLLER" --update >/dev/null 2>&1
ckcode "an expired backoff window fetches again" "$?" 0
ckhas "a recovered poll paints live numbers again" "5h |7% ("
if [ ! -f "$BACKOFF" ]; then pass=$((pass + 1)); printf '  ✓ a success clears the backoff state\n'
else fail=$((fail + 1)); printf '  ✗ backoff state survived a successful poll\n'; fi

# Only 429 backs off. A 401 or a dead network costs the endpoint nothing to retry
# and recovers the moment the user fixes it — deferring those keeps a meter dark
# for no reason.
reset
STUB_CURL="ok" STUB_HTTP=401 bash "$POLLER" --update >/dev/null 2>&1
if [ ! -f "$BACKOFF" ]; then pass=$((pass + 1)); printf '  ✓ an auth failure does not arm backoff\n'
else fail=$((fail + 1)); printf '  ✗ 401 armed the 429 backoff\n'; fi
reset
STUB_CURL="fail" bash "$POLLER" --update >/dev/null 2>&1
if [ ! -f "$BACKOFF" ]; then pass=$((pass + 1)); printf '  ✓ a transport failure does not arm backoff\n'
else fail=$((fail + 1)); printf '  ✗ a transport failure armed the 429 backoff\n'; fi

# The grace window is BOUNDED: past it the row must go back to the honest marker,
# so a genuinely dead pipeline still turns the panel off. That bound is the whole
# reason this is not "serve stale numbers forever".
reset
STUB_CURL="ok" bash "$POLLER" --update >/dev/null 2>&1
rm -f "$RENAMES" "$PROGRESS" "$CURLCALLS" "$BACKOFF"
touch -t 202601010000 "$CACHE"       # older than any sane grace window
STUB_CURL="ok" STUB_HTTP=429 CMUX_SENTINEL_USAGE_CACHE_TTL=0 bash "$POLLER" --update >/dev/null 2>&1
ckhas "past the grace window the row falls back to ⚠" "⚠ rate limit"
ckprog "…and the stale bar is cleared" "CLEAR"

# The off switch restores the pre-grace behaviour exactly.
reset
STUB_CURL="ok" bash "$POLLER" --update >/dev/null 2>&1
rm -f "$RENAMES" "$PROGRESS" "$CURLCALLS" "$BACKOFF"
STUB_CURL="ok" STUB_HTTP=429 CMUX_SENTINEL_STALE_GRACE=0 CMUX_SENTINEL_USAGE_CACHE_TTL=0 bash "$POLLER" --update >/dev/null 2>&1
ckhas "STALE_GRACE=0 marks ⚠ immediately" "⚠ rate limit"
cknothas "STALE_GRACE=0 keeps no number" "5h |7%"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
