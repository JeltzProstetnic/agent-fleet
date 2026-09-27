#!/usr/bin/env bash
# Tests for agent-fleet GH#12 instrumentation: config-check.sh appends one line
# per invocation to a log OUTSIDE the repo (~/.claude/logs/session-start.log)
# recording payload size + hash. Six sessions started with NONE of the
# SessionStart additionalContext reaching the model while a manual re-run of
# the hook was healthy; nothing could tell "hook never invoked" from "invoked,
# output discarded". A log line for a session that received nothing settles
# it. This is instrumentation, not a root-cause fix.
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/test-check-helpers.sh"

suite_header "config-check.sh: per-invocation log (GH#12)"

_log_env() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    # The patched script sources its libs relative to ITS OWN location, so the
    # stdin reader must sit next to it for the session id to be read at all.
    cp "$REPO_ROOT/global/hooks/lib-hook-stdin.sh" "$TEST_TMPDIR/"
    create_patched_script "$config_repo" "$mock_home" "$project_dir"
}

_sha12() { printf '%s' "$1" | sha256sum | cut -c1-12; }

test_log_line_records_size_and_hash() {
    local patched log out ctx line
    patched=$(_log_env)
    log="$TEST_TMPDIR/home/.claude/logs/session-start.log"

    out=$(printf '{"session_id":"sess-abc123","hook_event_name":"SessionStart","source":"startup"}' | run_hook "$patched")
    ctx=$(extract_additional_context "$out")
    [ -n "$ctx" ] || { echo "hook emitted no additionalContext" >&2; return 1; }

    assert_file_exists "$log" "log lives outside the repo, under HOME/.claude/logs" || return 1
    line=$(tail -1 "$log")
    assert_contains "$line" "session=sess-abc123" "CC session id from hook stdin" || return 1
    assert_contains "$line" "cwd=$TEST_TMPDIR/project" "project dir" || return 1
    assert_contains "$line" "chars=${#ctx}" "payload size matches what was emitted" || return 1
    assert_contains "$line" "sha256=$(_sha12 "$ctx")" "payload hash matches what was emitted" || return 1
    assert_contains "$line" "emit=" "which encoder produced the JSON" || return 1
    # ISO timestamp leads the line
    printf '%s' "$line" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' \
        || { echo "line does not start with a timestamp: $line" >&2; return 1; }
}
run_test "each invocation appends timestamp, session, cwd, payload chars + sha256" test_log_line_records_size_and_hash

test_log_written_without_session_id() {
    local patched log line
    patched=$(_log_env)
    log="$TEST_TMPDIR/home/.claude/logs/session-start.log"
    run_hook "$patched" </dev/null >/dev/null
    assert_file_exists "$log" || return 1
    line=$(tail -1 "$log")
    assert_contains "$line" "session=-" "missing id is recorded as '-', the line still lands"
}
run_test "invocation without stdin JSON still logs (session=-)" test_log_written_without_session_id

test_log_is_bounded() {
    local patched log n
    patched=$(_log_env)
    log="$TEST_TMPDIR/home/.claude/logs/session-start.log"
    mkdir -p "$(dirname "$log")"
    seq 1 1200 | sed 's/^/old line /' > "$log"
    run_hook "$patched" </dev/null >/dev/null
    n=$(wc -l < "$log" | tr -d ' ')
    [ "$n" -le 501 ] || { echo "log not trimmed: $n lines" >&2; return 1; }
    assert_contains "$(tail -1 "$log")" "chars=" "newest line is the one just written" || return 1
    assert_not_contains "$(head -1 "$log")" "old line 1$" "oldest lines were dropped"
}
run_test "log is trimmed to the last 500 lines once it passes 1000" test_log_is_bounded

# A private checks dir the patched hook loads instead of the real one: one
# module that supplies identity, plus whatever the caller adds.
_log_checks_dir() {
    local patched="$1" checks="$TEST_TMPDIR/checks"
    mkdir -p "$checks"
    printf 'IDENTITY_MSG="HOSTNAME: testhost"\n' > "$checks/01-id.sh"
    sed -i "s|^export CONFIG_CHECK_DIR=.*|export CONFIG_CHECK_DIR=\"$checks\"|" "$patched"
    echo "$checks"
}

# The whole point of the log is to tell "never invoked" from "invoked, and the
# payload never arrived". A hook KILLED mid-run (Claude Code's hook timeout, or
# a module that hangs on the network) is the likeliest way to get "nothing at
# all" — so it must leave a record too, not only a hook that ran to the end.
test_killed_hook_leaves_start_record() {
    local patched log checks rc=0
    patched=$(_log_env)
    log="$TEST_TMPDIR/home/.claude/logs/session-start.log"
    checks=$(_log_checks_dir "$patched")
    printf 'sleep 20\n' > "$checks/50-hang.sh"

    printf '{"session_id":"sess-killed"}' | timeout 2 bash "$patched" >/dev/null 2>&1 || rc=$?
    assert_eq "124" "$rc" "fixture: the hook was killed by the timeout" || return 1
    assert_file_exists "$log" "an invoked-then-killed hook must still leave a log line" || return 1
    assert_contains "$(grep 'session=sess-killed' "$log")" " start " \
        "a START record lands before any check module runs" || return 1
    assert_not_contains "$(grep 'session=sess-killed' "$log")" " done " \
        "no DONE record: the payload was never emitted — start without done = killed/hung"
}
run_test "a hook killed mid-run leaves a START record and no DONE record" test_killed_hook_leaves_start_record

test_healthy_run_pairs_start_and_done() {
    local patched log checks start done_line pid
    patched=$(_log_env)
    log="$TEST_TMPDIR/home/.claude/logs/session-start.log"
    checks=$(_log_checks_dir "$patched")

    printf '{"session_id":"sess-pair"}' | run_hook "$patched" >/dev/null
    assert_eq "2" "$(grep -c 'session=sess-pair' "$log")" "one START and one DONE per run" || return 1
    start=$(grep 'session=sess-pair' "$log" | head -1)
    done_line=$(grep 'session=sess-pair' "$log" | tail -1)
    assert_contains "$start" " start " "first record is START" || return 1
    assert_contains "$done_line" " done " "last record is DONE" || return 1
    assert_contains "$done_line" "chars=" "DONE carries the payload size" || return 1
    pid=$(printf '%s' "$start" | grep -oE 'pid=[0-9]+')
    [ -n "$pid" ] || { echo "START record has no pid: $start" >&2; return 1; }
    assert_contains "$done_line" "$pid" "START and DONE share the pid, so runs pair up"
}
run_test "a healthy run writes one START and one DONE record with the same pid" test_healthy_run_pairs_start_and_done

test_unwritable_log_never_breaks_output() {
    local patched out ctx
    patched=$(_log_env)
    # A FILE where the logs dir should be: mkdir -p fails, the append fails.
    : > "$TEST_TMPDIR/home/.claude/logs"
    out=$(run_hook "$patched" </dev/null)
    ctx=$(extract_additional_context "$out")
    assert_contains "$ctx" "HOSTNAME:" "payload still delivered when the log cannot be written"
}
run_test "an unwritable log location never affects the hook's output" test_unwritable_log_never_breaks_output

suite_summary
