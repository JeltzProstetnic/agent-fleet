#!/usr/bin/env bash
# Tests for shared aliases deployment
source "$(dirname "$0")/test-helpers.sh"

SYNC_SCRIPT="$REPO_ROOT/sync.sh"
DEPLOY_LIB="$REPO_ROOT/sync-lib/deploy.sh"
SETUP_LIB="$REPO_ROOT/sync-lib/setup.sh"

suite_header "Shared Aliases"

# ── Source file exists and is valid ──────────────────────────────────────────

test_aliases_file_exists() {
    assert_file_exists "$REPO_ROOT/setup/config/aliases.sh"
}
run_test "aliases.sh exists" test_aliases_file_exists

test_aliases_file_valid_bash() {
    bash -n "$REPO_ROOT/setup/config/aliases.sh"
}
run_test "aliases.sh is valid bash" test_aliases_file_valid_bash

test_aliases_defines_cls() {
    assert_file_contains "$REPO_ROOT/setup/config/aliases.sh" "alias cls="
}
run_test "aliases.sh defines cls alias" test_aliases_defines_cls

test_aliases_defines_md() {
    assert_file_contains "$REPO_ROOT/setup/config/aliases.sh" "alias md="
}
run_test "aliases.sh defines md alias" test_aliases_defines_md

test_aliases_define_no_af() {
    # CFG-507: `af` is the guarded link deploy_afleet makes (never over an unrelated af). An alias
    # here would be unguarded — it shadows the user's own af in every interactive shell.
    local out
    out=$(bash -c 'shopt -s expand_aliases; source "$1"; alias af 2>/dev/null; declare -F af' _ \
        "$REPO_ROOT/setup/config/aliases.sh")
    assert_eq "" "$out" "aliases.sh must define no af alias or function"
}
run_test "aliases.sh defines no af alias or function (af is the guarded link)" test_aliases_define_no_af

# ── deploy_aliases function ──────────────────────────────────────────────────

# Helper: extract deploy_aliases and its dependencies from sync-lib/deploy.sh
_run_deploy_aliases() {
    local fake_home="$1"
    (
        export HOME="$fake_home"
        SCRIPT_DIR="$REPO_ROOT"
        # Source just the function + logger
        log_info() { echo "[INFO] $*"; }
        log_warn() { echo "[WARN] $*"; }
        source <(sed -n '/^deploy_aliases()/,/^}/p' "$DEPLOY_LIB")
        deploy_aliases
    )
}

test_deploy_copies_file() {
    local fake_home="$TEST_TMPDIR/home"
    mkdir -p "$fake_home"
    echo "# existing bashrc" > "$fake_home/.bashrc"

    _run_deploy_aliases "$fake_home" >/dev/null
    assert_file_exists "$fake_home/.cfg-aliases.sh"
}
run_test "deploy_aliases copies file to home" test_deploy_copies_file

test_deploy_file_content_matches() {
    local fake_home="$TEST_TMPDIR/home"
    mkdir -p "$fake_home"
    echo "# existing bashrc" > "$fake_home/.bashrc"

    _run_deploy_aliases "$fake_home" >/dev/null
    diff -q "$REPO_ROOT/setup/config/aliases.sh" "$fake_home/.cfg-aliases.sh"
}
run_test "deployed file matches source" test_deploy_file_content_matches

test_deploy_injects_bashrc_line() {
    local fake_home="$TEST_TMPDIR/home"
    mkdir -p "$fake_home"
    echo "# existing bashrc" > "$fake_home/.bashrc"

    _run_deploy_aliases "$fake_home" >/dev/null
    assert_file_contains "$fake_home/.bashrc" "cfg-aliases.sh"
    assert_file_contains "$fake_home/.bashrc" "agent-fleet: shared aliases"
}
run_test "deploy_aliases injects source line into .bashrc" test_deploy_injects_bashrc_line

test_deploy_idempotent() {
    local fake_home="$TEST_TMPDIR/home"
    mkdir -p "$fake_home"
    echo "# existing bashrc" > "$fake_home/.bashrc"

    _run_deploy_aliases "$fake_home" >/dev/null
    _run_deploy_aliases "$fake_home" >/dev/null

    assert_grep_count "$fake_home/.bashrc" "cfg-aliases.sh" 1
}
run_test "deploy_aliases is idempotent" test_deploy_idempotent

test_deploy_creates_bashrc_if_missing() {
    local fake_home="$TEST_TMPDIR/home"
    mkdir -p "$fake_home"
    # No .bashrc exists

    _run_deploy_aliases "$fake_home" >/dev/null
    assert_file_exists "$fake_home/.bashrc"
    assert_file_contains "$fake_home/.bashrc" "cfg-aliases.sh"
}
run_test "deploy_aliases creates .bashrc if missing" test_deploy_creates_bashrc_if_missing

test_deploy_preserves_existing_bashrc() {
    local fake_home="$TEST_TMPDIR/home"
    mkdir -p "$fake_home"
    echo "export PATH=/custom/path" > "$fake_home/.bashrc"

    _run_deploy_aliases "$fake_home" >/dev/null
    assert_file_contains "$fake_home/.bashrc" "export PATH=/custom/path"
    assert_file_contains "$fake_home/.bashrc" "cfg-aliases.sh"
}
run_test "deploy_aliases preserves existing .bashrc content" test_deploy_preserves_existing_bashrc

# ── sync.sh integration ─────────────────────────────────────────────────────

test_deploy_aliases_in_sync_deploy() {
    # Verify deploy_aliases is called from cmd_deploy in sync-lib/deploy.sh
    assert_file_contains "$DEPLOY_LIB" "deploy_aliases"
}
run_test "sync-lib/deploy.sh calls deploy_aliases" test_deploy_aliases_in_sync_deploy

test_deploy_aliases_in_sync_setup() {
    # Verify deploy_aliases is called (not just mentioned in comment) in sync-lib/setup.sh
    local call_count
    call_count=$(grep -c '^\s*deploy_aliases' "$SETUP_LIB" || true)
    assert_eq "1" "$call_count" "deploy_aliases should be called once in cmd_setup"
}
run_test "sync-lib/setup.sh calls deploy_aliases" test_deploy_aliases_in_sync_setup

suite_summary
