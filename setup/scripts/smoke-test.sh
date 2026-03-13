#!/usr/bin/env bash
#
# smoke-test.sh - Quick verification that the agent-fleet repo is functional
# ===========================================================================
# Runs basic sanity checks and then the full test suite.
# Designed to be the entry point for Docker CI containers.
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Colors
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BOLD='' RESET=''
fi

FAILURES=0

pass() {
    printf "${GREEN}  [PASS]${RESET} %s\n" "$*"
}

fail() {
    printf "${RED}  [FAIL]${RESET} %s\n" "$*"
    ((FAILURES++)) || true
}

section() {
    printf "\n${BOLD}--- %s ---${RESET}\n\n" "$*"
}

# ============================================================================
# SMOKE CHECKS
# ============================================================================

section "Smoke Checks"

# 1. install.sh --help runs without error
if bash "${REPO_ROOT}/setup/install.sh" --help >/dev/null 2>&1; then
    pass "install.sh --help"
else
    fail "install.sh --help returned non-zero"
fi

# 2. configure-claude.sh exists and is executable (or at least valid bash)
if [[ -f "${REPO_ROOT}/setup/configure-claude.sh" ]]; then
    if bash -n "${REPO_ROOT}/setup/configure-claude.sh" 2>/dev/null; then
        pass "configure-claude.sh exists and has valid syntax"
    else
        fail "configure-claude.sh has syntax errors"
    fi
else
    fail "configure-claude.sh not found"
fi

# 3. lib.sh sources correctly
if bash -n "${REPO_ROOT}/setup/lib.sh" 2>/dev/null; then
    pass "lib.sh passes syntax check"
else
    fail "lib.sh has syntax errors"
fi

# 4. sync.sh exists
if [[ -f "${REPO_ROOT}/sync.sh" ]]; then
    if bash -n "${REPO_ROOT}/sync.sh" 2>/dev/null; then
        pass "sync.sh exists and has valid syntax"
    else
        fail "sync.sh has syntax errors"
    fi
else
    fail "sync.sh not found"
fi

# 5. preflight.sh runs
if [[ -f "${REPO_ROOT}/setup/preflight.sh" ]]; then
    if bash "${REPO_ROOT}/setup/preflight.sh" --skip-network >/dev/null 2>&1; then
        pass "preflight.sh --skip-network"
    else
        # Preflight may fail on minimal containers — that's a WARN, not FAIL
        printf "${YELLOW}  [WARN]${RESET} preflight.sh --skip-network returned non-zero (may be expected in minimal containers)\n"
    fi
else
    fail "preflight.sh not found"
fi

# 6. All setup scripts pass syntax check
SYNTAX_FAILURES=0
for script in "${REPO_ROOT}"/setup/*.sh "${REPO_ROOT}"/setup/scripts/*.sh; do
    [[ -f "$script" ]] || continue
    if ! bash -n "$script" 2>/dev/null; then
        fail "Syntax error in: $(basename "$script")"
        ((SYNTAX_FAILURES++)) || true
    fi
done
if [[ $SYNTAX_FAILURES -eq 0 ]]; then
    pass "all setup scripts pass syntax check"
fi

# ============================================================================
# FULL TEST SUITE
# ============================================================================

section "Full Test Suite"

if bash "${REPO_ROOT}/setup/tests/run.sh" 2>&1; then
    pass "full test suite passed"
else
    fail "full test suite had failures"
fi

# ============================================================================
# INTEGRATION TESTS
# ============================================================================

section "Integration Tests"

if [[ -f "${REPO_ROOT}/setup/tests/integration-test.sh" ]]; then
    if bash "${REPO_ROOT}/setup/tests/integration-test.sh" 2>&1; then
        pass "integration tests passed"
    else
        fail "integration tests had failures"
    fi
else
    printf "${YELLOW}  [WARN]${RESET} integration-test.sh not found, skipping\n"
fi

# ============================================================================
# SUMMARY
# ============================================================================

section "Summary"

if [[ $FAILURES -eq 0 ]]; then
    printf "${GREEN}${BOLD}All smoke checks passed.${RESET}\n"
    exit 0
else
    printf "${RED}${BOLD}%d smoke check(s) failed.${RESET}\n" "$FAILURES"
    exit 1
fi
