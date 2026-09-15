# cmux Custom Sidebar — Gotchas Cheatsheet

A one-screen field guide to the traps that cost real hours when building a cmux
[custom sidebar](https://cmux.com/docs/custom-sidebars). The sidebar runs a
**subset** of an interpreted SwiftUI-style language; the official docs tell you the
API, this tells you what bites. Everything below is verified through **cmux 0.64.20**, with the
0.64.23 additions marked (re-check after upgrades — the interpreter and data model move fast).

- Official authoring reference: `cmux docs sidebars` /
  <https://raw.githubusercontent.com/manaflow-ai/cmux/main/docs/custom-sidebars.md>
- Roadmap (lifts most of these limits): `docs/data-driven-sidebar-plan.md` upstream.

## Validation is not rendering

- **`cmux sidebar validate <name>` parses and interprets against a fixed synthetic data context.**
  It does **not** mount `RenderNodeView`, run SwiftUI/AppKit layout, exercise every live-data branch,
  or prove visible pixels. A file can validate and still render blank/collapsed with real data.
- **There is no public rendered-tree, accessibility-tree, or pixel snapshot RPC.**
  `cmux sidebar open <name>` is the strongest live smoke path; `select`/`reload` exercise the same
  mounted renderer. Visual inspection remains necessary. In remote-renderer mode,
  `CMUX_RENDER_WORKER_DEBUG=1` adds worker/layout telemetry but not source-level interpreter errors.
- This repo wraps that ceiling honestly as `make sidebar-live`: stage the repo file, validate it,
  mount it against live data, wait for inspection, close it, and remove the temporary copy. Upstream
  issue [#9002](https://github.com/manaflow-ai/cmux/issues/9002) tracks a real mounted artifact.
- The upstream implementation audit and rationale for keeping visual inspection instead of a brittle
  screenshot/OCR CI gate are in [`sidebar-render-validation.md`](sidebar-render-validation.md).

## Data channels (what actually reaches the sidebar)

- **`progress`, `description`, and `color` DO reach the interpreter, but are null until
  explicitly set.** A known-set render probe is the only valid test; an empty value on an untouched
  workspace proves nothing. `progress.value` + `progress.label` can drive a value-accurate
  `ProgressView(value:)`; `color` and `description` are also bindable.
- **The title is still the strongest identity/fallback channel.** It persists, can be re-resolved
  after workspace refs rotate, and exists before the next poll restores `progress`. Keep stable
  title prefixes for sentinel identity and a Unicode fallback for bootstrap/offline windows.
- **`cmux set-status` does NOT reach custom sidebars.** It renders native-sidebar pills only; the
  binding contract has no status field. Before 0.64.23, agent-state bridges therefore needed static
  title markers (or another interpreter-visible field).
- **0.64.23: `w.agents[]` carries cmux's native per-agent state** (`kind`, `status`
  `idle|working|needs_input|ended`, `lastActivityAt` epoch, …) for every agent cmux hooks. Two
  caveats: Claude's idle "waiting for input" notification (~60s after each finished turn) puts a
  Claude record in `needs_input`, so don't treat that as "asking" for `kind == "claude"`; and nothing
  reaps a `working` record whose agent never sent Stop — compare `clock.epoch - lastActivityAt`
  against a TTL. There is no compacting status.
- **0.64.23: `groups` (`id`, `name`, `collapsed`, `pinned`, `anchorId`, …) and `w.group`.** A group's
  header row is its anchor workspace (`anchorId == w.id`); its name lives only on the group. Group
  anchors and collapsed members take no ⌘N digit (0.64.22+), so a gutter digit computed from
  `w.index` is wrong under any group.
- **0.64.23: a `<name>.js` sidebar beats `<name>.swift`** (which beats `.json`) for the same base
  name, silently. cmux's own example is `Examples/CustomSidebars/workspaces.js`. Upstream issue
  [#9001](https://github.com/manaflow-ai/cmux/issues/9001) tracks this projection drift together with
  the snapshot's missing `progress`.
- **`cmux sidebar-state` and `extension.sidebar.snapshot` are data snapshots, not render probes.**
  The snapshot can omit `progress` immediately after a successful `set-progress`. Verify disputed
  fields with an in-sidebar `Text(...)` against a workspace where the field is known-set.

## Identity: title anchors remain the compatible contract

- **Installed cmux 0.64.20 still has no usable stable workspace UUID.** `cmux workspace list --json` returns
  `id: null`; the only handle is a positional `ref` (`workspace:N`) that **rotates
  across app restarts and reorders**. Don't store a workspace id to match a row later —
  it goes stale on the next restart. Match by a stable signal you control, e.g. a
  **title prefix** (`w.title.hasPrefix("5h ")`), re-resolved every run.
- **Upstream `main` is improving this, but do not migrate yet.** PR #8695 normally preserves the
  runtime `Workspace.id` through session restore. It can still be reminted on collision/exclusion,
  and cmux's explicitly durable `Workspace.stableId` is not exposed by workspace JSON, the snapshot
  RPC, or `w.id`. Keep title anchors until a released build exposes a durable public contract.

## Language subset

- **String ops `.hasPrefix` / `.contains` / `.hasSuffix` / `.split` DO work**, and so
  does `==`. (An older community note claimed they blank-render — disproven on current
  builds.) Use whichever is clearest.
- **Avoid `||`** (unproven) — use an `if`-chain that returns early. `&&` is fine and
  short-circuits.
- **Top-level `let` referencing `workspaces`/`clock` fails.** Those exist only inside
  the view builder; keep `let` bindings inside the `VStack` body.
- **`array != nil` is always false**, even on a populated array — `if w.agents != nil { … }` never
  renders. Guard arrays with `.count > 0`. (`!= nil` on a dictionary like `w.pr` works.)
- **No mutation, no early exit from loops.** `var n = 0; for x in xs { n += 1 }` leaves `n == 0`, and
  `return` inside a `for` doesn't leave the function — silently, and `validate` passes. Count with
  `.filter { … }.count`; its closures DO capture outer values (`workspaces.filter { $0.index <
  w.index }`). Compute into a `let` before comparing rather than putting a trailing closure inside an
  `if` condition.

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
puts all of the above into practice (native progress meters with title-anchor fallbacks plus
hook-driven static agent-state markers).
