#!/bin/bash
# cmux-sentinel-doctor.sh — verify the whole cmux-sentinel pipeline is wired.
# READ-ONLY: it changes nothing, just reports. The project's failure modes are
# all SILENT (blank sidebar, stale marker, hooks that never fire), so this turns
# "why isn't it updating?" into one diagnostic. Run: `make doctor` or directly.
#
# No secrets here: sentinel UUIDs are read at runtime from the user's env file.
set -u

CFG="$HOME/.config/cmux"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0; warns=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$1"; warns=$((warns + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fails=$((fails + 1)); }
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
  if grep 'REPLACE_WITH_.*_UUID' "$CFG/sidebars/workspaces.swift" | grep -vq '^[[:space:]]*//'; then
    warn "deployed sidebar has an un-substituted REPLACE_WITH_* placeholder on an active line"
  fi
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
    for ev in SessionStart UserPromptSubmit PreToolUse PreCompact PostCompact Stop; do
      jq -e --arg e "$ev" '(.hooks[$e] // []) | tostring | contains("cmux-bridge")' "$settings" >/dev/null 2>&1 \
        || missing="$missing $ev"
    done
    if [ -z "$missing" ]; then ok "bridge registered for all key hook events"
    else warn "bridge NOT registered for:$missing (see README — add to ~/.claude/settings.json)"; fi
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

echo "• usage sentinels"
envf="$CFG/usage-sentinels.env"
if [ -f "$envf" ]; then
  for key in SENTINEL_5H SENTINEL_7D; do
    val="$(grep -E "^${key}=" "$envf" | head -1 | cut -d= -f2- | tr -d '[:space:]')"
    if [ -z "$val" ]; then bad "$key not set in usage-sentinels.env"
    elif printf '%s' "$val" | grep -q 'REPLACE_WITH'; then bad "$key is still the placeholder — put your real UUID"
    elif have cmux && cmux list-workspaces --id-format uuids 2>/dev/null | grep -qF "$val"; then
      ok "$key resolves to a live workspace"
      grep -qF "$val" "$CFG/sidebars/workspaces.swift" 2>/dev/null \
        || warn "$key not referenced in the deployed sidebar's isUsageMeter() — meter row won't show"
    else warn "$key set but no matching workspace found (create the sentinel?)"; fi
  done
else warn "no usage-sentinels.env — usage meters are off (run ./install.sh)"; fi

echo
if [ "$fails" -gt 0 ]; then printf '\033[31m%d problem(s), %d warning(s).\033[0m\n' "$fails" "$warns"; exit 1
elif [ "$warns" -gt 0 ]; then printf '\033[33mAll critical checks passed, %d warning(s).\033[0m\n' "$warns"; exit 0
else printf '\033[32mEverything wired. \033[0m\n'; exit 0; fi
