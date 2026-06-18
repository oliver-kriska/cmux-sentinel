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
SCRIPTS := bin/cmux-claude-usage.sh bin/cmux-sentinel-doctor.sh hooks/cmux-bridge.sh \
           install.sh scripts/check-secrets.sh tests/bridge-state.sh
MD      := $(wildcard *.md) $(wildcard docs/*.md)

.PHONY: help check ci lint shellcheck secrets markdown test doctor sidebar fmt fmt-check

help:
	@echo "make check   — shellcheck + secrets + markdown + test + sidebar (full local gate)"
	@echo "make ci      — what CI runs (check minus sidebar; no cmux on the runner)"
	@echo "make test    — offline bridge state-machine test (stubs cmux)"
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

# bridge state machine: offline, stubs cmux, runs on Linux CI too.
test:
	bash tests/bridge-state.sh

# health-check the live setup (read-only) — bridge/hooks/launchd/automation/sentinels.
doctor:
	@./bin/cmux-sentinel-doctor.sh

# sidebar PARSE check — only meaningful where cmux exists (local/pre-commit);
# skipped in CI. NB: validate only parses; a green parse can still render blank.
sidebar:
	@if command -v cmux >/dev/null 2>&1; then \
		cmux sidebar validate workspaces && echo "sidebar validate: ok ✓"; \
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
