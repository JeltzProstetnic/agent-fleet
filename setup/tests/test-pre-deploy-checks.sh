#!/usr/bin/env bash
# Tests for sync-lib/pre-deploy.sh mechanical checks
# Verifies merge marker detection, bash syntax, JSON validity,
# settings completeness, and hook safe-run audit.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PRE_DEPLOY="$SCRIPT_DIR/../../sync-lib/pre-deploy.sh"

suite_header "Pre-Deploy Checks Tests"

# Helper: set up a minimal repo structure and source pre-deploy
# Returns exit code of pre_deploy_checks
run_checks() {
    local repo_dir="$1"
    (
        # Provide expected variables for the sourced module
        SCRIPT_DIR="$repo_dir"
        GLOBAL_DIR="$repo_dir/global"
        SETUP_DIR="$repo_dir/setup"
        local fail_count=0

        # Stub log functions
        log_info()  { :; }
        log_warn()  { :; }
        log_error() { echo "ERROR: $*" >&2; }

        source "$PRE_DEPLOY"
        pre_deploy_checks
    )
}

# ── Merge Marker Tests ──

test_detects_merge_markers() {
    local repo="$TEST_TMPDIR/repo"
    mkdir -p "$repo/global/hooks" "$repo/setup/config"
    echo "normal content" > "$repo/global/hooks/good.sh"
    cat > "$repo/global/hooks/bad.sh" <<'CONFLICT'
some code
<<<<<<< HEAD
my version
=======
their version
>>>>>>> branch
CONFLICT

    local output rc=0
    output=$(run_checks "$repo" 2>&1) || rc=$?

    assert_neq "0" "$rc" "Should fail when merge markers found"
    assert_contains "$output" "merge marker" "Should mention merge markers"
}

test_clean_files_no_merge_markers() {
    local repo="$TEST_TMPDIR/repo"
    mkdir -p "$repo/global/hooks" "$repo/setup/config"
    echo '#!/bin/bash' > "$repo/global/hooks/good.sh"
    echo '{}' > "$repo/setup/config/settings.json"

    local output rc=0
    output=$(run_checks "$repo" 2>&1) || rc=$?

    assert_eq "0" "$rc" "Should pass with no merge markers"
}

# ── Bash Syntax Tests ──

test_detects_bash_syntax_error() {
    local repo="$TEST_TMPDIR/repo"
    mkdir -p "$repo/global/hooks" "$repo/setup/config" "$repo/setup/scripts"
    cat > "$repo/global/hooks/broken.sh" <<'EOF'
#!/bin/bash
if [[ true ]]; then
    echo "missing fi"
EOF

    local output rc=0
    output=$(run_checks "$repo" 2>&1) || rc=$?

    assert_neq "0" "$rc" "Should fail on bash syntax error"
    assert_contains "$output" "syntax" "Should mention syntax"
}

test_valid_bash_passes() {
    local repo="$TEST_TMPDIR/repo"
    mkdir -p "$repo/global/hooks" "$repo/setup/config" "$repo/setup/scripts"
    cat > "$repo/global/hooks/good.sh" <<'EOF'
#!/bin/bash
if [[ true ]]; then
    echo "fine"
fi
EOF

    local output rc=0
    output=$(run_checks "$repo" 2>&1) || rc=$?

    assert_eq "0" "$rc" "Should pass with valid bash"
}

# ── JSON Validity Tests ──

test_detects_invalid_json() {
    local repo="$TEST_TMPDIR/repo"
    mkdir -p "$repo/global/hooks" "$repo/setup/config"
    echo '{invalid json' > "$repo/setup/config/settings.json"

    local output rc=0
    output=$(run_checks "$repo" 2>&1) || rc=$?

    assert_neq "0" "$rc" "Should fail on invalid JSON"
    assert_contains "$output" "JSON" "Should mention JSON"
}

test_valid_json_passes() {
    local repo="$TEST_TMPDIR/repo"
    mkdir -p "$repo/global/hooks" "$repo/setup/config"
    echo '{"hooks":{}, "permissions":{}, "enabledPlugins":{}}' > "$repo/setup/config/settings.json"

    local output rc=0
    output=$(run_checks "$repo" 2>&1) || rc=$?

    assert_eq "0" "$rc" "Should pass with valid JSON"
}

# ── Hook Safe-Run Audit Tests ──

test_detects_hook_missing_safe_run() {
    local repo="$TEST_TMPDIR/repo"
    mkdir -p "$repo/global/hooks" "$repo/setup/config"
    # Settings with a hook not routed through safe-run.sh
    cat > "$repo/setup/config/settings.json" <<'EOF'
{
    "hooks": {
        "PreToolUse": [
            {
                "matcher": "",
                "hooks": [
                    {
                        "type": "command",
                        "command": "bash ~/.claude/hooks/danger.sh"
                    }
                ]
            }
        ]
    },
    "permissions": {},
    "enabledPlugins": {}
}
EOF

    local output rc=0
    output=$(run_checks "$repo" 2>&1) || rc=$?

    assert_neq "0" "$rc" "Should fail when hook bypasses safe-run.sh"
    assert_contains "$output" "safe-run" "Should mention safe-run"
}

test_hooks_with_safe_run_pass() {
    local repo="$TEST_TMPDIR/repo"
    mkdir -p "$repo/global/hooks" "$repo/setup/config"
    cat > "$repo/setup/config/settings.json" <<'EOF'
{
    "hooks": {
        "PreToolUse": [
            {
                "matcher": "",
                "hooks": [
                    {
                        "type": "command",
                        "command": "bash ~/.claude/hooks/safe-run.sh my-hook.sh"
                    }
                ]
            }
        ]
    },
    "permissions": {},
    "enabledPlugins": {}
}
EOF

    local output rc=0
    output=$(run_checks "$repo" 2>&1) || rc=$?

    assert_eq "0" "$rc" "Should pass when all hooks use safe-run.sh"
}

# ── Run ──

run_test "detects merge markers in global/ files" test_detects_merge_markers
run_test "clean files pass merge marker check" test_clean_files_no_merge_markers
run_test "detects bash syntax errors in hook scripts" test_detects_bash_syntax_error
run_test "valid bash scripts pass syntax check" test_valid_bash_passes
run_test "detects invalid JSON in config" test_detects_invalid_json
run_test "valid JSON passes" test_valid_json_passes
run_test "detects hooks not routed through safe-run.sh" test_detects_hook_missing_safe_run
run_test "hooks using safe-run.sh pass audit" test_hooks_with_safe_run_pass

suite_summary
