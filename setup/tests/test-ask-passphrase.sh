#!/usr/bin/env bash
# Tests for setup/scripts/ask-passphrase.sh — cross-platform masked passphrase dialog
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/ask-passphrase.sh"

suite_header "ask-passphrase.sh (passphrase dialog)"

# ── 1. Detection logic ──────────────────────────────────────────────────────

test_detect_powershell_wpf_on_wsl_no_tty() {
    # Simulate: no TTY + WSL proc/version
    local fake_proc="$TEST_TMPDIR/proc_version"
    echo "Linux version 6.6.87.2-microsoft-standard-WSL2" > "$fake_proc"

    # Source the script's functions
    ASK_PASS_SOURCE_ONLY=1 source "$SCRIPT"

    local method
    method=$(_ASK_PASS_PROC_VERSION="$fake_proc" _ASK_PASS_HAS_TTY=false _detect_method)
    assert_eq "powershell_wpf" "$method" \
        "no-TTY + WSL should select powershell_wpf"
}
run_test "detects PowerShell WPF on WSL without TTY" test_detect_powershell_wpf_on_wsl_no_tty

test_detect_read_on_wsl_with_tty() {
    local fake_proc="$TEST_TMPDIR/proc_version"
    echo "Linux version 6.6.87.2-microsoft-standard-WSL2" > "$fake_proc"

    ASK_PASS_SOURCE_ONLY=1 source "$SCRIPT"

    # With TTY, should NOT force PowerShell — fall through to normal detection
    # (no kdialog/zenity/osascript in test env → falls to "read")
    local method
    method=$(_ASK_PASS_PROC_VERSION="$fake_proc" _ASK_PASS_HAS_TTY=true _detect_method)
    assert_neq "powershell_wpf" "$method" \
        "WSL with TTY should NOT select powershell_wpf"
}
run_test "does NOT select PowerShell WPF on WSL with TTY" test_detect_read_on_wsl_with_tty

test_detect_read_on_linux_no_tty() {
    # No TTY but not WSL → can't use PowerShell, falls to GUI tool or read
    local fake_proc="$TEST_TMPDIR/proc_version"
    echo "Linux version 6.1.0-generic" > "$fake_proc"

    ASK_PASS_SOURCE_ONLY=1 source "$SCRIPT"

    local method
    method=$(_ASK_PASS_PROC_VERSION="$fake_proc" _ASK_PASS_HAS_TTY=false _detect_method)
    # On headless systems falls to "read"; on KDE/GNOME desktops picks kdialog/zenity
    assert_neq "powershell_wpf" "$method" \
        "no-TTY on non-WSL Linux should NOT select powershell_wpf"
}
run_test "falls back to read or GUI on non-WSL Linux without TTY" test_detect_read_on_linux_no_tty

test_detect_no_proc_version_file() {
    # /proc/version doesn't exist (macOS, containers)
    ASK_PASS_SOURCE_ONLY=1 source "$SCRIPT"

    local method
    method=$(_ASK_PASS_PROC_VERSION="/nonexistent/proc_version" _ASK_PASS_HAS_TTY=false _detect_method)
    assert_neq "powershell_wpf" "$method" \
        "missing /proc/version should NOT select powershell_wpf"
}
run_test "handles missing /proc/version gracefully" test_detect_no_proc_version_file

# ── 2. PowerShell WPF prompt ─────────────────────────────────────────────────

test_powershell_wpf_reads_from_temp_file() {
    ASK_PASS_SOURCE_ONLY=1 source "$SCRIPT"

    local mock_bin="$TEST_TMPDIR/vp.bin"

    # Override METHOD and the temp file path
    METHOD="powershell_wpf"
    _ASK_PASS_WPF_RESULT_FILE="$mock_bin"
    # Mock cmd.exe: simulate PowerShell writing the passphrase to the result file
    _ASK_PASS_WPF_CMD() { printf 'test-passphrase-123' > "$mock_bin"; return 0; }

    RESULT=""
    _prompt_once "Test prompt"
    assert_eq "test-passphrase-123" "$RESULT" \
        "should read passphrase from PowerShell WPF temp file"
}
run_test "PowerShell WPF reads passphrase from temp file" test_powershell_wpf_reads_from_temp_file

test_powershell_wpf_cleans_temp_files() {
    ASK_PASS_SOURCE_ONLY=1 source "$SCRIPT"

    local mock_bin="$TEST_TMPDIR/vp.bin"
    local mock_ps1="$TEST_TMPDIR/ask.ps1"

    METHOD="powershell_wpf"
    _ASK_PASS_WPF_RESULT_FILE="$mock_bin"
    _ASK_PASS_WPF_PS1_FILE="$mock_ps1"
    # Mock writes result file (simulating PowerShell), script creates ps1 at mock path
    _ASK_PASS_WPF_CMD() { printf 'secret' > "$mock_bin"; return 0; }

    RESULT=""
    _prompt_once "Test"

    assert_file_not_exists "$mock_bin" "should clean up passphrase temp file"
    # Note: ps1 is created by the script at _ASK_PASS_WPF_PS1_FILE, then cleaned up
    assert_file_not_exists "$mock_ps1" "should clean up PowerShell script file"
}
run_test "PowerShell WPF cleans up temp files after reading" test_powershell_wpf_cleans_temp_files

test_powershell_wpf_fails_on_empty_result() {
    ASK_PASS_SOURCE_ONLY=1 source "$SCRIPT"

    local mock_bin="$TEST_TMPDIR/vp.bin"
    printf '' > "$mock_bin"

    METHOD="powershell_wpf"
    _ASK_PASS_WPF_RESULT_FILE="$mock_bin"
    _ASK_PASS_WPF_CMD() { return 0; }

    RESULT=""
    local rc=0
    _prompt_once "Test" 2>/dev/null || rc=$?
    assert_neq "0" "$rc" "should fail on empty passphrase"
}
run_test "PowerShell WPF fails on empty passphrase" test_powershell_wpf_fails_on_empty_result

test_powershell_wpf_fails_when_cmd_fails() {
    ASK_PASS_SOURCE_ONLY=1 source "$SCRIPT"

    METHOD="powershell_wpf"
    _ASK_PASS_WPF_RESULT_FILE="$TEST_TMPDIR/nonexistent.bin"
    _ASK_PASS_WPF_CMD() { return 1; }  # Simulate dialog cancel

    RESULT=""
    local rc=0
    _prompt_once "Test" 2>/dev/null || rc=$?
    assert_neq "0" "$rc" "should fail when PowerShell dialog is cancelled"
}
run_test "PowerShell WPF fails when dialog is cancelled" test_powershell_wpf_fails_when_cmd_fails

test_powershell_wpf_ps1_has_no_placeholders() {
    ASK_PASS_SOURCE_ONLY=1 source "$SCRIPT"

    local mock_bin="$TEST_TMPDIR/vp.bin"
    local mock_ps1="$TEST_TMPDIR/ask.ps1"

    METHOD="powershell_wpf"
    _ASK_PASS_WPF_RESULT_FILE="$mock_bin"
    _ASK_PASS_WPF_PS1_FILE="$mock_ps1"

    # Capture the .ps1 content before it gets cleaned up
    local captured_ps1="$TEST_TMPDIR/captured.ps1"
    _ASK_PASS_WPF_CMD() {
        cp "$mock_ps1" "$captured_ps1"
        printf 'secret' > "$mock_bin"
        return 0
    }

    RESULT=""
    _prompt_once "Decrypt vault"

    # The .ps1 must NOT contain raw placeholders
    assert_file_not_contains "$captured_ps1" "TITLE_PLACEHOLDER" \
        "ps1 should not contain TITLE_PLACEHOLDER"
    assert_file_not_contains "$captured_ps1" "RESULT_PLACEHOLDER" \
        "ps1 should not contain RESULT_PLACEHOLDER"

    # Must contain the actual title and a valid Windows path (no tab chars)
    assert_file_contains "$captured_ps1" "Decrypt vault" \
        "ps1 should contain the actual title"
    # Backslash-t must be literal backslash+t, not a tab (0x09)
    if grep -qP '\x09' "$captured_ps1"; then
        printf "${RED}    ASSERT failed: ps1 contains TAB character (\\t corruption)${RESET}\n" >&2
        printf "    This means sed interpreted \\t in C:\\temp\\ as a tab.\n" >&2
        return 1
    fi
}
run_test "PowerShell WPF .ps1 has no raw placeholders or tab corruption" test_powershell_wpf_ps1_has_no_placeholders

# ── 3. Source guard ──────────────────────────────────────────────────────────

test_source_guard_prevents_execution() {
    local output
    output=$(ASK_PASS_SOURCE_ONLY=1 bash "$SCRIPT" 2>&1) || true
    # Should produce no output (functions defined but not executed)
    assert_eq "" "$output" "source-only mode should produce no output"
}
run_test "ASK_PASS_SOURCE_ONLY prevents execution" test_source_guard_prevents_execution

# ── 4. Argument parsing ─────────────────────────────────────────────────────

test_confirm_flag_sets_confirm_mode() {
    ASK_PASS_SOURCE_ONLY=1 source "$SCRIPT"
    # CONFIRM should be 'false' by default after sourcing
    assert_eq "false" "$CONFIRM" "CONFIRM should default to false"
}
run_test "CONFIRM defaults to false" test_confirm_flag_sets_confirm_mode

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
