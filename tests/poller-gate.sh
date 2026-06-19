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
case "$1" in
  ping) exit 0 ;;
  workspace)
    [ "$2" = "list" ] && printf '{"workspaces":[{"title":"5h init","ref":"workspace:1"},{"title":"7d init","ref":"workspace:2"}]}\n'
    exit 0 ;;
  rename-workspace)
    shift; title=""
    while [ $# -gt 0 ]; do case "$1" in --workspace) shift 2 ;; *) title="$1"; shift ;; esac; done
    printf '%s\n' "$title" >> "$LOG"; exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$ROOT/bin/cmux"

# Fake security: always "not found" — the test controls "installed" via the creds
# file only, so there's no machine-Keychain dependency.
printf '#!/bin/bash\nexit 1\n' > "$ROOT/bin/security"; chmod +x "$ROOT/bin/security"

# Fake curl: STUB_CURL=ok → emit usage JSON; otherwise fail (simulates offline).
cat > "$ROOT/bin/curl" <<'FAKE'
#!/bin/bash
[ "${STUB_CURL:-fail}" = "ok" ] || exit 1
printf '{"five_hour":{"utilization":7,"resets_at":"2026-06-19T20:00:00Z"},"seven_day":{"utilization":42,"resets_at":"2026-06-25T00:00:00Z"}}\n'
FAKE
chmod +x "$ROOT/bin/curl"

export POLLERTEST="$ROOT" HOME="$ROOT/home" TMPDIR="$ROOT"
PATH="$ROOT/bin:$PATH"
CREDS="$ROOT/home/.claude/.credentials.json"
RENAMES="$ROOT/.renames"
TOKEN_JSON='{"claudeAiOauth":{"accessToken":"faketoken"}}'

pass=0; fail=0
ckcode() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  ✓ %s (exit %s)\n' "$1" "$2"
           else fail=$((fail + 1)); printf '  ✗ %s — exit got %s want %s\n' "$1" "$2" "$3"; fi; }
ckno()   { if [ ! -s "$RENAMES" ]; then pass=$((pass + 1)); printf '  ✓ %s (wrote nothing)\n' "$1"
           else fail=$((fail + 1)); printf '  ✗ %s — unexpected renames:\n%s\n' "$1" "$(cat "$RENAMES")"; fi; }
ckhas()  { if grep -q -- "$2" "$RENAMES" 2>/dev/null; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
           else fail=$((fail + 1)); printf '  ✗ %s — [%s] not in:\n%s\n' "$1" "$2" "$(cat "$RENAMES" 2>/dev/null)"; fi; }
reset()  { rm -f "$RENAMES"; }

echo "T1: disabled (USAGE_PROVIDERS without claude) → exit 0, writes nothing"
reset; printf '%s' "$TOKEN_JSON" > "$CREDS"          # installed, but explicitly disabled
USAGE_PROVIDERS="codex" bash "$POLLER" --update; ckcode "disabled --update" "$?" 0
ckno "disabled is a no-op"

echo "T2: not installed (no creds, no Keychain) → exit 0, writes nothing"
reset; rm -f "$CREDS"
bash "$POLLER" --update; ckcode "not-installed --update" "$?" 0
ckno "not-installed is a no-op"

echo "T3: installed + offline (creds present, fetch fails) → exit 1, ⚠ offline stamped"
reset; printf '%s' "$TOKEN_JSON" > "$CREDS"
STUB_CURL="fail" bash "$POLLER" --update; ckcode "installed+offline --update" "$?" 1
ckhas "offline stamps ⚠" "⚠"

echo "T4: installed + reachable → exit 0, bars written with percentages"
reset
STUB_CURL="ok" bash "$POLLER" --update; ckcode "installed+ok --update" "$?" 0
ckhas "5h sentinel renamed" "5h "
ckhas "5h utilization" "7%"
ckhas "7d utilization" "42%"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
