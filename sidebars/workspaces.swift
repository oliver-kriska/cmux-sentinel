// Workspaces sidebar — flat, your manual order (by index). SF Mono.
// Palette: Ayu Mirage (matches the terminal theme).
//   bg #1F2430 · fg #D9D7CE · dim #8A9199 · orange #FFCC66 · blue #73D0FF
//   green #87D96C · red #F28779 · selection #33415E
//
// State is modeled as TWO INDEPENDENT dimensions, each on its own row:
//   1. Agent activity — compacting (purple) / working (green) / needs-you
//      (orange) / idle (dim). Compacting, waiting & working are read from STATIC
//      markers the bridge keeps at the FRONT of the TITLE ("⏳"=compacting,
//      "❓"=waiting-on-you, "⚡"=working); needs-you ALSO triggers on `unread`.
//      Precedence: compacting > waiting > working > needs-you(unread) > idle.
//      "Waiting" is the bridge's way of saying Claude asked a question / hit a
//      permission prompt — the row shows the orange needs-you treatment, not
//      green "Working…", because the session is parked on YOU.
//      (Why the title and not `progress`: cmux does NOT pass progress/description/
//      color to custom-sidebar data on this build — proven by probe. Why STATIC:
//      an animated marker in the title freezes cmux's sidebar — upstream #6291.
//      The bridge ref-counts agents per workspace so multiple Claude/Codex
//      sessions don't stomp the marker — see .claude/STATE-ARCHITECTURE.md.)
//   2. Repo state — branch · uncommitted · PR. Independent of any agent; its
//      own row so it never competes with activity for the line.
// Usage meters ride hidden "sentinel" workspaces (see isUsageMeter).

// ── predicates ────────────────────────────────────────────────────
func hasPR(_ w) -> Bool {
  return w.pr != nil && w.pr.label != nil && w.pr.label != ""
}
func hasBranch(_ w) -> Bool {
  return w.branch != nil && w.branch != ""
}
func hasProgress(_ w) -> Bool {
  return w.progress != nil && w.progress.value != nil
}
func hasProgressLabel(_ w) -> Bool {
  return hasProgress(w) && w.progress.label != nil && w.progress.label != ""
}

// ── dimension 1: agent activity ───────────────────────────────────
// "Working" is detected from a marker the bridge injects at the FRONT of the
// TITLE ("⚡ name"). cmux does NOT pass `progress`/`description`/`color` to
// custom-sidebar data on this build (proven by probe: progN=0/descN=0 even for
// the selected, working workspace), so the title is the only channel — and the
// interpreter's `.hasPrefix` works here (also proven), so we can detect it.
func isWorking(_ w) -> Bool {
  return w.title.hasPrefix("⚡")
}
// Compacting is a distinct busy sub-state: the bridge swaps the working marker
// for "⏳" while Claude compacts its context (PreCompact→PostCompact). Static
// glyph on purpose — an animated/spinner marker in the title freezes cmux's
// sidebar (upstream #6291). Precedence: compacting > working > needs-you > idle.
func isCompacting(_ w) -> Bool {
  return w.title.hasPrefix("⏳")
}
// Waiting: the bridge flips the marker to "❓" when Claude is BLOCKED on you —
// it asked a question (AskUserQuestion / ExitPlanMode) or hit a permission/idle
// prompt. The session is alive but parked, so this beats "working" and rides the
// orange needs-you treatment. Markers are mutually exclusive (one leading glyph),
// so isWaiting ⇒ !isWorking && !isCompacting.
func isWaiting(_ w) -> Bool {
  return w.title.hasPrefix("❓")
}
// needs-you = Claude is waiting on you (the ❓ marker) OR there are unread
// messages while no agent is mid-turn. Working/compacting outrank a bare unread.
func needsYou(_ w) -> Bool {
  if isCompacting(w) { return false }
  if isWaiting(w) { return true }
  if isWorking(w) { return false }
  return w.unread > 0
}
// Show working by COLOR, not the glyph: strip the leading "⚡" marker from the
// displayed title. `.split` keeps the rest of the name intact (spaces and all);
// cmux trims a leading zero-width space, so a visible marker + strip is the only
// way to get a clean title.
func displayTitle(_ w) -> String {
  if w.title.hasPrefix("⏳") {
    let parts = w.title.split(separator: "⏳")
    if parts.count > 0 { return String(parts[0]) }
    return ""
  }
  if w.title.hasPrefix("❓") {
    let parts = w.title.split(separator: "❓")
    if parts.count > 0 { return String(parts[0]) }
    return ""
  }
  if w.title.hasPrefix("⚡") {
    let parts = w.title.split(separator: "⚡")
    if parts.count > 0 { return String(parts[0]) }
    return ""
  }
  return w.title
}
func workLabel(_ w) -> String {
  if hasProgressLabel(w) { return w.progress.label }
  return "Working…"
}
func activityText(_ w) -> String {
  if isCompacting(w) { return "Compacting…" }
  if isWaiting(w) { return "asking…" }   // Claude asked a question / needs permission
  if isWorking(w) { return workLabel(w) }
  if needsYou(w) {
    if w.unread > 1 { return "needs you · \(w.unread)" }
    return "needs you"
  }
  return "idle"
}
func activityColor(_ w) -> String {
  if isCompacting(w) { return "#DFBFFF" }
  if isWorking(w) { return "#87D96C" }
  if needsYou(w) { return "#FFCC66" }
  return "#8A9199"
}
// SF Symbol for the activity row; "" = no icon (compared with == elsewhere).
// Working shows by colour alone (no icon — Oliver: "icon is too much, just colour").
func activityIcon(_ w) -> String {
  if needsYou(w) { return "bell.fill" }
  return ""
}

// ── dimension 2: repo / git state ─────────────────────────────────
func hasRepoInfo(_ w) -> Bool {
  if hasPR(w) { return true }
  if hasBranch(w) { return true }
  if w.dirty == true { return true }
  return false
}
// Dirty is shown as a compact yellow "*" in the row (native "main*" look), NOT
// spelled out — "uncommitted changes" truncates and eats the narrow line. So
// repoText carries only branch / PR label (+ stale); the "*" is appended below.
func repoText(_ w) -> String {
  if hasPR(w) {
    let stale = w.pr.stale == true ? " · stale" : ""
    return "\(w.pr.label)\(stale)"
  }
  if hasBranch(w) { return w.branch }
  return ""   // dirty-only row: just the branch icon + the yellow "*"
}
// Branch / PR label colour. Dirty no longer tints this (the yellow "*" carries it).
func repoColor(_ w) -> String {
  if hasPR(w) && w.pr.status == "open" { return "#73D0FF" }
  return "#8A9199"
}
// ── usage meters (hidden sentinels) ───────────────────────────────
// ONE predicate per provider, matched by the sentinel's TITLE LABEL (not a
// workspace id). cmux 0.64.15 removed stable workspace UUIDs — the only handle
// is a positional ref that rotates on every app restart, so an id hard-coded
// here would go stale each restart and the meters would silently fall back into
// the normal list. The poller keeps each sentinel's title starting with its
// label ("5h "/"7d "), `.hasPrefix` works in the interpreter (proven), and the
// bridge prefixes real agent workspaces with ⚡/⏳ (never a bare label), so the
// label is a collision-free, restart-proof anchor both sides share.
func isClaudeMeter(_ w) -> Bool {
  if w.title == "5h" { return true }           // bare bootstrap label (before the first poll paints a bar)
  if w.title.hasPrefix("5h ") { return true }  // Claude — 5h session window
  if w.title == "7d" { return true }           // bare bootstrap label (before the first poll paints a bar)
  if w.title.hasPrefix("7d ") { return true }  // Claude — 7d weekly window
  return false
}
// Codex provider — same shape as isClaudeMeter, distinct labels so the two never
// collide ("cx5h"/"cx7d" never start with "5h "/"7d "). Fed by bin/cmux-codex-usage.sh,
// which reads ~/.codex rate_limits (primary=5h, secondary=weekly).
func isCodexMeter(_ w) -> Bool {
  if w.title == "cx5h" { return true }           // bare bootstrap label
  if w.title.hasPrefix("cx5h ") { return true }  // Codex — 5h window (primary)
  if w.title == "cx7d" { return true }           // bare bootstrap label
  if w.title.hasPrefix("cx7d ") { return true }  // Codex — weekly window (secondary)
  return false
}
func isUsageMeter(_ w) -> Bool {
  if isClaudeMeter(w) { return true }
  if isCodexMeter(w) { return true }
  return false
}

// ── row visuals ───────────────────────────────────────────────────
func accentColor(_ w) -> String {
  if isCompacting(w) { return "#DFBFFF" }
  if isWorking(w) { return "#87D96C" }
  if needsYou(w) { return "#FFCC66" }
  return "#73D0FF"
}
func accentOpacity(_ w) -> Double {
  if w.selected { return 1.0 }
  if isCompacting(w) { return 0.9 }
  if isWorking(w) { return 0.9 }
  if needsYou(w) { return 0.9 }
  return 0.0
}
func rowFill(_ w) -> String {
  if w.selected { return "#33415E" }
  if isCompacting(w) { return "#DFBFFF" }
  if isWorking(w) { return "#87D96C" }
  if needsYou(w) { return "#FFCC66" }
  return "#000000"
}
func rowFillOpacity(_ w) -> Double {
  if w.selected { return 0.85 }
  if isCompacting(w) { return 0.12 }
  if isWorking(w) { return 0.12 }
  if needsYou(w) { return 0.08 }
  return 0.06
}

func row(_ w) -> some View {
  VStack(spacing: 0) {
    Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
      HStack(alignment: .top, spacing: 10) {
        Capsule().frame(width: 3, height: 26)
          .foregroundColor(accentColor(w))
          .opacity(accentOpacity(w))
        VStack(alignment: .leading, spacing: 2) {
          Text(displayTitle(w))
            .font(.system(size: 14, design: .monospaced))
            .fontWeight(w.selected ? .bold : .medium)
            .foregroundColor(w.selected ? "#FFFFFF" : "#D9D7CE")
            .lineLimit(2).multilineTextAlignment(.leading)
          // dimension 1 — agent activity
          HStack(spacing: 5) {
            if activityIcon(w) != "" {
              Image(systemName: activityIcon(w)).font(.system(size: 9)).foregroundColor(activityColor(w))
            }
            Text(activityText(w))
              .font(.system(size: 11, design: .monospaced))
              .foregroundColor(activityColor(w))
              .lineLimit(1).truncationMode(.tail)
          }
          // dimension 2 — repo / git state (its own row, only when present).
          // Dirty = a compact yellow "*" trailing the branch (native "main*"), not prose.
          if hasRepoInfo(w) {
            HStack(spacing: 4) {
              Image(systemName: "arrow.triangle.branch").font(.system(size: 9)).foregroundColor("#6E7787")
              Text(repoText(w))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(repoColor(w))
                .lineLimit(1).truncationMode(.tail)
              if w.dirty == true {
                Text("*").font(.system(size: 12, design: .monospaced)).bold().foregroundColor("#FFCC66")
              }
            }
          }
        }
        Spacer()
        if w.unread > 0 {
          Text("\(w.unread)")
            .font(.system(size: 10, design: .monospaced)).bold()
            .foregroundColor("#1F2430").padding(4)
            .background { Circle().foregroundColor("#FFCC66") }
        }
        Button(action: { cmux("workspace.close", workspace_id: w.id) }) {
          Image(systemName: "xmark")
            .font(.system(size: 12)).foregroundColor("#6E7787")
            .frame(width: 22, height: 22)
        }
      }
      .padding(8)
      .background { RoundedRectangle(cornerRadius: 0).foregroundColor(rowFill(w)).opacity(rowFillOpacity(w)) }
    }
    .contextMenu {
      Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
        Label("Open", systemImage: "arrow.right.circle")
      }
      if w.pinned {
        Button(action: { cmux("workspace.action", workspace_id: w.id, action: "unpin") }) {
          Label("Unpin", systemImage: "pin.slash")
        }
      } else {
        Button(action: { cmux("workspace.action", workspace_id: w.id, action: "pin") }) {
          Label("Pin", systemImage: "pin")
        }
      }
      Menu("Color") {
        Button(action: { cmux("workspace.action", workspace_id: w.id, action: "set-color", color: "#FFCC66") }) { Text("Orange") }
        Button(action: { cmux("workspace.action", workspace_id: w.id, action: "set-color", color: "#73D0FF") }) { Text("Blue") }
        Button(action: { cmux("workspace.action", workspace_id: w.id, action: "set-color", color: "#87D96C") }) { Text("Green") }
        Button(action: { cmux("workspace.action", workspace_id: w.id, action: "set-color", color: "#F28779") }) { Text("Red") }
        Button(action: { cmux("workspace.action", workspace_id: w.id, action: "clear-color") }) { Text("Clear color") }
      }
      Button(action: { cmux("workspace.action", workspace_id: w.id, action: "move-up") }) {
        Label("Move up", systemImage: "arrow.up")
      }
      Button(action: { cmux("workspace.action", workspace_id: w.id, action: "move-down") }) {
        Label("Move down", systemImage: "arrow.down")
      }
      Button(action: { cmux("workspace.action", workspace_id: w.id, action: "move-top") }) {
        Label("Move to top", systemImage: "arrow.up.to.line")
      }
      Divider()
      Button(action: { cmux("workspace.close", workspace_id: w.id) }) {
        Label("Close", systemImage: "xmark")
      }
    }
    Divider()
  }
}

// ── layout ────────────────────────────────────────────────────────
VStack(alignment: .leading, spacing: 0) {
  HStack(spacing: 10) {
    Text("Workspaces").font(.system(size: 14, design: .monospaced)).bold()
      .foregroundColor("#D9D7CE")
    Spacer()
    if workspaces.filter { isCompacting($0) }.count > 0 {
      HStack(spacing: 4) {
        Image(systemName: "hourglass").font(.system(size: 10)).foregroundColor("#DFBFFF")
        Text("\(workspaces.filter { isCompacting($0) }.count)")
          .font(.system(size: 11, design: .monospaced)).bold().foregroundColor("#DFBFFF")
      }
    }
    if workspaces.filter { isWorking($0) }.count > 0 {
      HStack(spacing: 4) {
        Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundColor("#87D96C")
        Text("\(workspaces.filter { isWorking($0) }.count)")
          .font(.system(size: 11, design: .monospaced)).bold().foregroundColor("#87D96C")
      }
    }
    if workspaces.filter { needsYou($0) }.count > 0 {
      HStack(spacing: 4) {
        Image(systemName: "bell.fill").font(.system(size: 10)).foregroundColor("#FFCC66")
        Text("\(workspaces.filter { needsYou($0) }.count)")
          .font(.system(size: 11, design: .monospaced)).bold().foregroundColor("#FFCC66")
      }
    }
    Text(clock.time).font(.system(size: 11, design: .monospaced)).foregroundColor("#707A8C")
  }
  .padding(9)
  Divider()

  // CLAUDE USAGE — one labelled section per provider (same component reused).
  // Meters sort by WINDOW length (the short 5h/cx5h above the weekly 7d/cx7d), not
  // by workspace .index — index depends on sentinel creation order and reshuffles
  // across restarts, which would flip the rows. The 5h sentinels carry "5h" in the
  // title; the weekly ones don't.
  if workspaces.filter { isClaudeMeter($0) }.count > 0 {
    VStack(alignment: .leading, spacing: 6) {
      Text("CLAUDE USAGE").font(.system(size: 10, design: .monospaced)).bold().foregroundColor("#8A9199")
      ForEach(workspaces.filter { isClaudeMeter($0) }.sorted { $0.title.contains("5h") && !$1.title.contains("5h") }) { w in
        Text(w.title)
          .font(.system(size: 12, design: .monospaced))
          .foregroundColor("#CCCAC2")
      }
    }
    .padding(9)
    Divider()
  }

  // CODEX USAGE — same component; hidden unless Codex sentinels exist, so it stays
  // invisible for Claude-only users. Fed by bin/cmux-codex-usage.sh.
  if workspaces.filter { isCodexMeter($0) }.count > 0 {
    VStack(alignment: .leading, spacing: 6) {
      Text("CODEX USAGE").font(.system(size: 10, design: .monospaced)).bold().foregroundColor("#8A9199")
      ForEach(workspaces.filter { isCodexMeter($0) }.sorted { $0.title.contains("5h") && !$1.title.contains("5h") }) { w in
        Text(w.title)
          .font(.system(size: 12, design: .monospaced))
          .foregroundColor("#CCCAC2")
      }
    }
    .padding(9)
    Divider()
  }

  // WORKSPACES — labelled section header + count, then the list. This is the
  // delimiter between the usage panel and the workspace list.
  HStack(spacing: 8) {
    Text("WORKSPACES").font(.system(size: 10, design: .monospaced)).bold().foregroundColor("#8A9199")
    Spacer()
    Text("\(workspaces.filter { !isUsageMeter($0) }.count)")
      .font(.system(size: 10, design: .monospaced)).foregroundColor("#6E7787")
  }
  .padding(9)
  Divider()

  // Drag-and-drop reorder (persisted) — the supported way to make the list
  // draggable; the drop sends workspace_id + target index to workspace.reorder.
  Reorderable(workspaces.filter { !isUsageMeter($0) }.sorted { $0.index < $1.index }, move: "workspace.reorder") { w in
    row(w)
  }
  Spacer()
}
