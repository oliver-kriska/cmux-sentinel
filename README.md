# cmux-sentinel

An opinionated [cmux](https://cmux.com) **custom sidebar** — a clean, monospace, Ayu-Mirage
workspaces list with live agent states and pluggable **AI usage meters**.

```
Workspaces                          ⚡2  15:45
─────────────────────────────────────────────
USAGE
🟡 5h ███████░░░ 72% 41m
   7d ██▍░░░░░░░ 24% 2d18h
─────────────────────────────────────────────
▎ enaia            working · running tests
  enaia-main       idle
  Gettext          needs you · 2m
  ...
```

It's a vibe-coded [custom sidebar](https://cmux.com/docs/custom-sidebars) (beta) plus small
background pollers. Batteries included, easy to fork and tweak.

## Features

- **Flat workspace list** in your manual order, SF Mono, Ayu-Mirage palette.
- **Live agent row states** (via a Claude Code hooks bridge): `working` (green), `needs you`
  (orange, unread), `idle` (dim) — with a bolt/bell glyph and contextual subtitle (PR, branch,
  dirty, "needs you · 2m").
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

1. **Agent row states** — Claude Code hooks → `hooks/cmux-bridge.sh` → `cmux set-progress` /
   `clear-progress` on the *active* workspace. The sidebar reads that as the working signal.
2. **Usage meters** — a poller (run by launchd every few minutes) computes each metric and writes
   it into a dedicated idle **"sentinel" workspace** by **renaming its title** (the title is the
   one channel that propagates to idle workspaces — `set-progress` does not; see gotchas). The
   sidebar matches sentinels by id and renders their titles in the top `USAGE` panel, hidden from
   the list.

```
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
   `"automation": { "socketControlMode": "automation" }` to `~/.config/cmux/cmux.json`, then
   **fully restart cmux** (`reload-config` does not apply it).
5. **Start auto-refresh:**
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.cmux-claude-usage.plist`.

**Prereqs:** macOS, cmux (custom sidebars / beta), Claude Code logged in, `jq`, `curl`.

---

## Usage meters (providers)

The meter panel is provider-agnostic: each metric is just a sentinel workspace whose **title** a
poller keeps updated, and the sidebar renders every title where `isUsageMeter(w)` is true. To
**add a provider** (e.g. Codex):

1. Create a sentinel workspace, add its UUID to `isUsageMeter()` in `sidebars/workspaces.swift`.
2. Write a small poller (copy `bin/cmux-claude-usage.sh`) that fetches the provider's usage and
   does `cmux rename-workspace --workspace <uuid> "<label> <bar> <pct>% <reset>"`.
3. Schedule it (launchd) like the Claude one.

PRs adding providers are very welcome.

### Claude provider — data source

```
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

- **`set-progress` / workspace `color` do NOT propagate to the sidebar for IDLE workspaces** — only
  for the active/agent workspace. For idle sentinels, **`title` is the only reliable channel**, so
  bar + % + reset + severity dot all ride the title string. (`cmux sidebar-state` shows the
  canonical store and diverges from what the sidebar actually sees — don't trust it to predict the
  sidebar.)
- **String `.contains` / `.hasPrefix` are broken** when executed (silent blank render). Match by
  `==` instead. Avoid `||`; use an `if`-chain returning early.
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

```
bin/cmux-claude-usage.sh   Claude usage poller (--print | --raw | --update)
sidebars/workspaces.swift  the sidebar (the opinionated design + USAGE panel)
hooks/cmux-bridge.sh       optional Claude Code → cmux working-state bridge
examples/                  usage-sentinels.env + launchd plist templates
install.sh                 file placement + next-steps
```

## Security

The OAuth token is read fresh from the macOS Keychain on every poll and sent only to
`api.anthropic.com` — never written to disk, logged, or printed. Nothing in this repo contains a
token; sentinel UUIDs are placeholders you fill in locally.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). New meter providers, theme variants, and gotcha additions
are all welcome. MIT licensed.
