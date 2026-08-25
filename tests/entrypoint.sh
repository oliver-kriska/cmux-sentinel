#!/bin/bash
# entrypoint.sh — offline test for bin/cmux-sentinel, the single dispatcher.
#
# The property under test is NOT "does it print a menu". It is that the
# dispatcher never becomes a second implementation: every command must reach the
# real script, with arguments and exit status intact, and it must keep working
# from a repo checkout, a ~/bin install, and a Homebrew-style bin+libexec layout.
# The nine cmux-*.sh scripts stay callable directly because four LaunchAgents
# reference them by absolute path.
#
# Run:  make test   (or:  bash tests/entrypoint.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRY="${ENTRY:-$HERE/../bin/cmux-sentinel}"
[ -f "$ENTRY" ] || { echo "entrypoint not found: $ENTRY" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-entry-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export HOME="$ROOT/home"
mkdir -p "$HOME/.config/cmux-sentinel"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  ✗ %s\n' "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# A recorder standing in for each helper script: logs argv, echoes a marker, and
# exits with a status we choose, so we can prove pass-through in both directions.
mkrec() { # $1 = dir  $2 = name  $3 = exit code
  mkdir -p "$1"
  cat > "$1/$2" <<REC
#!/bin/bash
printf '%s ' "\$@" >> "$ROOT/argv.$2"
printf '\n' >> "$ROOT/argv.$2"
echo "RAN:$2"
exit $3
REC
  chmod +x "$1/$2"
}

echo "T1: commands reach the real script, with args and exit status intact"
BIN="$ROOT/repo"; mkrec "$BIN" cmux-sentinel-setup.sh 0
cp "$ENTRY" "$BIN/cmux-sentinel"; chmod +x "$BIN/cmux-sentinel"
out="$("$BIN/cmux-sentinel" setup --no-layout 2>&1)"; rc=$?
if has "$out" "RAN:cmux-sentinel-setup.sh"; then ok "setup dispatches to the setup script"; else bad "setup did not dispatch"; fi
if [ "$rc" = 0 ]; then ok "a successful command exits 0"; else bad "successful command exited $rc"; fi
argv="$(cat "$ROOT/argv.cmux-sentinel-setup.sh" 2>/dev/null)"
if has "$argv" "--no-layout"; then ok "arguments are passed through untouched"; else bad "arguments were swallowed: [$argv]"; fi

# Exit status must survive: a wrapper that always exits 0 turns a failed setup
# into a silent one, which is the exact class of bug this project keeps fixing.
mkrec "$BIN" cmux-sentinel-doctor.sh 3
"$BIN/cmux-sentinel" doctor >/dev/null 2>&1; rc=$?
if [ "$rc" = 3 ]; then ok "a failing command's exit status survives"; else bad "exit status was rewritten to $rc"; fi

echo "T2: the Homebrew layout (bin/ shim + libexec/ payload) resolves"
BREW="$ROOT/brew"; mkdir -p "$BREW/bin"
cp "$ENTRY" "$BREW/bin/cmux-sentinel"; chmod +x "$BREW/bin/cmux-sentinel"
mkrec "$BREW/libexec/cmux-sentinel" cmux-sentinel-setup.sh 0
out="$("$BREW/bin/cmux-sentinel" setup 2>&1)"
if has "$out" "RAN:cmux-sentinel-setup.sh"; then ok "finds helpers in ../libexec/cmux-sentinel"; else bad "libexec layout did not resolve: $out"; fi

echo "T3: a missing helper says where it looked"
EMPTY="$ROOT/empty"; mkdir -p "$EMPTY"
cp "$ENTRY" "$EMPTY/cmux-sentinel"; chmod +x "$EMPTY/cmux-sentinel"
out="$("$EMPTY/cmux-sentinel" setup 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then ok "a missing helper is an error, not a silent no-op"; else bad "missing helper exited 0"; fi
if has "$out" "looked in"; then ok "names the directories it searched"; else bad "gave no search paths: $out"; fi

echo "T4: usage aggregates the providers that have something to say"
AGG="$ROOT/agg"; mkdir -p "$AGG"
cp "$ENTRY" "$AGG/cmux-sentinel"; chmod +x "$AGG/cmux-sentinel"
# shellcheck disable=SC2016  # the $1 is for the generated script, not this one
printf '#!/bin/bash\n[ "$1" = --print ] && echo "5h  7%%"\nexit 0\n' > "$AGG/cmux-claude-usage.sh"
# A gated-off provider prints NOTHING and exits non-zero; that is its contract,
# and it must not make `usage` look broken or suppress the providers that worked.
printf '#!/bin/bash\necho "codex disabled" >&2\nexit 1\n' > "$AGG/cmux-codex-usage.sh"
chmod +x "$AGG/cmux-claude-usage.sh" "$AGG/cmux-codex-usage.sh"
out="$("$AGG/cmux-sentinel" usage 2>/dev/null)"; rc=$?
if has "$out" "5h  7%"; then ok "prints the provider that answered"; else bad "lost the working provider's output"; fi
if has "$out" "codex disabled"; then bad "leaked a gated provider's stderr into the report"; else ok "a gated provider stays quiet"; fi
if [ "$rc" = 0 ]; then ok "a gated provider does not fail the whole report"; else bad "usage exited $rc"; fi

echo "T5: version reads the installer's stamp"
out="$("$AGG/cmux-sentinel" version 2>&1)"
if has "$out" "no version stamp"; then ok "unstamped install says so"; else bad "unstamped install was not reported: $out"; fi
printf 'version=0.2.0\ninstalled=2026-08-25\ncommit=abc1234\n' > "$HOME/.config/cmux-sentinel/VERSION"
out="$("$AGG/cmux-sentinel" version 2>&1)"
if has "$out" "0.2.0"; then ok "reports the stamped version"; else bad "version not reported: $out"; fi
if has "$out" "abc1234"; then ok "reports the commit"; else bad "commit not reported"; fi

echo "T6: an unknown command fails loudly and shows the commands"
out="$("$AGG/cmux-sentinel" bogus 2>&1)"; rc=$?
if [ "$rc" = 2 ]; then ok "unknown command exits 2"; else bad "unknown command exited $rc"; fi
if has "$out" "unknown command 'bogus'"; then ok "names the bad command"; else bad "did not name the bad command"; fi
if has "$out" "cmux-sentinel doctor"; then ok "shows what it could have run"; else bad "no command list on error"; fi
out="$("$AGG/cmux-sentinel" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "bare invocation is help, not an error"; else bad "bare invocation exited $rc"; fi

echo "T7: the real Homebrew layout — whole tree in libexec, exec-script in bin"
# Homebrew stages the tree at libexec/ and generates bin/cmux-sentinel as a
# wrapper that execs the libexec path. A bin.install_symlink would NOT work:
# through a symlink $0 stays in the prefix's bin/, where no helper lives.
CELLAR="$ROOT/Cellar/cmux-sentinel/0.2.0"
mkdir -p "$CELLAR/libexec/bin" "$CELLAR/bin"
cp "$ENTRY" "$CELLAR/libexec/bin/cmux-sentinel"; chmod +x "$CELLAR/libexec/bin/cmux-sentinel"
mkrec "$CELLAR/libexec/bin" cmux-sentinel-doctor.sh 0
printf '#!/bin/bash\nexec "%s" "$@"\n' "$CELLAR/libexec/bin/cmux-sentinel" > "$CELLAR/bin/cmux-sentinel"
chmod +x "$CELLAR/bin/cmux-sentinel"
out="$("$CELLAR/bin/cmux-sentinel" doctor 2>&1)"
if has "$out" "RAN:cmux-sentinel-doctor.sh"; then ok "exec-script wrapper resolves the payload"; else bad "brew layout did not dispatch: $out"; fi

echo "T8: deploy runs the tree's own install.sh, never a second implementation"
# install.sh is the one deployer (its own 59-assertion suite); deploy locates it.
cat > "$CELLAR/libexec/install.sh" <<'INS'
#!/bin/bash
echo "RAN:install.sh $*"
exit 7
INS
chmod +x "$CELLAR/libexec/install.sh"
: > "$CELLAR/libexec/bin/cmux-claude-usage.sh"   # the marker deploy looks for
out="$("$CELLAR/bin/cmux-sentinel" deploy --with-zed 2>&1)"; rc=$?
if has "$out" "RAN:install.sh --with-zed"; then ok "deploy execs the tree's installer with args"; else bad "deploy did not reach install.sh: $out"; fi
if [ "$rc" = 7 ]; then ok "the installer's exit status survives deploy"; else bad "deploy rewrote the status to $rc"; fi
# A ~/bin install has scripts but no tree; that must be an explicit error naming
# the search paths, not a confusing failure from install.sh's own bootstrap.
out="$("$AGG/cmux-sentinel" deploy 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then ok "no source tree is an error"; else bad "deploy with no tree exited 0"; fi
if has "$out" "no source tree"; then ok "says there is no tree to deploy from"; else bad "unclear no-tree error: $out"; fi
if has "$out" "cmux-sentinel update"; then ok "points at the command that fetches one"; else bad "no recovery offered"; fi

echo "T9: version distinguishes what is DEPLOYED from what you just typed"
# The stamp is what launchd runs; the Cellar path is what brew last installed.
# Print one number only and "I upgraded" / "it's still broken" are both true.
out="$("$CELLAR/bin/cmux-sentinel" version 2>&1)"
if has "$out" "0.2.0"; then ok "reports the deployed stamp"; else bad "lost the stamp: $out"; fi
if has "$out" "homebrew  0.2.0"; then ok "names the Homebrew version in play"; else bad "did not report the brew version: $out"; fi
if has "$out" "deploy"; then bad "warned about a mismatch when both are 0.2.0"; else ok "no warning when they agree"; fi
# Now make them disagree — the state right after `brew upgrade`.
NEWER="$ROOT/Cellar/cmux-sentinel/0.9.0"; mkdir -p "$NEWER/bin"
cp "$ENTRY" "$NEWER/bin/cmux-sentinel"; chmod +x "$NEWER/bin/cmux-sentinel"
out="$("$NEWER/bin/cmux-sentinel" version 2>&1)"
if has "$out" "0.9.0"; then ok "reports the newer Homebrew version"; else bad "did not see the upgrade: $out"; fi
if has "$out" "still 0.2.0"; then ok "says the deployed copy is behind"; else bad "silent about the stale deploy: $out"; fi
if has "$out" "cmux-sentinel deploy"; then ok "names the command that fixes it"; else bad "no recovery offered: $out"; fi
# A plain ~/bin install has no Cellar path and must not grow a phantom line.
out="$("$AGG/cmux-sentinel" version 2>&1)"
if has "$out" "homebrew"; then bad "reported Homebrew on a non-brew install"; else ok "non-brew install says nothing about brew"; fi

echo "T10: a Homebrew-managed copy refuses to curl-install over itself"
# Re-running the curl installer would overwrite ~/bin while brew still reports a
# version it no longer controls — two updaters, one silently losing.
out="$("$CELLAR/bin/cmux-sentinel" update 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then ok "brew-managed update is refused"; else bad "brew-managed update ran the curl installer"; fi
if has "$out" "brew upgrade cmux-sentinel"; then ok "names the Homebrew update path"; else bad "did not name brew upgrade: $out"; fi
if has "$out" "cmux-sentinel deploy"; then ok "reminds that brew alone changes nothing running"; else bad "no deploy reminder: $out"; fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
