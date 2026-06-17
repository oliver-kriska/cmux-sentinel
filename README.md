# cmux-sentinel

An opinionated [cmux](https://cmux.com) **custom sidebar** — a clean, monospace, Ayu-Mirage
workspaces list with live agent states and pluggable **AI usage meters**.

<p align="center">
  <img src="assets/sidebar.png" alt="cmux-sentinel sidebar — USAGE panel above the workspace list" width="320">
</p>

The top **USAGE** panel shows live Claude limits (5h session + 7d weekly) with smooth sub-cell
bars — a 🟡/🔴 dot appears only when a limit gets close — and workspace rows light up by agent
state: **purple** (compacting) / **green** (working) / **orange** (needs you) / dim (idle).

It's a vibe-coded [custom sidebar](https://cmux.com/docs/custom-sidebars) (beta) plus small
background pollers. Batteries included, easy to fork and tweak.

## Features

- **Flat workspace list** in your manual order, SF Mono, Ayu-Mirage palette.
- **Live agent row states** (via a Claude Code hooks bridge): `compacting` (purple), `working`
  (green), `needs you` (orange, unread), `idle` (dim) — shown by row colour with a two-line
  subtitle that keeps agent activity separate from repo state (branch · dirty · PR). The header
  shows live per-state counts.
- **Inline actions**: click to select, `×` to close, unread badges.
- **Usage meters** — a top panel of live progress bars fed by background pollers. Ships with a
  **Claude Code** provider (rolling 5-hour session + 7-day weekly), with a smooth sub-cell
  Unicode bar, a `🟡`/`🔴` dot only when a limit gets close, and an `⚠ offline` marker when data
  goes stale. The numbers match Claude Desktop's *Plan usage limits* pane.

**Roadmap / help wanted:** more usage-meter providers — **Codex**, and whatever else exposes a
usage signal. The meter mechanism is provider-agnostic (see "Usage meters" below), so adding one
is mostly a small poller script.

---

## How it works

cmux custom sidebars are runtime-interpreted SwiftUI-style files. The sidebar can only read a
fixed set of per-workspace fields — it **cannot** fetch URLs or read arbitrary data. Two
mechanisms feed it:

1. **Agent row states** — Claude Code hooks → `hooks/cmux-bridge.sh` → a STATIC marker on the
   *active* workspace's **title** (`⚡` working, `⏳` compacting), reference-counted so multiple
   agents in one workspace don't stomp it and dead sessions can't strand it. The sidebar detects
   the marker, colours the row, and strips the glyph for display. (Why the title and not
   `set-progress`: progress doesn't reach custom-sidebar data on this build — see gotchas — and
   the marker must be *static*, since an animated one freezes cmux's sidebar.)
2. **Usage meters** — a poller (run by launchd every few minutes) computes each metric and writes
   it into a dedicated idle **"sentinel" workspace** by **renaming its title** (the same title
   channel). The sidebar matches sentinels by id and renders their titles in the top `USAGE`
   panel, hidden from the list.

```text
launchd ──► bin/cmux-claude-usage.sh --update
              ├─ read OAuth token ← macOS Keychain ("Claude Code-credentials")
              ├─ GET api.anthropic.com/api/oauth/usage   (5h + 7d utilization + reset times)
              └─ cmux rename-workspace <sentinel> "5h ██▍░░░░░░░ 24% 2d18h" ─► sidebar reads w.title
```

---

## Install

```bash
git clone https://github.com/oliver-kriska/cmux-sentinel.git
cd cmux-sentinel
./install.sh                 # add WITH_BRIDGE=1 to also install the working-state hooks
```

`install.sh` copies the files into place (backing up anything it overwrites) and prints the
remaining manual steps. In short:

1. **Create two sentinel workspaces** in cmux (any dir) and grab their UUIDs
   (`cmux sidebar-state --workspace workspace:<N> | grep '^tab='`); put them in
   `~/.config/cmux/usage-sentinels.env` **and** in `sidebars/workspaces.swift` → `isUsageMeter()`.
2. **Test the poller:** `~/bin/cmux-claude-usage.sh --print` then `--update`.
3. **Load the sidebar:** `cmux sidebar validate workspaces && cmux sidebar reload`, then
   right-click the sidebar button and pick *workspaces*.
4. **Enable external socket access** for auto-refresh — add
   `"automation": { "socketControlMode": "automation" }` to `~/.config/cmux/cmux.json`, then run
   `cmux reload-config` (applies live on current builds; if renames still get rejected, restart cmux).
5. **Start auto-refresh:**
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.cmux-claude-usage.plist`.
6. **Verify the pipeline:** `make doctor` (or `~/bin/cmux-sentinel-doctor.sh`) — a read-only check
   that the bridge, hooks, launchd job, automation mode, and sentinels are all wired.

**Prereqs:** macOS, cmux (custom sidebars / beta), Claude Code logged in, `jq`, `curl`.

---

## Usage meters (providers)

Each provider gets its **own labelled section** in the panel — `CLAUDE USAGE` now, `CODEX USAGE`
later — the same component reused. A meter is just an idle "sentinel" workspace whose **title** a
poller keeps updated. To **add a provider** (e.g. Codex):

1. Create a sentinel workspace and grab its UUID. In `sidebars/workspaces.swift`: add an
   `isCodexMeter(w)` predicate (copy `isClaudeMeter`), add `if isCodexMeter(w) { return true }` to
   `isUsageMeter`, and uncomment/duplicate the `CODEX USAGE` section in the panel.
2. Write a small poller (copy `bin/cmux-claude-usage.sh`) that fetches the provider's usage and
   does `cmux rename-workspace --workspace <uuid> "<label> <bar> <pct>% <reset>"`.
3. Schedule it (launchd) like the Claude one.

PRs adding providers are very welcome.

### Claude provider — data source

```http
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <oauth_access_token>
anthropic-beta: oauth-2025-04-20
```

Unofficial / beta (the same endpoint `ccusage statusline` uses; header may change). Buckets
`five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, … each `{ utilization: 0-100,
resets_at }`. Use `seven_day.resets_at` for the weekly reset — Anthropic's 7-day window **rolls**,
so local calendar-week math (`ccusage weekly`) is wrong. Token is read fresh from the macOS
Keychain each run; never stored or printed.

---

## Interpreter gotchas

The cmux sidebar runs a **subset** of SwiftUI. Hard-won facts (respect these in PRs):

- **`set-progress` / `description` / `color` do NOT reach custom-sidebar data at all** — not even
  for the selected, working workspace (proven by probe). **`title` is the only writable channel**, so
  usage bars AND the agent working/compacting markers all ride the title string. (`cmux sidebar-state`
  shows the canonical store and diverges from what the sidebar actually sees — don't trust it to
  predict the sidebar.)
- **String `.hasPrefix` / `.contains` / `.split` DO work** here — the marker detection relies on
  them. (An older note claimed they blank-render; that was disproven on the current build.) `==`
  works too. Avoid `||`; use an `if`-chain returning early.
- **No value-accurate native bar** (`ProgressView`/`Capsule`) for meters — a drawn bar needs the %
  as a number, but you only have it as a string in the title and the interpreter can't reliably
  parse it back. Hence Unicode block text bars. Likewise utilization **color** can only come from a
  colored emoji in the title.
- `Divider().background(...)` and `.frame(maxHeight: .infinity)` are **greedy** and wreck row
  height. `.contentShape(Rectangle())` is a no-op. Custom fonts aren't honored — use
  `.system(size:, design: .monospaced)`.
- `cmux sidebar validate` only **parses**; it passes on layouts that render blank. Bisect runtime
  errors by stripping the body to `Text("hi")` and adding back piece by piece.

## Layout

```text
bin/cmux-claude-usage.sh     Claude usage poller (--print | --raw | --update)
bin/cmux-sentinel-doctor.sh  read-only health-check of the whole pipeline
sidebars/workspaces.swift    the sidebar (the opinionated design + USAGE panel)
hooks/cmux-bridge.sh         Claude Code → cmux agent-state bridge (⚡ working / ⏳ compacting)
tests/bridge-state.sh        offline bridge state-machine test (stubs cmux; `make test`)
examples/                    usage-sentinels.env + launchd plist templates
install.sh                   file placement + next-steps
```

## Security

The OAuth token is read fresh from the macOS Keychain on every poll and sent only to
`api.anthropic.com` — never written to disk, logged, or printed. Nothing in this repo contains a
token; sentinel UUIDs are placeholders you fill in locally.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). New meter providers, theme variants, and gotcha additions
are all welcome. MIT licensed.
