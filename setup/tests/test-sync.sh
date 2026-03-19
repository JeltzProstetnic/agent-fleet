#!/usr/bin/env bash
# Tests for sync.sh — focused on testable functions and structural behaviors
source "$(dirname "$0")/test-helpers.sh"

SYNC_SCRIPT="$REPO_ROOT/sync.sh"
SYNC_COMMON="$REPO_ROOT/sync-lib/common.sh"

suite_header "sync.sh"

# ── Help/usage ───────────────────────────────────────────────────────────────

test_help() {
    local out
    out=$(bash "$SYNC_SCRIPT" help 2>&1)
    assert_contains "$out" "setup"
    assert_contains "$out" "deploy"
    assert_contains "$out" "collect"
    assert_contains "$out" "status"
}
run_test "help shows all subcommands" test_help

test_no_args() {
    local out
    out=$(bash "$SYNC_SCRIPT" 2>&1)
    assert_contains "$out" "Usage"
}
run_test "no arguments shows usage" test_no_args

# ── find_project_path ────────────────────────────────────────────────────────

test_find_project_by_home_dir() {
    # find_project_path was moved to sync-lib/common.sh
    # find_project_path checks $HOME/<name> first
    # Use agent-fleet which exists for any template user
    local result
    result=$(
        SCRIPT_DIR="$REPO_ROOT"
        source "$SYNC_COMMON" 2>/dev/null
        find_project_path "agent-fleet"
    )
    assert_eq "$HOME/agent-fleet" "$result"
}
run_test "find_project_path finds project in home directory" test_find_project_by_home_dir

test_find_project_registry_fallback() {
    # Create a mock registry and a project dir
    mkdir -p "$TEST_TMPDIR/mock-project"
    cat > "$TEST_TMPDIR/registry.md" <<EOF
| Project | Priority | Path | GitHub | Machines | Type | Phase |
|---------|----------|------|--------|----------|------|-------|
| mock-project | P3 | \`$TEST_TMPDIR/mock-project\` | — | test | code | active |
EOF

    local result
    result=$(
        SCRIPT_DIR="$TEST_TMPDIR"
        HOME="/nonexistent"
        source "$SYNC_COMMON" 2>/dev/null
        find_project_path "mock-project"
    )
    assert_eq "$TEST_TMPDIR/mock-project" "$result"
}
run_test "find_project_path falls back to registry.md" test_find_project_registry_fallback

test_find_project_not_found() {
    local result
    result=$(
        SCRIPT_DIR="$TEST_TMPDIR"
        HOME="$TEST_TMPDIR"
        source "$SYNC_COMMON" 2>/dev/null
        find_project_path "nonexistent-project-xyz"
    )
    assert_eq "" "$result" "should return empty for unknown project"
}
run_test "find_project_path returns empty for unknown project" test_find_project_not_found

# ── deploy_hooks ─────────────────────────────────────────────────────────────

test_deploy_hooks_copies_files() {
    # Set up a mock environment
    mkdir -p "$TEST_TMPDIR/global/hooks"
    mkdir -p "$TEST_TMPDIR/claude-home/hooks"
    echo "#!/bin/bash" > "$TEST_TMPDIR/global/hooks/test-hook.sh"
    echo "echo test" >> "$TEST_TMPDIR/global/hooks/test-hook.sh"

    (
        GLOBAL_DIR="$TEST_TMPDIR/global"
        CLAUDE_HOME="$TEST_TMPDIR/claude-home"
        source <(sed -n '/^deploy_hooks()/,/^}/p' "$SYNC_SCRIPT" | sed 's/log_info/echo/g')
        deploy_hooks
    )

    assert_file_exists "$TEST_TMPDIR/claude-home/hooks/test-hook.sh"
    # Should be executable
    [[ -x "$TEST_TMPDIR/claude-home/hooks/test-hook.sh" ]]
}
run_test "deploy_hooks copies hook files and makes them executable" test_deploy_hooks_copies_files

# ── check_settings_health ────────────────────────────────────────────────────

test_settings_health_warns_missing_permissions() {
    mkdir -p "$TEST_TMPDIR/.cc-mirror/mclaude/config"
    echo '{"hooks": {}, "enabledPlugins": []}' > "$TEST_TMPDIR/.cc-mirror/mclaude/config/settings.json"

    local out
    out=$(
        HOME="$TEST_TMPDIR"
        unset CC_MIRROR_DIR
        source <(sed -n '/^check_settings_health()/,/^}/p' "$SYNC_SCRIPT" \
            | sed 's/log_warn/echo WARN/g; s/log_info/echo INFO/g')
        check_settings_health
    )
    assert_contains "$out" "permissions"
}
run_test "check_settings_health warns when permissions block missing" test_settings_health_warns_missing_permissions

test_settings_health_clean() {
    mkdir -p "$TEST_TMPDIR/.cc-mirror/mclaude/config"
    echo '{"permissions": {}, "hooks": {}, "enabledPlugins": []}' > "$TEST_TMPDIR/.cc-mirror/mclaude/config/settings.json"

    local out
    out=$(
        HOME="$TEST_TMPDIR"
        unset CC_MIRROR_DIR
        source <(sed -n '/^check_settings_health()/,/^}/p' "$SYNC_SCRIPT" \
            | sed 's/log_warn/echo WARN/g; s/log_info/echo INFO/g')
        check_settings_health
    )
    assert_not_contains "$out" "WARN"
}
run_test "check_settings_health is silent when all blocks present" test_settings_health_clean

# ── Platform detection ───────────────────────────────────────────────────────

test_platform_detection() {
    # Verify sync.sh sets PLATFORM to a known value
    local platform
    platform=$(bash -c "
        source <(head -30 '$SYNC_SCRIPT')
        echo \$PLATFORM
    ")
    assert_neq "" "$platform" "PLATFORM should be set"
    # Valid platforms: linux, wsl, macos, steamos
    assert_contains "linux wsl macos steamos" "$platform" "PLATFORM should be a known value"
}
run_test "platform detection works on current machine" test_platform_detection

# ── Status subcommand runs ───────────────────────────────────────────────────

test_status_runs() {
    local out rc=0
    out=$(bash "$SYNC_SCRIPT" status 2>&1) || rc=$?
    assert_eq "0" "$rc" "status should exit 0"
    assert_contains "$out" "CLAUDE.md"
    assert_contains "$out" "foundation"
}
run_test "status subcommand runs successfully" test_status_runs

# ── stamp subcommand ─────────────────────────────────────────────────────

test_stamp_updates_manifest_hashes() {
    # Create a mock manifest with a stale hash
    mkdir -p "$TEST_TMPDIR/global/foundation"
    echo "some content" > "$TEST_TMPDIR/global/foundation/test-file.md"
    echo "other content" > "$TEST_TMPDIR/global/CLAUDE.md"

    # Compute actual hashes
    local actual_hash1 actual_hash2
    actual_hash1=$(python3 -c "import binascii;print(format(binascii.crc32(open('$TEST_TMPDIR/global/foundation/test-file.md','rb').read())&0xFFFFFFFF,'08x'))")
    actual_hash2=$(python3 -c "import binascii;print(format(binascii.crc32(open('$TEST_TMPDIR/global/CLAUDE.md','rb').read())&0xFFFFFFFF,'08x'))")

    # Create manifest with wrong hashes
    cat > "$TEST_TMPDIR/template-sync-manifest.md" <<'EOF'
# Template Sync Manifest

## Tracked Files — Must Be Identical

| File | Hash (CRC32, python binascii) | Date |
|------|------|------|
| `global/foundation/test-file.md` | `00000000` | 2026-01-01 |

## Tracked Files — Intentional Diffs

| File | Hash (CRC32, python binascii) | Diff reason |
|------|------|-------------|
| `global/CLAUDE.md` | `11111111` | Personal: test diff |
EOF

    # Run stamp
    local out
    out=$(SCRIPT_DIR="$TEST_TMPDIR" bash -c "
        source <(sed -n '/^log_info()/,/^}/p' '$SYNC_SCRIPT')
        source <(sed -n '/^log_warn()/,/^}/p' '$SYNC_SCRIPT')
        source <(sed -n '/^cmd_stamp()/,/^}/p' '$SYNC_SCRIPT')
        SCRIPT_DIR='$TEST_TMPDIR'
        cmd_stamp
    " 2>&1)

    # Verify manifest now has correct hashes
    assert_file_contains "$TEST_TMPDIR/template-sync-manifest.md" "$actual_hash1"
    assert_file_contains "$TEST_TMPDIR/template-sync-manifest.md" "$actual_hash2"
    assert_file_not_contains "$TEST_TMPDIR/template-sync-manifest.md" "00000000"
    assert_file_not_contains "$TEST_TMPDIR/template-sync-manifest.md" "11111111"
    assert_contains "$out" "Refreshed"
}
run_test "stamp updates stale manifest hashes" test_stamp_updates_manifest_hashes

test_stamp_skips_missing_files() {
    # Manifest references a file that doesn't exist
    cat > "$TEST_TMPDIR/template-sync-manifest.md" <<'EOF'
# Template Sync Manifest

## Tracked Files — Must Be Identical

| File | Hash (CRC32, python binascii) | Date |
|------|------|------|
| `nonexistent/file.md` | `00000000` | 2026-01-01 |
EOF

    local out rc=0
    out=$(SCRIPT_DIR="$TEST_TMPDIR" bash -c "
        source <(sed -n '/^log_info()/,/^}/p' '$SYNC_SCRIPT')
        source <(sed -n '/^log_warn()/,/^}/p' '$SYNC_SCRIPT')
        source <(sed -n '/^cmd_stamp()/,/^}/p' '$SYNC_SCRIPT')
        SCRIPT_DIR='$TEST_TMPDIR'
        cmd_stamp
    " 2>&1) || rc=$?

    # Should warn but not fail
    assert_eq "0" "$rc"
    assert_contains "$out" "nonexistent/file.md"
}
run_test "stamp skips missing files gracefully" test_stamp_skips_missing_files

test_stamp_shows_in_help() {
    local out
    out=$(bash "$SYNC_SCRIPT" help 2>&1)
    assert_contains "$out" "stamp"
}
run_test "help shows stamp subcommand" test_stamp_shows_in_help

# ── cmd_check: smart drift detection ────────────────────────────────────

# Helper: create a mock environment for cmd_check tests
_setup_check_env() {
    # Personal repo mock
    mkdir -p "$TEST_TMPDIR/personal/global/foundation"
    mkdir -p "$TEST_TMPDIR/personal/global/hooks"
    # Template repo mock
    mkdir -p "$TEST_TMPDIR/template/global/foundation"
    mkdir -p "$TEST_TMPDIR/template/global/hooks"
}

test_check_identical_no_drift_when_template_matches() {
    _setup_check_env

    # Create identical files in personal and template
    echo "same content" > "$TEST_TMPDIR/personal/global/foundation/test.md"
    echo "same content" > "$TEST_TMPDIR/template/global/foundation/test.md"

    # Manifest with stale hash (doesn't match current file)
    cat > "$TEST_TMPDIR/personal/template-sync-manifest.md" <<'EOF'
# Template Sync Manifest

## Tracked Files — Must Be Identical

| File | Hash (CRC32, python binascii) | Date |
|------|------|------|
| `global/foundation/test.md` | `00000000` | 2026-01-01 |

## Tracked Files — Intentional Diffs

| File | Hash (CRC32, python binascii) | Diff reason |
|------|------|-------------|
EOF

    local out
    out=$(bash "$SYNC_SCRIPT" check \
        --repo-root "$TEST_TMPDIR/personal" \
        --template-dir "$TEST_TMPDIR/template" \
        --mobile-dir "$TEST_TMPDIR/nonexistent" 2>&1)

    # Should NOT warn about drift — files are identical despite stale hash
    assert_not_contains "$out" "file(s) drifted"
    assert_not_contains "$out" "differs from template"
}
run_test "check: identical files don't trigger drift even with stale hash" test_check_identical_no_drift_when_template_matches

test_check_identical_drift_when_template_differs() {
    _setup_check_env

    # Personal file was updated, template was NOT
    echo "updated content" > "$TEST_TMPDIR/personal/global/foundation/test.md"
    echo "old content" > "$TEST_TMPDIR/template/global/foundation/test.md"

    local current_hash
    current_hash=$(python3 -c "import binascii;print(format(binascii.crc32(open('$TEST_TMPDIR/personal/global/foundation/test.md','rb').read())&0xFFFFFFFF,'08x'))")

    cat > "$TEST_TMPDIR/personal/template-sync-manifest.md" <<EOF
# Template Sync Manifest

## Tracked Files — Must Be Identical

| File | Hash (CRC32, python binascii) | Date |
|------|------|------|
| \`global/foundation/test.md\` | \`$current_hash\` | 2026-01-01 |

## Tracked Files — Intentional Diffs

| File | Hash (CRC32, python binascii) | Diff reason |
|------|------|-------------|
EOF

    local out
    out=$(bash "$SYNC_SCRIPT" check \
        --repo-root "$TEST_TMPDIR/personal" \
        --template-dir "$TEST_TMPDIR/template" \
        --mobile-dir "$TEST_TMPDIR/nonexistent" 2>&1)

    # Should warn — files genuinely differ
    assert_contains "$out" "differs from template"
}
run_test "check: identical-tracked files warn when template actually differs" test_check_identical_drift_when_template_differs

test_check_identical_fallback_hash_when_no_template() {
    _setup_check_env

    echo "some content" > "$TEST_TMPDIR/personal/global/foundation/test.md"

    cat > "$TEST_TMPDIR/personal/template-sync-manifest.md" <<'EOF'
# Template Sync Manifest

## Tracked Files — Must Be Identical

| File | Hash (CRC32, python binascii) | Date |
|------|------|------|
| `global/foundation/test.md` | `00000000` | 2026-01-01 |

## Tracked Files — Intentional Diffs

| File | Hash (CRC32, python binascii) | Diff reason |
|------|------|-------------|
EOF

    local out
    out=$(bash "$SYNC_SCRIPT" check \
        --repo-root "$TEST_TMPDIR/personal" \
        --template-dir "$TEST_TMPDIR/nonexistent" \
        --mobile-dir "$TEST_TMPDIR/nonexistent" 2>&1)

    # Should fall back to hash-based and warn
    assert_contains "$out" "drifted"
}
run_test "check: falls back to hash-based when template dir missing" test_check_identical_fallback_hash_when_no_template

test_check_intentional_stale_hash_suggests_stamp() {
    _setup_check_env

    echo "personal version" > "$TEST_TMPDIR/personal/global/CLAUDE.md"

    cat > "$TEST_TMPDIR/personal/template-sync-manifest.md" <<'EOF'
# Template Sync Manifest

## Tracked Files — Must Be Identical

| File | Hash (CRC32, python binascii) | Date |
|------|------|------|

## Tracked Files — Intentional Diffs

| File | Hash (CRC32, python binascii) | Diff reason |
|------|------|-------------|
| `global/CLAUDE.md` | `00000000` | Personal: test |
EOF

    local out
    out=$(bash "$SYNC_SCRIPT" check \
        --repo-root "$TEST_TMPDIR/personal" \
        --template-dir "$TEST_TMPDIR/template" \
        --mobile-dir "$TEST_TMPDIR/nonexistent" 2>&1)

    # Should suggest running stamp
    assert_contains "$out" "stamp"
}
run_test "check: intentional-diff stale hash suggests stamp" test_check_intentional_stale_hash_suggests_stamp

test_check_intentional_current_hash_is_clean() {
    _setup_check_env

    echo "personal version" > "$TEST_TMPDIR/personal/global/CLAUDE.md"

    local current_hash
    current_hash=$(python3 -c "import binascii;print(format(binascii.crc32(open('$TEST_TMPDIR/personal/global/CLAUDE.md','rb').read())&0xFFFFFFFF,'08x'))")

    cat > "$TEST_TMPDIR/personal/template-sync-manifest.md" <<EOF
# Template Sync Manifest

## Tracked Files — Must Be Identical

| File | Hash (CRC32, python binascii) | Date |
|------|------|------|

## Tracked Files — Intentional Diffs

| File | Hash (CRC32, python binascii) | Diff reason |
|------|------|-------------|
| \`global/CLAUDE.md\` | \`$current_hash\` | Personal: test |
EOF

    local out
    out=$(bash "$SYNC_SCRIPT" check \
        --repo-root "$TEST_TMPDIR/personal" \
        --template-dir "$TEST_TMPDIR/template" \
        --mobile-dir "$TEST_TMPDIR/nonexistent" 2>&1)

    # Should not warn about CLAUDE.md
    assert_not_contains "$out" "CLAUDE.md"
    assert_contains "$out" "Template: clean"
}
run_test "check: intentional-diff with current hash is clean" test_check_intentional_current_hash_is_clean

# ── Hook deploy: executable permissions ──────────────────────────────────────

test_deploy_hooks_makes_executable() {
    mkdir -p "$TEST_TMPDIR/global/hooks"
    mkdir -p "$TEST_TMPDIR/claude-home/hooks"

    # Create a hook that is NOT executable
    echo '#!/bin/bash' > "$TEST_TMPDIR/global/hooks/my-hook.sh"
    echo 'echo hello' >> "$TEST_TMPDIR/global/hooks/my-hook.sh"
    chmod -x "$TEST_TMPDIR/global/hooks/my-hook.sh"

    (
        GLOBAL_DIR="$TEST_TMPDIR/global"
        CLAUDE_HOME="$TEST_TMPDIR/claude-home"
        source <(sed -n '/^deploy_hooks()/,/^}/p' "$SYNC_SCRIPT" | sed 's/log_info/echo/g')
        deploy_hooks
    )

    # Deployed hook must be executable
    [[ -x "$TEST_TMPDIR/claude-home/hooks/my-hook.sh" ]]
}
run_test "deploy_hooks makes hooks executable even if source isn't" test_deploy_hooks_makes_executable

# ── Hook collect: uncommitted edit safety ────────────────────────────────────

test_collect_hooks_skips_uncommitted() {
    # Set up a git repo as the "config repo"
    create_git_repo "$TEST_TMPDIR/repo"
    mkdir -p "$TEST_TMPDIR/repo/global/hooks"
    echo '#!/bin/bash' > "$TEST_TMPDIR/repo/global/hooks/test-hook.sh"
    echo 'echo original' >> "$TEST_TMPDIR/repo/global/hooks/test-hook.sh"
    (cd "$TEST_TMPDIR/repo" && git add -A && git commit -m "add hook" >/dev/null 2>&1)

    # Now make an uncommitted edit to the repo source
    echo 'echo EDITED IN REPO' >> "$TEST_TMPDIR/repo/global/hooks/test-hook.sh"

    # Set up the deployed hook (different content — simulates live edit)
    mkdir -p "$TEST_TMPDIR/claude-home/hooks"
    echo '#!/bin/bash' > "$TEST_TMPDIR/claude-home/hooks/test-hook.sh"
    echo 'echo deployed version' >> "$TEST_TMPDIR/claude-home/hooks/test-hook.sh"

    # Collect should SKIP this hook because repo has uncommitted changes
    local out
    out=$(
        SCRIPT_DIR="$TEST_TMPDIR/repo"
        GLOBAL_DIR="$TEST_TMPDIR/repo/global"
        CLAUDE_HOME="$TEST_TMPDIR/claude-home"
        PROJECTS_DIR="$TEST_TMPDIR/repo/projects"
        NC='\033[0m'; RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
        mkdir -p "$PROJECTS_DIR"
        source <(sed -n '/^log_info()/,/^}/p' "$SYNC_SCRIPT"; sed -n '/^log_warn()/,/^}/p' "$SYNC_SCRIPT")
        # Source the collect hook logic
        source <(awk '/^cmd_collect\(\)/,/^}/' "$SYNC_SCRIPT" | sed 's/find_project_path/echo/g')
        cmd_collect 2>&1
    )
    assert_contains "$out" "uncommitted"

    # Verify the repo source was NOT overwritten by the deployed version
    assert_file_contains "$TEST_TMPDIR/repo/global/hooks/test-hook.sh" "EDITED IN REPO"
}
run_test "collect_hooks skips hooks with uncommitted repo edits" test_collect_hooks_skips_uncommitted

# ── Hook collect: copies changed hooks ───────────────────────────────────────

test_collect_hooks_copies_changed() {
    # Set up a clean git repo
    create_git_repo "$TEST_TMPDIR/repo"
    mkdir -p "$TEST_TMPDIR/repo/global/hooks"
    echo '#!/bin/bash' > "$TEST_TMPDIR/repo/global/hooks/test-hook.sh"
    echo 'echo original' >> "$TEST_TMPDIR/repo/global/hooks/test-hook.sh"
    (cd "$TEST_TMPDIR/repo" && git add -A && git commit -m "add hook" >/dev/null 2>&1)

    # Set up a DIFFERENT deployed hook (simulates live modification)
    mkdir -p "$TEST_TMPDIR/claude-home/hooks"
    echo '#!/bin/bash' > "$TEST_TMPDIR/claude-home/hooks/test-hook.sh"
    echo 'echo modified at deploy target' >> "$TEST_TMPDIR/claude-home/hooks/test-hook.sh"

    # Collect should pick up the changed deployed hook
    local out
    out=$(
        SCRIPT_DIR="$TEST_TMPDIR/repo"
        GLOBAL_DIR="$TEST_TMPDIR/repo/global"
        CLAUDE_HOME="$TEST_TMPDIR/claude-home"
        PROJECTS_DIR="$TEST_TMPDIR/repo/projects"
        NC='\033[0m'; RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
        mkdir -p "$PROJECTS_DIR"
        source <(sed -n '/^log_info()/,/^}/p' "$SYNC_SCRIPT"; sed -n '/^log_warn()/,/^}/p' "$SYNC_SCRIPT")
        source <(awk '/^cmd_collect\(\)/,/^}/' "$SYNC_SCRIPT" | sed 's/find_project_path/echo/g')
        cmd_collect 2>&1
    )
    assert_contains "$out" "Collected hook"

    # Verify the repo source was updated with the deployed content
    assert_file_contains "$TEST_TMPDIR/repo/global/hooks/test-hook.sh" "modified at deploy target"
}
run_test "collect_hooks copies changed deployed hooks to repo" test_collect_hooks_copies_changed

# ── Project rule deploy ──────────────────────────────────────────────────────

test_deploy_project_rules_copies_to_target() {
    # Set up mock project rules in repo
    mkdir -p "$TEST_TMPDIR/repo/projects/myproject/rules"
    echo "# My Project Rules" > "$TEST_TMPDIR/repo/projects/myproject/rules/CLAUDE.md"

    # Set up mock project target
    mkdir -p "$TEST_TMPDIR/myproject"

    # Deploy should copy rules to the project's .claude/ dir
    (
        PROJECTS_DIR="$TEST_TMPDIR/repo/projects"
        NC='\033[0m'; RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
        source <(sed -n '/^log_info()/,/^}/p' "$SYNC_SCRIPT"; sed -n '/^log_warn()/,/^}/p' "$SYNC_SCRIPT")
        # Override find_project_path to return our mock
        find_project_path() { [[ "$1" == "myproject" ]] && echo "$TEST_TMPDIR/myproject"; }
        source <(sed -n '/^deploy_project_rules()/,/^}/p' "$SYNC_SCRIPT")
        deploy_project_rules
    )

    assert_file_exists "$TEST_TMPDIR/myproject/.claude/CLAUDE.md"
    assert_file_contains "$TEST_TMPDIR/myproject/.claude/CLAUDE.md" "My Project Rules"
}
run_test "deploy_project_rules copies rules to target project" test_deploy_project_rules_copies_to_target

test_deploy_project_rules_skips_missing_project() {
    # Set up mock project rules but NO target project dir
    mkdir -p "$TEST_TMPDIR/repo/projects/ghost/rules"
    echo "# Ghost Rules" > "$TEST_TMPDIR/repo/projects/ghost/rules/CLAUDE.md"

    local out
    out=$(
        PROJECTS_DIR="$TEST_TMPDIR/repo/projects"
        NC='\033[0m'; RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
        source <(sed -n '/^log_info()/,/^}/p' "$SYNC_SCRIPT"; sed -n '/^log_warn()/,/^}/p' "$SYNC_SCRIPT")
        find_project_path() { echo ""; }
        source <(sed -n '/^deploy_project_rules()/,/^}/p' "$SYNC_SCRIPT")
        deploy_project_rules 2>&1
    )
    assert_contains "$out" "not found"
}
run_test "deploy_project_rules skips projects not on this machine" test_deploy_project_rules_skips_missing_project

test_collect_project_rules_from_live() {
    # Set up repo project rules dir (empty)
    mkdir -p "$TEST_TMPDIR/repo/projects/myproject/rules"

    # Set up live project with modified rules
    mkdir -p "$TEST_TMPDIR/myproject/.claude"
    echo "# Modified at live" > "$TEST_TMPDIR/myproject/.claude/CLAUDE.md"

    # Collect should pick up the live rule
    local out
    out=$(
        SCRIPT_DIR="$TEST_TMPDIR/repo"
        GLOBAL_DIR="$TEST_TMPDIR/repo/global"
        CLAUDE_HOME="$TEST_TMPDIR/claude-home"
        PROJECTS_DIR="$TEST_TMPDIR/repo/projects"
        NC='\033[0m'; RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
        mkdir -p "$CLAUDE_HOME" "$GLOBAL_DIR"
        # Symlink CLAUDE.md so collect doesn't try to copy it
        ln -sf "$GLOBAL_DIR/CLAUDE.md" "$CLAUDE_HOME/CLAUDE.md" 2>/dev/null || true
        touch "$GLOBAL_DIR/CLAUDE.md"
        source <(sed -n '/^log_info()/,/^}/p' "$SYNC_SCRIPT"; sed -n '/^log_warn()/,/^}/p' "$SYNC_SCRIPT")
        find_project_path() { [[ "$1" == "myproject" ]] && echo "$TEST_TMPDIR/myproject"; }
        source <(awk '/^cmd_collect\(\)/,/^}/' "$SYNC_SCRIPT")
        cmd_collect 2>&1
    )
    assert_contains "$out" "Collected"
    assert_file_contains "$TEST_TMPDIR/repo/projects/myproject/rules/CLAUDE.md" "Modified at live"
}
run_test "collect picks up modified project rules from live" test_collect_project_rules_from_live

# ── Inbox pending count (cmd_status) ─────────────────────────────────────────

# Helper: extract the inbox pending count from sync.sh status output given an inbox file
_run_inbox_count() {
    local inbox_file="$1"
    local cross_dir
    cross_dir="$(dirname "$inbox_file")"

    # Source just the status function's inbox block by running it in a subshell
    awk '
        /# Inbox pending count/,/^        fi$/ {
            # Replace "$cross_dir" variable with our actual path
            gsub(/\$cross_dir/, ENVIRON["CROSS_DIR"])
            print
        }
    ' CROSS_DIR="$cross_dir" "$SYNC_SCRIPT" 2>/dev/null | bash 2>/dev/null || true
}

test_inbox_count_empty_inbox() {
    # inbox.md with only header + format docs + marker (no real tasks)
    mkdir -p "$TEST_TMPDIR/cross-project"
    cat > "$TEST_TMPDIR/cross-project/inbox.md" <<'EOF'
# Cross-Project Inbox

One-off tasks passed between projects and machines.

## Format

```
## [project-name]
- [ ] [Task description]
  Context: [Any relevant detail]
```

<!-- Pending tasks appear below this line -->
EOF

    local count
    count=$(awk '/<!-- Pending tasks appear below this line -->/{found=1; next} found && /^\- \[ \]/{count++} END{print count+0}' \
        "$TEST_TMPDIR/cross-project/inbox.md" 2>/dev/null)
    assert_eq "0" "$count" "empty inbox (with format docs above marker) should count 0 tasks"
}
run_test "inbox count: empty inbox with format docs above marker reports 0" test_inbox_count_empty_inbox

test_inbox_count_real_tasks_after_marker() {
    # inbox.md with actual tasks below the marker
    mkdir -p "$TEST_TMPDIR/cross-project"
    cat > "$TEST_TMPDIR/cross-project/inbox.md" <<'EOF'
# Cross-Project Inbox

## Format

```
- [ ] [Task description]
```

<!-- Pending tasks appear below this line -->

## myproject
- [ ] Do something important
- [ ] Do another thing
EOF

    local count
    count=$(awk '/<!-- Pending tasks appear below this line -->/{found=1; next} found && /^\- \[ \]/{count++} END{print count+0}' \
        "$TEST_TMPDIR/cross-project/inbox.md" 2>/dev/null)
    assert_eq "2" "$count" "should count 2 tasks after the marker"
}
run_test "inbox count: real tasks after marker are counted correctly" test_inbox_count_real_tasks_after_marker

test_inbox_count_only_counts_after_marker() {
    # Tasks in format docs (above marker) must NOT be counted; only tasks below marker count
    mkdir -p "$TEST_TMPDIR/cross-project"
    cat > "$TEST_TMPDIR/cross-project/inbox.md" <<'EOF'
# Cross-Project Inbox

```
- [ ] example task in docs
```

<!-- Pending tasks appear below this line -->
- [ ] real task one
EOF

    local count
    count=$(awk '/<!-- Pending tasks appear below this line -->/{found=1; next} found && /^\- \[ \]/{count++} END{print count+0}' \
        "$TEST_TMPDIR/cross-project/inbox.md" 2>/dev/null)
    assert_eq "1" "$count" "only task after the marker should be counted (not the one in format docs)"
}
run_test "inbox count: tasks above marker (in format docs) are not counted" test_inbox_count_only_counts_after_marker

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
