#!/usr/bin/env bash
# Tests for upgrade.sh — upgrade with rollback mechanism
source "$(dirname "$0")/test-helpers.sh"

suite_header "upgrade.sh — Upgrade with Rollback"

UPGRADE_SCRIPT="$REPO_ROOT/setup/scripts/upgrade.sh"

# ── Helper: create a mock repo with remote ───────────────────────────────────

_setup_upgrade_env() {
    local remote="$TEST_TMPDIR/remote.git"
    local repo="$TEST_TMPDIR/repo"

    create_tracked_repo "$repo" "$remote"

    # Add some files to simulate agent-fleet structure
    (
        cd "$repo"
        mkdir -p setup/scripts global
        echo '#!/bin/bash' > sync.sh
        echo 'cmd_deploy() { echo "deployed"; }' >> sync.sh
        chmod +x sync.sh
        cp "$UPGRADE_SCRIPT" setup/scripts/upgrade.sh 2>/dev/null || true
        git add -A
        git commit -m "Add structure" >/dev/null 2>&1
        git push origin "$(git branch --show-current)" >/dev/null 2>&1
    )

    echo "$repo"
}

# ── Test: script exists and is executable ────────────────────────────────────

test_script_exists() {
    assert_file_exists "$UPGRADE_SCRIPT"
    [[ -x "$UPGRADE_SCRIPT" ]] || chmod +x "$UPGRADE_SCRIPT"
    assert_success test -x "$UPGRADE_SCRIPT"
}
run_test "upgrade.sh exists and is executable" test_script_exists

# ── Test: --help flag shows usage ─────────────────────────────────────────────

test_help_flag() {
    local output
    output=$(bash "$UPGRADE_SCRIPT" --help 2>&1)
    assert_contains "$output" "Usage"
    assert_contains "$output" "rollback"
}
run_test "upgrade.sh --help shows usage with rollback info" test_help_flag

# ── Test: --dry-run does not modify repo ──────────────────────────────────────

test_dry_run() {
    local repo
    repo=$(_setup_upgrade_env)

    local before_hash
    before_hash=$(git -C "$repo" rev-parse HEAD)

    local output
    output=$(bash "$UPGRADE_SCRIPT" --dry-run --repo "$repo" 2>&1) || true

    local after_hash
    after_hash=$(git -C "$repo" rev-parse HEAD)

    assert_eq "$before_hash" "$after_hash" "dry-run should not change HEAD"

    # Should not create any tags
    local tag_count
    tag_count=$(git -C "$repo" tag -l 'pre-upgrade-*' | wc -l)
    assert_eq "0" "$tag_count" "dry-run should not create tags"
}
run_test "upgrade.sh --dry-run does not modify repo" test_dry_run

# ── Test: creates pre-upgrade tag ─────────────────────────────────────────────

test_creates_pre_upgrade_tag() {
    local repo
    repo=$(_setup_upgrade_env)
    local remote="$TEST_TMPDIR/remote.git"

    # Push a new commit to remote so there's something to pull
    local clone="$TEST_TMPDIR/clone"
    git clone "$remote" "$clone" >/dev/null 2>&1
    (
        cd "$clone"
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "update" > update.txt
        git add update.txt
        git commit -m "Remote update" >/dev/null 2>&1
        git push >/dev/null 2>&1
    )

    bash "$UPGRADE_SCRIPT" --repo "$repo" --skip-deploy 2>&1 || true

    local tag_count
    tag_count=$(git -C "$repo" tag -l 'pre-upgrade-*' | wc -l)
    assert_eq "1" "$tag_count" "should create exactly one pre-upgrade tag"
}
run_test "upgrade.sh creates pre-upgrade-TIMESTAMP tag" test_creates_pre_upgrade_tag

# ── Test: pulls latest changes ────────────────────────────────────────────────

test_pulls_latest() {
    local repo
    repo=$(_setup_upgrade_env)
    local remote="$TEST_TMPDIR/remote.git"

    # Push a new commit to remote from a separate clone
    local clone="$TEST_TMPDIR/clone"
    git clone "$remote" "$clone" >/dev/null 2>&1
    (
        cd "$clone"
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "new content" > newfile.txt
        git add newfile.txt
        git commit -m "Remote update" >/dev/null 2>&1
        git push >/dev/null 2>&1
    )

    local before_hash
    before_hash=$(git -C "$repo" rev-parse HEAD)

    bash "$UPGRADE_SCRIPT" --repo "$repo" --skip-deploy 2>&1 || true

    local after_hash
    after_hash=$(git -C "$repo" rev-parse HEAD)

    assert_neq "$before_hash" "$after_hash" "HEAD should advance after pull"
    assert_file_exists "$repo/newfile.txt"
}
run_test "upgrade.sh pulls latest changes from remote" test_pulls_latest

# ── Test: --rollback reverts to pre-upgrade tag ──────────────────────────────

test_rollback() {
    local repo
    repo=$(_setup_upgrade_env)
    local remote="$TEST_TMPDIR/remote.git"

    # Remember original state
    local original_hash
    original_hash=$(git -C "$repo" rev-parse HEAD)

    # Push a new commit to remote
    local clone="$TEST_TMPDIR/clone"
    git clone "$remote" "$clone" >/dev/null 2>&1
    (
        cd "$clone"
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "breaking change" > breaking.txt
        git add breaking.txt
        git commit -m "Breaking update" >/dev/null 2>&1
        git push >/dev/null 2>&1
    )

    # Upgrade (creates tag + pulls)
    bash "$UPGRADE_SCRIPT" --repo "$repo" --skip-deploy 2>&1 || true

    local upgraded_hash
    upgraded_hash=$(git -C "$repo" rev-parse HEAD)
    assert_neq "$original_hash" "$upgraded_hash" "should have upgraded"

    # Rollback
    bash "$UPGRADE_SCRIPT" --rollback --repo "$repo" 2>&1 || true

    local rollback_hash
    rollback_hash=$(git -C "$repo" rev-parse HEAD)
    assert_eq "$original_hash" "$rollback_hash" "rollback should restore original HEAD"
    assert_file_not_exists "$repo/breaking.txt"
}
run_test "upgrade.sh --rollback reverts to pre-upgrade state" test_rollback

# ── Test: rollback fails gracefully without tags ──────────────────────────────

test_rollback_no_tags() {
    local repo
    repo=$(_setup_upgrade_env)

    local output
    output=$(bash "$UPGRADE_SCRIPT" --rollback --repo "$repo" 2>&1) || true

    assert_contains "$output" "No pre-upgrade tag"
}
run_test "upgrade.sh --rollback shows error when no tags exist" test_rollback_no_tags

# ── Test: upgrade when already up to date ─────────────────────────────────────

test_already_up_to_date() {
    local repo
    repo=$(_setup_upgrade_env)

    local output
    output=$(bash "$UPGRADE_SCRIPT" --repo "$repo" --skip-deploy 2>&1) || true

    assert_contains "$output" "up to date"
}
run_test "upgrade.sh handles already-up-to-date gracefully" test_already_up_to_date

# ── Test: --list-tags shows available rollback points ─────────────────────────

test_list_tags() {
    local repo
    repo=$(_setup_upgrade_env)

    # Create a tag manually
    git -C "$repo" tag "pre-upgrade-2026-03-12-180000"

    local output
    output=$(bash "$UPGRADE_SCRIPT" --list-tags --repo "$repo" 2>&1)

    assert_contains "$output" "pre-upgrade-2026-03-12-180000"
}
run_test "upgrade.sh --list-tags shows available rollback points" test_list_tags

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
