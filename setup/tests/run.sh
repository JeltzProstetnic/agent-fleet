#!/usr/bin/env bash
# Test runner — discovers and runs all test-*.sh files in the tests/ directory
# Usage: bash tests/run.sh [pattern]
#   pattern: optional glob to filter test files (e.g., "rotate" matches test-rotate*.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

PATTERN="${1:-}"
TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
FAILED_NAMES=()

printf "${BOLD}cfg-agent-fleet test runner${RESET}\n"
printf "Repo: %s\n\n" "$REPO_ROOT"

# Discover test files
test_files=()
for f in "$SCRIPT_DIR"/test-*.sh; do
    [[ -f "$f" ]] || continue
    if [[ -n "$PATTERN" ]]; then
        basename_f="$(basename "$f")"
        [[ "$basename_f" == *"$PATTERN"* ]] || continue
    fi
    test_files+=("$f")
done

if [[ ${#test_files[@]} -eq 0 ]]; then
    printf "${YELLOW}No test files found"
    [[ -n "$PATTERN" ]] && printf " matching '%s'" "$PATTERN"
    printf "${RESET}\n"
    exit 0
fi

printf "Found %d test suite(s)\n\n" "${#test_files[@]}"

for test_file in "${test_files[@]}"; do
    suite_name="$(basename "$test_file" .sh)"
    ((TOTAL_SUITES++)) || true

    if bash "$test_file"; then
        ((PASSED_SUITES++)) || true
    else
        ((FAILED_SUITES++)) || true
        FAILED_NAMES+=("$suite_name")
    fi
done

# Final summary
printf "\n${BOLD}════════════════════════════════════${RESET}\n"
printf "${BOLD}Test Suites: %d total${RESET}\n" "$TOTAL_SUITES"
printf "  ${GREEN}Passed: %d${RESET}\n" "$PASSED_SUITES"
if [[ $FAILED_SUITES -gt 0 ]]; then
    printf "  ${RED}Failed: %d${RESET}\n" "$FAILED_SUITES"
    for name in "${FAILED_NAMES[@]}"; do
        printf "    ${RED}- %s${RESET}\n" "$name"
    done
    exit 1
fi
printf "\n${GREEN}All suites passed.${RESET}\n"
