#!/bin/bash
# release-notes.sh — the GitHub Release body for a version, taken from CHANGELOG.md.
#
# Releases used to be tag-only unless someone remembered `gh release create`, and
# nobody did for v0.2.0–v0.2.2: GitHub kept showing v0.1.0 as "Latest" while three
# newer tags existed. .github/workflows/release.yml now publishes one for every
# tag, and this script is the part of it that can be tested offline.
#
#   scripts/release-notes.sh [VERSION]   print the body (default: $(cat VERSION))
#   scripts/release-notes.sh --check     fail unless CHANGELOG.md describes VERSION
#                                        (make check runs this, so a release commit
#                                        can't be tagged without its notes)
#   scripts/release-notes.sh --latest-tag
#                                        the highest vX.Y.Z tag — only that one may
#                                        be marked Latest, so republishing an OLD
#                                        tag never steals the badge
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG="${CHANGELOG:-$HERE/CHANGELOG.md}"
REPO_URL="https://github.com/oliver-kriska/cmux-sentinel"

die() { echo "release-notes: $*" >&2; exit 1; }

# Numeric per component — 0.10.0 sorts above 0.9.0, which a string sort gets wrong.
release_tags() {
  git -C "$HERE" tag -l 'v[0-9]*' 2>/dev/null \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | sed 's/^/v/' || true
}

# The CHANGELOG section for $1, without its heading and without the blank lines
# around it. Dots are escaped so "0.2.3" can't match a "0x2y3" heading.
section() {
  awk -v v="$1" '
    BEGIN { gsub(/\./, "\\.", v); head = "^## " v "([ \t]|$)" }
    $0 ~ head { on = 1; next }
    on && /^## / { exit }
    on { lines[++n] = $0 }
    END {
      s = 1; while (s <= n && lines[s] ~ /^[ \t]*$/) s++
      e = n; while (e >= s && lines[e] ~ /^[ \t]*$/) e--
      for (i = s; i <= e; i++) print lines[i]
    }' "$CHANGELOG"
}

check=0
case "${1:-}" in
  --latest-tag) release_tags | tail -1; exit 0 ;;
  --check)      check=1; shift ;;
esac

ver="${1:-$(cat "$HERE/VERSION")}"
ver="${ver#v}"
case "$ver" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "not a release version: '$ver'" ;;
esac
[ -f "$CHANGELOG" ] || die "no changelog at $CHANGELOG"

body="$(section "$ver")"
# A release with an empty body is the failure this script exists to prevent.
[ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ] \
  || die "CHANGELOG.md has no '## $ver' section — write the release notes before tagging v$ver"
if [ "$check" = 1 ]; then
  echo "release notes: CHANGELOG.md describes v$ver ✓"
  exit 0
fi

# The newest release strictly below this one, for the compare link. Absent on
# the first release, or when tags aren't fetched (a shallow checkout).
prev="$(release_tags | awk -v v="v$ver" '$0 == v { exit } { p = $0 } END { print p }')"

printf '%s\n' "$body"
cat <<EOF

## Upgrading

\`\`\`bash
# curl install
curl -fsSL https://raw.githubusercontent.com/oliver-kriska/cmux-sentinel/main/install.sh | bash

# Homebrew: both steps, since brew alone changes nothing launchd runs
brew upgrade cmux-sentinel && cmux-sentinel deploy
\`\`\`
EOF
if [ -n "$prev" ]; then
  printf '\n**Full Changelog**: %s/compare/%s...v%s\n' "$REPO_URL" "$prev" "$ver"
fi
