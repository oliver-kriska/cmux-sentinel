// amp-bridge.ts — Bridge Amp (ampcode.com) agent state into the cmux custom sidebar.
//
// WHY THIS EXISTS AT ALL. cmux ships its own amp integration
// (`cmux hooks amp install` → ~/.config/amp/plugins/cmux-session.ts), but that one
// reports state with `cmux set-status`, which renders as pills in cmux's NATIVE
// sidebar tab row and NEVER reaches a custom sidebar — verified by an in-sidebar
// render probe and by cmux's own binding contract in docs/custom-sidebars.md,
// which lists every interpreter-visible workspace field and has no status among
// them. So sentinel's sidebar cannot see amp at all without this file. The two
// plugins are complementary and must BOTH be installed; amp auto-loads every
// *.ts in the plugin dir, so they coexist. NEVER edit cmux-session.ts — it says
// "DO NOT EDIT MANUALLY. cmux upgrades this file in place."
//
// WHY IT SHELLS OUT INSTEAD OF REIMPLEMENTING. The marker state machine
// (ref-counting live sessions per workspace, PID-liveness reaping, the
// compacting > waiting > working precedence, restart self-heal) is subtle and
// already tested in hooks/cmux-bridge.sh. Duplicating it in TypeScript would
// mean two implementations to keep in sync AND would break co-tenancy: when Amp
// and Claude Code run in the SAME workspace they must ref-count against each
// other, which only works if both write the same $WORKROOT. So this file is a
// thin ADAPTER — it maps Amp's lifecycle events onto the bash bridge's event
// names and lets the bridge own all state. Bugs get fixed once, for both agents.
//
// STATE COVERAGE IS 2-OF-3 BY DESIGN, and the gaps are Amp's, not ours:
//   ⚡ working — agent.start (turn begins) + tool.call (keeps the marker fresh)
//   (clear)   — agent.end, whatever the outcome (done | error | cancelled)
//   ⏳ compacting — IMPOSSIBLE: Amp emits no compaction event. Not faked.
//   ❓ asked in text — agent.end(done) passes the final reply; when it ends on a
//     question the bridge shows ❓, quieting to ❔ after 10 minutes, until the next
//     agent.start. Always on: it only reads what Amp already said and changes
//     nothing about how Amp behaves.
//   ❓ waiting mid-turn — OPT-IN, off by default. Amp does not ask permission by default
//     ("By default, Amp does not ask for approval before running tools"), so
//     there is no blocked-on-user moment to observe. Set CMUX_SENTINEL_AMP_ASK=1
//     and the tool.call handler marks ❓ around tools listed in
//     CMUX_SENTINEL_AMP_ASK_TOOLS while it confirms with you. Left off by default
//     because turning it on CHANGES AMP'S BEHAVIOUR (it starts prompting), which
//     a status bridge has no business doing uninvited.
//
// Normal cmux writes are fire-and-forget and errors are swallowed. The only
// synchronous path is a terminal error paired with an old bridge, where ordering
// is required for correctness and the turn has already ended.

import { spawn, spawnSync } from "node:child_process"
import { existsSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

// Resolve the bash bridge. Env override first (tests and non-standard checkouts),
// then Amp's neutral installed dependency, then the explicit Claude integration's
// copy for backward compatibility with older installs.
function bridgePath() {
  const candidates = [
    process.env.CMUX_SENTINEL_BRIDGE,
    join(homedir(), ".config/cmux-sentinel/cmux-bridge.sh"),
    join(homedir(), ".claude/hooks/cmux-bridge.sh"),
  ].filter((p) => typeof p === "string" && p.length > 0)
  for (const p of candidates) if (existsSync(p)) return p
  return null
}

const BRIDGE = bridgePath()

// The plugin and bridge are installed as two files. A manual partial copy can
// pair this plugin with an older bridge that silently ignores StopFailureFinal
// (unknown bridge events return success). Probe stdout once at load: output is
// the capability contract; exit status alone proves nothing.
function supportsFinalFailure() {
  if (!BRIDGE) return false
  try {
    const result = spawnSync("bash", [BRIDGE, "--capabilities"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      // Plugin load can overlap other startup work; avoid misclassifying a current
      // bridge as legacy just because process launch exceeded a one-second budget.
      timeout: 5000,
    })
    return typeof result.stdout === "string" && result.stdout.includes("stop-failure-final")
  } catch (_) {
    return false
  }
}

const SUPPORTS_FINAL_FAILURE = supportsFinalFailure()

// One amp process = one session for ref-counting. The bridge keys liveness on
// this pid (kill -0), so a crashed amp can never strand a ⚡ on the workspace.
const SESSION_PID = String(process.pid)

// Drive the bash bridge with an event name + JSON on stdin, exactly as Claude
// Code's hooks do. Detached and fully ignored: never block the agent's turn.
function drive(event, payload = {}) {
  if (!BRIDGE) return
  if (!process.env.CMUX_WORKSPACE_ID) return // not inside a cmux workspace
  try {
    const child = spawn("bash", [BRIDGE, event], {
      env: {
        ...process.env,
        CMUX_SENTINEL_SESSION_PID: SESSION_PID,
        CMUX_SENTINEL_AGENT_LABEL: "Amp",
        CMUX_SENTINEL_LOG_SOURCE: "amp",
      },
      stdio: ["pipe", "ignore", "ignore"],
      detached: true,
    })
    child.on("error", () => {})
    child.stdin?.on("error", () => {}) // bridge may exit before we finish writing
    child.stdin?.end(JSON.stringify({ hook_event_name: event, ...payload }))
    child.unref()
  } catch (_) {}
}

// Compatibility path for an old bridge: the terminal clear must finish before
// StopFailure reports the error, or SessionEnd immediately erases the new status
// pill. Two detached calls could reorder, so both steps are synchronous.
function driveSync(event, payload = {}) {
  if (!BRIDGE) return
  if (!process.env.CMUX_WORKSPACE_ID) return
  try {
    spawnSync("bash", [BRIDGE, event], {
      env: {
        ...process.env,
        CMUX_SENTINEL_SESSION_PID: SESSION_PID,
        CMUX_SENTINEL_AGENT_LABEL: "Amp",
        CMUX_SENTINEL_LOG_SOURCE: "amp",
      },
      input: JSON.stringify({ hook_event_name: event, ...payload }),
      stdio: ["pipe", "ignore", "ignore"],
      timeout: 5000,
    })
  } catch (_) {}
}

// The turn's id: agent.start and agent.end both carry the id of the message that
// started the turn. The bridge uses it to ignore a Stop that arrives after the
// next turn already began (detached spawns can reorder).
function turnId(event) {
  return typeof event?.id === "string" ? event.id : ""
}

// The last non-blank text block of the turn's last assistant message, or "".
// agent.end carries the turn's messages; content is an array of blocks (text,
// thinking, tool_use), or a bare string. A trailing whitespace-only block is
// skipped, or it would hide the question before it. Only the tail is sent — the
// bridge reads just the final line, and this rides a pipe on every turn end.
function lastAssistantText(event) {
  const messages = Array.isArray(event?.messages) ? event.messages : []
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]
    if (m?.role !== "assistant") continue
    if (typeof m.content === "string") return m.content.slice(-2000)
    const blocks = Array.isArray(m.content) ? m.content : []
    for (let j = blocks.length - 1; j >= 0; j--) {
      const b = blocks[j]
      if (b?.type === "text" && typeof b.text === "string" && b.text.trim() !== "") {
        return b.text.slice(-2000)
      }
    }
    return ""
  }
  return ""
}

// ── opt-in ❓ waiting ──────────────────────────────────────────────────────
const ASK_ENABLED = process.env.CMUX_SENTINEL_AMP_ASK === "1"
const ASK_TOOLS = (process.env.CMUX_SENTINEL_AMP_ASK_TOOLS || "Bash")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean)

export default function (amp) {
  amp.on("session.start", () => {
    // Reconcile markers we still track and strip any stranded by a reboot wiping
    // $TMPDIR. Same self-heal Claude Code's SessionStart does.
    drive("SessionStart", { source: "startup" })
  })

  amp.on("agent.start", (event) => {
    drive("UserPromptSubmit", {
      prompt: typeof event?.message === "string" ? event.message : "",
      prompt_id: turnId(event),
    })
  })

  amp.on("tool.call", async (event, ctx) => {
    const tool = typeof event?.tool === "string" ? event.tool : ""

    if (ASK_ENABLED && ASK_TOOLS.includes(tool)) {
      // Blocked on the user for real → ❓ while the dialog is up, then back to ⚡.
      // PreToolUse with these tool names is how the bash bridge already routes
      // "this call parks on the human" (it does the same for AskUserQuestion).
      drive("PreToolUse", { tool_name: "AskUserQuestion" })
      try {
        const ok = await ctx?.ui?.confirm?.({
          title: `Run ${tool}?`,
          message: "cmux-sentinel: approve this tool call.",
        })
        drive("PreToolUse", { tool_name: tool }) // answered → back to working
        if (ok === false) return { action: "reject-and-continue" }
      } catch (_) {
        drive("PreToolUse", { tool_name: tool }) // dialog unavailable → don't strand ❓
      }
      return { action: "allow" }
    }

    // Normal path: refresh ⚡. The bridge's .marked TTL flag makes this cheap —
    // it skips the ~44ms title read on every call after the first.
    drive("PreToolUse", { tool_name: tool })
    return { action: "allow" }
  })

  amp.on("agent.end", (event) => {
    const status = event?.status
    if (status === "error") {
      // New bridge: one atomic report+clear event. Old bridge: synchronous ordered
      // fallback; it does not understand StopFailureFinal, and detached calls race.
      if (SUPPORTS_FINAL_FAILURE) {
        drive("StopFailureFinal", { error: "Amp turn failed" })
      } else {
        // SessionEnd clears the legacy session without Stop's misleading
        // "Finished responding" notification. Report the failure SECOND so
        // SessionEnd cannot immediately clear the native error pill it creates.
        driveSync("SessionEnd", {})
        driveSync("StopFailure", { error: "Amp turn failed" })
      }
      return
    }
    // done | cancelled — both mean this turn is over. A finished turn hands the
    // bridge its final text, so a reply that ends on a question shows ❓ (then ❔)
    // until you answer. A cancelled turn sends none: you are already at the keyboard.
    drive("Stop", status === "done"
      ? { prompt_id: turnId(event), last_assistant_message: lastAssistantText(event) }
      : { prompt_id: turnId(event) })
  })
}
