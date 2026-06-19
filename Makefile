# cmux-sentinel — task runner. One source of truth for lint/format/CI so the
# pre-commit hook (lefthook.yml) and CI (.github/workflows/ci.yml) call the SAME
# targets — no drift between "passes locally" and "passes in CI".
#
#   make check   what CI runs + sidebar: shellcheck + secrets + markdown + test
#   make test    offline bridge state-machine test (stubs cmux; runs in CI too)
#   make doctor  health-check the live setup (read-only)
#   make fmt     rewrite shell with shfmt (OPT-IN — see note below)
#   make help    list targets

SHELL   := bash
SCRIPTS := bin/cmux-claude-usage.sh bin/cmux-codex-usage.sh bin/cmux-sentinel-doctor.sh \
           bin/cmux-sentinel-setup.sh bin/cmux-group-sync.sh hooks/cmux-bridge.sh \
           install.sh scripts/check-secrets.sh \
           tests/bridge-state.sh tests/poller-gate.sh tests/codex-poller.sh \
           tests/install-hooks.sh tests/sentinel-setup.sh tests/group-sync.sh
MD      := $(wildcard *.md) $(wildcard docs/*.md)

.PHONY: help check ci lint shellcheck secrets markdown test doctor sidebar fmt fmt-check

help:
	@echo "make check   — shellcheck + secrets + markdown + test + sidebar (full local gate)"
	@echo "make ci      — what CI runs (check minus sidebar; no cmux on the runner)"
	@echo "make test    — offline state-machine tests: bridge markers + poller gating (stubs cmux)"
	@echo "make doctor  — health-check the live setup (read-only)"
	@echo "make fmt     — reformat shell scripts with shfmt (opt-in, not a gate)"

# correctness: real bug-catching for the bash. -x follows `source`d files.
shellcheck:
	shellcheck -x $(SCRIPTS)

# never-leak guard: no real UUIDs / home paths / tokens; placeholders intact.
secrets:
	./scripts/check-secrets.sh

# docs hygiene: code-fence languages, blank lines around fences (config in
# .markdownlint.jsonc — line-length & inline-HTML are off by house style).
markdown:
	markdownlint $(MD)

# state machines: offline, stub cmux/security/curl, run on Linux CI too.
#   bridge-state  — agent activity markers (⚡/⏳/❓)
#   poller-gate   — Claude usage-poller gating + malformed-value clamping + bare-label resolve
#   codex-poller  — Codex usage-poller gating + rollout snapshot parsing + clamping
#   install-hooks  — install.sh Claude-hook auto-registration (merge / preserve / idempotent / no-jq)
#   sentinel-setup — cmux-sentinel-setup.sh idempotent sentinel creation + auto-naming guard
#   group-sync     — cmux-group-sync.sh group-name → anchor-title sync (gate / rename / marker / multi-window)
test:
	bash tests/bridge-state.sh
	bash tests/poller-gate.sh
	bash tests/codex-poller.sh
	bash tests/install-hooks.sh
	bash tests/sentinel-setup.sh
	bash tests/group-sync.sh

# health-check the live setup (read-only) — bridge/hooks/launchd/automation/sentinels.
doctor:
	@./bin/cmux-sentinel-doctor.sh

# sidebar PARSE check — only meaningful where cmux exists (local/pre-commit);
# skipped in CI. NB: validate only parses; a green parse can still render blank.
# `cmux sidebar validate` only takes a NAME (it reads ~/.config/cmux/sidebars), so
# validating `workspaces` would check the DEPLOYED copy, not this repo's file — a
# broken repo sidebar could pass while the old deployed one is fine. So stage the
# REPO file under a throwaway name, validate THAT, and remove it. Always reports
# which file was checked.
SIDEBAR_DIR := $(HOME)/.config/cmux/sidebars
sidebar:
	@if command -v cmux >/dev/null 2>&1; then \
		mkdir -p "$(SIDEBAR_DIR)"; \
		tmp="$(SIDEBAR_DIR)/workspaces-makecheck.swift"; \
		cp sidebars/workspaces.swift "$$tmp"; \
		if cmux sidebar validate workspaces-makecheck >/dev/null 2>&1; then \
			rm -f "$$tmp"; echo "sidebar validate: ok ✓ (repo file sidebars/workspaces.swift)"; \
		else \
			echo "sidebar validate: FAILED for repo sidebars/workspaces.swift" >&2; \
			cmux sidebar validate workspaces-makecheck || true; \
			rm -f "$$tmp"; exit 1; \
		fi; \
	else \
		echo "sidebar: cmux not found — skipping parse check"; \
	fi

check: shellcheck secrets markdown test sidebar
lint: check
ci: shellcheck secrets markdown test   ## CI omits `sidebar` (no cmux on the runner)

# shfmt is OPT-IN, not a gate: the scripts use a deliberately terse one-liner
# style (`die() { echo ...; exit 1; }`) that shfmt would explode. Run this only
# if you intend to adopt shfmt's canonical layout wholesale.
fmt:
	shfmt -w -i 2 -ci $(SCRIPTS)

fmt-check:
	shfmt -d -i 2 -ci $(SCRIPTS)
