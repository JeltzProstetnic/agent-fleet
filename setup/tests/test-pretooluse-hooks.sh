#!/usr/bin/env bash
# Test PreToolUse hooks for correct CC protocol behavior.
#
# CC hook protocol for command hooks:
#   - Exit 0 + empty stdout = hook_success (no UI noise)
#   - Exit 0 + JSON stdout = validated against gN6 schema (FAILS for hookSpecificOutput!)
#   - Exit 2 + stderr = blocking error
#   - Exit non-zero (not 2) = non_blocking_error
#
# RULE: PreToolUse command hooks must exit 0 with NO stdout for "allow".
#       Never output JSON — it fails CC's Zod schema validation.

set -euo pipefail

HOOKS_DIR="${HOOKS_DIR:-$HOME/.claude/hooks}"
PASS=0
FAIL=0
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

# --- rtk-rewrite.sh ---
echo "Testing rtk-rewrite.sh..."

# Test: Non-Bash tool -> exit 0, empty stdout
STDOUT=$(echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/test"}}' | bash "$HOOKS_DIR/rtk-rewrite.sh" 2>/dev/null)
EXIT=$?
assert "rtk-rewrite Read exit code" "0" "$EXIT"
assert_empty "rtk-rewrite Read stdout" "$STDOUT"

STDOUT=$(echo '{"tool_name":"Edit","tool_input":{}}' | bash "$HOOKS_DIR/rtk-rewrite.sh" 2>/dev/null)
EXIT=$?
assert "rtk-rewrite Edit exit code" "0" "$EXIT"
assert_empty "rtk-rewrite Edit stdout" "$STDOUT"

STDOUT=$(echo '{"tool_name":"Glob","tool_input":{}}' | bash "$HOOKS_DIR/rtk-rewrite.sh" 2>/dev/null)
EXIT=$?
assert "rtk-rewrite Glob exit code" "0" "$EXIT"
assert_empty "rtk-rewrite Glob stdout" "$STDOUT"

# Test: Bash tool with non-rewritable command -> exit 0, empty stdout
STDOUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}' | bash "$HOOKS_DIR/rtk-rewrite.sh" 2>/dev/null)
EXIT=$?
assert "rtk-rewrite Bash echo exit code" "0" "$EXIT"
assert_empty "rtk-rewrite Bash echo stdout" "$STDOUT"

# --- afd-relay.sh ---
echo "Testing afd-relay.sh..."

# Ensure not in AFK mode
rm -f "$HOME/.afd-afk" "$HOME/.afd-user-active"

# Test: Non-Bash tool -> exit 0, empty stdout
STDOUT=$(echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/test"}}' | bash "$HOOKS_DIR/afd-relay.sh" 2>/dev/null)
EXIT=$?
assert "afd-relay Read exit code" "0" "$EXIT"
assert_empty "afd-relay Read stdout" "$STDOUT"

STDOUT=$(echo '{"tool_name":"Grep","tool_input":{}}' | bash "$HOOKS_DIR/afd-relay.sh" 2>/dev/null)
EXIT=$?
assert "afd-relay Grep exit code" "0" "$EXIT"
assert_empty "afd-relay Grep stdout" "$STDOUT"

# Test: Bash tool (not AFK) -> exit 0, empty stdout
STDOUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}' | bash "$HOOKS_DIR/afd-relay.sh" 2>/dev/null)
EXIT=$?
assert "afd-relay Bash (not AFK) exit code" "0" "$EXIT"
assert_empty "afd-relay Bash (not AFK) stdout" "$STDOUT"

# --- Results ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    echo -e "Failures:$ERRORS"
    exit 1
fi
echo "All tests passed."
