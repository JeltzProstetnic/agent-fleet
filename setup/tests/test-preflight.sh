#!/usr/bin/env bash
# Tests for setup/preflight.sh — system requirement checks
source "$(dirname "$0")/test-helpers.sh"

PREFLIGHT_SCRIPT="$REPO_ROOT/setup/preflight.sh"

suite_header "preflight.sh (system requirement checks)"

# ── Helpers ──────────────────────────────────────────────────────────────────

create_test_env() {
    local home="$TEST_TMPDIR/home"
    mkdir -p "$home/.local/bin"
    echo "$home"
}

# Create a minimal PATH with only essential system tools plus any extras
# This gives us control over which commands are "found"
build_restricted_env() {
    local home="$1"
    shift
    local extra_bins=("$@")

    local fake_bin="$TEST_TMPDIR/bin"
    mkdir -p "$fake_bin"

    # Always provide bash and basic coreutils (needed for the script to run)
    for cmd in bash cat df mkdir test printf echo tr cut head tail wc grep sed awk sort uname dirname readlink; do
        local real_path
        real_path=$(command -v "$cmd" 2>/dev/null || true)
        if [[ -n "$real_path" ]]; then
            ln -sf "$real_path" "$fake_bin/$cmd"
        fi
    done

    # Add requested extra commands
    for cmd in "${extra_bins[@]}"; do
        local real_path
        real_path=$(command -v "$cmd" 2>/dev/null || true)
        if [[ -n "$real_path" ]]; then
            ln -sf "$real_path" "$fake_bin/$cmd"
        fi
    done

    echo "$fake_bin"
}

# ── 1. All checks pass with full tooling ─────────────────────────────────────

test_all_pass_with_full_tooling() {
    local home
    home=$(create_test_env)

    local output
    # Run with current PATH (has everything installed on dev machine)
    # Use --skip-network to avoid flaky CI network checks
    output=$(HOME="$home" bash "$PREFLIGHT_SCRIPT" --skip-network 2>&1) || true

    assert_contains "$output" "[PASS]" "should have at least one PASS"
    assert_not_contains "$output" "[FAIL]" "should have no failures on a dev machine"
}
run_test "all checks pass on a fully-equipped machine" test_all_pass_with_full_tooling

# ── 2. Missing required command produces FAIL ────────────────────────────────

test_missing_git_fails() {
    local home
    home=$(create_test_env)

    local fake_bin
    # Provide npm, node, python3, curl, jq — but NOT git
    fake_bin=$(build_restricted_env "$home" npm node python3 curl jq)

    local output exit_code=0
    output=$(HOME="$home" PATH="$fake_bin" bash "$PREFLIGHT_SCRIPT" --skip-network 2>&1) || exit_code=$?

    assert_contains "$output" "[FAIL]" "should report FAIL for missing git"
    assert_contains "$output" "git" "should mention git"
    assert_eq "1" "$exit_code" "should exit 1 when required command missing"
}
run_test "missing required command (git) produces FAIL and exit 1" test_missing_git_fails

# ── 3. Missing recommended command produces WARN ─────────────────────────────

test_missing_jq_warns() {
    local home
    home=$(create_test_env)

    local fake_bin
    # Provide required commands but NOT jq (which is recommended, not required)
    fake_bin=$(build_restricted_env "$home" git npm node python3 curl)

    local output exit_code=0
    output=$(HOME="$home" PATH="$fake_bin" bash "$PREFLIGHT_SCRIPT" --skip-network 2>&1) || exit_code=$?

    assert_contains "$output" "[WARN]" "should report WARN for missing jq"
    assert_contains "$output" "jq" "should mention jq"
    # Missing recommended tools should not cause failure
    assert_eq "0" "$exit_code" "should exit 0 when only recommended command missing"
}
run_test "missing recommended command (jq) produces WARN, still passes" test_missing_jq_warns

# ── 4. HOME writable check ──────────────────────────────────────────────────

test_writable_home() {
    local home
    home=$(create_test_env)

    local output
    output=$(HOME="$home" bash "$PREFLIGHT_SCRIPT" --skip-network 2>&1) || true

    assert_contains "$output" "[PASS]" "should pass writable HOME"
}
run_test "writable HOME directory passes" test_writable_home

# ── 5. Disk space check ─────────────────────────────────────────────────────

test_disk_space_reported() {
    local home
    home=$(create_test_env)

    local output
    output=$(HOME="$home" bash "$PREFLIGHT_SCRIPT" --skip-network 2>&1) || true

    # The disk space check should produce output about free space
    assert_contains "$output" "Disk space" "should report disk space check"
}
run_test "disk space check is reported" test_disk_space_reported

# ── 6. --skip-network flag ──────────────────────────────────────────────────

test_skip_network_flag() {
    local home
    home=$(create_test_env)

    local output
    output=$(HOME="$home" bash "$PREFLIGHT_SCRIPT" --skip-network 2>&1) || true

    assert_not_contains "$output" "github.com" "should skip network checks"
    assert_not_contains "$output" "registry.npmjs.org" "should skip npm registry check"
}
run_test "--skip-network skips connectivity checks" test_skip_network_flag

# ── 7. Sourceable — functions callable individually ──────────────────────────

test_sourceable_functions() {
    # Source the script and call check_commands directly
    local output
    output=$(bash -c "
        source '$PREFLIGHT_SCRIPT' --source-only
        # check_commands should be a defined function
        type check_commands >/dev/null 2>&1 && echo 'FUNC_EXISTS'
        type check_paths >/dev/null 2>&1 && echo 'FUNC_EXISTS'
        type check_disk_space >/dev/null 2>&1 && echo 'FUNC_EXISTS'
    " 2>&1) || true

    assert_contains "$output" "FUNC_EXISTS" "should export callable functions when sourced"
}
run_test "script is sourceable with --source-only" test_sourceable_functions

# ── 8. Creates ~/.local/bin if missing ───────────────────────────────────────

test_creates_local_bin() {
    local home="$TEST_TMPDIR/home-no-local-bin"
    mkdir -p "$home"
    # Intentionally do NOT create ~/.local/bin

    local output
    output=$(HOME="$home" bash "$PREFLIGHT_SCRIPT" --skip-network 2>&1) || true

    assert_dir_exists "$home/.local/bin" "should create ~/.local/bin if missing"
}
run_test "creates ~/.local/bin if missing" test_creates_local_bin

# ── 9. Human-readable output format ─────────────────────────────────────────

test_output_format() {
    local home
    home=$(create_test_env)

    local output
    output=$(HOME="$home" bash "$PREFLIGHT_SCRIPT" --skip-network 2>&1) || true

    # Should have section headers and status markers
    assert_contains "$output" "Commands" "should have Commands section"
    assert_contains "$output" "Paths" "should have Paths section"
}
run_test "output has human-readable sections" test_output_format

# ── Summary ─────────────────────────────────────────────────────────────────
suite_summary
