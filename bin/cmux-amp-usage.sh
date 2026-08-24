#!/bin/bash
# cmux-amp-usage.sh — feed Amp (ampcode.com) subscription utilization into the
# cmux custom sidebar via sentinel workspaces. Third provider, sibling of
# cmux-claude-usage.sh / cmux-codex-usage.sh; same display channel.
#
# Data source: the `amp usage` CLI, which prints (plain text, no ANSI):
#   Signed in as <email> (<handle>)
#   Subscription <Plan>: <N>% other usage and <M>% orb usage remaining - resets upon renewal in <when>
#   Workspace <name>: $<amount> remaining - <url>
# "other usage" = normal agent/thread execution; "orb usage" = Amp's remote
# machines that run threads for you (`amp orb`). Both are subscription-included
# allowances that reset on renewal.
#
# TWO WAYS THIS DIFFERS FROM THE OTHER PROVIDERS — both shape the code below:
#
#  1. NO --json, NO stable schema. `amp usage --json` is rejected outright, so the
#     only source is human-facing prose that Amp is free to reword in any release.
#     So parsing is deliberately loose and anchored on the smallest stable thing
#     (the number immediately before "other usage" / "orb usage"), never on line
#     position, field order, plan name, or the surrounding sentence. Anything it
#     cannot parse is treated as "can't tell" (offline), NEVER as 0%.
#
#  2. The numbers are REMAINING, the meters show USED. amp prints "100% other
#     usage … remaining" for an untouched allowance; a meter at 100% must mean
#     "you're out". So every parsed value is inverted (used = 100 - remaining).
#     Getting this backwards would show a full bar on a fresh subscription — the
#     single most dangerous bug in this file, hence the loud comment.
#
# Also unlike the others: these are not rolling 5h/7d WINDOWS but a monthly
# allowance, so the reset text comes from Amp's own phrase rather than a computed
# countdown; the dashboard compacts simple units (`26 days` → `26d`) to fit. The
# `$` workspace credit balance is deliberately NOT metered
# — it's a currency balance, not a 0-100% utilization, so it has no honest bar.
#
# THE ORB METER IS OFF BY DEFAULT, on purpose. A sentinel is an ordinary
# workspace, so a meter nobody looks at is not free — it still eats one of the
# ⌘1…⌘9 keys (see CLAUDE.md's shortcut-layout invariant). Most people never run
# orbs, so metering orb usage by default would cost a real key for an unused row.
# Opt in with AMP_ORB_METER=1.
#
# Modes:
#   --print     run + print parsed values (no cmux writes)
#   --raw       print `amp usage` output verbatim (NOTE: includes your email —
#               it is the only mode that does, and it never leaves your machine)
#   --update    paint the sentinel workspaces (title + native progress bar)
#   --buckets   print the labels this account HAS a live allowance for (one per
#               line); prints NOTHING when it can't tell. For cmux-sentinel-setup.sh.
#
# Provider gating: this is the AMP provider; it SELF-GATES so Amp being absent or
# disabled never errors. Panel visibility is separate: the sidebar hides a provider
# only when its sentinels are absent, and doctor flags leftovers.
#   * disabled (USAGE_PROVIDERS doesn't list "amp"; default is "claude") → exit 0.
#   * amp not installed / never logged in (no credentials file) → exit 0, silently.
#   * logged in but `amp usage` fails or is unparseable → transient "⚠ offline".
# Config: ~/.config/cmux/usage-sentinels.env
#   SENTINEL_AMPU_LABEL=ampu   SENTINEL_AMPO_LABEL=ampo
#   USAGE_PROVIDERS="claude amp"   # add "amp" to enable this poller
#   AMP_ORB_METER=1                # also meter orb usage (costs a ⌘ key)

set -uo pipefail

# cmux prints a one-time deprecation notice for legacy verbs (rename-workspace →
# workspace rename) on STDERR. Anything that CAPTURES cmux stderr to explain a
# failure gets that notice at the front of the reason, where it reads as the cause
# — it buried a real "Command timed out" once. cmux documents this switch for it.
export CMUX_QUIET=1

AMP_BIN="${AMP_BIN:-amp}"
# Existence-only login probe: never read these, they hold credentials.
AMP_SECRETS="${AMP_SECRETS_JSON:-$HOME/.local/share/amp/secrets.json}"
SENTINELS_ENV="$HOME/.config/cmux/usage-sentinels.env"

# shellcheck disable=SC1090
[ -f "$SENTINELS_ENV" ] && source "$SENTINELS_ENV"
LABEL_AMPU="${SENTINEL_AMPU_LABEL:-ampu}"
LABEL_AMPO="${SENTINEL_AMPO_LABEL:-ampo}"

PROVIDER_ID="amp"
USAGE_PROVIDERS="${USAGE_PROVIDERS:-claude}"
ORB_METER="${AMP_ORB_METER:-0}"
USAGE_STATE_DIR="${CMUX_SENTINEL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/cmux-sentinel}/usage"

die() { echo "ERR: $*" >&2; exit 1; }

# Record only a COMPLETE successful --update. Keep this best-effort: freshness
# diagnostics must never turn an already-painted meter into a failed launchd run.
record_success() {
  local tmp
  mkdir -p "$USAGE_STATE_DIR" || return 1
  tmp=$(mktemp "$USAGE_STATE_DIR/.${PROVIDER_ID}.XXXXXX") || return 1
  printf '%s\n' "$(date +%s)" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$USAGE_STATE_DIR/$PROVIDER_ID.last-success" || { rm -f "$tmp"; return 1; }
}

provider_enabled() {
  case " $USAGE_PROVIDERS " in *" $PROVIDER_ID "*) return 0 ;; *) return 1 ;; esac
}

# Is Amp usable HERE? The binary must exist AND a credentials file must be
# present. Existence only — the file is never read, so no secret can leak through
# this script. An EXPIRED/revoked login still has the file, so it stays a
# transient '⚠ offline' rather than silently removing the panel (same asymmetry
# the Codex poller keeps for an expired ChatGPT token).
provider_available() {
  command -v "$AMP_BIN" >/dev/null 2>&1 || return 1
  [ -s "$AMP_SECRETS" ]
}

# ── sentinel plumbing (identical contract to the other pollers) ──────────────

# Resolve a sentinel's current ref by its title label — refs rotate across cmux
# restarts, so this re-resolves every run and nothing is ever stored. Matches the
# BARE label too so a freshly-created sentinel (titled just "ampu", no bar yet)
# can bootstrap. Multi-window: `workspace list` is window-scoped and launchd has
# no window context, so try the default window, then scan every window. Prints
# "<ref>\t<window>" — window EMPTY for the default window.
resolve_ref() { # $1 = label
  local lbl="$1" ref w
  ref=$(cmux workspace list --json 2>/dev/null \
    | jq -r --arg l "$lbl" '.workspaces[] | select(.title == $l or (.title | startswith($l + " "))) | .ref' 2>/dev/null | head -1)
  [ -n "$ref" ] && { printf '%s\t' "$ref"; return; }
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    ref=$(cmux workspace list --window "$w" --json 2>/dev/null \
      | jq -r --arg l "$lbl" '.workspaces[] | select(.title == $l or (.title | startswith($l + " "))) | .ref' 2>/dev/null | head -1)
    [ -n "$ref" ] && { printf '%s\t%s' "$ref" "$w"; return; }
  done < <(cmux list-windows --json 2>/dev/null | jq -r '.[].id // empty' 2>/dev/null)
}

# Resolve by label (across windows) and rename. Return: 0 ok, 10 not-found, 11 rejected.
_paint() { # $1 = label  $2 = new title
  local rw ref win err wargs=()
  rw=$(resolve_ref "$1"); IFS=$'\t' read -r ref win <<<"$rw"
  [ -n "$ref" ] || return 10
  [ -n "$win" ] && wargs=(--window "$win")
  # ${wargs[@]+"${wargs[@]}"} expands to nothing when empty — required under `set -u`
  # on bash 3.2 (macOS /bin/bash), where a bare "${wargs[@]}" errors.
  err=$(cmux rename-workspace --workspace "$ref" ${wargs[@]+"${wargs[@]}"} "$2" 2>&1 >/dev/null) || { printf '%s' "$err"; return 11; }
  return 0
}

# Resolve ONCE, then write BOTH the title (restart-proof anchor + unicode-bar
# fallback) and the native progress bar the sidebar draws a ProgressView from.
_meter_write() { # $1=label $2=title $3=progress_value(0..1) $4=progress_label
  local rw ref win err wargs=()
  rw=$(resolve_ref "$1"); IFS=$'\t' read -r ref win <<<"$rw"
  [ -n "$ref" ] || return 10
  [ -n "$win" ] && wargs=(--window "$win")
  err=$(cmux rename-workspace --workspace "$ref" ${wargs[@]+"${wargs[@]}"} "$2" 2>&1 >/dev/null) || { printf '%s' "$err"; return 11; }
  cmux set-progress "$3" --label "$4" --workspace "$ref" ${wargs[@]+"${wargs[@]}"} >/dev/null 2>&1 || true
  return 0
}

# Drop a sentinel's progress bar so the sidebar falls back to its TITLE.
_clear_progress() { # $1 = label
  local rw ref win wargs=()
  rw=$(resolve_ref "$1"); IFS=$'\t' read -r ref win <<<"$rw"
  [ -n "$ref" ] || return 0
  [ -n "$win" ] && wargs=(--window "$win")
  cmux clear-progress --workspace "$ref" ${wargs[@]+"${wargs[@]}"} >/dev/null 2>&1 || true
}

# integer percent (0-100) -> unicode block bar with 1/8-cell resolution.
make_bar() {
  local pct="${1:-0}" width="${2:-10}" eighths cell rem i bar="" start
  [ "$pct" -lt 0 ] && pct=0
  [ "$pct" -gt 100 ] && pct=100
  eighths=$(( pct * width * 8 / 100 ))
  cell=$(( eighths / 8 )); rem=$(( eighths % 8 ))
  for ((i = 0; i < cell; i++)); do bar+="█"; done
  if [ "$cell" -lt "$width" ]; then
    case "$rem" in
      1) bar+="▏" ;; 2) bar+="▎" ;; 3) bar+="▍" ;; 4) bar+="▌" ;;
      5) bar+="▋" ;; 6) bar+="▊" ;; 7) bar+="▉" ;; *) bar+="░" ;;
    esac
    start=$(( cell + 1 ))
    for ((i = start; i < width; i++)); do bar+="░"; done
  fi
  printf '%s' "$bar"
}

# Coerce to a clamped integer percent (0-100), rounded, entirely in jq — the input
# is scraped prose, so anything non-numeric must clamp rather than break the shell.
to_pct() { # $1 = raw value
  jq -rn --arg v "${1:-}" '
    (($v | tonumber?) // 0)
    | if . < 0 then 0 elif . > 100 then 100 else . end
    | round' 2>/dev/null || printf '0'
}

to_frac() { jq -rn --argjson p "${1:-0}" '$p / 100' 2>/dev/null || printf '0'; }

sev_dot() {
  local p="${1:-0}"
  if [ "$p" -ge 90 ]; then printf ' 🔴'
  elif [ "$p" -ge 70 ]; then printf ' 🟡'; fi
}

# Best-effort: stamp the sentinels offline so a frozen bar is obvious, and drop
# the native bar so the "⚠ offline" title shows through.
mark_offline() {
  local reason="${1:-offline}"
  cmux ping &>/dev/null || return 0
  _paint "$LABEL_AMPU" "$LABEL_AMPU |⚠ ${reason}|" >/dev/null 2>&1 || true
  _clear_progress "$LABEL_AMPU"
  if [ "$ORB_METER" = "1" ]; then
    _paint "$LABEL_AMPO" "$LABEL_AMPO |⚠ ${reason}|" >/dev/null 2>&1 || true
    _clear_progress "$LABEL_AMPO"
  fi
}

# ── parsing ─────────────────────────────────────────────────────────────────

fetch_usage() { "$AMP_BIN" usage 2>/dev/null; }

# Pull the number that immediately precedes a given phrase, e.g.
#   "... 87% other usage and 100% orb usage remaining ..." + "other usage" -> 87
# Anchored on the phrase, not on line/field position, so reordering the sentence
# or renaming the plan doesn't break it. Accepts decimals ("99.5%"). Empty when
# the phrase is absent — the caller MUST treat empty as "can't tell", not 0.
pct_before() { # $1 = text  $2 = phrase
  printf '%s' "$1" \
    | grep -oE "[0-9]+(\.[0-9]+)?% *$2" 2>/dev/null \
    | head -1 \
    | grep -oE "^[0-9]+(\.[0-9]+)?" 2>/dev/null
}

# Amp's own reset phrase, e.g. "resets upon renewal in 1 month" -> "1 month".
# Cosmetic only: an unparseable reset shows "?" and never blocks a meter.
reset_text() { # $1 = text
  printf '%s' "$1" \
    | grep -oE "resets[^-]*in [^-]*" 2>/dev/null \
    | head -1 \
    | sed -E 's/^.* in //; s/[[:space:]]*$//' \
    | tr -d '|' \
    | head -c 12
}

# Keep the source-derived renewal phrase in --print, but make the narrow dashboard
# label linear and compact. Unknown prose passes through unchanged.
compact_reset_text() { # $1 = reset_text
  printf '%s' "$1" | sed -E \
    -e 's/^([0-9]+) minutes?$/\1m/' \
    -e 's/^([0-9]+) hours?$/\1h/' \
    -e 's/^([0-9]+) days?$/\1d/' \
    -e 's/^([0-9]+) weeks?$/\1w/' \
    -e 's/^([0-9]+) months?$/\1mo/'
}

# INVERSION LIVES HERE — amp reports REMAINING, the meter shows USED.
used_from_remaining() { # $1 = remaining pct (already sanitized 0-100)
  printf '%s' "$(( 100 - ${1:-0} ))"
}

# Failure ledger for --update. A sentinel is an ordinary workspace users can close,
# and writing meters in sequence with a `die` on the first failure meant ONE closed
# sentinel froze every meter after it at whatever it last said — for days, since
# each run aborted in the same place. Record instead of exiting, paint everything
# paintable, report once at the end.
MISSING=(); REJECTED=()

# Write ONE sentinel: a real meter, or an honest "n/a" when the allowance isn't
# reported. A MISSING sentinel for a bucket we don't meter is the intended steady
# state (setup skips it), so that's a quiet no-op; a missing sentinel for a LIVE one
# is a real broken install, recorded in the ledger so the OTHER meter still updates.
_update_bucket() { # $1=label $2=na(0/1) $3=used_pct $4=reset_text
  local label="$1" na="$2" pct="${3:-0}" human="${4:-?}" bar dot frac detail err rc
  if [ "$na" = 1 ]; then
    err=$(_paint "$label" "$label |n/a|"); rc=$?
    [ "$rc" = 10 ] && return 0
    [ "$rc" = 11 ] && { REJECTED+=("$label (${err:-no detail})"); return 1; }
    _clear_progress "$label"
    return 0
  fi
  human=$(compact_reset_text "$human")
  bar=$(make_bar "$pct" 14); dot=$(sev_dot "$pct"); frac=$(to_frac "$pct")
  detail="${pct}% (${human})${dot}"
  err=$(_meter_write "$label" "$label |${detail}|${bar}" "$frac" "$detail"); rc=$?
  [ "$rc" = 10 ] && { MISSING+=("$label"); return 1; }
  [ "$rc" = 11 ] && { REJECTED+=("$label (${err:-no detail})"); return 1; }
  return 0
}

main() {
  local mode="${1:---print}" out remU remO usedU usedO human naU=0 naO=0

  # Provider gate: a disabled or not-installed provider is a clean no-op — no
  # error spam. Existing sentinels are not removed here; doctor reports leftovers.
  if ! provider_enabled; then
    echo "amp disabled (USAGE_PROVIDERS=\"$USAGE_PROVIDERS\") — nothing to do" >&2
    exit 0
  fi
  if ! provider_available; then
    echo "Amp not installed or never logged in (no $AMP_BIN on PATH, or no credentials) — nothing to meter" >&2
    exit 0
  fi

  local frc
  out=$(fetch_usage); frc=$?
  if [ "$frc" -ne 0 ]; then
    # Amp's failure modes aren't distinguishable from the outside (no exit-code
    # contract, and its stderr is swallowed to keep credentials out of the log), so
    # do NOT invent a cause the way the old "(logged out? offline?)" guess-list did.
    # Report the exit status and hand over the one command that shows the real error.
    [ "$mode" = "--update" ] && mark_offline "offline"
    die "\`$AMP_BIN usage\` failed (exit $frc) — run it by hand to see why"
  fi

  if [ "$mode" = "--raw" ]; then
    printf '%s\n' "$out"
    return
  fi

  remU=$(pct_before "$out" "other usage")
  remO=$(pct_before "$out" "orb usage")
  human=$(reset_text "$out")
  [ -n "$human" ] || human="?"

  # Neither number found → the output shape changed (or there's no subscription,
  # only pay-as-you-go credits). Either way we have nothing honest to draw, so go
  # offline rather than paint a fabricated 0%.
  if [ -z "$remU" ] && [ -z "$remO" ]; then
    [ "$mode" = "--update" ] && mark_offline "no data"
    die "could not parse \`$AMP_BIN usage\` (no subscription, or output format changed)"
  fi

  if [ -n "$remU" ]; then usedU=$(used_from_remaining "$(to_pct "$remU")"); else naU=1; fi
  if [ -n "$remO" ]; then usedO=$(used_from_remaining "$(to_pct "$remO")"); else naO=1; fi

  # Which sentinels should EXIST? Consumed by cmux-sentinel-setup.sh. Same
  # fail-open contract as the Codex poller: every can't-tell path exits earlier
  # with no stdout, so empty means "don't know" and setup creates the default —
  # a flaky network can never silently delete a meter. Only a POSITIVE answer
  # here may suppress one. The orb meter is additionally gated on AMP_ORB_METER
  # because it costs a ⌘ key (see the header).
  if [ "$mode" = "--buckets" ]; then
    [ "$naU" = 1 ] || echo "$LABEL_AMPU"
    if [ "$ORB_METER" = "1" ]; then
      [ "$naO" = 1 ] || echo "$LABEL_AMPO"
    fi
    return
  fi

  if [ "$mode" = "--print" ]; then
    if [ "$naU" = 1 ]; then echo "$LABEL_AMPU: n/a"
    else echo "$LABEL_AMPU: ${usedU}% used (${remU}% remaining), resets in ${human}"; fi
    if [ "$naO" = 1 ]; then echo "$LABEL_AMPO: n/a"
    else echo "$LABEL_AMPO: ${usedO}% used (${remO}% remaining), resets in ${human}"; fi
    [ "$ORB_METER" = "1" ] || echo "(orb meter disabled — set AMP_ORB_METER=1 to show it)"
    return
  fi

  if [ "$mode" = "--update" ]; then
    cmux ping &>/dev/null || die "cmux socket rejected (restart cmux to apply socketControlMode=automation)"
    _update_bucket "$LABEL_AMPU" "$naU" "${usedU:-0}" "$human" || true
    [ "$ORB_METER" = "1" ] && { _update_bucket "$LABEL_AMPO" "$naO" "${usedO:-0}" "$human" || true; }
    [ "${#REJECTED[@]}" -gt 0 ] && die "cmux rejected the rename for: ${REJECTED[*]}"
    record_success || echo "WARN: meters updated, but couldn't record Amp freshness in $USAGE_STATE_DIR" >&2
    # Parity with the Claude/Codex pollers: a success line, so the launchd .log
    # proves the poller ran. Without it amp's log stayed 0 bytes forever and a
    # silently-dead amp poller was indistinguishable from a healthy one.
    if [ "$ORB_METER" = "1" ]; then
      echo "updated: ${LABEL_AMPU}=$([ "$naU" = 1 ] && echo n/a || echo "${usedU}%")  ${LABEL_AMPO}=$([ "$naO" = 1 ] && echo n/a || echo "${usedO}%")"
    else
      echo "updated: ${LABEL_AMPU}=$([ "$naU" = 1 ] && echo n/a || echo "${usedU}%")"
    fi
    [ "${#MISSING[@]}" -gt 0 ] && die "no sentinel workspace for: ${MISSING[*]} — create it: ~/bin/cmux-sentinel-setup.sh"
    return 0
  fi

  die "unknown mode: $mode (--print | --raw | --update | --buckets)"
}

main "$@"
