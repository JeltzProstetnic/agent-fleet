#!/usr/bin/env bash
# Tests for CFG-172 Phase 2: proactive self-audit checks
# Check 15-escalation (escalation aggregation)
# Check 15b-backlog-health (backlog health metrics)
# Check 16-deployed-drift (deployed vs repo drift)
#
# NOTE: Check 43 (LOC budget) merged into existing Check 13 — no separate module needed.

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAIL_DETAILS=""

pass() { ((TESTS_PASSED++)) || true; ((TESTS_RUN++)) || true; echo "  PASS: $1"; }
fail() { ((TESTS_FAILED++)) || true; ((TESTS_RUN++)) || true; FAIL_DETAILS="${FAIL_DETAILS}\n  FAIL: $1"; echo "  FAIL: $1"; }

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
CHECKS_DIR="$REPO_ROOT/global/hooks/checks"

# Run a check script in a subshell and capture WARNINGS/INBOX_MSG
# Usage: result=$(run_check <check_file>)
# Output: WARNINGS=<value>\nINBOX_MSG=<value>
run_check() {
    local check_file="$1"
    (
        source "$check_file"
        echo "WARNINGS=${WARNINGS:-}"
        echo "INBOX_MSG=${INBOX_MSG:-}"
    )
}

# ════════════════════════════════════════════════
# 15-escalation.sh — Escalation aggregation
# ════════════════════════════════════════════════
echo "=== 15-escalation.sh tests ==="

# Test: No warnings → no escalation
_result=$(
    WARNINGS=""
    INBOX_MSG=""
    CONFIG_REPO="/tmp/nonexistent"
    PROJECT_DIR="/tmp/nonexistent"
    source "$CHECKS_DIR/15-escalation.sh"
    echo "$WARNINGS"
)
if [[ "$_result" == "" ]]; then pass "no escalation when no warnings"
else fail "no escalation when no warnings (got: $_result)"; fi

# Test: 2 warnings → no escalation (threshold is 3)
_result=$(
    WARNINGS="warn1 | warn2"
    INBOX_MSG=""
    CONFIG_REPO="/tmp/nonexistent"
    PROJECT_DIR="/tmp/nonexistent"
    source "$CHECKS_DIR/15-escalation.sh"
    echo "$WARNINGS"
)
if [[ "$_result" != *"ESCALATION"* ]]; then pass "no escalation with 2 warnings"
else fail "no escalation with 2 warnings (got: $_result)"; fi

# Test: 4 warnings → escalation summary prepended
_result=$(
    WARNINGS="warn1 | warn2 | warn3 | warn4"
    INBOX_MSG=""
    CONFIG_REPO="/tmp/nonexistent"
    PROJECT_DIR="/tmp/nonexistent"
    source "$CHECKS_DIR/15-escalation.sh"
    echo "$WARNINGS"
)
if [[ "$_result" == *"ESCALATION:"* ]] && [[ "$_result" == *"4 warning"* ]]; then
    pass "escalation fires with 4 warnings"
else fail "escalation fires with 4 warnings (got: $_result)"; fi

# Test: Escalation is prepended (first item)
_result=$(
    WARNINGS="warn1 | warn2 | warn3 | warn4"
    INBOX_MSG=""
    CONFIG_REPO="/tmp/nonexistent"
    PROJECT_DIR="/tmp/nonexistent"
    source "$CHECKS_DIR/15-escalation.sh"
    echo "$WARNINGS"
)
if [[ "$_result" == "ESCALATION:"* ]]; then pass "escalation is prepended"
else fail "escalation is prepended (got first chars: ${_result:0:30})"; fi

# ════════════════════════════════════════════════
# 15b-backlog-health.sh — Backlog health metrics
# ════════════════════════════════════════════════
echo ""
echo "=== 15b-backlog-health.sh tests ==="

# Clean daily gate before each test group
_BACKLOG_GATE="/tmp/.backlog-health-check-$(date +%Y-%m-%d)"
rm -f "$_BACKLOG_GATE"

# Test: No backlog file → no warning
_result=$(
    WARNINGS=""
    INBOX_MSG=""
    CONFIG_REPO="/tmp/nonexistent"
    PROJECT_DIR="/tmp/nonexistent-proj"
    source "$CHECKS_DIR/15b-backlog-health.sh"
    echo "$WARNINGS"
)
if [[ "$_result" != *"BACKLOG"* ]]; then pass "no warning when backlog missing"
else fail "no warning when backlog missing (got: $_result)"; fi

# Test: Healthy backlog → no warning
rm -f "$_BACKLOG_GATE"
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/project"
cat > "$TEST_DIR/project/backlog.md" << 'BACKLOG'
# Backlog

## Open

- [ ] [P2] `CFG-100` **Some task**: Description. Epic: E-01
- [ ] [P3] `CFG-101` **Another task**: Description. Epic: E-02

## Done
- [x] [P1] `CFG-099` **Done task**: Done.
BACKLOG
_result=$(
    WARNINGS=""
    INBOX_MSG=""
    CONFIG_REPO="$TEST_DIR"
    PROJECT_DIR="$TEST_DIR/project"
    source "$CHECKS_DIR/15b-backlog-health.sh"
    echo "$WARNINGS"
)
if [[ "$_result" != *"BACKLOG"* ]]; then pass "no warning for healthy backlog"
else fail "no warning for healthy backlog (got: $_result)"; fi
rm -rf "$TEST_DIR"

# Test: P0 item exists → warning
rm -f "$_BACKLOG_GATE"
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/project"
cat > "$TEST_DIR/project/backlog.md" << 'BACKLOG'
# Backlog

## Open

- [ ] [P0] `CFG-100` **Critical task**: Description. Epic: E-01
- [ ] [P2] `CFG-101` **Normal task**: Description. Epic: E-02
BACKLOG
_result=$(
    WARNINGS=""
    INBOX_MSG=""
    CONFIG_REPO="$TEST_DIR"
    PROJECT_DIR="$TEST_DIR/project"
    source "$CHECKS_DIR/15b-backlog-health.sh"
    echo "$WARNINGS"
)
if [[ "$_result" == *"P0"* ]]; then pass "warns on P0 items"
else fail "warns on P0 items (got: $_result)"; fi
rm -rf "$TEST_DIR"

# Test: >5 open P1 items → warning
rm -f "$_BACKLOG_GATE"
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/project"
cat > "$TEST_DIR/project/backlog.md" << 'BACKLOG'
# Backlog

## Open

- [ ] [P1] `CFG-100` **Task 1**: Desc. Epic: E-01
- [ ] [P1] `CFG-101` **Task 2**: Desc. Epic: E-01
- [ ] [P1] `CFG-102` **Task 3**: Desc. Epic: E-01
- [ ] [P1] `CFG-103` **Task 4**: Desc. Epic: E-01
- [ ] [P1] `CFG-104` **Task 5**: Desc. Epic: E-01
- [ ] [P1] `CFG-105` **Task 6**: Desc. Epic: E-01
BACKLOG
_result=$(
    WARNINGS=""
    INBOX_MSG=""
    CONFIG_REPO="$TEST_DIR"
    PROJECT_DIR="$TEST_DIR/project"
    source "$CHECKS_DIR/15b-backlog-health.sh"
    echo "$WARNINGS"
)
if [[ "$_result" == *"P1"* ]] && [[ "$_result" == *"6"* ]]; then pass "warns on >5 open P1 items"
else fail "warns on >5 open P1 items (got: $_result)"; fi
rm -rf "$TEST_DIR"

# Test: Exactly 5 P1 items → no warning
rm -f "$_BACKLOG_GATE"
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/project"
cat > "$TEST_DIR/project/backlog.md" << 'BACKLOG'
# Backlog

## Open

- [ ] [P1] `CFG-100` **Task 1**: Desc. Epic: E-01
- [ ] [P1] `CFG-101` **Task 2**: Desc. Epic: E-01
- [ ] [P1] `CFG-102` **Task 3**: Desc. Epic: E-01
- [ ] [P1] `CFG-103` **Task 4**: Desc. Epic: E-01
- [ ] [P1] `CFG-104` **Task 5**: Desc. Epic: E-01
BACKLOG
_result=$(
    WARNINGS=""
    INBOX_MSG=""
    CONFIG_REPO="$TEST_DIR"
    PROJECT_DIR="$TEST_DIR/project"
    source "$CHECKS_DIR/15b-backlog-health.sh"
    echo "$WARNINGS"
)
if [[ "$_result" != *"P1"* ]]; then pass "no warning at exactly 5 P1 items"
else fail "no warning at exactly 5 P1 items (got: $_result)"; fi
rm -rf "$TEST_DIR"

# Test: Daily gate prevents double-run
rm -f "$_BACKLOG_GATE"
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/project"
cat > "$TEST_DIR/project/backlog.md" << 'BACKLOG'
# Backlog

## Open

- [ ] [P0] `CFG-100` **Critical**: Desc. Epic: E-01
BACKLOG
_first=$(
    WARNINGS=""
    INBOX_MSG=""
    CONFIG_REPO="$TEST_DIR"
    PROJECT_DIR="$TEST_DIR/project"
    source "$CHECKS_DIR/15b-backlog-health.sh"
    echo "$WARNINGS"
)
_second=$(
    WARNINGS=""
    INBOX_MSG=""
    CONFIG_REPO="$TEST_DIR"
    PROJECT_DIR="$TEST_DIR/project"
    source "$CHECKS_DIR/15b-backlog-health.sh"
    echo "$WARNINGS"
)
if [[ "$_second" == "" ]] && [[ "$_first" == *"P0"* ]]; then pass "daily gate blocks second run"
else fail "daily gate blocks second run (first: $_first, second: $_second)"; fi
rm -f "$_BACKLOG_GATE"
rm -rf "$TEST_DIR"

# ════════════════════════════════════════════════
# 16-deployed-drift.sh — Deployed vs repo drift
# ════════════════════════════════════════════════
echo ""
echo "=== 16-deployed-drift.sh tests ==="

# Test: No deployed hooks dir → no warning
_result=$(
    WARNINGS=""
    INBOX_MSG=""
    CONFIG_REPO="/tmp/nonexistent"
    PROJECT_DIR="/tmp/nonexistent"
    _DEPLOYED_HOOKS_DIR="/tmp/nonexistent-deployed"
    source "$CHECKS_DIR/16-deployed-drift.sh"
    echo "$WARNINGS"
)
if [[ "$_result" != *"DEPLOYED_DRIFT"* ]]; then pass "no warning when deployed dir missing"
else fail "no warning when deployed dir missing (got: $_result)"; fi

# Test: Matching files → no warning
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/repo/global/hooks" "$TEST_DIR/deployed"
echo "identical content" > "$TEST_DIR/repo/global/hooks/config-check.sh"
echo "identical content" > "$TEST_DIR/deployed/config-check.sh"
_result=$(
    WARNINGS=""
    INBOX_MSG=""
    CONFIG_REPO="$TEST_DIR/repo"
    PROJECT_DIR="$TEST_DIR"
    _DEPLOYED_HOOKS_DIR="$TEST_DIR/deployed"
    source "$CHECKS_DIR/16-deployed-drift.sh"
    echo "$WARNINGS"
)
if [[ "$_result" != *"DEPLOYED_DRIFT"* ]]; then pass "no warning when files match"
else fail "no warning when files match (got: $_result)"; fi
rm -rf "$TEST_DIR"

# Test: Drifted file → warning
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/repo/global/hooks" "$TEST_DIR/deployed"
echo "repo version" > "$TEST_DIR/repo/global/hooks/config-check.sh"
echo "deployed version (stale)" > "$TEST_DIR/deployed/config-check.sh"
_result=$(
    WARNINGS=""
    INBOX_MSG=""
    CONFIG_REPO="$TEST_DIR/repo"
    PROJECT_DIR="$TEST_DIR"
    _DEPLOYED_HOOKS_DIR="$TEST_DIR/deployed"
    source "$CHECKS_DIR/16-deployed-drift.sh"
    echo "$WARNINGS"
)
if [[ "$_result" == *"DEPLOYED_DRIFT"* ]] && [[ "$_result" == *"config-check.sh"* ]]; then
    pass "warns on drifted hook"
else fail "warns on drifted hook (got: $_result)"; fi
rm -rf "$TEST_DIR"

# Test: Checks subdirectory too
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/repo/global/hooks/checks" "$TEST_DIR/deployed/checks"
echo "repo" > "$TEST_DIR/repo/global/hooks/checks/01-sync-state.sh"
echo "old" > "$TEST_DIR/deployed/checks/01-sync-state.sh"
_result=$(
    WARNINGS=""
    INBOX_MSG=""
    CONFIG_REPO="$TEST_DIR/repo"
    PROJECT_DIR="$TEST_DIR"
    _DEPLOYED_HOOKS_DIR="$TEST_DIR/deployed"
    source "$CHECKS_DIR/16-deployed-drift.sh"
    echo "$WARNINGS"
)
if [[ "$_result" == *"DEPLOYED_DRIFT"* ]]; then pass "detects drift in checks/ subdir"
else fail "detects drift in checks/ subdir (got: $_result)"; fi
rm -rf "$TEST_DIR"

# Test: Multiple drifted files → count correct
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/repo/global/hooks/checks" "$TEST_DIR/deployed/checks"
echo "v1" > "$TEST_DIR/repo/global/hooks/config-check.sh"
echo "v0" > "$TEST_DIR/deployed/config-check.sh"
echo "v1" > "$TEST_DIR/repo/global/hooks/checks/01-sync-state.sh"
echo "v0" > "$TEST_DIR/deployed/checks/01-sync-state.sh"
echo "v1" > "$TEST_DIR/repo/global/hooks/checks/02-session-state.sh"
echo "v0" > "$TEST_DIR/deployed/checks/02-session-state.sh"
_result=$(
    WARNINGS=""
    INBOX_MSG=""
    CONFIG_REPO="$TEST_DIR/repo"
    PROJECT_DIR="$TEST_DIR"
    _DEPLOYED_HOOKS_DIR="$TEST_DIR/deployed"
    source "$CHECKS_DIR/16-deployed-drift.sh"
    echo "$WARNINGS"
)
if [[ "$_result" == *"3"* ]] && [[ "$_result" == *"DEPLOYED_DRIFT"* ]]; then
    pass "reports correct count for multiple drifted files"
else fail "reports correct count (got: $_result)"; fi
rm -rf "$TEST_DIR"

# ════════════════════════════════════════════════
# CFG-237: rotate-session.sh approval tracking
# ════════════════════════════════════════════════
echo ""
echo "=== CFG-237: approval tracking in rotate-session.sh ==="
ROTATE_SCRIPT="$REPO_ROOT/setup/scripts/rotate-session.sh"

# Test: New backlog item without approval → warning
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/docs"
cat > "$TEST_DIR/session-context.md" << 'SC'
# Session Context

## Session Info
- **Last Updated**: 2026-03-19T10:00:00+01:00
- **Machine**: WSL
- **Working Directory**: ~/test
- **Session Goal**: Test approval tracking

## Current State
- **Active Task**: Testing
- **Progress** (use `- [x]` checkbox for each completed item):
- [x] Added CFG-999 to backlog
- **Pending**: nothing

## Key Decisions
- Decided to add CFG-999

## Recovery Instructions
SC
cat > "$TEST_DIR/backlog.md" << 'BL'
# Backlog

## Open

- [ ] [P2] `CFG-999` **Test item**: Test. Epic: E-01
BL
_output=$(bash "$ROTATE_SCRIPT" "$TEST_DIR" 2>&1)
if [[ "$_output" == *"WARNING"* ]] && [[ "$_output" == *"CFG-999"* ]] && [[ "$_output" == *"approval"* ]]; then
    pass "warns on unapproved backlog item"
else fail "warns on unapproved backlog item (got: $_output)"; fi
rm -rf "$TEST_DIR"

# Test: Approved backlog item → no warning
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/docs"
cat > "$TEST_DIR/session-context.md" << 'SC'
# Session Context

## Session Info
- **Last Updated**: 2026-03-19T10:00:00+01:00
- **Machine**: WSL
- **Working Directory**: ~/test
- **Session Goal**: Test approval tracking

## Current State
- **Active Task**: Testing
- **Progress** (use `- [x]` checkbox for each completed item):
- [x] Added CFG-888 to backlog
- **Pending**: nothing

## Key Decisions
- User approved CFG-888 at P2

## Recovery Instructions
SC
cat > "$TEST_DIR/backlog.md" << 'BL'
# Backlog

## Open

- [ ] [P2] `CFG-888` **Approved item**: Test. Epic: E-01
BL
_output=$(bash "$ROTATE_SCRIPT" "$TEST_DIR" 2>&1)
if [[ "$_output" != *"CFG-888"*"approval"* ]]; then
    pass "no warning for approved backlog item"
else fail "no warning for approved backlog item (got: $_output)"; fi
rm -rf "$TEST_DIR"

# Test: Done backlog item → no warning (only open items trigger)
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/docs"
cat > "$TEST_DIR/session-context.md" << 'SC'
# Session Context

## Session Info
- **Last Updated**: 2026-03-19T10:00:00+01:00
- **Machine**: WSL
- **Working Directory**: ~/test
- **Session Goal**: Close out CFG-777

## Current State
- **Active Task**: Done
- **Progress** (use `- [x]` checkbox for each completed item):
- [x] Completed CFG-777
- **Pending**: nothing

## Key Decisions
- CFG-777 is done
SC
cat > "$TEST_DIR/backlog.md" << 'BL'
# Backlog

## Open

## Done
- [x] [P1] `CFG-777` **Done item**: Done.
BL
_output=$(bash "$ROTATE_SCRIPT" "$TEST_DIR" 2>&1)
if [[ "$_output" != *"CFG-777"*"approval"* ]]; then
    pass "no warning for done backlog items"
else fail "no warning for done backlog items (got: $_output)"; fi
rm -rf "$TEST_DIR"

# ════════════════════════════════════════════════
# Summary (updated)
# ════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════"
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [ "$TESTS_FAILED" -gt 0 ]; then
    echo -e "Failures:$FAIL_DETAILS"
    exit 1
fi
echo "═══════════════════════════════════"
