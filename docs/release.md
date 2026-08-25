# Releasing cmux-sentinel

Two audiences share one release: people who install with `curl … | bash` (they track `main`) and
people who install with Homebrew (they track **tags**). Everything below exists so those two never
disagree about what "0.x.y" means.

## 1. Bump and describe the release

```bash
echo 0.3.0 > VERSION
$EDITOR CHANGELOG.md      # a section per version; the doctor's update warning points here
make check                # `make formula` will say "none yet (v0.3.0 not released)" — expected
git commit -am "Release 0.3.0"
git push
```

`install.sh` stamps `VERSION` (plus the install date and short commit) into
`~/.config/cmux-sentinel/VERSION`. `cmux-sentinel version` reads it back and the doctor header
compares it with the `VERSION` published on `main`, so "am I on the fixed one?" is self-serve.

## 2. Tag it

The tag is what Homebrew downloads and hashes, so it must exist before the formula does.

```bash
git tag v0.3.0
git push origin v0.3.0
```

## 3. Regenerate the formula

```bash
scripts/make-formula.sh          # hashes the tag's tarball, rewrites packaging/homebrew/
make formula                     # verifies version/url/sha256 agree with VERSION
git commit -am "Formula for 0.3.0" && git push
```

Never hand-edit `packaging/homebrew/cmux-sentinel.rb`: version, url and sha256 are three coupled
fields, and a tap that serves the previous release is invisible from inside this repo — `brew
upgrade` succeeds, prints nothing unusual, and installs the old code.

`make formula` runs in `make check` and in CI. It is offline, and treats a **missing** formula as
"not released yet" rather than a failure — the formula hashes a release tarball, so it cannot exist
before its tag. A formula that exists and disagrees with `VERSION` is the real bug, and fails.

## 4. Publish to the tap

The tap is a separate repository (`<owner>/homebrew-<name>`), because that is how `brew tap`
resolves a name. Homebrew expects the formula under `Formula/`:

```bash
cp packaging/homebrew/cmux-sentinel.rb ../homebrew-<name>/Formula/cmux-sentinel.rb
git -C ../homebrew-<name> commit -am "cmux-sentinel 0.3.0" && git -C ../homebrew-<name> push
```

Then verify against a real Homebrew, not just by reading:

```bash
brew untap <owner>/<name> 2>/dev/null; brew tap <owner>/<name>
brew install --build-from-source cmux-sentinel   # runs def install
brew test cmux-sentinel                          # runs the test block
brew audit --strict --online <owner>/<name>/cmux-sentinel
```

## What Homebrew does and does not do

It owns the **files under its prefix** and nothing else. cmux-sentinel is mostly `$HOME` — the
sidebar in `~/.config/cmux/sidebars`, the pollers in `~/bin`, four LaunchAgents in
`~/Library/LaunchAgents`, hooks in `~/.claude` — and a formula must not write there.

So the install is two commands, and the second one is not optional:

```bash
brew install <owner>/<name>/cmux-sentinel
cmux-sentinel deploy          # runs the tree's own install.sh: files, hooks, agents, sentinels
```

**An upgrade needs both too.** `brew upgrade` refreshes the Cellar copy while launchd keeps running
the scripts in `~/bin` — new code installed, nothing changed, no error. That is why:

- the "run deploy" line lives in the formula's `post_install`, not `caveats` (Homebrew prints
  caveats only on the first install, and the upgrade is when the message matters);
- `cmux-sentinel update` **refuses** on a Homebrew-managed copy and names `brew upgrade` instead —
  curl-installing over a brew install leaves two updaters fighting over `~/bin`, with brew still
  reporting a version it no longer controls;
- the generated plists keep pointing at `~/bin/*.sh`. A Cellar path carries the version, so an
  upgrade would break every loaded agent — and launchd holds its loaded definition, so it would
  break silently.

`brew services` is not usable here either: it is one service per formula, and there are four agents
with different intervals.
