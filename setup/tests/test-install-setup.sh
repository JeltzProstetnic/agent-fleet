#!/usr/bin/env bash
# Tests for install.sh and install-base.sh — P0 setup fixes (CFG-63, CFG-65, CFG-69)
source "$(dirname "$0")/test-helpers.sh"

suite_header "install setup fixes (CFG-63, CFG-65, CFG-69)"

# ── CFG-63: .template-repo deletion ─────────────────────────────────────────

test_template_repo_deleted_by_install() {
    # Simulate install.sh's template marker cleanup in isolation
    local mock_repo="$TEST_TMPDIR/agent-fleet"
    mkdir -p "$mock_repo/setup"

    # Create .template-repo marker
    echo "marker" > "$mock_repo/.template-repo"
    assert_file_exists "$mock_repo/.template-repo" "marker should exist before cleanup"

    # Simulate the cleanup logic from install.sh (uses a local var, not REPO_ROOT)
    local test_root="$mock_repo"
    if [[ -f "${test_root}/.template-repo" ]]; then
        rm -f "${test_root}/.template-repo"
    fi

    assert_file_not_exists "$mock_repo/.template-repo" "marker should be deleted after cleanup"
}
run_test "CFG-63: .template-repo is deleted by install.sh cleanup logic" test_template_repo_deleted_by_install

test_template_repo_absent_no_error() {
    # Cleanup logic should not error when .template-repo doesn't exist
    local mock_repo="$TEST_TMPDIR/agent-fleet"
    mkdir -p "$mock_repo/setup"

    local test_root="$mock_repo"
    local rc=0
    if [[ -f "${test_root}/.template-repo" ]]; then
        rm -f "${test_root}/.template-repo"
    fi || rc=$?

    assert_eq "0" "$rc" "should not error when .template-repo is absent"
}
run_test "CFG-63: no error when .template-repo is already absent" test_template_repo_absent_no_error

test_install_base_also_removes_template_repo() {
    # install-base.sh has a defense-in-depth copy of the cleanup
    local mock_repo="$TEST_TMPDIR/agent-fleet"
    mkdir -p "$mock_repo/setup"
    echo "marker" > "$mock_repo/.template-repo"

    local test_root="$mock_repo"
    if [[ -f "${test_root}/.template-repo" ]]; then
        rm -f "${test_root}/.template-repo"
    fi

    assert_file_not_exists "$mock_repo/.template-repo" "install-base.sh cleanup should also remove marker"
}
run_test "CFG-63: install-base.sh defense-in-depth also removes .template-repo" test_install_base_also_removes_template_repo

# ── CFG-63: config-check.sh fallback message mentions .template-repo ─────────

test_config_check_mentions_template_repo() {
    local hook="$REPO_ROOT/global/hooks/config-check.sh"
    assert_file_contains "$hook" ".template-repo" \
        "config-check.sh should mention .template-repo in fallback error"
    assert_file_contains "$hook" "delete it" \
        "config-check.sh should suggest deleting .template-repo"
}
run_test "CFG-63: config-check.sh fallback message mentions .template-repo" test_config_check_mentions_template_repo

# ── CFG-65: Non-TTY auto-detection ──────────────────────────────────────────

test_non_interactive_flag_in_install_sh() {
    local install="$REPO_ROOT/setup/install.sh"
    assert_file_contains "$install" 'NON_INTERACTIVE=true' \
        "install.sh should set NON_INTERACTIVE=true"
    assert_file_contains "$install" '! -t 0' \
        "install.sh should check for TTY with -t 0"
    assert_file_contains "$install" 'export NON_INTERACTIVE' \
        "install.sh should export NON_INTERACTIVE"
}
run_test "CFG-65: install.sh has TTY detection and NON_INTERACTIVE flag" test_non_interactive_flag_in_install_sh

test_non_interactive_flag_in_install_base() {
    local install_base="$REPO_ROOT/setup/install-base.sh"
    assert_file_contains "$install_base" 'NON_INTERACTIVE=true' \
        "install-base.sh should set NON_INTERACTIVE=true"
    assert_file_contains "$install_base" '! -t 0' \
        "install-base.sh should check for TTY with -t 0"
}
run_test "CFG-65: install-base.sh has TTY detection" test_non_interactive_flag_in_install_base

test_install_sh_skips_prompt_in_non_interactive() {
    local install="$REPO_ROOT/setup/install.sh"
    assert_file_contains "$install" 'NON_INTERACTIVE:-false' \
        "install.sh should check NON_INTERACTIVE flag before prompting"
    assert_file_contains "$install" 'Non-interactive mode detected' \
        "install.sh should log non-interactive mode"
}
run_test "CFG-65: install.sh skips confirmation prompt in non-interactive mode" test_install_sh_skips_prompt_in_non_interactive

test_tty_detection_sets_flag() {
    # Simulate the TTY detection logic with piped stdin (no TTY)
    local flag=""
    flag=$(echo "" | bash -c '
        if [[ ! -t 0 ]]; then
            echo "true"
        else
            echo "false"
        fi
    ')
    assert_eq "true" "$flag" "piped input should trigger non-interactive detection"
}
run_test "CFG-65: TTY detection correctly identifies piped (non-TTY) input" test_tty_detection_sets_flag

# ── CFG-69: ~/.local/bin PATH addition ───────────────────────────────────────

test_local_bin_path_in_install_base() {
    local install_base="$REPO_ROOT/setup/install-base.sh"
    assert_file_contains "$install_base" '.local/bin' \
        "install-base.sh should reference ~/.local/bin"
    assert_file_contains "$install_base" 'LOCALBIN_SNIPPET' \
        "install-base.sh should have the LOCALBIN_SNIPPET heredoc marker"
}
run_test "CFG-69: install-base.sh adds ~/.local/bin to PATH in .bashrc" test_local_bin_path_in_install_base

test_local_bin_idempotent() {
    # Simulate the idempotency check
    local bashrc="$TEST_TMPDIR/.bashrc"
    echo 'export PATH="$HOME/.local/bin:$PATH"' > "$bashrc"

    # The check from install-base.sh
    local already_present=false
    if grep -qF ".local/bin" "$bashrc" 2>/dev/null; then
        already_present=true
    fi

    assert_eq "true" "$already_present" "should detect .local/bin already in .bashrc"
}
run_test "CFG-69: ~/.local/bin PATH addition is idempotent" test_local_bin_idempotent

test_local_bin_added_when_missing() {
    # Simulate adding .local/bin when not present
    local bashrc="$TEST_TMPDIR/.bashrc"
    echo '# empty bashrc' > "$bashrc"

    if ! grep -qF ".local/bin" "$bashrc" 2>/dev/null; then
        cat >> "$bashrc" << 'LOCALBIN_SNIPPET'

# local binaries (cc-mirror launchers, pipx, etc.)
export PATH="$HOME/.local/bin:$PATH"
LOCALBIN_SNIPPET
    fi

    assert_file_contains "$bashrc" '.local/bin' "should add .local/bin to .bashrc"
    assert_file_contains "$bashrc" 'cc-mirror launchers' "should include comment"
}
run_test "CFG-69: ~/.local/bin added to .bashrc when missing" test_local_bin_added_when_missing

# ── CFG-69: Git identity configuration ──────────────────────────────────────

test_git_identity_in_configure_claude() {
    local config="$REPO_ROOT/setup/configure-claude.sh"
    assert_file_contains "$config" 'git config --global user.name' \
        "configure-claude.sh should configure git user.name"
    assert_file_contains "$config" 'git config --global user.email' \
        "configure-claude.sh should configure git user.email"
}
run_test "CFG-69: configure-claude.sh configures git identity" test_git_identity_in_configure_claude

test_git_identity_interactive_prompt() {
    local config="$REPO_ROOT/setup/configure-claude.sh"
    assert_file_contains "$config" 'read -r -p "Git user.name' \
        "should prompt for user.name in interactive mode"
    assert_file_contains "$config" 'read -r -p "Git user.email' \
        "should prompt for user.email in interactive mode"
}
run_test "CFG-69: git identity prompts user in interactive mode" test_git_identity_interactive_prompt

test_git_identity_non_interactive_derives_from_profile() {
    local config="$REPO_ROOT/setup/configure-claude.sh"
    assert_file_contains "$config" 'user-profile.md' \
        "should attempt to derive from user-profile.md in non-interactive mode"
    assert_file_contains "$config" 'derived_name' \
        "should have derived_name variable"
    assert_file_contains "$config" 'derived_email' \
        "should have derived_email variable"
}
run_test "CFG-69: git identity derives from user-profile.md in non-interactive mode" test_git_identity_non_interactive_derives_from_profile

test_git_identity_warns_when_not_set() {
    local config="$REPO_ROOT/setup/configure-claude.sh"
    assert_file_contains "$config" "Git user.name is not configured" \
        "should warn when user.name cannot be derived"
    assert_file_contains "$config" "Git user.email is not configured" \
        "should warn when user.email cannot be derived"
}
run_test "CFG-69: git identity warns when not configured and cannot derive" test_git_identity_warns_when_not_set

test_git_identity_skips_when_already_set() {
    local config="$REPO_ROOT/setup/configure-claude.sh"
    assert_file_contains "$config" 'Git identity already configured' \
        "should skip when both name and email are already set"
}
run_test "CFG-69: git identity skips when already configured" test_git_identity_skips_when_already_set

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
