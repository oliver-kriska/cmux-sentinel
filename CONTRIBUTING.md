# Contributing

Thanks for improving this! It's small and hackable — PRs and issues welcome.

## Dev loop

- **Sidebar (`sidebars/workspaces.swift`)** — edit, then:

  ```bash
  cp sidebars/workspaces.swift ~/.config/cmux/sidebars/workspaces.swift
  cmux sidebar validate workspaces && cmux sidebar reload
  ```

  ⚠ `validate` only **parses** — it passes on layouts that render blank. If the sidebar goes
  blank, you hit a runtime/interpreter error. Bisect by replacing the whole body with a single
  `Text("hi")`, confirm it renders, then add helpers/views back one at a time.

- **Poller (`bin/cmux-claude-usage.sh`)** — test without touching cmux:

  ```bash
  ./bin/cmux-claude-usage.sh --print    # parsed values
  ./bin/cmux-claude-usage.sh --raw      # raw API JSON (no token)
  ./bin/cmux-claude-usage.sh --update   # actually renames the sentinels
  ```

## Please respect the known interpreter limits

The cmux sidebar runs a **subset** of SwiftUI. Things that look fine but break (see README
"Interpreter gotchas" for the full list):

- `progress` / `description` / `color` don't reach custom-sidebar data on this build (proven by
  probe) — only the **title** does. That's why working/compacting state rides a title marker.
- String ops (`.hasPrefix` / `.contains` / `.split`) **do** work here — marker detection relies on
  them. (An earlier note claimed they render blank; that was disproven on the current build.)
- `Divider().background(...)` and `.frame(maxHeight: .infinity)` are greedy and wreck row height.

If you find a new gotcha, add it to the README list — that's the most valuable kind of PR here.

## Linting, hooks & CI

Clean-code gates run locally and in CI from one Makefile, so they can't drift:

```bash
make check   # shellcheck + secret/placeholder guard + markdownlint + sidebar parse
make fmt     # reformat shell with shfmt (opt-in — the scripts use a terse one-liner style)
```

Install the git hooks once — pre-commit runs the same gates, pre-push runs the CI subset:

```bash
brew install lefthook && lefthook install
```

`scripts/check-secrets.sh` is the load-bearing one: it fails the commit if a real workspace UUID, a
`/Users/<name>` path, or a token-shaped string lands in a tracked file, and asserts the sidebar keeps
its title-label meter anchors (`w.title.hasPrefix("5h "/"7d ")`). CI (`.github/workflows/ci.yml`)
runs `make ci` on every push/PR.

## Ground rules

- **Never commit secrets.** The OAuth token is read from the Keychain at runtime; keep it that
  way. No tokens, no real workspace UUIDs, no usernames in committed files. (The sidebar matches
  sentinels by title label, so it carries no ids to leak.)
- Keep it dependency-light (bash + `jq` + `curl`, macOS `date`).
- Match the existing style; keep comments terse and about *why*.
