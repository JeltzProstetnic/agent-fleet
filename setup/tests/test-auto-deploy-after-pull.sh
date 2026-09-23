#!/usr/bin/env bash
# Tests for CFG-208: auto-deploy after git pull in git-sync-check.sh
# Verifies that sync.sh deploy runs automatically when pulled commits
# include deploy-sensitive paths (hooks, config, knowledge, etc.)
source "$(dirname "$0")/test-helpers.sh"

SYNC_SCRIPT="$REPO_ROOT/setup/scripts/git-sync-check.sh"

suite_header "CFG-208: Auto-deploy after git pull"

# ── Helper: create a test repo with a mock sync.sh ──────────────────────────
# The mock sync.sh writes a marker file when "deploy" is called,
# so tests can verify whether deploy was triggered.

setup_deploy_test_repos() {
    local repo="$1"
    local remote="$2"
    local other="$3"

    create_tracked_repo "$repo" "$remote"

    # Create mock sync.sh in the repo
    cat > "$repo/sync.sh" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "deploy" ]]; then
    touch "$(dirname "$0")/.deploy-triggered"
    echo "[MOCK] sync.sh deploy executed"
fi
MOCK
    chmod +x "$repo/sync.sh"
    (cd "$repo" && git add sync.sh && git commit -m "Add sync.sh" >/dev/null 2>&1 && git push --quiet 2>/dev/null)

    # Clone "other machine" for pushing changes
    git clone "$remote" "$other" --quiet 2>/dev/null
}

# Helper: push a commit from "other" that touches a specific path
push_file_from_other() {
    local other="$1"
    local filepath="$2"
    local msg="${3:-change to $filepath}"

    (
        cd "$other"
        mkdir -p "$(dirname "$filepath")"
        echo "$msg" > "$filepath"
        git add "$filepath"
        git commit -m "$msg" >/dev/null 2>&1
        git push --quiet 2>/dev/null
    )
}

# ── Test: deploy triggered when global/hooks/ changes ───────────────────────

test_deploy_triggered_hooks() {
    setup_deploy_test_repos "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other"
    push_file_from_other "$TEST_TMPDIR/other" "global/hooks/config-check.sh" "hook update"

    local out rc=0
    out=$(bash "$SYNC_SCRIPT" --pull "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_eq "0" "$rc" "should pull successfully"
    assert_file_exists "$TEST_TMPDIR/repo/.deploy-triggered" "deploy should have been triggered"
    assert_contains "$out" "sync.sh deploy"
}
run_test "deploy triggered when global/hooks/ changes" test_deploy_triggered_hooks

# ── Test: deploy triggered when setup/config/ changes ───────────────────────

test_deploy_triggered_config() {
    setup_deploy_test_repos "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other"
    push_file_from_other "$TEST_TMPDIR/other" "setup/config/statusline-command.sh" "statusline update"

    local out rc=0
    out=$(bash "$SYNC_SCRIPT" --pull "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_eq "0" "$rc"
    assert_file_exists "$TEST_TMPDIR/repo/.deploy-triggered" "deploy should trigger for setup/config/"
}
run_test "deploy triggered when setup/config/ changes" test_deploy_triggered_config

# ── Test: deploy triggered when global/reference/ changes ───────────────────

test_deploy_triggered_reference() {
    setup_deploy_test_repos "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other"
    push_file_from_other "$TEST_TMPDIR/other" "global/reference/output-rules.md" "ref update"

    local out rc=0
    out=$(bash "$SYNC_SCRIPT" --pull "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_eq "0" "$rc"
    assert_file_exists "$TEST_TMPDIR/repo/.deploy-triggered" "deploy should trigger for global/reference/"
}
run_test "deploy triggered when global/reference/ changes" test_deploy_triggered_reference

# ── Test: deploy triggered when global/foundation/ changes ──────────────────

test_deploy_triggered_foundation() {
    setup_deploy_test_repos "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other"
    push_file_from_other "$TEST_TMPDIR/other" "global/foundation/session-protocol.md" "foundation update"

    local out rc=0
    out=$(bash "$SYNC_SCRIPT" --pull "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_eq "0" "$rc"
    assert_file_exists "$TEST_TMPDIR/repo/.deploy-triggered" "deploy should trigger for global/foundation/"
}
run_test "deploy triggered when global/foundation/ changes" test_deploy_triggered_foundation

# ── Test: deploy triggered when global/knowledge/ changes ───────────────────

test_deploy_triggered_knowledge() {
    setup_deploy_test_repos "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other"
    push_file_from_other "$TEST_TMPDIR/other" "global/knowledge/vault-ops.md" "knowledge update"

    local out rc=0
    out=$(bash "$SYNC_SCRIPT" --pull "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_eq "0" "$rc"
    assert_file_exists "$TEST_TMPDIR/repo/.deploy-triggered" "deploy should trigger for global/knowledge/"
}
run_test "deploy triggered when global/knowledge/ changes" test_deploy_triggered_knowledge

# ── Test: deploy triggered when global/domains/ changes ─────────────────────

test_deploy_triggered_domains() {
    setup_deploy_test_repos "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other"
    push_file_from_other "$TEST_TMPDIR/other" "global/domains/it-infra/notes.md" "domain update"

    local out rc=0
    out=$(bash "$SYNC_SCRIPT" --pull "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_eq "0" "$rc"
    assert_file_exists "$TEST_TMPDIR/repo/.deploy-triggered" "deploy should trigger for global/domains/"
}
run_test "deploy triggered when global/domains/ changes" test_deploy_triggered_domains

# ── Test: deploy triggered when setup/scripts/ changes ──────────────────────

test_deploy_triggered_scripts() {
    setup_deploy_test_repos "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other"
    push_file_from_other "$TEST_TMPDIR/other" "setup/scripts/rotate-session.sh" "script update"

    local out rc=0
    out=$(bash "$SYNC_SCRIPT" --pull "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_eq "0" "$rc"
    assert_file_exists "$TEST_TMPDIR/repo/.deploy-triggered" "deploy should trigger for setup/scripts/"
}
run_test "deploy triggered when setup/scripts/ changes" test_deploy_triggered_scripts

# ── Test: deploy NOT triggered for non-deploy files ─────────────────────────

test_no_deploy_for_session_context() {
    setup_deploy_test_repos "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other"
    push_file_from_other "$TEST_TMPDIR/other" "session-context.md" "session update"

    local out rc=0
    out=$(bash "$SYNC_SCRIPT" --pull "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_eq "0" "$rc"
    assert_file_not_exists "$TEST_TMPDIR/repo/.deploy-triggered" "deploy should NOT trigger for session-context.md"
}
run_test "deploy NOT triggered for session-context.md" test_no_deploy_for_session_context

# ── Test: deploy NOT triggered for docs/ changes ───────────────────────────

test_no_deploy_for_docs() {
    setup_deploy_test_repos "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other"
    push_file_from_other "$TEST_TMPDIR/other" "docs/session-log.md" "doc update"

    local out rc=0
    out=$(bash "$SYNC_SCRIPT" --pull "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_eq "0" "$rc"
    assert_file_not_exists "$TEST_TMPDIR/repo/.deploy-triggered" "deploy should NOT trigger for docs/"
}
run_test "deploy NOT triggered for docs/ changes" test_no_deploy_for_docs

# ── Test: deploy NOT triggered for backlog.md ───────────────────────────────

test_no_deploy_for_backlog() {
    setup_deploy_test_repos "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other"
    push_file_from_other "$TEST_TMPDIR/other" "backlog.md" "backlog update"

    local out rc=0
    out=$(bash "$SYNC_SCRIPT" --pull "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_eq "0" "$rc"
    assert_file_not_exists "$TEST_TMPDIR/repo/.deploy-triggered" "deploy should NOT trigger for backlog.md"
}
run_test "deploy NOT triggered for backlog.md" test_no_deploy_for_backlog

# ── Test: deploy NOT triggered when already up to date ──────────────────────

test_no_deploy_when_up_to_date() {
    setup_deploy_test_repos "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other"

    local out rc=0
    out=$(bash "$SYNC_SCRIPT" --pull "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_eq "0" "$rc"
    assert_contains "$out" "Up to date"
    assert_file_not_exists "$TEST_TMPDIR/repo/.deploy-triggered" "deploy should NOT trigger when up to date"
}
run_test "deploy NOT triggered when already up to date" test_no_deploy_when_up_to_date

# ── Test: deploy failure does not block session start ───────────────────────

test_deploy_failure_non_blocking() {
    setup_deploy_test_repos "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other"

    # Make sync.sh fail
    cat > "$TEST_TMPDIR/repo/sync.sh" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "deploy" ]]; then
    echo "[MOCK] sync.sh deploy FAILED" >&2
    exit 1
fi
MOCK
    (cd "$TEST_TMPDIR/repo" && git add sync.sh && git commit -m "break sync.sh" >/dev/null 2>&1 && git push --quiet 2>/dev/null)
    # Sync the breaking change to "other" too
    (cd "$TEST_TMPDIR/other" && git pull --quiet 2>/dev/null)

    push_file_from_other "$TEST_TMPDIR/other" "global/hooks/new-hook.sh" "hook that triggers deploy"

    local out rc=0
    out=$(bash "$SYNC_SCRIPT" --pull "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_eq "0" "$rc" "script should still exit 0 even if deploy fails"
    assert_contains "$out" "Pulled successfully"
}
run_test "deploy failure does not block session start (exit 0)" test_deploy_failure_non_blocking

# ── Test: mixed changes — deploy-sensitive + non-sensitive ──────────────────

test_deploy_triggered_on_mixed_changes() {
    setup_deploy_test_repos "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other"

    # Push two files: one deploy-sensitive, one not
    (
        cd "$TEST_TMPDIR/other"
        mkdir -p global/hooks
        echo "hook" > global/hooks/new.sh
        echo "doc" > README-update.md
        git add global/hooks/new.sh README-update.md
        git commit -m "mixed changes" >/dev/null 2>&1
        git push --quiet 2>/dev/null
    )

    local out rc=0
    out=$(bash "$SYNC_SCRIPT" --pull "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_eq "0" "$rc"
    assert_file_exists "$TEST_TMPDIR/repo/.deploy-triggered" "deploy should trigger if ANY file is deploy-sensitive"
}
run_test "deploy triggered on mixed changes (deploy-sensitive + other)" test_deploy_triggered_on_mixed_changes

# ── Test: deploy NOT triggered without --pull ───────────────────────────────

test_no_deploy_without_pull_flag() {
    setup_deploy_test_repos "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git" "$TEST_TMPDIR/other"
    push_file_from_other "$TEST_TMPDIR/other" "global/hooks/config-check.sh" "hook update"

    local out rc=0
    out=$(bash "$SYNC_SCRIPT" "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    # Without --pull, script reports BEHIND but doesn't pull, so no deploy
    assert_eq "1" "$rc" "should exit 1 (behind, no pull)"
    assert_file_not_exists "$TEST_TMPDIR/repo/.deploy-triggered" "deploy should NOT trigger without --pull"
}
run_test "deploy NOT triggered without --pull flag" test_no_deploy_without_pull_flag

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
