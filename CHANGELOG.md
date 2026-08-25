# Changelog

Re-run the installer to update; it re-deploys every file, re-runs setup so a release that adds a
meter gets its workspace, re-parks the sentinels out of ⌘1…⌘9, repaints and reloads the sidebar.

```bash
curl -fsSL https://raw.githubusercontent.com/oliver-kriska/cmux-sentinel/main/install.sh | bash
```

`~/bin/cmux-sentinel-doctor.sh` reports the version you actually have.

## 0.2.0 — 2026-08-25

### Added

- **Per-model weekly meter (`m7d`, opt-in).** Anthropic publishes a model-scoped weekly cap
  ("Fable" today) next to the account-wide windows. Enable with `CLAUDE_MODEL_METER=1` and re-run
  setup. The model's name comes from the payload and is drawn as the row's label, so it follows
  Anthropic if they re-scope the cap. `cmux-claude-usage.sh --print` shows the row whether or not
  it is metered.
- **Extra-usage spend meter (`spend`).** Meters money against your overage budget. The row is
  hidden while the balance is zero and appears by itself on the first charge, so it costs nothing
  to carry and needs no opt-in switch. Skipped entirely if your account has no such budget.
- **One command: `cmux-sentinel`.** A single entry point at `~/bin/cmux-sentinel` —
  `setup`, `doctor`, `version`, `usage`, `paint`, `update`, `group-sync`, `zed` — instead of nine
  script names. It dispatches to the existing `cmux-*.sh` scripts, which stay exactly where they
  are and keep working when called directly (the LaunchAgents reference them by absolute path).
- **`cmux-sentinel version` and a version stamp.** The installer records the version, install date
  and commit under `~/.config/cmux-sentinel/VERSION`; the doctor header prints it and tells you
  when a newer release is published (`CMUX_SENTINEL_UPDATE_CHECK=0` turns the check off).
- **Alert when an agent needs you.** Set `CMUX_SENTINEL_NOTIFY_CMD` to run a command on the ❓
  transition — the one state worth interrupting you for. Nothing else is notifiable by design.

### Fixed

- **A closed sentinel no longer freezes the other meters.** The pollers used to write sentinels in
  sequence and abort on the first failure, so one closed workspace could leave every meter after it
  stale for days. They now paint every sentinel they can resolve and report the rest at the end.
- **Usage-fetch failures say what to do.** 401/403 shows `⚠ auth`, 429 shows `⚠ rate limit`, 5xx
  shows `⚠ api down`, and the launchd log gets the matching recovery. The doctor surfaces the
  newest error under a stale provider.
- **The tool no longer rate-limits itself.** `--print` followed by `--update` was two API calls
  seconds apart on top of the 5-minute poll — the burst that triggered 429s. Successful responses
  are cached for 60s (`CMUX_SENTINEL_USAGE_CACHE_TTL`); failures are never cached.
- **Installing now finishes the job.** The installer runs setup, paints the meters and reloads the
  sidebar instead of printing six manual steps. An update that adds a meter now shows it. Pass
  `--no-setup` for files only.
- **An opt-in meter you could be using announces itself.** Setup and the doctor name the switch
  when your account has a per-model cap, instead of skipping in silence.
- **Stale work markers are reaped.** A `⚡` whose session ended without a `Stop` used to persist
  indefinitely; markers now expire after `CMUX_SENTINEL_WORK_TTL` (default 1h).
- Installer backups are content-aware and bounded instead of one dead file per run.

## 0.1.0 — 2026-08-24

First tagged release: the sidebar, the Claude/Codex/Amp usage meters, the agent-state bridge, the
setup and doctor scripts, and the opt-in Zed integration.
