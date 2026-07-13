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
| --- | --- | --- |
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

**Terminal Threads (non-ACP) already do most of the panel you want.** A "Terminal Thread"
(`zed.dev/blog/terminal-threads`) is a *plain terminal scoped to a project* — NO ACP agent — shown
in the Threads Sidebar grouped by project, with an auto-updating title, a status icon, and
click-to-focus, across all open projects. Run each agent as a Terminal Thread and you get the
project→terminal tree today, no fork. **Caveat (see the OSC correction below):** the native
Terminal-Thread title is *process-derived*, so it shows e.g. "claude — node", NOT our rich
⚡/⏳/❓ working/waiting/compacting semantics. If a process-name title is enough, use Terminal
Threads and skip the fork; if you want the rich agent-state markers, that's what the custom panel
below adds.

---

## Reusable core (editor-agnostic) — belongs in THIS repo

Regardless of fork-vs-no-fork, two pieces port straight over and should live here so cmux and Zed
share one data layer:

- **Status bridge** — `hooks/cmux-bridge.sh` turns Claude Code hook events into
  ⚡ working / ⏳ compacting / ❓ waiting-on-you with a precedence rule, writing to cmux's title
  channel. **Shipped: `hooks/zed-bridge.sh`** is the cmux-free Zed counterpart (same event→state
  precedence, no cross-session ref-count since each agent owns its tty) with two sinks:
  - **OSC** (default) → emits `\e]2;<marker> <title>\007` to the agent's tty, so status shows on
    the **Zed terminal tab** today with **no fork** (Zed honours OSC 2, confirmed).
  - **FILE** (default) → writes `$ZED_SENTINEL_STATE_DIR/<session>.json`
    (`{state, marker, title, project, session, pid, updated}`) — the channel a native Zed panel
    watches via `Fs::watch`. Toggle each with `ZED_SENTINEL_OSC=0` / `ZED_SENTINEL_FILE=0`; pin the
    tab label with `ZED_SENTINEL_TITLE`. Covered by `tests/zed-bridge.sh` (in `make test`).
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

- Trait + dock types: `crates/workspace/src/dock.rs` — the `Panel` trait
  (supertraits `Focusable`, `EventEmitter<PanelEvent>`, `Render`) and `DockPosition`
  (`Left`/`Bottom`/`Right`). Required methods: `persistent_name`, `panel_key`, `position`,
  `set_position`, `position_is_valid`, `default_size`, `icon`, `icon_tooltip`, `toggle_action`,
  `activation_priority`.
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

### Terminal-centric panel — the exact data path (if we build it)

Target: a left-dock tree of **project → its terminal tabs**, each agent tab showing status. Data path:

1. **All projects:** get the window's `MultiWorkspace` (`crates/workspace/src/multi_workspace.rs`);
   iterate `mw.workspaces()` → one node per project `Entity<Workspace>`.
2. **Per project → terminals:** `ws.read(cx).panel::<TerminalPanel>(cx)`, walk `center.panes()` →
   `pane.read(cx).items()` → downcast to `Entity<TerminalView>` → `.read(cx).terminal()`. Keep
   `(Entity<Pane>, item_index)` for click-to-focus.
3. **Per terminal fields** (`crates/terminal/src/terminal.rs`): `breadcrumb_text` (**where OSC-2 lands
   — our ⚡/⏳/❓**; `title()` does NOT read it, it's process-derived), `working_directory()` (associate
   to a worktree), `pid()`. **Subtle:** the native tab label ignores OSC, so to show our markers the
   panel reads `breadcrumb_text` OR our JSON status file (matched by `pid`/`project`).
4. **Live updates:** `cx.subscribe(&term, …)` on `Event::BreadcrumbsChanged` / `Event::TitleChanged`.
5. **Click a row:** `pane.update(cx, |p, cx| p.activate_item(ix, true, true, window, cx))` (activate the
   owning workspace + open the `TerminalPanel` dock first if inactive).
6. **"+" per project:** `terminal_panel.update(cx, |p, cx| p.add_terminal_shell(Some(root), …))`.

**But first weigh Terminal Threads:** a Terminal Thread is a plain, non-ACP terminal already shown in
the Threads Sidebar grouped by project, with title + status icon + click-to-focus. It gives the tree
for free — only weakness is a process-derived title (not our rich state). Fork only if the rich
⚡/⏳/❓ markers matter more than reusing the native sidebar.

---

## The ACTUAL pain (2026-07-13) — fast cmux→Zed project/worktree handoff

User feedback reframed the goal: **cmux stays the home for terminals/agents; Zed is wanted only for
file-editing + git UI/history.** The friction is the handoff — switching Zed to the *right project +
worktree* means window-switch → project picker → worktree picker by hand. That is NOT a fork problem.

**Key fact:** `zed <path>` already **opens the folder into the CURRENT Zed window and switches to
that project in-place** (default in 0.234; `-n` new window, `-a` add as extra root, `-r` reuse).
Passing an exact git-worktree path opens that worktree as the project. So the manual dance is
replaceable by one command run from the cmux terminal (whose `$PWD` already *is* the worktree).

**Proposed integration (tiny, no fork):** `bin/cmux-open-in-zed.sh` — resolve the current cmux
workspace's worktree root and `exec zed` it; bind it to a cmux key / shell alias so one keystroke
jumps Zed to exactly what you're working on. Optional `--add` for multi-root. This solves the stated
pain directly and makes the status/usage panel work genuinely optional.

---

## Recommendation (updated)

Given the reframed pain, the priority order is:

1. **Build `bin/cmux-open-in-zed.sh` + a cmux keybind** — the one-keystroke cmux→Zed handoff to the
   right project/worktree. Smallest possible change, solves the actual annoyance, no fork.
2. **Usage TUI pane** (reuse the pollers) if you still want meters visible while in Zed.
3. **The terminal-centric panel fork** is now *optional* — only if, after living with #1, you still
   want cmux's full status rail replicated inside Zed rather than glancing back at cmux.

The shell-side work (bridge sinks, pollers, open-in-zed) stays shared between cmux and Zed, so the
handoff is a config/keybind, not a second codebase.

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
