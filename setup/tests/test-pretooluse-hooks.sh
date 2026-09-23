#!/usr/bin/env bash
# Test PreToolUse hooks for correct CC protocol behavior.
#
# CC hook protocol for command hooks (CC 2.1.170):
#   - Exit 0 + empty stdout = hook_success (no UI noise)         ← guard hooks (this file)
#   - Exit 0 + {"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"…"}}
#                           = allow tool + inject context        ← injector hooks (see below)
#   - Exit 2 + stderr = blocking error
#   - Exit non-zero (not 2) = non_blocking_error
#
# NOTE: The old "never output JSON from PreToolUse — fails Zod" rule was true for CC 2.1.76
#       but is REVERSED in 2.1.170 (PreToolUse now accepts hookSpecificOutput.additionalContext).
#       See knowledge/hook-behavior.md and test-point-of-action-knowledge.sh for the injector path.
#       The GUARD hooks tested here (afd-relay, unc-path-guard) correctly exit 0 with NO stdout
#       for "allow" and exit 2 + stderr for "block" — that contract is unchanged.

set -euo pipefail

HOOKS_DIR="${HOOKS_DIR:-$HOME/.claude/hooks}"
PASS=0
FAIL=0
SKIP=0
ERRORS=""

assert() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: $desc (expected: '$expected', got: '$actual')"
    fi
}

assert_empty() {
    local desc="$1" actual="$2"
    if [[ -z "$actual" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: $desc (expected empty, got: '${actual:0:80}')"
    fi
}

# --- afd-relay.sh ---
echo "Testing afd-relay.sh..."

# Use a temp HOME to avoid deleting real user files (CFG-278)
_REAL_HOME="$HOME"
TEST_TMPDIR="$(mktemp -d)"
export HOME="$TEST_TMPDIR"

# Ensure not in AFK mode (now writes to temp HOME, not real)
rm -f "$HOME/.afd-afk" "$HOME/.afd-user-active"

# Test: Non-Bash tool → exit 0, empty stdout
STDOUT=$(echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/test"}}' | bash "$HOOKS_DIR/afd-relay.sh" 2>/dev/null)
EXIT=$?
assert "afd-relay Read exit code" "0" "$EXIT"
assert_empty "afd-relay Read stdout" "$STDOUT"

STDOUT=$(echo '{"tool_name":"Grep","tool_input":{}}' | bash "$HOOKS_DIR/afd-relay.sh" 2>/dev/null)
EXIT=$?
assert "afd-relay Grep exit code" "0" "$EXIT"
assert_empty "afd-relay Grep stdout" "$STDOUT"

# Test: Bash tool (not AFK) → exit 0, empty stdout
STDOUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}' | bash "$HOOKS_DIR/afd-relay.sh" 2>/dev/null)
EXIT=$?
assert "afd-relay Bash (not AFK) exit code" "0" "$EXIT"
assert_empty "afd-relay Bash (not AFK) stdout" "$STDOUT"

# Restore real HOME and clean up temp dir
export HOME="$_REAL_HOME"
rm -rf "$TEST_TMPDIR"

# --- unc-path-guard.sh ---
echo "Testing unc-path-guard.sh..."

# Test: Non-Bash tool → exit 0, empty stdout
STDOUT=$(echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/test"}}' | bash "$HOOKS_DIR/unc-path-guard.sh" 2>/dev/null)
EXIT=$?
assert "unc-guard Read exit code" "0" "$EXIT"
assert_empty "unc-guard Read stdout" "$STDOUT"

# Test: Bash without Windows exe → exit 0
STDOUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}' | bash "$HOOKS_DIR/unc-path-guard.sh" 2>/dev/null)
EXIT=$?
assert "unc-guard plain bash exit code" "0" "$EXIT"
assert_empty "unc-guard plain bash stdout" "$STDOUT"

# WSL-specific tests: /mnt/c must exist
if [[ -d /mnt/c ]]; then
    # Test: Bash with cmd.exe from /mnt/ path → exit 0 (allowed)
    STDOUT=$(cd /mnt/c 2>/dev/null && echo '{"tool_name":"Bash","tool_input":{"command":"cmd.exe /c echo hi"}}' | bash "$HOOKS_DIR/unc-path-guard.sh" 2>/dev/null)
    EXIT=$?
    assert "unc-guard cmd.exe from /mnt/ exit code" "0" "$EXIT"
    assert_empty "unc-guard cmd.exe from /mnt/ stdout" "$STDOUT"
else
    echo "  SKIP: /mnt/c not available (not WSL) — skipping cmd.exe from /mnt/ test"
    SKIP=$((SKIP + 1))
fi

# Test: Bash with cmd.exe from WSL path → exit 2 (blocked)
# Note: exit 2 tests need || true to survive set -e
EXIT=0
STDERR=$(cd /tmp && echo '{"tool_name":"Bash","tool_input":{"command":"cmd.exe /c echo hi"}}' | bash "$HOOKS_DIR/unc-path-guard.sh" 2>&1 >/dev/null) || EXIT=$?
assert "unc-guard cmd.exe from /tmp exit code" "2" "$EXIT"
[[ "$STDERR" == *"BLOCKED"* ]] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); ERRORS="${ERRORS}\n  FAIL: unc-guard cmd.exe block message missing (got: '$STDERR')"; }

# Test: Bash with multipass from WSL path → exit 2 (blocked)
EXIT=0
STDERR=$(cd /tmp && echo '{"tool_name":"Bash","tool_input":{"command":"multipass exec vm -- uname"}}' | bash "$HOOKS_DIR/unc-path-guard.sh" 2>&1 >/dev/null) || EXIT=$?
assert "unc-guard multipass from /tmp exit code" "2" "$EXIT"

# Test: Bash with powershell.exe from WSL path → exit 2 (blocked)
EXIT=0
STDERR=$(cd /tmp && echo '{"tool_name":"Bash","tool_input":{"command":"powershell.exe -Command Get-Date"}}' | bash "$HOOKS_DIR/unc-path-guard.sh" 2>&1 >/dev/null) || EXIT=$?
assert "unc-guard powershell from /tmp exit code" "2" "$EXIT"

# WSL-specific tests: /mnt/c must exist
if [[ -d /mnt/c ]]; then
    # Test: Bash with multipass from /mnt/ path → exit 0 (allowed)
    STDOUT=$(cd /mnt/c 2>/dev/null && echo '{"tool_name":"Bash","tool_input":{"command":"multipass list"}}' | bash "$HOOKS_DIR/unc-path-guard.sh" 2>/dev/null)
    EXIT=$?
    assert "unc-guard multipass from /mnt/ exit code" "0" "$EXIT"
    assert_empty "unc-guard multipass from /mnt/ stdout" "$STDOUT"
else
    echo "  SKIP: /mnt/c not available (not WSL) — skipping multipass from /mnt/ test"
    SKIP=$((SKIP + 1))
fi

# Test: Bash with cmd.exe in message text (not as executable) → exit 0 (no false positive)
STDOUT=$(cd /tmp && echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"blocks cmd.exe from UNC\""}}' | bash "$HOOKS_DIR/unc-path-guard.sh" 2>/dev/null)
EXIT=$?
assert "unc-guard cmd.exe in string not blocked" "0" "$EXIT"
assert_empty "unc-guard cmd.exe in string stdout" "$STDOUT"

# Test: Bash with multipass in string (not as executable) → exit 0
STDOUT=$(cd /tmp && echo '{"tool_name":"Bash","tool_input":{"command":"echo multipass is cool"}}' | bash "$HOOKS_DIR/unc-path-guard.sh" 2>/dev/null)
EXIT=$?
assert "unc-guard multipass in string not blocked" "0" "$EXIT"

# --- Results ---
echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [[ $FAIL -gt 0 ]]; then
    echo -e "Failures:$ERRORS"
    exit 1
fi
echo "All tests passed."
