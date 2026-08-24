#!/bin/bash
# sentinel-setup.sh — offline test for bin/cmux-sentinel-setup.sh.
#
# Stubs cmux (with a throwaway $HOME) so it runs in CI too. Asserts the idempotent
# create behaviour: only enabled providers get sentinels, existing ones are left
# alone, and the auto-naming guard reports the global state.
#
# Run:  make test   (or:  bash tests/sentinel-setup.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="${SETUP:-$HERE/../bin/cmux-sentinel-setup.sh}"
[ -f "$SETUP" ] || { echo "setup not found: $SETUP" >&2; exit 2; }
JQ="$(command -v jq)" || { echo "jq required" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-setup-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/home/.config/cmux"
ln -s "$JQ" "$ROOT/bin/jq"

# Fake cmux: ping ok; workspace create logs the --name; the set_auto_title probe
# reports global auto-naming OFF unless STUB_AUTONAMING=on.
#
# `workspace list` is STATEFUL so the shortcut-layout pass can be tested for real:
# it renders $SETUPTEST/.wslist (one "ref<TAB>title" line per workspace, in order)
# as JSON with a computed .index, and `reorder-workspace` actually moves a line.
# STUB_EXISTING seeds a list with the sentinels interleaved among real workspaces
# — i.e. exactly the state in which meters steal ⌘ keys.
cat > "$ROOT/bin/cmux" <<'FAKE'
#!/bin/bash
LOG="$SETUPTEST/.created"
STATE="$SETUPTEST/.ws.json"

# State is a JSON file ($SETUPTEST/.ws.json); `workspace list` just cats it and
# `reorder-workspace` moves one element with jq. Keeping JSON handling in jq (not
# a bash printf loop) keeps this stub small and predictable.
render() { cat "$STATE"; }

reorder() { # $1 = ref, $2 = final index — drop the element, re-insert at $2, renumber .index
  local tmp="$STATE.tmp"
  jq -c --arg r "$1" --argjson i "$2" '
    .workspaces as $w
    | ($w | map(.ref) | index($r)) as $pos
    | if $pos == null then $w
      else ($w | del(.[$pos])) as $rest
        | $rest[0:$i] + [$w[$pos]] + $rest[$i:]
      end
    | {workspaces: [to_entries[] | .value + {index: .key}]}
  ' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
}

case "$1" in
  ping) exit 0 ;;
  list-windows) printf '[{"id":"win-a"}]\n'; exit 0 ;;
  workspace-group) printf '%s\n' "${STUB_GROUPS:-{\"groups\":[]\}}"; exit 0 ;;
  reorder-workspace)
    shift; ref=""; idx=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --workspace) ref="$2"; shift 2 ;;
        --index) idx="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -f "$STATE" ] || exit 1
    reorder "$ref" "$idx" || exit 1
    echo "OK workspace=$ref index=$idx"; exit 0 ;;
  workspace)
    case "$2" in
      list) if [ -f "$STATE" ]; then render; else printf '{"workspaces":[]}\n'; fi ;;
      create)
        shift 2; name=""
        while [ $# -gt 0 ]; do case "$1" in --name) name="$2"; shift 2 ;; *) shift ;; esac; done
        printf '%s\n' "$name" >> "$LOG"; echo "OK workspace:99" ;;
    esac
    exit 0 ;;
  rpc)
    if [ "$2" = "workspace.set_auto_title" ]; then
      if [ "${STUB_AUTONAMING:-off}" = "on" ]; then echo "Error: missing required param workspace_id" >&2
      else echo "Error: disabled: Workspace auto-naming is disabled in Settings" >&2; fi
      exit 1
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$ROOT/bin/cmux"

export SETUPTEST="$ROOT" HOME="$ROOT/home" TMPDIR="$ROOT"
PATH="$ROOT/bin:/usr/bin:/bin"
CREATED="$ROOT/.created"
WSLIST="$ROOT/.ws.json"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  ✗ %s\n' "$1"; }
ck()  { local m="$1"; shift; if "$@"; then ok "$m"; else bad "$m"; fi; }   # cmd true
ckn() { local m="$1"; shift; if "$@"; then bad "$m"; else ok "$m"; fi; }   # cmd false
ckhas() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" ;; esac; }           # substring
created() { grep -qx -- "$1" "$CREATED" 2>/dev/null; }       # was label $1 created?
ncreated() { [ -f "$CREATED" ] && wc -l < "$CREATED" | tr -d ' ' || echo 0; }
reset() { rm -f "$CREATED" "$WSLIST"; }
seed() { local i=0 t; : > "$WSLIST.raw"; for t in "$@"; do printf '%s\n' "$t" >> "$WSLIST.raw"; done
         jq -R -s -c 'split("\n") | map(select(length>0)) | {workspaces: [to_entries[] | {index: .key, ref: ("w" + (.key+1|tostring)), title: .value}]}' "$WSLIST.raw" > "$WSLIST"; rm -f "$WSLIST.raw"; }
titles() { jq -r '[.workspaces[].title] | join("|")' "$WSLIST" 2>/dev/null; }   # current order

echo "T1: providers=claude → creates 5h + 7d (+ the always-on spend row)"
reset
USAGE_PROVIDERS="claude" bash "$SETUP" >/dev/null 2>&1; ck "exit 0" [ "$?" = 0 ]
ck  "created 5h"  created 5h
ck  "created 7d"  created 7d
ckn "did not create cx5h (codex disabled)" created cx5h
ckn "did not create m7d (per-model meter is opt-in)" created m7d
# The real poller can't reach an API from this fake $HOME, so it can't tell us
# whether the account has an overage budget — and silence never suppresses a
# sentinel. The row stays invisible until money is actually spent, so failing open
# here costs nothing; failing closed could hide a charge.
ck  "created spend (fails open, and hides itself when there's nothing to show)" created spend
ck  "exactly 3 created" [ "$(ncreated)" = 3 ]

echo "T2: providers=\"claude codex\" → creates all four"
# $HOME/PATH have no logged-in Codex CLI, so the real poller can't tell us
# which windows exist → setup fails open and creates both codex sentinels.
reset
USAGE_PROVIDERS="claude codex" bash "$SETUP" >/dev/null 2>&1
for l in 5h 7d cx5h cx7d; do ck "created $l" created "$l"; done

# ── per-window gating (CODEX_POLLER --buckets) ────────────────────────────────
# OpenAI dropped the 5h window for Codex Pro, so setup asks the poller which
# windows the account actually has rather than assuming both. A sentinel for a
# window that doesn't exist is a permanently-"n/a" row that still eats a ⌘ key.
stub_poller() { # $1 = what `--buckets` prints ("" = can't tell)
  # shellcheck disable=SC2016  # $1 belongs to the GENERATED script — must stay literal
  printf '#!/bin/bash\n[ "$1" = --buckets ] || exit 2\nprintf %%s "%s"\n' "$1" > "$ROOT/bin/poller"
  chmod +x "$ROOT/bin/poller"
}

echo "T2b: poller reports weekly-only → cx5h skipped, cx7d still created"
reset
stub_poller 'cx7d
'
out=$(USAGE_PROVIDERS="claude codex" CODEX_POLLER="$ROOT/bin/poller" bash "$SETUP" 2>&1)
ckn "did not create cx5h (no 5h window on this account)" created cx5h
ck  "created cx7d (window exists)" created cx7d
ck  "claude sentinels unaffected" created 5h
ckhas "explains the skip" "$out" "skipping 'cx5h'"

echo "T2c: poller can't tell (offline/expired) → FAILS OPEN, creates both"
reset
stub_poller ''
USAGE_PROVIDERS="claude codex" CODEX_POLLER="$ROOT/bin/poller" bash "$SETUP" >/dev/null 2>&1
ck "created cx5h (empty answer must not suppress a meter)" created cx5h
ck "created cx7d" created cx7d

echo "T2d: poller reports both windows → both created (5h restored upstream)"
reset
stub_poller 'cx5h
cx7d
'
USAGE_PROVIDERS="claude codex" CODEX_POLLER="$ROOT/bin/poller" bash "$SETUP" >/dev/null 2>&1
ck "created cx5h (window came back → meter returns by itself)" created cx5h
ck "created cx7d" created cx7d

echo "T2e: Amp offline/undetermined + default config → FAILS OPEN to ampu only"
reset
stub_poller ''
USAGE_PROVIDERS="amp" AMP_POLLER="$ROOT/bin/poller" bash "$SETUP" >/dev/null 2>&1
ck  "created ampu (normal meter fails open)" created ampu
ckn "did not create opt-in ampo while offline" created ampo

echo "T2f: Amp online + default config → ampu only"
reset
stub_poller 'ampu
'
USAGE_PROVIDERS="amp" AMP_POLLER="$ROOT/bin/poller" bash "$SETUP" >/dev/null 2>&1
ck  "created ampu (reported live)" created ampu
ckn "did not create ampo without opt-in" created ampo

echo "T2g: AMP_ORB_METER=1 → creates ampu + ampo"
reset
stub_poller 'ampu
ampo
'
USAGE_PROVIDERS="amp" AMP_ORB_METER=1 AMP_POLLER="$ROOT/bin/poller" bash "$SETUP" >/dev/null 2>&1
ck "created ampu with orb opt-in" created ampu
ck "created ampo with orb opt-in" created ampo

# The per-model Claude cap follows the SAME local-opt-in policy as the orb meter:
# the flag is the user's positive request, and the poller then says whether the
# account actually has such a cap.
echo "T2h: CLAUDE_MODEL_METER=1 + the account has a per-model cap → creates m7d"
reset
stub_poller '5h
7d
m7d
'
USAGE_PROVIDERS="claude" CLAUDE_MODEL_METER=1 CLAUDE_POLLER="$ROOT/bin/poller" bash "$SETUP" >/dev/null 2>&1
ck "created 5h" created 5h
ck "created 7d" created 7d
ck "created m7d with the model-meter opt-in" created m7d

echo "T2i: opted in but the account has NO per-model cap → m7d skipped"
reset
stub_poller '5h
7d
'
out=$(USAGE_PROVIDERS="claude" CLAUDE_MODEL_METER=1 CLAUDE_POLLER="$ROOT/bin/poller" bash "$SETUP" 2>&1)
ckn "did not create a permanently-n/a m7d row" created m7d
ckhas "explains the skip" "$out" "skipping 'm7d'"
ck  "the account-wide meters are unaffected" created 7d

echo "T2j: opted in but the poller can't tell → FAILS OPEN, creates m7d"
reset
stub_poller ''
USAGE_PROVIDERS="claude" CLAUDE_MODEL_METER=1 CLAUDE_POLLER="$ROOT/bin/poller" bash "$SETUP" >/dev/null 2>&1
ck "created m7d (silence must never suppress an explicitly requested meter)" created m7d

echo "T2k: a live per-model cap without the opt-in still creates nothing"
reset
stub_poller '5h
7d
m7d
'
USAGE_PROVIDERS="claude" CLAUDE_POLLER="$ROOT/bin/poller" bash "$SETUP" >/dev/null 2>&1
ckn "the cap existing is not consent to spend a ⌘ key on it" created m7d

# The spend meter is the ONE row with no opt-in flag: the sidebar hides it while
# the balance is zero, so it costs nothing to look at — and a flag you never set
# could never warn you about a charge you didn't expect.
echo "T2l: the spend sentinel needs no opt-in, but does need an overage budget"
reset
stub_poller '5h
7d
spend
'
USAGE_PROVIDERS="claude" CLAUDE_POLLER="$ROOT/bin/poller" bash "$SETUP" >/dev/null 2>&1
ck "created spend with no flag at all" created spend
reset
stub_poller '5h
7d
'
USAGE_PROVIDERS="claude" CLAUDE_POLLER="$ROOT/bin/poller" bash "$SETUP" >/dev/null 2>&1
ckn "no overage budget → no spend sentinel" created spend
rm -f "$ROOT/bin/poller"

echo "T3: idempotent — existing sentinels are left alone"
reset
seed "5h x" "7d x" "spend |none|" "cx5h x" "cx7d x"
out=$(USAGE_PROVIDERS="claude codex" bash "$SETUP" 2>&1); rc=$?
ck "exit 0" [ "$rc" = 0 ]
ck "created nothing (all exist)" [ "$(ncreated)" = 0 ]
ckhas "reported existing" "$out" "already exists"

echo "T4: auto-naming guard reports global state"
reset
out=$(USAGE_PROVIDERS="claude" bash "$SETUP" 2>&1)
ckhas "OFF → reports safe" "$out" "auto-naming is OFF"
out=$(STUB_AUTONAMING=on USAGE_PROVIDERS="claude" bash "$SETUP" 2>&1)
ckhas "ON → warns" "$out" "may be ON"

# ── shortcut layout ───────────────────────────────────────────────────────────
# Invariant: sentinels end up in the keyless band (indices 8…count-2) and the LAST
# workspace is a real one — so ⌘1…⌘8 (indices 0…7) and ⌘9 (count-1) all hit real
# workspaces. Meters interleaved among reals is the state that steals keys.
echo "T5: layout parks meters below the list and anchors ⌘9 on the last real"
reset
seed a b c d e "cx7d ▎ 3%" "cx5h n/a" f g h i j k "5h ███ 41%" l "7d ██ 58%" "spend |none|"
out=$(USAGE_PROVIDERS="claude codex" bash "$SETUP" 2>&1)
ck "created nothing (all exist)" [ "$(ncreated)" = 0 ]
ckhas "reported parking" "$out" "parked"
ckhas "reported ⌘9 anchor" "$out" "anchored"
at() { jq -r --argjson i "$1" '.workspaces[$i].title // ""' "$WSLIST"; }   # title at index
ck "real workspaces keep their relative order" \
   [ "$(jq -r '[.workspaces[].title | select(test("^(5h|7d|m7d|spend|cx5h|cx7d)( |$)") | not)] | join("|")' "$WSLIST")" \
     = "a|b|c|d|e|f|g|h|i|j|k|l" ]
# ⌘1…⌘8 = indices 0-7
for i in 0 1 2 3 4 5 6 7; do
  t=$(at "$i")
  case "$t" in 5h*|7d*|cx5h*|cx7d*) bad "Cmd+$((i + 1)) hits a meter ($t)" ;; *) ok "Cmd+$((i + 1)) → real ($t)" ;; esac
done
# ⌘9 = last workspace
last=$(jq -r '.workspaces[-1].title' "$WSLIST")
case "$last" in 5h*|7d*|m7d*|spend*|cx5h*|cx7d*) bad "Cmd+9 hits a meter ($last)" ;; *) ok "Cmd+9 → real ($last)" ;; esac
ck "all five meters sit in the keyless band (indices 8…count-2)" \
   [ "$(jq -r '[.workspaces[8:-1][] | select(.title | test("^(5h|7d|m7d|spend|cx5h|cx7d)( |$)"))] | length' "$WSLIST")" = 5 ]

echo "T6: layout is idempotent — a second run converges to the same order"
before=$(titles)
USAGE_PROVIDERS="claude codex" bash "$SETUP" >/dev/null 2>&1
ck "order unchanged on re-run" [ "$(titles)" = "$before" ]

echo "T7: --no-layout / SENTINEL_LAYOUT=0 leave the order alone"
reset
seed a "5h ███" b "7d ██" c
before=$(titles)
out=$(USAGE_PROVIDERS="claude" bash "$SETUP" --no-layout 2>&1)
ck "--no-layout: order untouched" [ "$(titles)" = "$before" ]
case "$out" in *parked*) bad "--no-layout: says nothing about parking" ;; *) ok "--no-layout: says nothing about parking" ;; esac
SENTINEL_LAYOUT=0 USAGE_PROVIDERS="claude" bash "$SETUP" >/dev/null 2>&1
ck "SENTINEL_LAYOUT=0: order untouched" [ "$(titles)" = "$before" ]

echo "T8: degenerate lists don't scramble anything"
reset
seed "5h ███" "7d ██"                       # sentinels only, no real workspace
out=$(USAGE_PROVIDERS="claude" bash "$SETUP" 2>&1); rc=$?
ck "exit 0 with no reals" [ "$rc" = 0 ]
ckhas "reports it can't anchor ⌘9" "$out" "too few workspaces"
reset
seed a "5h ███" "7d ██"                     # exactly one real — don't bury it
out=$(USAGE_PROVIDERS="claude" bash "$SETUP" 2>&1)
ck "single real workspace stays at index 0 (keeps ⌘1)" [ "$(jq -r '.workspaces[0].title' "$WSLIST")" = "a" ]
reset
out=$(USAGE_PROVIDERS="claude codex" bash "$SETUP" 2>&1)   # no workspaces at all
ckhas "empty list → nothing to park" "$out" "no sentinels to park"

echo "T9: ⌘9 is anchored on a row cmux actually NUMBERS, never a group anchor"
# Since 0.64.22 (#9176) a group's anchor renders as the group HEADER and is left
# out of the ⌘1…⌘9 numbering. Parking it last therefore hands ⌘9 to whatever is
# numbered last — a meter — which is precisely the key this pass exists to save.
# seed order: one, two, 5h, grp-anchor(w4). Picking the last non-meter by raw
# index selects the anchor; the numbered choice is "two".
reset
seed one two "5h ███ 41%" grp-anchor
STUB_GROUPS='{"groups":[{"name":"G","anchor_workspace_ref":"w4","is_collapsed":false,"member_workspace_refs":["w4"]}]}' \
  USAGE_PROVIDERS="claude" bash "$SETUP" >/dev/null 2>&1
last=$(jq -r '.workspaces[-1].title' "$WSLIST")
case "$last" in grp-anchor) bad "⌘9 parked on the group anchor — it renders as a header, so a meter takes ⌘9" ;;
  5h*|7d*) bad "⌘9 landed on a meter ($last)" ;;
  *) ok "⌘9 anchored on a numbered real workspace ($last)" ;; esac
# The anchor must still be present — this pass reorders, it never drops a row.
ck "group anchor is still in the list" [ "$(jq -r '[.workspaces[].title | select(. == "grp-anchor")] | length' "$WSLIST")" = 1 ]

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
