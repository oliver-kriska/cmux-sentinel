#!/bin/bash
# cmux-group-sync.sh — mirror each cmux workspace GROUP's logical name onto its
# anchor workspace's TITLE, so the custom sidebar shows "Payduct" instead of the
# generic "Group 2".
#
# WHY THIS EXISTS. A cmux workspace group's display name (group.name) and its
# anchor workspace's title are two INDEPENDENT fields. Native cmux renders
# group.name on the group header, but a custom sidebar gets NO group data at all —
# proven: `extension.sidebar.snapshot` carries no group fields, and the sidebar
# interpreter exposes no `groups` binding (probed 2026-06-19, see
# .claude/research/2026-06-19-workspace-group-names-in-sidebar.md). The only
# per-workspace channel a custom sidebar CAN read is the TITLE — the same lever the
# usage meters and the agent-state bridge already ride. So this poller reads
# `cmux workspace-group list` and renames each group's ANCHOR workspace to the
# group's name. Nothing in the sidebar file changes; it already renders titles.
#
# It PRESERVES a leading agent-state marker (⚡ working / ⏳ compacting / ❓ waiting)
# the bridge may have put on an anchor that's running an agent, and only renames
# when the name actually differs — so steady state writes nothing (cmux's title
# coalescer is sensitive to churn, upstream #6291).
#
# OPT-IN, like the Codex meter: a no-op unless GROUP_NAME_SYNC=1 (set in
# ~/.config/cmux/usage-sentinels.env or the launchd plist). Even when enabled, a
# machine with no groups is a clean no-op.
#
# Modes:
#   --list    read-only: every group, its anchor, current title, sync status
#   --raw     dump the raw workspace-group list JSON (every window)
#   --update  rename anchors to match group names (gated on GROUP_NAME_SYNC=1)
#
# No creds, no network — a local socket read + renames. Multi-window: groups are
# window-scoped and launchd has no window context, so it iterates every window
# (`list-windows` is global) and renames with --window so the positional ref is
# unambiguous.

set -uo pipefail

# cmux prints a one-time deprecation notice for legacy verbs (rename-workspace →
# workspace rename) on STDERR. Anything that CAPTURES cmux stderr to explain a
# failure gets that notice at the front of the reason, where it reads as the cause
# — it buried a real "Command timed out" once. cmux documents this switch for it.
export CMUX_QUIET=1

SENTINELS_ENV="$HOME/.config/cmux/usage-sentinels.env"
# shellcheck disable=SC1090
[ -f "$SENTINELS_ENV" ] && source "$SENTINELS_ENV"
GROUP_NAME_SYNC="${GROUP_NAME_SYNC:-0}"

die() { echo "ERR: $*" >&2; exit 1; }

# All window ids (UUIDs). launchd has no current-window context, so we always
# target windows explicitly; `list-windows` is global so it sees them all.
windows() { cmux list-windows --json 2>/dev/null | jq -r '.[].id // empty' 2>/dev/null; }

# Groups in one window as TSV "name\tanchor_ref", skipping unnamed groups (an
# empty name must never overwrite an anchor's title) and ANCHORLESS ones.
#
# Both guards live in jq on purpose. A null/missing anchor_workspace_ref cannot be
# caught downstream: jq's string interpolation renders it as the literal text
# "null", which is non-empty, so a bash `[ -n "$anchor" ]` test PASSES and we'd go
# on to rename a workspace with the ref `null`. Empty groups (cmux 0.64.18 added
# entrypoints to create them) are the case that makes an anchorless group reachable.
groups_in_window() { # $1 = window id
  cmux workspace-group list --window "$1" --json 2>/dev/null \
    | jq -r '.groups[]?
             | select(.name != null and .name != "")
             | select(.anchor_workspace_ref != null and .anchor_workspace_ref != "")
             | "\(.name)\t\(.anchor_workspace_ref)"' 2>/dev/null
}

# Current title of a ref within a window's workspace list (passed as JSON in $2 to
# avoid a socket round-trip per group).
title_in() { # $1 = ref  $2 = workspace-list JSON
  printf '%s' "$2" | jq -r --arg r "$1" '.workspaces[] | select(.ref == $r) | .title' 2>/dev/null | head -1
}

main() {
  local mode="${1:---list}"
  command -v cmux >/dev/null 2>&1 || die "cmux not on PATH"

  if [ "$mode" = "--raw" ]; then
    local w
    for w in $(windows); do cmux workspace-group list --window "$w" --json 2>/dev/null; done
    return
  fi

  if [ "$mode" = "--update" ]; then
    if [ "$GROUP_NAME_SYNC" != "1" ]; then
      # Only a HUMAN needs to hear this. launchd runs --update every 5 minutes and
      # captures stderr, so an unconditional notice wrote 3259 identical lines /
      # 400KB (~12MB a year) into the .err of a feature that is OFF BY DEFAULT —
      # and buried any real error in it. The plist calls itself "dormant unless
      # enabled"; this is what actually makes that true.
      [ -t 2 ] && echo "group-name sync disabled (set GROUP_NAME_SYNC=1 in $SENTINELS_ENV) — nothing to do" >&2
      exit 0
    fi
    cmux ping &>/dev/null || die "cmux socket rejected (restart cmux to apply socketControlMode=automation)"
  fi

  local w name anchor cur marker base newtitle err total=0 synced=0 renamed=0 failed=0
  for w in $(windows); do
    local wsjson grprows
    wsjson=$(cmux workspace list --window "$w" --json 2>/dev/null)
    grprows=$(groups_in_window "$w")
    [ -n "$grprows" ] || continue
    while IFS=$'\t' read -r name anchor; do
      [ -n "$name" ] && [ -n "$anchor" ] || continue
      total=$(( total + 1 ))
      cur=$(title_in "$anchor" "$wsjson")
      # Split off a leading agent-state marker (⚡ working / ⏳ compacting / ❓
      # waiting) the bridge prepends bare (e.g. "⚡cmux-sentinel"); preserve it so a
      # sync on an anchor that's mid-turn doesn't blink the marker off, and compare
      # the BASE name (not the marker) to the group name to decide on a rename.
      marker=""; base="$cur"
      case "$cur" in
        ⚡*) marker="⚡"; base="${cur#⚡}" ;;
        ⏳*) marker="⏳"; base="${cur#⏳}" ;;
        ❓*) marker="❓"; base="${cur#❓}" ;;
      esac
      base="${base# }"   # tolerate a "⚡ name" (with space) form too
      if [ "$base" = "$name" ]; then
        synced=$(( synced + 1 ))
        [ "$mode" = "--list" ] && printf '  ✓ %-24s anchor=%s title="%s"\n' "$name" "$anchor" "$cur"
        continue
      fi
      newtitle="${marker}${name}"
      if [ "$mode" = "--list" ]; then
        printf '  → %-24s anchor=%s title="%s" ⇒ "%s"\n' "$name" "$anchor" "$cur" "$newtitle"
        continue
      fi
      # --update
      if err=$(cmux rename-workspace --workspace "$anchor" --window "$w" "$newtitle" 2>&1 >/dev/null); then
        renamed=$(( renamed + 1 ))
      else
        failed=$(( failed + 1 ))
        echo "WARN: rename rejected for group '$name' (anchor $anchor): ${err:-no detail}" >&2
      fi
    done <<<"$grprows"
  done

  if [ "$total" = 0 ]; then
    echo "no workspace groups — nothing to sync"
    return
  fi
  case "$mode" in
    --list)   echo "groups: $total ($synced in sync, $(( total - synced )) need rename)" ;;
    --update) echo "synced $total group(s): $renamed renamed, $synced already current$([ "$failed" -gt 0 ] && printf ', %s failed' "$failed")" ;;
    *)        die "unknown mode: $mode (use --list | --raw | --update)" ;;
  esac
}

main "$@"
