#!/usr/bin/env bash
# Tests for ensure_local_bin_path (setup/lib.sh) — CFG-336, CFG-1087 slice 1
# agent-fleet GH#3: `afleet: command not found` after a Git Bash install, because ~/.local/bin is
# not on the MINGW64 PATH and nothing put it there. configure-claude.sh carried the fix inline
# and untested; it is now one function, used by the installer and verified on a fresh shell.
source "$(dirname "$0")/test-helpers.sh"

LIB_SH="$REPO_ROOT/setup/lib.sh"
CONFIGURE_SH="$REPO_ROOT/setup/configure-claude.sh"
MARKER="# agent-fleet: local bin path"

suite_header "ensure_local_bin_path (CFG-336: ~/.local/bin on PATH for new shells)"

# _run <rc-file> <PATH value for the call> [DRY_RUN] — runs the function in a clean subshell
_run() {
    (
        export NO_COLOR=true DRY_RUN="${3:-false}"
        # shellcheck disable=SC1090
        source "$LIB_SH"
        BACKUP_ROOT="$TEST_TMPDIR/bak"
        PATH="$2"
        ensure_local_bin_path "$1"
    )
}

# _on_path_in_fresh_shell <rc-file> — "on-path" when a shell that sources <rc-file> has ~/.local/bin on PATH
_on_path_in_fresh_shell() {
    PATH=/usr/bin:/bin bash -c "source '$1'; case \":\$PATH:\" in *\":$HOME/.local/bin:\"*) echo on-path ;; *) echo missing ;; esac"
}

test_function_exists() {
    local t
    t=$(bash -c "NO_COLOR=true; source '$LIB_SH'; type -t ensure_local_bin_path" 2>/dev/null || true)
    assert_eq "function" "$t" "ensure_local_bin_path is defined by setup/lib.sh"
}
run_test "ensure_local_bin_path is defined in setup/lib.sh" test_function_exists

test_appends_block_and_fresh_shell_sees_it() {
    local rc="$TEST_TMPDIR/.bashrc"
    echo '# empty' > "$rc"
    _run "$rc" "/usr/bin:/bin" > "$TEST_TMPDIR/out.log" 2>&1 || { cat "$TEST_TMPDIR/out.log"; return 1; }
    assert_file_contains "$rc" "$MARKER" "marker line written" || return 1
    assert_file_contains "$rc" 'export PATH="$HOME/.local/bin:$PATH"' "PATH export written" || return 1
    assert_eq "on-path" "$(_on_path_in_fresh_shell "$rc")" "a fresh shell sourcing the rc file has ~/.local/bin on PATH" || return 1
    assert_file_contains "$TEST_TMPDIR/out.log" "Added" "the installer says what it did"
}
run_test "adds the PATH block when ~/.local/bin is missing — and a fresh shell sees it" test_appends_block_and_fresh_shell_sees_it

test_idempotent() {
    local rc="$TEST_TMPDIR/.bashrc"
    echo '# empty' > "$rc"
    _run "$rc" "/usr/bin:/bin" >/dev/null 2>&1 || return 1
    _run "$rc" "/usr/bin:/bin" >/dev/null 2>&1 || return 1
    assert_grep_count "$rc" "local bin path" 1 "second call adds nothing"
}
run_test "a second call adds nothing (marker present)" test_idempotent

test_skips_when_already_on_path() {
    local rc="$TEST_TMPDIR/.bashrc"
    echo '# empty' > "$rc"
    _run "$rc" "$HOME/.local/bin:/usr/bin:/bin" >/dev/null 2>&1 || return 1
    assert_file_not_contains "$rc" "local bin path" "rc untouched when the directory is already on PATH" || return 1
    assert_eq "# empty" "$(cat "$rc")" "rc content unchanged"
}
run_test "skips when ~/.local/bin is already on this shell's PATH (Linux default)" test_skips_when_already_on_path

test_creates_missing_rc_file() {
    local rc="$TEST_TMPDIR/.bashrc"
    [ -f "$rc" ] && rm -f "$rc"
    _run "$rc" "/usr/bin:/bin" >/dev/null 2>&1 || return 1
    assert_file_exists "$rc" "rc file created when absent" || return 1
    assert_eq "on-path" "$(_on_path_in_fresh_shell "$rc")"
}
run_test "creates the rc file when it does not exist yet" test_creates_missing_rc_file

test_dry_run_writes_nothing() {
    local rc="$TEST_TMPDIR/.bashrc"
    echo '# empty' > "$rc"
    _run "$rc" "/usr/bin:/bin" true > "$TEST_TMPDIR/out.log" 2>&1 || { cat "$TEST_TMPDIR/out.log"; return 1; }
    assert_eq "# empty" "$(cat "$rc")" "dry run leaves the rc file alone" || return 1
    assert_file_contains "$TEST_TMPDIR/out.log" "DRY RUN" "dry run says what it would do"
}
run_test "dry run writes nothing and says so" test_dry_run_writes_nothing

test_configure_claude_uses_the_function() {
    local calls inline
    calls=$(grep -c 'ensure_local_bin_path' "$CONFIGURE_SH" || true)
    inline=$(grep -c "$MARKER" "$CONFIGURE_SH" || true)
    [[ "$calls" -ge 1 ]] || { echo "    configure-claude.sh does not call ensure_local_bin_path"; return 1; }
    assert_eq "0" "$inline" "configure-claude.sh no longer carries the inline block (found $inline)"
}
run_test "configure-claude.sh calls ensure_local_bin_path instead of an inline block" test_configure_claude_uses_the_function

suite_summary
