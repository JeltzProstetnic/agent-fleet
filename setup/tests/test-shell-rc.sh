#!/usr/bin/env bash
# Tests for detect_shell_rc() — macOS .zshrc / Linux .bashrc detection
source "$(dirname "$0")/test-helpers.sh"

suite_header "detect_shell_rc — Shell RC File Detection"

# Source lib.sh for the function under test
source "$REPO_ROOT/setup/lib.sh"

# ── Test: returns .zshrc on macOS ─────────────────────────────────────────────

test_zshrc_on_macos() {
    # Mock detect_distro to return macos
    local orig_distro="$DETECTED_DISTRO"
    DETECTED_DISTRO="macos"

    local result
    result=$(HOME="$TEST_TMPDIR" detect_shell_rc)
    assert_eq "$TEST_TMPDIR/.zshrc" "$result" "macOS should default to .zshrc"

    DETECTED_DISTRO="$orig_distro"
}
run_test "detect_shell_rc returns .zshrc on macOS" test_zshrc_on_macos

# ── Test: returns .zshrc when SHELL is zsh ────────────────────────────────────

test_zshrc_when_shell_is_zsh() {
    local orig_distro="$DETECTED_DISTRO"
    DETECTED_DISTRO="debian"

    local orig_shell="${SHELL:-}"
    SHELL="/usr/bin/zsh"

    local result
    result=$(HOME="$TEST_TMPDIR" detect_shell_rc)
    assert_eq "$TEST_TMPDIR/.zshrc" "$result" "zsh SHELL should return .zshrc"

    SHELL="$orig_shell"
    DETECTED_DISTRO="$orig_distro"
}
run_test "detect_shell_rc returns .zshrc when SHELL ends in zsh" test_zshrc_when_shell_is_zsh

# ── Test: returns .bashrc on Linux with bash ──────────────────────────────────

test_bashrc_on_linux_bash() {
    local orig_distro="$DETECTED_DISTRO"
    DETECTED_DISTRO="debian"

    local orig_shell="${SHELL:-}"
    SHELL="/bin/bash"

    local result
    result=$(HOME="$TEST_TMPDIR" detect_shell_rc)
    assert_eq "$TEST_TMPDIR/.bashrc" "$result" "Linux + bash should return .bashrc"

    SHELL="$orig_shell"
    DETECTED_DISTRO="$orig_distro"
}
run_test "detect_shell_rc returns .bashrc on Linux with bash" test_bashrc_on_linux_bash

# ── Test: returns .bashrc on Fedora with bash ─────────────────────────────────

test_bashrc_on_fedora() {
    local orig_distro="$DETECTED_DISTRO"
    DETECTED_DISTRO="fedora"

    local orig_shell="${SHELL:-}"
    SHELL="/bin/bash"

    local result
    result=$(HOME="$TEST_TMPDIR" detect_shell_rc)
    assert_eq "$TEST_TMPDIR/.bashrc" "$result" "Fedora + bash should return .bashrc"

    SHELL="$orig_shell"
    DETECTED_DISTRO="$orig_distro"
}
run_test "detect_shell_rc returns .bashrc on Fedora" test_bashrc_on_fedora

# ── Test: returns .zshrc on Arch when SHELL is zsh ────────────────────────────

test_zshrc_on_arch_with_zsh() {
    local orig_distro="$DETECTED_DISTRO"
    DETECTED_DISTRO="arch"

    local orig_shell="${SHELL:-}"
    SHELL="/usr/bin/zsh"

    local result
    result=$(HOME="$TEST_TMPDIR" detect_shell_rc)
    assert_eq "$TEST_TMPDIR/.zshrc" "$result" "Arch + zsh should return .zshrc"

    SHELL="$orig_shell"
    DETECTED_DISTRO="$orig_distro"
}
run_test "detect_shell_rc returns .zshrc on Arch with zsh SHELL" test_zshrc_on_arch_with_zsh

# ── Test: shell_rc_name returns just the filename ─────────────────────────────

test_shell_rc_name() {
    local orig_distro="$DETECTED_DISTRO"
    DETECTED_DISTRO="macos"

    local result
    result=$(detect_shell_rc_name)
    assert_eq ".zshrc" "$result" "macOS should return .zshrc name"

    DETECTED_DISTRO="debian"
    SHELL="/bin/bash"
    result=$(detect_shell_rc_name)
    assert_eq ".bashrc" "$result" "Linux+bash should return .bashrc name"

    DETECTED_DISTRO="$orig_distro"
}
run_test "detect_shell_rc_name returns just the filename" test_shell_rc_name

# ── Test: install-base.sh uses detect_shell_rc ────────────────────────────────

test_install_base_uses_detect() {
    local script="$REPO_ROOT/setup/install-base.sh"
    assert_file_contains "$script" "detect_shell_rc" "install-base.sh should use detect_shell_rc"
}
run_test "install-base.sh uses detect_shell_rc" test_install_base_uses_detect

# ── Test: configure-claude.sh uses detect_shell_rc ────────────────────────────

test_configure_uses_detect() {
    local script="$REPO_ROOT/setup/configure-claude.sh"
    assert_file_contains "$script" "detect_shell_rc" "configure-claude.sh should use detect_shell_rc"
}
run_test "configure-claude.sh uses detect_shell_rc" test_configure_uses_detect

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
