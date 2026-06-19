#!/bin/bash
# sentinel-setup.sh — offline test for bin/cmux-sentinel-setup.sh.
#
# Stubs cmux (with a throwaway $HOME) so it runs in CI too. Asserts the idempotent
# create behaviour: only enabled providers get sentinels, existing ones are left
# alone, and the auto-naming guard reports the global state.
#
# Run:  make test   (or:  bash tests/sentinel-setup.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="${SETUP:-$HERE/../bin/cmux-sentinel-setup.sh}"
[ -f "$SETUP" ] || { echo "setup not found: $SETUP" >&2; exit 2; }
JQ="$(command -v jq)" || { echo "jq required" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-setup-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/home/.config/cmux"
ln -s "$JQ" "$ROOT/bin/jq"

# Fake cmux: ping ok; workspace create logs the --name; workspace list returns the
# four sentinels when STUB_EXISTING is set (else none); the set_auto_title probe
# reports global auto-naming OFF unless STUB_AUTONAMING=on.
cat > "$ROOT/bin/cmux" <<'FAKE'
#!/bin/bash
LOG="$SETUPTEST/.created"
case "$1" in
  ping) exit 0 ;;
  list-windows) printf '[{"id":"win-a"}]\n'; exit 0 ;;
  workspace)
    case "$2" in
      list)
        if [ -n "${STUB_EXISTING:-}" ]; then
          printf '{"workspaces":[{"title":"5h x","ref":"w1"},{"title":"7d x","ref":"w2"},{"title":"cx5h x","ref":"w3"},{"title":"cx7d x","ref":"w4"}]}\n'
        else printf '{"workspaces":[]}\n'; fi ;;
      create)
        shift 2; name=""
        while [ $# -gt 0 ]; do case "$1" in --name) name="$2"; shift 2 ;; *) shift ;; esac; done
        printf '%s\n' "$name" >> "$LOG"; echo "OK workspace:99" ;;
    esac
    exit 0 ;;
  rpc)
    if [ "$2" = "workspace.set_auto_title" ]; then
      if [ "${STUB_AUTONAMING:-off}" = "on" ]; then echo "Error: missing required param workspace_id" >&2
      else echo "Error: disabled: Workspace auto-naming is disabled in Settings" >&2; fi
      exit 1
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$ROOT/bin/cmux"

export SETUPTEST="$ROOT" HOME="$ROOT/home" TMPDIR="$ROOT"
PATH="$ROOT/bin:/usr/bin:/bin"
CREATED="$ROOT/.created"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  ✗ %s\n' "$1"; }
ck()  { local m="$1"; shift; if "$@"; then ok "$m"; else bad "$m"; fi; }   # cmd true
ckn() { local m="$1"; shift; if "$@"; then bad "$m"; else ok "$m"; fi; }   # cmd false
ckhas() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" ;; esac; }           # substring
created() { grep -qx -- "$1" "$CREATED" 2>/dev/null; }       # was label $1 created?
ncreated() { [ -f "$CREATED" ] && wc -l < "$CREATED" | tr -d ' ' || echo 0; }
reset() { rm -f "$CREATED"; }

echo "T1: providers=claude → creates 5h + 7d only"
reset
USAGE_PROVIDERS="claude" bash "$SETUP" >/dev/null 2>&1; ck "exit 0" [ "$?" = 0 ]
ck  "created 5h"  created 5h
ck  "created 7d"  created 7d
ckn "did not create cx5h (codex disabled)" created cx5h
ck  "exactly 2 created" [ "$(ncreated)" = 2 ]

echo "T2: providers=\"claude codex\" → creates all four"
reset
USAGE_PROVIDERS="claude codex" bash "$SETUP" >/dev/null 2>&1
for l in 5h 7d cx5h cx7d; do ck "created $l" created "$l"; done

echo "T3: idempotent — existing sentinels are left alone"
reset
out=$(STUB_EXISTING=1 USAGE_PROVIDERS="claude codex" bash "$SETUP" 2>&1); rc=$?
ck "exit 0" [ "$rc" = 0 ]
ck "created nothing (all exist)" [ "$(ncreated)" = 0 ]
ckhas "reported existing" "$out" "already exists"

echo "T4: auto-naming guard reports global state"
out=$(USAGE_PROVIDERS="claude" bash "$SETUP" 2>&1)
ckhas "OFF → reports safe" "$out" "auto-naming is OFF"
out=$(STUB_AUTONAMING=on USAGE_PROVIDERS="claude" bash "$SETUP" 2>&1)
ckhas "ON → warns" "$out" "may be ON"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
