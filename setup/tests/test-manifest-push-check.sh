#!/usr/bin/env bash
# Tests for global/hooks/manifest-push-check.sh — PreToolUse template-push gate
# Verifies that `git commit` Bash calls touching manifest-tracked files are
# blocked unless a `.template-push-verified-<HEAD-sha>` marker exists.
source "$(dirname "$0")/test-helpers.sh"

HOOK="$REPO_ROOT/global/hooks/manifest-push-check.sh"

suite_header "manifest-push-check.sh (CFG-393: template-push verification gate)"

# Build a mock cfg-agent-fleet repo with manifest + initial commit
make_mock_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    cat > "$repo/template-sync-manifest.md" <<'EOF'
# Template Sync Manifest
## Tracked Files — Must Be Identical
| File | Notes |
|------|-------|
| `setup/lib.sh` | Shared lib |
| `global/hooks/cfg-boundary-guard.sh` | Boundary guard |

## Tracked Files — Intentional Diffs
| File | Diff reason |
|------|-------------|
| `sync.sh` | Personal hostname case |
EOF
    mkdir -p "$repo/setup" "$repo/global/hooks"
    echo "lib" > "$repo/setup/lib.sh"
    echo "guard" > "$repo/global/hooks/cfg-boundary-guard.sh"
    echo "sync" > "$repo/sync.sh"
    echo "readme" > "$repo/README.md"
    git -C "$repo" add . >/dev/null
    git -C "$repo" commit -q -m "init"
}

# Run hook with simulated PreToolUse JSON for a Bash command
run_hook() {
    local cmd="$1"
    local pwd_dir="$2"
    local esc=${cmd//\\/\\\\}; esc=${esc//\"/\\\"}
    local input="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$esc\"}}"
    echo "$input" | (cd "$pwd_dir" && bash "$HOOK") 2>&1
}

# ── Tests ──

test_non_commit_bash_passes() {
    local repo="$TEST_TMPDIR/repo"
    make_mock_repo "$repo"
    local out rc=0
    out=$(run_hook "ls -la" "$repo") || rc=$?
    assert_eq "0" "$rc" "non-commit bash call should pass"
}

test_commit_with_no_manifest_files_passes() {
    local repo="$TEST_TMPDIR/repo"
    make_mock_repo "$repo"
    echo "new" > "$repo/README.md"
    git -C "$repo" add README.md >/dev/null
    local out rc=0
    out=$(run_hook "git commit -m fix" "$repo") || rc=$?
    assert_eq "0" "$rc" "commit touching only non-manifest files should pass"
}

test_commit_with_manifest_file_no_marker_blocks() {
    local repo="$TEST_TMPDIR/repo"
    make_mock_repo "$repo"
    echo "edit" >> "$repo/setup/lib.sh"
    git -C "$repo" add setup/lib.sh >/dev/null
    local out rc=0
    out=$(run_hook "git commit -m fix" "$repo") || rc=$?
    assert_eq "2" "$rc" "commit touching manifest file with no marker should block (exit 2)"
    assert_contains "$out" "MANIFEST_PUSH_CHECK" "should print MANIFEST_PUSH_CHECK header"
    assert_contains "$out" "setup/lib.sh" "should list the offending file"
    assert_contains "$out" "template-push --dry-run" "should instruct dry-run"
}

test_commit_with_intentional_diff_file_blocks() {
    local repo="$TEST_TMPDIR/repo"
    make_mock_repo "$repo"
    echo "edit" >> "$repo/sync.sh"
    git -C "$repo" add sync.sh >/dev/null
    local out rc=0
    out=$(run_hook "git commit -m fix" "$repo") || rc=$?
    assert_eq "2" "$rc" "commit touching Intentional Diffs file should also block"
}

test_commit_with_valid_marker_passes() {
    local repo="$TEST_TMPDIR/repo"
    make_mock_repo "$repo"
    echo "edit" >> "$repo/setup/lib.sh"
    git -C "$repo" add setup/lib.sh >/dev/null
    local sha
    sha=$(git -C "$repo" rev-parse HEAD)
    touch "$repo/.template-push-verified-${sha}"
    local out rc=0
    out=$(run_hook "git commit -m fix" "$repo") || rc=$?
    assert_eq "0" "$rc" "commit with valid HEAD-matching marker should pass"
}

test_commit_with_stale_marker_blocks() {
    local repo="$TEST_TMPDIR/repo"
    make_mock_repo "$repo"
    touch "$repo/.template-push-verified-deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    echo "edit" >> "$repo/setup/lib.sh"
    git -C "$repo" add setup/lib.sh >/dev/null
    local out rc=0
    out=$(run_hook "git commit -m fix" "$repo") || rc=$?
    assert_eq "2" "$rc" "stale marker (different HEAD) should still block"
}

test_bash_dash_c_escape_hatch_passes() {
    local repo="$TEST_TMPDIR/repo"
    make_mock_repo "$repo"
    echo "edit" >> "$repo/setup/lib.sh"
    git -C "$repo" add setup/lib.sh >/dev/null
    local out rc=0
    out=$(run_hook "bash -c 'git commit -m fix'" "$repo") || rc=$?
    assert_eq "0" "$rc" "bash -c wrapper should bypass the guard"
}

test_git_dash_C_form_inspected() {
    local repo="$TEST_TMPDIR/repo"
    make_mock_repo "$repo"
    echo "edit" >> "$repo/setup/lib.sh"
    git -C "$repo" add setup/lib.sh >/dev/null
    local out rc=0
    out=$(run_hook "git -C $repo commit -m fix" "/tmp") || rc=$?
    assert_eq "2" "$rc" "git -C <path> commit form should be inspected via path arg"
}

test_no_manifest_file_passes_silently() {
    local repo="$TEST_TMPDIR/repo-no-manifest"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    echo "x" > "$repo/a"
    git -C "$repo" add . >/dev/null
    git -C "$repo" commit -q -m init
    echo "y" >> "$repo/a"
    git -C "$repo" add a >/dev/null
    local out rc=0
    out=$(run_hook "git commit -m fix" "$repo") || rc=$?
    assert_eq "0" "$rc" "repo with no manifest should pass (hook only enforces in cfg)"
}

test_non_bash_tool_ignored() {
    local out rc=0
    out=$(echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x"}}' | bash "$HOOK") || rc=$?
    assert_eq "0" "$rc" "non-Bash tool calls should be ignored"
}

# ── Run ──

run_test "non-commit Bash → pass"                            test_non_commit_bash_passes
run_test "commit only non-manifest files → pass"             test_commit_with_no_manifest_files_passes
run_test "commit manifest file (no marker) → block"          test_commit_with_manifest_file_no_marker_blocks
run_test "commit intentional-diff file → block"              test_commit_with_intentional_diff_file_blocks
run_test "commit with valid HEAD marker → pass"              test_commit_with_valid_marker_passes
run_test "commit with stale marker → block"                  test_commit_with_stale_marker_blocks
run_test "bash -c escape hatch → pass"                       test_bash_dash_c_escape_hatch_passes
run_test "git -C <path> commit form inspected"               test_git_dash_C_form_inspected
run_test "repo without manifest → silent pass"               test_no_manifest_file_passes_silently
run_test "non-Bash tool → ignored"                           test_non_bash_tool_ignored

suite_summary
