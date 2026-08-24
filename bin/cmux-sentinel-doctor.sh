#!/bin/bash
# cmux-sentinel-doctor.sh — verify the whole cmux-sentinel pipeline is wired.
# READ-ONLY: it changes nothing, just reports. The project's failure modes are
# all SILENT (blank sidebar, stale marker, hooks that never fire), so this turns
# "why isn't it updating?" into one diagnostic. Run: `make doctor` or directly.
#
# No secrets here: sentinels are resolved by their title label at runtime.
set -u

# cmux prints a one-time deprecation notice for legacy verbs (rename-workspace →
# workspace rename) on STDERR. Anything that CAPTURES cmux stderr to explain a
# failure gets that notice at the front of the reason, where it reads as the cause
# — it buried a real "Command timed out" once. cmux documents this switch for it.
export CMUX_QUIET=1

CFG="$HOME/.config/cmux"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0; warns=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$1"; warns=$((warns + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fails=$((fails + 1)); }
note() { printf '  \033[2m•\033[0m %s\n' "$1"; }   # neutral info, doesn't affect status
have() { command -v "$1" >/dev/null 2>&1; }
duration_label() { # $1=minutes
  local mins="${1:-0}"
  case "$mins" in ''|*[!0-9]*) printf '?' ;; *)
    if [ "$mins" -ge 1440 ] && [ $((mins % 1440)) = 0 ]; then printf '%dd' "$((mins / 1440))"
    elif [ "$mins" -ge 60 ] && [ $((mins % 60)) = 0 ]; then printf '%dh' "$((mins / 60))"
    else printf '%dm' "$mins"; fi ;;
  esac
}
check_launchd_job() { # $1=provider  $2=job label
  local provider="$1" job="$2"
  if launchctl list 2>/dev/null | grep -qF -- "$job"; then
    ok "$provider poller loaded ($job)"
  else
    warn "$provider poller not loaded — launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/$job.plist"
  fi
}

echo "cmux-sentinel doctor"

echo "• cmux"
if have cmux; then
  if cmux ping &>/dev/null; then ok "cmux present and responding"
  else bad "cmux installed but 'cmux ping' failed — is the app running?"; fi
else bad "cmux not on PATH"; fi

echo "• sidebar"
if [ -f "$CFG/sidebars/workspaces.swift" ]; then
  ok "sidebar deployed at ~/.config/cmux/sidebars/workspaces.swift"
  if have cmux && cmux sidebar validate workspaces &>/dev/null; then ok "sidebar interprets against validate's synthetic data"
  else warn "sidebar did not validate — run: cmux sidebar validate workspaces"; fi
  if grep -Eq 'w\.title\.hasPrefix\("(5h|7d) "\)' "$CFG/sidebars/workspaces.swift"; then :
  else warn "deployed sidebar is missing its isClaudeMeter title anchors — usage panel won't render"; fi
else bad "sidebar not deployed (run ./install.sh)"; fi

echo "• working-state bridge"
inst="$HOME/.claude/hooks/cmux-bridge.sh"
amp_bridge_file="$HOME/.config/cmux-sentinel/cmux-bridge.sh"
amp_plugin="$HOME/.config/amp/plugins/cmux-sentinel-amp.ts"
repo="$HERE/../hooks/cmux-bridge.sh"
if [ -f "$inst" ]; then
  ok "bridge installed at ~/.claude/hooks/cmux-bridge.sh"
  if [ -f "$repo" ]; then
    if diff -q "$repo" "$inst" >/dev/null 2>&1; then ok "installed bridge matches this repo"
    else warn "installed bridge differs from repo — re-run: WITH_BRIDGE=1 ./install.sh"; fi
  elif grep -q '_sweep_orphan_marks' "$inst"; then ok "installed bridge looks current"
  else warn "installed bridge is an older version (no restart self-heal)"; fi
  settings="$HOME/.claude/settings.json"
  if [ -f "$settings" ] && have jq; then
    missing=""
    # Notification drives the ❓ "waiting on a permission prompt" state, so it's a
    # key event too — without it a blocked session never shows "asking…".
    for ev in SessionStart UserPromptSubmit PreToolUse Notification PreCompact PostCompact Stop; do
      jq -e --arg e "$ev" '(.hooks[$e] // []) | tostring | contains("cmux-bridge")' "$settings" >/dev/null 2>&1 \
        || missing="$missing $ev"
    done
    if [ -z "$missing" ]; then ok "bridge registered for all key hook events"
    else warn "bridge NOT registered for:$missing — re-run 'WITH_BRIDGE=1 ./install.sh' to auto-wire it (or paste README's hooks block), then RESTART Claude Code"; fi
  else warn "can't check hook registration (need ~/.claude/settings.json + jq)"; fi
elif [ -f "$amp_bridge_file" ]; then
  note "Claude bridge not installed — expected for an Amp-only setup"
else
  warn "no agent-state bridge installed — working/compacting rows are off (use --with-bridge or --with-amp)"
fi
if [ -f "$amp_bridge_file" ]; then
  ok "Amp shared bridge installed at ~/.config/cmux-sentinel/cmux-bridge.sh"
  if [ -f "$repo" ] && ! diff -q "$repo" "$amp_bridge_file" >/dev/null 2>&1; then
    warn "Amp shared bridge differs from repo — re-run: WITH_AMP=1 ./install.sh"
  fi
elif [ -f "$amp_plugin" ] && [ -f "$inst" ]; then
  warn "Amp still uses the legacy Claude bridge path — re-run: WITH_AMP=1 ./install.sh"
elif [ -f "$amp_plugin" ]; then
  warn "Amp plugin is installed but its shared bridge is missing — re-run: WITH_AMP=1 ./install.sh"
fi

echo "• auto-refresh"
# cmux.json is JSONC (comments), so grep rather than jq-parse it.
if [ -f "$CFG/cmux.json" ]; then
  if grep -Eq '"socketControlMode"[[:space:]]*:[[:space:]]*"automation"' "$CFG/cmux.json"; then
    ok "socketControlMode: automation (external renames allowed)"
  else warn "cmux.json has no socketControlMode: automation — auto-refresh renames may be rejected"; fi
else warn "no ~/.config/cmux/cmux.json — can't confirm automation mode"; fi

# Usage meters are provider-gated: a provider's panel shows IFF its sentinels
# exist, the poller only maintains them when the provider is installed + enabled
# (USAGE_PROVIDERS), and the sidebar hides any provider with no sentinels. So this
# section cross-checks installed × enabled × sentinel-present and flags only the
# states that are actually wrong (e.g. a leftover panel for an uninstalled
# provider). Sentinels are resolved by TITLE LABEL (released cmux 0.64.20 exposes
# no durable public workspace handle — see the poller's resolve_ref); labels +
# provider set are env-overridable.
echo "• usage meters (providers)"
envf="$CFG/usage-sentinels.env"
# shellcheck disable=SC1090
[ -f "$envf" ] && . "$envf"
lbl5="${SENTINEL_5H_LABEL:-5h}"; lbl7="${SENTINEL_7D_LABEL:-7d}"
lblm7d="${SENTINEL_M7D_LABEL:-m7d}"
providers="${USAGE_PROVIDERS:-claude}"
usage_state_dir="${CMUX_SENTINEL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/cmux-sentinel}/usage"
stale_after="${USAGE_STALE_AFTER_SECONDS:-900}"
case "$stale_after" in ''|*[!0-9]*) warn "invalid USAGE_STALE_AFTER_SECONDS='$stale_after' — using 900"; stale_after=900 ;; esac

# Match the pollers/setup: workspace lists are window-scoped, while launchd and
# the doctor may have no default-window context. Return "ref<TAB>window" and keep
# the window empty when the default lookup found it.
resolve_ref() { # $1 = title label
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

close_hint() { # $1 = ref  $2 = window (empty for the caller/default window)
  if [ -n "${2:-}" ]; then
    printf 'cmux workspace close %q --window %q' "$1" "$2"
  else
    printf 'cmux workspace close %q' "$1"
  fi
}

age_label() { # $1=seconds
  local age="${1:-0}" d h m
  [ "$age" -ge 0 ] 2>/dev/null || age=0
  d=$((age / 86400)); h=$(((age % 86400) / 3600)); m=$(((age % 3600) / 60))
  if [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm' "$m"
  else printf '%ds' "$age"; fi
}

# A freshness stamp says a poller STOPPED succeeding; it can't say why. launchd
# already captured the reason — the plist's StandardErrorPath holds the poller's own
# "ERR: …" line — so read it back instead of leaving the user to guess. Without this
# a stale meter's only advice is "run --update", which just reproduces the failure
# in a terminal (and for a keychain/socket problem may not even reproduce it).
poller_err_log() { # $1 = launchd job label — prints the log path, or nothing
  local plist="$HOME/Library/LaunchAgents/$1.plist" path=""
  [ -f "$plist" ] || return 0
  if have plutil; then
    path=$(plutil -extract StandardErrorPath raw -o - "$plist" 2>/dev/null)
  fi
  # Fallback (and the Linux/CI path): the plists we generate are plain XML.
  [ -n "$path" ] || path=$(grep -A1 '>StandardErrorPath<' "$plist" 2>/dev/null \
    | sed -n 's:.*<string>\(.*\)</string>.*:\1:p' | head -1)
  [ -n "$path" ] && [ -f "$path" ] && printf '%s' "$path"
}

last_poller_error() { # $1 = launchd job label — prints the newest error line
  local log line
  log=$(poller_err_log "$1")
  [ -n "$log" ] || return 0
  # The poller's own messages are "ERR: …"; prefer those over curl/tool chatter.
  line=$(grep -a 'ERR:' "$log" 2>/dev/null | tail -1)
  [ -n "$line" ] || line=$(grep -av '^[[:space:]]*$' "$log" 2>/dev/null | tail -1)
  # One line, bounded — a log line is untrusted text that must not wreck the report.
  printf '%.200s' "$line"
}

# Poller loaded != poller succeeding. Each provider atomically records the epoch
# after its complete --update; this catches a launchd job that silently stopped or
# has failed for multiple intervals. Advisory only: stale data does not break wiring.
check_usage_freshness() { # $1=provider  $2=poller filename  $3=launchd job label
  local provider="$1" script="$2" job="${3:-}" stamp="$usage_state_dir/$1.last-success" now saved age reason
  [ "$stale_after" -gt 0 ] || return 0
  if [ ! -f "$stamp" ]; then
    warn "$provider data freshness unknown — no successful update recorded; run: ~/bin/$script --update"
    reason=$([ -n "$job" ] && last_poller_error "$job")
    [ -n "$reason" ] && note "last poller error: $reason"
    return
  fi
  IFS= read -r saved < "$stamp" || saved=""
  case "$saved" in ''|*[!0-9]*) warn "$provider freshness stamp is invalid — run: ~/bin/$script --update"; return ;; esac
  now=$(date +%s)
  case "$now" in ''|*[!0-9]*) warn "couldn't read the clock — skipping $provider freshness"; return ;; esac
  age=$((now - saved))
  if [ "$age" -lt -60 ]; then
    warn "$provider freshness stamp is in the future — check the system clock, then run: ~/bin/$script --update"
  elif [ "$age" -gt "$stale_after" ]; then
    warn "$provider data stale (last successful update $(age_label "$age") ago; expected within $(age_label "$stale_after")) — run: ~/bin/$script --update"
    reason=$([ -n "$job" ] && last_poller_error "$job")
    [ -n "$reason" ] && note "last poller error: $reason"
  else
    [ "$age" -lt 0 ] && age=0
    ok "$provider data fresh (updated $(age_label "$age") ago)"
  fi
}

claude_installed() {
  security find-generic-password -s "Claude Code-credentials" -w &>/dev/null && return 0
  [ -f "$HOME/.claude/.credentials.json" ] && return 0
  return 1
}
case " $providers " in *" claude "*) claude_on=1 ;; *) claude_on=0 ;; esac
if claude_installed; then claude_inst=1; else claude_inst=0; fi

if [ "$claude_on" = 1 ] && [ "$claude_inst" = 1 ]; then
  ok "claude: installed + enabled → meters active"
  check_launchd_job "claude" "com.cmux-claude-usage"
  check_usage_freshness "claude" "cmux-claude-usage.sh" "com.cmux-claude-usage"
elif [ "$claude_on" = 1 ]; then
  warn "claude: enabled but NOT installed here — poller exits cleanly; any existing sentinels remain until closed"
else
  warn "claude: disabled via USAGE_PROVIDERS=\"$providers\" — poller skips it"
fi

if have cmux && have jq; then
  # m7d (the per-model weekly cap) is metered only when CLAUDE_MODEL_METER=1 —
  # same local opt-in policy as the Amp orb meter, and for the same reason: an
  # unmetered sentinel reads 'n/a' forever while still eating a ⌘ key.
  for lbl in "$lbl5" "$lbl7" "$lblm7d"; do
    lbl_metered=1
    [ "$lbl" = "$lblm7d" ] && [ "${CLAUDE_MODEL_METER:-0}" != 1 ] && lbl_metered=0
    rw="$(resolve_ref "$lbl")"; IFS=$'\t' read -r ref ref_win <<<"$rw"
    where="$ref"; [ -n "$ref_win" ] && where="$where in window $ref_win"
    close_cmd="$(close_hint "$ref" "$ref_win")"
    if [ -n "$ref" ]; then
      if [ "$claude_on" != 1 ] || [ "$claude_inst" != 1 ]; then warn "'$lbl' sentinel present ($where) but claude is off/uninstalled — close it to hide the panel: $close_cmd"
      elif [ "$lbl_metered" = 0 ]; then warn "'$lbl' sentinel present ($where) but it isn't metered (CLAUDE_MODEL_METER is off) — it'll read 'n/a' forever and still eats a ⌘ key: $close_cmd"
      else ok "'$lbl' sentinel present ($where)"; fi
    else
      if [ "$lbl_metered" = 0 ]; then ok "no '$lbl' sentinel — correct, it isn't metered"
      elif [ "$claude_on" = 1 ] && [ "$claude_inst" = 1 ]; then warn "no '$lbl' sentinel (title \"$lbl\" or starting \"$lbl \") — create it: $HERE/cmux-sentinel-setup.sh"
      else ok "no '$lbl' sentinel — panel hidden by design (claude off/uninstalled)"; fi
    fi
  done
else warn "cmux or jq unavailable — can't check sentinels"; fi

# Codex provider — same installed × enabled × sentinel cross-check. Ask Codex's
# auth abstraction so file- and keyring-backed ChatGPT logins both work. API-key
# mode has no ChatGPT-plan account allowance.
lblcx5="${SENTINEL_CX5H_LABEL:-cx5h}"; lblcx7="${SENTINEL_CX7D_LABEL:-cx7d}"
codex_installed() {
  have codex || return 1
  codex login status 2>&1 | grep -q '^Logged in using ChatGPT$'
}
case " $providers " in *" codex "*) codex_on=1 ;; *) codex_on=0 ;; esac
if codex_installed; then codex_inst=1; else codex_inst=0; fi

if [ "$codex_on" = 1 ] && [ "$codex_inst" = 1 ]; then
  ok "codex: ChatGPT login stored + provider enabled"
  check_launchd_job "codex" "com.cmux-codex-usage"
  check_usage_freshness "codex" "cmux-codex-usage.sh" "com.cmux-codex-usage"
elif [ "$codex_on" = 1 ]; then
  warn "codex: enabled but NOT installed here — poller exits cleanly; any existing sentinels remain until closed"
elif [ "$codex_inst" = 1 ]; then
  ok "codex: installed but not enabled — add it to USAGE_PROVIDERS (\"claude codex\") to show its meters"
else
  ok "codex: not installed and not enabled — nothing to do"
fi

if have cmux && have jq; then
  # A sentinel is only MISSING if the account actually has that window: setup
  # deliberately skips one OpenAI doesn't return (it dropped 5h for Codex Pro), so
  # nagging to "create it" would be a permanent false alarm — and a doctor that cries
  # wolf gets ignored, which costs us the real warnings. Ask the poller's structured
  # status mode: available carries a KNOWN bucket set; unknown means offline/expired/
  # schema drift and must RETAIN the current layout without suggesting creation or
  # removal. `--buckets` intentionally cannot make that distinction because setup
  # needs its older fail-open empty-output contract.
  cx_cap=""; cx_status="unknown"; cx_reason="status unavailable"; cx_live=""
  if [ "$codex_on" != 1 ]; then
    cx_status="disabled"; cx_reason="provider disabled"
  elif [ "$codex_inst" != 1 ]; then
    cx_status="uninstalled"; cx_reason="ChatGPT-plan login unavailable"
  else
    [ -x "$HERE/cmux-codex-usage.sh" ] && cx_cap=$("$HERE/cmux-codex-usage.sh" --status 2>/dev/null)
    if printf '%s' "$cx_cap" | jq -e '.status | type == "string"' >/dev/null 2>&1; then
      cx_status=$(printf '%s' "$cx_cap" | jq -r '.status')
      cx_reason=$(printf '%s' "$cx_cap" | jq -r '.reason // ""')
      [ "$cx_status" = "available" ] && cx_live=$(printf '%s' "$cx_cap" | jq -r '.buckets[]?')
    fi
  fi
  if [ "$codex_on" = 1 ] && [ "$codex_inst" = 1 ]; then
    if [ "$cx_status" = "available" ]; then
      ok "codex: live allowance available → default meter data valid"
      while IFS=$'\t' read -r extra_name extra_used extra_mins; do
        [ -n "$extra_name" ] || continue
        note "codex additional limit: $extra_name — ${extra_used}% used ($(duration_label "$extra_mins") window); informational only, no extra workspace"
      done < <(printf '%s' "$cx_cap" | jq -r '
        .additionalLimits[]? | select(.name != .id) | .name as $name | .windows[]?
        | [$name, (.usedPercent | if . < 0 then 0 elif . > 100 then 100 else . end | round), .windowDurationMins]
        | @tsv' 2>/dev/null)
      reset_count=$(printf '%s' "$cx_cap" | jq -r '.resetCredits.availableCount // empty' 2>/dev/null)
      case "$reset_count" in ''|*[!0-9]*) : ;;
        0) note "codex usage resets: none available" ;;
        1) note "codex usage resets: 1 available (read-only; redeem in Codex)" ;;
        *) note "codex usage resets: $reset_count available (read-only; redeem in Codex)" ;;
      esac
      while IFS=$'\t' read -r reset_title reset_status; do
        [ -n "$reset_title" ] || reset_title="unnamed reset"
        [ -n "$reset_status" ] || reset_status="status unknown"
        note "codex reset credit: $reset_title — $reset_status"
      done < <(printf '%s' "$cx_cap" | jq -r \
        '.resetCredits.credits[]? | [(.title // ""), (.status // "")] | @tsv' 2>/dev/null)
    else
      warn "codex: live allowance unavailable — ${cx_reason:-offline or schema changed}; stored login alone does not prove meters are active"
      note "retaining the current Codex sentinel layout until capability is known"
    fi
  fi
  for lbl in "$lblcx5" "$lblcx7"; do
    rw="$(resolve_ref "$lbl")"; IFS=$'\t' read -r ref ref_win <<<"$rw"
    where="$ref"; [ -n "$ref_win" ] && where="$where in window $ref_win"
    close_cmd="$(close_hint "$ref" "$ref_win")"
    lbl_live=1
    [ "$cx_status" = "available" ] && ! printf '%s\n' "$cx_live" | grep -qxF -- "$lbl" && lbl_live=0
    if [ -n "$ref" ]; then
      if [ "$codex_on" != 1 ]; then warn "'$lbl' sentinel present ($where) but codex is disabled — close it to hide the panel: $close_cmd"
      elif [ "$codex_inst" != 1 ]; then warn "'$lbl' sentinel present ($where) but codex is uninstalled — close it to hide the panel: $close_cmd"
      elif [ "$lbl_live" = 0 ]; then warn "'$lbl' sentinel present ($where) but your plan has no such window — it'll read 'n/a' forever and still eats a ⌘ key: $close_cmd"
      else ok "'$lbl' sentinel present ($where)"; fi
    elif [ "$codex_on" = 1 ] && [ "$codex_inst" = 1 ]; then
      if [ "$cx_status" = "unknown" ]; then note "no '$lbl' sentinel — capability unknown, so the doctor is retaining this layout"
      elif [ "$lbl_live" = 0 ]; then ok "no '$lbl' sentinel — correct, your plan has no such window"
      else warn "no '$lbl' sentinel (title \"$lbl\" or starting \"$lbl \") — create it: $HERE/cmux-sentinel-setup.sh"; fi
    fi
  done
fi

# Amp provider — same installed × enabled × sentinel cross-check. "Installed" is
# the CLI plus a credentials file (existence only, never read): an expired login
# still has the file, so it stays a transient offline rather than a false
# "uninstalled". Amp meters a MONTHLY allowance, not rolling windows, and the orb
# meter only exists when AMP_ORB_METER=1. Keep that local policy even when
# --buckets returns empty/can't-tell; fail-open must never enable an optional meter.
lblampu="${SENTINEL_AMPU_LABEL:-ampu}"; lblampo="${SENTINEL_AMPO_LABEL:-ampo}"
amp_installed() { command -v amp >/dev/null 2>&1 && [ -s "$HOME/.local/share/amp/secrets.json" ]; }
case " $providers " in *" amp "*) amp_on=1 ;; *) amp_on=0 ;; esac
if amp_installed; then amp_inst=1; else amp_inst=0; fi

if [ "$amp_on" = 1 ] && [ "$amp_inst" = 1 ]; then
  ok "amp: installed + enabled → meters active"
  check_launchd_job "amp" "com.cmux-amp-usage"
  check_usage_freshness "amp" "cmux-amp-usage.sh" "com.cmux-amp-usage"
elif [ "$amp_on" = 1 ]; then
  warn "amp: enabled but NOT installed/logged in here — poller exits cleanly; any existing sentinels remain until closed"
elif [ "$amp_inst" = 1 ]; then
  ok "amp: installed but not enabled — add it to USAGE_PROVIDERS (\"claude amp\") to show its meters"
else
  ok "amp: not installed and not enabled — nothing to do"
fi

if have cmux && have jq; then
  amp_live=""
  if [ "$amp_on" = 1 ] && [ "$amp_inst" = 1 ] && [ -x "$HERE/cmux-amp-usage.sh" ]; then
    amp_live=$("$HERE/cmux-amp-usage.sh" --buckets 2>/dev/null)
  fi
  for lbl in "$lblampu" "$lblampo"; do
    rw="$(resolve_ref "$lbl")"; IFS=$'\t' read -r ref ref_win <<<"$rw"
    where="$ref"; [ -n "$ref_win" ] && where="$where in window $ref_win"
    close_cmd="$(close_hint "$ref" "$ref_win")"
    lbl_live=1
    [ -n "$amp_live" ] && ! printf '%s\n' "$amp_live" | grep -qxF -- "$lbl" && lbl_live=0
    [ "$lbl" = "$lblampo" ] && [ "${AMP_ORB_METER:-0}" != 1 ] && lbl_live=0
    if [ -n "$ref" ]; then
      if [ "$amp_on" != 1 ]; then warn "'$lbl' sentinel present ($where) but amp is disabled — close it to hide the panel: $close_cmd"
      elif [ "$amp_inst" != 1 ]; then warn "'$lbl' sentinel present ($where) but amp is uninstalled — close it to hide the panel: $close_cmd"
      elif [ "$lbl_live" = 0 ]; then warn "'$lbl' sentinel present ($where) but it isn't metered (orb meter off, or no such allowance) — it'll read 'n/a' forever and still eats a ⌘ key: $close_cmd"
      else ok "'$lbl' sentinel present ($where)"; fi
    elif [ "$amp_on" = 1 ] && [ "$amp_inst" = 1 ]; then
      if [ "$lbl_live" = 0 ]; then ok "no '$lbl' sentinel — correct, it isn't metered"
      else warn "no '$lbl' sentinel (title \"$lbl\" or starting \"$lbl \") — create it: $HERE/cmux-sentinel-setup.sh"; fi
    fi
  done
fi

# ── ⌘N shortcut layout ────────────────────────────────────────────────────────
# Mirrors cmux's WorkspaceShortcutMapper: ⌘1…⌘8 select positions 0…7, and ⌘9 ALWAYS
# selects the LAST row (count-1) — so positions 8…count-2 are the "keyless band".
# That digit math is unchanged (re-verified on 0.64.22 against upstream's own
# WorkspaceShortcutMapperTests), but the SET being numbered changed in 0.64.22:
# TabManager.selectWorkspaceByNumber now indexes the ordinary rendered rows, not the
# raw tab array. See JQ_NUMBERED below.
#
# A sentinel is an ordinary workspace to cmux ("sentinel" only exists in our sidebar's
# predicates), so a meter on a keyed index silently EATS that ⌘ key.
# bin/cmux-sentinel-setup.sh parks them in the band, but that's a one-shot pass: CLOSING
# workspaces above a meter shifts it up, and the invariant decays with no symptom beyond
# a ⌘ key doing something unexpected. Hence a check — this is exactly the class of silent
# failure the doctor exists for. Read-only by design: we report, setup fixes. (Deliberately
# NOT auto-repaired in the pollers — re-asserting order every 5min would fight manual
# drag-reordering; see CLAUDE.md.)
echo "• ⌘N shortcut layout"
if have cmux && have jq; then
  lay_labels="$(printf '%s\n' "$lbl5" "$lbl7" "$lblm7d" "$lblcx5" "$lblcx7" "$lblampu" "$lblampo" | jq -R . | jq -s .)"
  # The rows cmux actually numbers for ⌘1…⌘9 — kept identical to the copy in
  # bin/cmux-sentinel-setup.sh (setup parks by it, the doctor reports drift off it).
  # Since 0.64.22 (#9176) ⌘N indexes the ORDINARY sidebar rows, so a group ANCHOR
  # (drawn as the group header) and every member of a COLLAPSED group are skipped,
  # shifting each row below them one key up.
  # shellcheck disable=SC2016  # jq program — $gs/$x/$r are jq vars, must NOT expand in bash
  JQ_NUMBERED='def numbered($gs):
    ( [ $gs[]? | .anchor_workspace_ref // empty ]
      + [ $gs[]? | select(.is_collapsed == true) | .member_workspace_refs[]? ] ) as $x
    | [ .workspaces | sort_by(.index)[] | select( .ref as $r | ($x | index($r)) == null ) ];'
  check_layout() { # $1 = window id; empty means default-window fallback
    local win="$1" ctx="" lay grp eaten n_ws n_meters first_meter slack
    if [ -n "$win" ]; then
      lay="$(cmux workspace list --window "$win" --json 2>/dev/null)"; ctx=" in window $win"
      grp="$(cmux workspace-group list --window "$win" --json 2>/dev/null)"
    else
      lay="$(cmux workspace list --json 2>/dev/null)"
      grp="$(cmux workspace-group list --json 2>/dev/null)"
    fi
    grp="$(printf '%s' "$grp" | jq -c '.groups // []' 2>/dev/null)"; [ -n "$grp" ] || grp='[]'
    # Digits eaten by a meter, computed off the NUMBERED position — not raw .index
    # (0.64.22/#9176 skips group anchors and collapsed members, so a group above a
    # meter shifts it a key up) and never off the ref, which is an insertion-order
    # handle that does NOT equal display position. A meter that is itself unnumbered
    # eats nothing, which falls out of the filter for free.
    eaten="$(printf '%s' "$lay" | jq -r --argjson ls "$lay_labels" --argjson gs "$grp" "$JQ_NUMBERED"'
        (numbered($gs)) as $rows
        | ($rows | length) as $n
        | [ $rows | to_entries[]
            | select(.value.title as $t | $ls | any(. as $l | $t == $l or ($t | startswith($l + " "))))
            | .key
            | if . == $n - 1 then "⌘9" elif . <= 7 then "⌘\(. + 1)" else empty end ]
        | unique | join(", ")' 2>/dev/null)"
    n_ws="$(printf '%s' "$lay" | jq -r '.workspaces | length' 2>/dev/null)"
    n_meters="$(printf '%s' "$lay" | jq -r --argjson ls "$lay_labels" '
        [ .workspaces[] | select(.title as $t | $ls | any(. as $l | $t == $l or ($t | startswith($l + " ")))) ] | length' 2>/dev/null)"

    if [ -z "${lay:-}" ] || [ -z "${n_ws:-}" ]; then
      warn "couldn't read the workspace list$ctx — skipping layout check"
    elif [ "${n_meters:-0}" = 0 ]; then
      note "no meters$ctx — nothing to park"
    elif [ -n "$eaten" ]; then
      warn "meters$ctx are eating $eaten — re-park them: $HERE/cmux-sentinel-setup.sh"
    else
      # A meter needs 8 reals above it to clear ⌘1…⌘8. Closing rows consumes
      # the difference between the first meter's numbered position and 8.
      # Collapsing a group above the meters spends that headroom just as fast as
      # closing workspaces does, since a collapsed group contributes only its
      # (unnumbered) header.
      first_meter="$(printf '%s' "$lay" | jq -r --argjson ls "$lay_labels" --argjson gs "$grp" "$JQ_NUMBERED"'
          [ numbered($gs) | to_entries[]
            | select(.value.title as $t | $ls | any(. as $l | $t == $l or ($t | startswith($l + " "))))
            | .key ] | min' 2>/dev/null)"
      ok "all 9 ⌘ keys$ctx are on real workspaces (meters parked in the keyless band)"
      # jq's `min` over an empty array is null: every meter is UNNUMBERED (dragged into
      # a group, or into a collapsed one). That's a genuine all-clear — the meters cost
      # no key at all — but there is no position to measure headroom from, and
      # $(( null - 8 )) would quietly read as 0 and print a negative countdown.
      case "${first_meter:-null}" in
        ''|null) slack="" ;;
        *) slack=$(( first_meter - 8 )) ;;
      esac
      if [ -n "$slack" ] && [ "$slack" -le 1 ]; then
        note "headroom$ctx is thin — closing $((slack + 1)) more workspace(s) above the meters will eat ⌘8; re-run cmux-sentinel-setup.sh after a cleanup"
      fi
    fi
  }

  windows="$(cmux list-windows --json 2>/dev/null | jq -r '.[].id // empty' 2>/dev/null)"
  if [ -n "$windows" ]; then
    while IFS= read -r window; do [ -n "$window" ] && check_layout "$window"; done <<<"$windows"
  else
    check_layout ""
  fi
else warn "cmux or jq unavailable — can't check the ⌘N layout"; fi

# Sidebar DATA snapshot (cmux 0.64.16+ exposes extension.sidebar.snapshot). This is
# the closest read-only view of what cmux actually projects to the sidebar — handy
# when a meter looks wrong. NB: the snapshot is the DATA MODEL, not the rendered
# tree, so it can confirm the inputs are present but CANNOT prove the interpreter
# rendered them (parse-passes/render-blank is this project's classic failure) — that
# still needs an eyeball. Also auto-naming guard: if cmux's global auto-naming is on
# it could rename a sentinel and blank its meter (we can only detect it).
echo "• sidebar data (snapshot, read-only)"
if have cmux && have jq; then
  snap="$(cmux rpc extension.sidebar.snapshot '{}' 2>/dev/null)"
  if [ -n "$snap" ] && printf '%s' "$snap" | jq -e . >/dev/null 2>&1; then
    # all meter labels for enabled providers
    labels=""
    if [ "$claude_on" = 1 ]; then
      labels="$labels $lbl5 $lbl7"
      [ "${CLAUDE_MODEL_METER:-0}" = 1 ] && labels="$labels $lblm7d"
    fi
    if [ "$codex_on" = 1 ]; then
      if [ "${cx_status:-unknown}" = "available" ]; then
        printf '%s\n' "$cx_live" | grep -qxF -- "$lblcx5" && labels="$labels $lblcx5"
        printf '%s\n' "$cx_live" | grep -qxF -- "$lblcx7" && labels="$labels $lblcx7"
      else
        # Unknown capability means retain the CURRENT layout. Snapshot only the
        # Codex sentinels that actually exist; otherwise this final section would
        # contradict the earlier no-create/no-remove diagnostic with a false miss.
        for cx_lbl in "$lblcx5" "$lblcx7"; do
          rw="$(resolve_ref "$cx_lbl")"; IFS=$'\t' read -r cx_ref _ <<<"$rw"
          [ -n "$cx_ref" ] && labels="$labels $cx_lbl"
        done
      fi
    fi
    if [ "$amp_on" = 1 ]; then
      labels="$labels $lblampu"
      [ "${AMP_ORB_METER:-0}" = 1 ] && labels="$labels $lblampo"
    fi
    for lbl in $labels; do
      row="$(printf '%s' "$snap" | jq -r --arg l "$lbl" \
        'first(.workspaces[] | select(.title == $l or (.title|startswith($l+" ")))) | .title // empty' 2>/dev/null)"
      if [ -n "$row" ]; then ok "snapshot sees '$lbl' → \"$row\""
      else warn "snapshot has no '$lbl' sentinel in this window (sidebar renders per-window — keep sentinels in the window the sidebar is shown in)"; fi
    done
    note "snapshot proves DATA, not RENDER; validate uses synthetic data and does not mount/layout — eyeball the panel after changes"
  else
    note "extension.sidebar.snapshot unavailable (older cmux?) — skipping; using workspace list above"
  fi
  # auto-naming guard (same probe the setup script uses; empty params = no mutation)
  probe="$(cmux rpc workspace.set_auto_title '{}' 2>&1 || true)"
  case "$probe" in
    *[Dd]isabled*[Ss]ettings*) ok "cmux auto-naming OFF globally — sentinel title prefixes are safe" ;;
    *) warn "cmux auto-naming may be ON — it could rename a sentinel and blank its meter; disable it in Settings" ;;
  esac
else
  note "cmux or jq unavailable — skipping snapshot check"
fi

# Workspace-group names (opt-in). cmux passes custom sidebars NO group data, so a
# group renders its anchor workspace's title (often a generic "Group N") instead of
# the group name. cmux-group-sync.sh keeps anchor titles in sync when
# GROUP_NAME_SYNC=1. This cross-checks groups-present × enabled × in-sync and only
# nags when something is actually off. See
# .claude/research/2026-06-19-workspace-group-names-in-sidebar.md.
echo "• workspace-group names (opt-in)"
gsync="${GROUP_NAME_SYNC:-0}"
if have cmux && have jq; then
  ngroups=0; ndiverged=0
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    while IFS=$'\t' read -r gname ganchor; do
      [ -n "$gname" ] && [ -n "$ganchor" ] || continue
      ngroups=$((ngroups + 1))
      gtitle="$(cmux workspace list --window "$w" --json 2>/dev/null \
        | jq -r --arg r "$ganchor" '.workspaces[] | select(.ref == $r) | .title' 2>/dev/null | head -1)"
      gbase="$gtitle"
      case "$gbase" in ⚡*) gbase="${gbase#⚡}" ;; ⏳*) gbase="${gbase#⏳}" ;; ❓*) gbase="${gbase#❓}" ;; esac
      gbase="${gbase# }"
      [ "$gbase" = "$gname" ] || ndiverged=$((ndiverged + 1))
    done < <(cmux workspace-group list --window "$w" --json 2>/dev/null \
      | jq -r '.groups[]? | select(.name != null and .name != "") | "\(.name)\t\(.anchor_workspace_ref)"' 2>/dev/null)
  done < <(cmux list-windows --json 2>/dev/null | jq -r '.[].id // empty' 2>/dev/null)
  if [ "$ngroups" = 0 ]; then
    note "no workspace groups — nothing to sync"
  elif [ "$gsync" = 1 ]; then
    if launchctl list 2>/dev/null | grep -q com.cmux-group-sync; then ok "group-name sync ON, launchd loaded ($ngroups group(s))"
    else warn "GROUP_NAME_SYNC=1 but launchd job not loaded — launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.cmux-group-sync.plist"; fi
    if [ "$ndiverged" = 0 ]; then ok "all $ngroups anchor title(s) match their group name"
    else warn "$ndiverged of $ngroups group anchor(s) out of sync — run: ~/bin/cmux-group-sync.sh --update"; fi
  else
    warn "$ngroups workspace group(s) present but GROUP_NAME_SYNC is off — sidebar shows anchor titles, not group names (set GROUP_NAME_SYNC=1)"
  fi
else
  note "cmux or jq unavailable — skipping group-name check"
fi

echo
if [ "$fails" -gt 0 ]; then printf '\033[31m%d problem(s), %d warning(s).\033[0m\n' "$fails" "$warns"; exit 1
elif [ "$warns" -gt 0 ]; then printf '\033[33mAll critical checks passed, %d warning(s).\033[0m\n' "$warns"; exit 0
else printf '\033[32mEverything wired. \033[0m\n'; exit 0; fi
