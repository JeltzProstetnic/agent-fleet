#!/usr/bin/env bash
# Tests for CFG-143: fleet version check module (17-fleet-updates.sh)
# Verifies: newer upstream → warning, same version → silent, missing version → skip,
#           no upstream remote → skip, corporate context detection, date gating.

source "$(dirname "$0")/test-helpers.sh"

suite_header "Fleet Version Check (CFG-143)"

CHECK_17="$REPO_ROOT/global/hooks/checks/17-fleet-updates.sh"

# ── Helper: set up minimal env for the check module ──────────────────────────

setup_check_env() {
    export CONFIG_REPO="$TEST_TMPDIR/config-repo"
    export PROJECT_DIR="$TEST_TMPDIR/project"
    WARNINGS=""
    INBOX_MSG=""

    mkdir -p "$CONFIG_REPO/.git"
    mkdir -p "$PROJECT_DIR"

    # Clear any date-gate marker from previous test
    rm -f /tmp/.fleet-update-check-* 2>/dev/null || true
}

# Create a project git repo with an upstream remote pointing to a bare repo.
# Writes .agent-fleet-version into both local and upstream.
# Usage: create_upstream_env <local_version> <upstream_version>
create_upstream_env() {
    local local_ver="${1:-0.2}"
    local upstream_ver="${2:-0.3}"

    local bare="$TEST_TMPDIR/upstream.git"
    local template="$TEST_TMPDIR/template"

    # Build template repo with upstream version
    create_git_repo "$template"
    echo "$upstream_ver" > "$template/.agent-fleet-version"
    git -C "$template" add -A
    git -C "$template" commit -m "upstream v$upstream_ver" >/dev/null 2>&1

    # Push to bare
    create_bare_repo "$bare"
    git -C "$template" remote add origin "$bare"
    git -C "$template" push origin main >/dev/null 2>&1

    # Set up project dir as a git repo with upstream remote
    create_git_repo "$PROJECT_DIR"
    echo "$local_ver" > "$PROJECT_DIR/.agent-fleet-version"
    git -C "$PROJECT_DIR" add -A
    git -C "$PROJECT_DIR" commit -m "local v$local_ver" >/dev/null 2>&1
    git -C "$PROJECT_DIR" remote add upstream "$bare"
    git -C "$PROJECT_DIR" fetch upstream >/dev/null 2>&1
}

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 1: Core version detection
# ══════════════════════════════════════════════════════════════════════════════

test_newer_upstream_warns() {
    setup_check_env
    create_upstream_env "0.2" "0.3"
    # Set channel to 'all' so minor version bumps are detected
    echo "all" > "$PROJECT_DIR/.agent-fleet-channel"
    source "$CHECK_17"
    assert_contains "$WARNINGS" "FLEET_UPDATE" \
        "newer upstream should produce FLEET_UPDATE warning"
    assert_contains "$WARNINGS" "0.2" "warning should mention local version"
    assert_contains "$WARNINGS" "0.3" "warning should mention upstream version"
    assert_contains "$WARNINGS" "upgrade.sh" "warning should mention upgrade command"
}
run_test "newer upstream version produces FLEET_UPDATE warning" test_newer_upstream_warns

test_same_version_silent() {
    setup_check_env
    create_upstream_env "0.2" "0.2"
    source "$CHECK_17"
    assert_not_contains "$WARNINGS" "FLEET_UPDATE" \
        "same version should not produce FLEET_UPDATE warning"
}
run_test "same version produces no warning" test_same_version_silent

test_older_upstream_silent() {
    setup_check_env
    create_upstream_env "0.3" "0.2"
    source "$CHECK_17"
    assert_not_contains "$WARNINGS" "FLEET_UPDATE" \
        "older upstream should not produce FLEET_UPDATE warning"
}
run_test "older upstream version produces no warning" test_older_upstream_silent

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 2: Graceful degradation
# ══════════════════════════════════════════════════════════════════════════════

test_missing_version_file_skips() {
    setup_check_env
    # PROJECT_DIR exists but has no .agent-fleet-version and no git
    mkdir -p "$PROJECT_DIR"
    source "$CHECK_17"
    assert_not_contains "$WARNINGS" "FLEET_UPDATE" \
        "missing .agent-fleet-version should skip gracefully"
}
run_test "missing .agent-fleet-version skips gracefully" test_missing_version_file_skips

test_no_upstream_remote_skips() {
    setup_check_env
    create_git_repo "$PROJECT_DIR"
    echo "0.2" > "$PROJECT_DIR/.agent-fleet-version"
    git -C "$PROJECT_DIR" add -A
    git -C "$PROJECT_DIR" commit -m "v0.2" >/dev/null 2>&1
    # No upstream remote added
    source "$CHECK_17"
    assert_not_contains "$WARNINGS" "FLEET_UPDATE" \
        "no upstream remote should skip gracefully"
}
run_test "no upstream remote skips gracefully" test_no_upstream_remote_skips

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 3: Corporate context detection
# ══════════════════════════════════════════════════════════════════════════════

test_corporate_origin_still_warns() {
    setup_check_env
    create_upstream_env "0.2" "0.3"
    echo "all" > "$PROJECT_DIR/.agent-fleet-channel"
    # Override origin to a corporate-org URL — still triggers version check
    git -C "$PROJECT_DIR" remote add origin "https://github.com/example-org/agent-fleet.git" 2>/dev/null || \
        git -C "$PROJECT_DIR" remote set-url origin "https://github.com/example-org/agent-fleet.git"
    source "$CHECK_17"
    assert_contains "$WARNINGS" "FLEET_UPDATE" \
        "corporate origin should still produce FLEET_UPDATE warning"
}
run_test "corporate origin still triggers update warning" test_corporate_origin_still_warns

test_non_corporate_no_corporate_label() {
    setup_check_env
    create_upstream_env "0.2" "0.3"
    echo "all" > "$PROJECT_DIR/.agent-fleet-channel"
    # Origin points to personal repo (default from create_upstream_env has no origin)
    git -C "$PROJECT_DIR" remote add origin "https://github.com/example-user/my-fleet.git" 2>/dev/null || true
    source "$CHECK_17"
    assert_contains "$WARNINGS" "FLEET_UPDATE" "should still warn"
    assert_not_contains "$WARNINGS" "corporate" \
        "non-corporate origin should not mention corporate"
}
run_test "non-corporate origin omits corporate label" test_non_corporate_no_corporate_label

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 4: Date gating
# ══════════════════════════════════════════════════════════════════════════════

test_date_gate_prevents_rerun() {
    setup_check_env
    create_upstream_env "0.2" "0.3"
    echo "all" > "$PROJECT_DIR/.agent-fleet-channel"

    # First run should produce warning
    source "$CHECK_17"
    assert_contains "$WARNINGS" "FLEET_UPDATE" "first run should warn"

    # Reset WARNINGS and run again — date gate should prevent it
    WARNINGS=""
    source "$CHECK_17"
    assert_not_contains "$WARNINGS" "FLEET_UPDATE" \
        "second run same day should be gated"
}
run_test "date gate prevents redundant checks" test_date_gate_prevents_rerun

# ══════════════════════════════════════════════════════════════════════════════

suite_summary
