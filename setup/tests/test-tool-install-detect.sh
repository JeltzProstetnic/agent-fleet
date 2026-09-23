#!/usr/bin/env bash
# Tests for tool-install-detect.sh PostToolUse hook
# Verifies that install commands trigger a machine-file update reminder.
source "$(dirname "$0")/test-helpers.sh"

suite_header "Tool Install Detection Hook"

HOOK_SCRIPT="$REPO_ROOT/global/hooks/tool-install-detect.sh"

# Helper: create a mock PostToolUse JSON input
make_input() {
    local tool_name="$1"
    local command="$2"
    local stdout="${3:-}"
    python3 -c "
import json, sys
d = {'tool_name': sys.argv[1], 'tool_input': {'command': sys.argv[2]}, 'tool_output': {'stdout': sys.argv[3]}}
print(json.dumps(d))
" "$tool_name" "$command" "$stdout"
}

# Helper: run hook and capture output
run_hook() {
    echo "$1" | bash "$HOOK_SCRIPT" 2>/dev/null
}

# ── Tests ────────────────────────────────────────────────────────────────────

test_pipx_install_detected() {
    local input
    input=$(make_input "Bash" "pipx install weasyprint" "installed package weasyprint")
    local output
    output=$(run_hook "$input")
    assert_contains "$output" "additionalContext" "produces additionalContext" || return 1
    assert_contains "$output" "machine file" "mentions machine file" || return 1
}
run_test "pipx install triggers reminder" test_pipx_install_detected

test_npm_install_g_detected() {
    local input
    input=$(make_input "Bash" "npm install -g @anthropic-ai/claude-code" "added 1 package")
    local output
    output=$(run_hook "$input")
    assert_contains "$output" "additionalContext" "produces additionalContext" || return 1
}
run_test "npm install -g triggers reminder" test_npm_install_g_detected

test_pacman_s_detected() {
    local input
    input=$(make_input "Bash" "sudo pacman -S jq" "resolving dependencies")
    local output
    output=$(run_hook "$input")
    assert_contains "$output" "additionalContext" "produces additionalContext" || return 1
}
run_test "pacman -S triggers reminder" test_pacman_s_detected

test_flatpak_install_detected() {
    local input
    input=$(make_input "Bash" "flatpak install flathub org.libreoffice.LibreOffice" "Installation complete")
    local output
    output=$(run_hook "$input")
    assert_contains "$output" "additionalContext" "produces additionalContext" || return 1
}
run_test "flatpak install triggers reminder" test_flatpak_install_detected

test_apt_install_detected() {
    local input
    input=$(make_input "Bash" "sudo apt install -y git nodejs" "Setting up git")
    local output
    output=$(run_hook "$input")
    assert_contains "$output" "additionalContext" "produces additionalContext" || return 1
}
run_test "apt install triggers reminder" test_apt_install_detected

test_regular_command_ignored() {
    local input
    input=$(make_input "Bash" "ls -la /home/deck" "total 42")
    local output
    output=$(run_hook "$input")
    assert_eq "" "$output" "no output for regular command" || return 1
}
run_test "regular command produces no reminder" test_regular_command_ignored

test_non_bash_tool_ignored() {
    local input
    input=$(make_input "Read" "/home/deck/file.txt" "contents")
    local output
    output=$(run_hook "$input")
    assert_eq "" "$output" "no output for non-Bash tool" || return 1
}
run_test "non-Bash tool produces no reminder" test_non_bash_tool_ignored

test_pip_install_detected() {
    local input
    input=$(make_input "Bash" "pip install requests" "Successfully installed")
    local output
    output=$(run_hook "$input")
    assert_contains "$output" "additionalContext" "produces additionalContext" || return 1
}
run_test "pip install triggers reminder" test_pip_install_detected

test_npm_install_local_ignored() {
    local input
    input=$(make_input "Bash" "npm install express" "added 57 packages")
    local output
    output=$(run_hook "$input")
    assert_eq "" "$output" "no reminder for local npm install" || return 1
}
run_test "npm install (local, no -g) does not trigger" test_npm_install_local_ignored

suite_summary
