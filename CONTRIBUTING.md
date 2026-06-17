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

- No working String `.contains` / `.hasPrefix` — match by `==`.
- `progress` / `color` don't propagate to **idle** workspaces — only `title` does.
- `Divider().background(...)` and `.frame(maxHeight: .infinity)` are greedy and wreck row height.

If you find a new gotcha, add it to the README list — that's the most valuable kind of PR here.

## Ground rules

- **Never commit secrets.** The OAuth token is read from the Keychain at runtime; keep it that
  way. No tokens, no real workspace UUIDs (use placeholders), no usernames in committed files.
- Keep it dependency-light (bash + `jq` + `curl`, macOS `date`).
- Match the existing style; keep comments terse and about *why*.
