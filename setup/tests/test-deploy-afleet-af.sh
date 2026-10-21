#!/usr/bin/env bash
# Tests for deploy_afleet's `af` shortcut (sync-lib/deploy.sh) in the REAL flows (CFG-507 repair)
#
# install.sh Phase 3 runs `sync.sh setup` (→ deploy_afleet) BEFORE its own af block, and every
# SessionEnd `sync.sh deploy` runs deploy_afleet again. deploy_afleet used to link
# ~/.local/bin/af whenever the path was absent, with no PATH check — so by the time the
# installer's guard (install_af_shortcut, setup/lib.sh) ran, the target was already "our" link:
# an unrelated af on PATH was shadowed with no warning, and deploy re-created the link after
# the installer skipped it. These run the REAL deploy_afleet and the REAL install.sh block.
# (Cat-3: sync-lib/ is not template-tracked — CFG-607. The Cat-1 half is test-install-af-shortcut.sh.)
source "$(dirname "$0")/test-helpers.sh"

suite_header "deploy_afleet af shortcut (CFG-507: sync.sh setup/deploy never shadow an unrelated af)"

# deploy_afleet in a sandbox HOME, as sync.sh setup/deploy call it (writes only under HOME).
run_deploy_afleet() {
    local ostype="${1:-linux-gnu}"
    mkdir -p "$TEST_TMPDIR/home/.local/bin"
    (
        export HOME="$TEST_TMPDIR/home"
        unset WSL_DISTRO_NAME
        OSTYPE="$ostype"
        PATH="$HOME/.local/bin:${EXTRA_PATH:-}:/usr/bin:/bin"
        SCRIPT_DIR="$REPO_ROOT"; GLOBAL_DIR="$REPO_ROOT/global"; PLATFORM=linux
        log_info()  { echo "[INFO] $*"; }
        log_warn()  { echo "[WARN] $*"; }
        log_error() { echo "[ERROR] $*"; }
        # shellcheck disable=SC1091
        source "$REPO_ROOT/sync-lib/common.sh"
        # shellcheck disable=SC1091
        source "$REPO_ROOT/sync-lib/deploy.sh"
        deploy_afleet
    ) >> "$TEST_TMPDIR/deploy.log" 2>&1
}

# install.sh's af block plus its closing summary, extracted verbatim, in the same sandbox.
run_installer_af_block() {
    local ostype="${1:-linux-gnu}" installer="$REPO_ROOT/setup/install.sh" code
    code="$(sed -n '/^# `af` is the standard fleet shortcut/,/^fi$/p' "$installer")
$(sed -n '/^print_header "Installation Complete!"/,$p' "$installer")"
    [[ "$code" == *install_af_shortcut* ]] || { echo "    could not extract the af block from install.sh"; return 1; }
    (
        export HOME="$TEST_TMPDIR/home" NO_COLOR=true
        # shellcheck disable=SC1091
        source "$REPO_ROOT/setup/lib.sh"
        set +e
        OSTYPE="$ostype"
        PATH="$HOME/.local/bin:${EXTRA_PATH:-}:/usr/bin:/bin"
        CONFIG_REPO_ROOT="$REPO_ROOT"
        eval "$code"
    ) > "$TEST_TMPDIR/installer.log" 2>&1
}

# deploy_aliases in the same sandbox — the OTHER af writer in the same `sync.sh setup` / `deploy`
# run: it copies setup/config/aliases.sh to ~/.cfg-aliases.sh and sources it from ~/.bashrc.
run_deploy_aliases() {
    mkdir -p "$TEST_TMPDIR/home"
    (
        export HOME="$TEST_TMPDIR/home"
        SCRIPT_DIR="$REPO_ROOT"; GLOBAL_DIR="$REPO_ROOT/global"; PLATFORM=linux
        log_info()  { echo "[INFO] $*"; }
        log_warn()  { echo "[WARN] $*"; }
        log_error() { echo "[ERROR] $*"; }
        # shellcheck disable=SC1091
        source "$REPO_ROOT/sync-lib/common.sh"
        # shellcheck disable=SC1091
        source "$REPO_ROOT/sync-lib/deploy.sh"
        deploy_aliases
    ) >> "$TEST_TMPDIR/deploy.log" 2>&1
}

# What an INTERACTIVE shell in the sandbox runs for `af` — where af is actually typed. It reads
# the sandbox ~/.bashrc, so it sees everything deploy_aliases wired in.
interactive_type_af() {
    env -i HOME="$TEST_TMPDIR/home" TERM=dumb \
        PATH="$TEST_TMPDIR/home/.local/bin:${EXTRA_PATH:-}:/usr/bin:/bin" \
        bash -ic 'type af' 2>/dev/null | tail -n 1
}

make_other_af() {
    mkdir -p "$TEST_TMPDIR/other"
    printf '#!/bin/sh\necho users-own-af\n' > "$TEST_TMPDIR/other/af"
    chmod +x "$TEST_TMPDIR/other/af"
}

resolve_af() {
    ( PATH="$TEST_TMPDIR/home/.local/bin:${EXTRA_PATH:-}:/usr/bin:/bin"; command -v af )
}

test_installer_order_never_shadows() {
    make_other_af
    local EXTRA_PATH="$TEST_TMPDIR/other" af="$TEST_TMPDIR/home/.local/bin/af"
    run_deploy_afleet                      # sync.sh setup, Phase 3's first step
    [[ ! -e "$af" && ! -L "$af" ]] || { echo "    deploy_afleet created af although another af is on PATH"; return 1; }
    assert_file_contains "$TEST_TMPDIR/deploy.log" "$TEST_TMPDIR/other/af" || return 1
    run_installer_af_block || return 1     # then install.sh's own af block
    [[ ! -e "$af" && ! -L "$af" ]] || { echo "    the installer created af although another af is on PATH"; return 1; }
    assert_file_contains "$TEST_TMPDIR/installer.log" "$TEST_TMPDIR/other/af" || return 1
    assert_file_not_contains "$TEST_TMPDIR/installer.log" "Run: af " || return 1
    run_deploy_afleet                      # a later SessionEnd `sync.sh deploy`
    [[ ! -e "$af" && ! -L "$af" ]] || { echo "    a later deploy re-created af after the installer skipped it"; return 1; }
    assert_eq "$TEST_TMPDIR/other/af" "$(resolve_af)" "the user's own af still resolves"
}
run_test "real order (sync.sh setup → installer → deploy): an unrelated af on PATH is never shadowed" \
    test_installer_order_never_shadows

test_earlier_link_is_withdrawn() {
    # A machine where an earlier (unguarded) deploy already linked af → afleet (absolute, via
    # _link_file) while the user's own af sits later on PATH: ours, so removed — not refreshed.
    make_other_af
    local EXTRA_PATH="$TEST_TMPDIR/other" af="$TEST_TMPDIR/home/.local/bin/af"
    mkdir -p "$TEST_TMPDIR/home/.local/bin"
    ln -s "$TEST_TMPDIR/home/.local/bin/afleet" "$af"
    run_deploy_afleet
    [[ ! -e "$af" && ! -L "$af" ]] || { echo "    our old af link still shadows the user's af"; return 1; }
    assert_file_contains "$TEST_TMPDIR/deploy.log" "$TEST_TMPDIR/other/af" || return 1
    assert_eq "$TEST_TMPDIR/other/af" "$(resolve_af)"
}
run_test "deploy withdraws its own earlier af link when an unrelated af is on PATH" test_earlier_link_is_withdrawn

test_deploy_leaves_dangling_unrelated_link() {
    # deploy_afleet's old `[ ! -e af ]` guard is true for a DANGLING link, and ln -sf then
    # replaced the user's (broken) link with ours.
    local af="$TEST_TMPDIR/home/.local/bin/af"
    mkdir -p "$TEST_TMPDIR/home/.local/bin"
    ln -s /nonexistent/users-own-af "$af"
    run_deploy_afleet
    assert_eq "/nonexistent/users-own-af" "$(readlink "$af")"
}
run_test "deploy leaves an unrelated (dangling) af symlink alone" test_deploy_leaves_dangling_unrelated_link

test_deploy_leaves_unrelated_file() {
    local af="$TEST_TMPDIR/home/.local/bin/af"
    mkdir -p "$TEST_TMPDIR/home/.local/bin"
    printf '#!/bin/sh\necho my-own-af-tool\n' > "$af"; chmod +x "$af"
    run_deploy_afleet
    [[ ! -L "$af" ]] || { echo "    the user's af was replaced by a link"; return 1; }
    assert_file_contains "$af" "my-own-af-tool"
}
run_test "deploy leaves an unrelated af file at the target alone" test_deploy_leaves_unrelated_file

test_no_conflict_deploy_then_installer() {
    local af="$TEST_TMPDIR/home/.local/bin/af"
    run_deploy_afleet
    [[ -L "$af" ]] || { echo "    deploy_afleet did not create the af link"; return 1; }
    assert_eq "$(cd "$TEST_TMPDIR/home/.local/bin" && pwd -P)/afleet" \
        "$(cd "$TEST_TMPDIR/home/.local/bin" && readlink -f af)" "af resolves to the deployed afleet" || return 1
    run_installer_af_block || return 1
    [[ -L "$af" ]] || { echo "    the installer removed af"; return 1; }
    assert_file_not_contains "$TEST_TMPDIR/installer.log" "Skipped 'af'" || return 1
    assert_file_contains "$TEST_TMPDIR/installer.log" "Run: af "
}
run_test "no conflict: deploy links af → afleet, installer keeps it and says 'Run: af'" \
    test_no_conflict_deploy_then_installer

test_msys_af_is_wrapper_copy() {
    # On MSYS/Cygwin af is a copy of the self-contained afleet-wrapper.sh (what deploy_afleet
    # copies to ~/.local/bin/afleet); neither deploy nor installer turns it into raw afleet.sh.
    local af="$TEST_TMPDIR/home/.local/bin/af" wrapper="$REPO_ROOT/setup/scripts/afleet-wrapper.sh"
    run_deploy_afleet msys
    [[ -f "$af" && ! -L "$af" ]] || { echo "    deploy did not copy af"; return 1; }
    cmp -s "$wrapper" "$af" || { echo "    deploy's af copy is not afleet-wrapper.sh"; return 1; }
    run_installer_af_block msys || return 1
    cmp -s "$wrapper" "$af" || { echo "    the installer replaced the wrapper copy with something else"; return 1; }
}
run_test "MSYS: af is a copy of afleet-wrapper.sh, from both deploy and installer" test_msys_af_is_wrapper_copy

test_interactive_shell_never_shadows() {
    # ⛔ The link was guarded, but the same run's deploy_aliases shipped an unconditional
    #    `alias af='afleet'` into ~/.cfg-aliases.sh and sourced it from ~/.bashrc: the user's own
    #    af stayed shadowed in every interactive shell while deploy said "Skipped 'af' shortcut".
    make_other_af
    local EXTRA_PATH="$TEST_TMPDIR/other"
    run_deploy_afleet
    run_deploy_aliases
    assert_file_contains "$TEST_TMPDIR/home/.bashrc" "cfg-aliases.sh" || return 1
    assert_file_contains "$TEST_TMPDIR/deploy.log" "Skipped 'af' shortcut" || return 1
    assert_eq "af is $TEST_TMPDIR/other/af" "$(interactive_type_af)" "what an interactive shell runs for af"
}
run_test "setup/deploy (deploy_afleet + deploy_aliases): an interactive shell still runs the user's own af" \
    test_interactive_shell_never_shadows

test_interactive_shell_af_without_conflict() {
    # With nothing in the way, af still works interactively — through the guarded link.
    run_deploy_afleet
    run_deploy_aliases
    assert_eq "af is $TEST_TMPDIR/home/.local/bin/af" "$(interactive_type_af)" "interactive af"
}
run_test "no conflict: an interactive shell runs af through the deployed link" \
    test_interactive_shell_af_without_conflict

suite_summary
