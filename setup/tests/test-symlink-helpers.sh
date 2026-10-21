#!/usr/bin/env bash
# Tests for portable symlink helpers (CFG-335)
# Tests both symlink mode (default on Linux) and copy-fallback mode (MINGW64)
source "$(dirname "$0")/test-helpers.sh"

SYNC_LIB_DIR="$REPO_ROOT/sync-lib"

suite_header "Portable Symlink Helpers (CFG-335)"

# Helper to source common.sh with required variables in current shell
_init_common() {
    SCRIPT_DIR="$REPO_ROOT"
    GLOBAL_DIR="$REPO_ROOT/global"
    PROJECTS_DIR="$REPO_ROOT/setup/projects"
    CLAUDE_HOME="$TEST_TMPDIR/.claude"
    PLATFORM="${1:-linux}"
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
    log_info() { :; }
    log_warn() { :; }
    log_error() { :; }
    _SYMLINK_MODE=""  # reset cache
    source "$SYNC_LIB_DIR/common.sh"
}

# ── _can_symlink ─────────────────────────────────────────────────────────────

test_can_symlink_on_linux() {
    _init_common "linux"
    _can_symlink
    assert_eq "symlink" "$_SYMLINK_MODE"
}
run_test "_can_symlink returns true on Linux" test_can_symlink_on_linux

test_can_symlink_caches_result() {
    _init_common "linux"
    _can_symlink
    local first="$_SYMLINK_MODE"
    _can_symlink
    assert_eq "$first" "$_SYMLINK_MODE"
}
run_test "_can_symlink caches result across calls" test_can_symlink_caches_result

test_can_symlink_copy_mode_forced() {
    _init_common "windows"
    _SYMLINK_MODE="copy"  # force copy mode (as MINGW64 would)
    local rc=0
    _can_symlink || rc=$?
    assert_eq "copy" "$_SYMLINK_MODE"
    assert_neq "0" "0$rc" "should return non-zero in copy mode"
}
run_test "_can_symlink returns false in forced copy mode" test_can_symlink_copy_mode_forced

# ── _link_file ───────────────────────────────────────────────────────────────

test_link_file_creates_symlink() {
    _init_common "linux"
    echo "hello" > "$TEST_TMPDIR/source.txt"
    _link_file "$TEST_TMPDIR/source.txt" "$TEST_TMPDIR/target.txt"
    assert_file_exists "$TEST_TMPDIR/target.txt"
    # On Linux, should be a real symlink
    local is_link="no"
    [ -L "$TEST_TMPDIR/target.txt" ] && is_link="yes"
    assert_eq "yes" "$is_link" "target should be a symlink"
    assert_eq "hello" "$(cat "$TEST_TMPDIR/target.txt")"
}
run_test "_link_file creates symlink on Linux" test_link_file_creates_symlink

test_link_file_creates_copy_in_copy_mode() {
    _init_common "windows"
    _SYMLINK_MODE="copy"
    echo "hello" > "$TEST_TMPDIR/source.txt"
    _link_file "$TEST_TMPDIR/source.txt" "$TEST_TMPDIR/target.txt"
    assert_file_exists "$TEST_TMPDIR/target.txt"
    # Should NOT be a symlink
    local is_link="no"
    [ -L "$TEST_TMPDIR/target.txt" ] && is_link="yes"
    assert_eq "no" "$is_link" "target should NOT be a symlink in copy mode"
    assert_eq "hello" "$(cat "$TEST_TMPDIR/target.txt")"
}
run_test "_link_file creates copy in copy mode" test_link_file_creates_copy_in_copy_mode

test_link_file_overwrites_existing() {
    _init_common "linux"
    echo "old" > "$TEST_TMPDIR/target.txt"
    echo "new" > "$TEST_TMPDIR/source.txt"
    _link_file "$TEST_TMPDIR/source.txt" "$TEST_TMPDIR/target.txt"
    assert_eq "new" "$(cat "$TEST_TMPDIR/target.txt")"
}
run_test "_link_file overwrites existing file" test_link_file_overwrites_existing

# ── _link_dir ────────────────────────────────────────────────────────────────

test_link_dir_creates_symlink() {
    _init_common "linux"
    mkdir -p "$TEST_TMPDIR/srcdir"
    echo "content" > "$TEST_TMPDIR/srcdir/file.txt"
    _link_dir "$TEST_TMPDIR/srcdir" "$TEST_TMPDIR/dstdir"
    local is_link="no"
    [ -L "$TEST_TMPDIR/dstdir" ] && is_link="yes"
    assert_eq "yes" "$is_link" "target should be a symlink"
    assert_eq "content" "$(cat "$TEST_TMPDIR/dstdir/file.txt")"
}
run_test "_link_dir creates dir symlink on Linux" test_link_dir_creates_symlink

test_link_dir_creates_copy_in_copy_mode() {
    _init_common "windows"
    _SYMLINK_MODE="copy"
    mkdir -p "$TEST_TMPDIR/srcdir"
    echo "content" > "$TEST_TMPDIR/srcdir/file.txt"
    _link_dir "$TEST_TMPDIR/srcdir" "$TEST_TMPDIR/dstdir"
    assert_dir_exists "$TEST_TMPDIR/dstdir"
    local is_link="no"
    [ -L "$TEST_TMPDIR/dstdir" ] && is_link="yes"
    assert_eq "no" "$is_link" "target should NOT be a symlink in copy mode"
    assert_eq "content" "$(cat "$TEST_TMPDIR/dstdir/file.txt")"
}
run_test "_link_dir creates copy in copy mode" test_link_dir_creates_copy_in_copy_mode

test_link_dir_replaces_existing_symlink() {
    _init_common "linux"
    mkdir -p "$TEST_TMPDIR/old" "$TEST_TMPDIR/new"
    echo "new" > "$TEST_TMPDIR/new/file.txt"
    ln -sfn "$TEST_TMPDIR/old" "$TEST_TMPDIR/target"
    _link_dir "$TEST_TMPDIR/new" "$TEST_TMPDIR/target"
    assert_eq "new" "$(cat "$TEST_TMPDIR/target/file.txt")"
}
run_test "_link_dir replaces existing symlink" test_link_dir_replaces_existing_symlink

# ── _check_linked ────────────────────────────────────────────────────────────

test_check_linked_symlink_mode() {
    _init_common "linux"
    echo "x" > "$TEST_TMPDIR/source"
    ln -sf "$TEST_TMPDIR/source" "$TEST_TMPDIR/link"
    # Symlink should pass
    local rc=0
    _check_linked "$TEST_TMPDIR/link" || rc=$?
    assert_eq "0" "$rc" "symlink should pass"
    # Missing should fail
    rc=0
    _check_linked "$TEST_TMPDIR/nonexistent" || rc=$?
    assert_neq "0" "0$rc" "missing should fail"
    # Regular file is NOT a link in symlink mode
    rc=0
    _check_linked "$TEST_TMPDIR/source" || rc=$?
    assert_neq "0" "0$rc" "regular file should fail in symlink mode"
}
run_test "_check_linked detects symlinks in symlink mode" test_check_linked_symlink_mode

test_check_linked_copy_mode() {
    _init_common "windows"
    _SYMLINK_MODE="copy"
    echo "x" > "$TEST_TMPDIR/file"
    # Regular file should pass in copy mode
    local rc=0
    _check_linked "$TEST_TMPDIR/file" || rc=$?
    assert_eq "0" "$rc" "regular file should pass in copy mode"
    # Missing should fail
    rc=0
    _check_linked "$TEST_TMPDIR/nonexistent" || rc=$?
    assert_neq "0" "0$rc" "missing should fail"
}
run_test "_check_linked accepts regular files in copy mode" test_check_linked_copy_mode

# ── _check_linked_valid ──────────────────────────────────────────────────────

test_check_linked_valid_good_symlink() {
    _init_common "linux"
    echo "x" > "$TEST_TMPDIR/source"
    ln -sf "$TEST_TMPDIR/source" "$TEST_TMPDIR/link"
    local rc=0
    _check_linked_valid "$TEST_TMPDIR/link" || rc=$?
    assert_eq "0" "$rc" "valid symlink should pass"
}
run_test "_check_linked_valid passes for valid symlink" test_check_linked_valid_good_symlink

test_check_linked_valid_broken_symlink() {
    _init_common "linux"
    ln -sf "$TEST_TMPDIR/nonexistent" "$TEST_TMPDIR/broken"
    local rc=0
    _check_linked_valid "$TEST_TMPDIR/broken" || rc=$?
    assert_neq "0" "0$rc" "broken symlink should fail"
}
run_test "_check_linked_valid fails for broken symlink" test_check_linked_valid_broken_symlink

test_check_linked_valid_copy_mode() {
    _init_common "windows"
    _SYMLINK_MODE="copy"
    echo "x" > "$TEST_TMPDIR/file"
    local rc=0
    _check_linked_valid "$TEST_TMPDIR/file" || rc=$?
    assert_eq "0" "$rc" "existing file passes in copy mode"
    rc=0
    _check_linked_valid "$TEST_TMPDIR/missing" || rc=$?
    assert_neq "0" "0$rc" "missing file fails"
}
run_test "_check_linked_valid works in copy mode" test_check_linked_valid_copy_mode

# ── Integration: source files use helpers (regression guards) ────────────────

test_setup_uses_link_helpers() {
    assert_file_contains "$SYNC_LIB_DIR/setup.sh" "_link_file"
    assert_file_contains "$SYNC_LIB_DIR/setup.sh" "_link_dir"
}
run_test "sync-lib/setup.sh uses portable link helpers" test_setup_uses_link_helpers

test_verify_uses_check_helpers() {
    assert_file_contains "$SYNC_LIB_DIR/setup.sh" "_check_linked"
}
run_test "verify_setup uses _check_linked" test_verify_uses_check_helpers

test_deploy_afleet_uses_helpers() {
    local has_helper="no"
    grep -q '_link_file\|_check_linked' "$SYNC_LIB_DIR/deploy.sh" && has_helper="yes"
    assert_eq "yes" "$has_helper" "deploy.sh should use link helpers"
}
run_test "deploy_afleet uses portable helpers" test_deploy_afleet_uses_helpers

test_no_bare_ln_in_sync_lib() {
    # No bare 'ln -s' should remain in setup.sh or deploy.sh (except comments)
    local bare_ln
    bare_ln=$(grep -n 'ln -s' "$SYNC_LIB_DIR/setup.sh" "$SYNC_LIB_DIR/deploy.sh" 2>/dev/null \
        | grep -v '^\s*#' | grep -v ':#' || true)
    assert_eq "" "$bare_ln" "no bare ln -s should remain in sync-lib"
}
run_test "no bare ln -s in sync-lib setup/deploy" test_no_bare_ln_in_sync_lib

suite_summary
