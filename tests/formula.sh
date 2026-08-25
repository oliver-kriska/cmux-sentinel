#!/bin/bash
# formula.sh — offline test for scripts/make-formula.sh, the Homebrew formula
# generator.
#
# The property under test is that the formula can never quietly disagree with
# VERSION. A tap serving the previous release is invisible from inside the repo:
# `brew upgrade` succeeds, prints nothing unusual, and installs the old code —
# the same class of silent-no-op failure as a meter that stopped updating.
#
# Everything here is offline: --check must never touch the network, because it
# runs in CI and in the pre-commit hook, where a slow GitHub would block commits
# that have nothing to do with packaging.
#
# Run:  make test   (or:  bash tests/formula.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
GEN="$REPO/scripts/make-formula.sh"
[ -f "$GEN" ] || { echo "generator not found: $GEN" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-formula-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  ✗ %s\n' "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# A throwaway copy of the repo skeleton, so a test can move VERSION around
# without touching the real one.
WORK="$ROOT/repo"; mkdir -p "$WORK/scripts" "$WORK/packaging/homebrew"
cp "$GEN" "$WORK/scripts/make-formula.sh"
SHA64="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

mkformula() { # $1 = version  $2 = sha256 field contents
  cat > "$WORK/packaging/homebrew/cmux-sentinel.rb" <<RB
class CmuxSentinel < Formula
  url "https://github.com/oliver-kriska/cmux-sentinel/archive/refs/tags/v$1.tar.gz"
  sha256 "$2"
end
RB
}

echo "T1: before the first release, no formula is not a failure"
echo "0.2.0" > "$WORK/VERSION"
out="$("$WORK/scripts/make-formula.sh" --check 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "a missing formula does not block the gate"; else bad "pre-release check exited $rc"; fi
if has "$out" "not released"; then ok "says why there is no formula"; else bad "unclear pre-release message: $out"; fi
if has "$out" "make-formula.sh"; then ok "names the command that creates one"; else bad "no next step offered"; fi

echo "T2: a formula that matches VERSION passes"
mkformula 0.2.0 "$SHA64"
out="$("$WORK/scripts/make-formula.sh" --check 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "matching formula passes"; else bad "matching formula failed: $out"; fi
if has "$out" "v0.2.0"; then ok "reports the version it verified"; else bad "did not report the version: $out"; fi

echo "T3: a stale formula fails and names BOTH versions"
# The whole point: after a version bump, the committed formula still points at
# the previous tag until it is regenerated.
echo "0.3.0" > "$WORK/VERSION"
out="$("$WORK/scripts/make-formula.sh" --check 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then ok "a stale formula fails the gate"; else bad "stale formula passed"; fi
if has "$out" "0.2.0"; then ok "names the version the formula has"; else bad "did not name the formula's version: $out"; fi
if has "$out" "0.3.0"; then ok "names the version it should have"; else bad "did not name VERSION: $out"; fi

echo "T4: a placeholder sha256 never ships"
mkformula 0.3.0 "REPLACE_ME"
out="$("$WORK/scripts/make-formula.sh" --check 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then ok "a non-hash sha256 fails"; else bad "placeholder sha256 passed"; fi
if has "$out" "sha256"; then ok "says what is wrong"; else bad "unclear sha error: $out"; fi

echo "T5: --check is offline"
# Any curl here would make the pre-commit hook depend on GitHub being up.
mkformula 0.3.0 "$SHA64"
BINSTUB="$ROOT/stub"; mkdir -p "$BINSTUB"
printf '#!/bin/bash\necho "NETWORK USED" >&2\nexit 1\n' > "$BINSTUB/curl"
chmod +x "$BINSTUB/curl"
out="$(PATH="$BINSTUB:$PATH" "$WORK/scripts/make-formula.sh" --check 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "check passes with the network stubbed out"; else bad "check needs the network: $out"; fi
if has "$out" "NETWORK USED"; then bad "check called curl"; else ok "check never calls curl"; fi

echo "T6: an explicit version argument overrides VERSION"
out="$("$WORK/scripts/make-formula.sh" --check 0.2.0 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then ok "checking against another version is possible"; else bad "0.2.0 check passed against a 0.3.0 formula"; fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
