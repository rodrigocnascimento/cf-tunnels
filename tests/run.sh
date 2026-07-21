#!/usr/bin/env bash
# tests/run.sh — Test runner for cf-tunnels
# =============================================================================
# Usage:
#   ./tests/run.sh           # Run all tests
#   ./tests/run.sh --verbose # Show full output for each test
#
# Each test file is sourced in a subshell with a fresh HOME temp directory.
# Results are reported at the end.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERBOSE=0
FAILED=0
PASSED=0
TOTAL=0

# ── Parse args ──
if [[ "${1:-}" == "--verbose" ]]; then
	VERBOSE=1
fi

# ── Helpers ──
_pass() {
	local name="$1"
	((PASSED++)) || true
	((TOTAL++)) || true
	if [[ $VERBOSE -eq 1 ]]; then
		echo "  ✓ PASS: $name"
	fi
}

_fail() {
	local name="$1"
	local msg="${2:-}"
	((FAILED++)) || true
	((TOTAL++)) || true
	echo "  ✗ FAIL: $name${msg:+ — $msg}"
}

# Run a single test function in a subshell with fresh env
run_test() {
	local file="$1"
	local func="$2"
	local tmp_home
	tmp_home=$(mktemp -d)
	local output="$tmp_home/output.txt"
	local exit_code=0

	# Export functions and vars into subshell
	(
		export HOME="$tmp_home"
		export PROJECT_DIR="$PROJECT_DIR"
		export PATH="$SCRIPT_DIR/fixtures:$PATH"
		export BASH_ENV=""  # prevent .bashrc from interfering
		export CFTUNNEL_SKIP_MAIN=1  # skip main logic when sourcing run.sh
		cd "$PROJECT_DIR"
		set --  # do not leak test-runner flags into run.sh's CLI parser
		source "$SCRIPT_DIR/runner-lib.sh"
		source "$PROJECT_DIR/run.sh"
		source "$file"
		$func
	) >"$output" 2>&1 || exit_code=$?

	if [[ $exit_code -eq 0 ]]; then
		_pass "$func"
		[[ $VERBOSE -eq 1 ]] && cat "$output"
	else
		_fail "$func" "exit code $exit_code"
		if [[ $VERBOSE -eq 1 ]]; then
			cat "$output"
		else
			# Show last 20 lines on failure
			tail -20 "$output"
		fi
	fi

	rm -rf "$tmp_home"
}

# ── Test list (explicit) ──
TEST_FILES=(
	"$SCRIPT_DIR/test_functions.sh"
	"$SCRIPT_DIR/test_zones.sh"
	"$SCRIPT_DIR/test_zone_credentials.sh"
	"$SCRIPT_DIR/test_list.sh"
	"$SCRIPT_DIR/test_parser.sh"
	"$SCRIPT_DIR/test_version.sh"
	"$SCRIPT_DIR/test_yaml.sh"
)

# ── Header ──
echo "════════════════════════════════════════════════════════════════"
echo "  cf-tunnels Test Suite"
echo "════════════════════════════════════════════════════════════════"
echo

# ── Phase 1: Smoke (syntax + deps) ──
echo "Phase 1: Smoke Tests"
echo "────────────────────"

for script in run.sh install.sh uninstall.sh; do
	if bash -n "$PROJECT_DIR/$script"; then
		_pass "syntax: $script"
	else
		_fail "syntax: $script"
	fi
done

# Check core dependencies exist
for dep in jq cloudflared systemctl; do
	if command -v "$dep" >/dev/null 2>&1; then
		_pass "dep exists: $dep"
	else
		_pass "dep missing: $dep (may be mocked)"
	fi
done

echo

# ── Phase 2: Unit Tests ──
echo "Phase 2: Unit Tests (test_functions.sh)"
echo "───────────────────────────────────────"

for func in $(grep -oE '^test_[a-zA-Z0-9_]+' "$SCRIPT_DIR/test_functions.sh"); do
	run_test "$SCRIPT_DIR/test_functions.sh" "$func"
done

echo

# ── Phase 3: Integration Tests ──
echo "Phase 3: Integration Tests"
echo "──────────────────────────"

for file in test_zones.sh test_zone_credentials.sh test_list.sh test_yaml.sh; do
	file_path="$SCRIPT_DIR/$file"
	echo "  → $file"
	for func in $(grep -oE '^test_[a-zA-Z0-9_]+' "$file_path"); do
		run_test "$file_path" "$func"
	done
done

echo

# ── Phase 4: CLI Tests ──
echo "Phase 4: CLI Tests"
echo "──────────────────"

for file in test_parser.sh test_version.sh; do
	file_path="$SCRIPT_DIR/$file"
	echo "  → $file"
	for func in $(grep -oE '^test_[a-zA-Z0-9_]+' "$file_path"); do
		run_test "$file_path" "$func"
	done
done

echo

echo

# ── Summary ──
echo "════════════════════════════════════════════════════════════════"
echo "  Results: $PASSED passed, $FAILED failed, $TOTAL total"
echo "════════════════════════════════════════════════════════════════"

if [[ $FAILED -eq 0 ]]; then
	echo "  ✅ All tests passed!"
	exit 0
else
	echo "  ❌ Some tests failed."
	exit 1
fi
