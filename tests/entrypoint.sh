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

echo "T11: same version does NOT mean same files — the payload fingerprint says so"
# The gap this closes: a checkout ahead of the last tag deploys newer code under
# the released version, so both copies read the same string while differing. The
# version comparison in T9 is blind to it by construction.
mktree() { # $1 = tree root  $2 = version  $3 = extra bytes in a payload file
  mkdir -p "$1/bin" "$1/hooks" "$1/sidebars"
  printf '%s\n' "$2" > "$1/VERSION"
  printf '#!/bin/bash\necho "RAN:install.sh $*"\nexit 7\n' > "$1/install.sh"
  chmod +x "$1/install.sh"
  printf '#!/bin/bash\n# %s\n' "$3" > "$1/bin/cmux-claude-usage.sh"
  cp "$ENTRY" "$1/bin/cmux-sentinel"; chmod +x "$1/bin/cmux-sentinel"
}
TD="$ROOT/drift"; mktree "$TD" 0.3.0 original
# Borrow the dispatcher's own hasher, which also proves it is self-contained.
eval "$(sed -n '/^payload_hash()/,/^}/p' "$ENTRY")"
real="$(payload_hash "$TD")"
if [ -n "$real" ]; then ok "payload_hash fingerprints a tree"; else bad "payload_hash produced nothing"; fi

printf 'version=0.3.0\ninstalled=2026-09-16\ncommit=abc1234\npayload=%s\n' "$real" \
  > "$HOME/.config/cmux-sentinel/VERSION"
out="$("$TD/bin/cmux-sentinel" version 2>&1)"
if has "$out" "DIFFERENT files"; then bad "warned when the payloads match: $out"; else ok "matching payloads stay quiet"; fi

# Now the real-world case: same version, different bytes.
printf 'version=0.3.0\ninstalled=2026-09-16\ncommit=abc1234\npayload=000000000000\n' \
  > "$HOME/.config/cmux-sentinel/VERSION"
out="$("$TD/bin/cmux-sentinel" version 2>&1)"
if has "$out" "DIFFERENT files"; then ok "drift at an equal version is reported"; else bad "silent about content drift: $out"; fi
if has "$out" "$real"; then ok "names this tree's fingerprint"; else bad "did not name the tree payload: $out"; fi
if has "$out" "000000000000"; then ok "names the deployed fingerprint"; else bad "did not name the deployed payload: $out"; fi

# Fail OPEN: a stamp from before this feature has no payload line and must not
# grow a warning, or every existing install reports drift it cannot act on.
printf 'version=0.3.0\ninstalled=2026-09-16\ncommit=abc1234\n' > "$HOME/.config/cmux-sentinel/VERSION"
out="$("$TD/bin/cmux-sentinel" version 2>&1)"
if has "$out" "DIFFERENT files"; then bad "an old stamp with no payload warned: $out"; else ok "a payload-less stamp stays quiet"; fi

echo "T12: deploy refuses to go BACKWARDS"
# deploy copies tree -> ~/bin and assumes the tree is at least as new. When a
# checkout is ahead of the tag that is false, and a plain deploy silently
# reinstates the released pollers under launchd.
OLDT="$ROOT/oldtree"; mktree "$OLDT" 0.1.0 original
printf 'version=0.3.0\ninstalled=2026-09-16\ncommit=abc1234\npayload=%s\n' "$real" \
  > "$HOME/.config/cmux-sentinel/VERSION"
out="$("$OLDT/bin/cmux-sentinel" deploy 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then ok "an older tree is refused"; else bad "deployed backwards silently"; fi
if has "$out" "BACKWARDS"; then ok "says it would go backwards"; else bad "unclear refusal: $out"; fi
if has "$out" "0.1.0" && has "$out" "0.3.0"; then ok "names both versions"; else bad "did not name both versions: $out"; fi
if has "$out" "RAN:install.sh"; then bad "reached install.sh despite refusing"; else ok "install.sh never ran"; fi
# --force is the escape hatch, and must NOT leak into install.sh's parser, which
# rejects unknown options with exit 2.
out="$("$OLDT/bin/cmux-sentinel" deploy --force 2>&1)"; rc=$?
if has "$out" "RAN:install.sh"; then ok "--force deploys anyway"; else bad "--force did not deploy: $out"; fi
if has "$out" "RAN:install.sh --force"; then bad "--force leaked into install.sh's args"; else ok "--force is consumed by the dispatcher"; fi
if [ "$rc" = 7 ]; then ok "the installer's exit status still survives"; else bad "status rewritten to $rc"; fi
# A NEWER tree is the normal `brew upgrade && deploy` path and must not be blocked.
NEWT="$ROOT/newtree"; mktree "$NEWT" 0.9.0 original
out="$("$NEWT/bin/cmux-sentinel" deploy 2>&1)"
if has "$out" "RAN:install.sh"; then ok "a newer tree deploys normally"; else bad "blocked a real upgrade: $out"; fi

echo "T13: deploy refuses an equal-version tree whose CONTENT differs"
# The case version numbers cannot see, and the one that actually bit: Cellar and
# ~/bin both v0.2.2, Cellar older. Proceeding would regress what launchd runs.
SAMET="$ROOT/sametree"; mktree "$SAMET" 0.3.0 CHANGED
printf 'version=0.3.0\ninstalled=2026-09-16\ncommit=abc1234\npayload=%s\n' "$real" \
  > "$HOME/.config/cmux-sentinel/VERSION"
out="$("$SAMET/bin/cmux-sentinel" deploy 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then ok "equal-version content drift is refused"; else bad "deployed over a differing tree silently"; fi
if has "$out" "files differ"; then ok "says the files differ"; else bad "unclear refusal: $out"; fi
if has "$out" "--force"; then ok "offers the override"; else bad "no override named: $out"; fi
out="$("$SAMET/bin/cmux-sentinel" deploy --force 2>&1)"
if has "$out" "RAN:install.sh"; then ok "--force deploys the differing tree"; else bad "--force did not deploy: $out"; fi
# Identical bytes at the same version is a harmless re-deploy, not a refusal.
IDENT="$ROOT/ident"; mktree "$IDENT" 0.3.0 original
printf 'version=0.3.0\ninstalled=2026-09-16\ncommit=abc1234\npayload=%s\n' "$(payload_hash "$IDENT")" \
  > "$HOME/.config/cmux-sentinel/VERSION"
out="$("$IDENT/bin/cmux-sentinel" deploy 2>&1)"
if has "$out" "RAN:install.sh"; then ok "an identical re-deploy proceeds"; else bad "blocked a harmless re-deploy: $out"; fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
