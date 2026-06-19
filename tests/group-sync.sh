#!/bin/bash
# group-sync.sh — offline test for bin/cmux-group-sync.sh.
#
# Stubs cmux with file-backed fixtures (windows / per-window workspace list /
# per-window group list) so it runs in CI on Linux too. PATH is restricted (stubs
# first, jq symlinked) so the test exercises the poller under /bin/bash 3.2 like
# launchd does. Asserts: opt-in gate, no-groups no-op, diverged rename, idempotency,
# agent-marker preservation, unnamed-group skip, multi-window --window, and that
# --list never mutates.
#
# Fixtures the stub serves (each test writes them):
#   windows.json        → `cmux list-windows --json`
#   ws-<window>.json    → `cmux workspace list --window <window> --json`
#   grp-<window>.json   → `cmux workspace-group list --window <window> --json`
# Renames are logged to .renames as "<window>\t<ref>\t<title>".
#
# Run:  make test   (or:  bash tests/group-sync.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLER="${POLLER:-$HERE/../bin/cmux-group-sync.sh}"
[ -f "$POLLER" ] || { echo "poller not found: $POLLER" >&2; exit 2; }

JQ="$(command -v jq)" || { echo "jq required for this test" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-group-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/home/.config/cmux"

cat > "$ROOT/bin/cmux" <<'FAKE'
#!/bin/bash
T="$GSTEST"
case "$1" in
  ping) exit 0 ;;
  list-windows) cat "$T/windows.json" 2>/dev/null || echo '[]'; exit 0 ;;
  workspace)
    if [ "$2" = "list" ]; then
      win=""; shift 2
      while [ $# -gt 0 ]; do case "$1" in --window) win="$2"; shift 2 ;; *) shift ;; esac; done
      cat "$T/ws-$win.json" 2>/dev/null || echo '{"workspaces":[]}'
    fi
    exit 0 ;;
  workspace-group)
    if [ "$2" = "list" ]; then
      win=""; shift 2
      while [ $# -gt 0 ]; do case "$1" in --window) win="$2"; shift 2 ;; *) shift ;; esac; done
      cat "$T/grp-$win.json" 2>/dev/null || echo '{"groups":[]}'
    fi
    exit 0 ;;
  rename-workspace)
    shift; ref=""; win=""; title=""
    while [ $# -gt 0 ]; do case "$1" in --workspace) ref="$2"; shift 2 ;; --window) win="$2"; shift 2 ;; *) title="$1"; shift ;; esac; done
    printf '%s\t%s\t%s\n' "$win" "$ref" "$title" >> "$T/.renames"
    exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$ROOT/bin/cmux"
ln -s "$JQ" "$ROOT/bin/jq"

export GSTEST="$ROOT" HOME="$ROOT/home" TMPDIR="$ROOT"
PATH="$ROOT/bin:/usr/bin:/bin"
RENAMES="$ROOT/.renames"

setwin() { printf '%s' "$1" > "$ROOT/windows.json"; }                 # $1 = json array
setws()  { printf '%s' "$2" > "$ROOT/ws-$1.json"; }                   # $1 = window  $2 = json
setgrp() { printf '%s' "$2" > "$ROOT/grp-$1.json"; }                  # $1 = window  $2 = json

pass=0; fail=0
ckcode()  { if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  ✓ %s (exit %s)\n' "$1" "$2"
            else fail=$((fail + 1)); printf '  ✗ %s — exit got %s want %s\n' "$1" "$2" "$3"; fi; }
ckno()    { if [ ! -s "$RENAMES" ]; then pass=$((pass + 1)); printf '  ✓ %s (wrote nothing)\n' "$1"
            else fail=$((fail + 1)); printf '  ✗ %s — unexpected renames:\n%s\n' "$1" "$(cat "$RENAMES")"; fi; }
ckhas()   { if grep -q -- "$2" "$RENAMES" 2>/dev/null; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
            else fail=$((fail + 1)); printf '  ✗ %s — [%s] not in:\n%s\n' "$1" "$2" "$(cat "$RENAMES" 2>/dev/null)"; fi; }
cknohas() { if grep -q -- "$2" "$RENAMES" 2>/dev/null; then fail=$((fail + 1)); printf '  ✗ %s — [%s] unexpectedly in:\n%s\n' "$1" "$2" "$(cat "$RENAMES")"
            else pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; fi; }
ckout()   { if printf '%s' "$2" | grep -q -- "$3"; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
            else fail=$((fail + 1)); printf '  ✗ %s — [%s] not in output:\n%s\n' "$1" "$3" "$2"; fi; }
reset()   { rm -f "$RENAMES" "$ROOT"/windows.json "$ROOT"/ws-*.json "$ROOT"/grp-*.json; }

# Common single-window fixtures: one group "Payduct" whose anchor (workspace:5)
# still carries a stale/generic title.
one_window_diverged() {
  setwin '[{"id":"w1"}]'
  setws  w1 '{"workspaces":[{"title":"Group 2","ref":"workspace:5"},{"title":"Payduct App","ref":"workspace:6"}]}'
  setgrp w1 '{"groups":[{"name":"Payduct","anchor_workspace_ref":"workspace:5"}]}'
}

echo "T1: --update without GROUP_NAME_SYNC=1 → disabled no-op (exit 0, no rename)"
reset; one_window_diverged
bash "$POLLER" --update; ckcode "disabled --update" "$?" 0
ckno "disabled is a no-op"

echo "T2: enabled but no groups → exit 0, writes nothing"
reset; setwin '[{"id":"w1"}]'; setws w1 '{"workspaces":[]}'; setgrp w1 '{"groups":[]}'
GROUP_NAME_SYNC=1 bash "$POLLER" --update; ckcode "no-groups --update" "$?" 0
ckno "no-groups is a no-op"

echo "T3: enabled + diverged anchor → renames anchor to group name (with --window)"
reset; one_window_diverged
GROUP_NAME_SYNC=1 bash "$POLLER" --update; ckcode "diverged --update" "$?" 0
ckhas "anchor renamed to group name" "	workspace:5	Payduct"
ckhas "rename carried the window" "w1	workspace:5	"

echo "T4: anchor title already == group name → idempotent (no rename)"
reset; setwin '[{"id":"w1"}]'
setws  w1 '{"workspaces":[{"title":"Payduct","ref":"workspace:5"}]}'
setgrp w1 '{"groups":[{"name":"Payduct","anchor_workspace_ref":"workspace:5"}]}'
GROUP_NAME_SYNC=1 bash "$POLLER" --update; ckcode "in-sync --update" "$?" 0
ckno "in-sync writes nothing"

echo "T5: agent marker on an in-sync anchor → preserved, no churn"
reset; setwin '[{"id":"w1"}]'
setws  w1 '{"workspaces":[{"title":"⚡Payduct","ref":"workspace:5"}]}'
setgrp w1 '{"groups":[{"name":"Payduct","anchor_workspace_ref":"workspace:5"}]}'
GROUP_NAME_SYNC=1 bash "$POLLER" --update; ckcode "marker in-sync --update" "$?" 0
ckno "marker anchor not rewritten"

echo "T5b: agent marker on a DIVERGED anchor → rename keeps the marker prefix"
reset; setwin '[{"id":"w1"}]'
setws  w1 '{"workspaces":[{"title":"⚡Group 2","ref":"workspace:5"}]}'
setgrp w1 '{"groups":[{"name":"Payduct","anchor_workspace_ref":"workspace:5"}]}'
GROUP_NAME_SYNC=1 bash "$POLLER" --update; ckcode "marker diverged --update" "$?" 0
ckhas "renamed to ⚡+name" "	workspace:5	⚡Payduct"

echo "T6: unnamed group (name null/empty) → skipped, never overwrites with empty"
reset; setwin '[{"id":"w1"}]'
setws  w1 '{"workspaces":[{"title":"Group 7","ref":"workspace:9"}]}'
setgrp w1 '{"groups":[{"name":null,"anchor_workspace_ref":"workspace:9"}]}'
GROUP_NAME_SYNC=1 bash "$POLLER" --update; ckcode "unnamed --update" "$?" 0
ckno "unnamed group skipped"

echo "T7: group lives in a NON-default window → renamed via --window"
reset; setwin '[{"id":"w1"},{"id":"w2"}]'
setws  w1 '{"workspaces":[]}'; setgrp w1 '{"groups":[]}'
setws  w2 '{"workspaces":[{"title":"Group 3","ref":"workspace:12"}]}'
setgrp w2 '{"groups":[{"name":"Streeyt","anchor_workspace_ref":"workspace:12"}]}'
GROUP_NAME_SYNC=1 bash "$POLLER" --update; ckcode "multi-window --update" "$?" 0
ckhas "renamed in the right window" "w2	workspace:12	Streeyt"

echo "T8: --list is read-only → reports the target but never renames"
reset; one_window_diverged
out="$(GROUP_NAME_SYNC=1 bash "$POLLER" --list)"; ckcode "--list" "$?" 0
ckout "--list shows the rename target" "$out" "Payduct"
ckno "--list never mutates"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
