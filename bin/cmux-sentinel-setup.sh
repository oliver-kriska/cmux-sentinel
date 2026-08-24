#!/bin/bash
# cmux-sentinel-setup.sh — idempotently create the usage-meter "sentinel" workspaces.
#
# Creating + naming the sentinels by hand is the most error-prone install step (a
# typo'd label = a silently blank panel). This does it for you: for each ENABLED
# provider (USAGE_PROVIDERS, default "claude") it creates an idle workspace titled
# with the right label and a "managed by …" description — but only if one doesn't
# already exist (resolved by title across ALL windows), so re-running is safe. It
# also skips a window the provider doesn't actually HAVE (Codex asks the poller via
# `--buckets`; see "ensure_live") so you don't get a permanently-"n/a" meter.
#
# It also PARKS the sentinels so they don't steal ⌘1…⌘9 (see "shortcut layout"
# below). It does NOT update the bars (that's the poller's job) and never closes
# anything. Run it once after install, then run the poller(s) + reload the sidebar.
#
# Config: ~/.config/cmux/usage-sentinels.env (labels + USAGE_PROVIDERS).
#         SENTINEL_LAYOUT=0 (or --no-layout) skips the shortcut layout pass.
set -uo pipefail

# cmux prints a one-time deprecation notice for legacy verbs (rename-workspace →
# workspace rename) on STDERR. Anything that CAPTURES cmux stderr to explain a
# failure gets that notice at the front of the reason, where it reads as the cause
# — it buried a real "Command timed out" once. cmux documents this switch for it.
export CMUX_QUIET=1

LAYOUT="${SENTINEL_LAYOUT:-1}"
for a in "$@"; do
  case "$a" in
    --no-layout) LAYOUT=0 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;   # the header block above
    *) echo "unknown flag: $a (try --no-layout)" >&2; exit 2 ;;
  esac
done

CFG="$HOME/.config/cmux"
SENTINELS_ENV="$CFG/usage-sentinels.env"
# shellcheck disable=SC1090
[ -f "$SENTINELS_ENV" ] && . "$SENTINELS_ENV"
LABEL_5H="${SENTINEL_5H_LABEL:-5h}";   LABEL_7D="${SENTINEL_7D_LABEL:-7d}"
LABEL_M7D="${SENTINEL_M7D_LABEL:-m7d}"
LABEL_SPEND="${SENTINEL_SPEND_LABEL:-spend}"
LABEL_CX5H="${SENTINEL_CX5H_LABEL:-cx5h}"; LABEL_CX7D="${SENTINEL_CX7D_LABEL:-cx7d}"
LABEL_AMPU="${SENTINEL_AMPU_LABEL:-ampu}"; LABEL_AMPO="${SENTINEL_AMPO_LABEL:-ampo}"
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

# A provider may not HAVE every window we model: OpenAI dropped the 5h window for
# Codex Pro (2026-07-13; still gone with fresh usage 2026-07-16), so creating cx5h
# parks a permanently-"n/a" row — and a sentinel is an ordinary workspace, so it eats
# one of the ⌘1…⌘9 keys to show nothing. So ASK the poller which windows are live
# (`--buckets`) instead of hardcoding it here; a later setup run recreates the
# meter if OpenAI ever restores the window.
#
# Fail-open by design: a windowed provider prints nothing when it can't tell and
# empty preserves its normal modeled windows. Only a POSITIVE answer suppresses a
# normal sentinel. Optional meters (Amp orbs) still require their local opt-in.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_POLLER="${CLAUDE_POLLER:-$SELF_DIR/cmux-claude-usage.sh}"
CODEX_POLLER="${CODEX_POLLER:-$SELF_DIR/cmux-codex-usage.sh}"
AMP_POLLER="${AMP_POLLER:-$SELF_DIR/cmux-amp-usage.sh}"

live_buckets() { # $1 = poller path — echoes live labels, or nothing if undeterminable
  [ -x "$1" ] || return 0
  "$1" --buckets 2>/dev/null
}

ensure_live() { # $1 = label  $2 = description  $3 = live labels ("" = undetermined)
  if [ -n "$3" ] && ! printf '%s\n' "$3" | grep -qxF -- "$1"; then
    echo "  – skipping '$1' — the provider reports no such window (would be a dead 'n/a' row)"
    return 0
  fi
  ensure "$1" "$2"
}

echo "cmux-sentinel setup — providers: $PROVIDERS"
case " $PROVIDERS " in *" claude "*)
  ensure "$LABEL_5H" "Claude 5-hour rate meter — managed by cmux-claude-usage.sh; leave idle"
  ensure "$LABEL_7D" "Claude weekly rate meter — managed by cmux-claude-usage.sh; leave idle"
  # Per-model weekly cap (Fable et al). Opt-in for the same reason as Amp orbs: the
  # row costs one of the ⌘1…⌘9 keys, and most accounts don't watch a second cap.
  # The two normal meters deliberately stay on plain `ensure` — asking the poller
  # must never be able to suppress a proven-working meter.
  cl_live=$(live_buckets "$CLAUDE_POLLER")
  if [ "${CLAUDE_MODEL_METER:-0}" = 1 ]; then
    ensure_live "$LABEL_M7D" "Claude per-model weekly meter — managed by cmux-claude-usage.sh; leave idle" "$cl_live"
  fi
  # Extra-usage SPEND. Created whenever the account has an overage budget — a stable
  # account property, NOT the balance. This is the one meter with no opt-in flag,
  # because the sidebar hides the row while the balance is zero: it costs nothing to
  # look at, and a flag you never set could never warn you about an unexpected charge.
  ensure_live "$LABEL_SPEND" "Claude extra-usage spend meter — managed by cmux-claude-usage.sh; leave idle" "$cl_live"
  ;; esac
case " $PROVIDERS " in *" codex "*)
  cx_live=$(live_buckets "$CODEX_POLLER")
  ensure_live "$LABEL_CX5H" "Codex 5-hour rate meter — managed by cmux-codex-usage.sh; leave idle" "$cx_live"
  ensure_live "$LABEL_CX7D" "Codex weekly rate meter — managed by cmux-codex-usage.sh; leave idle" "$cx_live"
  ;; esac
# Amp meters a MONTHLY subscription allowance, not rolling windows. Its normal
# ampu meter fails open like Codex. The optional ampo meter must also be opted in
# LOCALLY: an empty --buckets answer means "can't tell", never "enable every
# optional meter" (that would consume a ⌘ key while AMP_ORB_METER is off).
case " $PROVIDERS " in *" amp "*)
  amp_live=$(live_buckets "$AMP_POLLER")
  ensure_live "$LABEL_AMPU" "Amp subscription usage meter — managed by cmux-amp-usage.sh; leave idle" "$amp_live"
  if [ "${AMP_ORB_METER:-0}" = 1 ]; then
    ensure_live "$LABEL_AMPO" "Amp orb usage meter — managed by cmux-amp-usage.sh; leave idle" "$amp_live"
  fi
  ;; esac

# ── shortcut layout ───────────────────────────────────────────────────────────
# A sentinel is an ORDINARY workspace to cmux — "sentinel" is a concept that only
# exists in our sidebar's predicates — so every meter silently eats one of the
# ⌘1…⌘9 workspace keys (verified: ⌘6→cx7d, ⌘7→cx5h, ⌘9→7d). There's no way to make
# one weightless (cmux's TabManager.tabs is the raw array — no hidden/archived
# concept), so the only lever is ORDER. That lever is free: sentinel index has zero
# effect on what renders (the sidebar's meter panel sorts by title label, and the
# workspace list filters meters out), so this reorders nothing the user can see.
#
# cmux maps ⌘1…⌘8 to numbered positions 0…7 and ⌘9 to the LAST numbered row
# (count-1) — positions 8…count-2 are the "keyless band". Those positions are NOT
# raw `.index`: since 0.64.22 group anchors and collapsed members are skipped
# (see JQ_NUMBERED). Hence the invariant:
#
#   sentinels live in the keyless band, and the LAST NUMBERED row is a real one.
#
# That puts 9/9 keys on real workspaces. Sentinels at the very bottom would cost
# ⌘9; at the top they'd cost ⌘1…⌘4. Relative order of real workspaces is PRESERVED:
# we only push meters down and then re-park the workspace that was already last.
#
# Refs are positional handles that a move renumbers, so re-resolve by TITLE before
# every move rather than caching a ref. (0.64.22 populates `id` again, but it is not
# a proven-durable handle — see CLAUDE.md — and the title anchor already works.)

# Every label the sidebar hides — including disabled providers' leftovers, which
# still exist as workspaces and still eat ⌘ keys. Array, not a string: a label is
# user-configurable and could contain a space.
ALL_LABELS=("$LABEL_5H" "$LABEL_7D" "$LABEL_M7D" "$LABEL_SPEND" "$LABEL_CX5H" "$LABEL_CX7D" "$LABEL_AMPU" "$LABEL_AMPO")
labels_json() { printf '%s\n' "${ALL_LABELS[@]}" | jq -R . | jq -s .; }

ws_json() { # $1 = window ("" = default)
  if [ -n "${1:-}" ]; then cmux workspace list --window "$1" --json 2>/dev/null
  else cmux workspace list --json 2>/dev/null; fi
}
ws_reorder() { # $1 = ref  $2 = index  $3 = window ("")
  if [ -n "${3:-}" ]; then cmux reorder-workspace --workspace "$1" --index "$2" --window "$3" >/dev/null 2>&1
  else cmux reorder-workspace --workspace "$1" --index "$2" >/dev/null 2>&1; fi
}
grp_json() { # $1 = window ("" = default)
  if [ -n "${1:-}" ]; then cmux workspace-group list --window "$1" --json 2>/dev/null
  else cmux workspace-group list --json 2>/dev/null; fi
}

# jq: the rows cmux actually NUMBERS for ⌘1…⌘9, in display order.
#
# cmux 0.64.22 (upstream #9176) stopped numbering the raw tab array: ⌘N now indexes
# `SidebarWorkspaceRenderItem.numberedWorkspaceIds`, i.e. the ORDINARY sidebar rows.
# Two kinds of workspace are therefore NOT numbered, and both shrink the list so
# every row below them shifts one key UP:
#   - a group's ANCHOR (it renders as the group header, not as a workspace row)
#   - every member of a COLLAPSED group
# Sentinels are plain ungrouped workspaces, so they are always numbered — but a
# group above them silently moves them into the keyed band. Computing the band off
# raw `.index` would then park them wrong and report a false all-clear.
# shellcheck disable=SC2016  # jq program — $gs/$x/$r are jq vars, must NOT expand in bash
JQ_NUMBERED='def numbered($gs):
  ( [ $gs[]? | .anchor_workspace_ref // empty ]
    + [ $gs[]? | select(.is_collapsed == true) | .member_workspace_refs[]? ] ) as $x
  | [ .workspaces | sort_by(.index)[] | select( .ref as $r | ($x | index($r)) == null ) ];'

# jq: does a title belong to a sentinel? Exact label ("5h", pre-first-poll) or
# label + " " + bar ("5h ███ 41%") — the same match the sidebar and pollers use, so
# a real workspace named e.g. "5h-notes" is correctly NOT a meter.
# shellcheck disable=SC2016  # jq program — $ls/$t/$l are jq vars, must NOT expand in bash
JQ_IS_SENT='def is_sent($ls): . as $t | any($ls[]; . as $l | $t == $l or ($t | startswith($l + " ")));'

# Which window holds the sentinels? Echoes "" for the default window (a bare ref
# suffices) or the window id; returns 1 when there are none anywhere.
sentinel_window() {
  local w
  ws_json "" | jq -e --argjson ls "$(labels_json)" \
    "$JQ_IS_SENT"' any(.workspaces[]; .title | is_sent($ls))' >/dev/null 2>&1 && { printf ''; return 0; }
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    ws_json "$w" | jq -e --argjson ls "$(labels_json)" \
      "$JQ_IS_SENT"' any(.workspaces[]; .title | is_sent($ls))' >/dev/null 2>&1 && { printf '%s' "$w"; return 0; }
  done < <(cmux list-windows --json 2>/dev/null | jq -r '.[].id // empty' 2>/dev/null)
  return 1
}

layout() {
  local win json total ref lbl reals last_real gj
  win=$(sentinel_window) || { echo "  = no sentinels to park"; return 0; }

  # Push every sentinel to the end, re-resolving its ref by title each time (a
  # move renumbers refs). Label order is deterministic; order AMONG meters is
  # irrelevant — the panel sorts them by label.
  for lbl in "${ALL_LABELS[@]}"; do
    json=$(ws_json "$win"); [ -n "$json" ] || return 0
    ref=$(printf '%s' "$json" | jq -r --arg l "$lbl" \
      '.workspaces[] | select(.title == $l or (.title | startswith($l + " "))) | .ref' 2>/dev/null | head -1)
    [ -n "$ref" ] || continue
    total=$(printf '%s' "$json" | jq -r '.workspaces | length' 2>/dev/null)
    [ "${total:-0}" -gt 1 ] || continue
    ws_reorder "$ref" "$((total - 1))" "$win" && echo "  ↓ parked '$lbl' below the workspace list"
  done

  # Re-park the workspace that was already last so it takes count-1 and answers ⌘9.
  # Needs 2+ real workspaces: with 0 there's nothing to anchor, and with 1 we'd be
  # pushing the user's only workspace below the meters to buy nothing.
  json=$(ws_json "$win"); [ -n "$json" ] || return 0
  # Only a NUMBERED real workspace can answer ⌘9. Parking a group anchor last would
  # render it as a group header — dropping it out of the numbering and handing ⌘9
  # straight back to a meter, the exact bug this pass exists to prevent.
  gj=$(grp_json "$win" | jq -c '.groups // []' 2>/dev/null); [ -n "$gj" ] || gj='[]'
  reals=$(printf '%s' "$json" | jq -r --argjson ls "$(labels_json)" --argjson gs "$gj" \
    "$JQ_IS_SENT$JQ_NUMBERED"' [numbered($gs)[] | select(.title | is_sent($ls) | not)] | length' 2>/dev/null)
  if [ "${reals:-0}" -lt 2 ]; then
    echo "  = too few workspaces to anchor ⌘9 — meters still take some keys"
    return 0
  fi
  last_real=$(printf '%s' "$json" | jq -r --argjson ls "$(labels_json)" --argjson gs "$gj" \
    "$JQ_IS_SENT$JQ_NUMBERED"' [numbered($gs)[] | select(.title | is_sent($ls) | not)] | last | .ref' 2>/dev/null)
  total=$(printf '%s' "$json" | jq -r '.workspaces | length' 2>/dev/null)
  [ -n "$last_real" ] && [ "${total:-0}" -gt 1 ] || return 0
  ws_reorder "$last_real" "$((total - 1))" "$win" && echo "  ✓ ⌘9 anchored on your last workspace"
}

if [ "$LAYOUT" = 1 ]; then
  echo
  echo "shortcut layout — keeping the meters out of ⌘1…⌘9:"
  layout
fi

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
case " $PROVIDERS " in *" amp "*)    echo "  ~/bin/cmux-amp-usage.sh --update"; esac
echo "  cmux sidebar reload"
exit "$rc"
