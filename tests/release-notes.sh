#!/bin/bash
# release-notes.sh — offline test for scripts/release-notes.sh, which writes the
# body of every GitHub Release (.github/workflows/release.yml).
#
# The properties under test: a release never ships with empty notes, the body is
# exactly this version's CHANGELOG section, and only the newest tag is ever
# eligible for "Latest" — the badge sat on v0.1.0 for three releases because
# nothing published the newer ones.
#
# Offline: a throwaway repo with its own tags, no network.
#
# Run:  make test   (or:  bash tests/release-notes.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../scripts/release-notes.sh"
[ -f "$SRC" ] || { echo "script not found: $SRC" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-notes-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  ✗ %s\n' "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# A repo skeleton: the script resolves VERSION, CHANGELOG.md and tags relative
# to its own parent directory, so copy it in rather than pointing at this repo.
REPO="$ROOT/repo"
mkdir -p "$REPO/scripts"
cp "$SRC" "$REPO/scripts/release-notes.sh"; chmod +x "$REPO/scripts/release-notes.sh"
NOTES="$REPO/scripts/release-notes.sh"
cat > "$REPO/CHANGELOG.md" <<'MD'
# Changelog

Intro text that belongs to no release.

## Unreleased

### Added

- Something not shipped yet.

## 0.10.0 — 2026-09-20

### Fixed

- The ten fix.

## 0x9y0 — decoy

- A heading an unescaped regex matches for 0.9.0 — it sits ABOVE the real one on purpose.

## 0.9.0 — 2026-09-01

### Added

- The nine feature.

## 0.1.0 — 2026-08-01

- First.
MD
echo 0.10.0 > "$REPO/VERSION"
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
for t in v0.1.0 v0.9.0 v0.10.0 v0.10.0-rc1 not-a-version; do git -C "$REPO" tag "$t"; done

echo "T1: the body is exactly this version's section"
out="$("$NOTES" 0.9.0 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "a documented version succeeds"; else bad "exit $rc: $out"; fi
if has "$out" "The nine feature."; then ok "includes the section's content"; else bad "section content missing: $out"; fi
if has "$out" "The ten fix." || has "$out" "not shipped yet"; then bad "leaked a neighbouring section"; else ok "stops at the next heading"; fi
if has "$out" "## 0.9.0"; then bad "repeated its own heading"; else ok "drops the section heading"; fi
if has "$out" "unescaped regex matches"; then bad "matched 0x9y0 as 0.9.0 (unescaped dots)"; else ok "dots are literal, not regex wildcards"; fi
case "$out" in "### Added"*) ok "starts at the content, not a blank line";; *) bad "leading junk: $(printf '%s' "$out" | head -2)";; esac
if has "$out" "brew upgrade cmux-sentinel && cmux-sentinel deploy"; then ok "carries the upgrade instructions"; else bad "no upgrade instructions"; fi

echo "T2: the compare link names the previous RELEASE, numerically"
if has "$out" "compare/v0.1.0...v0.9.0"; then ok "0.9.0 compares against 0.1.0"; else bad "wrong compare link: $out"; fi
out10="$("$NOTES" 0.10.0 2>&1)"
# A string sort puts 0.10.0 before 0.9.0 and would link to the wrong base.
if has "$out10" "compare/v0.9.0...v0.10.0"; then ok "0.10.0 compares against 0.9.0, not 0.1.0"; else bad "string-sorted: $out10"; fi
out1="$("$NOTES" 0.1.0 2>&1)"
if has "$out1" "Full Changelog"; then bad "the first release linked to a nonexistent base"; else ok "the first release has no compare link"; fi

echo "T3: no notes, no release"
out="$("$NOTES" 0.5.0 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then ok "an undocumented version fails"; else bad "published an empty release body"; fi
if has "$out" "no '## 0.5.0' section"; then ok "names the missing section"; else bad "unclear failure: $out"; fi
out="$("$NOTES" main 2>&1)"; rc=$?
if [ "$rc" != 0 ] && has "$out" "not a release version"; then ok "rejects a non-version argument"; else bad "accepted 'main': $out"; fi
out="$("$NOTES" v0.9.0 2>&1)"
if has "$out" "The nine feature."; then ok "accepts a leading v"; else bad "v-prefixed version failed: $out"; fi

echo "T4: --check guards the release commit"
out="$("$NOTES" --check 2>&1)"; rc=$?
if [ "$rc" = 0 ] && has "$out" "describes v0.10.0"; then ok "passes when VERSION has a section"; else bad "check failed: $out"; fi
if has "$out" "Upgrading"; then bad "--check printed the body"; else ok "--check prints only a verdict"; fi
# The real mistake: bumping VERSION while the notes still sit under Unreleased.
echo 0.11.0 > "$REPO/VERSION"
out="$("$NOTES" --check 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then ok "a bump without notes fails the gate"; else bad "a bump without notes passed"; fi
if has "$out" "before tagging v0.11.0"; then ok "says what to do"; else bad "unclear: $out"; fi
echo 0.10.0 > "$REPO/VERSION"

echo "T5: only the newest release tag may be Latest"
latest="$("$NOTES" --latest-tag 2>&1)"
if [ "$latest" = "v0.10.0" ]; then ok "picks v0.10.0 over v0.9.0 (numeric)"; else bad "picked '$latest'"; fi
# Pre-release and junk tags must never become Latest.
case "$latest" in *rc*|*not-a*) bad "a non-release tag won: $latest";; *) ok "ignores pre-release and junk tags";; esac

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
