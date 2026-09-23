#!/usr/bin/env bash
# Tests for global/hooks/pkill-guard.sh — PreToolUse hook refusing `pkill -f` / `pgrep -f`
# with a pattern that can match the very command carrying it.
#
# Why this hook exists (CFG-597 / CFG-693). `pkill -f <pattern>` matches against the FULL
# command line of every process — and the command line of the shell running the pkill
# contains the pattern, so the pattern matches its own shell. Measured 2026-09-23:
# `ssh … 'pkill -f cru181_body_over_wifi.py'` killed its own remote shell and robot
# telemetry was down ~1 min. The same defect had already been recorded 11 days earlier and
# was filed as a RULE change, parked behind Meta-Rules consent nobody ever requested. The
# knowledge that would have prevented it lives in on-demand files (fleet-capabilities.md
# §pkill) that are never in context at the moment someone types pkill — a rule cannot fire
# where it is not loaded, which is why MG ordered this shipped as a hook instead.
#
# The safe forms: a self-excluding character class — [c]ru181 matches the string "cru181"
# but the literal text "[c]ru181" in the shell's own argv does not match the regex — or
# -x, which matches exactly rather than as a substring.
#
# NOTE: one decisive assert per test — this harness lets only the FINAL assert decide.
source "$(dirname "$0")/test-helpers.sh"

HOOK="$REPO_ROOT/global/hooks/pkill-guard.sh"

suite_header "pkill-guard.sh (PreToolUse self-match guard)"

_rc() {
    local input rc=0
    input=$(jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}')
    HOOK_STDERR=$(printf '%s' "$input" | bash "$HOOK" 2>&1) || rc=$?
    printf '%s' "$rc"
}

# ── MUST BLOCK ────────────────────────────────────────────────────────────────

t_blocks_the_exact_incident() {
    assert_eq "2" "$(_rc 'pkill -f cru181_body_over_wifi.py')" \
        "the exact pattern that killed its own shell must be refused"
}
run_test "blocks the exact command from the 2026-09-23 incident" t_blocks_the_exact_incident

t_blocks_inside_ssh() {
    assert_eq "2" "$(_rc "ssh nuc 'pkill -f cru181_body_over_wifi.py'")" \
        "the pattern travels inside the ssh payload and still self-matches there"
}
run_test "blocks it inside an ssh '...' payload" t_blocks_inside_ssh

t_blocks_inside_bash_c() {
    assert_eq "2" "$(_rc 'bash -c "pkill -f myworker.py"')" "bash -c payload must be refused"
}
run_test "blocks it inside a bash -c payload" t_blocks_inside_bash_c

t_blocks_signal_flag() {
    assert_eq "2" "$(_rc 'pkill -9 -f myworker.py')" "a signal flag must not evade the guard"
}
run_test "blocks pkill -9 -f" t_blocks_signal_flag

t_blocks_combined_flags() {
    assert_eq "2" "$(_rc 'pkill -9f myworker.py')" "combined flag cluster must not evade the guard"
}
run_test "blocks the combined -9f cluster" t_blocks_combined_flags

t_blocks_pgrep_wait_loop() {
    # The other half of CFG-597: a wait loop that polls for its own pattern never sees the
    # job finish, because the loop's own shell keeps matching.
    assert_eq "2" "$(_rc 'until ! pgrep -f myworker.py; do sleep 2; done')" \
        "a pgrep -f wait loop self-matches and must be refused"
}
run_test "blocks a pgrep -f wait loop" t_blocks_pgrep_wait_loop

t_blocks_full_option() {
    assert_eq "2" "$(_rc 'pkill --full myworker.py')" "the long option must be covered too"
}
run_test "blocks pkill --full" t_blocks_full_option

# ── MUST ALLOW ────────────────────────────────────────────────────────────────

t_allows_character_class() {
    assert_eq "0" "$(_rc "pkill -f '[c]ru181_body_over_wifi.py'")" \
        "the self-excluding character class is the documented safe form"
}
run_test "allows the [c]haracter-class self-exclusion" t_allows_character_class

t_allows_character_class_pgrep() {
    assert_eq "0" "$(_rc "until ! pgrep -f '[m]yworker.py'; do sleep 2; done")" \
        "a self-excluding wait loop is correct and must not be refused"
}
run_test "allows a self-excluding pgrep wait loop" t_allows_character_class_pgrep

t_allows_dash_x() {
    assert_eq "0" "$(_rc 'pkill -x -f myworker.py')" "-x matches exactly, not as a substring"
}
run_test "allows -x" t_allows_dash_x

t_allows_no_f_flag() {
    assert_eq "0" "$(_rc 'pkill node')" \
        "without -f the match is against the process NAME, which cannot carry the pattern"
}
run_test "allows pkill without -f" t_allows_no_f_flag

t_allows_pgrep_no_f() {
    assert_eq "0" "$(_rc 'pgrep -x claude')" "process-name matching is not the defect"
}
run_test "allows pgrep -x without -f" t_allows_pgrep_no_f

t_allows_grep_for_the_string() {
    assert_eq "0" "$(_rc "grep -rn 'pkill -f' docs/")" \
        "searching for the string is not running it"
}
run_test "allows grepping for the literal string" t_allows_grep_for_the_string

t_allows_help() {
    assert_eq "0" "$(_rc 'pkill --help')" "--help kills nothing"
}
run_test "allows pkill --help" t_allows_help

t_allows_unrelated_command() {
    assert_eq "0" "$(_rc 'ls -la /tmp')" "an unrelated command must pass untouched"
}
run_test "allows an unrelated command" t_allows_unrelated_command

t_ignores_non_bash_tool() {
    local input rc=0
    input=$(jq -n '{tool_name: "Read", tool_input: {file_path: "/tmp/pkill -f x"}}')
    printf '%s' "$input" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "a non-Bash tool must never be inspected"
}
run_test "ignores non-Bash tools" t_ignores_non_bash_tool

# ── The refusal must teach the safe form ──────────────────────────────────────

t_refusal_names_the_safe_form() {
    _rc 'pkill -f myworker.py' >/dev/null
    echo "    measured refusal: $(printf '%s' "$HOOK_STDERR" | grep -c '\[m\]yworker' || true) rewrite(s) of the caller's own pattern"
    assert_contains "$HOOK_STDERR" "[m]yworker.py" \
        "the refusal must show the caller THEIR pattern rewritten, not a generic example"
}
run_test "refusal rewrites the caller's own pattern into the safe form" t_refusal_names_the_safe_form

suite_summary
