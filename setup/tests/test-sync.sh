#!/usr/bin/env bash
# Tests for sync.sh — focused on testable functions and structural behaviors
source "$(dirname "$0")/test-helpers.sh"

SYNC_SCRIPT="$REPO_ROOT/sync.sh"
SYNC_LIB_DIR="$REPO_ROOT/sync-lib"

suite_header "sync.sh"

# ── Help/usage ───────────────────────────────────────────────────────────────

test_help() {
    local out
    out=$(bash "$SYNC_SCRIPT" help 2>&1)
    assert_contains "$out" "setup"
    assert_contains "$out" "deploy"
    assert_contains "$out" "recover"
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
    # HOME is sandboxed to TEST_TMPDIR (test-helpers.sh setup_test), so create
    # the project there to exercise the "$HOME/$name" home-directory branch.
    mkdir -p "$HOME/mock-config-repo"
    local result
    result=$(
        SCRIPT_DIR="$REPO_ROOT"
        source "$SYNC_LIB_DIR/common.sh"
        find_project_path "mock-config-repo"
    )
    assert_eq "$HOME/mock-config-repo" "$result"
}
run_test "find_project_path finds project in home directory" test_find_project_by_home_dir

test_find_project_registry_fallback() {
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
        source "$SYNC_LIB_DIR/common.sh"
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
        source "$SYNC_LIB_DIR/common.sh"
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
        source <(sed -n '/^deploy_hooks()/,/^}/p' "$SYNC_LIB_DIR/deploy.sh" | sed 's/log_info/echo/g')
        deploy_hooks
    )

    assert_file_exists "$TEST_TMPDIR/claude-home/hooks/test-hook.sh"
    # Should be executable
    [[ -x "$TEST_TMPDIR/claude-home/hooks/test-hook.sh" ]]
}
run_test "deploy_hooks copies hook files and makes them executable" test_deploy_hooks_copies_files

# ── deploy_skills ────────────────────────────────────────────────────────────
# MEASURED 2026-09-23 on deck and deck2: their ~/.claude/skills/<name> are symlinks back
# into the repo, so `cp -r src/* dst/` copies files onto themselves, cp exits non-zero,
# and sync.sh's `set -euo pipefail` ABORTS THE WHOLE DEPLOY at this step. Everything after
# it never runs — including deploy_settings. deck's settings.json was last written
# 2026-06-03: nearly four months of a stale hook configuration, with the newest hooks
# present on disk but wired into nothing, and no .sync-failed marker to say so.

_skills_fixture() {  # builds src + a sandboxed CLAUDE_CONFIG_DIR, echoes the src path
    mkdir -p "$TEST_TMPDIR/repo/global/skills/lrn" "$TEST_TMPDIR/cfg"
    printf '# lrn\n' > "$TEST_TMPDIR/repo/global/skills/lrn/SKILL.md"
    mkdir -p "$TEST_TMPDIR/repo/global/skills/lrn/references"
    printf 'ref\n' > "$TEST_TMPDIR/repo/global/skills/lrn/references/patterns.md"
}

_run_deploy_skills() {  # runs it under set -e, exactly as sync.sh does; echoes rc
    # NOT `( ... ) || rc=$?` — a compound command in a || list runs with set -e DISABLED,
    # so the subshell would survive the very failure this is meant to catch. Capture $?
    # on its own line instead. (Same trap the header of run_test documents.)
    local rc
    (
        set -euo pipefail
        SCRIPT_DIR="$TEST_TMPDIR/repo"
        CLAUDE_CONFIG_DIR="$TEST_TMPDIR/cfg"
        source <(sed -n '/^deploy_skills()/,/^}/p' "$SYNC_LIB_DIR/deploy.sh" | sed 's/log_info/echo/g')
        deploy_skills
    ) >/dev/null 2>&1
    rc=$?
    printf '%s' "$rc"
}

_deploy_skills_output() {  # same run, but returns stdout+stderr instead of the rc
    (
        set -euo pipefail
        SCRIPT_DIR="$TEST_TMPDIR/repo"
        CLAUDE_CONFIG_DIR="$TEST_TMPDIR/cfg"
        source <(sed -n '/^deploy_skills()/,/^}/p' "$SYNC_LIB_DIR/deploy.sh" | sed 's/log_info/echo/g')
        deploy_skills
    ) 2>&1 || true
}

test_deploy_skills_normal_case() {
    _skills_fixture
    local rc; rc=$(_run_deploy_skills)
    echo "    measured rc=$rc, SKILL.md deployed=$( [ -f "$TEST_TMPDIR/cfg/skills/lrn/SKILL.md" ] && echo yes || echo no )"
    assert_eq "0" "$rc" "an ordinary deploy must exit 0" || return 1
    assert_file_exists "$TEST_TMPDIR/cfg/skills/lrn/SKILL.md"
}
run_test "deploy_skills copies skills in the ordinary case" test_deploy_skills_normal_case

test_deploy_skills_survives_self_referential_symlink() {
    _skills_fixture
    mkdir -p "$TEST_TMPDIR/cfg/skills"
    ln -s "$TEST_TMPDIR/repo/global/skills/lrn" "$TEST_TMPDIR/cfg/skills/lrn"
    local rc out
    rc=$(_run_deploy_skills)
    out=$(_deploy_skills_output)
    echo "    measured rc=$rc, same-file errors=$(printf '%s' "$out" | grep -c 'same file' || true)"
    # Assert the ERROR IS ABSENT, not merely that this box survived it: WSL's bash carries
    # on past the failing cp while the Decks' aborts, so an exit-code-only assertion would
    # pass here and still ship the bug to the machines that actually break.
    assert_not_contains "$out" "same file" "a skill symlinked to its source must not be copied onto itself" || return 1
    assert_eq "0" "$rc" "a skill already symlinked to its source must not abort the deploy" || return 1
    assert_file_exists "$TEST_TMPDIR/repo/global/skills/lrn/SKILL.md"
}
run_test "deploy_skills survives a skill symlinked back to its source" test_deploy_skills_survives_self_referential_symlink

test_deploy_skills_no_skills_returns_zero() {
    mkdir -p "$TEST_TMPDIR/repo/global/skills" "$TEST_TMPDIR/cfg"
    local rc; rc=$(_run_deploy_skills)
    echo "    measured rc=$rc with zero skills present"
    # `[ "$deployed" -gt 0 ] && log_info ...` is the function's LAST command, so with no
    # skills it returns 1 and set -e aborts the deploy on a machine that simply has none.
    assert_eq "0" "$rc" "no skills to deploy is not a failure"
}
run_test "deploy_skills returns 0 when there is nothing to deploy" test_deploy_skills_no_skills_returns_zero

# ── check_settings_health ────────────────────────────────────────────────────

test_settings_health_warns_missing_permissions() {
    mkdir -p "$TEST_TMPDIR/.cc-mirror/mclaude/config"
    echo '{"hooks": {}, "enabledPlugins": []}' > "$TEST_TMPDIR/.cc-mirror/mclaude/config/settings.json"

    local out
    out=$(
        HOME="$TEST_TMPDIR"
        CC_MIRROR_DIR="$TEST_TMPDIR/.cc-mirror/mclaude"
        source <(sed -n '/^check_settings_health()/,/^}/p' "$SYNC_LIB_DIR/deploy.sh" \
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
        CC_MIRROR_DIR="$TEST_TMPDIR/.cc-mirror/mclaude"
        source <(sed -n '/^check_settings_health()/,/^}/p' "$SYNC_LIB_DIR/deploy.sh" \
            | sed 's/log_warn/echo WARN/g; s/log_info/echo INFO/g')
        check_settings_health
    )
    assert_not_contains "$out" "WARN"
}
run_test "check_settings_health is silent when all blocks present" test_settings_health_clean

# ── Platform detection ───────────────────────────────────────────────────────

test_platform_detection() {
    # Verify platform detection produces a known value for the current machine
    local platform
    platform=$(bash -c "
        source <(head -30 '$SYNC_SCRIPT')
        echo \$PLATFORM
    ")
    assert_neq "" "$platform" "PLATFORM should be set"
    # Must be one of the known platforms
    case "$platform" in
        linux|wsl|macos|windows) ;; # valid
        *) fail "unknown PLATFORM value: $platform" ;;
    esac
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

# ── stamp removed (v1.0) ─────────────────────────────────────────────────────

test_stamp_removed_shows_deprecation() {
    local out rc=0
    out=$(bash "$SYNC_SCRIPT" stamp 2>&1) || rc=$?
    assert_neq "0" "$rc" "stamp should fail with non-zero exit"
    assert_contains "$out" "removed" "should mention removal"
}
run_test "stamp command shows deprecation message" test_stamp_removed_shows_deprecation

# ── Module structure (CFG-163) ───────────────────────────────────────────────

test_common_module_exports_functions() {
    local out
    out=$(
        SCRIPT_DIR="$REPO_ROOT"
        source "$SYNC_LIB_DIR/common.sh"
        type -t find_project_path
        type -t _extract_manifest_section
        type -t get_hostname
    )
    assert_eq "function
function
function" "$out"
}
run_test "common.sh exports find_project_path, _extract_manifest_section, get_hostname" test_common_module_exports_functions

test_check_module_exports_functions() {
    local out
    out=$(
        SCRIPT_DIR="$REPO_ROOT"
        CLAUDE_HOME="$TEST_TMPDIR"
        RED='' GREEN='' YELLOW='' NC=''
        log_info() { :; }; log_warn() { :; }; log_error() { :; }
        source "$SYNC_LIB_DIR/common.sh"
        source "$SYNC_LIB_DIR/check.sh"
        type -t cmd_check
        type -t cmd_check_template
        type -t check_personal_data_leaks
        type -t check_template_drift
    )
    assert_eq "function
function
function
function" "$out"
}
run_test "check.sh exports cmd_check, cmd_check_template, check_personal_data_leaks, check_template_drift" test_check_module_exports_functions

# ── cmd_check: smart drift detection (CFG-26) ────────────────────────────────

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

    cat > "$TEST_TMPDIR/personal/template-sync-manifest.md" <<'EOF'
# Template Sync Manifest

## Tracked Files — Must Be Identical

| File | Notes |
|------|-------|
| `global/foundation/test.md` | Test file |

## Tracked Files — Intentional Diffs

| File | Diff reason |
|------|-------------|
EOF

    local out
    out=$(bash "$SYNC_SCRIPT" check \
        --repo-root "$TEST_TMPDIR/personal" \
        --template-dir "$TEST_TMPDIR/template" \
        --mobile-dir "$TEST_TMPDIR/nonexistent" 2>&1)

    # Should NOT warn about drift — files are identical
    assert_not_contains "$out" "file(s) drifted"
    assert_not_contains "$out" "differs from template"
}
run_test "check: identical files don't trigger drift" test_check_identical_no_drift_when_template_matches

test_check_identical_drift_when_template_differs() {
    _setup_check_env

    # Personal file was updated, template was NOT
    echo "updated content" > "$TEST_TMPDIR/personal/global/foundation/test.md"
    echo "old content" > "$TEST_TMPDIR/template/global/foundation/test.md"

    cat > "$TEST_TMPDIR/personal/template-sync-manifest.md" <<'EOF'
# Template Sync Manifest

## Tracked Files — Must Be Identical

| File | Notes |
|------|-------|
| `global/foundation/test.md` | Test file |

## Tracked Files — Intentional Diffs

| File | Diff reason |
|------|-------------|
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

test_check_skips_silently_when_no_template() {
    _setup_check_env

    echo "some content" > "$TEST_TMPDIR/personal/global/foundation/test.md"

    cat > "$TEST_TMPDIR/personal/template-sync-manifest.md" <<'EOF'
# Template Sync Manifest

## Tracked Files — Must Be Identical

| File | Notes |
|------|-------|
| `global/foundation/test.md` | Test file |

## Tracked Files — Intentional Diffs

| File | Diff reason |
|------|-------------|
EOF

    local out
    out=$(bash "$SYNC_SCRIPT" check \
        --repo-root "$TEST_TMPDIR/personal" \
        --template-dir "$TEST_TMPDIR/nonexistent" \
        --mobile-dir "$TEST_TMPDIR/nonexistent" 2>&1)

    # Template dir missing — should skip template checks
    assert_not_contains "$out" "drifted" "no drift when template dir is missing"
}
run_test "check: skips template drift when template dir missing" test_check_skips_silently_when_no_template

test_check_intentional_diff_reports_when_files_differ() {
    _setup_check_env

    echo "personal version" > "$TEST_TMPDIR/personal/global/CLAUDE.md"
    echo "template version" > "$TEST_TMPDIR/template/global/CLAUDE.md"

    cat > "$TEST_TMPDIR/personal/template-sync-manifest.md" <<'EOF'
# Template Sync Manifest

## Tracked Files — Must Be Identical

| File | Notes |
|------|-------|

## Tracked Files — Intentional Diffs

| File | Diff reason |
|------|-------------|
| `global/CLAUDE.md` | Personal: test |
EOF

    local out
    out=$(bash "$SYNC_SCRIPT" check \
        --repo-root "$TEST_TMPDIR/personal" \
        --template-dir "$TEST_TMPDIR/template" \
        --mobile-dir "$TEST_TMPDIR/nonexistent" 2>&1)

    # Intentional diffs that actually differ are expected — should not be errors
    assert_not_contains "$out" "error" "intentional diff should not be an error"
}
run_test "check: intentional diff noted when files actually differ" test_check_intentional_diff_reports_when_files_differ

test_check_intentional_identical_warns_promotion() {
    _setup_check_env

    # Same content in both — might be ready to promote to "Must Be Identical"
    echo "same content" > "$TEST_TMPDIR/personal/global/CLAUDE.md"
    echo "same content" > "$TEST_TMPDIR/template/global/CLAUDE.md"

    cat > "$TEST_TMPDIR/personal/template-sync-manifest.md" <<'EOF'
# Template Sync Manifest

## Tracked Files — Must Be Identical

| File | Notes |
|------|-------|

## Tracked Files — Intentional Diffs

| File | Diff reason |
|------|-------------|
| `global/CLAUDE.md` | Personal: test |
EOF

    local out
    out=$(bash "$SYNC_SCRIPT" check \
        --repo-root "$TEST_TMPDIR/personal" \
        --template-dir "$TEST_TMPDIR/template" \
        --mobile-dir "$TEST_TMPDIR/nonexistent" 2>&1)

    # When an intentional-diff file becomes identical, suggest promotion
    assert_contains "$out" "CLAUDE.md" "should mention the now-identical file"
}
run_test "check: warns when intentional-diff file becomes identical" test_check_intentional_identical_warns_promotion

# ── recover (formerly collect): hook staleness guard (P1 fix) ────────────────

# Helper: create a mock environment for recover hook tests
_setup_recover_env() {
    # Mock config repo with git
    create_git_repo "$TEST_TMPDIR/config-repo"
    mkdir -p "$TEST_TMPDIR/config-repo/global/hooks"
    mkdir -p "$TEST_TMPDIR/config-repo/setup/projects"

    # Mock deployed hooks dir
    mkdir -p "$TEST_TMPDIR/claude-home/hooks"
}

# Helper: source cmd_recover with all dependencies
_source_recover() {
    NC='\033[0m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
    log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
    log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
    find_project_path() { echo ""; }
    source <(sed -n '/^cmd_recover()/,/^}/p' "$SYNC_LIB_DIR/recover.sh")
}

test_collect_skips_when_repo_hook_is_newer() {
    _setup_recover_env

    # Repo hook: committed recently (new version with extra features)
    echo '#!/bin/bash
echo "new version with checks 19-24"' > "$TEST_TMPDIR/config-repo/global/hooks/test-hook.sh"
    (
        cd "$TEST_TMPDIR/config-repo"
        git add global/hooks/test-hook.sh
        git commit -m "Add checks 19-24" >/dev/null 2>&1
    )

    # Deployed hook: older stale version (simulate never-deployed machine)
    echo '#!/bin/bash
echo "old version"' > "$TEST_TMPDIR/claude-home/hooks/test-hook.sh"
    # Backdate the deployed file to be clearly older than the commit
    touch -t 202603010000.00 "$TEST_TMPDIR/claude-home/hooks/test-hook.sh"

    local out
    out=$(
        SCRIPT_DIR="$TEST_TMPDIR/config-repo"
        GLOBAL_DIR="$TEST_TMPDIR/config-repo/global"
        CLAUDE_HOME="$TEST_TMPDIR/claude-home"
        PROJECTS_DIR="$TEST_TMPDIR/config-repo/setup/projects"
        HOME="$TEST_TMPDIR"
        _source_recover
        cmd_recover --emergency 2>&1
    )

    # Repo version should NOT have been overwritten by stale deployed version
    assert_file_contains "$TEST_TMPDIR/config-repo/global/hooks/test-hook.sh" "checks 19-24"
    assert_contains "$out" "repo version is newer"
}
run_test "recover: skips hook when repo version is newer than deployed" test_collect_skips_when_repo_hook_is_newer

test_collect_copies_when_deployed_is_newer() {
    _setup_recover_env

    # Repo hook: committed a while ago (baseline version)
    echo '#!/bin/bash
echo "baseline"' > "$TEST_TMPDIR/config-repo/global/hooks/test-hook.sh"
    (
        cd "$TEST_TMPDIR/config-repo"
        git add global/hooks/test-hook.sh
        git commit -m "Add baseline hook" --date="2026-03-01T00:00:00" >/dev/null 2>&1
    )

    # Deployed hook: genuinely newer (edited on this machine during a session)
    echo '#!/bin/bash
echo "locally improved version"' > "$TEST_TMPDIR/claude-home/hooks/test-hook.sh"
    # Touch to current time (newer than the old commit)
    touch "$TEST_TMPDIR/claude-home/hooks/test-hook.sh"

    local out
    out=$(
        SCRIPT_DIR="$TEST_TMPDIR/config-repo"
        GLOBAL_DIR="$TEST_TMPDIR/config-repo/global"
        CLAUDE_HOME="$TEST_TMPDIR/claude-home"
        PROJECTS_DIR="$TEST_TMPDIR/config-repo/setup/projects"
        HOME="$TEST_TMPDIR"
        _source_recover
        cmd_recover --emergency 2>&1
    )

    # Deployed version should have been collected (repo updated)
    assert_file_contains "$TEST_TMPDIR/config-repo/global/hooks/test-hook.sh" "locally improved"
    assert_contains "$out" "Collected hook"
}
run_test "recover: copies hook when deployed is genuinely newer" test_collect_copies_when_deployed_is_newer

test_collect_skips_identical_hooks() {
    _setup_recover_env

    # Same content in both
    echo '#!/bin/bash
echo "same version"' > "$TEST_TMPDIR/config-repo/global/hooks/test-hook.sh"
    (
        cd "$TEST_TMPDIR/config-repo"
        git add global/hooks/test-hook.sh
        git commit -m "Add hook" >/dev/null 2>&1
    )
    cp "$TEST_TMPDIR/config-repo/global/hooks/test-hook.sh" "$TEST_TMPDIR/claude-home/hooks/test-hook.sh"

    local out
    out=$(
        SCRIPT_DIR="$TEST_TMPDIR/config-repo"
        GLOBAL_DIR="$TEST_TMPDIR/config-repo/global"
        CLAUDE_HOME="$TEST_TMPDIR/claude-home"
        PROJECTS_DIR="$TEST_TMPDIR/config-repo/setup/projects"
        HOME="$TEST_TMPDIR"
        _source_recover
        cmd_recover --emergency 2>&1
    )

    # Should not mention collecting or skipping — files are identical
    assert_not_contains "$out" "Collected hook"
    assert_not_contains "$out" "repo version is newer"
}
run_test "recover: skips identical hooks silently" test_collect_skips_identical_hooks

# ── recover: directory staleness guard (CFG-128) ─────────────────────────────

test_collect_skips_dir_file_when_repo_is_newer() {
    _setup_recover_env

    # Repo directory file: committed recently
    mkdir -p "$TEST_TMPDIR/config-repo/global/foundation"
    echo "new foundation content" > "$TEST_TMPDIR/config-repo/global/foundation/test-file.md"
    (
        cd "$TEST_TMPDIR/config-repo"
        git add global/foundation/test-file.md
        git commit -m "Add new foundation file" >/dev/null 2>&1
    )

    # Deployed directory file: older stale version (non-symlinked)
    mkdir -p "$TEST_TMPDIR/claude-home/foundation"
    echo "old stale content" > "$TEST_TMPDIR/claude-home/foundation/test-file.md"
    touch -t 202603010000.00 "$TEST_TMPDIR/claude-home/foundation/test-file.md"

    local out
    out=$(
        SCRIPT_DIR="$TEST_TMPDIR/config-repo"
        GLOBAL_DIR="$TEST_TMPDIR/config-repo/global"
        CLAUDE_HOME="$TEST_TMPDIR/claude-home"
        PROJECTS_DIR="$TEST_TMPDIR/config-repo/setup/projects"
        HOME="$TEST_TMPDIR"
        _source_recover
        cmd_recover --emergency 2>&1
    )

    # Repo version should NOT have been overwritten by stale deployed version
    assert_file_contains "$TEST_TMPDIR/config-repo/global/foundation/test-file.md" "new foundation content"
    assert_contains "$out" "repo version is newer"
}
run_test "recover: skips directory file when repo version is newer than deployed (CFG-128)" test_collect_skips_dir_file_when_repo_is_newer

test_collect_copies_dir_file_when_deployed_is_newer() {
    _setup_recover_env

    # Repo directory file: committed a while ago
    mkdir -p "$TEST_TMPDIR/config-repo/global/reference"
    echo "baseline reference" > "$TEST_TMPDIR/config-repo/global/reference/test-ref.md"
    (
        cd "$TEST_TMPDIR/config-repo"
        git add global/reference/test-ref.md
        git commit -m "Add baseline reference" --date="2026-03-01T00:00:00" >/dev/null 2>&1
    )

    # Deployed directory file: genuinely newer (edited on this machine)
    mkdir -p "$TEST_TMPDIR/claude-home/reference"
    echo "locally improved reference" > "$TEST_TMPDIR/claude-home/reference/test-ref.md"
    touch "$TEST_TMPDIR/claude-home/reference/test-ref.md"

    local out
    out=$(
        SCRIPT_DIR="$TEST_TMPDIR/config-repo"
        GLOBAL_DIR="$TEST_TMPDIR/config-repo/global"
        CLAUDE_HOME="$TEST_TMPDIR/claude-home"
        PROJECTS_DIR="$TEST_TMPDIR/config-repo/setup/projects"
        HOME="$TEST_TMPDIR"
        _source_recover
        cmd_recover --emergency 2>&1
    )

    # Deployed version should have been collected (repo updated)
    assert_file_contains "$TEST_TMPDIR/config-repo/global/reference/test-ref.md" "locally improved reference"
    assert_contains "$out" "Collected:"
}
run_test "recover: copies directory file when deployed is genuinely newer (CFG-128)" test_collect_copies_dir_file_when_deployed_is_newer

test_collect_skips_identical_dir_files() {
    _setup_recover_env

    # Same content in both
    mkdir -p "$TEST_TMPDIR/config-repo/global/knowledge"
    echo "same knowledge" > "$TEST_TMPDIR/config-repo/global/knowledge/test-kb.md"
    (
        cd "$TEST_TMPDIR/config-repo"
        git add global/knowledge/test-kb.md
        git commit -m "Add knowledge file" >/dev/null 2>&1
    )
    mkdir -p "$TEST_TMPDIR/claude-home/knowledge"
    cp "$TEST_TMPDIR/config-repo/global/knowledge/test-kb.md" "$TEST_TMPDIR/claude-home/knowledge/test-kb.md"

    local out
    out=$(
        SCRIPT_DIR="$TEST_TMPDIR/config-repo"
        GLOBAL_DIR="$TEST_TMPDIR/config-repo/global"
        CLAUDE_HOME="$TEST_TMPDIR/claude-home"
        PROJECTS_DIR="$TEST_TMPDIR/config-repo/setup/projects"
        HOME="$TEST_TMPDIR"
        _source_recover
        cmd_recover --emergency 2>&1
    )

    # Should not mention collecting for this file
    assert_not_contains "$out" "test-kb.md"
}
run_test "recover: skips identical directory files silently (CFG-128)" test_collect_skips_identical_dir_files

# ── v1.0: collect → recover rename (CFG-291) ─────────────────────────────────

test_recover_requires_emergency_flag() {
    local out rc=0
    out=$(bash "$SYNC_SCRIPT" recover 2>&1) || rc=$?
    assert_neq "0" "$rc" "recover without --emergency should fail"
    assert_contains "$out" "--emergency" "should mention --emergency flag"
}
run_test "v1.0: recover requires --emergency flag" test_recover_requires_emergency_flag

test_recover_emergency_runs() {
    # Just test that the command is accepted (actual collect logic tested separately)
    local out rc=0
    out=$(bash "$SYNC_SCRIPT" recover --emergency 2>&1) || rc=$?
    # Should run (may fail due to env, but should not say "unknown command")
    assert_not_contains "$out" "Usage:" "recover --emergency should be a recognized command"
}
run_test "v1.0: recover --emergency is accepted" test_recover_emergency_runs

test_collect_shows_deprecation() {
    local out rc=0
    out=$(bash "$SYNC_SCRIPT" collect 2>&1) || rc=$?
    assert_contains "$out" "recover" "collect should point to recover"
}
run_test "v1.0: collect shows deprecation pointing to recover" test_collect_shows_deprecation

test_help_shows_recover_not_collect() {
    local out
    out=$(bash "$SYNC_SCRIPT" help 2>&1)
    assert_contains "$out" "recover" "help should show recover command"
}
run_test "v1.0: help shows recover command" test_help_shows_recover_not_collect

# ── v1.0: modular split verification (CFG-163) ───────────────────────────────

test_sync_lib_modules_exist() {
    assert_file_exists "$SYNC_LIB_DIR/deploy.sh" "sync-lib/deploy.sh should exist"
    assert_file_exists "$SYNC_LIB_DIR/recover.sh" "sync-lib/recover.sh should exist"
    assert_file_exists "$SYNC_LIB_DIR/setup.sh" "sync-lib/setup.sh should exist"
    assert_file_exists "$SYNC_LIB_DIR/status.sh" "sync-lib/status.sh should exist"
    assert_file_not_exists "$SYNC_LIB_DIR/stamp.sh" "sync-lib/stamp.sh should be removed (v1.0)"
}
run_test "v1.0: sync-lib modules exist after split" test_sync_lib_modules_exist

test_dead_template_push_stub_removed() {
    local stub="$SYNC_LIB_DIR/template-push.sh"
    if [ -f "$stub" ]; then
        # File exists — check it's not the dead stub
        assert_not_contains "$(cat "$stub")" "not yet implemented" \
            "dead template-push.sh stub should be removed (CFG-281)"
    fi
    # If file doesn't exist, that's also correct
}
run_test "v1.0: dead template-push.sh stub removed (CFG-281)" test_dead_template_push_stub_removed

test_dispatcher_is_thin() {
    local lines
    lines=$(wc -l < "$SYNC_SCRIPT")
    local under_200="yes"
    [ "$lines" -ge 200 ] && under_200="no (got $lines)"
    assert_eq "yes" "$under_200" "sync.sh dispatcher should be under 200 lines"
}
run_test "v1.0: sync.sh dispatcher is thin after split" test_dispatcher_is_thin

# ── v1.0: managed-file header in deployed hooks (CFG-291) ────────────────────

test_deploy_hooks_adds_managed_header() {
    local test_dir="$TEST_TMPDIR/deploy-header-test"
    local mock_home="$test_dir/home/.claude"
    local mock_repo="$test_dir/repo"
    mkdir -p "$mock_home/hooks" "$mock_repo/global/hooks"

    # Create a hook source file
    cat > "$mock_repo/global/hooks/test-hook.sh" << 'HOOK'
#!/usr/bin/env bash
echo "I am a hook"
HOOK

    # Source deploy_hooks and run it
    local out
    out=$(
        CLAUDE_HOME="$mock_home"
        GLOBAL_DIR="$mock_repo/global"
        SCRIPT_DIR="$mock_repo"
        PLATFORM="linux"
        source <(sed -n '/^log_info()/,/^}/p' "$SYNC_SCRIPT")
        source <(sed -n '/^log_warn()/,/^}/p' "$SYNC_SCRIPT")
        source <(sed -n '/^deploy_hooks()/,/^}/p' "$SYNC_LIB_DIR/deploy.sh")
        deploy_hooks 2>&1
    )

    local deployed="$mock_home/hooks/test-hook.sh"
    assert_file_exists "$deployed" "hook should be deployed"
    assert_contains "$(sed -n '2p' "$deployed")" "MANAGED" "second line should contain MANAGED header"
    assert_contains "$(sed -n '2p' "$deployed")" "test-hook.sh" "header should reference source filename"
    assert_contains "$(sed -n '2p' "$deployed")" "Source: $mock_repo/global/hooks/" "header names the repo it was deployed from (CFG-700)"
    assert_not_contains "$(sed -n '2p' "$deployed")" "~/cfg-agent-fleet" "header must not hardcode the owner's repo path (CFG-700)"
    assert_contains "$(head -1 "$deployed")" "#!/" "first line should still be the shebang"
}
run_test "v1.0: deploy_hooks adds managed-file header" test_deploy_hooks_adds_managed_header

# ── v1.0: git-diff drift detection replaces CRC32 (CFG-293) ──────────────────

test_check_template_drift_uses_diff() {
    # Create mock personal and template repos with one identical and one differing file
    local personal="$TEST_TMPDIR/personal"
    local template="$TEST_TMPDIR/template"
    mkdir -p "$personal/setup/scripts" "$template/setup/scripts"
    mkdir -p "$personal/global/hooks" "$template/global/hooks"

    echo "same content" > "$personal/setup/scripts/shared.sh"
    echo "same content" > "$template/setup/scripts/shared.sh"
    echo "personal version" > "$personal/global/hooks/hook.sh"
    echo "template version" > "$template/global/hooks/hook.sh"

    # Create manifest WITHOUT hashes (v1.0 format)
    cat > "$personal/template-sync-manifest.md" << 'EOF'
# Template Sync Manifest

## Tracked Files — Must Be Identical

| File | Notes |
|------|-------|
| `setup/scripts/shared.sh` | Shared utility |

## Tracked Files — Intentional Diffs

| File | Diff reason |
|------|-------------|
| `global/hooks/hook.sh` | Personal: custom. Template: generic. |
EOF

    local out
    out=$(bash "$SYNC_SCRIPT" check --repo-root "$personal" --template-dir "$template" 2>&1)

    # Identical file should not trigger drift
    assert_not_contains "$out" "shared.sh differs" "identical file should not drift"
    # cmd_check should complete without python3 errors
    assert_not_contains "$out" "python3" "should not reference python3"
}
run_test "v1.0: check uses diff not CRC32 for drift detection" test_check_template_drift_uses_diff

test_stamp_command_removed() {
    local out rc=0
    out=$(bash "$SYNC_SCRIPT" stamp 2>&1) || rc=$?
    assert_contains "$out" "removed" "stamp should say it's removed"
}
run_test "v1.0: stamp command removed" test_stamp_command_removed

test_manifest_has_no_hashes() {
    local manifest="$REPO_ROOT/template-sync-manifest.md"
    [ -f "$manifest" ] || return 0
    local hash_lines
    hash_lines=$(grep -cE '\| `[0-9a-f]{8}` \|' "$manifest" 2>/dev/null || echo "0")
    local no_hashes="yes"
    [ "$hash_lines" -gt 0 ] && no_hashes="no ($hash_lines hash lines remain)"
    assert_eq "yes" "$no_hashes" "manifest should have no CRC32 hashes"
}
run_test "v1.0: manifest has no CRC32 hashes" test_manifest_has_no_hashes

# ── v1.0: hook read-only + edit command (CFG-294) ────────────────────────────

test_deployed_hooks_are_read_only() {
    local test_dir="$TEST_TMPDIR/readonly-test"
    local mock_home="$test_dir/home/.claude"
    local mock_repo="$test_dir/repo"
    mkdir -p "$mock_home/hooks" "$mock_repo/global/hooks"

    cat > "$mock_repo/global/hooks/test-hook.sh" << 'HOOK'
#!/usr/bin/env bash
echo "test"
HOOK

    local out
    out=$(
        CLAUDE_HOME="$mock_home"
        GLOBAL_DIR="$mock_repo/global"
        SCRIPT_DIR="$mock_repo"
        source <(sed -n '/^log_info()/,/^}/p' "$SYNC_SCRIPT")
        source <(sed -n '/^log_warn()/,/^}/p' "$SYNC_SCRIPT")
        source <(sed -n '/^deploy_hooks()/,/^}/p' "$SYNC_LIB_DIR/deploy.sh")
        deploy_hooks 2>&1
    )

    local deployed="$mock_home/hooks/test-hook.sh"
    assert_file_exists "$deployed" "hook should be deployed"
    # Check permissions: should be 555 (r-xr-xr-x)
    local perms
    perms=$(stat -c '%a' "$deployed")
    assert_eq "555" "$perms" "deployed hooks should be chmod 555"
}
run_test "v1.0: deployed hooks are read-only (chmod 555)" test_deployed_hooks_are_read_only

test_edit_command_exists() {
    local out
    out=$(bash "$SYNC_SCRIPT" help 2>&1)
    assert_contains "$out" "edit" "help should show edit command"
}
run_test "v1.0: edit command in help" test_edit_command_exists

test_edit_shows_source_path() {
    local out rc=0
    # Suppress editor launch by overriding EDITOR and PATH
    out=$(EDITOR=echo PATH="/usr/bin" bash "$SYNC_SCRIPT" edit config-check.sh 2>&1) || rc=$?
    # Should print the repo source path
    assert_contains "$out" "global/hooks/config-check.sh" "should show source path"
}
run_test "v1.0: edit shows repo source path" test_edit_shows_source_path

test_edit_no_arg_fails() {
    local out rc=0
    out=$(bash "$SYNC_SCRIPT" edit 2>&1) || rc=$?
    assert_neq "0" "$rc" "edit without arg should fail"
}
run_test "v1.0: edit without argument fails" test_edit_no_arg_fails

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
