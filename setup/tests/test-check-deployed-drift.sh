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

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
