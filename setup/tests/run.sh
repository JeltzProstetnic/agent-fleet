#!/usr/bin/env bash
# Test runner — discovers and runs all test-*.sh files in the setup/tests/ directory
# Usage: bash setup/tests/run.sh [pattern] [--e2e]
#   pattern: optional glob to filter test files (e.g., "rotate" matches test-rotate*.sh)
#   --e2e:   include E2E tests (test-e2e-*.sh) — these spawn real Claude Code sessions
#            and consume API credits. Excluded by default. Use only in VM/controlled environments.

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

PATTERN=""
INCLUDE_E2E=false
for arg in "$@"; do
    case "$arg" in
        --e2e) INCLUDE_E2E=true ;;
        *) PATTERN="$arg" ;;
    esac
done
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
    basename_f="$(basename "$f")"
    # Skip E2E tests unless --e2e flag is passed (they spawn real Claude sessions)
    if [[ "$INCLUDE_E2E" == "false" ]] && [[ "$basename_f" == test-e2e-* ]]; then
        continue
    fi
    if [[ -n "$PATTERN" ]]; then
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

    # Run in subshell to prevent env var leakage (test exports contaminated parent session).
    # stdin is /dev/null (CFG-474): a suite that inherits the caller's terminal and reads it
    # blocks forever, and only when a human runs the gate — every TTY-less runner sees EOF and
    # passes. That asymmetry cost this gate two separate indefinite hangs. Tests that need input
    # still pipe it into the specific command they are exercising.
    #
    # setsid (CFG-670) is the other half, and the third instance of that same asymmetry.
    # Closing stdin does NOT stop a `read -r x </dev/tty` — opening /dev/tty reaches the
    # CONTROLLING TERMINAL directly and ignores stdin entirely. afleet.sh prompts exactly that
    # way, by design, because its real caller is a human at a terminal. So the gate hung again
    # on 2026-09-21, this time launched through tmux-launch.sh, which CLAUDE.md MANDATES for
    # background commands: an empty log and a live tmux session, indistinguishable from a
    # long-running suite. A Claude Code Bash call has no controlling terminal, so the same
    # suite passed 166/166 and could not see the hang.
    # setsid puts each suite in a new session with NO controlling terminal, so opening
    # /dev/tty fails and the code takes its EOF path — the behaviour every runner already had,
    # now including the ones that own a terminal. --wait propagates the child's exit status.
    if (exec setsid --wait bash "$test_file" </dev/null); then
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
