# cmux Custom Sidebar — Gotchas Cheatsheet

A one-screen field guide to the traps that cost real hours when building a cmux
[custom sidebar](https://cmux.com/docs/custom-sidebars). The sidebar runs a
**subset** of an interpreted SwiftUI-style language; the official docs tell you the
API, this tells you what bites. Everything below is verified on **cmux 0.64.16**
(re-check after upgrades — the interpreter and data model move fast).

- Official authoring reference: `cmux docs sidebars` /
  <https://raw.githubusercontent.com/manaflow-ai/cmux/main/docs/custom-sidebars.md>
- Roadmap (lifts most of these limits): `docs/data-driven-sidebar-plan.md` upstream.

## Validation lies

- **`cmux sidebar validate <name>` only PARSES.** It passes on files that render
  **completely blank** at runtime, and the interpreter swallows the error silently
  (no log). A file that "validates" can still break everything — always eyeball it.

## Data channels (what actually reaches the sidebar)

- **The TITLE is the only dependable per-workspace channel.** `progress`, `color`,
  and `description` are unreliable in custom-sidebar data today — active-workspace-only
  at best, often not present at all for idle workspaces. So anything you want to show
  on an idle/sentinel row (bars, state, status) has to ride the **title** string.
  (cmux's data-driven-sidebar plan intends to fix this — re-probe after each upgrade.)
- **No value-accurate native bar.** `ProgressView(value:)` / `Gauge(value:)` need a
  numeric `progress` you don't reliably have, so meters are Unicode block text bars
  (`▏▎▍▌▋▊▉█`) and color is a colored emoji in the title (🟡/🔴).
- **`cmux sidebar-state` DIVERGES from what the sidebar sees** (it reads the canonical
  store). Never use it to predict the sidebar — verify with an in-sidebar `Text(...)`
  probe instead.

## Identity: no stable workspace id

- **cmux 0.64.15 removed stable workspace UUIDs.** `cmux workspace list --json` returns
  `id: null`; the only handle is a positional `ref` (`workspace:N`) that **rotates
  across app restarts and reorders**. Don't store a workspace id to match a row later —
  it goes stale on the next restart. Match by a stable signal you control, e.g. a
  **title prefix** (`w.title.hasPrefix("5h ")`), re-resolved every run.

## Language subset

- **String ops `.hasPrefix` / `.contains` / `.hasSuffix` / `.split` DO work**, and so
  does `==`. (An older community note claimed they blank-render — disproven on current
  builds.) Use whichever is clearest.
- **Avoid `||`** (unproven) — use an `if`-chain that returns early. `&&` is fine and
  short-circuits.
- **Top-level `let` referencing `workspaces`/`clock` fails.** Those exist only inside
  the view builder; keep `let` bindings inside the `VStack` body.

## Greedy modifiers that wreck layout

- **`Divider().background("#hex")` is the worst trap** — a color `.background()` is
  greedy and corrupts the WHOLE row (inflates height 3-4× AND breaks the sibling's
  width, shoving content to center). Use a plain `Divider()`.
- **`.frame(maxHeight: .infinity)` and `.overlay { Rectangle().frame(height: 1) }`**
  similarly balloon row height. Use `Divider()` + a single `.padding(n)`.
- **`.contentShape(Rectangle())` is a no-op** — a `Button`'s tap area is only its
  rendered content, so give each row a non-zero background fill to make the whole frame
  tappable.
- **Custom fonts aren't honored.** `.font(.custom(...))` silently falls back to the
  proportional system font and adds ~1s lag. Use `.system(size:, design: .monospaced)`.

## Title markers must be STATIC

- If you encode state in the title (e.g. a working/compacting marker), it must be a
  **static** glyph. An animated / frame-by-frame title floods cmux's title coalescer
  and **freezes the sidebar** (upstream issue #6291).

## Debugging a blank sidebar — don't guess, bisect

1. Replace the whole file with a one-line `Text("HELLO")` and confirm it renders (this
   proves the pipeline is alive).
2. Add your helpers/views back **one at a time**, running `cmux sidebar reload` after
   each, until it blanks.
3. The construct you just added is the culprit. This isolates it in ~3 steps instead of
   staring at a silent blank.

---

Worked example: this repo's [`sidebars/workspaces.swift`](../sidebars/workspaces.swift)
puts all of the above into practice (title-as-data-channel usage meters + hook-driven
agent-state markers).
