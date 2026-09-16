# Releasing cmux-sentinel

Two audiences share one release: people who install with `curl … | bash` (they track `main`) and
people who install with Homebrew (they track **tags**). Everything below exists so those two never
disagree about what "0.x.y" means.

## 1. Bump and describe the release

```bash
echo 0.3.0 > VERSION
$EDITOR CHANGELOG.md      # a section per version; the doctor's update warning points here
make check                # `make formula` notes the formula still describes the previous
                          # release and that v0.3.0 is not tagged yet — expected here
git commit -am "Release 0.3.0"
git push
```

`install.sh` stamps `VERSION` (plus the install date, short commit and a fingerprint of the files it
deployed) into `~/.config/cmux-sentinel/VERSION`. `cmux-sentinel version` reads it back and the
doctor header compares it with the `VERSION` published on `main`, so "am I on the fixed one?" is
self-serve. The fingerprint matters between releases: a checkout ahead of the last tag deploys newer
files under the *same* version number, and only the fingerprint can tell those two copies apart.

`make check` also runs `make notes`, which fails if `CHANGELOG.md` has no `## 0.3.0` section: that
section becomes the GitHub Release body in step 2, so it has to exist before the tag does. The
pre-commit hook runs the same check whenever `VERSION` or `CHANGELOG.md` is staged.

## 2. Tag it — the GitHub Release is published for you

The tag is what Homebrew downloads and hashes, so it must exist before the formula does.

```bash
git tag -a v0.3.0 -m "cmux-sentinel 0.3.0"
git push origin v0.3.0
```

Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`, which creates the GitHub Release: title
`v0.3.0`, body from `scripts/release-notes.sh` (the version's CHANGELOG section, upgrade
instructions and a compare link to the previous release). The job fails if the tag's `VERSION`
disagrees with the tag. Don't run `gh release create` by hand. If you want a descriptive title, edit
it afterwards; re-running the workflow keeps it.

Only the **highest** version tag is marked **Latest**, so re-publishing an older tag never takes the
badge from the current release. The 0.2.x tags were never published as Releases, which is why
GitHub showed v0.1.0 as Latest until v0.2.3. To backfill or refresh one:

```bash
gh workflow run release.yml -f tag=v0.2.2
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

The tap is a separate repository — [`oliver-kriska/homebrew-tap`](https://github.com/oliver-kriska/homebrew-tap) —
because `brew tap <owner>/<name>` resolves to `<owner>/homebrew-<name>`. It is shared across
projects, and Homebrew expects the formula under `Formula/`:

```bash
git clone https://github.com/oliver-kriska/homebrew-tap.git   # once
cp packaging/homebrew/cmux-sentinel.rb homebrew-tap/Formula/cmux-sentinel.rb
git -C homebrew-tap commit -am "cmux-sentinel 0.3.0" && git -C homebrew-tap push
```

Then verify against a real Homebrew, not just by reading:

```bash
brew update && brew upgrade cmux-sentinel        # or: brew tap oliver-kriska/tap && brew install …
brew test cmux-sentinel                          # runs the formula's test block
brew audit --strict --online oliver-kriska/tap/cmux-sentinel
cmux-sentinel version                            # brew version, deployed stamp, and file drift
```

## What Homebrew does and does not do

It owns the **files under its prefix** and nothing else. cmux-sentinel is mostly `$HOME` — the
sidebar in `~/.config/cmux/sidebars`, the pollers in `~/bin`, four LaunchAgents in
`~/Library/LaunchAgents`, hooks in `~/.claude` — and a formula must not write there.

So the install is two commands, and the second one is not optional:

```bash
brew install oliver-kriska/tap/cmux-sentinel
cmux-sentinel deploy          # runs the tree's own install.sh: files, hooks, agents, sentinels
```

**An upgrade needs both too.** `brew upgrade` refreshes the Cellar copy while launchd keeps running
the scripts in `~/bin` — new code installed, nothing changed, no error. That is why:

- the "run deploy" line lives in the formula's `caveats`, which Homebrew prints on upgrade as well
  as on first install. There is no `post_install`: Homebrew 7 deprecates it, and its replacement
  (`post_install_steps`) only performs file operations and cannot print a message;
- `cmux-sentinel update` **refuses** on a Homebrew-managed copy and names `brew upgrade` instead —
  curl-installing over a brew install leaves two updaters fighting over `~/bin`, with brew still
  reporting a version it no longer controls;
- `cmux-sentinel deploy` **refuses to go backwards.** It copies the tree beside it into `~/bin`,
  which is only an upgrade if that tree is at least as new. When `~/bin` was deployed from a
  checkout ahead of the tag, the Cellar is *older* while reading the same version — so `deploy`
  refuses an older tree version, and a same-version tree whose fingerprint differs. `--force`
  deploys anyway. Cutting a release is what makes the Cellar current again;
- the generated plists keep pointing at `~/bin/*.sh`. A Cellar path carries the version, so an
  upgrade would break every loaded agent — and launchd holds its loaded definition, so it would
  break silently.

`brew services` is not usable here either: it is one service per formula, and there are four agents
with different intervals.
