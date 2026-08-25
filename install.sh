#!/bin/bash
# install.sh — place the opinionated cmux sidebar files into your config.
# Idempotent and non-destructive: backs up anything it would overwrite. Re-run it
# any time to UPDATE — the curl bootstrap git-pulls the cache, then this re-deploys
# every file (and refreshes an existing bridge automatically; see step 5).
# Does NOT touch any secrets. Sentinels are matched by title label now (no ids
# to edit) — follow the printed "NEXT STEPS" to finish wiring it up.
set -euo pipefail

# Opt-in features. Accept them as flags AND honour the env form (WITH_BRIDGE /
# WITH_ZED / WITH_AMP / RELOAD_AGENTS) — a flag just exports the env so it survives
# the curl-bootstrap re-exec below (which forwards env, not argv). Everything here
# is OFF by default, so a plain install / the bare curl one-liner stays cmux-only,
# Zed-free, and never interrupts a running launchd job.
for arg in "$@"; do
  case "$arg" in
    --with-zed)    export WITH_ZED=1 ;;
    --with-bridge) export WITH_BRIDGE=1 ;;
    --with-amp)    export WITH_AMP=1 ;;
    --reload-agents) export RELOAD_AGENTS=1 ;;
    --no-setup)    export NO_SETUP=1 ;;
    -h|--help)     echo "usage: install.sh [--with-bridge] [--with-zed] [--with-amp] [--reload-agents] [--no-setup]"; exit 0 ;;
    *) echo "install.sh: unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

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
  if [ -d "$cache/.git" ]; then
    # Never silently continue on a failed update — a dirty/diverged/offline cache
    # would reinstall STALE files while the user thinks they updated. Warn loudly
    # (with the recovery command) and proceed from cache so offline redeploys still
    # work; the user can force a clean copy.
    git -C "$cache" pull --ff-only --quiet || {
      echo "  ⚠ couldn't update the cached checkout at $cache" >&2
      echo "    (offline, diverged, or local changes). Installing from the EXISTING" >&2
      echo "    cache — it may be STALE. For a guaranteed-fresh copy:" >&2
      echo "      rm -rf \"$cache\"   then re-run the installer." >&2
    }
  else rm -rf "${cache:?}"; git clone --depth 1 "$REPO_URL" "$cache"; fi
  exec bash "$cache/install.sh"   # WITH_BRIDGE and other env vars survive exec
fi

cfg="$HOME/.config/cmux"
# Back up a file we're about to overwrite. Two guards, both learned the hard way:
# re-running the installer is the DOCUMENTED update path (the curl bootstrap
# git-pulls and re-deploys every file), so an unconditional copy wrote one dead
# file per run — 48 had piled up across the config dirs by 2026-08-10, which
# buries the one backup that actually mattered.
#   1. Skip entirely when the incoming bytes match: nothing would change, so there
#      is nothing to preserve. Callers pass the source as $2; the plist path
#      already does its own cmp and calls the 1-arg form.
#   2. Keep only the newest $BAK_KEEP. Bounded history beats an unbounded pile.
BAK_KEEP="${INSTALL_BAK_KEEP:-3}"
bak() { # $1 = file about to be overwritten   [$2 = incoming source to compare]
  [ -e "$1" ] || return 0
  if [ -n "${2:-}" ] && cmp -s "$1" "$2"; then return 0; fi
  cp "$1" "$1.bak.$(date +%s)" && echo "  backed up $1"
  # Epoch suffixes are fixed-width for any date this century, so a reverse lexical
  # sort is a reverse chronological one. An unmatched glob stays literal, hence -e.
  local f n=0
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    n=$((n + 1))
    [ "$n" -gt "$BAK_KEEP" ] && rm -f "$f"
  done < <(printf '%s\n' "$1".bak.* | sort -r)
  return 0
}

# Render one launchd template only when its contents changed. launchd does not
# reread an already-loaded plist after a file replacement, so silently writing a
# new PATH/program configuration leaves the old process definition active. A
# normal install stays non-disruptive and prints exact reload commands; the
# explicit --reload-agents / RELOAD_AGENTS=1 path reloads only changed+loaded jobs.
print_reload_commands() { # $1=launchd domain $2=plist path
  printf '      launchctl bootout %q %q\n' "$1" "$2"
  printf '      launchctl bootstrap %q %q\n' "$1" "$2"
}

install_plist() { # $1=template $2=destination $3=launchd label $4=description
  local template="$1" dest="$2" job="$3" description="$4" tmp domain loaded=0
  tmp="$(mktemp)"
  sed "s#/Users/YOUR_USERNAME#$HOME#g" "$template" >"$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    echo "  = $dest  ($description; unchanged)"
    return
  fi

  bak "$dest"
  mv "$tmp" "$dest"
  echo "  -> $dest  ($description; updated)"

  domain="gui/$(id -u)"
  if command -v launchctl >/dev/null 2>&1 \
    && launchctl print "$domain/$job" >/dev/null 2>&1; then
    loaded=1
  fi
  [ "$loaded" = 1 ] || return 0

  if [ "${RELOAD_AGENTS:-0}" = 1 ]; then
    echo "     reloading changed launchd job: $job"
    if ! launchctl bootout "$domain" "$dest"; then
      if launchctl print "$domain/$job" >/dev/null 2>&1; then
        echo "  ⚠ couldn't stop $job; its old definition remains loaded. Retry:"
        print_reload_commands "$domain" "$dest"
        return 0
      fi
      # bootout may report failure after launchd has already removed the job.
      # In that case continue to bootstrap rather than leaving it unloaded.
    fi
    if ! launchctl bootstrap "$domain" "$dest"; then
      echo "  ⚠ couldn't restart $job; it may currently be unloaded. Recover with:"
      print_reload_commands "$domain" "$dest"
    fi
  else
    echo "  ⚠ $job is loaded, but launchd has not reread this changed plist. Reload it:"
    print_reload_commands "$domain" "$dest"
    echo "    (or re-run this installer with --reload-agents)"
  fi
}

# Idempotently wire the bridge into ~/.claude/settings.json: for each Claude Code
# hook event the bridge handles, add a {matcher:"", hooks:[{command:…cmux-bridge.sh,
# async:true}]} entry UNLESS that event already references cmux-bridge. This is the
# step the tester missed when it was a manual "see README" note — the bridge file
# alone does nothing until it's registered. Backs the file up first; creates {} if
# absent. Needs jq; if jq is missing or the file isn't valid JSON we DON'T touch it
# (don't clobber a hand-edited settings) — we point at the README block. New event
# registrations only take effect after Claude Code restarts.
# register_hooks <cmd> <marker> <event…> — for each named Claude Code hook event add
# a {matcher:"", hooks:[{command:$cmd, async:true}]} entry UNLESS that event already
# references $marker (idempotent). $cmd carries a literal ~ (Claude expands it at
# hook-exec time); $marker is the substring that means "already wired" (e.g. the
# script basename). Both bridges route through here so the jq stays in one place.
register_hooks() {
  local cmd="$1" marker="$2"; shift 2
  local settings="$HOME/.claude/settings.json" tmp events_json
  if ! command -v jq >/dev/null 2>&1; then
    echo "  ⚠ jq not found — paste the hooks block from the README into $settings"; return 0
  fi
  [ -f "$settings" ] || echo '{}' >"$settings"
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    echo "  ⚠ $settings isn't valid JSON — paste the hooks block from the README by hand"; return 0
  fi
  events_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"  # events → JSON array
  # Render FIRST, then compare. `ensure` is idempotent, so on an already-wired
  # settings.json the old order (back up → jq → mv → announce) rewrote the file
  # byte-identically, dropped a junk backup, and told the user to RESTART Claude
  # Code — every single run. Only touch the file when the render actually differs.
  tmp="$(mktemp)"
  if jq --arg cmd "$cmd" --arg marker "$marker" --argjson events "$events_json" '
      def ensure($ev):
        (.hooks[$ev] // []) as $cur
        | if ($cur | tostring | contains($marker)) then .
          else .hooks[$ev] = ($cur + [{matcher: "", hooks: [{type: "command", command: $cmd, async: true}]}]) end;
      .hooks = (.hooks // {})
      | reduce ($events[]) as $ev (.; ensure($ev))
    ' "$settings" >"$tmp" && [ -s "$tmp" ]; then
    if cmp -s "$tmp" "$settings"; then
      rm -f "$tmp"
      echo "  = $marker already wired into $settings"
      return 0
    fi
    bak "$settings"     # 1-arg: we just proved it differs
    mv "$tmp" "$settings"
    echo "  -> wired $marker into $settings (RESTART Claude Code to load new hook events)"
  else
    rm -f "$tmp"
    echo "  ⚠ couldn't update $settings automatically — paste the hooks block from the README"
  fi
}

echo "Installing opinionated cmux sidebar from $here"

mkdir -p "$HOME/bin" "$cfg/sidebars" "$HOME/.claude/hooks" "$HOME/Library/LaunchAgents"

# 1. pollers + doctor. ALL THREE pollers are deployed (the Codex and Amp ones
#    self-gate and are no-ops until you opt in via USAGE_PROVIDERS — see
#    usage-sentinels.env), so an out-of-the-box install is Claude-only but each
#    other provider is one env edit away.
bak "$HOME/bin/cmux-claude-usage.sh" "$here/bin/cmux-claude-usage.sh"
install -m 0755 "$here/bin/cmux-claude-usage.sh" "$HOME/bin/cmux-claude-usage.sh"
echo "  -> ~/bin/cmux-claude-usage.sh"
bak "$HOME/bin/cmux-codex-usage.sh" "$here/bin/cmux-codex-usage.sh"
install -m 0755 "$here/bin/cmux-codex-usage.sh" "$HOME/bin/cmux-codex-usage.sh"
echo "  -> ~/bin/cmux-codex-usage.sh  (opt-in: add 'codex' to USAGE_PROVIDERS)"
bak "$HOME/bin/cmux-amp-usage.sh" "$here/bin/cmux-amp-usage.sh"
install -m 0755 "$here/bin/cmux-amp-usage.sh" "$HOME/bin/cmux-amp-usage.sh"
echo "  -> ~/bin/cmux-amp-usage.sh  (opt-in: add 'amp' to USAGE_PROVIDERS)"
install -m 0755 "$here/bin/cmux-sentinel-doctor.sh" "$HOME/bin/cmux-sentinel-doctor.sh"
echo "  -> ~/bin/cmux-sentinel-doctor.sh  (run anytime to health-check the setup)"
install -m 0755 "$here/bin/cmux-sentinel-setup.sh" "$HOME/bin/cmux-sentinel-setup.sh"
echo "  -> ~/bin/cmux-sentinel-setup.sh  (creates the meter sentinel workspaces for you)"
# One entry point for everything above. A DISPATCHER, not a replacement: the
# cmux-*.sh scripts stay where they are and keep working when called directly,
# because the LaunchAgents reference them by absolute path and launchd keeps its
# loaded definition until reloaded. Moving them would stop the meters on every
# already-bootstrapped install, silently.
install -m 0755 "$here/bin/cmux-sentinel" "$HOME/bin/cmux-sentinel"
echo "  -> ~/bin/cmux-sentinel  (one entry point: setup / doctor / usage / update)"
install -m 0755 "$here/bin/cmux-group-sync.sh" "$HOME/bin/cmux-group-sync.sh"
echo "  -> ~/bin/cmux-group-sync.sh  (opt-in: show workspace-GROUP names in the sidebar; set GROUP_NAME_SYNC=1)"

# 2. sidebar
bak "$cfg/sidebars/workspaces.swift" "$here/sidebars/workspaces.swift"
install -m 0644 "$here/sidebars/workspaces.swift" "$cfg/sidebars/workspaces.swift"
echo "  -> ~/.config/cmux/sidebars/workspaces.swift"

# 3. sentinel env (only if missing — optional label overrides, no ids)
if [ ! -f "$cfg/usage-sentinels.env" ]; then
  cp "$here/examples/usage-sentinels.env.example" "$cfg/usage-sentinels.env"
  echo "  -> ~/.config/cmux/usage-sentinels.env (optional label overrides)"
else
  echo "  ~/.config/cmux/usage-sentinels.env already exists, leaving it"
fi

# 4. launchd plists, templated to this user. Only changed files are replaced. If a
#    changed job is already loaded, install_plist either reloads it explicitly
#    (--reload-agents) or prints exact commands without disrupting the live job.
#    Provider gating remains in the pollers, so installing a plist never enables it.
plist="$HOME/Library/LaunchAgents/com.cmux-claude-usage.plist"
install_plist "$here/examples/com.cmux-claude-usage.plist" "$plist" \
  "com.cmux-claude-usage" "Claude poller"
cxplist="$HOME/Library/LaunchAgents/com.cmux-codex-usage.plist"
install_plist "$here/examples/com.cmux-codex-usage.plist" "$cxplist" \
  "com.cmux-codex-usage" "Codex poller; dormant unless enabled"
ampplist="$HOME/Library/LaunchAgents/com.cmux-amp-usage.plist"
install_plist "$here/examples/com.cmux-amp-usage.plist" "$ampplist" \
  "com.cmux-amp-usage" "Amp poller; dormant unless enabled"
gsplist="$HOME/Library/LaunchAgents/com.cmux-group-sync.plist"
install_plist "$here/examples/com.cmux-group-sync.plist" "$gsplist" \
  "com.cmux-group-sync" "group sync; dormant unless enabled"

# 5. working-state hooks bridge. Install when explicitly requested (WITH_BRIDGE=1)
#    OR when one is already present — so a plain re-run still UPDATES an existing
#    bridge instead of silently leaving it stale. Register hooks only when explicitly
#    requested or already registered: old Amp-only releases also put their shared
#    dependency here, and a plain update must not silently opt those users into Claude.
if [ "${WITH_BRIDGE:-0}" = "1" ] || [ -f "$HOME/.claude/hooks/cmux-bridge.sh" ]; then
  bak "$HOME/.claude/hooks/cmux-bridge.sh" "$here/hooks/cmux-bridge.sh"
  install -m 0755 "$here/hooks/cmux-bridge.sh" "$HOME/.claude/hooks/cmux-bridge.sh"
  echo "  -> ~/.claude/hooks/cmux-bridge.sh"
  if [ "${WITH_BRIDGE:-0}" = "1" ] || grep -q 'cmux-bridge' "$HOME/.claude/settings.json" 2>/dev/null; then
    # Wire the events into settings.json (idempotent). The literal ~ is intentional
    # (Claude expands it at hook-exec time), so quote it.
    # shellcheck disable=SC2088
    register_hooks '~/.claude/hooks/cmux-bridge.sh' 'cmux-bridge' \
      SessionStart UserPromptSubmit PreToolUse PreCompact PostCompact \
      Stop StopFailure Notification PostToolUseFailure SessionEnd
  else
    echo "  Claude hooks remain disabled (legacy shared bridge found; use --with-bridge to enable them)"
  fi
fi

# 5b. Zed integration (opt-in via --with-zed / WITH_ZED=1). Mirrors the bridge block:
#     also refreshes an already-installed zed-bridge on a plain re-run. Installs the
#     Zed status bridge + the cmux→Zed handoff and usage-TUI helpers, and wires the
#     Zed bridge's 8 events into settings.json. Everything stays INERT until you
#     `export ZED_SENTINEL=1` (the master gate) — see docs/zed-integration.md — so a
#     default install never touches Zed and other users of the repo are unaffected.
if [ "${WITH_ZED:-0}" = "1" ] || [ -f "$HOME/.claude/hooks/zed-bridge.sh" ]; then
  bak "$HOME/.claude/hooks/zed-bridge.sh" "$here/hooks/zed-bridge.sh"
  install -m 0755 "$here/hooks/zed-bridge.sh" "$HOME/.claude/hooks/zed-bridge.sh"
  echo "  -> ~/.claude/hooks/zed-bridge.sh"
  install -m 0755 "$here/bin/cmux-open-in-zed.sh" "$HOME/bin/cmux-open-in-zed.sh"
  echo "  -> ~/bin/cmux-open-in-zed.sh  (ze: open the current worktree in Zed)"
  install -m 0755 "$here/bin/zed-usage-tui.sh" "$HOME/bin/zed-usage-tui.sh"
  echo "  -> ~/bin/zed-usage-tui.sh  (usage meters in a Zed terminal pane)"
  # shellcheck disable=SC2088
  register_hooks '~/.claude/hooks/zed-bridge.sh' 'zed-bridge' \
    SessionStart UserPromptSubmit PreToolUse PreCompact PostCompact \
    Notification Stop SessionEnd
  ZED_INSTALLED=1
fi

# 5c. Amp integration (opt-in via --with-amp / WITH_AMP=1). Mirrors the blocks
#     above: also refreshes an already-installed amp bridge on a plain re-run.
#     Amp has no shell hooks — it has a Bun/TypeScript PLUGIN system — so this is
#     a *.ts file dropped into amp's plugin dir (amp auto-loads every *.ts there;
#     no manifest, no registration step). It is a thin adapter that shells out to
#     cmux-bridge.sh, so it REQUIRES a neutral copy of that shared dependency.
#     Keep it outside ~/.claude/hooks: that path is the explicit signal that
#     Claude integration is enabled, and Amp-only users must not gain Claude
#     hooks on a later plain installer re-run.
#
#     This is NOT a replacement for `cmux hooks amp install` — that one is cmux's
#     own plugin (native tab-status pills + session restore) and lives alongside
#     as a separate file. Install BOTH: cmux's for the native UI, this one for the
#     custom sidebar, which set-status provably cannot reach.
if [ "${WITH_AMP:-0}" = "1" ] || [ -f "$HOME/.config/amp/plugins/cmux-sentinel-amp.ts" ]; then
  mkdir -p "$HOME/.config/amp/plugins" "$HOME/.config/cmux-sentinel"
  bak "$HOME/.config/cmux-sentinel/cmux-bridge.sh" "$here/hooks/cmux-bridge.sh"
  install -m 0755 "$here/hooks/cmux-bridge.sh" "$HOME/.config/cmux-sentinel/cmux-bridge.sh"
  echo "  -> ~/.config/cmux-sentinel/cmux-bridge.sh  (shared dependency for Amp)"
  bak "$HOME/.config/amp/plugins/cmux-sentinel-amp.ts" "$here/hooks/amp-bridge.ts"
  install -m 0644 "$here/hooks/amp-bridge.ts" "$HOME/.config/amp/plugins/cmux-sentinel-amp.ts"
  echo "  -> ~/.config/amp/plugins/cmux-sentinel-amp.ts"
  AMP_INSTALLED=1
fi

# ── version stamp ─────────────────────────────────────────────────────────────
# Record WHAT was installed, so "is the fix in my copy?" is answerable without
# asking the maintainer. The git sha is best-effort: the curl bootstrap installs
# from a clone (so it has one), a tarball install does not.
if [ -f "$here/VERSION" ]; then
  mkdir -p "$HOME/.config/cmux-sentinel"
  _sha="$(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf 'version=%s\ninstalled=%s\ncommit=%s\n' \
    "$(cat "$here/VERSION")" "$(date +%Y-%m-%d)" "$_sha" \
    > "$HOME/.config/cmux-sentinel/VERSION"
  echo "  -> ~/.config/cmux-sentinel/VERSION  (v$(cat "$here/VERSION"), $_sha)"
fi

# ── finish the job ────────────────────────────────────────────────────────────
# Deploying files used to be the whole install, followed by six manual steps. The
# first of those — creating the sentinel workspaces — is idempotent, fail-open and
# needs no input, so leaving it to the user bought nothing and cost everything: an
# UPDATE would print "✅ Files installed" and change nothing visible, because the
# new release's meters had no workspaces to live in. That is what a successful
# install looked like to the first person who updated.
#
# So run it. Everything here is best-effort and NON-FATAL: a machine with no cmux
# running, no socket automation, or no credentials must still finish the install
# with its files in place. Opt out with --no-setup / NO_SETUP=1.
setup_ran=0
if [ "${NO_SETUP:-0}" = 1 ]; then
  echo
  echo "Skipping setup (--no-setup). Run ~/bin/cmux-sentinel-setup.sh when you're ready."
elif ! command -v cmux >/dev/null 2>&1; then
  echo
  echo "cmux isn't on PATH — skipping sentinel setup. Once cmux is installed, run:"
  echo "  ~/bin/cmux-sentinel-setup.sh"
else
  echo
  echo "── Creating/refreshing the meter sentinels ──────────────────────────────"
  # Re-running this on every install is the point: a release can ADD a meter, and
  # creating a workspace shifts cmux's ⌘1…⌘9 numbering until the sentinels are
  # re-parked (cmux drops a new workspace beside your current selection, not at
  # the end). Both are exactly what setup fixes, idempotently.
  if bash "$HOME/bin/cmux-sentinel-setup.sh"; then
    setup_ran=1
  else
    echo "  ⚠ setup didn't complete — your files ARE installed. Re-run it by hand:" >&2
    echo "      ~/bin/cmux-sentinel-setup.sh" >&2
  fi

  if [ "$setup_ran" = 1 ]; then
    echo
    echo "── Painting the meters ──────────────────────────────────────────────────"
    # Only the providers the user actually enabled; each poller self-gates and
    # exits 0 silently when its provider is off or uninstalled, so this is safe to
    # run unconditionally.
    for prov in claude codex amp; do
      [ -x "$HOME/bin/cmux-$prov-usage.sh" ] || continue
      bash "$HOME/bin/cmux-$prov-usage.sh" --update 2>/dev/null || true
    done
    cmux sidebar validate workspaces >/dev/null 2>&1 && cmux sidebar reload >/dev/null 2>&1 \
      && echo "  ✓ sidebar reloaded" \
      || echo "  ⚠ couldn't reload the sidebar — run: cmux sidebar reload"
  fi
fi

cat <<'NEXT'

✅ Installed. What just happened: files deployed, sentinel workspaces created and
   parked out of ⌘1…⌘9, meters painted, sidebar reloaded. Anything below is
   OPTIONAL or needs a decision from you.

   Claude meters: 5h (session) + 7d (week) always; "spend" whenever your account
   has an extra-usage budget (it stays HIDDEN until you actually spend, so it
   costs you nothing to carry); "m7d" for a per-model weekly cap only if you opt
   in with CLAUDE_MODEL_METER=1 in ~/.config/cmux/usage-sentinels.env — setup
   tells you when you have such a cap. `~/bin/cmux-claude-usage.sh --print` lists
   whatever your account actually has, metered or not.

1. Enable external socket access for the 5-min auto-refresh — add to ~/.config/cmux/cmux.json:
     "automation": { "socketControlMode": "automation" }
   then run `cmux reload-config` (applies live on current builds). If external socket
   commands still get rejected later, the mode regressed — fully restart cmux.

2. Start auto-refresh for every provider you enabled (skip the others). If the
   installer says a loaded plist changed, run its printed bootout + bootstrap
   commands, or re-run `./install.sh --reload-agents` to reload changed jobs only:
     launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.cmux-claude-usage.plist
     launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.cmux-codex-usage.plist
     launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.cmux-amp-usage.plist

3. Verify the whole pipeline:
     ~/bin/cmux-sentinel-doctor.sh        # or, from the repo:  make doctor

(Working-state rows — ⚡ working / ⏳ compacting / ❓ waiting-on-you: run
 WITH_BRIDGE=1 ./install.sh  — it installs the bridge AND auto-wires the hooks into
 ~/.claude/settings.json. Then RESTART Claude Code so the new hook events register.)

(Use Zed as your editor/git UI alongside cmux? Run  ./install.sh --with-zed  to add
 the opt-in Zed integration — a cmux→Zed worktree handoff, agent-state markers, and a
 usage-meter pane. It stays inert until you export ZED_SENTINEL=1. See docs/zed-integration.md.)

(Workspace-GROUP names — if you use cmux workspace groups, the sidebar shows the
 anchor's generic "Group 2" instead of the group's name (cmux gives custom sidebars
 no group data). To fix: set GROUP_NAME_SYNC=1 in ~/.config/cmux/usage-sentinels.env,
 try it with `~/bin/cmux-group-sync.sh --list`, then start it:
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.cmux-group-sync.plist )

To UPDATE later: just re-run this installer (curl one-liner or `git pull && ./install.sh`).
It re-deploys every file, re-runs setup so a release that ADDS a meter gets its
workspace, re-parks the sentinels out of ⌘1…⌘9, repaints and reloads the sidebar.
An already-installed bridge refreshes automatically — no flag needed. Pass
--no-setup if you want files only.
NEXT

# Extra steps only when the Zed integration was just installed. Kept OUT of the main
# heredoc so a default install never mentions Zed. Unquoted heredoc so $HOME expands
# to the real path; the command-sub and backticks are escaped to print literally.
if [ "${ZED_INSTALLED:-0}" = "1" ]; then
  cat <<ZED

🧩 Zed integration installed (opt-in — inert until you arm it). To turn it ON for
   yourself only (other repo users are unaffected), add to your ~/.zshrc:

     export ZED_SENTINEL=1
     eval "\$($HOME/bin/cmux-open-in-zed.sh --shell-init)"

   Then: (a) RESTART Claude Code so the zed-bridge hook events load; (b) open a new
   shell. Now \`ze\` (or Ctrl-O) opens Zed on the current git worktree, and agent
   state (⚡ working / ⏳ compacting / ❓ waiting-on-you) reaches OSC-2 terminal
   metadata + \$ZED_SENTINEL_STATE_DIR JSON. Stock Zed's tab label stays
   process-derived; the JSON is ready for panel/status consumers. Without
   ZED_SENTINEL=1 the bridge is a no-op.
   Optional: run ~/bin/zed-usage-tui.sh in a Zed terminal pane for the usage meters.
   Full guide + all the toggles: docs/zed-integration.md
ZED
fi

# Extra steps only when the Amp bridge was just installed. Same pattern as Zed:
# kept out of the main heredoc so a default install never mentions Amp.
if [ "${AMP_INSTALLED:-0}" = "1" ]; then
  cat <<AMP

🔌 Amp bridge installed → ~/.config/amp/plugins/cmux-sentinel-amp.ts
   Restart Amp so it picks up the plugin; verify the file is discovered with
   \`amp plugins list\`. Amp workspaces now show ⚡ working / idle in the sentinel
   sidebar. Two things it deliberately does NOT do: ⏳ compacting (Amp emits no
   such event) and ❓ waiting-on-you (Amp doesn't ask permission by default — opt
   in with CMUX_SENTINEL_AMP_ASK=1, which makes Amp start prompting).

   ALSO run  cmux hooks amp install  if you haven't. That is cmux's own separate
   plugin for the NATIVE sidebar's status pills, notifications and session
   restore; this one is for the custom sidebar, which those pills cannot reach.
   They coexist as two files — never edit cmux's cmux-session.ts, it self-upgrades.
AMP
fi
