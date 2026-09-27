#!/usr/bin/env bash
# Tests for install_af_shortcut (setup/lib.sh) — the standard `af` fleet shortcut (CFG-507)
source "$(dirname "$0")/test-helpers.sh"

suite_header "install_af_shortcut (CFG-507: af is the standard shortcut, never clobbering)"

# Run the function in a clean subshell: a sandbox bin dir, a PATH that holds only it plus
# the system dirs, and a fake afleet.sh source. Status 0 = installed; non-zero = skipped,
# with the conflicting path on stdout (captured in out.log) for the installer's warning.
run_af() {
    local ostype="${1:-linux-gnu}"
    mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/repo/setup/scripts"
    [[ -f "$TEST_TMPDIR/repo/setup/scripts/afleet.sh" ]] \
        || printf '#!/usr/bin/env bash\n# afleet — unified agent fleet launcher\necho afleet\n' > "$TEST_TMPDIR/repo/setup/scripts/afleet.sh"
    (
        export NO_COLOR=true
        # shellcheck disable=SC1091
        source "$REPO_ROOT/setup/lib.sh"
        OSTYPE="$ostype"
        PATH="$TEST_TMPDIR/bin:${EXTRA_PATH:-}:/usr/bin:/bin"
        install_af_shortcut "$TEST_TMPDIR/repo/setup/scripts/afleet.sh" "$TEST_TMPDIR/bin/af"
    ) > "$TEST_TMPDIR/out.log" 2>&1
}

test_fresh_install_creates_af() {
    run_af || return 1
    [[ -L "$TEST_TMPDIR/bin/af" ]] || { echo "    af is not a symlink"; return 1; }
    assert_eq "afleet" "$(readlink "$TEST_TMPDIR/bin/af")"
}
run_test "fresh install: af -> afleet symlink is created" test_fresh_install_creates_af

test_own_symlink_is_refreshed() {
    mkdir -p "$TEST_TMPDIR/bin"
    ln -s afleet "$TEST_TMPDIR/bin/af"
    run_af || { echo "    reported a conflict with its own link"; return 1; }
    assert_eq "afleet" "$(readlink "$TEST_TMPDIR/bin/af")"
}
run_test "an existing af -> afleet symlink is ours and is kept" test_own_symlink_is_refreshed

test_own_absolute_symlink_is_ours() {
    mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/elsewhere/setup/scripts"
    ln -s "$TEST_TMPDIR/elsewhere/setup/scripts/afleet.sh" "$TEST_TMPDIR/bin/af"
    run_af || return 1
    assert_eq "afleet" "$(readlink "$TEST_TMPDIR/bin/af")" "a hand-made link to afleet.sh is replaced by the standard one"
}
run_test "a hand-made af -> .../afleet.sh link counts as ours" test_own_absolute_symlink_is_ours

test_unrelated_file_is_not_clobbered() {
    # ⛔ install.sh replaced ANY existing ~/.local/bin/af with its symlink — the guard only
    #    looked for an `af` elsewhere on PATH, so a user's own tool at the target was lost.
    mkdir -p "$TEST_TMPDIR/bin"
    printf '#!/bin/sh\necho my-own-af-tool\n' > "$TEST_TMPDIR/bin/af"
    chmod +x "$TEST_TMPDIR/bin/af"
    run_af && { echo "    no conflict reported"; return 1; }
    [[ ! -L "$TEST_TMPDIR/bin/af" ]] || { echo "    the user's af was replaced by a symlink"; return 1; }
    assert_file_contains "$TEST_TMPDIR/bin/af" "my-own-af-tool" || return 1
    assert_file_contains "$TEST_TMPDIR/out.log" "$TEST_TMPDIR/bin/af"
}
run_test "an unrelated af file at the target is not clobbered" test_unrelated_file_is_not_clobbered

test_unrelated_symlink_is_not_clobbered() {
    mkdir -p "$TEST_TMPDIR/bin"
    ln -s /bin/true "$TEST_TMPDIR/bin/af"
    run_af && { echo "    no conflict reported"; return 1; }
    assert_eq "/bin/true" "$(readlink "$TEST_TMPDIR/bin/af")"
}
run_test "an unrelated af symlink at the target is not clobbered" test_unrelated_symlink_is_not_clobbered

test_unrelated_af_elsewhere_on_path_wins() {
    mkdir -p "$TEST_TMPDIR/other"
    printf '#!/bin/sh\necho other\n' > "$TEST_TMPDIR/other/af"
    chmod +x "$TEST_TMPDIR/other/af"
    EXTRA_PATH="$TEST_TMPDIR/other" run_af && { echo "    no conflict reported"; return 1; }
    [[ ! -e "$TEST_TMPDIR/bin/af" && ! -L "$TEST_TMPDIR/bin/af" ]] \
        || { echo "    af was created although another af is on PATH"; return 1; }
    assert_file_contains "$TEST_TMPDIR/out.log" "$TEST_TMPDIR/other/af"
}
run_test "an unrelated af elsewhere on PATH: skipped with a warning" test_unrelated_af_elsewhere_on_path_wins

test_windows_copy_mode() {
    run_af msys || return 1
    [[ -f "$TEST_TMPDIR/bin/af" && ! -L "$TEST_TMPDIR/bin/af" ]] || { echo "    not a copied file"; return 1; }
    cmp -s "$TEST_TMPDIR/repo/setup/scripts/afleet.sh" "$TEST_TMPDIR/bin/af" || { echo "    copy differs"; return 1; }
    # After an upgrade the old copy no longer matches the source byte-for-byte; a re-run
    # still recognises it as ours (by afleet's own header) and refreshes it.
    printf '#!/usr/bin/env bash\n# afleet — unified agent fleet launcher\necho afleet v2\n' \
        > "$TEST_TMPDIR/repo/setup/scripts/afleet.sh"
    run_af msys || return 1
    assert_file_contains "$TEST_TMPDIR/bin/af" "afleet v2"
}
run_test "MSYS/Cygwin: af is a copy, refreshed on re-run" test_windows_copy_mode

test_installer_uses_the_function() {
    local installer="$REPO_ROOT/setup/install.sh"
    grep -q 'install_af_shortcut ' "$installer" || { echo "    install.sh does not call install_af_shortcut"; return 1; }
    grep -q '^_af_target=' "$installer" && { echo "    the old inline af block is still in install.sh"; return 1; }
    grep -q "unrelated 'af' already exists" "$installer" || { echo "    install.sh lost its skip warning"; return 1; }
    # Onboarding presents af as the primary command, afleet as the long form.
    grep -q 'Run: af ' "$installer"
}
run_test "install.sh calls it and tells the user to run 'af'" test_installer_uses_the_function

# ── The installer block itself (CFG-507 repair) ─────────────────────────────────
# install.sh's af block plus its closing summary, extracted verbatim, in a sandbox HOME.
# (The deploy_afleet side of the real order — `sync.sh setup` runs it BEFORE this block —
# lives in test-deploy-afleet-af.sh: its subject sync-lib/ is not template-tracked.)
run_installer_af_block() {
    local ostype="${1:-linux-gnu}" installer="$REPO_ROOT/setup/install.sh" code
    code="$(sed -n '/^# `af` is the standard fleet shortcut/,/^fi$/p' "$installer")
$(sed -n '/^print_header "Installation Complete!"/,$p' "$installer")"
    [[ "$code" == *install_af_shortcut* ]] || { echo "    could not extract the af block from install.sh"; return 1; }
    mkdir -p "$TEST_TMPDIR/home"
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

make_other_af() {
    mkdir -p "$TEST_TMPDIR/other"
    printf '#!/bin/sh\necho users-own-af\n' > "$TEST_TMPDIR/other/af"
    chmod +x "$TEST_TMPDIR/other/af"
}

test_unit_own_link_withdrawn() {
    # A link an earlier, unguarded deploy made while the user's own af sits on PATH: it is
    # ours, so it is withdrawn (not refreshed) — otherwise it keeps shadowing that af.
    make_other_af
    mkdir -p "$TEST_TMPDIR/bin"
    ln -s afleet "$TEST_TMPDIR/bin/af"
    EXTRA_PATH="$TEST_TMPDIR/other" run_af && { echo "    no conflict reported"; return 1; }
    [[ ! -e "$TEST_TMPDIR/bin/af" && ! -L "$TEST_TMPDIR/bin/af" ]] || { echo "    own link kept"; return 1; }
    assert_file_contains "$TEST_TMPDIR/out.log" "$TEST_TMPDIR/other/af"
}
run_test "own af link + unrelated af elsewhere on PATH: link withdrawn, conflict reported" \
    test_unit_own_link_withdrawn

test_installer_skip_hint_says_afleet() {
    make_other_af
    local EXTRA_PATH="$TEST_TMPDIR/other" af="$TEST_TMPDIR/home/.local/bin/af"
    run_installer_af_block || return 1
    [[ ! -e "$af" && ! -L "$af" ]] || { echo "    the installer created af although another af is on PATH"; return 1; }
    assert_file_contains "$TEST_TMPDIR/installer.log" "$TEST_TMPDIR/other/af" || return 1
    # The closing hint must not tell the user to run `af` — that would start their own tool.
    assert_file_not_contains "$TEST_TMPDIR/installer.log" "Run: af " || return 1
    assert_file_contains "$TEST_TMPDIR/installer.log" "Run: afleet"
}
run_test "installer skipped af: the closing hint says 'Run: afleet', not 'Run: af'" \
    test_installer_skip_hint_says_afleet

test_installer_ok_hint_says_af() {
    run_installer_af_block || return 1
    [[ -L "$TEST_TMPDIR/home/.local/bin/af" ]] || { echo "    af was not created"; return 1; }
    assert_file_not_contains "$TEST_TMPDIR/installer.log" "Skipped 'af'" || return 1
    assert_file_contains "$TEST_TMPDIR/installer.log" "Run: af "
}
run_test "installer installed af: the closing hint says 'Run: af'" test_installer_ok_hint_says_af

test_installer_msys_copies_wrapper() {
    # On MSYS/Cygwin af is a copy. It must be the self-contained afleet-wrapper.sh: a raw
    # afleet.sh copy resolves its own directory to ~/.local/bin, finds no afleet-lib.sh
    # there and falls into the DEGRADED launch.
    local af="$TEST_TMPDIR/home/.local/bin/af"
    run_installer_af_block msys || return 1
    [[ -f "$af" && ! -L "$af" ]] || { echo "    af is not a copied file"; return 1; }
    cmp -s "$REPO_ROOT/setup/scripts/afleet-wrapper.sh" "$af" || { echo "    af is not a copy of afleet-wrapper.sh"; return 1; }
}
run_test "installer on MSYS: af is a copy of afleet-wrapper.sh, not raw afleet.sh" test_installer_msys_copies_wrapper

suite_summary
