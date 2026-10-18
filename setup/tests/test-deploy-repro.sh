#!/usr/bin/env bash
# Tests for deploy_repro (sync-lib/deploy.sh): the `repro` command on SteamOS.
# Typing the full path to setup/reprovision-steamos.sh after every OS
# update is too long — `repro` from any folder must run it. deploy_repro links
# ~/.local/bin/repro → setup/reprovision-steamos.sh on SteamOS only, and never replaces an
# unrelated `repro`. These run the REAL deploy_repro in a sandbox HOME.
source "$(dirname "$0")/test-helpers.sh"

suite_header "deploy_repro (repro → reprovision-steamos.sh on SteamOS)"

# $1 = os-release content to present (ID line decides SteamOS vs not)
run_deploy_repro() {
    local os_id="${1:-steamos}"
    mkdir -p "$TEST_TMPDIR/home/.local/bin"
    printf 'NAME="Test"\nID=%s\n' "$os_id" > "$TEST_TMPDIR/os-release"
    (
        export HOME="$TEST_TMPDIR/home"
        OS_RELEASE_FILE="$TEST_TMPDIR/os-release"
        SCRIPT_DIR="$REPO_ROOT"; GLOBAL_DIR="$REPO_ROOT/global"; PLATFORM=linux
        log_info()  { echo "[INFO] $*"; }
        log_warn()  { echo "[WARN] $*"; }
        log_error() { echo "[ERROR] $*"; }
        # shellcheck disable=SC1091
        source "$REPO_ROOT/sync-lib/common.sh"
        # shellcheck disable=SC1091
        source "$REPO_ROOT/sync-lib/deploy.sh"
        deploy_repro
    ) >> "$TEST_TMPDIR/deploy.log" 2>&1
}

# What `repro` resolves to when typed from an unrelated folder with ~/.local/bin on PATH.
resolve_repro_from_elsewhere() {
    mkdir -p "$TEST_TMPDIR/somewhere"
    ( cd "$TEST_TMPDIR/somewhere" \
        && PATH="$TEST_TMPDIR/home/.local/bin:/usr/bin:/bin" \
        && readlink -f "$(command -v repro)" )
}

test_steamos_gets_repro() {
    run_deploy_repro steamos
    assert_eq "$(readlink -f "$REPO_ROOT/setup/reprovision-steamos.sh")" "$(resolve_repro_from_elsewhere)" \
        "repro resolves to reprovision-steamos.sh from any folder" || return 1
    [[ -x "$TEST_TMPDIR/home/.local/bin/repro" ]] || { echo "    repro is not executable"; return 1; }
}
run_test "SteamOS: repro on PATH resolves to reprovision-steamos.sh" test_steamos_gets_repro

test_non_steamos_gets_nothing() {
    run_deploy_repro fedora
    local r="$TEST_TMPDIR/home/.local/bin/repro"
    [[ ! -e "$r" && ! -L "$r" ]] || { echo "    repro was deployed on a non-SteamOS machine"; return 1; }
}
run_test "non-SteamOS: no repro deployed" test_non_steamos_gets_nothing

test_unrelated_repro_left_alone() {
    local r="$TEST_TMPDIR/home/.local/bin/repro"
    mkdir -p "$TEST_TMPDIR/home/.local/bin"
    printf '#!/bin/sh\necho my-own-repro\n' > "$r"; chmod +x "$r"
    run_deploy_repro steamos
    [[ ! -L "$r" ]] || { echo "    the user's repro was replaced by a link"; return 1; }
    assert_file_contains "$r" "my-own-repro" || return 1
    assert_file_contains "$TEST_TMPDIR/deploy.log" "Skipped 'repro'"
}
run_test "an unrelated repro at the target is left alone (with a warning)" test_unrelated_repro_left_alone

test_redeploy_is_idempotent() {
    run_deploy_repro steamos
    run_deploy_repro steamos
    assert_eq "$(readlink -f "$REPO_ROOT/setup/reprovision-steamos.sh")" "$(resolve_repro_from_elsewhere)" || return 1
    assert_file_not_contains "$TEST_TMPDIR/deploy.log" "Skipped 'repro'"
}
run_test "re-deploy keeps our own repro link" test_redeploy_is_idempotent

test_wired_into_deploy_and_setup() {
    assert_file_contains "$REPO_ROOT/sync-lib/deploy.sh" "^    deploy_repro$" || return 1
    assert_file_contains "$REPO_ROOT/sync-lib/setup.sh" "^    deploy_repro$"
}
run_test "deploy_repro runs in sync.sh deploy and sync.sh setup" test_wired_into_deploy_and_setup

suite_summary
