# Zed integration — OFF by default, opt-in per user

This repo's Zed pieces (cmux→Zed handoff, agent-state bridge, usage TUI) are **disabled by default**
so anyone who clones cmux-sentinel and runs `install.sh` gets **zero** Zed behavior. Enable them for
**yourself only** — nothing here is wired into `install.sh` or the shared `sidebars/workspaces.swift`,
and you should keep it that way (don't make it the default for other users of the repo).

## What's opt-in

| Piece | How it activates | Off-by-default guarantee |
| --- | --- | --- |
| `hooks/zed-bridge.sh` | Runs only if YOU register it as a Claude Code hook | Also gated on `ZED_SENTINEL=1` — silent no-op unless set, even if hooked |
| `bin/cmux-open-in-zed.sh` (`ze`) | Runs only when you invoke it (alias/keybind) | Invoke-only; never fires on its own |
| `bin/zed-usage-tui.sh` | Runs only when you launch it in a terminal pane | Invoke-only |

`install.sh` wires `hooks/cmux-bridge.sh` (the cmux bridge) only — never the Zed bridge.

## Enable it for yourself

1. **Master switch** — in your `~/.zshrc` (so Claude Code, launched from your shell, inherits it):

   ```sh
   export ZED_SENTINEL=1
   ```

   Without this, `zed-bridge.sh` exits immediately as a no-op.

2. **cmux→Zed handoff** — add the `ze` alias + a `Ctrl-O` keybind that opens Zed on the current
   worktree straight from the shell prompt:

   ```sh
   eval "$(/path/to/cmux-sentinel/bin/cmux-open-in-zed.sh --shell-init)"
   ```

   (Change the key with `--key '^E'`. The keybind fires only at the shell prompt — never mid-agent.)

3. **Agent-state markers in Zed** (optional) — register `hooks/zed-bridge.sh` for the Claude Code
   events in your **personal** `~/.claude/settings.json` (UserPromptSubmit, PreToolUse, PreCompact,
   PostCompact, Notification, Stop, SessionEnd). With `ZED_SENTINEL=1` it writes ⚡/⏳/❓ to the
   terminal's OSC title and a per-session JSON status file (`ZED_SENTINEL_STATE_DIR`).

4. **Usage meters while in Zed** (optional) — run `bin/zed-usage-tui.sh` in a dedicated Zed terminal
   pane.

## Disable

Unset `ZED_SENTINEL` (or set it to `0`), remove the `eval` line and the `~/.claude` hook entries.
Nothing in the committed repo changes.

## Do NOT make it default for the repo

Keep the Zed pieces out of `install.sh`'s default path and out of the shared sidebar. If a
one-command personal enable is ever added, gate it behind an explicit flag (e.g. `install.sh --with-zed`
or `ZED_SENTINEL=1`), never on by default. See `docs/zed-fork-research.md` for the full background.
