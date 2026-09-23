#!/usr/bin/env bash
# Tests for 12-init-guard.sh — detects CLAUDE.md nuked by /init
source "$(dirname "$0")/test-helpers.sh"

suite_header "Init Guard Check (12-init-guard.sh)"

CHECK="$REPO_ROOT/global/hooks/checks/12-init-guard.sh"

# Helper: set up a mock project environment and run the check
run_check() {
    local project_dir="$1"
    local claude_md_content="$2"
    local registry_content="${3:-}"

    # Set up shared variables that config-check.sh normally provides
    export PROJECT_DIR="$project_dir"
    export CONFIG_REPO="$TEST_TMPDIR/config-repo"
    WARNINGS=""

    mkdir -p "$project_dir"
    mkdir -p "$CONFIG_REPO"

    # Create CLAUDE.md if content provided
    if [ -n "$claude_md_content" ]; then
        echo "$claude_md_content" > "$project_dir/CLAUDE.md"
    fi

    # Create registry if content provided
    if [ -n "$registry_content" ]; then
        echo "$registry_content" > "$CONFIG_REPO/registry.md"
    fi

    source "$CHECK"
    echo "$WARNINGS"
}

# ── Tests ────────────────────────────────────────────────────────────────────

# Test 1: Fleet-managed CLAUDE.md is silent
test_fleet_managed_silent() {
    local output
    output=$(run_check "$TEST_TMPDIR/myproject" \
        "<!-- agent-fleet-managed: DO NOT run /init -->"$'\n'"# My Project" \
        "| myproject | code |")
    assert_eq "" "$output" "fleet-managed CLAUDE.md should not warn"
}
run_test "fleet-managed CLAUDE.md is silent" test_fleet_managed_silent

# Test 2: Missing marker in registered project triggers warning
test_missing_marker_warns() {
    local output
    output=$(run_check "$TEST_TMPDIR/myproject" \
        "# My Project"$'\n'"Generic init content" \
        "| myproject | code |")
    assert_contains "$output" "WARN"
    assert_contains "$output" "/init"
}
run_test "missing marker in registered project triggers warning" test_missing_marker_warns

# Test 3: Missing marker in unregistered project is silent
test_unregistered_silent() {
    local output
    output=$(run_check "$TEST_TMPDIR/randomproject" \
        "# Random Project" \
        "| otherproject | code |")
    assert_eq "" "$output" "unregistered project should not warn"
}
run_test "unregistered project without marker is silent" test_unregistered_silent

# Test 4: No CLAUDE.md at all is silent
test_no_claude_md_silent() {
    local output
    output=$(run_check "$TEST_TMPDIR/emptyproject" "" "| emptyproject | code |")
    assert_eq "" "$output" "no CLAUDE.md should not warn"
}
run_test "no CLAUDE.md is silent" test_no_claude_md_silent

# Test 5: Marker anywhere in file is detected
test_marker_in_body() {
    local output
    output=$(run_check "$TEST_TMPDIR/myproject" \
        "# My Project"$'\n'"<!-- agent-fleet-managed -->" \
        "| myproject | code |")
    assert_eq "" "$output" "marker in body should be detected"
}
run_test "marker anywhere in file is detected" test_marker_in_body

# Test 6: No registry file is silent (no config repo)
test_no_registry_silent() {
    local project_dir="$TEST_TMPDIR/myproject"
    mkdir -p "$project_dir"
    echo "# Generic" > "$project_dir/CLAUDE.md"

    export PROJECT_DIR="$project_dir"
    export CONFIG_REPO="$TEST_TMPDIR/no-config-repo"
    WARNINGS=""

    source "$CHECK"
    assert_eq "" "$WARNINGS" "missing registry should not warn"
}
run_test "missing registry is silent" test_no_registry_silent

# Summary
echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed out of $TESTS_RUN"
[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
