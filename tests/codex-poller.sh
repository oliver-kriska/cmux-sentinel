#!/bin/bash
# codex-poller.sh — offline test for bin/cmux-codex-usage.sh.
#
# Stubs codex (presence), cmux, and a throwaway $HOME holding fake Codex rollout
# files, so it runs in CI on Linux too. PATH is restricted to keep the REAL codex
# binary out (so "not installed" is testable), with jq symlinked in. Asserts:
# disabled / not-installed / no-usable-snapshot(⚠ stale) / populated(bars) and the
# newest-first non-null fallback across files.
#
# Run:  make test   (or:  bash tests/codex-poller.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLER="${POLLER:-$HERE/../bin/cmux-codex-usage.sh}"
[ -f "$POLLER" ] || { echo "poller not found: $POLLER" >&2; exit 2; }

JQ="$(command -v jq)" || { echo "jq required for this test" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-codex-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/home/.config/cmux"
SESS="$ROOT/home/.codex/sessions/2026/06"
mkdir -p "$SESS"

# Fake cmux: ping ok; workspace list --json serves the two codex sentinels with
# their BARE labels (the real first-run state — no bar appended yet, which the
# poller must still resolve to bootstrap them); rename logs the resulting title.
cat > "$ROOT/bin/cmux" <<'FAKE'
#!/bin/bash
LOG="$CODEXTEST/.renames"
case "$1" in
  ping) exit 0 ;;
  workspace)
    [ "$2" = "list" ] && printf '{"workspaces":[{"title":"cx5h","ref":"workspace:1"},{"title":"cx7d","ref":"workspace:2"}]}\n'
    exit 0 ;;
  rename-workspace)
    shift; title=""
    while [ $# -gt 0 ]; do case "$1" in --workspace) shift 2 ;; *) title="$1"; shift ;; esac; done
    printf '%s\n' "$title" >> "$LOG"; exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$ROOT/bin/cmux"
ln -s "$JQ" "$ROOT/bin/jq"   # keep jq reachable under the restricted PATH

export CODEXTEST="$ROOT" HOME="$ROOT/home" TMPDIR="$ROOT"
# Restricted PATH: stubs first, then core dirs — deliberately NOT /opt/homebrew/bin,
# so the machine's real `codex` can't leak into "not installed" cases.
PATH="$ROOT/bin:/usr/bin:/bin"
RENAMES="$ROOT/.renames"
NOW=$(date +%s); R5=$((NOW + 18000)); R7=$((NOW + 604800))

snap() { # $1=primary_pct $2=secondary_pct  → one populated rollout line
  printf '{"type":"token_count","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":%s,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":%s,"window_minutes":10080,"resets_at":%s}}}}\n' "$1" "$R5" "$2" "$R7"
}
nullsnap() { printf '{"type":"token_count","payload":{"rate_limits":null}}\n'; }

codex_stub() { printf '#!/bin/bash\nexit 0\n' > "$ROOT/bin/codex"; chmod +x "$ROOT/bin/codex"; }
no_codex()   { rm -f "$ROOT/bin/codex"; }

pass=0; fail=0
ckcode() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  ✓ %s (exit %s)\n' "$1" "$2"
           else fail=$((fail + 1)); printf '  ✗ %s — exit got %s want %s\n' "$1" "$2" "$3"; fi; }
ckno()   { if [ ! -s "$RENAMES" ]; then pass=$((pass + 1)); printf '  ✓ %s (wrote nothing)\n' "$1"
           else fail=$((fail + 1)); printf '  ✗ %s — unexpected renames:\n%s\n' "$1" "$(cat "$RENAMES")"; fi; }
ckhas()  { if grep -q -- "$2" "$RENAMES" 2>/dev/null; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
           else fail=$((fail + 1)); printf '  ✗ %s — [%s] not in:\n%s\n' "$1" "$2" "$(cat "$RENAMES" 2>/dev/null)"; fi; }
reset()  { rm -f "$RENAMES" "$SESS"/rollout-*.jsonl; }

echo "T1: disabled (USAGE_PROVIDERS without codex) → exit 0, writes nothing"
reset; codex_stub; snap 33 12 > "$SESS/rollout-2026-06-19T06-00-00-aaaa.jsonl"
USAGE_PROVIDERS="claude" bash "$POLLER" --update; ckcode "disabled --update" "$?" 0
ckno "disabled is a no-op"

echo "T2: not installed (no codex binary, no ~/.codex/sessions) → exit 0, nothing"
reset; no_codex; rm -rf "$ROOT/home/.codex"
USAGE_PROVIDERS="claude codex" bash "$POLLER" --update; ckcode "not-installed --update" "$?" 0
ckno "not-installed is a no-op"
mkdir -p "$SESS"   # restore for later tests

echo "T3: installed + no usable snapshot (only null) → exit 1, ⚠ stale stamped"
reset; codex_stub; nullsnap > "$SESS/rollout-2026-06-19T06-00-00-bbbb.jsonl"
USAGE_PROVIDERS="claude codex" bash "$POLLER" --update; ckcode "no-snapshot --update" "$?" 1
ckhas "stamps ⚠" "⚠"

echo "T4: installed + populated → exit 0, cx5h/cx7d bars with percentages"
reset; codex_stub; snap 33 12 > "$SESS/rollout-2026-06-19T06-00-00-cccc.jsonl"
USAGE_PROVIDERS="claude codex" bash "$POLLER" --update; ckcode "populated --update" "$?" 0
ckhas "cx5h sentinel renamed" "cx5h "
ckhas "cx5h pct" "33%"
ckhas "cx7d pct" "12%"

echo "T5: newest file is null-only → falls back to latest non-null in older file"
reset; codex_stub
nullsnap > "$SESS/rollout-2026-06-19T09-00-00-dddd.jsonl"   # newest, useless
snap 47 7 > "$SESS/rollout-2026-06-19T06-00-00-eeee.jsonl"  # older, populated
USAGE_PROVIDERS="claude codex" bash "$POLLER" --update; ckcode "fallback --update" "$?" 0
ckhas "fell back to older snapshot" "47%"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
