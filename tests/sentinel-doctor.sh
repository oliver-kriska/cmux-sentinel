#!/bin/bash
# sentinel-doctor.sh — offline regression test for multi-window diagnostics.
#
# launchd has no default-window context. The doctor must scan every cmux window
# before reporting a sentinel missing or checking whether meters consume ⌘ keys.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCTOR="${DOCTOR:-$HERE/../bin/cmux-sentinel-doctor.sh}"
[ -f "$DOCTOR" ] || { echo "doctor not found: $DOCTOR" >&2; exit 2; }
JQ="$(command -v jq)" || { echo "jq required" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-doctor-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
HOME="$ROOT/home"; export HOME
mkdir -p "$ROOT/bin" "$HOME/.config/cmux/sidebars" "$HOME/.local/share/amp"
ln -s "$JQ" "$ROOT/bin/jq"
mkdir -p "$HOME/.config/cmux-sentinel"
cp "$HERE/../hooks/cmux-bridge.sh" "$HOME/.config/cmux-sentinel/cmux-bridge.sh"

cat > "$HOME/.config/cmux/sidebars/workspaces.swift" <<'SWIFT'
func isClaudeMeter(_ w: Workspace) -> Bool {
    if w.title.hasPrefix("5h ") { return true }
    if w.title.hasPrefix("7d ") { return true }
    return false
}
SWIFT
cat > "$HOME/.config/cmux/cmux.json" <<'JSON'
{"automation":{"socketControlMode":"automation"}}
JSON
cat > "$HOME/.config/cmux/usage-sentinels.env" <<'ENV'
USAGE_PROVIDERS="claude codex amp"
ENV
printf '{"present":true}\n' > "$HOME/.local/share/amp/secrets.json"

# The default list intentionally has no meters. Both sentinels live in win-b,
# where they are safely parked at indices 8–9 and a real workspace owns ⌘9.
cat > "$ROOT/bin/cmux" <<'FAKE'
#!/bin/bash
window_list() {
  # STUB_WINB reshapes win-b for the "unavoidable vs fixable" ⌘ cases (T16).
  case "${STUB_WINB:-}" in
    eight-parked) # 8 reals, meters parked, last real anchors ⌘9 → ⌘8 is unavoidable
      cat <<'JSON'
{"workspaces":[
  {"ref":"w1","index":0,"title":"one"},{"ref":"w2","index":1,"title":"two"},
  {"ref":"w3","index":2,"title":"three"},{"ref":"w4","index":3,"title":"four"},
  {"ref":"w5","index":4,"title":"five"},{"ref":"w6","index":5,"title":"six"},
  {"ref":"w7","index":6,"title":"seven"},
  {"ref":"w9","index":7,"title":"5h █ 24% · resets 2h"},
  {"ref":"w10","index":8,"title":"7d ██ 48% · resets 3d"},
  {"ref":"w11","index":9,"title":"cx7d |8% (3d)|█░"},
  {"ref":"w12","index":10,"title":"ampu |12% (1 month)|█░"},
  {"ref":"w13","index":11,"title":"last-real"}
]}
JSON
      return ;;
    eight-last) # same 8 reals, meters at the very bottom → ⌘9 is on a meter, and setup CAN fix it
      cat <<'JSON'
{"workspaces":[
  {"ref":"w1","index":0,"title":"one"},{"ref":"w2","index":1,"title":"two"},
  {"ref":"w3","index":2,"title":"three"},{"ref":"w4","index":3,"title":"four"},
  {"ref":"w5","index":4,"title":"five"},{"ref":"w6","index":5,"title":"six"},
  {"ref":"w7","index":6,"title":"seven"},{"ref":"w13","index":7,"title":"last-real"},
  {"ref":"w9","index":8,"title":"5h █ 24% · resets 2h"},
  {"ref":"w10","index":9,"title":"7d ██ 48% · resets 3d"},
  {"ref":"w11","index":10,"title":"cx7d |8% (3d)|█░"},
  {"ref":"w12","index":11,"title":"ampu |12% (1 month)|█░"}
]}
JSON
      return ;;
  esac
  cat <<'JSON'
{"workspaces":[
  {"ref":"w1","index":0,"title":"one"},
  {"ref":"w2","index":1,"title":"two"},
  {"ref":"w3","index":2,"title":"three"},
  {"ref":"w4","index":3,"title":"four"},
  {"ref":"w5","index":4,"title":"five"},
  {"ref":"w6","index":5,"title":"six"},
  {"ref":"w7","index":6,"title":"seven"},
  {"ref":"w8","index":7,"title":"eight"},
  {"ref":"w9","index":8,"title":"5h █ 24% · resets 2h"},
  {"ref":"w10","index":9,"title":"7d ██ 48% · resets 3d"},
  {"ref":"w11","index":10,"title":"cx7d |8% (3d)|█░"},
  {"ref":"w12","index":11,"title":"ampu |12% (1 month)|█░"},
  {"ref":"w13","index":12,"title":"last-real"}
]}
JSON
}

case "$1" in
  # Unset STUB_CMUX_VERSION = a cmux whose version can't be read: the doctor must
  # make no native-data claims at all (the baseline run below relies on that).
  --version) [ -n "${STUB_CMUX_VERSION:-}" ] && printf 'cmux %s (103) [211b8bb35]\n' "$STUB_CMUX_VERSION"; exit 0 ;;
  ping) exit 0 ;;
  sidebar) [ "$2" = validate ] && exit 0 ;;
  list-windows) printf '[{"id":"win-b"}]\n' ;;
  workspace)
    if [ "$2" = list ]; then
      case " $* " in *" --window win-b "*) window_list ;; *) printf '{"workspaces":[{"ref":"d1","index":0,"title":"default-real"}]}\n' ;; esac
    fi
    ;;
  workspace-group) printf '%s\n' "${STUB_GROUPS:-{\"groups\":[]\}}" ;;
  rpc)
    if [ "$2" = extension.sidebar.snapshot ]; then window_list
    else echo "Error: disabled: Workspace auto-naming is disabled in Settings" >&2; exit 1; fi
    ;;
esac
FAKE
cat > "$ROOT/bin/security" <<'FAKE'
#!/bin/bash
exit 0
FAKE
cat > "$ROOT/bin/launchctl" <<'FAKE'
#!/bin/bash
printf '%s\n' "${STUB_LAUNCHD_JOBS:-com.cmux-claude-usage}"
exit 0
FAKE
cat > "$ROOT/bin/codex" <<'FAKE'
#!/bin/bash
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then
  [ "${STUB_CODEX_AUTH:-chatgpt}" = chatgpt ] || { echo "Not logged in" >&2; exit 1; }
  echo "Logged in using ChatGPT" >&2; exit 0
fi
[ "${1:-}" = app-server ] || exit 2
# Codex capability intentionally unknown: doctor must retain the current layout.
while IFS= read -r line; do
  case "$(printf '%s' "$line" | jq -r '.id // empty')" in
    0) printf '{"id":0,"result":{"userAgent":"fake","codexHome":"/tmp/fake","platformFamily":"unix","platformOs":"linux"}}\n' ;;
    1)
      if [ "${STUB_CODEX_RPC:-expired}" = expanded ]; then
        printf '%s\n' '{"id":1,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":8,"windowDurationMins":10080,"resetsAt":2000000000},"secondary":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":8,"windowDurationMins":10080,"resetsAt":2000000000}},"codex_test_model":{"limitId":"codex_test_model","limitName":"Test Model","primary":{"usedPercent":6,"windowDurationMins":10080,"resetsAt":2000000000}},"codex_opaque":{"limitId":"codex_opaque","limitName":null,"primary":{"usedPercent":3,"windowDurationMins":10080,"resetsAt":2000000000}}},"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"RateLimitResetCredit_fake_private","status":"available","title":"Full reset"}]}}}'
      else
        printf '{"id":1,"error":{"code":-32603,"message":"GET usage failed: 401 Unauthorized: token_expired"}}\n'
      fi
      ;;
  esac
done
FAKE
cat > "$ROOT/bin/amp" <<'FAKE'
#!/bin/bash
[ "$1" = usage ] || exit 0
printf '%s\n' 'Subscription Test: 88% other usage and 100% orb usage remaining - resets upon renewal in 1 month'
FAKE
# Fake curl: the doctor asks GitHub whether a newer VERSION exists. Stub it so the
# suite never touches the network AND so the update-available path is testable.
# STUB_LATEST is what raw.githubusercontent "returns"; unset = unreachable.
cat > "$ROOT/bin/curl" <<'FAKE'
#!/bin/bash
[ -n "${STUB_LATEST:-}" ] || exit 7
printf '%s\n' "$STUB_LATEST"
FAKE
chmod +x "$ROOT/bin/cmux" "$ROOT/bin/security" "$ROOT/bin/launchctl" "$ROOT/bin/codex" "$ROOT/bin/amp" "$ROOT/bin/curl"

PATH="$ROOT/bin:/usr/bin:/bin"; export PATH
out="$(bash "$DOCTOR" 2>&1)"; rc=$?

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  ✗ %s\n' "$1"; }
has() { case "$out" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
lacks() { case "$1" in *"$2"*) return 1 ;; *) return 0 ;; esac; }

echo "T1: sentinels outside the default window are found"
if [ "$rc" = 0 ]; then ok "doctor exited 0"; else bad "doctor exited $rc"; fi
if has "'5h' sentinel present (w9 in window win-b)"; then ok "found 5h in win-b"; else bad "did not find 5h in win-b"; fi
if has "'7d' sentinel present (w10 in window win-b)"; then ok "found 7d in win-b"; else bad "did not find 7d in win-b"; fi
if has "no '5h' sentinel"; then bad "reported a false missing 5h sentinel"; else ok "no false missing 5h warning"; fi
if has "no '7d' sentinel"; then bad "reported a false missing 7d sentinel"; else ok "no false missing 7d warning"; fi

echo "T2: shortcut layout is checked in the meter's window"
if has "all 9 ⌘ keys in window win-b are on real workspaces"; then ok "validated win-b layout"; else bad "did not validate win-b layout"; fi
if has "meters in window win-b are eating"; then bad "reported false shortcut theft"; else ok "no false shortcut warning"; fi

echo "T3: Amp-only neutral bridge is reported accurately"
if has "Amp shared bridge installed"; then ok "neutral Amp bridge detected"; else bad "neutral Amp bridge not detected"; fi
if has "no agent-state bridge installed"; then bad "Amp-only setup reported as bridge-less"; else ok "no false bridge-missing warning"; fi

echo "T4: Codex unknown capability retains layout without false creation advice"
if has "live allowance unavailable — Codex login expired; run codex logout, then codex login"; then ok "unknown Codex capability is explicit and actionable"; else bad "actionable Codex capability failure not reported"; fi
if has "stored login alone does not prove meters are active"; then ok "stored login is not mistaken for live availability"; else bad "stored login was presented as active"; fi
if has "no 'cx5h' sentinel — capability unknown"; then ok "missing cx5h layout retained"; else bad "missing cx5h retention not reported"; fi
if has "no 'cx5h' sentinel (title"; then bad "unknown capability suggested creating cx5h"; else ok "no false cx5h creation warning"; fi
if has "snapshot has no 'cx5h'"; then bad "snapshot contradicted unknown-layout retention"; else ok "snapshot retains unknown Codex layout"; fi

echo "T5: launchd is checked per enabled/installed provider"
if has "claude poller loaded (com.cmux-claude-usage)"; then ok "Claude launchd loaded"; else bad "Claude launchd not detected"; fi
if has "codex poller not loaded — launchctl bootstrap"; then ok "Codex launchd guidance"; else bad "Codex launchd guidance missing"; fi
if has "com.cmux-codex-usage.plist"; then ok "Codex bootstrap path"; else bad "Codex bootstrap path missing"; fi
if has "amp poller not loaded — launchctl bootstrap"; then ok "Amp launchd guidance"; else bad "Amp launchd guidance missing"; fi
if has "com.cmux-amp-usage.plist"; then ok "Amp bootstrap path"; else bad "Amp bootstrap path missing"; fi

echo "T6: disabled/uninstalled providers do not produce launchd warnings"
printf 'USAGE_PROVIDERS="claude"\n' > "$HOME/.config/cmux/usage-sentinels.env"
rm -f "$HOME/.local/share/amp/secrets.json"
out2="$(STUB_CODEX_AUTH=none bash "$DOCTOR" 2>&1)"
if lacks "$out2" "codex poller not loaded"; then ok "disabled Codex has no launchd warning"; else bad "disabled Codex got launchd warning"; fi
if lacks "$out2" "amp poller not loaded"; then ok "disabled Amp has no launchd warning"; else bad "disabled Amp got launchd warning"; fi
case "$out2" in
  *"'cx7d' sentinel present (w11 in window win-b) but codex is disabled"*) ok "disabled Codex leftover is reported" ;;
  *) bad "disabled Codex leftover was missed" ;;
esac
case "$out2" in
  *"'ampu' sentinel present (w12 in window win-b) but amp is disabled"*) ok "disabled Amp leftover is reported" ;;
  *) bad "disabled Amp leftover was missed" ;;
esac
case "$out2" in
  *"cmux workspace close w11 --window win-b"*) ok "cross-window close guidance keeps its window" ;;
  *) bad "cross-window close guidance omitted its window" ;;
esac

echo "T7: additional Codex limits and reset credits are read-only diagnostics"
printf 'USAGE_PROVIDERS="claude codex"\n' > "$HOME/.config/cmux/usage-sentinels.env"
out3="$(STUB_CODEX_RPC=expanded bash "$DOCTOR" 2>&1)"
case "$out3" in *"codex: live allowance available → default meter data valid"*) ok "live capability validates default meter data";;
  *) bad "live capability was not reported valid";; esac
case "$out3" in *"codex additional limit: Test Model — 6% used (7d window); informational only, no extra workspace"*) ok "additional named limit shown without sentinel advice";;
  *) bad "additional named limit diagnostic missing";; esac
case "$out3" in *"codex usage resets: 1 available (read-only; redeem in Codex)"*"codex reset credit: Full reset — available"*) ok "reset-credit count, title, and status shown read-only";;
  *) bad "reset-credit diagnostics missing";; esac
case "$out3" in *"codex_test_model"*|*"codex_opaque"*|*"RateLimitResetCredit_fake_private"*) bad "opaque Codex ids leaked into doctor output";;
  *) ok "doctor never prints opaque limit or reset-credit ids";; esac

echo "T8: provider freshness distinguishes fresh, stale, and never-recorded data"
state="$HOME/.local/state/cmux-sentinel/usage"; mkdir -p "$state"
printf '{"present":true}\n' > "$HOME/.local/share/amp/secrets.json"
now=$(date +%s)
printf '%s\n' "$now" > "$state/claude.last-success"
printf '%s\n' "$((now - 901))" > "$state/codex.last-success"
rm -f "$state/amp.last-success"
printf 'USAGE_PROVIDERS="claude codex amp"\nUSAGE_STALE_AFTER_SECONDS=900\n' > "$HOME/.config/cmux/usage-sentinels.env"
# "stale" says a poller stopped succeeding but not WHY — launchd already captured the
# reason, so the plist's StandardErrorPath is read back and the newest ERR: surfaced.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/com.cmux-codex-usage.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.cmux-codex-usage</string>
  <key>StandardErrorPath</key>
  <string>$ROOT/codex-usage.err</string>
</dict>
</plist>
PLIST
printf 'some older noise\nERR: Codex login expired; run codex logout, then codex login\n' > "$ROOT/codex-usage.err"
out4="$(STUB_CODEX_RPC=expanded bash "$DOCTOR" 2>&1)"
case "$out4" in *"last poller error: ERR: Codex login expired"*) ok "a stale provider reports the poller's own last error";;
  *) bad "stale provider did not surface the launchd error log";; esac
case "$out4" in *"claude data fresh (updated "*) ok "fresh Claude update is recognized";;
  *) bad "fresh Claude update was not recognized";; esac
case "$out4" in *"codex data stale (last successful update 15m ago; expected within 15m)"*) ok "stale Codex data is actionable";;
  *) bad "stale Codex data was not reported";; esac
case "$out4" in *"amp data freshness unknown — no successful update recorded"*) ok "missing Amp freshness is explicit";;
  *) bad "missing Amp freshness was not reported";; esac

echo "T9: ⌘N drift is measured on cmux's NUMBERED rows, not raw indices"
# cmux 0.64.22 (#9176) numbers only the ordinary sidebar rows: a group's ANCHOR
# renders as the group header and every member of a COLLAPSED group is hidden, so
# each one shrinks the numbered list and pulls every row below it a key UP.
# win-b parks its four meters at raw indices 8…11 with "last-real" at 12 — an
# all-clear by raw index. Making "one" (index 0) a group anchor drops the numbered
# count to 12, so the '5h' meter slides to position 7 and really does answer ⌘8.
# Reading raw .index here reports a FALSE all-clear; that is the regression.
out5="$(STUB_GROUPS='{"groups":[{"name":"G","anchor_workspace_ref":"w1","is_collapsed":false,"member_workspace_refs":["w1"]}]}' bash "$DOCTOR" 2>&1)"
case "$out5" in *"are eating ⌘8"*) ok "a group anchor above the meters is counted (⌘8 reported eaten)";;
  *) bad "group anchor ignored — doctor still reports a raw-index all-clear";; esac
case "$out5" in *"all 9 ⌘ keys in window win-b"*) bad "doctor claimed all-clear despite the shifted numbering";;
  *) ok "no false all-clear for the grouped window";; esac

# Collapsing a group hides its non-anchor members too, so a collapsed group of
# three above the meters costs three positions, not one.
out6="$(STUB_GROUPS='{"groups":[{"name":"G","anchor_workspace_ref":"w1","is_collapsed":true,"member_workspace_refs":["w1","w2","w3"]}]}' bash "$DOCTOR" 2>&1)"
case "$out6" in *"are eating ⌘6, ⌘7, ⌘8"*) ok "collapsed members are excluded (three meters land in the keyed band)";;
  *) bad "collapsed group members were still counted as numbered rows";; esac

# A window with no groups must behave exactly as before — the fix may not move
# the baseline, or every ungrouped user's layout silently changes meaning.
case "$out" in *"all 9 ⌘ keys in window win-b are on real workspaces"*) ok "ungrouped baseline is unchanged";;
  *) bad "ungrouped baseline regressed";; esac

echo "T10: the opt-in per-model meter is only 'missing' when it was asked for"
# CLAUDE_MODEL_METER=1 is the user's positive request; without it an absent m7d row
# is correct, not a broken install. Getting this backwards would nag every Claude
# user forever to create a meter they never asked for.
printf 'USAGE_PROVIDERS="claude"\n' > "$HOME/.config/cmux/usage-sentinels.env"
out7="$(bash "$DOCTOR" 2>&1)"
case "$out7" in *"no 'm7d' sentinel — the per-model meter is off"*) ok "an absent m7d is reported as OFF, not as broken";;
  *) bad "absent m7d was not reported as merely off";; esac
# The point of not-nagging is not silence — it's telling someone who WANTS the row
# how to get it. "correct, it isn't metered" answered the wrong question.
case "$out7" in *"CLAUDE_MODEL_METER=1"*) ok "…and names the switch that turns it on";;
  *) bad "reported the meter as off without saying how to enable it";; esac
case "$out7" in *"no 'm7d' sentinel (title"*) bad "doctor nagged about an m7d nobody asked for";;
  *) ok "no false m7d creation advice";; esac
out8="$(CLAUDE_MODEL_METER=1 bash "$DOCTOR" 2>&1)"
case "$out8" in *"no 'm7d' sentinel (title"*) ok "opting in makes a missing m7d actionable";;
  *) bad "opted-in missing m7d was not reported";; esac

echo "T11: a present spend sentinel is never nagged about"
# It is expected to sit there painted `spend |none|` and invisible most of the time;
# reporting that as a problem would train people to ignore the doctor.
case "$out7" in *"'spend' sentinel present"*) ok "an existing spend sentinel reports as healthy";;
  *"no 'spend' sentinel"*) ok "an absent spend sentinel is reported, not silently ignored";;
  *) bad "the doctor says nothing at all about the spend meter";; esac

echo "T12: the doctor answers \"is the fix in my copy?\" without a chat round-trip"
vf="$HOME/.config/cmux-sentinel/VERSION"
mkdir -p "$(dirname "$vf")"
out9="$(bash "$DOCTOR" 2>&1)"
case "$out9" in *"no version stamp"*) ok "an unstamped install says so, and how to fix it";;
  *) bad "an unstamped install reported no version at all";; esac

printf 'version=0.2.0\ninstalled=2026-08-25\ncommit=abc1234\n' > "$vf"
out10="$(STUB_LATEST=0.2.0 bash "$DOCTOR" 2>&1)"
case "$out10" in *"cmux-sentinel v0.2.0 (installed 2026-08-25, abc1234)"*) ok "reports version, date and commit";;
  *) bad "version stamp was not reported";; esac
case "$out10" in *"is available"*) bad "offered an update while already current";;
  *) ok "no update noise when you are current";; esac

# 0.10.0 > 0.9.0 — the comparison must be numeric per component, not lexical.
printf 'version=0.9.0\ninstalled=2026-08-25\ncommit=abc1234\n' > "$vf"
out11="$(STUB_LATEST=0.10.0 bash "$DOCTOR" 2>&1)"
case "$out11" in *"v0.10.0 is available (you have v0.9.0)"*) ok "a newer release is reported, compared numerically";;
  *) bad "0.10.0 was not recognised as newer than 0.9.0";; esac

# Being AHEAD of the published version (a dev machine) is not an update.
printf 'version=0.3.0\ninstalled=2026-08-25\ncommit=abc1234\n' > "$vf"
out12="$(STUB_LATEST=0.2.0 bash "$DOCTOR" 2>&1)"
case "$out12" in *"is available"*) bad "told a dev machine to downgrade";;
  *) ok "running ahead of the release is not an update";; esac

# Every can't-tell path must be SILENT — a health report that errors because
# GitHub was slow is worse than one that says nothing about updates.
out13="$(STUB_LATEST="<html>404</html>" bash "$DOCTOR" 2>&1)"; rc13=$?
if [ "$rc13" = 0 ]; then ok "a garbage response does not fail the doctor"; else bad "garbage update response failed the doctor (rc $rc13)"; fi
case "$out13" in *"is available"*) bad "treated an HTML error page as a version";;
  *) ok "a non-version response is ignored";; esac
out14="$(CMUX_SENTINEL_UPDATE_CHECK=0 STUB_LATEST=9.9.9 bash "$DOCTOR" 2>&1)"
case "$out14" in *"is available"*) bad "checked for updates with the check turned off";;
  *) ok "CMUX_SENTINEL_UPDATE_CHECK=0 skips the network entirely";; esac
rm -f "$vf"

echo "T13: a workspaces.js silently replaces the sidebar — the doctor must say so"
# cmux 0.64.23: for one base name `.js` beats `.swift`, and upstream ships an example
# called workspaces.js. Every other sidebar check stays green while cmux shows the
# OTHER file, so this is the only line that can catch it.
case "$out" in *"SHADOWS workspaces.swift"*) bad "baseline (no .js) reported a shadow";;
  *) ok "no shadow warning without a workspaces.js";; esac
printf 'sidebar(() => Text("hi"))\n' > "$HOME/.config/cmux/sidebars/workspaces.js"
out15="$(bash "$DOCTOR" 2>&1)"
case "$out15" in *"workspaces.js SHADOWS workspaces.swift"*"my-workspaces.js"*) ok "workspaces.js is reported with the rename that fixes it";;
  *) bad "a shadowing workspaces.js went unreported";; esac
rm -f "$HOME/.config/cmux/sidebars/workspaces.js"
# .json LOSES to .swift, so it must not cry wolf.
printf '{}\n' > "$HOME/.config/cmux/sidebars/workspaces.json"
out16="$(bash "$DOCTOR" 2>&1)"
case "$out16" in *"SHADOWS"*) bad "workspaces.json (which loses to .swift) was reported as a shadow";;
  *) ok "workspaces.json is not a shadow";; esac
rm -f "$HOME/.config/cmux/sidebars/workspaces.json"

echo "T14: native agent state is claimed only on cmux ≥ 0.64.23 with a sidebar that reads it"
printf 'USAGE_PROVIDERS="claude"\n' > "$HOME/.config/cmux/usage-sentinels.env"
case "$out" in *"native agent state"*) bad "an unreadable cmux version produced a native-data claim";;
  *) ok "unknown cmux version → no native-data claims";; esac
out17="$(STUB_CMUX_VERSION=0.64.23 bash "$DOCTOR" 2>&1)"
case "$out17" in *"cmux present and responding (v0.64.23)"*) ok "cmux version is reported";;
  *) bad "cmux version missing from the cmux line";; esac
case "$out17" in *"deployed one predates it — re-run install.sh"*) ok "an old sidebar on a new cmux is told to update";;
  *) bad "old sidebar on cmux 0.64.23 got no update hint";; esac
cp "$HOME/.config/cmux/sidebars/workspaces.swift" "$ROOT/old-sidebar.swift"
cat >> "$HOME/.config/cmux/sidebars/workspaces.swift" <<'SWIFT'
func workingAgentCount(_ w) -> Int { return w.agents.filter { $0.status == "working" }.count }
func isGroupAnchor(_ w) -> Bool { return groups.filter { $0.anchorId == w.id }.count > 0 }
SWIFT
out18="$(STUB_CMUX_VERSION=0.64.23 bash "$DOCTOR" 2>&1)"
case "$out18" in *"sidebar also reads cmux's native agent state"*) ok "a current sidebar on cmux 0.64.23 reports native agent state";;
  *) bad "native agent state not reported";; esac
case "$out18" in *"predates it"*) bad "a current sidebar was told it predates native data";;
  *) ok "no stale-sidebar hint for a current sidebar";; esac
out19="$(STUB_CMUX_VERSION=0.64.22 bash "$DOCTOR" 2>&1)"
case "$out19" in *"native agent state"*) bad "cmux 0.64.22 was credited with native agent state";;
  *) ok "cmux 0.64.22 gets no native-data claim";; esac
# 0.64.100 > 0.64.23 — numeric per component, not lexical.
out20="$(STUB_CMUX_VERSION=0.64.100 bash "$DOCTOR" 2>&1)"
case "$out20" in *"sidebar also reads cmux's native agent state"*) ok "0.64.100 compares as newer than 0.64.23";;
  *) bad "0.64.100 was compared lexically";; esac
# Without any bridge, a native-capable setup is NOT "working rows are off".
mv "$HOME/.config/cmux-sentinel/cmux-bridge.sh" "$ROOT/amp-bridge.bak"
out21="$(STUB_CMUX_VERSION=0.64.23 bash "$DOCTOR" 2>&1)"
case "$out21" in *"no bridge installed — Working… still comes from cmux's native agent state"*) ok "bridge-less + native → informational, names what the bridge adds";;
  *) bad "bridge-less native setup not explained";; esac
case "$out21" in *"working/compacting rows are off"*) bad "bridge-less native setup still claims working rows are off";;
  *) ok "no false 'rows are off' warning";; esac
out22="$(STUB_CMUX_VERSION=0.64.22 bash "$DOCTOR" 2>&1)"
case "$out22" in *"working/compacting rows are off"*) ok "bridge-less on an old cmux still warns";;
  *) bad "bridge-less old cmux lost its warning";; esac
mv "$ROOT/amp-bridge.bak" "$HOME/.config/cmux-sentinel/cmux-bridge.sh"

echo "T15: group names come from the sidebar natively — no sync nag"
G1='{"groups":[{"name":"Team","anchor_workspace_ref":"d1","is_collapsed":false,"member_workspace_refs":["d1"]}]}'
out23="$(STUB_GROUPS="$G1" STUB_CMUX_VERSION=0.64.23 bash "$DOCTOR" 2>&1)"
case "$out23" in *"sidebar shows group names natively (1 group(s), cmux v0.64.23)"*) ok "native group names reported";;
  *) bad "native group names not reported";; esac
case "$out23" in *"GROUP_NAME_SYNC is off"*|*"out of sync"*) bad "native group names still nagged about sync";;
  *) ok "no sync nag when the sidebar reads names itself";; esac
out24="$(STUB_GROUPS="$G1" STUB_CMUX_VERSION=0.64.23 GROUP_NAME_SYNC=1 bash "$DOCTOR" 2>&1)"
case "$out24" in *"GROUP_NAME_SYNC=1 is redundant"*) ok "enabled sync is called redundant, not broken";;
  *) bad "redundant sync not explained";; esac
out25="$(STUB_GROUPS="$G1" STUB_CMUX_VERSION=0.64.22 bash "$DOCTOR" 2>&1)"
case "$out25" in *"GROUP_NAME_SYNC is off"*) ok "old cmux keeps the sync advice";;
  *) bad "old cmux lost its sync advice";; esac
cp "$ROOT/old-sidebar.swift" "$HOME/.config/cmux/sidebars/workspaces.swift"
out26="$(STUB_GROUPS="$G1" STUB_CMUX_VERSION=0.64.23 bash "$DOCTOR" 2>&1)"
case "$out26" in *"GROUP_NAME_SYNC is off"*) ok "an old sidebar on a new cmux keeps the sync advice";;
  *) bad "old sidebar was credited with native group names";; esac

echo "T16: a key the meters CAN'T give back is a note, not a warning"
# 9 keys, 8 real workspaces: some meter has to hold a key however the rows are
# parked. Setup's best layout keeps ⌘9 real and hands ⌘8 to a meter; telling the user
# to "re-park them" there is advice that can't work and a warning nobody can clear.
printf 'USAGE_PROVIDERS="claude codex amp"\n' > "$HOME/.config/cmux/usage-sentinels.env"
out27="$(STUB_WINB=eight-parked bash "$DOCTOR" 2>&1)"
case "$out27" in *"are eating ⌘8 — unavoidable with 8 real workspace(s)"*) ok "8 reals, best layout → ⌘8 reported as unavoidable";;
  *) bad "unavoidable ⌘8 not explained";; esac
case "$out27" in *"re-park them"*) bad "told to re-park a layout that is already optimal";;
  *) ok "no futile re-park advice";; esac
# Same 8 reals with the meters at the very bottom: the COUNT is the same, but ⌘9 (the
# "last workspace" key) sits on a meter and setup can move it — still a warning.
out28="$(STUB_WINB=eight-last bash "$DOCTOR" 2>&1)"
case "$out28" in *"are eating ⌘9 — re-park them"*) ok "⌘9 on a meter is still fixable drift";;
  *) bad "fixable ⌘9 drift was downgraded";; esac
# T9's grouped windows leave 8 and 6 NUMBERED reals, so their lost keys are unavoidable too.
case "$out5$out6" in *"re-park them"*) bad "group-shifted meters with 8 numbered reals still told to re-park";;
  *) ok "group-shifted meters with no spare real row are not nagged";; esac

echo "T17: the doctor says when it is not the copy this machine runs"
# The failure this closes: `cmux-sentinel` on PATH can be a Homebrew wrapper into
# the Cellar (the last RELEASE) while ~/bin holds a newer deployed copy. The
# Cellar doctor then reports findings its own fix already removed — which is
# exactly how a warning outlives the code that stopped emitting it.
mkdir -p "$HOME/bin"
printf '#!/bin/bash\n# a DIFFERENT doctor\n' > "$HOME/bin/cmux-sentinel-doctor.sh"
out17="$(bash "$DOCTOR" 2>&1)"
case "$out17" in *"DIFFERS from the installed"*) ok "a doctor unlike the installed copy says so";;
  *) bad "silent about running a different doctor than is installed";; esac
case "$out17" in *"not what runs"*) ok "says its findings describe this file";;
  *) bad "did not explain why that matters";; esac
# Identical bytes are the normal case and must stay quiet, or every ~/bin install
# grows a permanent note about itself.
cp "$DOCTOR" "$HOME/bin/cmux-sentinel-doctor.sh"
out17b="$(bash "$DOCTOR" 2>&1)"
case "$out17b" in *"DIFFERS from the installed"*) bad "warned when the two copies are identical";;
  *) ok "an identical installed copy stays quiet";; esac
# No installed copy at all (a fresh checkout) is not a drift condition.
rm -f "$HOME/bin/cmux-sentinel-doctor.sh"
out17c="$(bash "$DOCTOR" 2>&1)"
case "$out17c" in *"DIFFERS from the installed"*) bad "warned with nothing installed to differ from";;
  *) ok "no installed copy means no note";; esac

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
