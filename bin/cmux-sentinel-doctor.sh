#!/bin/bash
# cmux-sentinel-doctor.sh — verify the whole cmux-sentinel pipeline is wired.
# READ-ONLY: it changes nothing, just reports. The project's failure modes are
# all SILENT (blank sidebar, stale marker, hooks that never fire), so this turns
# "why isn't it updating?" into one diagnostic. Run: `make doctor` or directly.
#
# No secrets here: sentinels are resolved by their title label at runtime.
set -u

CFG="$HOME/.config/cmux"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0; warns=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$1"; warns=$((warns + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fails=$((fails + 1)); }
note() { printf '  \033[2m•\033[0m %s\n' "$1"; }   # neutral info, doesn't affect status
have() { command -v "$1" >/dev/null 2>&1; }

echo "cmux-sentinel doctor"

echo "• cmux"
if have cmux; then
  if cmux ping &>/dev/null; then ok "cmux present and responding"
  else bad "cmux installed but 'cmux ping' failed — is the app running?"; fi
else bad "cmux not on PATH"; fi

echo "• sidebar"
if [ -f "$CFG/sidebars/workspaces.swift" ]; then
  ok "sidebar deployed at ~/.config/cmux/sidebars/workspaces.swift"
  if have cmux && cmux sidebar validate workspaces &>/dev/null; then ok "sidebar parses (validate)"
  else warn "sidebar did not validate — run: cmux sidebar validate workspaces"; fi
  if grep -Eq 'w\.title\.hasPrefix\("(5h|7d) "\)' "$CFG/sidebars/workspaces.swift"; then :
  else warn "deployed sidebar is missing its isClaudeMeter title anchors — usage panel won't render"; fi
else bad "sidebar not deployed (run ./install.sh)"; fi

echo "• working-state bridge"
inst="$HOME/.claude/hooks/cmux-bridge.sh"
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
else warn "bridge not installed — working/compacting rows are off (WITH_BRIDGE=1 ./install.sh)"; fi

echo "• auto-refresh"
if launchctl list 2>/dev/null | grep -q com.cmux-claude-usage; then ok "launchd poller loaded (com.cmux-claude-usage)"
else warn "poller not loaded — launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.cmux-claude-usage.plist"; fi
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
# provider). Sentinels are resolved by TITLE LABEL (cmux 0.64.15 dropped stable
# UUIDs — see the poller's resolve_ref); labels + provider set are env-overridable.
echo "• usage meters (providers)"
envf="$CFG/usage-sentinels.env"
# shellcheck disable=SC1090
[ -f "$envf" ] && . "$envf"
lbl5="${SENTINEL_5H_LABEL:-5h}"; lbl7="${SENTINEL_7D_LABEL:-7d}"
providers="${USAGE_PROVIDERS:-claude}"

claude_installed() {
  security find-generic-password -s "Claude Code-credentials" -w &>/dev/null && return 0
  [ -f "$HOME/.claude/.credentials.json" ] && return 0
  return 1
}
case " $providers " in *" claude "*) claude_on=1 ;; *) claude_on=0 ;; esac
if claude_installed; then claude_inst=1; else claude_inst=0; fi

if [ "$claude_on" = 1 ] && [ "$claude_inst" = 1 ]; then
  ok "claude: installed + enabled → meters active"
elif [ "$claude_on" = 1 ]; then
  warn "claude: enabled but NOT installed here — poller exits cleanly, no panel (expected if you don't use Claude)"
else
  warn "claude: disabled via USAGE_PROVIDERS=\"$providers\" — poller skips it"
fi

if have cmux && have jq; then
  for lbl in "$lbl5" "$lbl7"; do
    ref="$(cmux workspace list --json 2>/dev/null \
      | jq -r --arg l "$lbl" '.workspaces[] | select(.title == $l or (.title|startswith($l+" "))) | .ref' 2>/dev/null | head -1)"
    if [ -n "$ref" ]; then
      if [ "$claude_on" = 1 ] && [ "$claude_inst" = 1 ]; then ok "'$lbl' sentinel present ($ref)"
      else warn "'$lbl' sentinel present ($ref) but claude is off/uninstalled — close it to hide the panel: cmux workspace close $ref"; fi
    else
      if [ "$claude_on" = 1 ] && [ "$claude_inst" = 1 ]; then warn "no '$lbl' sentinel (title \"$lbl\" or starting \"$lbl \") — create it (see install.sh)"
      else ok "no '$lbl' sentinel — panel hidden by design (claude off/uninstalled)"; fi
    fi
  done
else warn "cmux or jq unavailable — can't check sentinels"; fi

# Codex provider — same installed × enabled × sentinel cross-check. Codex usage is
# read from local rollout files (no creds), so "installed" = the CLI or ~/.codex.
lblcx5="${SENTINEL_CX5H_LABEL:-cx5h}"; lblcx7="${SENTINEL_CX7D_LABEL:-cx7d}"
codex_installed() { command -v codex >/dev/null 2>&1 || [ -d "$HOME/.codex/sessions" ]; }
case " $providers " in *" codex "*) codex_on=1 ;; *) codex_on=0 ;; esac
if codex_installed; then codex_inst=1; else codex_inst=0; fi

if [ "$codex_on" = 1 ] && [ "$codex_inst" = 1 ]; then
  ok "codex: installed + enabled → meters active"
elif [ "$codex_on" = 1 ]; then
  warn "codex: enabled but NOT installed here — poller exits cleanly, no panel"
elif [ "$codex_inst" = 1 ]; then
  ok "codex: installed but not enabled — add it to USAGE_PROVIDERS (\"claude codex\") to show its meters"
else
  ok "codex: not installed and not enabled — nothing to do"
fi

if [ "$codex_on" = 1 ] && have cmux && have jq; then
  for lbl in "$lblcx5" "$lblcx7"; do
    ref="$(cmux workspace list --json 2>/dev/null \
      | jq -r --arg l "$lbl" '.workspaces[] | select(.title == $l or (.title|startswith($l+" "))) | .ref' 2>/dev/null | head -1)"
    if [ -n "$ref" ]; then
      if [ "$codex_inst" = 1 ]; then ok "'$lbl' sentinel present ($ref)"
      else warn "'$lbl' sentinel present ($ref) but codex is uninstalled — close it to hide the panel: cmux workspace close $ref"; fi
    elif [ "$codex_inst" = 1 ]; then warn "no '$lbl' sentinel (title \"$lbl\" or starting \"$lbl \") — create it (see install.sh)"
    fi
  done
fi

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
    [ "$claude_on" = 1 ] && labels="$labels $lbl5 $lbl7"
    [ "$codex_on" = 1 ]  && labels="$labels $lblcx5 $lblcx7"
    for lbl in $labels; do
      row="$(printf '%s' "$snap" | jq -r --arg l "$lbl" \
        'first(.workspaces[] | select(.title == $l or (.title|startswith($l+" ")))) | .title // empty' 2>/dev/null)"
      if [ -n "$row" ]; then ok "snapshot sees '$lbl' → \"$row\""
      else warn "snapshot has no '$lbl' sentinel in this window (sidebar renders per-window — keep sentinels in the window the sidebar is shown in)"; fi
    done
    note "snapshot proves the sidebar's DATA, not its RENDER — validate only parses; eyeball the panel after changes"
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
