# CLAUDE.md — guidance for AI assistants working on cmux-sentinel

cmux-sentinel is an opinionated [cmux](https://cmux.com) **custom sidebar** (a runtime-interpreted
SwiftUI-style file) plus background pollers that show workspace/agent states and **AI usage
meters**. Read this before editing — it encodes traps that cost real hours and that you cannot
discover from the code alone, because the failure mode is a **silently blank sidebar**.

## ⚠️ The sidebar interpreter is a SUBSET of SwiftUI — these WILL bite you

`cmux sidebar validate` only **parses**. It passes on files that render **completely blank** at
runtime, and the interpreter swallows the error (no log). So an edit that "validates" can still
break everything. Confirmed traps:

- **No working String `.contains` / `.hasPrefix`.** They render blank when actually executed. The
  existing `isCompacting` uses `.contains("Compact")` and only "works" because a workspace is
  almost never mid-compact, so that line never runs. **Match by exact id with `==`** instead
  (proven: row code uses `w.pr.status == "open"`).
- **Avoid `||`** (unproven). Use an `if`-chain returning early. `&&` is fine and short-circuits.
- **For IDLE workspaces, only `title` reaches the sidebar data.** `progress` and `color` are
  populated only for the ACTIVE/agent workspace — both show up in `cmux sidebar-state` but stay
  `nil` in the sidebar's `workspaces[]` for idle ones. This is THE reason usage meters ride the
  workspace **title** (set via `cmux rename-workspace`), not `set-progress`.
- **`cmux sidebar-state` DIVERGES from what the sidebar sees** (it reads the canonical store). Never
  use it to predict the sidebar — verify with an in-sidebar `Text(...)` probe.
- **No native value bar for meters.** `ProgressView(value:)` needs a numeric `progress`, which idle
  sentinels don't have — so meters are Unicode block text bars (`▏▎▍▌▋▊▉█`). Utilization **color**
  can't come from data either; it's a colored emoji in the title (🟡/🔴).
- **Greedy modifiers that wreck row height:** `Divider().background("#hex")`,
  `.frame(maxHeight: .infinity)`, `.overlay { Rectangle().frame(height:1) }`. Use plain `Divider()`
  + a single `.padding(n)`. `.contentShape(Rectangle())` is a no-op. Custom fonts aren't honored —
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

```
sidebars/workspaces.swift  the sidebar. isUsageMeter() = the `==` id list for meter sentinels.
bin/cmux-claude-usage.sh    Claude usage poller. make_bar / sev_dot / mark_offline / bucket_field.
hooks/cmux-bridge.sh        Claude Code → cmux working-state bridge (green "working" rows).
examples/                   usage-sentinels.env + launchd plist templates.
```

- **Usage meters are provider-agnostic:** a meter is just an idle "sentinel" workspace whose title
  a poller keeps updated. To add a provider (e.g. Codex): create a sentinel, add its id to
  `isUsageMeter()`, copy the poller with a new data source. (Whether Codex exposes a usable usage
  endpoint is an open research question.)
- **Auto-refresh** needs `"automation": { "socketControlMode": "automation" }` in `cmux.json` AND a
  **full cmux restart** (`reload-config` does NOT apply socket security — read only at startup).
  Otherwise external (launchd) socket commands are rejected.

## Conventions & security

- **Never commit secrets.** The OAuth token is read from the macOS Keychain at runtime — keep it
  that way. No tokens, no real workspace UUIDs (use `REPLACE_WITH_*` placeholders), no usernames in
  committed files.
- Dependency-light: bash + `jq` + `curl` + macOS `date`. Terse comments about *why*.
- See `CONTRIBUTING.md` for the dev loop and PR norms. (Maintainers may keep a gitignored
  `NOTES.local.md` with the full debugging history and decisions.)
