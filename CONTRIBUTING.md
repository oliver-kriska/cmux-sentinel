# Contributing

Thanks for improving this! It's small and hackable — PRs and issues welcome.

## Dev loop

- **Sidebar (`sidebars/workspaces.swift`)** — edit, then:

  ```bash
  cp sidebars/workspaces.swift ~/.config/cmux/sidebars/workspaces.swift
  cmux sidebar validate workspaces && cmux sidebar reload workspaces
  make sidebar-live
  ```

  ⚠ `validate` parses and interprets against **synthetic data**, but it does not mount the SwiftUI
  view, exercise every live-data branch, or prove visible pixels. After a meaningful UI change,
  inspect the mounted sidebar. `make sidebar-live` stages the **repo** file under a temporary name,
  mounts it against live data, waits for inspection, then closes it and cleans up. It honestly proves
  only that the command/mount path succeeded: cmux exposes no rendered-tree/pixel assertion today.
  If the sidebar goes blank, bisect by
  replacing the whole body with `Text("hi")`, confirming it renders, then restoring helpers/views
  one at a time.

- **Pollers** — inspect without touching cmux, then use `--update` only for a live paint:

  ```bash
  ./bin/cmux-claude-usage.sh --print
  ./bin/cmux-codex-usage.sh --print
  ./bin/cmux-amp-usage.sh --print       # --raw includes your email; keep it local
  ```

## Please respect the known interpreter limits

The cmux sidebar runs a **subset** of SwiftUI. Keep
[`docs/cmux-custom-sidebar-cheatsheet.md`](docs/cmux-custom-sidebar-cheatsheet.md) as the canonical
fact sheet rather than duplicating probe results here. In particular:

- `progress` / `description` / `color` reach the interpreter but are null until set; prove a field
  against a known-set workspace. Status pills do not reach custom sidebars.
- Usage meters use native progress plus a title anchor/fallback. Agent state still uses static title
  markers for persistence, co-tenancy, and custom-sidebar visibility.
- String ops (`.hasPrefix` / `.contains` / `.split`) **do** work here — marker detection relies on
  them. (An earlier note claimed they render blank; that was disproven on the current build.)
- `Divider().background(...)` and `.frame(maxHeight: .infinity)` are greedy and wreck row height.

If you find a new gotcha, add it to the cheatsheet with the cmux version and a known-set control.

## Linting, hooks & CI

The shared gates live in one Makefile: `make ci` runs the portable CI subset, while `make check`
adds the local cmux sidebar validation:

```bash
make check   # shellcheck + secret guard + markdownlint + offline tests + sidebar parse
make sidebar-live # optional macOS live mount; requires a human visual verdict
make fmt     # reformat shell with shfmt (opt-in — the scripts use a terse one-liner style)
```

The offline suite also expects Node.js: it executes the JS-compatible Amp adapter against fake old
and current bridge protocols. Node is test-only; the installed project remains dependency-light.

Install the git hooks once — pre-commit runs the same gates, pre-push runs the CI subset:

```bash
brew install lefthook && lefthook install
```

`scripts/check-secrets.sh` is the load-bearing one: it fails the commit if a real workspace UUID, a
`/Users/<name>` path, or a token-shaped string lands in a tracked file, and asserts the sidebar keeps
its title-label meter anchors. CI runs `make ci` on Ubuntu and validates every launchd template plus
its installed-path substitution with `plutil` on macOS.

## Cutting a release

`VERSION` + `CHANGELOG.md` + a `v<version>` tag, then regenerate the Homebrew formula from that tag
(`scripts/make-formula.sh`; `make formula` checks the two agree, and is part of `make check`). The
full sequence, and the four Homebrew constraints that are silent failures when ignored, are in
[`docs/release.md`](docs/release.md).

## Ground rules

- **Never commit secrets.** OAuth tokens are read from provider-owned local credential stores at
  runtime; keep them there. No tokens, no real workspace UUIDs, no usernames in committed files. (The sidebar matches
  sentinels by title label, so it carries no ids to leak.)
- Keep it dependency-light (bash + `jq` + `curl`, macOS `date`).
- Match the existing style; keep comments terse and about *why*.
