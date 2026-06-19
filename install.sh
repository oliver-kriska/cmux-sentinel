#!/bin/bash
# install.sh — place the opinionated cmux sidebar files into your config.
# Idempotent and non-destructive: backs up anything it would overwrite. Re-run it
# any time to UPDATE — the curl bootstrap git-pulls the cache, then this re-deploys
# every file (and refreshes an existing bridge automatically; see step 5).
# Does NOT touch any secrets. Sentinels are matched by title label now (no ids
# to edit) — follow the printed "NEXT STEPS" to finish wiring it up.
set -euo pipefail

REPO_URL="https://github.com/oliver-kriska/cmux-sentinel.git"

# Resolve our own directory. When piped (curl … | bash) there is no file beside
# us — BASH_SOURCE is empty and the repo files aren't local — so clone to a cache
# dir and re-exec from there. This is what makes the one-line curl installer work.
src="${BASH_SOURCE[0]:-}"
here=""
[ -n "$src" ] && here="$(cd "$(dirname "$src")" && pwd)"
if [ -z "$here" ] || [ ! -f "$here/bin/cmux-claude-usage.sh" ]; then
  command -v git >/dev/null 2>&1 || { echo "git is required for the curl installer" >&2; exit 1; }
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/cmux-sentinel"
  echo "Fetching cmux-sentinel → $cache"
  if [ -d "$cache/.git" ]; then git -C "$cache" pull --ff-only --quiet || true
  else rm -rf "${cache:?}"; git clone --depth 1 "$REPO_URL" "$cache"; fi
  exec bash "$cache/install.sh"   # WITH_BRIDGE and other env vars survive exec
fi

cfg="$HOME/.config/cmux"
bak() { [ -e "$1" ] && cp "$1" "$1.bak.$(date +%s)" && echo "  backed up $1"; return 0; }

# Idempotently wire the bridge into ~/.claude/settings.json: for each Claude Code
# hook event the bridge handles, add a {matcher:"", hooks:[{command:…cmux-bridge.sh,
# async:true}]} entry UNLESS that event already references cmux-bridge. This is the
# step the tester missed when it was a manual "see README" note — the bridge file
# alone does nothing until it's registered. Backs the file up first; creates {} if
# absent. Needs jq; if jq is missing or the file isn't valid JSON we DON'T touch it
# (don't clobber a hand-edited settings) — we point at the README block. New event
# registrations only take effect after Claude Code restarts.
register_hooks() {
  # The literal ~ is intentional: Claude Code stores and expands it at hook-exec time
  # (matches the form in a working settings.json), so don't substitute $HOME here.
  # shellcheck disable=SC2088
  local settings="$HOME/.claude/settings.json" cmd='~/.claude/hooks/cmux-bridge.sh' tmp
  if ! command -v jq >/dev/null 2>&1; then
    echo "  ⚠ jq not found — paste the hooks block from the README into $settings"; return 0
  fi
  [ -f "$settings" ] || echo '{}' >"$settings"
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    echo "  ⚠ $settings isn't valid JSON — paste the hooks block from the README by hand"; return 0
  fi
  bak "$settings"
  tmp="$(mktemp)"
  if jq --arg cmd "$cmd" '
      def ensure($ev):
        (.hooks[$ev] // []) as $cur
        | if ($cur | tostring | contains("cmux-bridge")) then .
          else .hooks[$ev] = ($cur + [{matcher: "", hooks: [{type: "command", command: $cmd, async: true}]}]) end;
      .hooks = (.hooks // {})
      | reduce (["SessionStart","UserPromptSubmit","PreToolUse","PreCompact","PostCompact","Stop","StopFailure","Notification","PostToolUseFailure","SessionEnd"][]) as $ev (.; ensure($ev))
    ' "$settings" >"$tmp" && [ -s "$tmp" ]; then
    mv "$tmp" "$settings"
    echo "  -> wired cmux-bridge into $settings (RESTART Claude Code to load new hook events)"
  else
    rm -f "$tmp"
    echo "  ⚠ couldn't update $settings automatically — paste the hooks block from the README"
  fi
}

echo "Installing opinionated cmux sidebar from $here"

mkdir -p "$HOME/bin" "$cfg/sidebars" "$HOME/.claude/hooks" "$HOME/Library/LaunchAgents"

# 1. pollers + doctor. Both pollers are deployed (the Codex one self-gates and is a
#    no-op until you opt in via USAGE_PROVIDERS — see usage-sentinels.env), so an
#    out-of-the-box install is Claude-only but Codex is one env edit away.
bak "$HOME/bin/cmux-claude-usage.sh"
install -m 0755 "$here/bin/cmux-claude-usage.sh" "$HOME/bin/cmux-claude-usage.sh"
echo "  -> ~/bin/cmux-claude-usage.sh"
bak "$HOME/bin/cmux-codex-usage.sh"
install -m 0755 "$here/bin/cmux-codex-usage.sh" "$HOME/bin/cmux-codex-usage.sh"
echo "  -> ~/bin/cmux-codex-usage.sh  (opt-in: add 'codex' to USAGE_PROVIDERS)"
install -m 0755 "$here/bin/cmux-sentinel-doctor.sh" "$HOME/bin/cmux-sentinel-doctor.sh"
echo "  -> ~/bin/cmux-sentinel-doctor.sh  (run anytime to health-check the setup)"

# 2. sidebar
bak "$cfg/sidebars/workspaces.swift"
install -m 0644 "$here/sidebars/workspaces.swift" "$cfg/sidebars/workspaces.swift"
echo "  -> ~/.config/cmux/sidebars/workspaces.swift"

# 3. sentinel env (only if missing — optional label overrides, no ids)
if [ ! -f "$cfg/usage-sentinels.env" ]; then
  cp "$here/examples/usage-sentinels.env.example" "$cfg/usage-sentinels.env"
  echo "  -> ~/.config/cmux/usage-sentinels.env (optional label overrides)"
else
  echo "  ~/.config/cmux/usage-sentinels.env already exists, leaving it"
fi

# 4. launchd plists, templated to this user. The Claude one is bootstrapped in the
#    NEXT STEPS; the Codex one is deployed dormant (not loaded) so opting in is just
#    a `launchctl bootstrap` once you've set USAGE_PROVIDERS + created cx sentinels.
plist="$HOME/Library/LaunchAgents/com.cmux-claude-usage.plist"
bak "$plist"
sed "s#/Users/YOUR_USERNAME#$HOME#g" "$here/examples/com.cmux-claude-usage.plist" > "$plist"
echo "  -> $plist"
cxplist="$HOME/Library/LaunchAgents/com.cmux-codex-usage.plist"
bak "$cxplist"
sed "s#/Users/YOUR_USERNAME#$HOME#g" "$here/examples/com.cmux-codex-usage.plist" > "$cxplist"
echo "  -> $cxplist  (dormant — bootstrap it only if you enable Codex)"

# 5. working-state hooks bridge. Install when explicitly requested (WITH_BRIDGE=1)
#    OR when one is already present — so a plain re-run still UPDATES an existing
#    bridge instead of silently leaving it stale. (Without this, a bridge user who
#    re-runs the bare installer to update would get a new sidebar + poller but a
#    months-old bridge.) The hooks themselves are registered once in settings.json.
if [ "${WITH_BRIDGE:-0}" = "1" ] || [ -f "$HOME/.claude/hooks/cmux-bridge.sh" ]; then
  bak "$HOME/.claude/hooks/cmux-bridge.sh"
  install -m 0755 "$here/hooks/cmux-bridge.sh" "$HOME/.claude/hooks/cmux-bridge.sh"
  echo "  -> ~/.claude/hooks/cmux-bridge.sh"
  register_hooks   # wire the events into settings.json (idempotent) — was the manual step everyone skipped
fi

cat <<'NEXT'

✅ Files installed. NEXT STEPS (manual — they need your input):

1. Create two throwaway "sentinel" workspaces in cmux (any directory) and name them
   so their TITLES start with the labels — that's the whole wiring (no ids to copy;
   cmux dropped stable workspace UUIDs, so the poller + sidebar match by title):
     cmux workspace list                                    # find the refs
     cmux rename-workspace --workspace workspace:<N> "5h"   # one for 5h, one for 7d
   To use different labels, set SENTINEL_5H_LABEL / SENTINEL_7D_LABEL in
   ~/.config/cmux/usage-sentinels.env and the matching hasPrefix() in the sidebar.

2. Test the poller:
     ~/bin/cmux-claude-usage.sh --print
     ~/bin/cmux-claude-usage.sh --update

3. Load the sidebar:
     cmux sidebar validate workspaces && cmux sidebar reload
   then right-click the sidebar button and pick "workspaces".

4. Enable external socket access for the 5-min auto-refresh — add to ~/.config/cmux/cmux.json:
     "automation": { "socketControlMode": "automation" }
   then run `cmux reload-config` (applies live on current builds). If external socket
   commands still get rejected later, the mode regressed — fully restart cmux.

5. Start the auto-refresh:
     launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.cmux-claude-usage.plist

6. Verify the whole pipeline:
     ~/bin/cmux-sentinel-doctor.sh        # or, from the repo:  make doctor

(Working-state rows — ⚡ working / ⏳ compacting / ❓ waiting-on-you: run
 WITH_BRIDGE=1 ./install.sh  — it installs the bridge AND auto-wires the hooks into
 ~/.claude/settings.json. Then RESTART Claude Code so the new hook events register.)

To UPDATE later: re-run this installer (curl one-liner or `git pull && ./install.sh`), then
`cmux sidebar reload`. An already-installed bridge refreshes automatically — no flag needed.
NEXT
