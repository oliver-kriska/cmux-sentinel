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
//      (Why the title and not `progress` for agent state: the title is the
//      persistent, restart-proof anchor and encodes the marker-precedence order;
//      `progress` DOES reach the sidebar on 0.64.17 — meters use it — but it's
//      transient. Why STATIC: an animated marker in the title freezes cmux's
//      sidebar — upstream #6291. The bridge ref-counts agents per workspace so
//      multiple Claude/Codex sessions don't stomp the marker — see
//      .claude/STATE-ARCHITECTURE.md.)
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
// TITLE ("⚡ name"). Agent state rides the title (not `progress`) because it must
// be persistent and precedence-ordered; `progress` reaches the sidebar on 0.64.17
// but is transient (meters use it — see meterRow). The interpreter's `.hasPrefix`
// works here (proven), so we detect the marker on the title.
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
// Idle repo rows already communicate useful state below the title; repeating
// literal "idle" makes the list taller without adding information. Keep it only
// for empty rows, while all actionable/active states always get an activity line.
func showsActivity(_ w) -> Bool {
  if isCompacting(w) { return true }
  if isWorking(w) { return true }
  if needsYou(w) { return true }
  if hasRepoInfo(w) { return false }
  return true
}
func titleLineLimit(_ w) -> Int {
  if w.selected { return 2 }
  if isCompacting(w) { return 2 }
  if isWorking(w) { return 2 }
  if needsYou(w) { return 2 }
  return 1
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
// workspace id). 0.64.15 removed stable workspace UUIDs, leaving only a positional
// ref that rotates on every app restart, so an id hard-coded here would go stale
// each restart and the meters would silently fall back into the normal list.
// 0.64.22 populates `w.id` again, but it is not a proven-durable handle (no public
// `stableId`) and a hard-coded id would still need a reinstall to change — the
// label needs neither. The poller keeps each sentinel's title starting with its
// label ("5h "/"7d "), `.hasPrefix` works in the interpreter (proven), and the
// bridge prefixes real agent workspaces with ⚡/⏳ (never a bare label), so the
// label is a collision-free, restart-proof anchor both sides share.
func isClaudeMeter(_ w) -> Bool {
  if w.title == "5h" { return true }           // bare bootstrap label (before the first poll paints a bar)
  if w.title.hasPrefix("5h ") { return true }  // Claude — 5h session window
  if w.title == "7d" { return true }           // bare bootstrap label (before the first poll paints a bar)
  if w.title.hasPrefix("7d ") { return true }  // Claude — 7d weekly window
  // Per-MODEL weekly cap (e.g. a Fable-scoped allowance), opt-in via
  // CLAUDE_MODEL_METER=1. The MODEL NAME is never part of the anchor — it rides
  // the title's detail text, because the anchor must be a static literal here and
  // Anthropic re-scopes which model is capped at will.
  if w.title == "m7d" { return true }           // bare bootstrap label
  if w.title.hasPrefix("m7d ") { return true }  // Claude — model-scoped weekly window
  return false
}
// Codex provider — same shape as isClaudeMeter, distinct labels so the two never
// collide. bin/cmux-codex-usage.sh reads ChatGPT account usage and routes windows
// by numeric duration (never by unstable primary/secondary position).
func isCodexMeter(_ w) -> Bool {
  if w.title == "cx5h" { return true }           // bare bootstrap label
  if w.title.hasPrefix("cx5h ") { return true }  // Codex — short/session window
  if w.title == "cx7d" { return true }           // bare bootstrap label
  if w.title.hasPrefix("cx7d ") { return true }  // Codex — weekly window
  return false
}
// Amp provider — fed by bin/cmux-amp-usage.sh, which scrapes `amp usage`.
// Labels are distinct from every other provider's ("ampu"/"ampo" can't collide
// with "5h "/"7d "/"cx5h "/"cx7d "). Unlike the others these are NOT rolling time
// windows but one monthly subscription allowance: "ampu" = agent/thread usage,
// "ampo" = orb (remote machine) usage. "ampo" only exists when the user opted in
// with AMP_ORB_METER=1 — a sentinel costs a ⌘ key, so it isn't created by default.
func isAmpMeter(_ w) -> Bool {
  if w.title == "ampu" { return true }           // bare bootstrap label
  if w.title.hasPrefix("ampu ") { return true }  // Amp — subscription agent usage
  if w.title == "ampo" { return true }           // bare bootstrap label
  if w.title.hasPrefix("ampo ") { return true }  // Amp — orb usage (opt-in)
  return false
}
func isUsageMeter(_ w) -> Bool {
  if isClaudeMeter(w) { return true }
  if isCodexMeter(w) { return true }
  if isAmpMeter(w) { return true }
  return false
}

// ── native meter row (progress channel) ───────────────────────────
// The poller writes each sentinel's utilization via `set-progress` (value 0..1 +
// a clean label), which cmux 0.64.17 passes to the interpreter (null-until-set —
// see .claude/research/2026-07-06-conductor-sidebar-analysis.md). So a meter is a
// NATIVE ProgressView, not a unicode-block bar baked into the title. The title
// stays the anchor (isClaudeMeter/resolve_ref) AND the fallback shown here
// whenever progress is absent (bootstrap, offline-cleared, a dropped write, or
// the first poll after an app restart).
func meterWindow(_ w) -> String {   // human label; title anchor remains unchanged
  if w.title == "5h" { return "session" }
  if w.title.hasPrefix("5h ") { return "session" }
  if w.title == "7d" { return "week" }
  if w.title.hasPrefix("7d ") { return "week" }
  if w.title == "cx5h" { return "session" }
  if w.title.hasPrefix("cx5h ") { return "session" }
  if w.title == "cx7d" { return "week" }
  if w.title.hasPrefix("cx7d ") { return "week" }
  if w.title == "ampu" { return "threads" }
  if w.title.hasPrefix("ampu ") { return "threads" }
  if w.title == "ampo" { return "orbs" }
  if w.title.hasPrefix("ampo ") { return "orbs" }
  return "usage"
}
func meterTint(_ w) -> String {     // color-from-data: red ≥90%, amber ≥70%, else blue
  if hasProgress(w) {
    if w.progress.value >= 0.9 { return "#F28779" }
    if w.progress.value >= 0.7 { return "#FFCC66" }
  }
  return "#73D0FF"
}
// Poller title fallback protocol: "<anchor> |<detail>|<unicode bar>". The space
// before the first delimiter preserves every existing "<label> " identity match;
// the single-character split avoids provider-specific prefix parsing entirely.
// Old pre-protocol titles show "refreshing…" until the next poll migrates them.
func meterFallbackDetail(_ w) -> String {
  if w.title == "5h" { return "waiting…" }
  if w.title == "7d" { return "waiting…" }
  if w.title == "cx5h" { return "waiting…" }
  if w.title == "cx7d" { return "waiting…" }
  if w.title == "ampu" { return "waiting…" }
  if w.title == "ampo" { return "waiting…" }
  let parts = w.title.split(separator: "|")
  if parts.count > 1 { return String(parts[1]) }
  return "refreshing…"
}
func meterFallbackBar(_ w) -> String {
  let parts = w.title.split(separator: "|")
  if parts.count > 2 { return String(parts[2]) }
  return ""
}
func meterRow(_ w) -> some View {
  VStack(alignment: .leading, spacing: 3) {
    if hasProgress(w) {
      HStack(spacing: 6) {
        Text(meterWindow(w))
          .font(.system(size: 12, design: .monospaced)).foregroundColor("#CCCAC2")
        Spacer()
        if hasProgressLabel(w) {
          Text(w.progress.label)
            .font(.system(size: 11, design: .monospaced)).foregroundColor("#8A9199")
            .lineLimit(1).truncationMode(.tail).multilineTextAlignment(.trailing)
        }
      }
      ProgressView(value: w.progress.value).tint(meterTint(w))
    } else {
      HStack(spacing: 6) {
        Text(meterWindow(w))
          .font(.system(size: 12, design: .monospaced)).foregroundColor("#CCCAC2")
        Spacer()
        Text(meterFallbackDetail(w))
          .font(.system(size: 11, design: .monospaced)).foregroundColor("#8A9199")
          .lineLimit(1).truncationMode(.tail).multilineTextAlignment(.trailing)
      }
      if meterFallbackBar(w) != "" {
        Text(meterFallbackBar(w))
          .font(.system(size: 11, design: .monospaced)).foregroundColor("#73D0FF")
          .lineLimit(1)
      }
    }
  }
}

// ── ⌘N shortcut digit ─────────────────────────────────────────────
// The gray gutter digit is the workspace's REAL ⌘N key, mirrored from cmux's own
// WorkspaceShortcutMapper (Sources/App/TerminalDirectoryOpenSupport.swift) so the
// badge can never drift from the keystroke. Two things that logic dictates and a
// naive 1..N counter would get WRONG:
//   1. ⌘9 is NOT "the 9th" — it always targets the LAST workspace, so the digit
//      hangs off the end of the list, not off position 9.
//   2. The number indexes cmux's FULL workspace list (`manager.tabs`), which
//      includes the usage sentinels. cmux has no notion of a "sentinel" — that
//      concept lives only in this file's predicates — so the meters silently eat
//      ⌘ slots and the visible rows have gaps. Numbering the visible rows 1..N
//      instead would be a lie that makes ⌘N worse, so we key on w.index.
// 0 = this row has no ⌘ key at all (indices 8…count-2 are unreachable).
func shortcutDigit(_ w) -> Int {
  if w.index < 8 { return w.index + 1 }             // ⌘1…⌘8 = fixed zero-based index
  if w.index == workspaceCount - 1 { return 9 }     // ⌘9 = last workspace, whatever its index
  return 0
}
func shortcutLabel(_ w) -> String {
  if shortcutDigit(w) > 0 { return "⌘\(shortcutDigit(w))" }
  return ""
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
  if needsYou(w) { return "#FFCC66" }
  return "#FFFFFF"
}
func rowFillOpacity(_ w) -> Double {
  if w.selected { return 0.85 }
  if needsYou(w) { return 0.10 }
  if isCompacting(w) { return 0.035 }
  if isWorking(w) { return 0.035 }
  return 0.025
}
func closeColor(_ w) -> String {
  if w.selected { return "#FFFFFF" }
  if needsYou(w) { return "#FFCC66" }
  return "#A7AFBD"
}

func row(_ w) -> some View {
  VStack(spacing: 0) {
    Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
      HStack(alignment: .top, spacing: 8) {
        Capsule().frame(width: 3, height: 26)
          .foregroundColor(accentColor(w))
          .opacity(accentOpacity(w))
        // ⌘N gutter. Fixed width so titles stay aligned on rows that have no key
        // (shortcutLabel == ""), and dim on purpose — it's a lookup aid, not state.
        Text(shortcutLabel(w))
          .font(.system(size: 11, design: .monospaced))
          .foregroundColor(w.selected ? "#D9D7CE" : "#707A8C")
          .frame(width: 20)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 5) {
            Text(displayTitle(w))
              .font(.system(size: 14, design: .monospaced))
              .fontWeight(w.selected ? .bold : .medium)
              .foregroundColor(w.selected ? "#FFFFFF" : "#D9D7CE")
              .lineLimit(titleLineLimit(w)).multilineTextAlignment(.leading)
            if w.pinned {
              Image(systemName: "pin.fill").font(.system(size: 9)).foregroundColor("#8A9199")
            }
          }
          // dimension 1 — agent activity
          if showsActivity(w) {
            HStack(spacing: 5) {
              if activityIcon(w) != "" {
                Image(systemName: activityIcon(w)).font(.system(size: 9)).foregroundColor(activityColor(w))
              }
              Text(activityText(w))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(activityColor(w))
                .lineLimit(1).truncationMode(.tail)
            }
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
            .font(.system(size: 12)).foregroundColor(closeColor(w))
            .frame(width: 24, height: 24)
        }
      }
      .padding(6)
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
    if workspaces.filter { needsYou($0) }.count > 0 {
      HStack(spacing: 4) {
        Image(systemName: "bell.fill").font(.system(size: 10)).foregroundColor("#FFCC66")
        Text("\(workspaces.filter { needsYou($0) }.count)")
          .font(.system(size: 11, design: .monospaced)).bold().foregroundColor("#FFCC66")
      }
    }
    if workspaces.filter { isWorking($0) }.count > 0 {
      HStack(spacing: 4) {
        Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundColor("#87D96C")
        Text("\(workspaces.filter { isWorking($0) }.count)")
          .font(.system(size: 11, design: .monospaced)).bold().foregroundColor("#87D96C")
      }
    }
    if workspaces.filter { isCompacting($0) }.count > 0 {
      HStack(spacing: 4) {
        Image(systemName: "hourglass").font(.system(size: 10)).foregroundColor("#DFBFFF")
        Text("\(workspaces.filter { isCompacting($0) }.count)")
          .font(.system(size: 11, design: .monospaced)).bold().foregroundColor("#DFBFFF")
      }
    }
    Text(clock.time).font(.system(size: 11, design: .monospaced)).foregroundColor("#707A8C")
  }
  .padding(9)
  Divider()

  // CLAUDE USAGE — one labelled section per provider (same component reused).
  // Meters sort by WINDOW length (the short 5h/cx5h above the weekly 7d/cx7d), not
  // by workspace .index — index depends on sentinel creation order and reshuffles
  // across restarts, which would flip the rows. Match the stable title PREFIX,
  // never a substring: a weekly countdown can itself contain "5h". The optional
  // m7d row has no rank of its own — it keeps workspace order, which puts it after
  // 7d because setup creates it last.
  if workspaces.filter { isClaudeMeter($0) }.count > 0 {
    VStack(alignment: .leading, spacing: 6) {
      Text("CLAUDE USAGE").font(.system(size: 10, design: .monospaced)).bold().foregroundColor("#8A9199")
      ForEach(workspaces.filter { isClaudeMeter($0) }.sorted { $0.title.hasPrefix("5h") && !$1.title.hasPrefix("5h") }) { w in
        meterRow(w)
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
      ForEach(workspaces.filter { isCodexMeter($0) }.sorted { $0.title.hasPrefix("cx5h") && !$1.title.hasPrefix("cx5h") }) { w in
        meterRow(w)
      }
    }
    .padding(9)
    Divider()
  }

  // AMP USAGE — same component; hidden unless Amp sentinels exist. Fed by
  // bin/cmux-amp-usage.sh. Sorted so "ampu" (the allowance everyone has) sits
  // above the opt-in "ampo"; both are monthly, so there's no window length to
  // sort by — `.contains("ampu")` is the equivalent stable key.
  if workspaces.filter { isAmpMeter($0) }.count > 0 {
    VStack(alignment: .leading, spacing: 6) {
      Text("AMP USAGE").font(.system(size: 10, design: .monospaced)).bold().foregroundColor("#8A9199")
      ForEach(workspaces.filter { isAmpMeter($0) }.sorted { $0.title.contains("ampu") && !$1.title.contains("ampu") }) { w in
        meterRow(w)
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
