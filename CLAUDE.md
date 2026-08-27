# CLAUDE.md — guidance for AI assistants working on cmux-sentinel

cmux-sentinel is an opinionated [cmux](https://cmux.com) **custom sidebar** (a runtime-interpreted
SwiftUI-style file) plus background pollers that show workspace/agent states and **AI usage
meters**. Read this before editing — it encodes traps that cost real hours and that you cannot
discover from the code alone, because the failure mode is a **silently blank sidebar**.

## ⚠️ The sidebar interpreter is a SUBSET of SwiftUI — these WILL bite you

`cmux sidebar validate` parses and interprets against a FIXED SYNTHETIC context, but does not mount
`RenderNodeView`, run SwiftUI/AppKit layout, or exercise every live-data branch. It can pass files
that render **completely blank** at runtime. cmux exposes no public rendered-tree/pixel assertion;
`sidebar open/select/reload` plus an eyeball is the practical ceiling. `make sidebar-live` stages
the repo file under a temporary name, mounts it against live data, waits for inspection, then closes
and cleans it up; it deliberately does not claim a pixel pass. See
`docs/sidebar-render-validation.md` for the upstream source audit. Confirmed traps:

- **String ops `.hasPrefix` / `.contains` / `.hasSuffix` / `.split` DO work** on the current build
  (proven by probe: `hasPrefix=Y contains=Y hasSuffix=Y`; the live sidebar detects the working/
  compacting title markers via `.hasPrefix` and strips them with `.split`). An earlier note here
  claimed they render blank — that was WRONG on this build. `==` works too; use whichever is clearest.
- **`||` is now DOCUMENTED as supported** — upstream `docs/custom-sidebars.md` lists `&& || !` as
  short-circuiting (re-read 2026-08-10). The old "avoid, unproven" note predates that. It is still
  unproven *on this build by render probe*, and the sidebar has no `||` in it today, so there's
  nothing to fix — just don't treat an `if`-chain as mandatory any more. If you do introduce one,
  probe it (blank-render is the failure mode, and `validate` won't catch it). `&&` is fine.
- **`progress`, `description` AND `color` all DO reach the sidebar — all three are null-until-set.**
  Earlier
  probes concluded "`progress` never reaches" but every one checked an IDLE sentinel on which
  `set-progress` was never called — so of course it read `null`. It's **null-until-set**: after
  `cmux set-progress <0..1> --label <t>` the interpreter sees `w.progress.value` AND
  `w.progress.label` (verified 2026-07-06 by an in-sidebar render probe — see
  `.claude/research/2026-07-06-conductor-sidebar-analysis.md`). So the usage meters now draw a
  **native `ProgressView`** off the progress channel, and the **title** stays the meter's
  restart-proof ANCHOR (`resolve_ref`/`isClaudeMeter` key on it) AND the fallback the sidebar renders
  whenever progress is absent — bootstrap, offline-cleared, a dropped write, or the window right
  after an app restart before the next poll re-asserts it. The poller writes BOTH every run
  (`_meter_write`), so the title path is never "ripped out" and restart-persistence of `progress` is
  a non-issue (it self-heals within one poll). **Agent working/compacting/waiting state still rides
  the title** (static markers, stripped for display) — a persistence + precedence choice, not a
  channel limit. **CAVEAT — the snapshot RPC is the WRONG instrument for this:**
  `cmux rpc extension.sidebar.snapshot '{}'` omits the `progress` key entirely even right after a
  successful `set-progress` (that's how the old re-probe "confirmed" the wrong answer), and
  `cmux sidebar-state` diverges too — only an in-sidebar `Text(...)`/render probe is authoritative,
  so eyeball it. **`description`/`color` were re-probed 2026-07-20 and DO reach the interpreter** —
  the old "still don't" note here was WRONG for the exact reason the `progress` note above describes
  (it read unset workspaces). A render probe of `Text("C:[\(w.description)][\(w.color)]")` showed
  `C:[DESCPROBE9][#FF00FF]` on a workspace set via `cmux workspace-action --action set-description`
  / `set-color`, and `C:[][#73D0FF]` on an untouched workspace that merely already had a color —
  which is the control that rules out "the probe itself made it work". Set them with
  `cmux workspace-action --action set-color --color <name|#hex>` (16 named colors or hex) /
  `--action set-description --description <text>`, clear with `clear-color` / `clear-description`.
  Canonical-store field names differ from the bindings: snapshot says `custom_color`, the
  interpreter sees `w.color`. **The generalized lesson: on this interpreter, "renders empty" NEVER
  means "unreachable" — it is indistinguishable from "unset". Only a probe against a workspace where
  the field is KNOWN-SET can prove absence.** See
  `.claude/research/2026-07-20-amp-agent-state-into-cmux.md`.
- **`cmux set-status` pills do NOT reach the custom sidebar** (probed 2026-07-20, same doc). cmux's
  bundled agent plugins (amp, opencode, pi, …) report live state with
  `cmux set-status <key> <value> --icon --color --priority`, which renders as pills in the NATIVE
  sidebar tab row only. `w.status`/`w.state`/`w.statusText` all render empty even with a status
  set — and here the known-set control makes that conclusive. Corroborated by the authoritative
  binding contract in cmux's `docs/custom-sidebars.md` ("Live data you can bind to"), which lists
  every interpreter-visible field and has no status among them: always `id`, `title`, `selected`,
  `pinned`, `index`, `directory`, `ports`+`portCount`, `unread`, `tabs`+`tabCount`; optional
  `description`, `color`, `branch`+`dirty`, `pr`+`prs`, `progress`, `latestMessage`, `latestPrompt`,
  `latestAt`, `remote`. **Consequence: a cmux-native agent integration can never light up this
  sidebar — per-agent title-marker bridges stay mandatory.** (`latestMessage`/`latestPrompt`/
  `latestAt` are bindable and currently unused here.) Upstream issue
  `manaflow-ai/cmux#9001` tracks unifying this projection with the snapshot's missing `progress`
  (still OPEN, no maintainer response as of 2026-08-10; so is #9002 for a render diagnostic).
  Re-read on 0.64.22: the binding list above is **UNCHANGED** — nothing gained, nothing lost.
- **cmux SHIPPED a native workspace "status lane" concept in 0.64.22 — usable by hand, invisible to
  us.** `markWorkspaceDone` (⌘;) and `cycleWorkspaceStatus` (⌘⇧;, "cycle the workspace status one
  lane forward") are present at the **v0.64.22 tag** (verified by fetching
  `web/data/cmux-shortcuts.ts` at the tag), alongside 0.64.21's "Restore todo/completion-status
  parity in the AppKit sidebar" (#8552) and "Tell coding agents workspace todos are user-owned"
  (#8566). It has **no programmatic surface at all**: `cmux workspace-action --action mark-done` →
  `Unknown workspace action` (the action list has no status/done/lane entry), no RPC method matches
  `todo|lane|complet|done`, the `extension.sidebar.snapshot` key set has no lane field, and the
  sidebar binding contract has none either. So: **Oliver can use it manually; the sidebar cannot read
  it and no poller can write it.** Nothing to integrate. Flagged because it is the first upstream
  feature that genuinely OVERLAPS our title-marker agent state (⚡/⏳/❓) — if a lane ever becomes
  readable, revisit whether the markers should defer to it rather than compete. Also note "workspace
  todos are USER-owned" is now an explicit upstream stance, so don't have an agent drive lanes even
  if a write API appears.
- **TRAP: `cmux shortcuts` prints only `OK`** — it opens the Settings UI, it does not list anything.
  Grepping its output to test whether a shortcut exists returns nothing and looks like proof of
  absence; it is proof of nothing. (This exact mistake produced a wrong "not released yet" note here
  on 2026-08-10.) To check a keybinding, fetch `web/data/cmux-shortcuts.ts` **at the installed
  version's tag** — `main` runs ahead of the release. Same shape as the `progress`/`description`
  lesson above: an empty read is never evidence.
- **Sentinel resolution is multi-window + title-anchored.** `cmux workspace list` is window-scoped and
  launchd has no window context, so the pollers' `resolve_ref` tries the default window then scans
  `list-windows`, returning `ref⇥window` and renaming with `--window` (unambiguous positional ref).
  `bin/cmux-sentinel-setup.sh` creates the sentinels idempotently; both it and the doctor probe
  `workspace.set_auto_title '{}'` (empty params = no mutation) to warn if global auto-naming could
  clobber a title prefix.
- **`cmux sidebar-state` DIVERGES from what the sidebar sees** (it reads the canonical store). Never
  use it to predict the sidebar — verify with an in-sidebar `Text(...)` probe.
- **Sentinel identity stays TITLE-anchored — even though `workspace list --json` now has real ids
  again.** History: 0.64.15 removed stable workspace UUIDs and `id` came back `null`, leaving only a
  positional `ref` (`workspace:N`) that **rotates across app restarts and reorders**. The original
  scheme stored sentinel UUIDs in the env file and the sidebar; that broke on the first restart
  (silent "offline" meters in the normal list). Both sides therefore anchor on the **title label**:
  the poller `resolve_ref()`s each sentinel by the workspace whose title starts with the `5h`/`7d`
  label (plus a space) and renames by the live ref; the sidebar's `isClaudeMeter()` matches the same
  prefix. That is restart-proof BY CONSTRUCTION — it re-resolves every run — which is the same
  reason the bridge reads a LIVE `$CMUX_WORKSPACE_ID` instead of storing one.
  **Re-probed 2026-08-10 on 0.64.22: `id` is populated again** (PR #8437, "Fix stable IDs in mirror
  workspace CLI output") and it equals the shell's `$CMUX_WORKSPACE_ID` for the same workspace —
  verified by matching `workspace:3`'s `id` against the env var. 0.64.21 also shipped "Preserve
  workspace IDs across session restore" (#8695), so ids very likely DO now survive a normal restart.
  **This still does NOT justify switching back.** Preserved-normally ≠ durable: #8695 can still
  remint on collision/exclusion, and the explicitly durable
  `Workspace.stableId` is STILL absent from workspace JSON (key not present), the snapshot RPC, and
  `w.id`. Nothing about a title anchor gets cheaper if ids work, and it costs nothing today. Before
  anyone reopens this: the missing evidence is a restart probe — record every `id`, quit and reopen
  cmux, diff — plus a public `stableId`. Don't reintroduce a stored id on anything less. The
  committed and deployed sidebars stay byte-identical (no id substitution at install).
  See `.claude/research/2026-08-10-cmux-0.64.22-vacation-catchup.md`.
- **Meters use a native value bar now.** `ProgressView(value:)` needs a numeric `progress`; the
  poller supplies it via `set-progress` (see the progress bullet above), so a meter row renders a
  native `ProgressView` tinted from the value (red ≥90%, amber ≥70%, else blue) with
  `w.progress.label` for compact `28% (1h 54m)` text. The title uses
  `<anchor> |<detail>|<unicode bar>` so the fallback keeps the same label/detail-then-bar rhythm when
  `progress` is absent. The title's severity emoji (🟡/🔴) stays because title **color** still can't
  come from data.
- **Workspace-GROUP data NEVER reaches the sidebar interpreter** (probed 2026-06-19, see
  `.claude/research/2026-06-19-workspace-group-names-in-sidebar.md`). There is no `groups` binding and
  no per-workspace group field — referencing `groups` renders empty (the interpreter is lenient, it
  does NOT blank), and `extension.sidebar.snapshot` carries no group fields either. A cmux group's
  display name (`group.name`, via `cmux workspace-group list`) lives ONLY on the group object; the
  group header IS its ANCHOR workspace's row, and the anchor's `title` does NOT track `group.name`
  (they diverge on rename). So the sidebar shows the anchor's stale/generic "Group N". Same fix shape
  as the meters: `bin/cmux-group-sync.sh` (opt-in `GROUP_NAME_SYNC=1`) renames each anchor's title to
  `group.name` via the **title channel** (preserving any ⚡/⏳ marker, writing only on change). Don't
  try to read group data in the sidebar — it isn't there.
- **No modifier-key state reaches the interpreter — ⌘-hold hints are impossible.** The live
  bindings are only `workspaces` / `tabs` / `workspaceCount` / `selectedTitle` / `selectedId` /
  `unreadTotal` / `clock`; there's no keyboard/modifier binding (and no `@State`, no
  `.keyboardShortcut`). cmux's NATIVE sidebar does draw ⌘-hold digit badges
  (`modifierKeyMonitor.isModifierPressed`), but that's internal to it. Even given a binding, the
  ~1s re-eval would lag a held key. Needs an upstream feature — don't try to fake it.
- **The ⌘N gutter digit keys on a NUMBERED POSITION, not on `w.index`** — mirroring cmux's
  `WorkspaceShortcutMapper` plus `SidebarWorkspaceRenderItem.numberedWorkspaceIds`. Three traps a
  naive 1..N counter gets wrong. **(1) ⌘9 is NOT the 9th** — it always selects the LAST row
  (`count-1`), so positions 8…count-2 have no key at all. **(2) The digits count the sentinels**
  (cmux has no "sentinel" concept — that's only this file's predicates), so the meters really do eat
  ⌘ slots and the visible rows show honest gaps (verified 2026-07-15 by a real ⌘1…⌘9 sweep:
  ⌘6→`cx7d`, ⌘7→`cx5h`, ⌘9→`7d`). **(3) Since 0.64.22 the digits do NOT count every workspace.**
  Upstream #9176 ("Fix workspace group anchor numbering", in `main` 2026-07-30, shipped in 0.64.22)
  changed `TabManager.selectWorkspaceByNumber` to index the ORDINARY RENDERED ROWS instead of the raw
  `TabManager.tabs` array. Excluded, and each exclusion pulls every row below it one key UP:
  a group's **ANCHOR** (it renders as the group header, not a workspace row) and every member of a
  **COLLAPSED** group. Sentinels are plain ungrouped workspaces so they're always numbered — but a
  group above them silently shifts them into the keyed band. **The digit math itself is unchanged**
  (re-verified 2026-08-10 against upstream's own `WorkspaceShortcutMapperTests`: ⌘9→`count-1`,
  index 8 of 12 → no digit); only the set being numbered moved.
  There's still no way to make a sentinel weightless — no hidden/archived concept — so
  the fix is ORDER, which is free because sentinel position doesn't affect what renders (the meter
  panel sorts by label; the list filters meters out). **Layout invariant: sentinels live in the
  keyless band (numbered positions 8…count-2) and the LAST NUMBERED row is a real one** — that's 9/9
  keys on real workspaces. Sentinels at the very bottom costs ⌘9; at the top costs ⌘1–⌘4. Enforced by
  the layout pass in `bin/cmux-sentinel-setup.sh` (re-run it anytime; `--no-layout` /
  `SENTINEL_LAYOUT=0` opts out). It only pushes meters down and re-parks a workspace that is already
  near the end, so relative order of real workspaces is preserved and nothing visible moves.
  **It must never park a group ANCHOR last** — an anchor renders as a header, drops out of the
  numbering, and hands ⌘9 straight back to a meter; `layout()` picks the last *numbered* real via
  `JQ_NUMBERED` for exactly that reason (regression-tested in `tests/sentinel-setup.sh` T9).
  Deliberately NOT in the pollers — re-asserting order every 5min would fight manual drag-reordering.
  **That pass is one-shot, so the invariant DECAYS: closing a workspace above a meter shifts the
  meter up, and once fewer than 8 reals sit above it, it eats ⌘8** — silently, since the only symptom
  is a ⌘ key doing something odd. **Collapsing a group above the meters now spends that headroom the
  same way a close does.** So `bin/cmux-sentinel-doctor.sh` reports which digits (if any) the
  meters are eating and warns when headroom is down to one close; the fix is always "re-run setup".
  Read-only, for the same reason it's not in the pollers. Both scripts keep an identical copy of the
  `JQ_NUMBERED` jq helper (setup parks by it, doctor reports drift off it) — change them together.
  The source is fetchable; `cmux docs shortcuts` names the raw URLs.
  See `.claude/research/2026-08-10-cmux-0.64.22-vacation-catchup.md`,
  `.claude/research/2026-07-15-workspace-shortcut-digits.md` and
  `.claude/research/2026-07-16-cmux-0.64.19-pre-restart-check.md`.
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
cmux sidebar validate workspaces && cmux sidebar reload   # synthetic interpretation only — eyeball it

# pollers (no cmux writes unless --update)
./bin/cmux-claude-usage.sh --print     # parsed values
./bin/cmux-claude-usage.sh --raw       # raw API JSON (no token)
./bin/cmux-claude-usage.sh --update    # writes title fallback + native progress
./bin/cmux-claude-usage.sh --buckets   # which labels have live data (fails open); drives setup
./bin/cmux-codex-usage.sh --print      # Codex: live utilization via account/rateLimits/read
./bin/cmux-codex-usage.sh --raw        # normalized JSON; account-scoped reset-credit ids removed
./bin/cmux-codex-usage.sh --raw-full   # complete account-private JSON — inspect locally only
./bin/cmux-codex-usage.sh --update     # writes cx5h/cx7d title + progress (needs codex enabled)
./bin/cmux-codex-usage.sh --buckets    # which windows the account HAS (empty = can't tell); drives setup
./bin/cmux-amp-usage.sh --print        # Amp: monthly subscription allowance (scraped from `amp usage`)
./bin/cmux-amp-usage.sh --raw          # raw `amp usage` text (CONTAINS YOUR EMAIL — stays local)
./bin/cmux-amp-usage.sh --update       # writes ampu (+opt-in ampo) title + progress; needs amp enabled
./bin/cmux-amp-usage.sh --buckets      # which allowances to meter (empty = can't tell); drives setup
./bin/cmux-sentinel-setup.sh           # create known-live provider sentinels; fail open when unknown + park them out of ⌘1…⌘9
./bin/cmux-group-sync.sh --list        # workspace-GROUP names: which anchors are out of sync (read-only)
./bin/cmux-group-sync.sh --update      # rename group anchors to the group name (needs GROUP_NAME_SYNC=1)
cmux-sentinel doctor                   # dispatcher: setup/doctor/version/usage/paint/update/group-sync/zed
make sidebar-live                     # mount repo sidebar against live data; human visual verdict

# offline tests (stub cmux/security/curl/stat/$HOME — run in CI too)
make test   # bridge-state(58) poller-gate(111) codex-poller(83) install-hooks(62) sentinel-setup(69)
            # sentinel-doctor(49) group-sync(24) zed-bridge(24) open-in-zed(14) usage-tui(23)
            # amp-bridge(43) amp-poller(49) entrypoint(33) formula(18) = 660 assertions total
```

## Architecture / where things live

```text
sidebars/workspaces.swift  the sidebar. isClaudeMeter()/isCodexMeter()/isAmpMeter() = title-label `.hasPrefix` per provider; isUsageMeter() = any.
bin/cmux-claude-usage.sh    Claude usage poller. scoped_weekly (per-model cap, opt-in m7d) + response cache. make_bar / sev_dot / mark_offline / bucket_field / to_pct / resolve_ref(+_paint, multi-window).
bin/cmux-codex-usage.sh     Codex usage poller (short-lived account/rateLimits/read app-server RPC; Codex owns auth/refresh). Default meter + read-only named limits/reset credits; sanitized --raw / local-only --raw-full; actionable RPC failure classes; --buckets drives setup.
bin/cmux-amp-usage.sh       Amp usage poller (scrapes `amp usage` PROSE — no --json). Monthly allowance, not windows. REMAINING→USED inversion. ampu (agent) + ampo (orb, opt-in AMP_ORB_METER=1).
bin/cmux-sentinel-setup.sh  idempotent sentinel creation (per USAGE_PROVIDERS; known-live buckets only, fail-open on unknown) + auto-naming guard probe + ⌘N shortcut layout (layout/sentinel_window/JQ_NUMBERED, --no-layout).
bin/cmux-sentinel-doctor.sh READ-ONLY wiring report: cmux/sidebar/bridge/auto-refresh, installed × enabled × live capability × sentinel × freshness per provider, informational Codex limits/reset credits, ⌘N layout drift (JQ_NUMBERED), snapshot data.
                            JQ_NUMBERED is duplicated verbatim in both files — cmux numbers ⌘1…⌘9 over the ORDINARY sidebar rows (group anchors + collapsed members excluded), so change them together.
bin/cmux-sentinel           DISPATCHER installed as ~/bin/cmux-sentinel: setup|doctor|version|usage|paint|deploy|update|group-sync|zed. Resolves the cmux-*.sh helpers next to itself (or ../libexec, or ~/bin) and `exec`s them, so exit status and args pass through untouched. It does NOT replace them — the LaunchAgents reference them by absolute path.
bin/cmux-sidebar-live-smoke.sh  stage + validate + mount the repo sidebar against live data, wait for a human verdict, then close/clean up; not a pixel assertion.
bin/cmux-group-sync.sh      workspace-GROUP name → anchor-title sync (opt-in GROUP_NAME_SYNC). split-marker / multi-window / --list|--raw|--update.
hooks/cmux-bridge.sh        Claude Code → cmux agent-state bridge (⚡ working / ⏳ compacting / ❓ waiting-on-you rows). AGENT-AGNOSTIC: CMUX_SENTINEL_SESSION_PID / _AGENT_LABEL / _LOG_SOURCE let any agent's adapter reuse it.
hooks/amp-bridge.ts         Amp plugin (Bun/TS) → drives cmux-bridge.sh. Thin ADAPTER, no own state, so amp+claude co-tenants ref-count in one $WORKROOT. 2-of-3 states (no ⏳; ❓ opt-in).
hooks/zed-bridge.sh         OPT-IN (ZED_SENTINEL=1) cmux-free Zed bridge: same ⚡/⏳/❓ markers to OSC-2 terminal metadata + JSON sink (stock Zed tab label stays process-derived).
bin/cmux-open-in-zed.sh     OPT-IN cmux→Zed worktree handoff (`ze` alias / Ctrl-O via --shell-init). git-toplevel-aware; switch/--add/--new/--print.
bin/zed-usage-tui.sh        OPT-IN usage meters rendered in a Zed terminal pane (reuses the pollers). No cmux writes.
tests/                      bridge-state + poller-gate + codex-poller + amp-poller + install-hooks + sentinel-setup + sentinel-doctor + group-sync + zed-bridge + open-in-zed + usage-tui + amp-bridge + entrypoint. `make test`.
scripts/make-formula.sh     GENERATES packaging/homebrew/cmux-sentinel.rb for a tag (url+sha256+version must agree); `--check` is the offline gate `make formula` runs.
packaging/homebrew/         the tap's formula. Generated — regenerate after tagging, never hand-edit.
VERSION + CHANGELOG.md      release stamp. install.sh copies VERSION (+ install date + short commit) to ~/.config/cmux-sentinel/VERSION; `cmux-sentinel version` and the doctor header read it back and compare against the remote VERSION (fail-silent; CMUX_SENTINEL_UPDATE_CHECK=0 disables).
examples/                   usage-sentinels.env + launchd plist templates (com.cmux-claude-usage / com.cmux-codex-usage / com.cmux-amp-usage / com.cmux-group-sync).
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
  **`kill -0` alone is NOT a sufficient reaper — it reaps CRASHES, not turns that ended without a
  `Stop`.** Bit for real on 2026-08-14: two workspaces (`claude-elixir-phoenix`, `Scribe`) sat at ⚡
  for THREE DAYS. Both were Amp: `hooks/amp-bridge.ts` uses `process.pid`, which is Amp's **plugin
  runtime host — one process per amp SESSION, not per turn** (`amp run …/plugin-runtime.ts
  …/cmux-sentinel-amp.ts`, still alive with an `amp threads continue T-…` parent). The threads were
  abandoned, `agent.end` never fired, the ref-count file was never removed — and `kill -0`
  truthfully answered "alive" forever. Worse, `_reconcile_all()` on every SessionStart faithfully
  **re-asserted** the stale ⚡ and refreshed `.marked`, so the self-heal path made it look deliberate;
  `_sweep_orphan_marks` couldn't help either (it defers to `_desired_mark`, which said ⚡). Same
  class as the documented Esc-interrupt edge, but unbounded because a plugin-runtime host has no
  reason to exit. **Fix: liveness AND freshness.** `_set_working` touches the pid file on every turn
  event, so `_desired_mark` now also reaps working/compacting entries untouched for `_WORK_TTL`
  (`CMUX_SENTINEL_WORK_TTL`, default 3600s; `0` = old pure-liveness behaviour). `_expired()` answers
  "not expired" on every uncertain path (TTL off, non-numeric, unreadable mtime) — reaping a live
  turn's marker is the worse failure. **`.waiting.<pid>` is deliberately EXEMPT**: nothing refreshes
  it while a session sits blocked on you, so a TTL would silently delete exactly the ❓ signal that
  matters most. Err LONG on the TTL — one tool call (a build, a full suite) can legitimately run for
  a long time; overshooting costs a stale row, undershooting drops ⚡ mid-turn. Regression-tested in
  `tests/bridge-state.sh` K–K5 (back-dated with `touch -t CCYYMMDDhhmm`, the one form both BSD and
  GNU accept, so the block needs no sleeps).

- **The ❓ transition is the ONLY notifiable event** (`CMUX_SENTINEL_NOTIFY_CMD`, opt-in, empty
  = off). An agent that is alive but parked on YOU is the one state worth interrupting someone
  out-of-window for; working/idle/finished are passive status you read off the sidebar when you
  look — which is exactly why the ✅ "done" marker was rejected. Adding a second notifiable
  event would make the alert ignorable and cost you the ❓, so don't. It fires from
  `_set_waiting` AFTER the already-waiting guard (one alert per transition, not per hook event),
  runs `sh -c "$CMUX_SENTINEL_NOTIFY_CMD"` with the workspace label as `$1` / the event as `$2`
  (also `CMUX_SENTINEL_WORKSPACE` / `_EVENT` in the env), and is **detached with output
  discarded on purpose**: this is the agent's hot path, so a notifier that blocks or fails must
  never stall a turn or break the marker. The accepted cost is that a notifier which hangs
  forever leaks one process — keep it a quick fire (`curl -sf`, `terminal-notifier`).
  Covered by `tests/bridge-state.sh` block L.
- **Amp agent state needs OUR OWN plugin — cmux's native amp integration cannot light up this
  sidebar.** `cmux hooks amp install` writes `~/.config/amp/plugins/cmux-session.ts`, which reports
  state with `cmux set-status` → native-sidebar pills only (see the set-status bullet above). So
  `hooks/amp-bridge.ts` is a SECOND, separate plugin file in the same dir (amp auto-loads every
  `*.ts`; the two coexist). **Never edit `cmux-session.ts`** — it self-upgrades in place. Install
  BOTH: cmux's for the native UI + session restore, ours for the custom sidebar.
  Amp has **no shell hooks** — it has a Bun/TypeScript **plugin** system (`session.start`,
  `agent.start`, `agent.end`, `tool.call`, `tool.result`; `ctx.$` is Bun's shell). Authoritative
  per-build API: **`amp plugins show-docs`** (better than the web manual).
  **`amp plugins exec <file> <event>` only actually INVOKES `session.start`** — `agent.start`,
  `agent.end`, `tool.call` and `tool.result` all exit 0 WITHOUT running the handler (they need a
  real thread context; verified across all five, 2026-07-20). So it's useless as a general event
  injector, and a test that just greps its output for errors is a FALSE POSITIVE proving only that
  the file parses. `tests/amp-bridge.sh` therefore drives `session.start` through the real runtime
  into a recorder standing in for the bridge (`CMUX_SENTINEL_BRIDGE` override) — that's what proves
  amp loads the TS, fires the handler, and spawns the bridge with the right identity and payload.
  **Our plugin is a thin ADAPTER that shells out to `hooks/cmux-bridge.sh`, not a reimplementation.**
  That's load-bearing: co-tenant agents in one workspace must ref-count against each other, which
  only works if they share one `$WORKROOT`. So the bridge grew three agent-agnostic knobs
  (`CMUX_SENTINEL_SESSION_PID` / `_AGENT_LABEL` / `_LOG_SOURCE`; defaults keep Claude Code
  byte-identical). `tests/amp-bridge.sh` pins the co-tenancy property explicitly. The plugin probes
  `cmux-bridge.sh --capabilities` by OUTPUT (old bridges ignore unknown events and still exit 0): a
  new bridge handles terminal Amp errors atomically with `StopFailureFinal`; an old bridge gets the
  synchronous ordered fallback `SessionEnd` then `StopFailure`, so a partial manual update cannot
  strand ⚡, clear its own error pill, or emit `Stop`'s misleading finished notification.
  **Coverage is 2-of-3 and the gaps are Amp's:** ⚡ from `agent.start` + `tool.call`, cleared by
  `agent.end`; **⏳ compacting is IMPOSSIBLE** (Amp emits no compaction event — don't fake it); **❓
  waiting is opt-in** (`CMUX_SENTINEL_AMP_ASK=1`) because Amp doesn't ask permission by default, so
  there's no blocked-on-user moment to observe — and turning it on CHANGES AMP'S BEHAVIOUR.
  Under `amp -x`, lifecycle events are SKIPPED unless you pass `--plugin-ready-timeout`.
- **Usage meters group by provider:** each provider gets its own labelled panel section
  (`CLAUDE USAGE`, `CODEX USAGE`, `AMP USAGE`) — same component reused. A meter is just an idle
  "sentinel" workspace whose poller updates both native progress and a title anchor/fallback.
  **Three providers ship:** Claude
  (`bin/cmux-claude-usage.sh`, OAuth usage endpoint), Codex (`bin/cmux-codex-usage.sh`) and Amp
  (`bin/cmux-amp-usage.sh` — CLI scrape, see its own bullet below). Codex calls the supported
  `account/rateLimits/read` app-server RPC through one short-lived stdio process per poll. Codex
  owns file/keyring auth lookup, proactive OAuth refresh, account headers, backend routing, and
  normalization; **no OAuth material enters the poller**. Under the hood current Codex still reads
  ChatGPT's internal `wham/usage` route. The JSONL client keeps a FIFO open until the correlated
  `id=1` response arrives because early stdin EOF races app-server shutdown; notifications may
  interleave or be torn mid-write; the JSONL reader ignores malformed unrelated lines and
  correlates only complete responses by id. **Route windows by `windowDurationMins`, NEVER by primary/secondary POSITION**
  (<1d → `cx5h`, ≥1d → `cx7d`) — OpenAI reshaped that twice in ~10 days. The OLD local-rollout source
  (`~/.codex/sessions/**/rollout-*.jsonl`) is DEAD on codex-cli 0.142.x — `codex exec` (how Claude
  Code drives Codex) doesn't write `rate_limits` (openai/codex#14880) and fresh data moved to
  non-queryable sqlite, so the meter went weeks-stale; the endpoint is account-server-side, so it's
  correct for any usage pattern. The app-server RPC is the strongest structured contract, but its
  backend remains internal → parse defensively; API-key logins aren't covered (and any existing
  sentinels must still be closed to hide their panel). `codex login status` only confirms a stored
  auth mode, not token health; an invalidated refresh token still needs `codex logout` + re-login.
  RPC failures are classified without echoing response bodies: auth failures give that exact
  recovery, while timeout/transport/network/schema failures remain distinct. `rateLimits` is the
  generic sidebar projection. Optional `rateLimitsByLimitId` entries are open-ended backend-defined
  named/model limits: show them only in `--print`/doctor, prefer `limitName`, never treat opaque ids
  as stable, and never auto-create sentinels for them. Optional reset credits are likewise read-only
  diagnostics; never consume them. Normal `--raw` removes account-scoped reset-credit ids;
  `--raw-full` is explicitly account-private/local-only and must never be pasted into logs.
  Current source audit: `docs/usage-data-source-research.md`. Earlier decision record:
  `.claude/research/2026-07-06-codex-usage-api-source.md`. To add a FOURTH provider: create a
  sentinel, add an `isXMeter()` predicate + an `if isXMeter(w)` line to `isUsageMeter()` + an
  `X USAGE` panel section, a poller with a new data source, then wire it into
  `cmux-sentinel-setup.sh` (label + `live_buckets`/`ensure_live` branch + `ALL_LABELS`),
  `cmux-sentinel-doctor.sh` (installed × enabled × sentinel + the `labels` line),
  `scripts/check-secrets.sh` (anchor assertion), `install.sh`, `examples/`, and `tests/`.
- **Amp is the THIRD provider, and it breaks two shape assumptions the first two share**
  (`bin/cmux-amp-usage.sh`, added 2026-07-20 — see
  `.claude/research/2026-07-20-amp-agent-state-into-cmux.md`):
  1. **The source is PROSE, not JSON.** `amp usage --json` is rejected outright; the only source
     is the human-facing text `amp usage` prints. So parsing anchors on the smallest stable
     thing — the number immediately before the phrase `other usage` / `orb usage` — and NEVER on
     line position, field order, plan name, or the surrounding sentence (Amp is free to reword
     it in any release). `tests/amp-poller.sh` pins this with a deliberately reworded+reordered
     fixture. Anything unparseable becomes `⚠ offline`, **never** a fabricated 0%.
  2. **The numbers are REMAINING; the meters show USED.** Amp prints "100% other usage …
     remaining" for an untouched allowance, so every value is inverted (`used = 100 - remaining`).
     Get this backwards and a brand-new subscription renders a FULL red bar. It has its own test.
  Also: not rolling windows but ONE monthly allowance, so reset text comes from Amp's own phrase
  rather than a computed countdown (simple units are compacted for display: `26 days` → `26d`),
  and the `$` workspace credit balance is
  deliberately not metered (a currency balance has no honest 0-100% bar). **`ampo` (orb usage) is
  opt-in via `AMP_ORB_METER=1`** — same "a dead meter is NOT free" rule as the retired `cx5h`:
  most people never run orbs, so metering it by default would cost a real ⌘ key for an unused row.
  `provider_available()` checks the binary plus a non-empty
  `~/.local/share/amp/secrets.json` — it never reads the file, which holds credentials.
- **Anthropic publishes a per-MODEL weekly cap; it is metered only on request (`m7d`).**
  Alongside `five_hour`/`seven_day` the payload carries a modern self-describing
  `limits[]` array whose `kind == "weekly_scoped"` row is a model-scoped allowance
  (`scope.model.display_name` = "Fable" today). Three rules, each of which is a trap:
  **(1) the two working meters keep reading the legacy top-level buckets** — `limits[]` is
  parsed ONLY for the new row, because adding a feature must never put a proven meter at risk.
  **(2) never hardcode the model name.** `scope.model.id` is `null`, so `display_name` is the
  only handle, and Anthropic re-scopes which model is capped at will. The name therefore rides
  its OWN 4th title segment — `m7d |15% (3d 2h)|▉…|Fable` — never the anchor (that has to be a
  static `.hasPrefix` literal) and never the detail. The sidebar draws it as the ROW LABEL,
  where every other meter shows one word ("session", "week", "threads"); prefixing the detail
  instead shipped a row reading `model  Fable 15% (3d 2h)`, saying it twice. Split on `|`, not
  on the detail's first space, so a name containing a space survives. **(3) `seven_day_opus`/`seven_day_sonnet` exist as
  top-level keys and are `null`** — reading those is exactly the "renders empty ≠ unreachable"
  mistake this file keeps warning about; a non-null `weekly_scoped` row is the only proof.
  Off by default (`CLAUDE_MODEL_METER=1`) for the same reason as the Amp orb meter: the sentinel
  is an ordinary workspace and costs one of the ⌘1…⌘9 keys. **An opt-in meter that skips SILENTLY is a bug, not restraint** — the first user to update
  saw no Fable row and couldn't tell "off" from "broken". So all three surfaces name the switch:
  `--print` lists the row (and how to enable it) whether or not it is metered; setup probes what
  `--buckets` WOULD answer with the flag on and says so only when a real cap exists (no cap, no
  noise); the doctor says "the per-model meter is off" plus the variable, instead of the useless
  "correct, it isn't metered". Discovering the feature must never require opting into it first.
  `--buckets` was added to the Claude poller for setup's `ensure_live`, with the same fail-open
  contract as Codex/Amp: it lists `5h`/`7d` always and adds `m7d` only when opted in AND the cap
  is live — silence never suppresses. Opted in with no cap → the row paints an honest `n/a`
  rather than a fabricated 0%, and does NOT fail (Anthropic adds and drops these).
- **The `spend` meter is the one row that HIDES ITSELF, and the one optional row with no
  opt-in flag.** The Claude payload's `spend` object is the account's extra-usage (overage)
  budget and carries BOTH `used` and `limit` (plus its own `percent`), so unlike Amp's bare `$`
  balance it has an honest 0–100% bar. Two rules that look inconsistent with the rest of the
  file but aren't: **(1) no `*_METER=1` flag.** The opt-in rule exists because a dead meter
  still costs a ⌘ key to show nothing — this row costs nothing to LOOK at, because the sidebar
  drops it while the balance is zero. And it must be on by default to do its job at all: the
  point is to catch money you did NOT expect to be spending, which a flag you never set cannot
  do. **(2) The sentinel is created from whether the account HAS a budget, never from the
  balance.** Gating creation on `spent > 0` would mean the meter can only appear after someone
  re-runs setup — i.e. never, since nobody re-runs setup because they suspect a charge they
  don't know about. The zero case is handled at RENDER time: the poller writes `spend |none|`
  every run while the balance is zero, and the sidebar's `isZeroSpend` drops it. That marker is
  load-bearing — `scripts/check-secrets.sh` asserts BOTH the `"spend "` prefix and the `|none|`
  marker, because losing the second one parks a permanent `€0.00` row on everyone.
  `isClaudeMeter` still matches a hidden row (so it never leaks into the normal workspace list);
  the panel filters with the separate `isClaudePanelRow`. **`extra_usage.utilization` sits right
  next to `spend.percent` and is `null`** — read the wrong one and you'd conclude the data isn't
  there, exactly like `seven_day_opus`. Never guess a currency symbol: `fmt_money` maps
  EUR/USD/GBP and prints any other ISO code verbatim, and honours `exponent` so a zero-decimal
  currency doesn't grow a fake decimal point.
- **The usage poller caches its last good response (`CMUX_SENTINEL_USAGE_CACHE_TTL`, default
  60s).** The documented way to use this tool — `--print` to look, then `--update` to paint — was
  two API calls seconds apart on top of the 5-minute launchd poll, and that burst is what trips
  the endpoint's 429. Only SUCCESSES are cached: a failed response must stay visible as
  `⚠ rate limit`/`⚠ auth` and the next poll must retry the network, never replay the error.
  `TTL=0` disables it. Cache file is `$USAGE_STATE_DIR/<provider>.last-response.json`, mode 600
  (it is an account-scoped usage body — treat it like `--raw-full`).
  **Probe the mtime with GNU `stat -c` FIRST, then BSD `stat -f` — the order is load-bearing and
  getting it backwards is invisible on macOS.** The two flavours are NOT symmetric: BSD rejects
  `-c` outright (empty stdout, clean fallback), but on Linux `-f` is a REAL flag meaning
  `--file-system`, so a BSD-first probe prints a filesystem block, the `||` appends the true mtime
  to it, and the digit check rejects the concatenation — the cache reads cold forever and every
  burst is two API calls again. Shipped exactly that way: `make ci` was red for ten commits on
  `main` while every local run passed 109/109, because the only failing assertion was one nobody
  could reproduce on a Mac. `hooks/cmux-bridge.sh` already had the right order; the poller didn't.
  Both flavours are now pinned on ANY platform by a `stat` stub in `tests/poller-gate.sh`
  (`STUB_STAT=gnu|bsd`, unset delegates to the real binary) — reach for that stub before trusting
  a green local run on anything mtime-shaped. Same lesson as the empty-read traps above: a suite
  that passes on your OS is not evidence about the other one.
- **A provider may not HAVE a window we model — and a dead meter is NOT free.** A sentinel is
  an ordinary workspace, so a permanently-`n/a` row still eats one of the ⌘1…⌘9 keys to show
  nothing. OpenAI dropped the **5h window for Codex Pro** — confirmed permanent 2026-07-16
  (real Codex usage 4h before a poll still returned no 5h window, and codex-cli's OWN rollout
  snapshot agrees: `window_minutes: 10080, secondary: null`, same `resets_at` we read) — so
  `cx5h` is retired. **Detected, never hardcoded**: the account's window set changes too often for a constant,
  so the poller's `--buckets` prints the labels with LIVE windows and setup's `ensure_live()`
  skips the rest. If OpenAI restores 5h, a plain `cmux-sentinel-setup.sh` re-run brings the
  meter back with no code change. **`--buckets` FAILS OPEN** — it prints nothing on every
  can't-tell path (disabled / not logged in / expired token / offline / schema change) and
  setup reads empty as "create both", so a flaky network can never silently cost a meter.
  Keep that asymmetry: only a POSITIVE answer may suppress a sentinel. Corollary in the
  poller: an `n/a` bucket whose sentinel is ABSENT is a quiet no-op (launchd runs it every
  5min — dying there would fail forever over a meter that's correctly gone), but a **live**
  window with a missing sentinel still dies (a real broken install). Setup still **never
  closes anything** — retiring a live sentinel is a manual `cmux workspace close`.
  Diagnostics use the separate machine-readable `--status` mode, which distinguishes
  `available` bucket sets from `unknown`, `disabled`, and `uninstalled`; doctor retains the current
  layout on `unknown` instead of inventing a missing-window warning. Doctor must prove the live RPC
  before saying meters are active—a stored ChatGPT login alone is not availability.
  See `.claude/research/2026-07-16-codex-5h-window-gone-for-pro.md`.
- **Provider selection is gated, not configured in the sidebar** (it can't read config — only
  workspace data). A provider's panel shows IFF its sentinels exist, and the sidebar auto-hides any
  provider with a zero `count`. So selection lives in setup: which pollers run + which sentinels
  exist. Each poller **self-gates** — `provider_available()` (creds/CLI detection) + a `PROVIDER_ID`
  checked against `USAGE_PROVIDERS` (env, default `claude`) — and **exits 0 silently** when its
  provider is disabled or not installed (NOT installed ≠ expired token: an expired token still
  carries creds, so it stays the transient `⚠ offline`). This is why a missing/uninstalled provider
  never crashes or spams: keep that pattern when adding one. Gates are covered by
  `tests/poller-gate.sh`; `bin/cmux-sentinel-doctor.sh` reports installed × enabled × sentinel.
  Decision record: `.claude/research/2026-06-19-usage-provider-selection.md`.
- **Auto-refresh** needs `"automation": { "socketControlMode": "automation" }` in `cmux.json`. On the
  current build `reload-config` applies this **live** (proven: an external launchd kick landed its
  renames with no restart) — the earlier "needs a full cmux restart" note was outdated. If external
  (launchd) socket commands start getting rejected, the automation mode regressed → restart cmux.
  Every complete provider `--update` atomically records an epoch under
  `~/.local/state/cmux-sentinel/usage/`; doctor warns when an enabled provider has no success stamp
  or the last one is older than `USAGE_STALE_AFTER_SECONDS` (default 900, zero disables). Offline and
  read-only runs never advance the stamp, so "launchd loaded" cannot mask a stuck poller. A run whose
  DATA arrived but whose write partly failed does advance it — freshness is about the data, not about
  whether every sentinel still exists (next bullet).
- **A meter write failure is per-METER, and a fetch failure is CLASSIFIED.** Three ways the panel
  could lie for days, all found together on a user's install (2026-08-24). **(1)** The pollers wrote
  their sentinels in sequence and `die`d on the first failure, so ONE closed sentinel — an ordinary
  workspace anyone can close — froze every meter after it on whatever it last said. Real damage: a
  healthy fetch, a healthy `7d` row and a 5-minute launchd job, and `7d` still sat on a stale
  `⚠ offline` for 3½ days because every run aborted at the missing `5h`. All three pollers now keep a
  `MISSING`/`REJECTED` ledger, paint every sentinel they CAN resolve, and report once at the end.
  **(2)** Freshness and meter-presence are now SEPARATE signals: a meter that landed stamps
  `record_success` even when a sibling sentinel is gone, because "is data flowing" and "is the meter
  installed" are different questions — conflating them made one closed workspace read as a dead
  poller, and the stale warning's "run `--update`" advice then failed with the very same error. A
  REJECTED rename (cmux refused the write) is still a broken pipeline: no stamp. **(3)** The Claude
  poller's `fetch_usage` returns a failure CLASS as its **exit status** (`FETCH_AUTH`/`FETCH_RATE`/
  `FETCH_SERVER`/`FETCH_NET`) — it has to ride the exit status because the caller runs it inside a
  command substitution, where an assigned variable never escapes the subshell — so the sidebar shows
  `⚠ auth` (401/403: only Claude Code refreshes that token, this poller only reads it) vs
  `⚠ rate limit` (429: raise `StartInterval`) vs `⚠ api down` vs `⚠ offline`. Both 401s and 429s are
  real and common (34 and 19 respectively in one machine's launchd `.err`), and they need OPPOSITE
  fixes, which is why the old "token expired? endpoint changed? offline?" guess-list was useless. The
  response BODY is never printed — only the status, on stderr. Dropping `curl -f` is what makes the
  status readable; the parse tolerates a missing `-w` line and falls back to the exit code.
  Complementing it, `bin/cmux-sentinel-doctor.sh` reads the plist's `StandardErrorPath` and prints the
  newest `ERR:` line under a stale provider, so "stale — and now what?" answers itself. Regression
  tests: `tests/poller-gate.sh` T7–T9, `tests/sentinel-doctor.sh` T8.
- **`install.sh` FINISHES THE JOB — deploying files is not an install.** It used to copy files and
  print six manual steps; step 1 (`cmux-sentinel-setup.sh`) is idempotent, fail-open and needs no
  input, so leaving it manual bought nothing and cost everything: an UPDATE printed
  "✅ Files installed" and changed nothing visible, because the new release's meters had no
  workspaces. That is what a successful install looked like to the first person who updated.
  Setup now runs automatically, then every enabled provider is painted and the sidebar reloaded.
  **Because it is automatic, ITS failure modes are now the installer's** — all three steps are
  best-effort and NON-FATAL (no cmux on PATH, a cmux that refuses, no creds), each with a printed
  recovery, and `--no-setup`/`NO_SETUP=1` opts out. **`tests/install-hooks.sh` must pass
  `NO_SETUP=1` on every invocation**: it sandboxes `$HOME` but NOT `$PATH`, so without it
  `make test` reaches the developer's REAL cmux and creates REAL workspaces. T14 covers the
  skip/failure paths deliberately.
- **The installed version is stamped and reported.** `VERSION` in the repo → written to
  `~/.config/cmux-sentinel/VERSION` (version + date + short sha) at install; the doctor prints it
  and asks GitHub whether a newer one is published. Three constraints, each learned rather than
  assumed: the remote check is **fail-silent on every can't-tell path** (offline, rate limited, an
  HTML error page — a health report must never error because GitHub was slow); the comparison is
  **numeric per component** (`sort -t. -k1,1n -k2,2n -k3,3n`, so `0.10.0 > 0.9.0`, which a string
  compare gets wrong); and being **AHEAD** of the published version is not an update, or every dev
  machine gets nagged to downgrade. `CMUX_SENTINEL_UPDATE_CHECK=0` disables it. Keep `CHANGELOG.md`
  current with `VERSION` — the doctor's warning points at it.
- **launchd does not reread a changed loaded plist.** `install.sh` compares generated plist content,
  leaves unchanged jobs alone, and by default prints exact `bootout` + `bootstrap` commands for a
  changed+loaded job. `--reload-agents` / `RELOAD_AGENTS=1` explicitly performs only those targeted
  reloads. Do not cycle unchanged jobs or silently disrupt loaded agents on a plain install.
- **Installer backups are content-aware and bounded — keep them that way.** Re-running `install.sh`
  IS the documented update path (the curl bootstrap git-pulls and re-deploys *every* file), so the
  old unconditional `cp "$1" "$1.bak.$(date +%s)"` wrote one dead file per run: 48 had accumulated
  across the config dirs by 2026-08-10, which buries the one backup that actually matters. `bak()`
  now takes the incoming source as `$2` and **skips entirely when the bytes match**, then prunes to
  the newest `INSTALL_BAK_KEEP` (default 3). Every call site passes its source; only `$settings` and
  the plist path use the 1-arg form (the plist already does its own `cmp` first). If you add a
  deploy step, pass the source — otherwise you silently reintroduce the pile.
  Same class of bug, worse, in `register_hooks`: its jq `ensure` is idempotent, so the old order
  (back up → jq → `mv` → announce) rewrote `~/.claude/settings.json` **byte-identically on every
  run** — a junk backup each time (11 had accumulated) plus a false "RESTART Claude Code to load new
  hook events" instruction when nothing had been wired. It now renders to a temp file, `cmp`s, and
  returns "already wired" without touching the file. **Render-then-compare before you write** is the
  rule for every generated file here (the plist path always did it).
  Covered by `tests/install-hooks.sh` T12 + T13.

## Homebrew packaging (the tap)

The formula is a thin wrapper around what already exists — `install.sh` stays the ONE deployer.
Four things about it are non-obvious and each is a silent failure if you get it wrong:

- **`libexec.install Dir["*"]` — stage the WHOLE tree, not just `bin/`.** `install.sh` finds its
  payload relative to itself (it probes for `bin/cmux-claude-usage.sh` beside it), so a tree in
  `libexec` runs unmodified. That is why there is no second deployer to keep in sync.
- **`bin.write_exec_script`, never `bin.install_symlink`.** Through a symlink the dispatcher's `$0`
  stays in the prefix's `bin/`, where no `cmux-*.sh` helper lives, and every command fails to
  resolve. The generated wrapper `exec`s the real `libexec` path, so candidate #1 (beside the
  script) finds them. Pinned by `tests/entrypoint.sh` T7, which builds the layout by hand.
- **The launchd plists must keep pointing at `~/bin/*.sh`, never into the Cellar.** A Cellar path
  carries the version, so `brew upgrade` would break every loaded agent — and launchd holds its
  loaded definition, so the breakage is silent until the next reboot. This is also why `brew` alone
  cannot finish an upgrade: `cmux-sentinel deploy` re-runs the installer from the Cellar tree and
  refreshes `~/bin`. `update` REFUSES on a brew-managed copy (`*/Cellar/cmux-sentinel/*`) and names
  `brew upgrade` instead, so two updaters can't fight over `~/bin`.
- **The version stamp must not borrow an ancestor repo's git sha.** `git -C <dir> rev-parse` walks
  UP, and a formula unpacks under `/opt/homebrew`, which is itself a git repo — so the unguarded
  call stamped **Homebrew's** HEAD: a precise, confident, entirely unrelated sha. `install.sh` now
  trusts a sha only when `--show-toplevel` equals the tree it is installing from, and records
  `commit=unknown` otherwise (`tests/install-hooks.sh` T15).
- **`cmux-sentinel version` reports BOTH numbers on a brew install** — the deployed stamp (what
  launchd runs) and the Cellar version (what you just typed) — and warns when they differ. Print
  one and "I upgraded" / "it's still broken" are both true with no way to see it.
- **The "now run deploy" message goes in `post_install`, not `caveats`.** Homebrew prints `caveats`
  only on the FIRST install — and the upgrade is exactly when the message matters.

`make formula` (in `make check` and `ci`) keeps the committed formula honest, **offline**. It keys
on whether the version is TAGGED, not merely on whether it matches: the formula describes the LAST
RELEASE, so between a version bump and its tag it is legitimately behind — gating on equality alone
would fail the release commit itself. Once `v$VERSION` exists locally, regenerating is mandatory.
A missing formula is "not released yet"; a formula AHEAD of `VERSION` always fails (a bad revert).
A shallow CI checkout has no tags and lands in the lenient arm — the gate that matters runs locally,
where releases are cut.

## Conventions & security

- **Never commit secrets.** OAuth tokens are read from provider-owned local credential stores at
  runtime — keep them there. No tokens, no real workspace UUIDs, no usernames in committed files. (The sidebar carries
  no ids at all now — it matches sentinels by title label — so there's nothing to placeholder.)
- Dependency-light: bash + `jq` + `curl` + macOS `date`. Terse comments about *why*.
- **Run `make check` before proposing a commit** — shellcheck + the secret guard
  (`scripts/check-secrets.sh`) + markdownlint + offline tests + sidebar validation. `lefthook install` wires the same
  gates into git hooks; CI runs `make ci`. The secret guard is the load-bearing one (blocks real
  UUIDs / tokens / `/Users/<name>` paths and asserts the sidebar keeps its title-label meter anchors).
- See `CONTRIBUTING.md` for the dev loop and PR norms. (Maintainers may keep gitignored working
  docs under `.claude/` — e.g. `.claude/NOTES.local.md` with the full debugging history and
  `.claude/HANDOFF.md` for resuming a session — never committed.)
