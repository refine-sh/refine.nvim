NVIM ?= nvim
STYLUA ?= stylua

.PHONY: check format format-check helptags helptags-check test test-core test-health test-nvim

check: format-check test helptags-check

format:
	$(STYLUA) .

format-check:
	$(STYLUA) --check .

helptags:
	$(NVIM) --clean --headless -u NONE -c "helptags doc" -c qa

helptags-check: helptags
	git diff --exit-code -- doc/tags

test: test-core test-nvim test-health

test-core:
	$(NVIM) --clean --headless -u NONE -l tests/core/run.lua

test-health:
	$(NVIM) --clean --headless -u NONE -l tests/health/run.lua

test-nvim:
	@set -e; for spec in tests/nvim/*_spec.lua; do \
		echo "==> $$spec"; \
		$(NVIM) --clean --headless -u NONE -l "$$spec"; \
	done
