#!/bin/bash
# install.sh — place the opinionated cmux sidebar files into your config.
# Idempotent and non-destructive: backs up anything it would overwrite.
# Does NOT touch any secrets and does NOT auto-edit your sentinel UUIDs —
# follow the printed "NEXT STEPS" to finish wiring it up.
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

echo "Installing opinionated cmux sidebar from $here"

mkdir -p "$HOME/bin" "$cfg/sidebars" "$HOME/.claude/hooks" "$HOME/Library/LaunchAgents"

# 1. poller + doctor
bak "$HOME/bin/cmux-claude-usage.sh"
install -m 0755 "$here/bin/cmux-claude-usage.sh" "$HOME/bin/cmux-claude-usage.sh"
echo "  -> ~/bin/cmux-claude-usage.sh"
install -m 0755 "$here/bin/cmux-sentinel-doctor.sh" "$HOME/bin/cmux-sentinel-doctor.sh"
echo "  -> ~/bin/cmux-sentinel-doctor.sh  (run anytime to health-check the setup)"

# 2. sidebar
bak "$cfg/sidebars/workspaces.swift"
install -m 0644 "$here/sidebars/workspaces.swift" "$cfg/sidebars/workspaces.swift"
echo "  -> ~/.config/cmux/sidebars/workspaces.swift"

# 3. sentinel env (only if missing — never clobber real UUIDs)
if [ ! -f "$cfg/usage-sentinels.env" ]; then
  cp "$here/examples/usage-sentinels.env.example" "$cfg/usage-sentinels.env"
  echo "  -> ~/.config/cmux/usage-sentinels.env (template — edit in your UUIDs)"
else
  echo "  ~/.config/cmux/usage-sentinels.env already exists, leaving it"
fi

# 4. launchd plist, templated to this user
plist="$HOME/Library/LaunchAgents/com.cmux-claude-usage.plist"
bak "$plist"
sed "s#/Users/YOUR_USERNAME#$HOME#g" "$here/examples/com.cmux-claude-usage.plist" > "$plist"
echo "  -> $plist"

# 5. optional working-state hooks bridge
if [ "${WITH_BRIDGE:-0}" = "1" ]; then
  bak "$HOME/.claude/hooks/cmux-bridge.sh"
  install -m 0755 "$here/hooks/cmux-bridge.sh" "$HOME/.claude/hooks/cmux-bridge.sh"
  echo "  -> ~/.claude/hooks/cmux-bridge.sh  (register events in ~/.claude/settings.json — see README)"
fi

cat <<'NEXT'

✅ Files installed. NEXT STEPS (manual — they need your input):

1. Create two throwaway "sentinel" workspaces in cmux (any directory), then grab their UUIDs:
     cmux workspace list
     cmux sidebar-state --workspace workspace:<N> | grep '^tab='
   Put them in  ~/.config/cmux/usage-sentinels.env  (SENTINEL_5H / SENTINEL_7D)
   AND in       ~/.config/cmux/sidebars/workspaces.swift  ->  isUsageMeter()  (the two == checks)

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

(Optional working-state rows: re-run with  WITH_BRIDGE=1 ./install.sh  and wire the hooks per README.)
NEXT
