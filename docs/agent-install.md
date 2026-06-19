# Agent install guide — cmux-sentinel

This guide is written for an **AI coding agent** (Claude Code, Codex, Cursor, …) to
execute on the user's behalf. It automates the two steps people fumble by hand:
wiring the Claude Code hooks into `~/.claude/settings.json`, and creating the usage
sentinels with titles the poller can find.

If you are a human, you can follow it too — but the one-line installer in the
[README](../README.md) plus these steps is usually faster.

**Agent contract:** every step is idempotent and backs up what it changes. Do the
file edits yourself — never ask the user to hand-edit JSON. Run shell commands
directly. Stop and ask only if a **Preflight** check fails. At the end, run the
doctor and loop until it is clean.

## Preflight (stop and ask the user if any fails)

```bash
command -v cmux >/dev/null && cmux ping >/dev/null 2>&1 && echo "cmux OK"   # cmux installed + app running
command -v jq   >/dev/null && command -v curl >/dev/null && echo "jq/curl OK"
security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1 \
  && echo "Claude creds OK" || echo "Claude not logged in (usage meters will be skipped)"
```

- No `cmux` / `cmux ping` fails → tell the user to install cmux and open the app. Stop.
- No `jq`/`curl` → ask the user to install them (`brew install jq`). Stop.
- No Claude creds → continue, but the usage meters will stay idle until they log in.

## Step 1 — run the installer (files + bridge + hook wiring)

```bash
curl -fsSL https://raw.githubusercontent.com/oliver-kriska/cmux-sentinel/main/install.sh | WITH_BRIDGE=1 bash
```

`WITH_BRIDGE=1` installs the hooks bridge **and auto-wires** the events into
`~/.claude/settings.json` (idempotent, backed up). This is the part that makes
`⚡ working` / `⏳ compacting` / `❓ waiting-on-you` rows work — without it every row
shows "idle." After this, tell the user they must **restart Claude Code** for the new
hook events to register (the script body is read live, but new event registrations
are read at startup).

If the installer reports it could not edit `settings.json` automatically (no jq, or
the file was not valid JSON), wire it yourself — see [Appendix: hooks block](#appendix--hooks-block).

## Step 2 — create the usage sentinels (5h + 7d)

The meters ride two throwaway "sentinel" workspaces whose titles the poller keeps
updated. Check whether they already exist, then create any that are missing:

```bash
cmux workspace list --json | jq -r '.workspaces[].title'   # look for a "5h"/"7d" title
```

For each missing label, create a workspace and name it exactly the label:

```bash
cmux new-workspace --command "zsh"                  # creates one; note its workspace:N ref
cmux workspace list                                 # find the new ref
cmux rename-workspace --workspace workspace:<N> "5h"   # one for 5h, one for 7d
```

Then paint them with live numbers (also confirms the OAuth usage endpoint works):

```bash
~/bin/cmux-claude-usage.sh --print     # parsed values, no cmux writes
~/bin/cmux-claude-usage.sh --update    # renames both sentinels with bars
```

Naming them exactly `5h` / `7d` is fine — the poller resolves a bare label and then
overwrites the title with the bar on the first `--update`.

## Step 3 — enable auto-refresh (external socket access)

The launchd poller renames sentinels from outside the app, which needs automation
mode. Add it to `~/.config/cmux/cmux.json` (create the file if absent) and reload:

```jsonc
{
  "automation": { "socketControlMode": "automation" }
}
```

```bash
cmux reload-config    # applies live on current builds; if renames get rejected later, restart cmux
```

If `cmux.json` already exists, merge the `automation` key in rather than overwriting
the file. It is JSONC (comments allowed), so edit it as text, not with jq.

## Step 4 — start the poller (launchd)

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.cmux-claude-usage.plist
```

## Step 5 — load and select the sidebar

```bash
cmux sidebar validate workspaces && cmux sidebar reload
```

Then tell the user to right-click the sidebar toggle button and pick **workspaces**
(selecting a custom sidebar is a UI action you cannot do for them).

## Step 6 — verify (loop until clean)

```bash
~/bin/cmux-sentinel-doctor.sh
```

Fix any non-green check and re-run until it reports `Everything wired.` or only the
expected warnings (e.g. "claude enabled but not installed here" if the user has not
logged in). Common fixes:

- **bridge NOT registered** → re-run Step 1 with `WITH_BRIDGE=1`, then have the user
  restart Claude Code.
- **no 5h/7d sentinel** → redo Step 2.
- **socketControlMode** warning → redo Step 3.

Report the final doctor output to the user.

## Appendix — hooks block

If the installer could not wire the hooks automatically, merge this into
`~/.claude/settings.json` under `"hooks"` (add each event that is not already there;
do not remove the user's existing hooks). All entries are fire-and-forget
(`async: true`). Then have the user **restart Claude Code**.

```json
{
  "hooks": {
    "SessionStart":       [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }],
    "UserPromptSubmit":   [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }],
    "PreToolUse":         [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }],
    "PreCompact":         [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }],
    "PostCompact":        [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }],
    "Stop":               [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }],
    "StopFailure":        [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }],
    "Notification":       [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }],
    "PostToolUseFailure": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }],
    "SessionEnd":         [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }]
  }
}
```

`Notification` is what flips a session to **❓ waiting-on-you** when it hits a
permission prompt; `UserPromptSubmit`/`PreToolUse` drive **⚡ working**;
`PreCompact`/`PostCompact` drive **⏳ compacting**; `Stop`/`SessionEnd` clear the
marker. The rest are crash/cleanup self-heal.
