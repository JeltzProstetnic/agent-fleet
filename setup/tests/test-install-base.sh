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

DRY_RUN="${DRY_RUN:-false}"
INSTALLED_STEPS=()
SKIPPED_STEPS=()

# Stub shell rc detection to use .bashrc (test always uses bash)
detect_shell_rc() { echo "$HOME/.bashrc"; }
detect_shell_rc_name() { echo ".bashrc"; }
# Portable sed -i (from lib-portable.sh)
_sed_i() { sed -i "$@"; }
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

# ── 5. create_mclaude_variant: platform-aware launcher path (CFG-335, CFG-1087 slice 1) ────
# agent-fleet GH#2: on Git Bash cc-mirror writes ~/.cc-mirror/bin/<variant>.cmd, but the check
# after creation looked only at ~/.local/bin/<variant> and aborted the install with
# "mclaude launcher not found after creation". The function must look where the platform puts
# it — and accept either known location, since cc-mirror versions differ.

build_variant_harness() {
    cat > "$TEST_TMPDIR/vharness.sh" << 'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_LIB_PORTABLE"
TOTAL_STEPS=6; CC_MIRROR_VARIANT=mclaude; CLAUDE_CODE_VERSION=latest; DRY_RUN="${DRY_RUN:-false}"
INSTALLED_STEPS=(); SKIPPED_STEPS=()
log_step()    { shift 2; echo "[STEP] $*"; }
log_info()    { echo "[INFO] $*"; }
log_warn()    { echo "[WARN] $*"; }
log_success() { echo "[OK] $*"; }
log_error()   { echo "[ERROR] $*"; }
OSTYPE="${FAKE_OSTYPE:-$OSTYPE}"
HARNESS
    sed -n '/^create_mclaude_variant()/,/^}/p' "$INSTALL_SCRIPT" >> "$TEST_TMPDIR/vharness.sh"
    echo 'create_mclaude_variant' >> "$TEST_TMPDIR/vharness.sh"
    mkdir -p "$TEST_TMPDIR/fakebin"
    # fake cc-mirror: writes the launcher where FAKE_LAUNCHER says; empty = writes nothing
    printf '#!/usr/bin/env bash\n[ -n "${FAKE_LAUNCHER:-}" ] || exit 0\nmkdir -p "$(dirname "$FAKE_LAUNCHER")"\necho stub > "$FAKE_LAUNCHER"\n' > "$TEST_TMPDIR/fakebin/cc-mirror"
    chmod +x "$TEST_TMPDIR/fakebin/cc-mirror"
}

# run_variant <ostype> <launcher path relative to HOME, or empty> — output in $TEST_TMPDIR/v.log
run_variant() {
    local home="$TEST_TMPDIR/vhome"
    mkdir -p "$home"
    build_variant_harness
    local rc=0
    HOME="$home" FAKE_OSTYPE="$1" FAKE_LAUNCHER="${2:+$home/$2}" \
        REPO_LIB_PORTABLE="$REPO_ROOT/global/hooks/lib-portable.sh" \
        PATH="$TEST_TMPDIR/fakebin:$PATH" bash "$TEST_TMPDIR/vharness.sh" > "$TEST_TMPDIR/v.log" 2>&1 || rc=$?
    return $rc
}

test_variant_windows_cmd_launcher_accepted() {
    run_variant msys ".cc-mirror/bin/mclaude.cmd" || { sed 's/^/    | /' "$TEST_TMPDIR/v.log"; echo "    exited non-zero"; return 1; }
    assert_file_contains "$TEST_TMPDIR/v.log" "mclaude launcher created at" || return 1
    assert_file_contains "$TEST_TMPDIR/v.log" ".cc-mirror/bin/mclaude.cmd" "the message names the .cmd launcher"
}
run_test "Git Bash: the .cmd launcher cc-mirror writes passes the post-creation check" test_variant_windows_cmd_launcher_accepted

test_variant_windows_accepts_other_location() {
    run_variant msys ".local/bin/mclaude" || { sed 's/^/    | /' "$TEST_TMPDIR/v.log"; echo "    exited non-zero"; return 1; }
    assert_file_contains "$TEST_TMPDIR/v.log" ".local/bin/mclaude" "the message names where it was found"
}
run_test "Git Bash: a launcher at the other known location is accepted and named" test_variant_windows_accepts_other_location

test_variant_linux_unchanged() {
    run_variant linux-gnu ".local/bin/mclaude" || { sed 's/^/    | /' "$TEST_TMPDIR/v.log"; echo "    exited non-zero"; return 1; }
    assert_file_contains "$TEST_TMPDIR/v.log" "mclaude launcher created at" || return 1
    assert_file_contains "$TEST_TMPDIR/v.log" ".local/bin/mclaude"
}
run_test "Linux: ~/.local/bin/mclaude still passes (unchanged)" test_variant_linux_unchanged

test_variant_windows_existing_is_skipped() {
    mkdir -p "$TEST_TMPDIR/vhome/.cc-mirror/bin"
    echo stub > "$TEST_TMPDIR/vhome/.cc-mirror/bin/mclaude.cmd"
    run_variant msys "" || { sed 's/^/    | /' "$TEST_TMPDIR/v.log"; echo "    exited non-zero"; return 1; }
    assert_file_contains "$TEST_TMPDIR/v.log" "already exists" || return 1
    assert_file_not_contains "$TEST_TMPDIR/v.log" "Creating mclaude variant" "no second cc-mirror run"
}
run_test "Git Bash: an existing .cmd launcher is detected and the step skipped" test_variant_windows_existing_is_skipped

test_variant_missing_launcher_still_fails() {
    local rc=0
    run_variant msys "" || rc=$?
    [[ $rc -ne 0 ]] || { echo "    passed although cc-mirror wrote no launcher"; return 1; }
    assert_file_contains "$TEST_TMPDIR/v.log" "not found after creation"
}
run_test "no launcher after cc-mirror → the step still fails loudly" test_variant_missing_launcher_still_fails

# ── Summary ─────────────────────────────────────────────────────────────────
suite_summary
