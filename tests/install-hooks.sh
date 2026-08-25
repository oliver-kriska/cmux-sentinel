#!/bin/bash
# install-hooks.sh — offline test for install.sh's Claude-hook auto-registration
# (register_hooks). This is the onboarding step that used to be a manual "see
# README" note; a regression here silently leaves new users with no live row
# states, so it's worth a real end-to-end test.
#
# Runs the ACTUAL install.sh against a throwaway $HOME (its main flow makes no
# launchctl/security/network calls, only file copies), then asserts the hook
# merge: every event wired, pre-existing user hooks preserved, idempotent on
# re-run, and a graceful no-op when jq is unavailable.
#
# Run:  make test   (or:  bash tests/install-hooks.sh)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="${INSTALL:-$HERE/../install.sh}"
[ -f "$INSTALL" ] || { echo "install.sh not found: $INSTALL" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required for this test" >&2; exit 2; }

EVENTS="SessionStart UserPromptSubmit PreToolUse PreCompact PostCompact Stop StopFailure Notification PostToolUseFailure SessionEnd"
# Literal ~ on purpose: this is the exact command string install.sh writes into
# settings.json (Claude Code expands it at hook-exec time), so we match it verbatim.
# shellcheck disable=SC2088
BRIDGE='~/.claude/hooks/cmux-bridge.sh'

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-install-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
SBX="$ROOT/home"; mkdir -p "$SBX/.claude"
SETTINGS="$SBX/.claude/settings.json"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  ✗ %s\n' "$1"; }
# count cmux-bridge references registered for one event
bridgecount() { jq --arg e "$1" --arg c "$BRIDGE" \
  '[(.hooks[$e] // [])[].hooks[]? | select(.command == $c)] | length' "$SETTINGS" 2>/dev/null; }
runinstall() { ( cd "$ROOT" && WITH_BRIDGE=1 HOME="$SBX" NO_SETUP=1 bash "$INSTALL" ) >/dev/null 2>&1; }

# Pre-seed settings.json: an UNRELATED user hook on PreToolUse (must survive) and a
# cmux-bridge already on Stop (must NOT be duplicated).
cat > "$SETTINGS" <<'JSON'
{
  "hooks": {
    "PreToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/my/other-hook.sh" }] }],
    "Stop":       [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/cmux-bridge.sh", "async": true }] }]
  }
}
JSON

echo "T1: first run wires every hook event to cmux-bridge"
runinstall; rc=$?
if [ "$rc" = 0 ]; then ok "install.sh exited 0"; else bad "install.sh exited $rc"; fi
miss=""
for ev in $EVENTS; do
  n="$(bridgecount "$ev")"
  case "$n" in ''|0) miss="$miss $ev" ;; esac
done
if [ -z "$miss" ]; then ok "all events reference cmux-bridge"; else bad "events NOT wired:$miss"; fi

echo "T2: pre-existing user hook preserved, existing cmux-bridge not duplicated"
if jq -e '[.hooks.PreToolUse[].hooks[]? | select(.command == "~/my/other-hook.sh")] | length == 1' "$SETTINGS" >/dev/null 2>&1; then
  ok "unrelated PreToolUse hook still present"
else bad "unrelated PreToolUse hook was lost"; fi
if [ "$(bridgecount Stop)" = 1 ]; then ok "Stop's existing cmux-bridge not duplicated"
else bad "Stop cmux-bridge count = $(bridgecount Stop) (want 1)"; fi

echo "T3: idempotent — a second run adds no duplicates"
runinstall
dups=""
for ev in $EVENTS; do
  [ "$(bridgecount "$ev")" = 1 ] || dups="$dups $ev=$(bridgecount "$ev")"
done
if [ -z "$dups" ]; then ok "every event has exactly one cmux-bridge after re-run"; else bad "duplicate registrations:$dups"; fi

echo "T3b: plain re-run refreshes an already-registered Claude bridge"
printf '#!/bin/bash\n# stale\n' > "$SBX/.claude/hooks/cmux-bridge.sh"
( cd "$ROOT" && HOME="$SBX" NO_SETUP=1 bash "$INSTALL" ) >/dev/null 2>&1
if cmp -s "$HERE/../hooks/cmux-bridge.sh" "$SBX/.claude/hooks/cmux-bridge.sh"; then ok "plain re-run refreshed Claude bridge"; else bad "plain re-run left Claude bridge stale"; fi
if [ "$(bridgecount SessionStart)" = 1 ]; then ok "existing Claude registration remains idempotent"; else bad "cmux-bridge SessionStart count = $(bridgecount SessionStart)"; fi

echo "T4: jq unavailable → graceful no-op, settings.json untouched"
# Build a bin with symlinks to ONLY the tools install.sh needs — deliberately no
# jq — and run with PATH pointed there. (Trimming PATH to /usr/bin:/bin isn't
# enough: some systems ship /usr/bin/jq.)
NOJQ="$ROOT/nojqbin"; mkdir -p "$NOJQ"
for t in bash cat cmp cp date dirname id install mkdir mktemp mv rm sed; do
  p="$(command -v "$t")" && ln -sf "$p" "$NOJQ/$t"
done
if [ ! -e "$NOJQ/jq" ]; then ok "test bin has no jq (precondition)"; else bad "could not build a jq-less bin"; fi
# Fresh settings with only the unrelated hook.
printf '{"hooks":{"PreToolUse":[{"matcher":"","hooks":[{"type":"command","command":"~/my/other-hook.sh"}]}]}}\n' > "$SETTINGS"
before="$(cat "$SETTINGS")"
( cd "$ROOT" && WITH_BRIDGE=1 HOME="$SBX" PATH="$NOJQ" NO_SETUP=1 bash "$INSTALL" ) >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "install.sh still exited 0 without jq"; else bad "install.sh exited $rc without jq"; fi
if [ "$(cat "$SETTINGS")" = "$before" ]; then ok "settings.json left untouched (no clobber)"; else bad "settings.json was modified without jq"; fi

# ---- Zed integration (opt-in via --with-zed / WITH_ZED=1) --------------------
# zed-bridge handles 8 of the 10 events (no StopFailure / PostToolUseFailure), so we
# also assert it stays OFF those two — proves the event list, not just "wired".
ZED_EVENTS="SessionStart UserPromptSubmit PreToolUse PreCompact PostCompact Notification Stop SessionEnd"
# shellcheck disable=SC2088
ZED='~/.claude/hooks/zed-bridge.sh'
zedcount() { jq --arg e "$1" --arg c "$ZED" \
  '[(.hooks[$e] // [])[].hooks[]? | select(.command == $c)] | length' "$SETTINGS" 2>/dev/null; }

echo "T5: --with-zed (flag) wires zed-bridge for its 8 events + installs the helpers"
( cd "$ROOT" && HOME="$SBX" NO_SETUP=1 bash "$INSTALL" --with-zed ) >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "install.sh --with-zed exited 0"; else bad "install.sh --with-zed exited $rc"; fi
zmiss=""
for ev in $ZED_EVENTS; do
  n="$(zedcount "$ev")"; case "$n" in ''|0) zmiss="$zmiss $ev" ;; esac
done
if [ -z "$zmiss" ]; then ok "all zed events reference zed-bridge"; else bad "zed events NOT wired:$zmiss"; fi
zno=""
for ev in StopFailure PostToolUseFailure; do
  [ "$(zedcount "$ev")" = 0 ] || zno="$zno $ev=$(zedcount "$ev")"
done
if [ -z "$zno" ]; then ok "zed-bridge absent from cmux-only events"; else bad "zed-bridge wrongly on:$zno"; fi
for f in .claude/hooks/zed-bridge.sh bin/cmux-open-in-zed.sh bin/zed-usage-tui.sh; do
  if [ -x "$SBX/$f" ]; then ok "installed $f"; else bad "missing $f"; fi
done

echo "T6: WITH_ZED=1 re-run is idempotent and does not infer Claude opt-in"
( cd "$ROOT" && WITH_ZED=1 HOME="$SBX" NO_SETUP=1 bash "$INSTALL" ) >/dev/null 2>&1
zdups=""
for ev in $ZED_EVENTS; do
  [ "$(zedcount "$ev")" = 1 ] || zdups="$zdups $ev=$(zedcount "$ev")"
done
if [ -z "$zdups" ]; then ok "every zed event has exactly one zed-bridge after re-run"; else bad "duplicate zed registrations:$zdups"; fi
if [ "$(bridgecount SessionStart)" = 0 ]; then ok "--with-zed does not infer Claude opt-in from a leftover bridge file"; else bad "cmux-bridge SessionStart count = $(bridgecount SessionStart) (want 0)"; fi

echo "T7: a default install (no flags/env) stays Zed-free; unknown flag rejected"
SBX2="$ROOT/home2"; mkdir -p "$SBX2/.claude"
( cd "$ROOT" && HOME="$SBX2" NO_SETUP=1 bash "$INSTALL" ) >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "default install exited 0"; else bad "default install exited $rc"; fi
if [ ! -e "$SBX2/.claude/hooks/zed-bridge.sh" ]; then ok "no zed-bridge.sh on default install"; else bad "zed-bridge.sh installed by default"; fi
if [ ! -e "$SBX2/.claude/hooks/cmux-bridge.sh" ]; then ok "no cmux-bridge.sh on default install"; else bad "cmux-bridge.sh installed by default"; fi
S2="$SBX2/.claude/settings.json"
if [ ! -f "$S2" ] || ! grep -q -e cmux-bridge -e zed-bridge "$S2" 2>/dev/null; then ok "default settings carries no bridge hooks"; else bad "default install wrote bridge hooks"; fi
( cd "$ROOT" && HOME="$SBX2" NO_SETUP=1 bash "$INSTALL" --bogus ) >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then ok "unknown flag → exit 2"; else bad "unknown flag exit $rc (want 2)"; fi

echo "T8: Amp-only install uses a neutral bridge and never opts into Claude hooks"
SBX3="$ROOT/home3"; mkdir -p "$SBX3/.claude"
( cd "$ROOT" && HOME="$SBX3" NO_SETUP=1 bash "$INSTALL" --with-amp ) >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "install.sh --with-amp exited 0"; else bad "install.sh --with-amp exited $rc"; fi
if [ -x "$SBX3/.config/cmux-sentinel/cmux-bridge.sh" ]; then ok "Amp shared bridge installed at neutral path"; else bad "neutral Amp shared bridge missing"; fi
if [ -f "$SBX3/.config/amp/plugins/cmux-sentinel-amp.ts" ]; then ok "Amp plugin installed"; else bad "Amp plugin missing"; fi
if [ ! -e "$SBX3/.claude/hooks/cmux-bridge.sh" ]; then ok "Amp-only install creates no Claude bridge"; else bad "Amp-only install created Claude bridge"; fi
if [ ! -f "$SBX3/.claude/settings.json" ] || ! grep -q cmux-bridge "$SBX3/.claude/settings.json" 2>/dev/null; then ok "Amp-only install registers no Claude hooks"; else bad "Amp-only install registered Claude hooks"; fi

echo "T9: plain re-run refreshes Amp without turning Claude integration on"
( cd "$ROOT" && HOME="$SBX3" NO_SETUP=1 bash "$INSTALL" ) >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "plain re-run after Amp exited 0"; else bad "plain re-run after Amp exited $rc"; fi
if [ -x "$SBX3/.config/cmux-sentinel/cmux-bridge.sh" ]; then ok "plain re-run keeps neutral Amp bridge"; else bad "plain re-run lost neutral Amp bridge"; fi
if [ ! -e "$SBX3/.claude/hooks/cmux-bridge.sh" ]; then ok "plain re-run still creates no Claude bridge"; else bad "plain re-run created Claude bridge"; fi
if [ ! -f "$SBX3/.claude/settings.json" ] || ! grep -q cmux-bridge "$SBX3/.claude/settings.json" 2>/dev/null; then ok "plain re-run still registers no Claude hooks"; else bad "plain re-run registered Claude hooks"; fi

echo "T10: legacy Amp-only install migrates without enabling Claude hooks"
SBX4="$ROOT/home4"; mkdir -p "$SBX4/.claude/hooks" "$SBX4/.config/amp/plugins"
printf '#!/bin/bash\n# legacy Amp dependency\n' > "$SBX4/.claude/hooks/cmux-bridge.sh"
printf '// legacy Amp plugin\n' > "$SBX4/.config/amp/plugins/cmux-sentinel-amp.ts"
printf '{"hooks":{}}\n' > "$SBX4/.claude/settings.json"
( cd "$ROOT" && HOME="$SBX4" NO_SETUP=1 bash "$INSTALL" ) >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "legacy Amp update exited 0"; else bad "legacy Amp update exited $rc"; fi
if [ -x "$SBX4/.config/cmux-sentinel/cmux-bridge.sh" ]; then ok "legacy Amp dependency migrated to neutral path"; else bad "legacy Amp dependency not migrated"; fi
if ! grep -q cmux-bridge "$SBX4/.claude/settings.json" 2>/dev/null; then ok "legacy Amp update keeps Claude hooks disabled"; else bad "legacy Amp update enabled Claude hooks"; fi

echo "T11: changed loaded plists get guidance or an explicit targeted reload"
SBX5="$ROOT/home5"; mkdir -p "$SBX5"
RELOAD_BIN="$ROOT/reloadbin"; RELOAD_LOG="$ROOT/.launchctl"; mkdir -p "$RELOAD_BIN"
cat > "$RELOAD_BIN/launchctl" <<'FAKE'
#!/bin/bash
case "${1:-}" in
  print) case "${2:-}" in */com.cmux-codex-usage) exit 0 ;; *) exit 1 ;; esac ;;
  bootout)
    printf '%s\n' "$*" >> "$RELOAD_LOG"
    [ "${STUB_BOOTOUT_FAIL:-0}" = 1 ] && exit 1
    exit 0
    ;;
  bootstrap)
    printf '%s\n' "$*" >> "$RELOAD_LOG"
    [ "${STUB_BOOTSTRAP_FAIL:-0}" = 1 ] && exit 1
    exit 0
    ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$RELOAD_BIN/launchctl"
reload_env() {
  ( cd "$ROOT" && RELOAD_LOG="$RELOAD_LOG" HOME="$SBX5" \
      PATH="$RELOAD_BIN:/usr/bin:/bin" NO_SETUP=1 bash "$INSTALL" "$@" )
}

# Establish an exact generated baseline, then make only Codex's installed plist
# stale. A normal update must rewrite it but leave the loaded job uninterrupted.
reload_env >/dev/null 2>&1
codex_plist="$SBX5/Library/LaunchAgents/com.cmux-codex-usage.plist"
printf '\n<!-- stale -->\n' >> "$codex_plist"
rm -f "$RELOAD_LOG"
reload_out="$(reload_env 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "changed loaded plist update exited 0"; else bad "changed loaded plist update exited $rc"; fi
if [ ! -s "$RELOAD_LOG" ]; then ok "default update did not interrupt the loaded job"; else bad "default update unexpectedly called launchctl"; fi
case "$reload_out" in
  *"com.cmux-codex-usage is loaded"*"launchctl bootout"*"launchctl bootstrap"*"--reload-agents"*) ok "default update prints exact reload guidance" ;;
  *) bad "default update omitted reload guidance" ;;
esac

# With explicit permission, only the changed+loaded Codex job is cycled. An
# unchanged subsequent run must not touch launchd at all.
printf '\n<!-- stale again -->\n' >> "$codex_plist"
rm -f "$RELOAD_LOG"
reload_env --reload-agents >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "--reload-agents exited 0"; else bad "--reload-agents exited $rc"; fi
if [ "$(wc -l < "$RELOAD_LOG" 2>/dev/null | tr -d ' ')" = 2 ] \
  && grep -q '^bootout .*com.cmux-codex-usage.plist$' "$RELOAD_LOG" \
  && grep -q '^bootstrap .*com.cmux-codex-usage.plist$' "$RELOAD_LOG"; then
  ok "explicit reload cycles only the changed loaded Codex job"
else bad "explicit reload calls were not the expected bootout + bootstrap"; fi
rm -f "$RELOAD_LOG"
reload_env --reload-agents >/dev/null 2>&1
if [ ! -s "$RELOAD_LOG" ]; then ok "unchanged plists are never reloaded"; else bad "unchanged install touched launchd"; fi

# launchctl failures must not abort the installer halfway through or hide how to
# recover. A failed bootout leaves the old definition loaded; a failed bootstrap
# may leave it unloaded. Both paths retain the newly written plist for a retry.
printf '\n<!-- stale for bootout failure -->\n' >> "$codex_plist"
rm -f "$RELOAD_LOG"
reload_out="$(STUB_BOOTOUT_FAIL=1 reload_env --reload-agents 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$reload_out" | grep -q "old definition remains loaded" \
  && printf '%s' "$reload_out" | grep -q "launchctl bootstrap"; then
  ok "bootout failure continues installation with exact recovery guidance"
else bad "bootout failure aborted or omitted recovery guidance"; fi

printf '\n<!-- stale for bootstrap failure -->\n' >> "$codex_plist"
rm -f "$RELOAD_LOG"
reload_out="$(STUB_BOOTSTRAP_FAIL=1 reload_env --reload-agents 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$reload_out" | grep -q "may currently be unloaded" \
  && printf '%s' "$reload_out" | grep -q "launchctl bootstrap"; then
  ok "bootstrap failure continues installation with exact recovery guidance"
else bad "bootstrap failure aborted or omitted recovery guidance"; fi

echo "T12: backups are content-aware and bounded"
# Re-running the installer IS the documented update path, so an unconditional
# backup wrote one dead file per run. Those piles bury the one backup that
# matters, so: no copy when nothing changes, and keep only INSTALL_BAK_KEEP.
brg="$SBX/.claude/hooks/cmux-bridge.sh"
nbak() { local c=0 f; for f in "$brg".bak.*; do [ -e "$f" ] && c=$((c + 1)); done; printf '%s' "$c"; }

runinstall                       # converge: deployed bridge == repo bridge
rm -f "$brg".bak.*
runinstall
if [ "$(nbak)" = 0 ]; then ok "unchanged re-run creates no backup"
else bad "unchanged re-run still wrote $(nbak) backup(s)"; fi

printf '\n# local edit\n' >> "$brg"      # a real difference must be preserved
runinstall
if [ "$(nbak)" = 1 ]; then ok "a changed file is backed up exactly once"
else bad "changed file produced $(nbak) backups (expected 1)"; fi
if grep -q "local edit" "$brg".bak.* 2>/dev/null; then ok "the backup holds the REPLACED content"
else bad "backup did not capture the overwritten file"; fi

for e in 1000000001 1000000002 1000000003 1000000004 1000000005; do
  printf 'old\n' > "$brg.bak.$e"        # a pre-existing pile, oldest-first names
done
printf '\n# another edit\n' >> "$brg"
( cd "$ROOT" && WITH_BRIDGE=1 HOME="$SBX" INSTALL_BAK_KEEP=2 NO_SETUP=1 bash "$INSTALL" ) >/dev/null 2>&1
if [ "$(nbak)" -le 2 ]; then ok "history pruned to INSTALL_BAK_KEEP ($(nbak) kept)"
else bad "prune left $(nbak) backups, expected <= 2"; fi
if [ -e "$brg".bak.1000000001 ]; then bad "prune kept the OLDEST backup"
else ok "prune drops oldest first"; fi

echo "T13: an already-wired settings.json is not rewritten, backed up, or announced"
# `ensure` is idempotent, so the old order (back up → jq → mv → announce) rewrote
# settings.json byte-identically every run: a junk backup each time (11 had piled
# up on the maintainer's box) plus a false "RESTART Claude Code" instruction.
rm -f "$SETTINGS".bak.*
before="$(cat "$SETTINGS")"
out="$(cd "$ROOT" && WITH_BRIDGE=1 HOME="$SBX" NO_SETUP=1 bash "$INSTALL" 2>&1)"
if [ "$(cat "$SETTINGS")" = "$before" ]; then ok "settings.json byte-identical after a no-op run"
else bad "settings.json was rewritten with no change to make"; fi
nset=0; for f in "$SETTINGS".bak.*; do [ -e "$f" ] && nset=$((nset + 1)); done
if [ "$nset" = 0 ]; then ok "no settings.json backup for a no-op run"
else bad "no-op run still wrote $nset settings.json backup(s)"; fi
case "$out" in *"already wired"*) ok "reports 'already wired' instead of a restart prompt";;
  *) bad "no-op run did not report the already-wired state";; esac
# Scope this to the ACTION line ("-> wired … into …"). The NEXT STEPS block also
# mentions restarting Claude Code, but as static prose explaining WITH_BRIDGE=1 —
# that is not a claim about this run and must not fail the test.
case "$out" in *"-> wired"*) bad "no-op run still claimed it wired the hooks";;
  *) ok "no misleading 'wired … RESTART' action line on a no-op run";; esac

echo "T14: the installer finishes the job — and never fails because it tried"
# Deploying files used to be the whole install; the first person to UPDATE saw
# "✅ Files installed" and an unchanged sidebar, because the release's new meters
# had no workspaces and setup was left as a manual step nobody knew to repeat.
# Setup now runs automatically, which makes its FAILURE MODES load-bearing: an
# install must still succeed on a machine with no cmux, or with a cmux that says
# no. (Every other test in this file passes NO_SETUP=1 for exactly this reason —
# otherwise `make test` would reach the developer's real cmux and create real
# workspaces.)
SBX6="$ROOT/home6"; mkdir -p "$SBX6"
NOCMUX="$ROOT/nocmux"; mkdir -p "$NOCMUX"
for t in jq install sed grep cat mkdir rm cp chmod printf date dirname basename cmp mv ln find sort head tail wc; do
  src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$NOCMUX/$t" 2>/dev/null
done
out14="$( (cd "$ROOT" && HOME="$SBX6" PATH="$NOCMUX:/usr/bin:/bin" bash "$INSTALL") 2>&1 )"; rc14=$?
if [ "$rc14" = 0 ]; then ok "no cmux on PATH → install still succeeds"; else bad "install failed with no cmux (rc $rc14)"; fi
case "$out14" in *"cmux isn't on PATH"*) ok "says why setup was skipped" ;;
  *) bad "skipped setup silently when cmux was absent" ;; esac
if [ -f "$SBX6/bin/cmux-sentinel-setup.sh" ]; then ok "files still deployed without cmux"; else bad "no cmux meant no files"; fi

SBX7="$ROOT/home7"; mkdir -p "$SBX7"
out15="$( (cd "$ROOT" && HOME="$SBX7" NO_SETUP=1 bash "$INSTALL") 2>&1 )"; rc15=$?
if [ "$rc15" = 0 ]; then ok "--no-setup/NO_SETUP still succeeds"; else bad "NO_SETUP install failed (rc $rc15)"; fi
case "$out15" in *"Skipping setup"*) ok "NO_SETUP is announced, not silent" ;;
  *) bad "NO_SETUP skipped without saying so" ;; esac

# A cmux that exists but refuses everything must not fail the install: the files
# are on disk either way, and telling someone their install failed when it didn't
# is how you get a re-run that changes nothing.
SBX8="$ROOT/home8"; mkdir -p "$SBX8"
ANGRY="$ROOT/angry"; mkdir -p "$ANGRY"
for t in jq install sed grep cat mkdir rm cp chmod printf date dirname basename cmp mv ln find sort head tail wc; do
  src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$ANGRY/$t" 2>/dev/null
done
printf '#!/bin/bash\nexit 1\n' > "$ANGRY/cmux"; chmod +x "$ANGRY/cmux"
out16="$( (cd "$ROOT" && HOME="$SBX8" PATH="$ANGRY:/usr/bin:/bin" bash "$INSTALL") 2>&1 )"; rc16=$?
if [ "$rc16" = 0 ]; then ok "a cmux that rejects everything does not fail the install"; else bad "a refusing cmux failed the install (rc $rc16)"; fi
case "$out16" in *"Re-run it by hand"*) ok "tells you setup needs re-running" ;;
  *) bad "setup failure was not surfaced with a recovery command" ;; esac

echo "T15: the version stamp never borrows an ancestor repo's git sha"
# `git -C <dir> rev-parse` WALKS UP. A Homebrew tarball unpacks under
# /opt/homebrew, which is itself a git repo, so an unguarded rev-parse stamps
# Homebrew's HEAD — a confident, precise, completely unrelated sha. Reproduce the
# shape: a non-git tree nested inside a git repo.
PREFIX="$ROOT/prefix"; mkdir -p "$PREFIX"
git -C "$PREFIX" init -q >/dev/null 2>&1
git -C "$PREFIX" -c user.email=t@example.invalid -c user.name=t \
  commit -q --allow-empty -m ancestor >/dev/null 2>&1
ancestor="$(git -C "$PREFIX" rev-parse --short HEAD 2>/dev/null)"
TREE="$PREFIX/Cellar/cmux-sentinel/0.2.0"; mkdir -p "$TREE"
( cd "$HERE/.." && tar --exclude=.git -cf - . ) | ( cd "$TREE" && tar xf - )
SBX9="$ROOT/home9"; mkdir -p "$SBX9"
( cd "$TREE" && HOME="$SBX9" NO_SETUP=1 bash "$TREE/install.sh" ) >/dev/null 2>&1
stamp="$(cat "$SBX9/.config/cmux-sentinel/VERSION" 2>/dev/null)"
case "$stamp" in *"version="*) ok "a non-git tree still records its version" ;;
  *) bad "no version stamp written from a tarball tree: [$stamp]" ;; esac
if [ -n "$ancestor" ]; then
  case "$stamp" in *"commit=$ancestor"*) bad "stamped the ancestor repo's sha ($ancestor)" ;;
    *) ok "does not stamp the enclosing repo's sha" ;; esac
else
  ok "does not stamp the enclosing repo's sha (no ancestor repo to borrow)"
fi
case "$stamp" in *"commit=unknown"*) ok "says the commit is unknown instead of guessing" ;;
  *) bad "expected commit=unknown from a tarball tree: [$stamp]" ;; esac

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
