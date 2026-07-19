.PHONY: all smoke unit integration cli clean help

help:
	@echo "cf-tunnels Test Suite"
	@echo ""
	@echo "Targets:"
	@echo "  make smoke       - Syntax checks + dependency checks"
	@echo "  make unit        - Unit tests (pure functions)"
	@echo "  make integration - Integration tests (filesystem, no Cloudflare)"
	@echo "  make cli         - CLI parser tests"
	@echo "  make all         - Run everything (default)"
	@echo "  make clean       - Remove temp test directories"
	@echo "  make verbose     - Run all with full output"
	@echo ""

all: smoke unit integration cli

verbose:
	./run.sh --verbose

smoke:
	@echo "=== Smoke Tests ==="
	@echo "  Checking script syntax..."
	@bash -n ../run.sh && echo "  ✓ run.sh"
	@bash -n ../install.sh && echo "  ✓ install.sh"
	@bash -n ../uninstall.sh && echo "  ✓ uninstall.sh"
	@echo ""
	@echo "  Checking dependencies..."
	@command -v jq >/dev/null 2>&1 && echo "  ✓ jq" || echo "  ⚠ jq missing"
	@command -v cloudflared >/dev/null 2>&1 && echo "  ✓ cloudflared" || echo "  ⚠ cloudflared missing (tests use mock)"
	@echo ""

unit:
	@echo "=== Unit Tests ==="
	@./run.sh | grep -A 50 "Phase 2"

integration:
	@echo "=== Integration Tests ==="
	@./run.sh | grep -A 50 "Phase 3"

cli:
	@echo "=== CLI Parser Tests ==="
	@./run.sh | grep -A 50 "Phase 4"

clean:
	@echo "Cleaning temp directories..."
	@rm -rf /tmp/cftunnel-test-*
	@echo "Done."
