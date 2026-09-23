#!/usr/bin/env bash
# Tests for setup/scripts/launch-registry.sh — CFG-694.
#
# The registry exists because a session can PROVE ownership of its own descendants from the
# process tree, but not of anything a launcher detached: a tmux pane is a child of the tmux
# server, not of the session that asked for it. Those get written down at launch.
#
# The load-bearing test is the recycled pid: a bare pid list would let "the number I started"
# authorise killing whatever now holds that number.
source "$(dirname "$0")/test-helpers.sh"

LIB="$REPO_ROOT/setup/scripts/launch-registry.sh"

suite_header "launch-registry.sh (CFG-694 process ownership)"

_reg() { CC_LAUNCH_REGISTRY="$TEST_TMPDIR/reg.tsv" bash "$LIB" "$@"; }

t_add_and_has() {
    sleep 60 & local pid=$!
    _reg add "$pid" "test-job" "sleep 60"
    local rc=0; _reg has "$pid" || rc=$?
    kill "$pid" 2>/dev/null
    echo "    measured: has(registered live pid) rc=$rc"
    assert_eq "0" "$rc" "a registered, still-running process must be recognised"
}
run_test "recognises a process it registered" t_add_and_has

t_unregistered_is_not_ours() {
    sleep 60 & local pid=$!
    local rc=0; _reg has "$pid" || rc=$?
    kill "$pid" 2>/dev/null
    echo "    measured: has(unregistered live pid) rc=$rc"
    assert_neq "0" "$rc" "a process nobody registered must not be claimed"
}
run_test "does not claim an unregistered process" t_unregistered_is_not_ours

t_recycled_pid_is_refused() {
    # Register a pid, let it die, then forge an entry carrying that pid with a DIFFERENT
    # start time — exactly what a recycled pid looks like. Same number, other process.
    sleep 0.1 & local pid=$!
    wait "$pid" 2>/dev/null
    mkdir -p "$(dirname "$TEST_TMPDIR/reg.tsv")"
    # A live pid (this shell) recorded under a start time that is not its own.
    printf '%s\t%s\t%s\t%s\n' "$$" "999999999" "stale-entry" "sleep 60" > "$TEST_TMPDIR/reg.tsv"
    local rc=0; _reg has "$$" || rc=$?
    echo "    measured: has(pid present but start time differs) rc=$rc"
    assert_neq "0" "$rc" "a recycled pid must NOT inherit the original's permission"
}
run_test "refuses a recycled pid (same number, different process)" t_recycled_pid_is_refused

t_refuses_dead_pid_registration() {
    sleep 0.1 & local pid=$!
    wait "$pid" 2>/dev/null
    local rc=0; _reg add "$pid" "already-dead" || rc=$?
    echo "    measured: add(dead pid) rc=$rc"
    assert_neq "0" "$rc" "registering an already-dead pid would poison the registry"
}
run_test "refuses to register an already-dead pid" t_refuses_dead_pid_registration

t_list_shows_live_only() {
    sleep 60 & local live=$!
    _reg add "$live" "live-job" "sleep 60"
    printf '%s\t%s\t%s\t%s\n' "999999" "123" "dead-job" "gone" >> "$TEST_TMPDIR/reg.tsv"
    local out; out=$(_reg list)
    kill "$live" 2>/dev/null
    echo "    measured list: $(printf '%s' "$out" | tr '\n' ';' | cut -c1-90)"
    assert_contains "$out" "live-job" "a live entry must be listed" || return 1
    assert_not_contains "$out" "dead-job" "a dead entry is noise in a refusal message"
}
run_test "lists live entries only" t_list_shows_live_only

t_prune_drops_dead() {
    printf '%s\t%s\t%s\t%s\n' "999999" "123" "dead-job" "gone" > "$TEST_TMPDIR/reg.tsv"
    _reg prune
    echo "    measured: $(wc -l < "$TEST_TMPDIR/reg.tsv") line(s) after prune"
    assert_eq "0" "$(wc -l < "$TEST_TMPDIR/reg.tsv")" "prune must drop entries whose process is gone"
}
run_test "prune drops dead entries" t_prune_drops_dead

t_rejects_non_numeric() {
    local rc=0; _reg has "notapid" || rc=$?
    assert_neq "0" "$rc" "a non-numeric target must never be treated as registered"
}
run_test "rejects a non-numeric pid" t_rejects_non_numeric

suite_summary
