# Zed fork research — porting the cmux-sentinel workflow to Zed

**Date:** 2026-07-12 · **Branch:** `claude/zed-fork-cmux-features-dbrqv8`

Goal: reproduce, in Zed, the cmux workflow the user relies on — **see the status of agents
running per project/workspace, have multiple terminals per project, switch between projects,
open files like a normal IDE, and see AI usage meters** — with no need for cmux's embedded browser.

The user runs agents as **terminal processes** (Claude Code / Codex in a shell), *not* as Zed's
ACP agent threads (ACP is "not useful" and may soon stop working with Claude Code). So the design
must key off terminal-run agents, the same way `hooks/cmux-bridge.sh` does today.

---

## TL;DR — the goalposts moved

Zed shipped **Parallel Agents** (blog 2026-04-22, ~0.233.x, refined through 0.234.x). That release
replaced the old *one-project-per-window* model with **`MultiWorkspace`**: one window now holds
**multiple projects**, switchable in-window via a left-docked **Threads Sidebar**, with agent
threads grouped by repository / git worktree. As a result, **most of the "switching" workflow the
fork was meant to add already exists natively.**

What that means for us:

| Need | Stock Zed 0.234+ | Verdict |
|---|---|---|
| Multiple terminals per project | Terminal panel: tabs + splits; "Terminal Threads" grouped per project in the sidebar | ✅ native |
| Switch between projects/workspaces in one window | `MultiWorkspace` + Threads Sidebar (`NextProject`/`PreviousProject`, `projects::OpenRecent` in-window swap, Cmd+Enter = new window) | ✅ native |
| Open files of any project like a normal IDE | Project panel (multi-root), `cmd-p` fuzzy open | ✅ native |
| Per-worktree parallel agents | Parallel Agents: per-thread git-worktree isolation, auto-cleanup on archive | ✅ native |
| **Status of terminal-run agents in the sidebar** | Only *ACP threads* show status (Idle/Generating). Plain terminal agents don't get a status row. | ⚠️ **gap** |
| **AI usage meters (5h/7d, Codex)** | Nothing. Only a per-conversation context-window circle + a process CPU/mem monitor PR (#60096). | ❌ **gap** |
| Named / saved workspaces | Zed keys workspaces only by folder path + internal `WorkspaceId`; no user-facing name | ❌ gap (minor) |

**The fork's remaining justification is small and well-scoped:** (1) status for terminal-run
agents, and (2) usage meters. Everything else is either native or a thin config recipe.

---

## Step 0 — evaluate stock Zed 0.234+ FIRST

Before writing any Rust, confirm how much of the workflow stock Zed already delivers:

1. Update to Zed ≥ 0.234. Enable the new Parallel Agents layout (opt-in for existing users).
2. Add your projects to one window ("Add Project" → local folders; or `zed a b c`).
3. Run each agent in a **terminal** inside its project. Toggle the Threads Sidebar
   (`option-cmd-j` / `ctrl-option-j`); cycle projects with `NextProject`/`PreviousProject`.
4. For parallel branches, use **Parallel Agents** per-thread git-worktree isolation.

If terminal agents surfaced as "Terminal Threads" in the sidebar carry an **OSC-title status**
(set by our hook, see below) that Zed renders, you may not need a fork for status either — only
for usage.

---

## Reusable core (editor-agnostic) — belongs in THIS repo

Regardless of fork-vs-no-fork, two pieces port straight over and should live here so cmux and Zed
share one data layer:

- **Status bridge** — `hooks/cmux-bridge.sh` already turns Claude Code hook events into
  ⚡ working / ⏳ compacting / ❓ waiting-on-you with a precedence rule. Only the *output sink* is
  cmux-specific (`cmux rename-workspace`). Add pluggable sinks:
  - `SINK=osc` → emit `\e]2;<marker> <title>\007` to the agent's tty (Zed terminal tab title;
    confirmed Zed honours OSC 2). Works with **no fork** for per-tab status.
  - `SINK=file` → write a per-workspace status file (e.g. `$XDG_RUNTIME_DIR/zed-sentinel/<ws>.json`
    with `{state, title, provider, updated}`). This is what a native Zed panel would watch.
- **Usage pollers** — `bin/cmux-claude-usage.sh` / `bin/cmux-codex-usage.sh` are already
  editor-agnostic. Two rendering sinks:
  - a `bin/*-usage-tui.sh` `watch`-style loop rendering the Unicode block bars in one dedicated
    Zed terminal pane (no fork), and/or
  - the same JSON status-file for a native panel to read.

Do this first — it's a strict subset of the fork's needs and immediately usable.

---

## Option B — the Zed fork ("Workspaces" panel)

If the sidebar status gap and usage meters matter enough, add a native panel. The research below is
the implementation map.

### What to build on (don't reinvent)

- **`MultiWorkspace`** (`crates/workspace/src/multi_workspace.rs`) — window holds many `Workspace`
  (project) entities; `active_workspace`, `retained_workspaces`, `project_groups`; switching via
  `activate`/`cycle_project`/`NextProject`. Landed via **PR #52863**.
- **Project grouping setting** — **PR #59965** (`project_grouping` by repository/worktree). Read the
  same grouping so our panel matches Zed's.
- **Worktree↔thread association** — **PR #54947** (group threads by linked git worktree) and the
  live **PR #60776** (keep threads pinned to their worktree group). Read #60776 closely.
- **Git worktree primitives** — worktree picker + `git: worktree` command, `git.worktree_directory`
  setting, `create_worktree` task hook (`ZED_WORKTREE_ROOT`, `ZED_MAIN_GIT_WORKTREE`). Foundation
  from **PR #20164** (closed #4670). Bare-repo + naming edge cases: #54553, #57677, #54026 (open).

### Panel architecture (the `Panel` trait is STABLE — safe to implement against)

- Trait + dock types: `crates/workspace/src/dock.rs` (`Panel: Focusable + EventEmitter<PanelEvent>
  + Render`, `DockPosition::{Left,Bottom,Right}`). Required methods: `persistent_name`, `panel_key`,
  `position`/`set_position`/`position_is_valid`, `default_size`, `icon`, `icon_tooltip`,
  `toggle_action`, `activation_priority`.
- Mount API: `Workspace::add_panel` (`crates/workspace/src/workspace.rs`); orchestrated in
  `crates/zed/src/zed.rs::initialize_panels` via `add_panel_when_ready`; per-panel `init(cx)`
  called from `crates/zed/src/main.rs`.
- **Fork template:** `crates/project_panel/src/project_panel.rs` (closest match — tree of roots,
  `uniform_list`, selection, click-to-open). Full real `impl Panel`:
  `crates/terminal_view/src/terminal_panel.rs`.
- Enumerate projects/worktrees: `crates/project/src/project.rs`
  (`worktrees`, `visible_worktrees`, `worktree_root_names`). Cross-**window** enumeration:
  `cx.windows()` downcast, or — better for us — the external status file.
- **Watch the external status file** with `Fs::watch` (`crates/fs/src/fs.rs`, returns a
  `Stream<Vec<PathEvent>>` + `Arc<dyn Watcher>`); on each event `reload_status(cx); cx.notify();`.
  This is exactly how a poller/hook feeds the panel — same shape as cmux-sentinel today.
- Open on click: `Workspace::open_path`/`open_abs_path` (same window) or `Workspace::new_local` /
  `workspace::open_paths` (cross-project / new window).

### New-crate wiring (minimal change set)

1. `crates/workspaces_panel/{Cargo.toml, src/workspaces_panel.rs}` (deps: workspace, project, gpui,
   ui, settings, fs, db, serde, anyhow, util).
2. Root `Cargo.toml` → add to `[workspace] members`.
3. `crates/zed/Cargo.toml` → `workspaces_panel.workspace = true`.
4. `crates/zed/src/main.rs` → `workspaces_panel::init(cx);`.
5. `crates/zed/src/zed.rs` → load + `add_panel_when_ready` in `initialize_panels`.
6. Actions + optional keymap entry. **No changes to `crates/workspace` itself.**

(A working skeleton `impl Panel` + `Render` with `uniform_list` is in the session notes; fork
`project_panel.rs` for real row rendering and status dots via `ui` crate `Icon`/`Indicator`.)

### Design decision: separate panel vs. extend the Threads Sidebar

The Threads Sidebar is *already* a cross-project, per-worktree sidebar — our "Workspaces panel"
overlaps it. The workspace/sidebar area is **HOT** (eholk/eth0net/ytaben iterating Apr–Jul 2026;
open follow-ups #56316, #56414, #57254, #58608, #59773, #60524, #60776). Guidance:

- **Prefer a separate dock panel that is a pure READER** of workspace/project/worktree state + our
  status file. That isolates us from churn in the sidebar code. (The resource-monitor PR #60096
  even chose a workspace *item/tab* over a dock panel to dodge dock churn — a valid alternative.)
- Avoid modifying the git panel or Threads Sidebar code directly — treat them as data sources.

### Fork hygiene / timing

- **Base the fork on `main` AFTER commit `74b5207` (PR #58087, 2026-07-08)** — the GPUI
  "Unify Render and RenderOnce into View" refactor touches every panel `impl`. Forking before it
  means reworking all render code.
- Panel/dock trait: **stable** — no in-flight rework. Workspace/sidebar/git-panel: **hot** — read,
  don't fork. Agent/ACP status: **no clean bindable status API** — derive status ourselves (which we
  already do via hooks). ACP "elicitations" (merged `fbceb28`) are the closest "waiting-on-you"
  signal if we ever want it.

### Greenfield: usage meters

No Zed equivalent exists or is in flight (the only "usage" surface is process CPU/mem, #60096).
Render the pollers' bars in the panel from the status-file JSON. Low collision risk.

---

## Recommendation

1. **Ship the reusable core here first** (pluggable sinks in the bridge + a usage TUI + a status-file
   writer). No fork, immediately useful, and it's the data layer the fork depends on anyway.
2. **Live in stock Zed 0.234+** using the recipe in Step 0. Measure the real gap.
3. **Only if the gap bites**, build the **reader-style Workspaces dock panel** on a fork based after
   `#58087`, watching the status file — never modifying the churning sidebar/git code.

This is low-regret: every step is a subset of the next, and the shell-side work is shared between
cmux and Zed so "switching between them" stays a config flag, not a second codebase.

---

## Source index (key PRs / commits / docs)

- Parallel Agents: blog `zed.dev/blog/parallel-agents` (2026-04-22), docs `zed.dev/docs/ai/parallel-agents`
- Multi-project window: PR #52863 (MultiWorkspace), #59965 (`project_grouping`), docs PR #51702;
  `zed.dev/docs/windows-and-projects`
- Worktree/threads: #54947, #60776, #56316; worktree base #20164 (closed #4670); edge cases #54553,
  #57677, #54026
- Panels: `crates/workspace/src/dock.rs`, `crates/zed/src/zed.rs`, `crates/project_panel/…`,
  `crates/terminal_view/src/terminal_panel.rs`; new-panel ref PR #53239; usage-as-tab PR #60096
- Fork-base commit: `74b5207` / PR #58087 (Render/RenderOnce → View, 2026-07-08)
- Status/ACP: elicitations `fbceb28`; no bindable agent-status API yet
