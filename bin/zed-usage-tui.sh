#!/bin/bash
# zed-usage-tui.sh — render the Claude/Codex usage meters in a terminal pane.
#
# cmux shows the usage bars in its custom sidebar; Zed (and superzed) have no such
# panel, but they DO have terminals — so run this in one dedicated pane and you get
# the same 5h/7d + Codex meters alongside your editor. Editor-agnostic: it only
# reuses the existing pollers, which already handle creds, provider-gating, and
# offline. No cmux, no network of its own, no fork.
#
#   zed-usage-tui.sh            # live: repaint every ZED_USAGE_INTERVAL (default 30s)
#   zed-usage-tui.sh --once     # render a single frame and exit (scripts / tests)
#   zed-usage-tui.sh --interval 10
#
# Providers come straight from the pollers (self-gated via USAGE_PROVIDERS), so a
# disabled/uninstalled provider simply doesn't appear; an available-but-offline one
# shows "⚠ offline". Override poller paths with CLAUDE_USAGE_BIN / CODEX_USAGE_BIN.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_BIN="${CLAUDE_USAGE_BIN:-$HERE/cmux-claude-usage.sh}"
CODEX_BIN="${CODEX_USAGE_BIN:-$HERE/cmux-codex-usage.sh}"
INTERVAL="${ZED_USAGE_INTERVAL:-30}"
BAR_WIDTH="${ZED_USAGE_BAR_WIDTH:-14}"
ONCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --once)     ONCE=1 ;;
    --interval) shift; INTERVAL="${1:-30}" ;;
    -h | --help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$INTERVAL" in '' | *[!0-9]*) INTERVAL=30 ;; esac

# Unicode-block bar with 1/8-cell resolution — mirrors the pollers' make_bar so the
# pane and the cmux sidebar read identically (kept local to avoid sourcing a poller,
# whose top-level `main "$@"` would run on source).
make_bar() {
  local pct="${1:-0}" width="${2:-14}" eighths cell rem i bar="" start
  [ "$pct" -lt 0 ] && pct=0
  [ "$pct" -gt 100 ] && pct=100
  eighths=$(( pct * width * 8 / 100 )); cell=$(( eighths / 8 )); rem=$(( eighths % 8 ))
  for ((i = 0; i < cell; i++)); do bar+="█"; done
  if [ "$cell" -lt "$width" ]; then
    case "$rem" in
      1) bar+="▏" ;; 2) bar+="▎" ;; 3) bar+="▍" ;; 4) bar+="▌" ;;
      5) bar+="▋" ;; 6) bar+="▊" ;; 7) bar+="▉" ;; *) bar+="░" ;;
    esac
    start=$(( cell + 1 )); for ((i = start; i < width; i++)); do bar+="░"; done
  fi
  printf '%s' "$bar"
}

sev_dot() { # amber ≥70, red ≥90 — nothing below (matches the sidebar)
  local p="${1:-0}"
  if [ "$p" -ge 90 ]; then printf ' 🔴'; elif [ "$p" -ge 70 ]; then printf ' 🟡'; fi
}

# Render one provider section from its poller's `--print`. Prints nothing if the
# provider is gated off/uninstalled (poller exits 0 with no stdout); prints an
# offline notice if it's available but the fetch failed (poller exits non-zero).
render_provider() { # $1 = poller path   $2 = section title
  local bin="$1" title="$2" out rc line label pct human dot bar
  [ -x "$bin" ] || return 0
  out=$("$bin" --print 2>/dev/null); rc=$?
  if [ -z "$out" ]; then
    [ "$rc" -ne 0 ] && printf '%s\n  \033[2m⚠ offline\033[0m\n\n' "$title"
    return 0
  fi
  # Regex in a var: an inline unquoted regex containing `[^(]` confuses bash's parser.
  local re='^([A-Za-z0-9]+)[[:space:]]+([0-9]+)%.*resets[[:space:]]+([^(]+)'
  printf '\033[1m%s\033[0m\n' "$title"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # "<label>  <pct>%  · resets <human>[  (iso)]" — tolerant of both pollers.
    if [[ "$line" =~ $re ]]; then
      label="${BASH_REMATCH[1]}"; pct="${BASH_REMATCH[2]}"; human="${BASH_REMATCH[3]}"
      human="$(printf '%s' "$human" | sed -E 's/[[:space:]]+$//')"   # rtrim
      bar=$(make_bar "$pct" "$BAR_WIDTH"); dot=$(sev_dot "$pct")
      printf '  %-4s %s %3s%% · %s%s\n' "$label" "$bar" "$pct" "$human" "$dot"
    fi
  done <<<"$out"
  printf '\n'
}

frame() {
  render_provider "$CLAUDE_BIN" "CLAUDE USAGE"
  render_provider "$CODEX_BIN"  "CODEX USAGE"
}

if [ "$ONCE" = 1 ]; then frame; exit 0; fi

trap 'printf "\033[?25h"; exit 0' INT TERM              # restore cursor on exit
printf '\033[?25l'                                       # hide cursor
while :; do
  printf '\033[H\033[2J'                                 # home + clear
  printf '\033[2mAI usage · %s · every %ss (Ctrl-C to quit)\033[0m\n\n' "$(date +%H:%M:%S)" "$INTERVAL"
  frame
  sleep "$INTERVAL"
done
