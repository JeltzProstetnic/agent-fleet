#!/usr/bin/env bash
# Tests for setup/scripts/afleet-recover.sh — recovery, diagnostics, rollback
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/afleet-recover.sh"

suite_header "afleet-recover.sh (recovery & diagnostics)"

# ── Helpers ──────────────────────────────────────────────────────────────────

create_mock_fleet() {
    local home="$TEST_TMPDIR/home"
    local config="$TEST_TMPDIR/home/cfg-agent-fleet"

    # Create a git repo to simulate config repo
    create_git_repo "$config"
    add_commit "$config" "commit 1" "file1.txt"
    add_commit "$config" "commit 2" "file2.txt"
    add_commit "$config" "commit 3" "file3.txt"

    # Create claude dirs
    mkdir -p "$home/.claude/foundation"
    mkdir -p "$home/.claude/reference"
    mkdir -p "$home/.claude/knowledge"
    mkdir -p "$home/.claude/domains"
    mkdir -p "$home/.claude/machines"
    mkdir -p "$home/.claude/hooks/checks"

    # Create sync.sh stub
    cat > "$config/sync.sh" << 'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    deploy) echo "MOCK_DEPLOY_CALLED" ;;
    setup)  echo "MOCK_SETUP_CALLED" ;;
    *)      echo "Unknown: $1" ;;
esac
EOF
    chmod +x "$config/sync.sh"

    # Create mock claude binary
    mkdir -p "$home/.local/bin"
    cat > "$home/.local/bin/claude" << 'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "2.1.80"
    exit 0
fi
if [[ "${1:-}" == "--print" ]]; then
    echo '{"result":"pong"}'
    exit 0
fi
echo "MOCK_CLAUDE $*"
MOCK
    chmod +x "$home/.local/bin/claude"

    # Create settings.json
    mkdir -p "$home/.cc-mirror/mclaude/config"
    cat > "$home/.cc-mirror/mclaude/config/settings.json" << 'EOF'
{
  "env": {},
  "permissions": { "allow": [] },
  "hooks": {}
}
EOF

    # Create .mcp.json with test servers
    cat > "$home/.cc-mirror/mclaude/config/.mcp.json" << 'EOF'
{
  "mcpServers": {
    "serena": { "command": "uvx", "args": ["serena"] },
    "bad-url-server": { "url": "http://localhost:59999/sse" },
    "github": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"] }
  }
}
EOF

    # Create expected symlinks
    ln -sf "$config/global/foundation" "$home/.claude/foundation" 2>/dev/null || true
    ln -sf "$config/global/reference" "$home/.claude/reference" 2>/dev/null || true

    # Create hooks
    cat > "$home/.claude/hooks/checks/01-test.sh" << 'HOOK'
#!/usr/bin/env bash
echo "test hook"
HOOK
    chmod +x "$home/.claude/hooks/checks/01-test.sh"

    echo "$home"
}

# ── 1. Doctor — health checks ───────────────────────────────────────────────

test_doctor_detects_missing_cc() {
    local home
    home=$(create_mock_fleet)
    rm "$home/.local/bin/claude"

    local output
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        bash "$SCRIPT" doctor 2>&1) || true
    assert_contains "$output" "FAIL" "should report CC binary missing"
    assert_contains "$output" "claude" "should mention claude"
}
run_test "doctor detects missing claude binary" test_doctor_detects_missing_cc

test_doctor_detects_invalid_settings() {
    local home
    home=$(create_mock_fleet)
    echo "NOT JSON {{{" > "$home/.cc-mirror/mclaude/config/settings.json"

    local output
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        bash "$SCRIPT" doctor 2>&1) || true
    assert_contains "$output" "FAIL" "should report invalid settings.json"
}
run_test "doctor detects invalid settings.json" test_doctor_detects_invalid_settings

test_doctor_reports_healthy() {
    local home
    home=$(create_mock_fleet)

    local output
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        bash "$SCRIPT" doctor 2>&1) || true
    assert_contains "$output" "OK" "should report OK for healthy checks"
}
run_test "doctor reports healthy state" test_doctor_reports_healthy

test_doctor_detects_unreachable_mcp_url() {
    local home
    home=$(create_mock_fleet)

    local output
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        bash "$SCRIPT" doctor 2>&1) || true
    # bad-url-server points to localhost:59999 which shouldn't be listening
    assert_contains "$output" "bad-url-server" "should check bad-url-server"
    assert_contains "$output" "unreachable" "should flag unreachable server"
}
run_test "doctor detects unreachable MCP URL server" test_doctor_detects_unreachable_mcp_url

test_doctor_detects_broken_hooks() {
    local home
    home=$(create_mock_fleet)
    # Create a hook with syntax error
    cat > "$home/.claude/hooks/checks/02-broken.sh" << 'HOOK'
#!/usr/bin/env bash
if [[ ; then
HOOK
    chmod +x "$home/.claude/hooks/checks/02-broken.sh"

    local output
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        bash "$SCRIPT" doctor 2>&1) || true
    assert_contains "$output" "FAIL" "should report broken hook"
    assert_contains "$output" "02-broken" "should name the broken hook"
}
run_test "doctor detects hooks with syntax errors" test_doctor_detects_broken_hooks

test_doctor_detects_non_executable_hooks() {
    local home
    home=$(create_mock_fleet)
    # Create a hook without executable bit
    cat > "$home/.claude/hooks/checks/03-noexec.sh" << 'HOOK'
#!/usr/bin/env bash
echo "not executable"
HOOK
    # Deliberately NOT chmod +x

    local output
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        bash "$SCRIPT" doctor 2>&1) || true
    assert_contains "$output" "not executable" "should flag non-executable hook"
}
run_test "doctor detects non-executable hooks" test_doctor_detects_non_executable_hooks

test_doctor_detects_stale_lock() {
    local home
    home=$(create_mock_fleet)
    mkdir -p "$home/.claude"
    cat > "$home/.claude/.session-lock" << EOF
{
  "pid": 99999,
  "machine": "test-machine",
  "timestamp": "2026-03-19T10:00:00Z",
  "project": "test"
}
EOF

    local output
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        bash "$SCRIPT" doctor 2>&1) || true
    assert_contains "$output" "lock" "should mention session lock"
}
run_test "doctor detects stale session lock" test_doctor_detects_stale_lock

# ── 2. Recover — auto-fix ───────────────────────────────────────────────────

test_recover_fixes_non_executable_hooks() {
    local home
    home=$(create_mock_fleet)
    cat > "$home/.claude/hooks/checks/03-noexec.sh" << 'HOOK'
#!/usr/bin/env bash
echo "was not executable"
HOOK

    local output
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        bash "$SCRIPT" recover 2>&1) || true
    assert_contains "$output" "chmod" "should report fix"
    [[ -x "$home/.claude/hooks/checks/03-noexec.sh" ]] || {
        echo "    Hook should be executable after recover" >&2
        return 1
    }
}
run_test "recover fixes non-executable hooks" test_recover_fixes_non_executable_hooks

test_recover_reports_summary() {
    local home
    home=$(create_mock_fleet)

    local output
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        bash "$SCRIPT" recover 2>&1) || true
    assert_contains "$output" "Recovery" "should show recovery header"
}
run_test "recover reports summary" test_recover_reports_summary

# ── 3. Rollback ─────────────────────────────────────────────────────────────

test_rollback_shows_commits() {
    local home
    home=$(create_mock_fleet)

    local output
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        bash "$SCRIPT" rollback --dry-run 2 2>&1) || true
    assert_contains "$output" "commit 3" "should show most recent commit"
    assert_contains "$output" "commit 2" "should show second commit"
}
run_test "rollback --dry-run shows commits to roll back" test_rollback_shows_commits

test_rollback_resets_repo() {
    local home
    home=$(create_mock_fleet)

    local before_head
    before_head=$(git -C "$home/cfg-agent-fleet" rev-parse HEAD)

    local output
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        bash "$SCRIPT" rollback --yes 2 2>&1) || true

    local after_head
    after_head=$(git -C "$home/cfg-agent-fleet" rev-parse HEAD)

    assert_neq "$before_head" "$after_head" "HEAD should have changed"
    assert_file_not_exists "$home/cfg-agent-fleet/file3.txt" "file3 should be gone"
    assert_file_not_exists "$home/cfg-agent-fleet/file2.txt" "file2 should be gone"
    assert_file_exists "$home/cfg-agent-fleet/file1.txt" "file1 should still exist"
}
run_test "rollback resets repo by N commits" test_rollback_resets_repo

test_rollback_runs_deploy() {
    local home
    home=$(create_mock_fleet)

    local output
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        bash "$SCRIPT" rollback --yes 1 2>&1) || true
    assert_contains "$output" "MOCK_DEPLOY_CALLED" "should run deploy after rollback"
}
run_test "rollback runs deploy after reset" test_rollback_runs_deploy

test_rollback_rejects_too_many() {
    local home
    home=$(create_mock_fleet)

    local output rc=0
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        bash "$SCRIPT" rollback --yes 100 2>&1) || rc=$?
    [[ $rc -ne 0 ]] || assert_contains "$output" "Error\|error\|too many\|exceed" \
        "should reject rollback > available commits"
}
run_test "rollback rejects N > available commits" test_rollback_rejects_too_many

test_rollback_preserves_head_on_dry_run() {
    local home
    home=$(create_mock_fleet)

    local before_head
    before_head=$(git -C "$home/cfg-agent-fleet" rev-parse HEAD)

    HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        bash "$SCRIPT" rollback --dry-run 2 2>&1 || true

    local after_head
    after_head=$(git -C "$home/cfg-agent-fleet" rev-parse HEAD)
    assert_eq "$before_head" "$after_head" "HEAD should not change on dry-run"
}
run_test "rollback --dry-run makes no changes" test_rollback_preserves_head_on_dry_run

# ── 4. Safe-mode ─────────────────────────────────────────────────────────────

test_safe_mode_creates_temp_config() {
    local home
    home=$(create_mock_fleet)

    # safe-mode with --dry-run should show what it would do
    local output
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        AFLEET_SAFE_MODE_DRY_RUN=1 \
        bash "$SCRIPT" safe-mode 2>&1) || true
    assert_contains "$output" "Safe Mode" "should mention safe mode"
    assert_contains "$output" "no hooks" "should describe stripped config"
}
run_test "safe-mode describes minimal launch config" test_safe_mode_creates_temp_config

test_safe_mode_settings_are_minimal() {
    local home
    home=$(create_mock_fleet)

    # Use prepare-only mode to create the config without launching
    local output
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        AFLEET_SAFE_MODE_PREPARE_ONLY=1 \
        bash "$SCRIPT" safe-mode 2>&1) || true

    # Extract the temp dir path from output
    local safe_dir
    safe_dir=$(echo "$output" | grep -oP 'SAFE_CONFIG_DIR=\K\S+' || echo "")
    if [[ -n "$safe_dir" && -f "$safe_dir/settings.json" ]]; then
        assert_file_not_contains "$safe_dir/settings.json" "hooks" \
            "safe-mode settings should have no hooks"
        # Cleanup the temp dir since prepare-only doesn't
        rm -rf "$safe_dir" 2>/dev/null || true
    fi
    assert_contains "$output" "SAFE_CONFIG_DIR" "should output safe config dir path"
}
run_test "safe-mode creates settings without hooks/MCP" test_safe_mode_settings_are_minimal

test_safe_mode_passes_cc_native_flag() {
    local home
    home=$(create_mock_fleet)

    # Belt-and-suspenders (CFG-437): on top of temp-config isolation, safe-mode
    # should ALSO pass CC's native --safe-mode flag (2.1.169+). Dry-run advertises it.
    local output
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        AFLEET_SAFE_MODE_DRY_RUN=1 \
        bash "$SCRIPT" safe-mode 2>&1) || true
    assert_contains "$output" "--safe-mode" "dry-run should advertise CC's native --safe-mode flag"
}
run_test "safe-mode passes CC native --safe-mode flag" test_safe_mode_passes_cc_native_flag

# ── 4b. CFG-888: safe-mode must launch the MIRROR's Claude Code, never a stray PATH install ──
# Measured 2026-10-30 on WSL: the old lookup tried the mirror's cli.js (no longer shipped),
# then fell to PATH `claude` = a Windows npm shim at 2.1.37 while the mirror held 2.1.280.
# Resolution order: launcher exec target → mirror npm bin/claude.exe → mirror native/claude →
# legacy cli.js via node → PATH claude last (warned when it is a Windows install). A candidate
# must be executable and not the <1 MB npm-pack ASCII shim. Dry-run prints the choice.
_mk_fake_cc() {  # <path> <version>: a tiny executable standing in for a CC binary
    mkdir -p "$(dirname "$1")"
    printf '#!/usr/bin/env bash\n[[ "${1:-}" == "--version" ]] && { echo "%s"; exit 0; }\necho "FAKE_CC %s $*"\n' "$2" "$2" > "$1"
    chmod +x "$1"
}
_safe_dry() {  # <home> [extra PATH dir]: dry-run safe-mode in the fake HOME, prints its output
    # CC_MIRROR_DIR is exported by the live mclaude launcher and would point the resolver at
    # the REAL mirror (read-only, but it hides the fixtures): pin it to the fake HOME.
    HOME="$1" CONFIG_REPO="$1/cfg-agent-fleet" CC_MIRROR_DIR="$1/.cc-mirror/mclaude" \
        CLAUDE_CONFIG_DIR="$1/.cc-mirror/mclaude/config" \
        PATH="${2:-$1/.local/bin}:/usr/bin:/bin" AFLEET_SAFE_MODE_DRY_RUN=1 \
        bash "$SCRIPT" safe-mode 2>&1 || true
}
_MIRROR_BIN=".cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/bin/claude.exe"

test_safe_mode_prefers_launcher_target() {
    local home; home=$(create_mock_fleet)   # PATH claude mock at $home/.local/bin/claude (2.1.80)
    _mk_fake_cc "$home/$_MIRROR_BIN" "2.1.280"
    printf '#!/usr/bin/env bash\nexport CLAUDE_CONFIG_DIR="%s/.cc-mirror/mclaude/config"\nexec "%s/%s" "$@"\n' "$home" "$home" "$_MIRROR_BIN" > "$home/.local/bin/mclaude"
    chmod +x "$home/.local/bin/mclaude"
    local out; out=$(_safe_dry "$home")
    assert_contains "$out" "Binary: $home/$_MIRROR_BIN" "the launcher's exec target is chosen (output: $(printf '%s' "$out" | grep -i binary || true))"
    assert_not_contains "$out" "Binary: $home/.local/bin/claude" "PATH claude is not chosen while the launcher target exists"
}
run_test "CFG-888: safe-mode resolves the launcher's exec target first" test_safe_mode_prefers_launcher_target

test_safe_mode_mirror_npm_before_path() {
    local home; home=$(create_mock_fleet)
    _mk_fake_cc "$home/$_MIRROR_BIN" "2.1.280"       # no launcher at all
    local out; out=$(_safe_dry "$home")
    assert_contains "$out" "Binary: $home/$_MIRROR_BIN" "mirror npm bin/claude.exe beats PATH claude"
}
run_test "CFG-888: without a launcher, the mirror's npm binary beats PATH" test_safe_mode_mirror_npm_before_path

test_safe_mode_native_binary() {
    local home; home=$(create_mock_fleet)
    _mk_fake_cc "$home/.cc-mirror/mclaude/native/claude" "2.1.280"
    local out; out=$(_safe_dry "$home")
    assert_contains "$out" "Binary: $home/.cc-mirror/mclaude/native/claude" "native-install mirror binary is found"
}
run_test "CFG-888: a native-binary mirror (native/claude) is found" test_safe_mode_native_binary

test_safe_mode_legacy_cli_js() {
    local home; home=$(create_mock_fleet)
    local cli="$home/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/cli.js"
    mkdir -p "$(dirname "$cli")"; echo "// legacy" > "$cli"
    _mk_fake_cc "$home/.local/bin/node" "v22"
    local out; out=$(_safe_dry "$home")
    assert_contains "$out" "Binary: node $cli" "legacy cli.js is run through node, ahead of PATH claude"
}
run_test "CFG-888: legacy cli.js via node still works, ahead of PATH" test_safe_mode_legacy_cli_js

test_safe_mode_path_last_with_windows_warning() {
    local home; home=$(create_mock_fleet)
    rm -f "$home/.local/bin/claude"
    _mk_fake_cc "$home/mnt/c/Users/alice/AppData/Roaming/npm/claude" "2.1.37"
    local out; out=$(_safe_dry "$home" "$home/mnt/c/Users/alice/AppData/Roaming/npm")
    assert_contains "$out" "Binary: $home/mnt/c/Users/alice/AppData/Roaming/npm/claude" "PATH claude is the last resort"
    assert_contains "$out" "Windows install" "a PATH claude under /mnt/c/ is flagged as a Windows install"
}
run_test "CFG-888: PATH claude is last and a /mnt/c/ one is flagged as a Windows install" test_safe_mode_path_last_with_windows_warning

test_safe_mode_skips_npm_pack_shim() {
    local home; home=$(create_mock_fleet)
    mkdir -p "$(dirname "$home/$_MIRROR_BIN")"
    printf '#!/usr/bin/env bash\necho "Error: claude native binary not installed." >&2\nexit 1\n' > "$home/$_MIRROR_BIN"
    chmod +x "$home/$_MIRROR_BIN"
    local out; out=$(_safe_dry "$home")
    assert_not_contains "$out" "Binary: $home/$_MIRROR_BIN" "the <1 MB ASCII shim is never chosen"
    assert_contains "$out" "Binary: $home/.local/bin/claude" "falls through to the next candidate"
}
run_test "CFG-888: the npm-pack ASCII shim is skipped" test_safe_mode_skips_npm_pack_shim

test_safe_mode_reports_none_found() {
    local home; home=$(create_mock_fleet)
    rm -f "$home/.local/bin/claude"
    local out; out=$(_safe_dry "$home" "$home/emptybin")
    assert_contains "$out" "Binary: none found" "dry-run says when no candidate exists"
}
run_test "CFG-888: dry-run reports when no binary is found" test_safe_mode_reports_none_found

# ── 5. MCP connectivity check ───────────────────────────────────────────────

test_mcp_check_command_server_binary_exists() {
    local home
    home=$(create_mock_fleet)
    # npx should exist on PATH
    local output
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:/usr/bin:/usr/local/bin:$PATH" \
        bash "$SCRIPT" doctor 2>&1) || true
    # "github" server uses npx which should exist
    assert_not_contains "$output" "github.*FAIL.*binary" \
        "github server (npx) should not fail binary check"
}
run_test "MCP check: command server binary existence" test_mcp_check_command_server_binary_exists

# ── 6. Settings validation ───────────────────────────────────────────────────

test_settings_valid_json_passes() {
    local home
    home=$(create_mock_fleet)

    local output
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        bash "$SCRIPT" doctor 2>&1) || true
    assert_contains "$output" "Settings valid JSON" "valid JSON should pass"
}
run_test "settings validation: valid JSON passes" test_settings_valid_json_passes

test_settings_missing_file() {
    local home
    home=$(create_mock_fleet)
    rm "$home/.cc-mirror/mclaude/config/settings.json"

    local output
    output=$(HOME="$home" CONFIG_REPO="$home/cfg-agent-fleet" \
        CLAUDE_CONFIG_DIR="$home/.cc-mirror/mclaude/config" \
        PATH="$home/.local/bin:$PATH" \
        bash "$SCRIPT" doctor 2>&1) || true
    assert_contains "$output" "FAIL" "missing settings should fail"
}
run_test "settings validation: missing file fails" test_settings_missing_file

# ── 7. Help / usage ─────────────────────────────────────────────────────────

test_no_args_shows_usage() {
    local output
    output=$(bash "$SCRIPT" 2>&1) || true
    assert_contains "$output" "doctor" "no args should mention doctor"
}
run_test "no args shows usage" test_no_args_shows_usage

test_help_flag() {
    local output
    output=$(bash "$SCRIPT" --help 2>&1)
    assert_contains "$output" "doctor" "should list doctor subcommand"
    assert_contains "$output" "recover" "should list recover subcommand"
    assert_contains "$output" "rollback" "should list rollback subcommand"
    assert_contains "$output" "safe-mode" "should list safe-mode subcommand"
}
run_test "help flag shows all subcommands" test_help_flag

# ── Summary ──────────────────────────────────────────────────────────────────
suite_summary
