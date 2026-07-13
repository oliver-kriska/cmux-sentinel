#!/bin/bash
# open-in-zed.sh — offline test for bin/cmux-open-in-zed.sh.
#
# Uses --print (dry-run) to assert the composed `zed` command for each mode, then a
# stubbed `zed` on PATH to confirm real invocation. No Zed, no network.
#
# Run:  make test   (or:  bash tests/open-in-zed.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SUT:-$HERE/../bin/cmux-open-in-zed.sh}"
[ -f "$SUT" ] || { echo "script not found: $SUT" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/open-in-zed-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

# A git repo (worktree root) and a nested subdir; a plain non-git dir.
REPO="$ROOT/repo"; mkdir -p "$REPO/sub"; ( cd "$REPO" && git init -q ) 2>/dev/null
# Canonicalize like `git rev-parse --show-toplevel` does (macOS /var→/private/var
# symlink + strips any // from $TMPDIR) so expectations match on macOS and Linux.
REPO="$(cd "$REPO" && pwd -P)"
PLAIN="$ROOT/plain"; mkdir -p "$PLAIN"; PLAIN="$(cd "$PLAIN" && pwd -P)"

pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
       else fail=$((fail + 1)); printf '  ✗ %s — got [%s] want [%s]\n' "$1" "$2" "$3"; fi; }

echo "A: dry-run command composition (worktree-aware)"
ck "switch → zed <worktree root>"  "$(cd "$REPO/sub" && bash "$SUT" --print)"        "zed $REPO"
ck "explicit path → its root"      "$(bash "$SUT" --print "$REPO/sub")"              "zed $REPO"
ck "--add → zed --add <root>"      "$(cd "$REPO" && bash "$SUT" --add --print)"      "zed --add $REPO"
ck "--new → zed --new <root>"      "$(cd "$REPO" && bash "$SUT" --new --print)"      "zed --new $REPO"
ck "non-git dir → dir itself"      "$(bash "$SUT" --print "$PLAIN")"                 "zed $PLAIN"
ck "ZED_BIN override honored"      "$(ZED_BIN=zedd bash "$SUT" --print "$PLAIN")"    "zedd $PLAIN"

echo "B: error handling"
out=$(bash "$SUT" --print "$ROOT/nope" 2>&1); rc=$?
ck "missing dir → non-zero exit"   "$rc" "2"
out=$(bash "$SUT" --bogus 2>&1; echo ":$?"); ck "unknown option → exit 2" "${out##*:}" "2"

echo "D: --shell-init snippet"
si=$(bash "$SUT" --shell-init)
case "$si" in *"alias ze='$(cd "$(dirname "$SUT")" && pwd)/$(basename "$SUT")'"*) ck "alias points at script abs path" y y ;; *) ck "alias points at script abs path" n y ;; esac
case "$si" in *"bindkey '^O'"*)            ck "default keybind ^O"          y y ;; *) ck "default keybind ^O" n y ;; esac
case "$si" in *'ZSH_VERSION'*)             ck "gated on ZSH_VERSION"        y y ;; *) ck "gated on ZSH_VERSION" n y ;; esac
case "$(bash "$SUT" --shell-init --key '^E')" in *"bindkey '^E'"*) ck "--key overrides keybind" y y ;; *) ck "--key overrides keybind" n y ;; esac
# emitted snippet must be valid shell
if printf '%s\n' "$si" | bash -n 2>/dev/null; then ck "snippet parses as shell" y y; else ck "snippet parses as shell" n y; fi

echo "C: real invocation via stubbed zed"
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/zed" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" > "$ZEDLOG"
STUB
chmod +x "$ROOT/bin/zed"
export ZEDLOG="$ROOT/zed.args"
PATH="$ROOT/bin:$PATH" bash "$SUT" "$REPO/sub"
ck "exec zed received worktree root" "$(cat "$ZEDLOG" 2>/dev/null)" "$REPO"

echo
echo "open-in-zed: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
