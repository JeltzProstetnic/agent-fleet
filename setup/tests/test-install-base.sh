#!/usr/bin/env bash
# Tests for setup/install-base.sh — nvm/npmrc compatibility
source "$(dirname "$0")/test-helpers.sh"

INSTALL_SCRIPT="$REPO_ROOT/setup/install-base.sh"

suite_header "install-base.sh (nvm/npmrc compatibility)"

# ── Helpers ──────────────────────────────────────────────────────────────────

create_test_env() {
    local home="$TEST_TMPDIR/home"
    mkdir -p "$home/.local/bin"
    echo "$home"
}

# Build a test harness that extracts setup_npm_global from install-base.sh
# with stubbed dependencies so we can test it in isolation.
build_test_harness() {
    cat > "$TEST_TMPDIR/harness.sh" << 'HARNESS'
#!/usr/bin/env bash
set -euo pipefail

# Stubs for install-base dependencies
TOTAL_STEPS=6
log_step()    { shift 2; echo "[STEP] $*"; }
log_info()    { echo "[INFO] $*"; }
log_warn()    { echo "[WARN] $*"; }
log_success() { echo "[OK] $*"; }
file_contains() { grep -q "$2" "$1" 2>/dev/null; }
run_cmd()     { "$@"; }
backup_file() { :; }
detect_shell_rc()      { echo "${HOME}/.bashrc"; }
detect_shell_rc_name() { echo ".bashrc"; }

DRY_RUN="${DRY_RUN:-false}"
INSTALLED_STEPS=()
SKIPPED_STEPS=()
HARNESS

    # Extract the function from install-base.sh and append
    sed -n '/^setup_npm_global()/,/^}/p' "$INSTALL_SCRIPT" >> "$TEST_TMPDIR/harness.sh"

    echo 'setup_npm_global' >> "$TEST_TMPDIR/harness.sh"
}

# ── 1. NVM detection ────────────────────────────────────────────────────────

test_nvm_detected_skips_prefix() {
    local home
    home=$(create_test_env)

    # Simulate nvm installation
    mkdir -p "$home/.nvm"
    echo '# nvm stub' > "$home/.nvm/nvm.sh"
    echo '# empty bashrc' > "$home/.bashrc"

    build_test_harness

    local output
    output=$(HOME="$home" NVM_DIR="$home/.nvm" bash "$TEST_TMPDIR/harness.sh" 2>&1)

    assert_contains "$output" "NVM detected" "should detect nvm"
    assert_contains "$output" "skipping npm prefix" "should skip prefix config"
    # No assert_dir_not_exists in helpers — inline check
    if [[ -d "$home/.npm-global" ]]; then
        echo "    FAIL: ~/.npm-global should not exist when nvm is active" >&2
        return 1
    fi
}
run_test "nvm detected: skips npm prefix configuration" test_nvm_detected_skips_prefix

test_nvm_cleans_stale_prefix() {
    local home
    home=$(create_test_env)

    # Simulate nvm + stale .npmrc with prefix
    mkdir -p "$home/.nvm"
    echo '# nvm stub' > "$home/.nvm/nvm.sh"
    echo "prefix=$home/.npm-global" > "$home/.npmrc"
    echo '# empty bashrc' > "$home/.bashrc"

    build_test_harness

    local output
    output=$(HOME="$home" NVM_DIR="$home/.nvm" bash "$TEST_TMPDIR/harness.sh" 2>&1)

    assert_contains "$output" "Removing stale prefix" "should warn about stale prefix"
    assert_file_not_exists "$home/.npmrc" "should remove empty .npmrc after prefix removal"
}
run_test "nvm detected: cleans stale prefix= from .npmrc" test_nvm_cleans_stale_prefix

test_nvm_preserves_other_npmrc_lines() {
    local home
    home=$(create_test_env)

    # Simulate nvm + .npmrc with prefix AND other settings
    mkdir -p "$home/.nvm"
    echo '# nvm stub' > "$home/.nvm/nvm.sh"
    printf 'prefix=%s/.npm-global\nregistry=https://registry.npmjs.org/\n' "$home" > "$home/.npmrc"
    echo '# empty bashrc' > "$home/.bashrc"

    build_test_harness

    HOME="$home" NVM_DIR="$home/.nvm" bash "$TEST_TMPDIR/harness.sh" >/dev/null 2>&1

    assert_file_exists "$home/.npmrc" "should keep .npmrc with other settings"
    assert_file_not_contains "$home/.npmrc" "^prefix=" "should have removed prefix line"
    assert_file_contains "$home/.npmrc" "registry=" "should preserve registry line"
}
run_test "nvm detected: preserves other .npmrc lines" test_nvm_preserves_other_npmrc_lines

# ── 2. No NVM — traditional prefix setup ────────────────────────────────────

test_no_nvm_sets_prefix() {
    local home
    home=$(create_test_env)

    # No nvm installation — but need .bashrc for PATH addition
    echo '# empty bashrc' > "$home/.bashrc"

    build_test_harness

    local output
    output=$(HOME="$home" NVM_DIR="$home/.nvm" bash "$TEST_TMPDIR/harness.sh" 2>&1)

    assert_not_contains "$output" "NVM detected" "should not detect nvm"
    assert_dir_exists "$home/.npm-global" "should create ~/.npm-global"
}
run_test "no nvm: sets npm prefix normally" test_no_nvm_sets_prefix

# ── 3. ~/.local/bin PATH ────────────────────────────────────────────────────

test_local_bin_added_to_path() {
    local home
    home=$(create_test_env)

    echo '# empty bashrc' > "$home/.bashrc"

    build_test_harness

    HOME="$home" NVM_DIR="$home/.nvm" bash "$TEST_TMPDIR/harness.sh" >/dev/null 2>&1

    assert_file_contains "$home/.bashrc" '.local/bin' "should add ~/.local/bin to .bashrc PATH"
}
run_test "adds ~/.local/bin to .bashrc PATH" test_local_bin_added_to_path

test_local_bin_not_duplicated() {
    local home
    home=$(create_test_env)

    echo 'export PATH="$HOME/.local/bin:$PATH"' > "$home/.bashrc"

    build_test_harness

    local output
    output=$(HOME="$home" NVM_DIR="$home/.nvm" bash "$TEST_TMPDIR/harness.sh" 2>&1)

    assert_contains "$output" "already in PATH" "should detect existing .local/bin in PATH"
    assert_grep_count "$home/.bashrc" '.local/bin' 1 "should not duplicate .local/bin PATH entry"
}
run_test "does not duplicate ~/.local/bin if already in .bashrc" test_local_bin_not_duplicated

# ── 4. Dry run ──────────────────────────────────────────────────────────────

test_dry_run_no_file_changes() {
    local home
    home=$(create_test_env)

    mkdir -p "$home/.nvm"
    echo '# nvm stub' > "$home/.nvm/nvm.sh"
    echo "prefix=$home/.npm-global" > "$home/.npmrc"
    echo '# empty bashrc' > "$home/.bashrc"

    build_test_harness

    local output
    output=$(HOME="$home" NVM_DIR="$home/.nvm" DRY_RUN=true bash "$TEST_TMPDIR/harness.sh" 2>&1)

    assert_contains "$output" "DRY RUN" "should indicate dry run"
    assert_file_contains "$home/.npmrc" "^prefix=" "should not modify .npmrc in dry run"
}
run_test "dry run: no file modifications" test_dry_run_no_file_changes

# ── Summary ─────────────────────────────────────────────────────────────────
suite_summary
