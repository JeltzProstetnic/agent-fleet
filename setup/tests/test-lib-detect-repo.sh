#!/usr/bin/env bash
# Tests for lib-detect-repo.sh — canonical config repo detection
source "$(dirname "$0")/test-helpers.sh"

suite_header "lib-detect-repo.sh: config repo detection"

LIB_FILE="$REPO_ROOT/global/hooks/lib-detect-repo.sh"

# ── 1. Library file exists ────────────────────────────────────────────────────

test_lib_exists() {
    assert_file_exists "$LIB_FILE"
}
run_test "lib-detect-repo.sh exists" test_lib_exists

# ── 2. Guard prevents double-loading ─────────────────────────────────────────

test_guard_pattern() {
    (
        source "$LIB_FILE"
        [[ "$_LIB_DETECT_REPO_LOADED" == "true" ]] || { echo "Guard var not set" >&2; exit 1; }
    )
}
run_test "Guard pattern sets _LIB_DETECT_REPO_LOADED" test_guard_pattern

# ── 3. CONFIG_REPO env var wins when valid ────────────────────────────────────

test_env_var_wins() {
    local fake_repo="$TEST_TMPDIR/my-config"
    mkdir -p "$fake_repo"
    touch "$fake_repo/sync.sh"
    local result
    result=$(CONFIG_REPO="$fake_repo" bash -c 'source "'"$LIB_FILE"'"; _detect_config_repo')
    [[ "$result" == "$fake_repo" ]] || {
        printf "  Expected: %s\n  Got: %s\n" "$fake_repo" "$result" >&2
        return 1
    }
}
run_test "CONFIG_REPO env var wins when valid" test_env_var_wins

# ── 4. Invalid CONFIG_REPO falls through ──────────────────────────────────────

test_env_var_invalid_falls_through() {
    local fake_repo="$TEST_TMPDIR/cfg-agent-fleet"
    mkdir -p "$fake_repo"
    touch "$fake_repo/sync.sh"
    touch "$fake_repo/.config-repo"
    local result
    result=$(HOME="$TEST_TMPDIR" CONFIG_REPO="/nonexistent" bash -c 'source "'"$LIB_FILE"'"; _detect_config_repo')
    [[ "$result" == "$fake_repo" ]] || {
        printf "  Expected: %s\n  Got: %s\n" "$fake_repo" "$result" >&2
        return 1
    }
}
run_test "Invalid CONFIG_REPO falls through to detection" test_env_var_invalid_falls_through

# ── 5. .config-repo marker is preferred ───────────────────────────────────────

test_config_marker_preferred() {
    mkdir -p "$TEST_TMPDIR/cfg-agent-fleet" "$TEST_TMPDIR/agent-fleet"
    touch "$TEST_TMPDIR/cfg-agent-fleet/sync.sh" "$TEST_TMPDIR/cfg-agent-fleet/.config-repo"
    touch "$TEST_TMPDIR/agent-fleet/sync.sh"
    local result
    result=$(HOME="$TEST_TMPDIR" CONFIG_REPO="" bash -c 'source "'"$LIB_FILE"'"; _detect_config_repo')
    [[ "$result" == "$TEST_TMPDIR/cfg-agent-fleet" ]] || {
        printf "  Expected cfg-agent-fleet, got: %s\n" "$result" >&2
        return 1
    }
}
run_test ".config-repo marker is preferred" test_config_marker_preferred

# ── 6. .template-repo is rejected ────────────────────────────────────────────

test_template_marker_rejected() {
    mkdir -p "$TEST_TMPDIR/cfg-agent-fleet" "$TEST_TMPDIR/agent-fleet"
    touch "$TEST_TMPDIR/cfg-agent-fleet/sync.sh" "$TEST_TMPDIR/cfg-agent-fleet/.config-repo"
    touch "$TEST_TMPDIR/agent-fleet/sync.sh" "$TEST_TMPDIR/agent-fleet/.template-repo"
    local result
    result=$(HOME="$TEST_TMPDIR" CONFIG_REPO="" bash -c 'source "'"$LIB_FILE"'"; _detect_config_repo')
    [[ "$result" == "$TEST_TMPDIR/cfg-agent-fleet" ]] || {
        printf "  Expected cfg-agent-fleet (not template), got: %s\n" "$result" >&2
        return 1
    }
}
run_test ".template-repo repo is rejected" test_template_marker_rejected

# ── 7. Developer scenario: both repos, correct selection ─────────────────────

test_developer_both_repos() {
    mkdir -p "$TEST_TMPDIR/cfg-agent-fleet" "$TEST_TMPDIR/agent-fleet"
    touch "$TEST_TMPDIR/cfg-agent-fleet/sync.sh" "$TEST_TMPDIR/cfg-agent-fleet/.config-repo"
    touch "$TEST_TMPDIR/agent-fleet/sync.sh" "$TEST_TMPDIR/agent-fleet/.template-repo"
    local result
    result=$(HOME="$TEST_TMPDIR" CONFIG_REPO="" bash -c 'source "'"$LIB_FILE"'"; _detect_config_repo')
    [[ "$result" == "$TEST_TMPDIR/cfg-agent-fleet" ]]
}
run_test "Developer: selects cfg-agent-fleet over agent-fleet" test_developer_both_repos

# ── 8. User scenario: only agent-fleet, no markers ───────────────────────────

test_user_single_repo() {
    mkdir -p "$TEST_TMPDIR/agent-fleet"
    touch "$TEST_TMPDIR/agent-fleet/sync.sh"
    # No .template-repo, no .config-repo — a user who just cloned
    local result
    result=$(HOME="$TEST_TMPDIR" CONFIG_REPO="" bash -c 'source "'"$LIB_FILE"'"; _detect_config_repo')
    [[ "$result" == "$TEST_TMPDIR/agent-fleet" ]] || {
        printf "  Expected agent-fleet, got: %s\n" "$result" >&2
        return 1
    }
}
run_test "User: selects agent-fleet when it's the only repo" test_user_single_repo

# ── 9. Fallback when no repos found ──────────────────────────────────────────

test_fallback_no_repos() {
    # Empty HOME with no repos
    local result
    result=$(HOME="$TEST_TMPDIR" CONFIG_REPO="" bash -c 'source "'"$LIB_FILE"'"; _detect_config_repo')
    # Should return the fallback path (HOME/cfg-agent-fleet)
    [[ "$result" == "$TEST_TMPDIR/cfg-agent-fleet" ]] || {
        printf "  Expected fallback, got: %s\n" "$result" >&2
        return 1
    }
}
run_test "Fallback to HOME/cfg-agent-fleet when no repos" test_fallback_no_repos

# ── 10. Both hooks resolve to same path ───────────────────────────────────────

test_hooks_agree() {
    # Both hooks should use the same shared lib and resolve identically
    local check_hook="$REPO_ROOT/global/hooks/config-check.sh"
    local sync_hook="$REPO_ROOT/global/hooks/config-auto-sync.sh"
    # Verify both source lib-detect-repo.sh
    grep -q 'lib-detect-repo.sh' "$check_hook" 2>/dev/null || {
        printf "  config-check.sh does not source lib-detect-repo.sh\n" >&2
        return 1
    }
    grep -q 'lib-detect-repo.sh' "$sync_hook" 2>/dev/null || {
        printf "  config-auto-sync.sh does not source lib-detect-repo.sh\n" >&2
        return 1
    }
}
run_test "Both hooks source lib-detect-repo.sh" test_hooks_agree

# ── 11. Function is under 50 lines ───────────────────────────────────────────

test_function_size() {
    local lines
    lines=$(sed -n '/_detect_config_repo()/,/^}/p' "$LIB_FILE" | wc -l)
    [[ "$lines" -le 50 ]] || {
        printf "  Function is %d lines (max 50)\n" "$lines" >&2
        return 1
    }
}
run_test "Function is under 50 lines" test_function_size

suite_summary
