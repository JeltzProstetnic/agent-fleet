#!/usr/bin/env bash
# Tests for deploy_afx (sync-lib/deploy.sh): `sync.sh deploy` and `sync.sh setup` put the fleet dispatcher on
# PATH as ~/.local/bin/afx (CFG-1093). Runs the REAL deploy_afx in a sandbox HOME against a fixture repo.
source "$(dirname "$0")/test-helpers.sh"

suite_header "deploy_afx (~/.local/bin/afx → setup/scripts/afx.sh)"

fixture_repo() {
    local f="$TEST_TMPDIR/fixture-repo"
    mkdir -p "$f/setup/scripts" "$f/global/hooks"
    cp "$REPO_ROOT/global/hooks/lib-portable.sh" "$REPO_ROOT/global/hooks/lib-detect-repo.sh" "$f/global/hooks/"
    [[ "${FIXTURE_NO_SUBJECT:-}" == 1 ]] || cp "$REPO_ROOT/setup/scripts/afx.sh" "$f/setup/scripts/afx.sh"
    echo "$f"
}

# Runs the REAL deploy_afx the way sync.sh does: a fresh bash under `set -euo pipefail` (sync.sh:12). A subshell
# inside run_test is an errexit-ignored context, where an aborting deploy_afx would still look fine (Fable
# review 2026-11-26), so the process must be new and the line after deploy_afx must be reached.
run_deploy_afx() {
    local fx; fx=$(fixture_repo)
    mkdir -p "$TEST_TMPDIR/home/.local/bin"
    HOME="$TEST_TMPDIR/home" FX="$fx" RR="$REPO_ROOT" _SYMLINK_MODE=symlink bash -c '
        set -euo pipefail
        SCRIPT_DIR="$FX"; GLOBAL_DIR="$FX/global"; PLATFORM=linux
        log_info()  { echo "[INFO] $*"; }
        log_warn()  { echo "[WARN] $*"; }
        log_error() { echo "[ERROR] $*"; }
        source "$RR/sync-lib/common.sh"
        source "$RR/sync-lib/deploy.sh"
        deploy_afx
        echo "AFTER_DEPLOY_AFX"
    ' >> "$TEST_TMPDIR/deploy.log" 2>&1
    echo "DEPLOY_RC=$?" >> "$TEST_TMPDIR/deploy.log"
}

test_links_afx() {
    run_deploy_afx
    local fx="$TEST_TMPDIR/fixture-repo" bin="$TEST_TMPDIR/home/.local/bin"
    assert_eq "$fx/setup/scripts/afx.sh" "$(readlink -f "$bin/afx")" "afx → the repo's dispatcher"
    assert_file_contains "$TEST_TMPDIR/deploy.log" "Deployed: afx"
    assert_file_contains "$TEST_TMPDIR/deploy.log" "DEPLOY_RC=0"
}
run_test "deploy_afx links ~/.local/bin/afx to setup/scripts/afx.sh" test_links_afx

test_foreign_afx_kept_and_warned() {
    mkdir -p "$TEST_TMPDIR/home/.local/bin"
    printf '#!/bin/sh\necho other\n' > "$TEST_TMPDIR/home/.local/bin/afx"
    run_deploy_afx
    assert_file_contains "$TEST_TMPDIR/home/.local/bin/afx" "echo other" "an unrelated afx is never replaced"
    assert_file_contains "$TEST_TMPDIR/deploy.log" "\\[WARN\\] Skipped 'afx'"
    assert_file_contains "$TEST_TMPDIR/deploy.log" "DEPLOY_RC=0" "a conflict never stops the deploy"
    assert_file_contains "$TEST_TMPDIR/deploy.log" "AFTER_DEPLOY_AFX" "…the deploy reaches its next step under set -e"
}
run_test "an unrelated ~/.local/bin/afx is kept, warned about, and the deploy goes on" test_foreign_afx_kept_and_warned

test_missing_subject_noop() {
    FIXTURE_NO_SUBJECT=1 run_deploy_afx
    assert_file_not_exists "$TEST_TMPDIR/home/.local/bin/afx"
    assert_file_contains "$TEST_TMPDIR/deploy.log" "DEPLOY_RC=0"
}
test_unwritable_bin_does_not_abort() {
    mkdir -p "$TEST_TMPDIR/home/.local/bin"; chmod 555 "$TEST_TMPDIR/home/.local/bin"
    run_deploy_afx
    chmod 755 "$TEST_TMPDIR/home/.local/bin"
    assert_file_contains "$TEST_TMPDIR/deploy.log" "afx not deployed" "the failure is reported with afx's reason"
    assert_file_contains "$TEST_TMPDIR/deploy.log" "AFTER_DEPLOY_AFX" "and the deploy goes on"
    assert_file_contains "$TEST_TMPDIR/deploy.log" "DEPLOY_RC=0"
}
run_test "an unwritable ~/.local/bin is reported and never aborts the deploy (set -euo pipefail)" test_unwritable_bin_does_not_abort

run_test "no setup/scripts/afx.sh in the repo → nothing placed, deploy goes on" test_missing_subject_noop

test_wired_into_deploy_and_setup() {
    assert_grep_count "$REPO_ROOT/sync-lib/deploy.sh" "^[[:space:]]*deploy_afx$" 1 "cmd_deploy calls deploy_afx"
    assert_grep_count "$REPO_ROOT/sync-lib/setup.sh" "^[[:space:]]*deploy_afx$" 1 "cmd_setup calls deploy_afx"
}
run_test "deploy_afx runs in both sync.sh deploy and sync.sh setup" test_wired_into_deploy_and_setup

suite_summary
