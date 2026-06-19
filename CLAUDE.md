# CLAUDE.md — guidance for AI assistants working on cmux-sentinel

cmux-sentinel is an opinionated [cmux](https://cmux.com) **custom sidebar** (a runtime-interpreted
SwiftUI-style file) plus background pollers that show workspace/agent states and **AI usage
meters**. Read this before editing — it encodes traps that cost real hours and that you cannot
discover from the code alone, because the failure mode is a **silently blank sidebar**.

## ⚠️ The sidebar interpreter is a SUBSET of SwiftUI — these WILL bite you

`cmux sidebar validate` only **parses**. It passes on files that render **completely blank** at
runtime, and the interpreter swallows the error (no log). So an edit that "validates" can still
break everything. Confirmed traps:

- **String ops `.hasPrefix` / `.contains` / `.hasSuffix` / `.split` DO work** on the current build
  (proven by probe: `hasPrefix=Y contains=Y hasSuffix=Y`; the live sidebar detects the working/
  compacting title markers via `.hasPrefix` and strips them with `.split`). An earlier note here
  claimed they render blank — that was WRONG on this build. `==` works too; use whichever is clearest.
- **Avoid `||`** (unproven). Use an `if`-chain returning early. `&&` is fine and short-circuits.
- **`progress` / `description` / `color` never reach the sidebar data** — not even for the SELECTED,
  canonically-working workspace (proven by in-sidebar probe: `progN=0 descN=0`). They show in
  `cmux sidebar-state` but stay `nil` in the sidebar's `workspaces[]`. So the **title** is the only
  writable channel: usage meters AND agent working/compacting state all ride it (set via
  `cmux rename-workspace`), never `set-progress`.
- **`cmux sidebar-state` DIVERGES from what the sidebar sees** (it reads the canonical store). Never
  use it to predict the sidebar — verify with an in-sidebar `Text(...)` probe.
- **cmux 0.64.15 REMOVED stable workspace UUIDs.** `cmux workspace list --json` now returns
  `id: null`; the only handle is a positional `ref` (`workspace:N`) that **rotates across app
  restarts and reorders**. The old scheme stored sentinel UUIDs in the env file and the sidebar —
  that broke on the first restart (silent "offline" meters in the normal list). Both sides now anchor
  on the **title label** instead: the poller `resolve_ref()`s each sentinel by the workspace whose
  title starts with the `5h`/`7d` label (plus a space) and renames by the live ref; the sidebar's
  `isClaudeMeter()` matches the same prefix. This is restart-proof because it re-resolves every run —
  the same reason the bridge
  reads a LIVE `$CMUX_WORKSPACE_ID` (still a UUID, set per-shell) instead of storing one. Don't
  reintroduce a stored id. The committed and deployed sidebars are now byte-identical (no id
  substitution at install).
- **No native value bar for meters.** `ProgressView(value:)` needs a numeric `progress`, which idle
  sentinels don't have — so meters are Unicode block text bars (`▏▎▍▌▋▊▉█`). Utilization **color**
  can't come from data either; it's a colored emoji in the title (🟡/🔴).
- **Greedy modifiers that wreck row height:** `Divider().background("#hex")`,
  `.frame(maxHeight: .infinity)`, `.overlay { Rectangle().frame(height:1) }`. Use plain `Divider()` +
  a single `.padding(n)`. `.contentShape(Rectangle())` is a no-op. Custom fonts aren't honored —
  use `.system(size:, design: .monospaced)`.

**When the sidebar goes blank, DON'T guess.** Replace the whole file with a one-line
`Text("HELLO")`, confirm it renders, then add helpers/views back one at a time (`cmux sidebar
reload` after each) until it blanks. That isolates the bad construct in ~3 steps.

## Testing loop

```bash
# sidebar
cp sidebars/workspaces.swift ~/.config/cmux/sidebars/workspaces.swift
cmux sidebar validate workspaces && cmux sidebar reload   # validate only PARSES — also eyeball it

# poller (no cmux writes)
./bin/cmux-claude-usage.sh --print     # parsed values
./bin/cmux-claude-usage.sh --raw       # raw API JSON (no token)
./bin/cmux-claude-usage.sh --update    # actually renames the sentinels
```

## Architecture / where things live

```text
sidebars/workspaces.swift  the sidebar. isClaudeMeter() = title-label `.hasPrefix` per provider; isUsageMeter() = any.
bin/cmux-claude-usage.sh    Claude usage poller. make_bar / sev_dot / mark_offline / bucket_field.
hooks/cmux-bridge.sh        Claude Code → cmux agent-state bridge (⚡ working / ⏳ compacting / ❓ waiting-on-you rows).
examples/                   usage-sentinels.env + launchd plist templates.
```

- **Agent state rides STATIC title markers** the bridge keeps at the FRONT of the title — `⚡` =
  working, `⏳` = compacting, `❓` = waiting-on-you (the session asked a question via
  `AskUserQuestion`/`ExitPlanMode`, or hit a MID-TURN permission `Notification` — it's alive but
  parked, so it shows the orange needs-you treatment, NOT green "Working…"). The idle "waiting for
  input" Notification that fires ~60s after a turn ENDS is gated out (`_notify_waiting` checks for a
  live pid) so a finished workspace never flips to ❓. Precedence: compacting
  > waiting > working > needs-you(unread) > idle. The sidebar
  detects them with `.hasPrefix` and strips them for display. STATIC is mandatory: an animated /
  frame-by-frame marker in the title floods cmux's title coalescer and freezes the sidebar
  (upstream cmux #6291). The bridge ref-counts live sessions per workspace as files under
  `$TMPDIR/cmux-sentinel-work/<ws>/` and reaps dead PIDs (`kill -0`), so multiple agents and crashes
  are handled; a `.marked` flag (30s TTL) keeps the per-tool-call hot path off the ~44ms title read.
  Test the state machine offline with the stubbed-cmux harness (see `.claude/` working docs).

- **Usage meters group by provider:** each provider gets its own labelled panel section
  (`CLAUDE USAGE`, `CODEX USAGE`, …) — same component reused. A meter is just an idle "sentinel"
  workspace whose title a poller keeps updated. To add a provider: create a sentinel, add an
  `isCodexMeter()` predicate + an `if isCodexMeter(w)` line to `isUsageMeter()` + a `CODEX USAGE`
  panel section, and copy the poller with a new data source. (Whether Codex exposes a usable usage
  endpoint is an open research question.)
- **Auto-refresh** needs `"automation": { "socketControlMode": "automation" }` in `cmux.json`. On the
  current build `reload-config` applies this **live** (proven: an external launchd kick landed its
  renames with no restart) — the earlier "needs a full cmux restart" note was outdated. If external
  (launchd) socket commands start getting rejected, the automation mode regressed → restart cmux.

## Conventions & security

- **Never commit secrets.** The OAuth token is read from the macOS Keychain at runtime — keep it
  that way. No tokens, no real workspace UUIDs, no usernames in committed files. (The sidebar carries
  no ids at all now — it matches sentinels by title label — so there's nothing to placeholder.)
- Dependency-light: bash + `jq` + `curl` + macOS `date`. Terse comments about *why*.
- **Run `make check` before proposing a commit** — shellcheck + the secret guard
  (`scripts/check-secrets.sh`) + markdownlint + sidebar parse. `lefthook install` wires the same
  gates into git hooks; CI runs `make ci`. The secret guard is the load-bearing one (blocks real
  UUIDs / tokens / `/Users/<name>` paths and asserts the sidebar keeps its title-label meter anchors).
- See `CONTRIBUTING.md` for the dev loop and PR norms. (Maintainers may keep gitignored working
  docs under `.claude/` — e.g. `.claude/NOTES.local.md` with the full debugging history and
  `.claude/HANDOFF.md` for resuming a session — never committed.)
