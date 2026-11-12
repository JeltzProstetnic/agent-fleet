#!/usr/bin/env bash
# Tests for global/hooks/checks/16-deployed-drift.sh — deployed vs repo hook drift detection
source "$(dirname "$0")/test-helpers.sh"

suite_header "check 16: deployed-drift.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

setup_drift_env() {
    local repo_hooks="$TEST_TMPDIR/repo/global/hooks"
    local deployed_hooks="$TEST_TMPDIR/deployed"
    mkdir -p "$repo_hooks/checks" "$deployed_hooks/checks"

    # Create sample repo hooks (source — no managed header)
    cat > "$repo_hooks/my-hook.sh" << 'EOF'
#!/usr/bin/env bash
echo "hook logic"
EOF
    cat > "$repo_hooks/checks/01-check.sh" << 'EOF'
#!/usr/bin/env bash
echo "check logic"
EOF

    echo "$repo_hooks|$deployed_hooks"
}

run_check() {
    local repo_hooks="$1" deployed_hooks="$2"
    WARNINGS=""
    CONFIG_REPO="$TEST_TMPDIR/repo"
    _DEPLOYED_HOOKS_DIR="$deployed_hooks"
    source "$REPO_ROOT/global/hooks/checks/16-deployed-drift.sh"
    echo "$WARNINGS"
}

# ── Tests ────────────────────────────────────────────────────────────────────

test_no_drift_identical_files() {
    local env
    env=$(setup_drift_env)
    local repo_hooks="${env%%|*}" deployed_hooks="${env#*|}"

    # Deploy identical copies
    cp "$repo_hooks/my-hook.sh" "$deployed_hooks/my-hook.sh"
    cp "$repo_hooks/checks/01-check.sh" "$deployed_hooks/checks/01-check.sh"

    local output
    output=$(run_check "$repo_hooks" "$deployed_hooks")
    assert_eq "" "$output" "identical files should produce no warnings"
}
run_test "no drift when files are identical" test_no_drift_identical_files

test_no_drift_with_managed_header() {
    local env
    env=$(setup_drift_env)
    local repo_hooks="${env%%|*}" deployed_hooks="${env#*|}"

    # Deploy with managed header (what deploy_hooks() does)
    {
        head -1 "$repo_hooks/my-hook.sh"
        echo "# MANAGED — DO NOT EDIT. Source: ~/cfg-agent-fleet/global/hooks/my-hook.sh"
        tail -n +2 "$repo_hooks/my-hook.sh"
    } > "$deployed_hooks/my-hook.sh"

    {
        head -1 "$repo_hooks/checks/01-check.sh"
        echo "# MANAGED — DO NOT EDIT. Source: ~/cfg-agent-fleet/global/hooks/checks/01-check.sh"
        tail -n +2 "$repo_hooks/checks/01-check.sh"
    } > "$deployed_hooks/checks/01-check.sh"

    local output
    output=$(run_check "$repo_hooks" "$deployed_hooks")
    assert_eq "" "$output" "managed header should be stripped before comparison (CFG-299)"
}
run_test "no false positive drift from managed headers (CFG-299)" test_no_drift_with_managed_header

test_real_drift_detected() {
    local env
    env=$(setup_drift_env)
    local repo_hooks="${env%%|*}" deployed_hooks="${env#*|}"

    # Deploy with managed header + actual content change
    {
        head -1 "$repo_hooks/my-hook.sh"
        echo "# MANAGED — DO NOT EDIT. Source: ~/cfg-agent-fleet/global/hooks/my-hook.sh"
        echo "echo 'OLD logic'"
    } > "$deployed_hooks/my-hook.sh"

    cp "$repo_hooks/checks/01-check.sh" "$deployed_hooks/checks/01-check.sh"

    local output
    output=$(run_check "$repo_hooks" "$deployed_hooks")
    assert_contains "$output" "my-hook.sh" "real content change should be detected"
    assert_not_contains "$output" "01-check.sh" "unchanged check should not appear"
}
run_test "real drift is still detected" test_real_drift_detected

test_checks_subdir_drift() {
    local env
    env=$(setup_drift_env)
    local repo_hooks="${env%%|*}" deployed_hooks="${env#*|}"

    cp "$repo_hooks/my-hook.sh" "$deployed_hooks/my-hook.sh"
    # Modify the check
    echo "echo 'different'" > "$deployed_hooks/checks/01-check.sh"

    local output
    output=$(run_check "$repo_hooks" "$deployed_hooks")
    assert_contains "$output" "checks/01-check.sh" "checks/ drift should be detected"
}
run_test "checks subdirectory drift detected" test_checks_subdir_drift

# ── CFG-977: drift while another live session holds the config repo ─────────
# The difference is then that session's in-progress work (it deploys at its own
# shutdown), and "run sync.sh deploy" would put its half-edited tree live.

# Make the drift fixture's repo a git repo whose HEAD session-lock.sh answers <rc>.
_held_repo() {   # <rc> [lock]
    local repo="$TEST_TMPDIR/repo"
    mkdir -p "$repo/setup/scripts" "$repo/.claude"
    cat > "$repo/setup/scripts/session-lock.sh" <<EOF
_read_lock() { _LOCK_MACHINE=m; _LOCK_PID=4242; return 0; }
check_lock() { echo called >> "$TEST_TMPDIR/check_lock.calls"; return $1; }
EOF
    git -C "$repo" init -q -b main
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "repo at HEAD"
    [[ "${2:-}" == lock ]] && echo '{"machine":"m","pid":4242}' > "$repo/.claude/.session-lock"
    return 0
}

_drifted_env() {   # prints repo_hooks|deployed_hooks with my-hook.sh drifted
    local env repo_hooks deployed_hooks
    env=$(setup_drift_env); repo_hooks="${env%%|*}"; deployed_hooks="${env#*|}"
    echo "echo 'OLD logic'" > "$deployed_hooks/my-hook.sh"
    cp "$repo_hooks/checks/01-check.sh" "$deployed_hooks/checks/01-check.sh"
    echo "$env"
}

test_held_drift_is_not_a_warning() {
    local env out rc log="$HOME/.claude/logs/template-push-deferred.log"
    for rc in 2 3; do
        rm -rf "$TEST_TMPDIR/repo" "$TEST_TMPDIR/deployed" "$log"
        env=$(_drifted_env); _held_repo "$rc"
        out=$(PROJECT_DIR="$TEST_TMPDIR/gamma" run_check "${env%%|*}" "${env#*|}")
        echo "    measured check_lock=$rc: warnings='$out' audit='$(cat "$log" 2>/dev/null)'"
        assert_eq "" "$out" "held (check_lock $rc) ⇒ no DEPLOYED_DRIFT warning" || return 1
        assert_file_contains "$log" "DEPLOYED_DRIFT_DEFERRED: config repo held by another live session — 1 hook file(s) differ" "one audit line instead" || return 1
        assert_file_contains "$log" "my-hook.sh (SessionStart of gamma)" "naming the files and the starting project" || return 1
    done
}
run_test "CFG-977: held config repo ⇒ drift dropped to one audit line" test_held_drift_is_not_a_warning

test_owner_or_free_drift_keeps_the_advice() {
    local env out rc
    for rc in 0 1; do
        rm -rf "$TEST_TMPDIR/repo" "$TEST_TMPDIR/deployed"
        env=$(_drifted_env); _held_repo "$rc"
        out=$(run_check "${env%%|*}" "${env#*|}")
        echo "    measured check_lock=$rc: $out"
        assert_contains "$out" "DEPLOYED_DRIFT: 1 hook file(s) differ" "free (0) or our own (1) ⇒ the warning stays" || return 1
        assert_contains "$out" "Run 'sync.sh deploy' to fix." "with its advice" || return 1
    done
    assert_file_not_exists "$HOME/.claude/logs/template-push-deferred.log" "and no audit line"
}
run_test "CFG-977: free or own config repo ⇒ DEPLOYED_DRIFT with deploy advice" test_owner_or_free_drift_keeps_the_advice

test_unknown_drift_has_no_deploy_advice() {
    local env out rc
    for rc in 4 6; do
        rm -rf "$TEST_TMPDIR/repo" "$TEST_TMPDIR/deployed"
        env=$(_drifted_env); _held_repo "$rc"
        out=$(run_check "${env%%|*}" "${env#*|}")
        echo "    measured check_lock=$rc: $out"
        assert_contains "$out" "DEPLOYED_DRIFT: 1 hook file(s) differ" "unknown lock state ⇒ the drift is still reported" || return 1
        assert_contains "$out" "lock state is unknown (check_lock=$rc)" "with the unknown state named" || return 1
        assert_not_contains "$out" "Run 'sync.sh deploy' to fix" "but never the advice to deploy" || return 1
    done
}
run_test "CFG-977: unknown lock state ⇒ drift reported without deploy advice" test_unknown_drift_has_no_deploy_advice

test_no_library_fails_closed_on_a_lock() {
    local env with without
    env=$(_drifted_env); _held_repo 0 lock
    with=$(_CFG_HELD_LIB="$TEST_TMPDIR/missing.sh" run_check "${env%%|*}" "${env#*|}")
    rm -f "$TEST_TMPDIR/repo/.claude/.session-lock"
    without=$(_CFG_HELD_LIB="$TEST_TMPDIR/missing.sh" run_check "${env%%|*}" "${env#*|}")
    echo "    measured: lock -> $with | no lock -> $without"
    assert_not_contains "$with" "Run 'sync.sh deploy' to fix" "no library + a lock ⇒ no deploy advice" || return 1
    assert_contains "$with" "lock state is unknown" "the drift is reported as unknown" || return 1
    assert_contains "$without" "Run 'sync.sh deploy' to fix." "no library + no lock ⇒ the warning as before"
}
run_test "CFG-977: lib-cfg-held.sh missing ⇒ fail closed on a lock file" test_no_library_fails_closed_on_a_lock

test_no_drift_asks_no_lock_question() {
    local env repo_hooks deployed_hooks out
    env=$(setup_drift_env); repo_hooks="${env%%|*}"; deployed_hooks="${env#*|}"
    cp "$repo_hooks/my-hook.sh" "$deployed_hooks/my-hook.sh"
    cp "$repo_hooks/checks/01-check.sh" "$deployed_hooks/checks/01-check.sh"
    _held_repo 2
    out=$(run_check "$repo_hooks" "$deployed_hooks")
    assert_eq "" "$out" "no drift ⇒ no warning" || return 1
    assert_file_not_exists "$TEST_TMPDIR/check_lock.calls" "and the lock is not even asked (every SessionStart pays nothing)"
}
run_test "CFG-977: no drift ⇒ the lock verdict is not asked" test_no_drift_asks_no_lock_question

test_probe_deletes_no_lock() {
    # The real session-lock.sh at HEAD and a crashed holder's lock: check_lock
    # would clean it; a SessionStart of another project must not (read-only).
    local env repo="$TEST_TMPDIR/repo" out
    env=$(_drifted_env)
    mkdir -p "$repo/setup/scripts" "$repo/.claude"
    cp "$REPO_ROOT/setup/scripts/session-lock.sh" "$repo/setup/scripts/session-lock.sh"
    git -C "$repo" init -q -b main; git -C "$repo" add -A; git -C "$repo" commit -q -m "repo at HEAD"
    local dead; sleep 0 & dead=$!; wait "$dead" 2>/dev/null
    printf '{"machine":"%s","pid":%s,"sessionId":"s","timestamp":"t","user":"u","ccSessionId":""}\n' "$(hostname)" "$dead" > "$repo/.claude/.session-lock"
    out=$(run_check "${env%%|*}" "${env#*|}")
    echo "    measured: $out | lock-left=$([[ -f "$repo/.claude/.session-lock" ]] && echo yes || echo no)"
    assert_contains "$out" "Run 'sync.sh deploy' to fix." "a crashed holder does not suppress the drift advice" || return 1
    assert_file_exists "$repo/.claude/.session-lock" "and the probe deletes no lock"
}
run_test "CFG-977: the drift probe is read-only (a stale lock is not deleted)" test_probe_deletes_no_lock

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
