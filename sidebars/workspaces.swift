// Workspaces sidebar — flat, your manual order (by index). SF Mono.
// Palette: Ayu Mirage (matches the terminal theme).
//   bg #1F2430 · fg #D9D7CE · dim #8A9199 · orange #FFCC66 · blue #73D0FF
//   green #87D96C · selection #33415E
//
// Three live states, driven by cmux-bridge.sh + cmux unread:
//   working   (green)  — Claude actively working      (progress set)
//   needs you (orange) — Claude finished/awaiting you  (unread > 0, not working)
//   idle      (dim)    — nothing happening

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

func isWorking(_ w) -> Bool {
  return hasProgress(w) && w.progress.value < 1.0
}

func needsYou(_ w) -> Bool {
  return !isWorking(w) && w.unread > 0
}

func isCompacting(_ w) -> Bool {
  return hasProgressLabel(w) && w.progress.label.contains("Compact")
}

// Usage meters: idle "sentinel" workspaces whose titles are driven by background
// pollers. ONE predicate per provider (matched by exact id — the interpreter has
// no working String .contains, and == is fine) so each provider renders its own
// labelled section in the panel. Keep ids in sync with the poller env files.
func isClaudeMeter(_ w) -> Bool {
  if w.id == "REPLACE_WITH_5H_SENTINEL_UUID" { return true }  // Claude — 5h session
  if w.id == "REPLACE_WITH_7D_SENTINEL_UUID" { return true }  // Claude — 7d weekly
  return false
}

// Add a provider: copy isClaudeMeter with the new sentinel id(s), add an
// `if isCodexMeter(w) { return true }` line to isUsageMeter below, and a matching
// section in the panel (search "CLAUDE USAGE").
// func isCodexMeter(_ w) -> Bool {
//   if w.id == "REPLACE_WITH_CODEX_SENTINEL_UUID" { return true }
//   return false
// }

// Any meter, any provider — used only to hide sentinels from the workspace list.
func isUsageMeter(_ w) -> Bool {
  if isClaudeMeter(w) { return true }
  // if isCodexMeter(w) { return true }
  return false
}


func workLabel(_ w) -> String {
  if hasProgressLabel(w) { return w.progress.label }
  return "Working…"
}

func hasLatestAt(_ w) -> Bool {
  return w.latestAt != nil && w.latestAt != ""
}

func ago(_ mins) -> String {
  if mins < 1 { return "now" }
  if mins < 60 { return "\(mins)m" }
  if mins < 1440 { return "\(mins / 60)h" }
  return "\(mins / 1440)d"
}

func infoText(_ w, _ nowEpoch) -> String {
  if isWorking(w) { return workLabel(w) }
  let when = hasLatestAt(w) ? " · \(ago((nowEpoch - w.latestAt) / 60))" : ""
  if needsYou(w) { return "needs you\(when)" }
  if hasPR(w) {
    let stale = w.pr.stale == true ? " · stale" : ""
    return "\(w.pr.label)\(stale)\(when)"
  }
  if hasBranch(w) {
    let d = w.dirty == true ? " · uncommitted" : ""
    return "\(w.branch)\(d)\(when)"
  }
  if w.dirty == true { return "uncommitted changes\(when)" }
  return "idle\(when)"
}

func infoColor(_ w) -> String {
  if isWorking(w) { return "#87D96C" }
  if needsYou(w) { return "#FFCC66" }
  if hasPR(w) && w.pr.status == "open" { return "#73D0FF" }
  if w.dirty == true { return "#FFCC66" }
  return "#8A9199"
}

func accentColor(_ w) -> String {
  if isWorking(w) { return "#87D96C" }
  if needsYou(w) { return "#FFCC66" }
  return "#73D0FF"
}

func accentOpacity(_ w) -> Double {
  if w.selected { return 1.0 }
  if isWorking(w) { return 0.9 }
  if needsYou(w) { return 0.9 }
  return 0.0
}

func rowFill(_ w) -> String {
  if w.selected { return "#33415E" }
  if isWorking(w) { return "#87D96C" }
  if needsYou(w) { return "#FFCC66" }
  return "#000000"
}

func rowFillOpacity(_ w) -> Double {
  if w.selected { return 0.85 }
  if isWorking(w) { return 0.12 }
  if needsYou(w) { return 0.08 }
  return 0.06
}

func row(_ w, _ nowEpoch) -> some View {
  VStack(spacing: 0) {
    Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
      HStack(alignment: .top, spacing: 10) {
        Capsule().frame(width: 3, height: 26)
          .foregroundColor(accentColor(w))
          .opacity(accentOpacity(w))
        VStack(alignment: .leading, spacing: 2) {
          Text(w.title)
            .font(.system(size: 14, design: .monospaced))
            .fontWeight(w.selected ? .bold : .medium)
            .foregroundColor(w.selected ? "#FFFFFF" : "#D9D7CE")
            .lineLimit(2).multilineTextAlignment(.leading)
          HStack(spacing: 5) {
            if isWorking(w) {
              Image(systemName: isCompacting(w) ? "hourglass" : "bolt.fill")
                .font(.system(size: 9)).foregroundColor("#87D96C")
            }
            if needsYou(w) {
              Image(systemName: "bell.fill").font(.system(size: 9)).foregroundColor("#FFCC66")
            }
            Text(infoText(w, nowEpoch))
              .font(.system(size: 11, design: .monospaced))
              .foregroundColor(infoColor(w))
              .lineLimit(1).truncationMode(.tail)
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
    Divider()
  }
}

VStack(alignment: .leading, spacing: 0) {
  HStack(spacing: 10) {
    Text("Workspaces").font(.system(size: 14, design: .monospaced)).bold()
      .foregroundColor("#D9D7CE")
    Spacer()
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

  // USAGE — one labelled section per provider (same component, different meters).
  if workspaces.filter { isClaudeMeter($0) }.count > 0 {
    VStack(alignment: .leading, spacing: 6) {
      Text("CLAUDE USAGE").font(.system(size: 10, design: .monospaced)).bold().foregroundColor("#8A9199")
      ForEach(workspaces.filter { isClaudeMeter($0) }.sorted { $0.index < $1.index }) { w in
        Text(w.title)
          .font(.system(size: 12, design: .monospaced))
          .foregroundColor("#CCCAC2")
      }
    }
    .padding(9)
    Divider()
  }

  // Next provider — copy the block above, swap predicate + header:
  // if workspaces.filter { isCodexMeter($0) }.count > 0 {
  //   VStack(alignment: .leading, spacing: 6) {
  //     Text("CODEX USAGE").font(.system(size: 10, design: .monospaced)).bold().foregroundColor("#8A9199")
  //     ForEach(workspaces.filter { isCodexMeter($0) }.sorted { $0.index < $1.index }) { w in
  //       Text(w.title).font(.system(size: 12, design: .monospaced)).foregroundColor("#CCCAC2")
  //     }
  //   }
  //   .padding(9)
  //   Divider()
  // }

  ForEach(workspaces.filter { !isUsageMeter($0) }.sorted { $0.index < $1.index }) { w in
    row(w, clock.epoch)
  }
  Spacer()
}
