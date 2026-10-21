#!/usr/bin/env bash
# Tests for sync-lib/setup.sh helpers (CFG-700 step 3):
#   - cmd_setup arms the repo's tracked .githooks/ guard (template-only block, now shared)
#   - replacing a real ~/.claude/<dir> never deletes unbacked content, in symlink AND copy mode
source "$(dirname "$0")/test-helpers.sh"

SETUP_SH="$REPO_ROOT/sync-lib/setup.sh"
COMMON_SH="$REPO_ROOT/sync-lib/common.sh"

suite_header "sync-lib/setup.sh helpers (CFG-700)"

_load() {
    SCRIPT_DIR="$1"
    GLOBAL_DIR="$1/global"
    log_info() { :; }
    log_warn() { echo "WARN: $*"; }
    log_error() { echo "ERROR: $*"; }
    source "$COMMON_SH"
    source "$SETUP_SH"
}

test_arm_githooks_sets_hookspath() {
    (
        local repo="$TEST_TMPDIR/fixture-repo"
        mkdir -p "$repo/.githooks" "$repo/setup/scripts"
        git -C "$repo" init -q -b main
        printf '#!/bin/sh\nexit 0\n' > "$repo/.githooks/pre-push"
        cp "$REPO_ROOT/setup/scripts/ensure-githooks.sh" "$repo/setup/scripts/"
        _load "$repo"
        setup_arm_githooks >/dev/null 2>&1
        local got
        got=$(git -C "$repo" config --get core.hooksPath)
        assert_eq ".githooks" "$got" "core.hooksPath after setup_arm_githooks (got '$got')"
    )
}

test_arm_githooks_missing_script_is_harmless() {
    (
        local repo="$TEST_TMPDIR/noscript"
        mkdir -p "$repo"
        _load "$repo"
        local rc=0
        setup_arm_githooks >/dev/null 2>&1 || rc=$?
        assert_eq "0" "$rc" "missing ensure-githooks.sh must not fail setup (rc=$rc)"
    )
}

test_cmd_setup_calls_arm_githooks() {
    local body
    body=$(sed -n '/^cmd_setup()/,/^}/p' "$SETUP_SH")
    assert_contains "$body" "setup_arm_githooks" "cmd_setup arms the githooks guard"
}

_replace_case() {
    local mode="$1"
    (
        local repo="$TEST_TMPDIR/r-$mode" home="$TEST_TMPDIR/h-$mode"
        mkdir -p "$repo/global/knowledge" "$home/knowledge"
        echo "repo" > "$repo/global/knowledge/a.md"
        echo "user-only" > "$home/knowledge/mine.md"
        _load "$repo"
        _SYMLINK_MODE="$mode"
        _replace_dir_with_link "$repo/global/knowledge" "$home/knowledge" >/dev/null
        local bak
        bak=$(ls -d "$home"/knowledge.bak.* 2>/dev/null | head -1)
        assert_file_exists "$bak/mine.md" "$mode mode: unbacked user file preserved in a .bak dir (found '$bak')"
        assert_file_exists "$home/knowledge/a.md" "$mode mode: repo content deployed"
    )
}
test_replace_backs_up_symlink_mode() { _replace_case symlink; }
test_replace_backs_up_copy_mode()    { _replace_case copy; }

test_copy_mode_identical_copy_not_rebacked() {
    (
        local repo="$TEST_TMPDIR/r-same" home="$TEST_TMPDIR/h-same"
        mkdir -p "$repo/global/knowledge" "$home"
        echo "repo" > "$repo/global/knowledge/a.md"
        cp -r "$repo/global/knowledge" "$home/knowledge"
        _load "$repo"
        _SYMLINK_MODE="copy"
        _replace_dir_with_link "$repo/global/knowledge" "$home/knowledge" >/dev/null
        local n
        n=$(ls -d "$home"/knowledge.bak.* 2>/dev/null | wc -l)
        assert_eq "0" "$n" "copy mode: an unchanged previous copy is not backed up again (got $n)"
    )
}

run_test "setup_arm_githooks sets core.hooksPath=.githooks" test_arm_githooks_sets_hookspath
run_test "setup_arm_githooks tolerates a missing script" test_arm_githooks_missing_script_is_harmless
run_test "cmd_setup calls setup_arm_githooks" test_cmd_setup_calls_arm_githooks
run_test "replace dir: symlink mode backs up real dir" test_replace_backs_up_symlink_mode
run_test "replace dir: copy mode backs up real dir" test_replace_backs_up_copy_mode
run_test "replace dir: copy mode skips identical copy" test_copy_mode_identical_copy_not_rebacked

# CFG-700 step 7: deploy_afd replaces the client portably (no GNU-only cp flag)
test_deploy_afd_replaces_readonly_client() {
    (
        local repo="$TEST_TMPDIR/afdrepo" home="$TEST_TMPDIR/afdhome"
        mkdir -p "$repo/afd/client" "$home/.local/bin"
        printf '#!/bin/sh\necho new\n' > "$repo/afd/client/afd"
        printf '#!/bin/sh\necho old\n' > "$home/.local/bin/afd"; chmod 555 "$home/.local/bin/afd"
        HOME="$home"; SCRIPT_DIR="$repo"
        log_info() { :; }; log_warn() { :; }
        source <(sed -n '/^deploy_afd()/,/^}/p' "$REPO_ROOT/sync-lib/deploy.sh")
        deploy_afd >/dev/null 2>&1
        assert_file_contains "$home/.local/bin/afd" "echo new" "existing read-only afd is replaced" || return 1
        [[ -x "$home/.local/bin/afd" ]] || { echo "    afd not executable"; return 1; }
        assert_file_not_contains "$REPO_ROOT/sync-lib/deploy.sh" "remove-destination" "no GNU-only cp flag (BSD/macOS)"
    )
}
run_test "deploy_afd replaces a read-only client without GNU-only cp flags" test_deploy_afd_replaces_readonly_client

suite_summary
