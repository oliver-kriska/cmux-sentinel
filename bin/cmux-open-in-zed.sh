#!/bin/bash
# cmux-open-in-zed.sh — jump Zed to the project/worktree you're working on in cmux.
#
# THE POINT: cmux is home for terminals/agents; Zed is wanted only for file editing
# + git UI/history. The friction is the handoff — pointing Zed at the RIGHT project
# and worktree by hand (window → project picker → worktree picker). This removes it.
#
# On Zed ≥ 0.234 `zed <path>` opens the folder into the CURRENT window and switches
# to that project IN PLACE (no new window, no picker). Each cmux workspace's shell is
# already sitting in its worktree, so run this from that terminal (or bind a cmux key
# to it) and Zed jumps to exactly what you're working on.
#
#   cmux-open-in-zed.sh              # switch current Zed window to $PWD's worktree
#   cmux-open-in-zed.sh /path/to/wt  # …to an explicit path
#   cmux-open-in-zed.sh --add        # add as an extra root of the current workspace
#   cmux-open-in-zed.sh --new        # force a new Zed window
#   cmux-open-in-zed.sh --print      # dry-run: print the zed command, run nothing
#   cmux-open-in-zed.sh --shell-init # emit a shell snippet: `ze` alias + zsh keybind
#
# Setup — add to ~/.zshrc so any cmux terminal can jump to Zed:
#   eval "$(/path/to/cmux-sentinel/bin/cmux-open-in-zed.sh --shell-init)"
# That defines `ze` (run from a workspace shell) and binds Ctrl-O (change with
# --key '^E') to open Zed on the current worktree. The keybind fires at the SHELL
# PROMPT only — when an agent owns the terminal it's not the zsh line editor, so it
# won't fire mid-agent (which is exactly why this is safe, unlike a blind send).
set -u

MODE=switch                                   # switch | add | new
DRY=0
SHELLINIT=0
KEY='^O'
DIR=""
usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --add)             MODE=add ;;
    --new | -n)        MODE=new ;;
    --print | --dry-run) DRY=1 ;;
    --shell-init)      SHELLINIT=1 ;;
    --key)             KEY="${2:-}"; shift ;;
    -h | --help)       usage; exit 0 ;;
    -*)                echo "unknown option: $1" >&2; exit 2 ;;
    *)                 DIR="$1" ;;
  esac
  shift
done

# --shell-init: print a snippet the user evals from ~/.zshrc. No side effects.
if [ "$SHELLINIT" = 1 ]; then
  [ -n "$KEY" ] || { echo "--key requires a value" >&2; exit 2; }
  self="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)/$(basename "$0")"
  cat <<EOF
# cmux-sentinel: open the current worktree in Zed (\`ze\`, or the keybind below)
alias ze='$self'
if [ -n "\${ZSH_VERSION:-}" ]; then
  _cmux_open_in_zed() { '$self' </dev/null >/dev/null 2>&1; zle reset-prompt 2>/dev/null; }
  zle -N _cmux_open_in_zed
  bindkey '$KEY' _cmux_open_in_zed
fi
EOF
  exit 0
fi

target="${DIR:-$PWD}"
[ -d "$target" ] || { echo "not a directory: $target" >&2; exit 2; }

# --show-toplevel returns the WORKTREE root (a git worktree resolves to its own
# checkout dir, which is exactly what we want to open). Fall back to the dir itself.
root=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$target")

ZED="${ZED_BIN:-zed}"
case "$MODE" in
  add) set -- --add "$root" ;;
  new) set -- --new "$root" ;;
  *)   set -- "$root" ;;
esac

if [ "$DRY" = 1 ]; then printf '%s %s\n' "$ZED" "$*"; exit 0; fi
command -v "$ZED" >/dev/null 2>&1 \
  || { echo "zed CLI not found — in Zed run 'zed: install cli' (Cmd-Shift-P), or set ZED_BIN" >&2; exit 127; }
exec "$ZED" "$@"
