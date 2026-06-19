#!/bin/bash
# cmux-sentinel-setup.sh — idempotently create the usage-meter "sentinel" workspaces.
#
# Creating + naming the sentinels by hand is the most error-prone install step (a
# typo'd label = a silently blank panel). This does it for you: for each ENABLED
# provider (USAGE_PROVIDERS, default "claude") it creates an idle workspace titled
# with the right label and a "managed by …" description — but only if one doesn't
# already exist (resolved by title across ALL windows), so re-running is safe.
#
# It does NOT update the bars (that's the poller's job) and never closes anything.
# Run it once after install, then run the poller(s) + reload the sidebar.
#
# Config: ~/.config/cmux/usage-sentinels.env (labels + USAGE_PROVIDERS).
set -uo pipefail

CFG="$HOME/.config/cmux"
SENTINELS_ENV="$CFG/usage-sentinels.env"
# shellcheck disable=SC1090
[ -f "$SENTINELS_ENV" ] && . "$SENTINELS_ENV"
LABEL_5H="${SENTINEL_5H_LABEL:-5h}";   LABEL_7D="${SENTINEL_7D_LABEL:-7d}"
LABEL_CX5H="${SENTINEL_CX5H_LABEL:-cx5h}"; LABEL_CX7D="${SENTINEL_CX7D_LABEL:-cx7d}"
PROVIDERS="${USAGE_PROVIDERS:-claude}"

have() { command -v "$1" >/dev/null 2>&1; }
have cmux || { echo "cmux not on PATH" >&2; exit 1; }
have jq   || { echo "jq is required" >&2; exit 1; }
cmux ping &>/dev/null || { echo "cmux isn't responding — is the app running?" >&2; exit 1; }

# Does a sentinel titled with this label already exist in ANY window? (Same
# title-label match the pollers + sidebar use; launchd-less, window-agnostic.)
exists() { # $1 = label
  local w
  cmux workspace list --json 2>/dev/null \
    | jq -e --arg l "$1" 'any(.workspaces[]; .title == $l or (.title | startswith($l + " ")))' >/dev/null 2>&1 && return 0
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    cmux workspace list --window "$w" --json 2>/dev/null \
      | jq -e --arg l "$1" 'any(.workspaces[]; .title == $l or (.title | startswith($l + " ")))' >/dev/null 2>&1 && return 0
  done < <(cmux list-windows --json 2>/dev/null | jq -r '.[].id // empty' 2>/dev/null)
  return 1
}

rc=0
ensure() { # $1 = label  $2 = description
  if exists "$1"; then echo "  = '$1' already exists — leaving it"; return 0; fi
  if cmux workspace create --name "$1" --description "$2" --cwd "$HOME" --focus false >/dev/null 2>&1; then
    echo "  + created '$1' sentinel"
  else
    echo "  ✗ failed to create '$1' sentinel" >&2; rc=1
  fi
}

echo "cmux-sentinel setup — providers: $PROVIDERS"
case " $PROVIDERS " in *" claude "*)
  ensure "$LABEL_5H" "Claude 5-hour rate meter — managed by cmux-claude-usage.sh; leave idle"
  ensure "$LABEL_7D" "Claude weekly rate meter — managed by cmux-claude-usage.sh; leave idle"
  ;; esac
case " $PROVIDERS " in *" codex "*)
  ensure "$LABEL_CX5H" "Codex 5-hour rate meter — managed by cmux-codex-usage.sh; leave idle"
  ensure "$LABEL_CX7D" "Codex weekly rate meter — managed by cmux-codex-usage.sh; leave idle"
  ;; esac

# Auto-naming guard: cmux can auto-generate workspace titles; if that's ON it could
# rename a sentinel and break its label prefix (→ silently blank meter). There's no
# readable per-workspace auto-title state and the setter is gated by the global
# setting, so we can only DETECT + warn: an empty-params probe reports the global
# state without mutating anything.
probe=$(cmux rpc workspace.set_auto_title '{}' 2>&1 || true)
case "$probe" in
  *[Dd]isabled*[Ss]ettings*) echo "  ✓ cmux auto-naming is OFF globally — sentinel titles are safe" ;;
  *) echo "  ⚠ cmux auto-naming may be ON — disable it in Settings so it can't rename a sentinel and blank its meter" ;;
esac

echo
echo "Next — paint the bars and reload:"
case " $PROVIDERS " in *" claude "*) echo "  ~/bin/cmux-claude-usage.sh --update"; esac
case " $PROVIDERS " in *" codex "*)  echo "  ~/bin/cmux-codex-usage.sh --update"; esac
echo "  cmux sidebar reload"
exit "$rc"
