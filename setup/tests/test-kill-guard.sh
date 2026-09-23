#!/usr/bin/env bash
# Tests for global/hooks/kill-guard.sh — CFG-694.
#
# MG rejected the behavioural form of this outright ("did you think i would know processes
# by PID?? ridiculous, do better - this is cfg job"), so ownership is proved mechanically:
# same session id, or written down by a fleet launcher at launch.
#
# The guard UNDER-blocks by design. A guard that refuses legal work gets switched off and
# takes its working half with it (CFG-658), so anything it cannot resolve passes.
#
# NOTE: one decisive assert per test — this harness lets only the FINAL assert decide.
source "$(dirname "$0")/test-helpers.sh"

HOOK="$REPO_ROOT/global/hooks/kill-guard.sh"
LIB="$REPO_ROOT/setup/scripts/launch-registry.sh"

suite_header "kill-guard.sh (CFG-694 process ownership)"

_rc() {
    local input rc=0
    input=$(jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}')
    HOOK_STDERR=$(CC_LAUNCH_REGISTRY="$TEST_TMPDIR/reg.tsv" CC_LAUNCH_REGISTRY_LIB="$LIB" \
        printf '%s' "$input" | CC_LAUNCH_REGISTRY="$TEST_TMPDIR/reg.tsv" CC_LAUNCH_REGISTRY_LIB="$LIB" bash "$HOOK" 2>&1) || rc=$?
    printf '%s' "$rc"
}

# A process this session did NOT start and did not register: setsid gives it its own
# session id, which is exactly what somebody else's process looks like.
_foreign_pid() {
    setsid sleep 120 >/dev/null 2>&1 &
    sleep 0.3
    pgrep -n -f 'sleep 120' 2>/dev/null | head -1
}

# ── MUST BLOCK ────────────────────────────────────────────────────────────────

t_blocks_foreign_pid() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || { echo "    could not create a foreign process" >&2; return 1; }
    local rc; rc=$(_rc "kill $pid")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc for an unregistered, foreign-session pid"
    assert_eq "2" "$rc" "killing a process this session cannot prove it started must be refused"
}
run_test "blocks kill of a foreign, unregistered pid" t_blocks_foreign_pid

t_refusal_lists_alternatives() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    _rc "kill -9 $pid" >/dev/null
    kill -9 "$pid" 2>/dev/null
    echo "    measured refusal length: $(printf '%s' "$HOOK_STDERR" | wc -l) lines"
    assert_contains "$HOOK_STDERR" "MAY kill" "the refusal must name what IS allowed, not just say no"
}
run_test "the refusal names the registered alternatives" t_refusal_lists_alternatives

t_blocks_killall_by_name() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    local rc; rc=$(_rc "killall sleep")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc for killall by name"
    assert_eq "2" "$rc" "killall resolves to somebody else's processes and must be refused"
}
run_test "blocks killall by name when it would hit a foreign process" t_blocks_killall_by_name

# ── MUST ALLOW ────────────────────────────────────────────────────────────────

t_allows_registered_pid() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    CC_LAUNCH_REGISTRY="$TEST_TMPDIR/reg.tsv" bash "$LIB" add "$pid" "test-launch" "sleep 120"
    local rc; rc=$(_rc "kill $pid")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc after registering the same pid"
    assert_eq "0" "$rc" "a launcher-registered process is this session's to kill"
}
run_test "allows killing a registered launch" t_allows_registered_pid

t_allows_own_descendant() {
    sleep 60 & local pid=$!
    local rc; rc=$(_rc "kill $pid")
    kill "$pid" 2>/dev/null
    echo "    measured rc=$rc for a pid in this session's own tree"
    assert_eq "0" "$rc" "a process in this session's own tree needs no registry entry"
}
run_test "allows killing its own descendant" t_allows_own_descendant

t_allows_kill_zero_probe() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    local rc; rc=$(_rc "kill -0 $pid")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc for kill -0 (a probe, signals nothing)"
    assert_eq "0" "$rc" "kill -0 kills nothing and must not be refused"
}
run_test "allows kill -0 (liveness probe)" t_allows_kill_zero_probe

t_allows_job_spec() {
    assert_eq "0" "$(_rc 'kill %1')" "a job spec belongs to the caller's own shell"
}
run_test "allows a job spec" t_allows_job_spec

t_allows_unresolvable_variable() {
    assert_eq "0" "$(_rc 'kill $SERVER_PID')" \
        "an unresolved target passes — the guard under-blocks rather than refuse legal work"
}
run_test "allows an unresolvable variable target (under-blocks)" t_allows_unresolvable_variable

t_allows_grep_for_the_word() {
    assert_eq "0" "$(_rc "grep -rn 'killall' docs/")" "searching for the word is not running it"
}
run_test "allows grepping for the word" t_allows_grep_for_the_word

t_allows_unrelated() {
    assert_eq "0" "$(_rc 'ls -la /tmp')" "an unrelated command must pass untouched"
}
run_test "allows an unrelated command" t_allows_unrelated

t_ignores_non_bash() {
    local input rc=0
    input=$(jq -n '{tool_name: "Read", tool_input: {file_path: "/tmp/killall.txt"}}')
    printf '%s' "$input" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "a non-Bash tool must never be inspected"
}
run_test "ignores non-Bash tools" t_ignores_non_bash

suite_summary
