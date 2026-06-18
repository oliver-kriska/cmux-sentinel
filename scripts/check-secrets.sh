#!/bin/bash
# check-secrets.sh — fail the commit/CI if a tracked file leaks something that
# must never be public. cmux-sentinel's whole security model is "the OAuth token
# lives in the Keychain and the sidebar ships REPLACE_WITH_* placeholders" — this
# guard is what keeps a careless `cp live.swift repo.swift` from breaking it.
#
# Scans only git-tracked files (binary files are skipped by `grep -I`). Run from
# the repo root: `./scripts/check-secrets.sh` (also wired into `make secrets`,
# lefthook pre-commit, and CI).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

fail=0
# flag <message> <matches>. NB: called directly (never on the right of a pipe) so
# `fail=1` lands in THIS shell — a piped `... | flag` would set it in a subshell
# and the gate would print errors yet exit 0 (it did; that's why this is a func).
flag() {
  printf '\033[31m✗ %s\033[0m\n' "$1" >&2
  printf '%s\n' "$2" | sed 's/^/    /' >&2
  fail=1
}

files=$(git ls-files)

# 1. Real workspace UUIDs (8-4-4-4-12 hex). The sidebar MUST use the
#    REPLACE_WITH_*_UUID placeholders instead — those aren't UUID-shaped, so any
#    hit here is a real id that would leak (and pin the repo to one machine).
if hits=$(printf '%s\n' "$files" | xargs grep -nEI \
  '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' 2>/dev/null); then
  flag "real UUID in a tracked file (use a REPLACE_WITH_* placeholder)" "$hits"
fi

# 2. Absolute home paths leak a username and aren't portable. $HOME / ~ are fine,
#    and so is the documented /Users/YOUR_USERNAME placeholder (install.sh
#    sed-replaces it with $HOME) — only a REAL username is a leak.
if hits=$(printf '%s\n' "$files" | xargs grep -nEI '/Users/[A-Za-z0-9]' 2>/dev/null \
  | grep -v '/Users/YOUR_USERNAME'); then
  flag "absolute /Users/<name> path (use \$HOME, ~, or the YOUR_USERNAME placeholder)" "$hits"
fi

# 3. Token-shaped secrets. Known prefixes only, to stay false-positive-free.
if hits=$(printf '%s\n' "$files" | xargs grep -nEI \
  'sk-ant-[A-Za-z0-9_-]{6}|sk-[A-Za-z0-9]{20}|ghp_[A-Za-z0-9]{20}|gho_[A-Za-z0-9]{20}|xox[baprs]-[A-Za-z0-9-]{8}|Bearer [A-Za-z0-9._-]{16}' \
  2>/dev/null); then
  flag "token-shaped string" "$hits"
fi

# 4. Positive assertion: the shipped sidebar must still match the sentinels by
#    TITLE LABEL (the id-free scheme — cmux 0.64.15 removed stable workspace
#    UUIDs). A clobbered file that lost these anchors would pass every check above
#    yet render no usage panel — catch that regression. (This also means the
#    committed and deployed sidebars are now identical: no id substitution, so no
#    secret can leak through the sidebar at all.)
if [ -f sidebars/workspaces.swift ] \
  && ! grep -Eq 'w\.title\.hasPrefix\("(5h|7d) "\)' sidebars/workspaces.swift; then
  flag "sidebar is missing its isClaudeMeter title anchors (w.title.hasPrefix)" "sidebars/workspaces.swift"
fi

if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "secrets check failed — see above. Nothing was committed." >&2
  exit 1
fi
echo "secrets check: clean ✓"
