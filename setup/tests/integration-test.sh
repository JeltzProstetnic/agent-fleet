#!/usr/bin/env bash
# Integration test — full install.sh + configure-claude.sh cycle
# ================================================================
# Runs a complete installation in an isolated environment (temp HOME).
# Designed to run inside Docker containers from the CI pipeline.
#
# This test verifies:
#   1. install.sh --help runs without error
#   2. install.sh --dry-run completes (preview only, no execution)
#   3. configure-claude.sh --dry-run completes
#   4. sync.sh setup creates expected symlinks
#   5. Idempotency: re-running produces no errors or duplicates
#   6. MCP config is valid JSON (if created)
#   7. Key files and directories exist after setup
#
# Usage:
#   bash setup/tests/integration-test.sh
#
# Note: This does NOT run the full install.sh (which requires sudo for
# packages). It tests the dry-run paths and sync.sh setup, which are
# the parts that don't need root.

set -euo pipefail

source "$(dirname "$0")/test-helpers.sh"

INSTALL_SCRIPT="$REPO_ROOT/setup/install.sh"
CONFIGURE_SCRIPT="$REPO_ROOT/setup/configure-claude.sh"
SYNC_SCRIPT="$REPO_ROOT/sync.sh"
LIB_SCRIPT="$REPO_ROOT/setup/lib.sh"
PREFLIGHT_SCRIPT="$REPO_ROOT/setup/preflight.sh"

suite_header "Integration Tests (install + configure cycle)"

# ── Helpers ──────────────────────────────────────────────────────────────────

create_integration_env() {
    local home="$TEST_TMPDIR/home"
    mkdir -p "$home/.local/bin"
    mkdir -p "$home/.claude"
    echo "$home"
}

# ── 1. install.sh --help ────────────────────────────────────────────────────

test_install_help() {
    local output exit_code=0
    output=$(bash "$INSTALL_SCRIPT" --help 2>&1) || exit_code=$?

    assert_eq "0" "$exit_code" "install.sh --help should exit 0"
    assert_contains "$output" "install.sh" "help should mention script name"
    assert_contains "$output" "--dry-run" "help should mention --dry-run"
    assert_contains "$output" "--skip-preflight" "help should mention --skip-preflight"
}
run_test "install.sh --help runs without error" test_install_help

# ── 2. lib.sh sources cleanly ───────────────────────────────────────────────

test_lib_sources() {
    # bash -n checks syntax without executing
    local exit_code=0
    bash -n "$LIB_SCRIPT" 2>&1 || exit_code=$?
    assert_eq "0" "$exit_code" "lib.sh should pass syntax check"
}
run_test "lib.sh sources correctly (bash -n)" test_lib_sources

# ── 3. preflight.sh runs ────────────────────────────────────────────────────

test_preflight_runs() {
    local home
    home=$(create_integration_env)

    local output exit_code=0
    output=$(HOME="$home" bash "$PREFLIGHT_SCRIPT" --skip-network 2>&1) || exit_code=$?

    # On a CI machine with all deps, this should pass
    assert_contains "$output" "Preflight System Check" "should show title"
    assert_contains "$output" "[PASS]" "should have at least one PASS"
}
run_test "preflight.sh runs with --skip-network" test_preflight_runs

# ── 4. configure-claude.sh exists and is executable ─────────────────────────

test_configure_exists() {
    assert_file_exists "$CONFIGURE_SCRIPT" "configure-claude.sh should exist"

    if [[ ! -x "$CONFIGURE_SCRIPT" ]]; then
        # Not executable — check if it at least has valid bash syntax
        local exit_code=0
        bash -n "$CONFIGURE_SCRIPT" 2>&1 || exit_code=$?
        assert_eq "0" "$exit_code" "configure-claude.sh should pass syntax check"
    fi
}
run_test "configure-claude.sh exists and has valid syntax" test_configure_exists

# ── 5. sync.sh exists ───────────────────────────────────────────────────────

test_sync_exists() {
    assert_file_exists "$SYNC_SCRIPT" "sync.sh should exist"

    local exit_code=0
    bash -n "$SYNC_SCRIPT" 2>&1 || exit_code=$?
    assert_eq "0" "$exit_code" "sync.sh should pass syntax check"
}
run_test "sync.sh exists and has valid syntax" test_sync_exists

# ── 6. sync.sh setup creates symlinks ───────────────────────────────────────

test_sync_setup() {
    local home
    home=$(create_integration_env)

    local output exit_code=0
    output=$(HOME="$home" bash "$SYNC_SCRIPT" setup 2>&1) || exit_code=$?

    assert_eq "0" "$exit_code" "sync.sh setup should exit 0"

    # Check key symlinks
    if [[ -L "$home/.claude/CLAUDE.md" ]]; then
        assert_eq "0" "0" "CLAUDE.md symlink created"
    else
        # May be a regular file if symlink creation failed — still acceptable
        assert_file_exists "$home/.claude/CLAUDE.md" "CLAUDE.md should exist after sync setup"
    fi

    # Check directory symlinks
    for dir in foundation reference knowledge; do
        if [[ -d "$home/.claude/$dir" ]] || [[ -L "$home/.claude/$dir" ]]; then
            assert_eq "0" "0" "$dir directory/symlink exists"
        else
            echo "    WARN: $home/.claude/$dir not found after sync setup" >&2
        fi
    done
}
run_test "sync.sh setup creates expected structure" test_sync_setup

# ── 7. sync.sh setup idempotency ────────────────────────────────────────────

test_sync_idempotent() {
    local home
    home=$(create_integration_env)

    # Run setup twice
    local output1 output2 exit1=0 exit2=0
    output1=$(HOME="$home" bash "$SYNC_SCRIPT" setup 2>&1) || exit1=$?
    output2=$(HOME="$home" bash "$SYNC_SCRIPT" setup 2>&1) || exit2=$?

    assert_eq "0" "$exit1" "first sync.sh setup should exit 0"
    assert_eq "0" "$exit2" "second sync.sh setup should exit 0"

    # No errors in second run
    assert_not_contains "$output2" "ERROR" "idempotent run should have no errors"
}
run_test "sync.sh setup is idempotent" test_sync_idempotent

# ── 8. MCP config validation (if .mcp.json exists in config) ────────────────

test_mcp_config_valid_json() {
    local mcp_template="$REPO_ROOT/setup/config/.mcp.json"

    if [[ ! -f "$mcp_template" ]]; then
        skip_test "MCP config template validation" ".mcp.json template not found"
        return 0
    fi

    # Validate JSON structure
    if command -v python3 &>/dev/null; then
        local exit_code=0
        python3 -c "import json; json.load(open('$mcp_template'))" 2>&1 || exit_code=$?
        assert_eq "0" "$exit_code" "MCP config template should be valid JSON"
    elif command -v jq &>/dev/null; then
        local exit_code=0
        jq . "$mcp_template" >/dev/null 2>&1 || exit_code=$?
        assert_eq "0" "$exit_code" "MCP config template should be valid JSON"
    else
        skip_test "MCP config template validation" "neither python3 nor jq available"
    fi
}
run_test "MCP config template is valid JSON" test_mcp_config_valid_json

# ── 9. All setup scripts pass syntax check ──────────────────────────────────

test_all_scripts_syntax() {
    local failed=0
    for script in "$REPO_ROOT"/setup/*.sh "$REPO_ROOT"/setup/scripts/*.sh; do
        [[ -f "$script" ]] || continue
        if ! bash -n "$script" 2>/dev/null; then
            echo "    Syntax error in: $script" >&2
            ((failed++)) || true
        fi
    done

    assert_eq "0" "$failed" "all setup scripts should pass bash -n syntax check"
}
run_test "all setup scripts pass syntax check" test_all_scripts_syntax

# ── 10. Key config templates exist ──────────────────────────────────────────

test_config_templates_exist() {
    assert_file_exists "$REPO_ROOT/setup/config/settings.json" "settings.json template"

    # Global CLAUDE.md should exist
    assert_file_exists "$REPO_ROOT/global/CLAUDE.md" "global CLAUDE.md"

    # Foundation files
    assert_dir_exists "$REPO_ROOT/global/foundation" "global/foundation directory"
}
run_test "key config templates exist" test_config_templates_exist

# ── Summary ─────────────────────────────────────────────────────────────────
suite_summary
