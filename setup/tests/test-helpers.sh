#!/usr/bin/env bash
# Test helpers — assertion functions and test lifecycle management
# Source this file in test scripts: source "$(dirname "$0")/test-helpers.sh"

set -euo pipefail

# ── Globals ──────────────────────────────────────────────────────────────────
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
CURRENT_TEST=""
TEST_FAILURES=()
TEST_TMPDIR=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

# ── Test Lifecycle ───────────────────────────────────────────────────────────

# Call before each test to set up a fresh temp directory
setup_test() {
    local test_name="$1"
    CURRENT_TEST="$test_name"
    TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/cfgtest.XXXXXX")"
    ((TESTS_RUN++)) || true
}

# Call after each test (or use trap). Cleans up temp dir.
teardown_test() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    TEST_TMPDIR=""
    CURRENT_TEST=""
}

# Run a test function with automatic setup/teardown
run_test() {
    local test_name="$1"
    local test_func="$2"

    setup_test "$test_name"
    # Trap ensures teardown even on failure
    trap 'teardown_test' RETURN

    if "$test_func"; then
        ((TESTS_PASSED++)) || true
        printf "${GREEN}  PASS${RESET} %s\n" "$test_name"
    else
        ((TESTS_FAILED++)) || true
        TEST_FAILURES+=("$test_name")
        printf "${RED}  FAIL${RESET} %s\n" "$test_name"
    fi
}

# Skip a test with a reason
skip_test() {
    local test_name="$1"
    local reason="${2:-no reason given}"
    ((TESTS_RUN++)) || true
    ((TESTS_SKIPPED++)) || true
    printf "${YELLOW}  SKIP${RESET} %s (%s)\n" "$test_name" "$reason"
}

# Print test suite header
suite_header() {
    local suite_name="$1"
    printf "\n${BOLD}=== %s ===${RESET}\n\n" "$suite_name"
}

# Print final summary and return appropriate exit code
suite_summary() {
    printf "\n${BOLD}── Summary ──${RESET}\n"
    printf "  Total:   %d\n" "$TESTS_RUN"
    printf "  ${GREEN}Passed:  %d${RESET}\n" "$TESTS_PASSED"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        printf "  ${RED}Failed:  %d${RESET}\n" "$TESTS_FAILED"
        printf "\n${RED}Failed tests:${RESET}\n"
        for f in "${TEST_FAILURES[@]}"; do
            printf "  - %s\n" "$f"
        done
    fi
    if [[ $TESTS_SKIPPED -gt 0 ]]; then
        printf "  ${YELLOW}Skipped: %d${RESET}\n" "$TESTS_SKIPPED"
    fi
    printf "\n"
    [[ $TESTS_FAILED -eq 0 ]]
}

# ── Assertions ───────────────────────────────────────────────────────────────

# Assert two strings are equal
assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-expected '$expected', got '$actual'}"
    if [[ "$expected" != "$actual" ]]; then
        printf "${RED}    ASSERT_EQ failed: %s${RESET}\n" "$msg" >&2
        printf "    Expected: %s\n" "$expected" >&2
        printf "    Actual:   %s\n" "$actual" >&2
        return 1
    fi
}

# Assert two strings are NOT equal
assert_neq() {
    local unexpected="$1"
    local actual="$2"
    local msg="${3:-expected NOT '$unexpected', but got it}"
    if [[ "$unexpected" == "$actual" ]]; then
        printf "${RED}    ASSERT_NEQ failed: %s${RESET}\n" "$msg" >&2
        return 1
    fi
}

# Assert string contains substring
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-expected output to contain '$needle'}"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf "${RED}    ASSERT_CONTAINS failed: %s${RESET}\n" "$msg" >&2
        printf "    Searched: %.200s...\n" "$haystack" >&2
        printf "    For:      %s\n" "$needle" >&2
        return 1
    fi
}

# Assert string does NOT contain substring
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-expected output NOT to contain '$needle'}"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf "${RED}    ASSERT_NOT_CONTAINS failed: %s${RESET}\n" "$msg" >&2
        return 1
    fi
}

# Assert file exists
assert_file_exists() {
    local path="$1"
    local msg="${2:-expected file '$path' to exist}"
    if [[ ! -f "$path" ]]; then
        printf "${RED}    ASSERT_FILE_EXISTS failed: %s${RESET}\n" "$msg" >&2
        return 1
    fi
}

# Assert file does NOT exist
assert_file_not_exists() {
    local path="$1"
    local msg="${2:-expected file '$path' to NOT exist}"
    if [[ -f "$path" ]]; then
        printf "${RED}    ASSERT_FILE_NOT_EXISTS failed: %s${RESET}\n" "$msg" >&2
        return 1
    fi
}

# Assert directory exists
assert_dir_exists() {
    local path="$1"
    local msg="${2:-expected directory '$path' to exist}"
    if [[ ! -d "$path" ]]; then
        printf "${RED}    ASSERT_DIR_EXISTS failed: %s${RESET}\n" "$msg" >&2
        return 1
    fi
}

# Assert file contains a pattern (grep -q)
assert_file_contains() {
    local path="$1"
    local pattern="$2"
    local msg="${3:-expected file '$path' to contain pattern '$pattern'}"
    if ! grep -q "$pattern" "$path" 2>/dev/null; then
        printf "${RED}    ASSERT_FILE_CONTAINS failed: %s${RESET}\n" "$msg" >&2
        return 1
    fi
}

# Assert file does NOT contain a pattern
assert_file_not_contains() {
    local path="$1"
    local pattern="$2"
    local msg="${3:-expected file '$path' NOT to contain pattern '$pattern'}"
    if grep -q "$pattern" "$path" 2>/dev/null; then
        printf "${RED}    ASSERT_FILE_NOT_CONTAINS failed: %s${RESET}\n" "$msg" >&2
        return 1
    fi
}

# Assert exit code of a command
assert_exit_code() {
    local expected_code="$1"
    shift
    local actual_code=0
    "$@" >/dev/null 2>&1 || actual_code=$?
    if [[ "$actual_code" -ne "$expected_code" ]]; then
        printf "${RED}    ASSERT_EXIT_CODE failed: expected %d, got %d for: %s${RESET}\n" \
            "$expected_code" "$actual_code" "$*" >&2
        return 1
    fi
}

# Assert a command succeeds (exit 0)
assert_success() {
    local output
    output=$("$@" 2>&1) || {
        printf "${RED}    ASSERT_SUCCESS failed: command returned non-zero: %s${RESET}\n" "$*" >&2
        printf "    Output: %.200s\n" "$output" >&2
        return 1
    }
}

# Assert a command fails (exit non-zero)
assert_failure() {
    if "$@" >/dev/null 2>&1; then
        printf "${RED}    ASSERT_FAILURE failed: command returned 0: %s${RESET}\n" "$*" >&2
        return 1
    fi
}

# Assert line count in a file
assert_line_count() {
    local path="$1"
    local expected="$2"
    local msg="${3:-expected $expected lines in '$path'}"
    local actual
    actual=$(wc -l < "$path" | tr -d ' ')
    if [[ "$actual" -ne "$expected" ]]; then
        printf "${RED}    ASSERT_LINE_COUNT failed: %s (got %d lines)${RESET}\n" "$msg" "$actual" >&2
        return 1
    fi
}

# Assert grep match count in a file
assert_grep_count() {
    local path="$1"
    local pattern="$2"
    local expected="$3"
    local msg="${4:-expected $expected matches of '$pattern' in '$path'}"
    local actual
    actual=$(grep -c "$pattern" "$path" 2>/dev/null || echo "0")
    if [[ "$actual" -ne "$expected" ]]; then
        printf "${RED}    ASSERT_GREP_COUNT failed: %s (got %d)${RESET}\n" "$msg" "$actual" >&2
        return 1
    fi
}

# ── Git Fixtures ─────────────────────────────────────────────────────────────

# Create a bare git repo (simulates a remote)
create_bare_repo() {
    local path="$1"
    mkdir -p "$path"
    git init --bare "$path" >/dev/null 2>&1
}

# Create a git repo with initial commit
create_git_repo() {
    local path="$1"
    mkdir -p "$path"
    (
        cd "$path"
        git init >/dev/null 2>&1
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "init" > README.md
        git add README.md
        git commit -m "Initial commit" >/dev/null 2>&1
    )
}

# Create a git repo tracking a bare remote
create_tracked_repo() {
    local repo_path="$1"
    local remote_path="$2"
    local remote_name="${3:-origin}"

    create_bare_repo "$remote_path"
    create_git_repo "$repo_path"
    (
        cd "$repo_path"
        git remote add "$remote_name" "$remote_path"
        git push -u "$remote_name" "$(git branch --show-current)" >/dev/null 2>&1
    )
}

# Add a commit to a repo
add_commit() {
    local repo_path="$1"
    local msg="${2:-test commit}"
    local filename="${3:-file-$(date +%s%N).txt}"
    (
        cd "$repo_path"
        echo "$msg" > "$filename"
        git add "$filename"
        git commit -m "$msg" >/dev/null 2>&1
    )
}

# ── Project Fixtures ─────────────────────────────────────────────────────────

# Create a minimal session-context.md for testing rotate-session.sh
create_session_context() {
    local dir="$1"
    local goal="${2:-Test session goal}"
    local machine="${3:-test-machine}"
    local items="${4:-"- [x] Did something useful"}"

    mkdir -p "$dir/docs"

    cat > "$dir/session-context.md" << EOF
# Session Context

## Session Info
- **Last Updated**: 2026-01-01T00:00Z
- **Machine**: $machine
- **Working Directory**: $dir
- **Session Goal**: $goal

## Current State
- **Active Task**: Testing
- **Progress** (use \`- [x]\` checkbox for each completed item):
$items
- **Pending**: Nothing

## Key Decisions
- Test decision: for testing purposes

## Recovery Instructions
1. Resume testing
EOF
}
