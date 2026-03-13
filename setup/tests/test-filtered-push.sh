#!/usr/bin/env bash
# Tests for filtered-push.sh — dual-remote push with path exclusion
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/filtered-push.sh"

suite_header "filtered-push.sh"

# ── Helper: create a repo with dual remotes and .push-filter.conf ───────────

# Create a git repo ensuring the default branch is named "main"
# (git init defaults to "master" on some systems)
create_main_repo() {
    local path="$1"
    create_git_repo "$path"
    (
        cd "$path"
        git branch -M main 2>/dev/null || true
    )
}

# Creates a working repo with private + public bare remotes, tracked on main.
# Usage: setup_dual_remote_repo "$TEST_TMPDIR"
# Sets up: $TEST_TMPDIR/repo, $TEST_TMPDIR/private.git, $TEST_TMPDIR/public.git
setup_dual_remote_repo() {
    local base="$1"
    create_bare_repo "$base/private.git"
    create_bare_repo "$base/public.git"
    create_main_repo "$base/repo"
    (
        cd "$base/repo"
        git remote add private "$base/private.git"
        git remote add public "$base/public.git"
        git push -u private main --quiet 2>/dev/null
        git push public main --quiet 2>/dev/null
    )
}

# ── 1. Missing .push-filter.conf → exits with error ────────────────────────

test_missing_config() {
    create_main_repo "$TEST_TMPDIR/repo"
    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SCRIPT" 2>&1) || rc=$?
    assert_eq "1" "$rc" "should exit 1 when config missing"
    assert_contains "$out" "No .push-filter.conf found"
}
run_test "exits with error when .push-filter.conf is missing" test_missing_config

# ── 2. Not inside a git repo → exits with error ────────────────────────────

test_not_git_repo() {
    mkdir -p "$TEST_TMPDIR/notrepo"
    local out rc=0
    out=$(cd "$TEST_TMPDIR/notrepo" && bash "$SCRIPT" 2>&1) || rc=$?
    assert_eq "1" "$rc" "should exit 1 outside git repo"
    assert_contains "$out" "Not inside a git repository"
}
run_test "exits with error when not inside a git repo" test_not_git_repo

# ── 3. Missing private_remote config → exits with error ────────────────────

test_missing_private_remote() {
    create_main_repo "$TEST_TMPDIR/repo"
    cat > "$TEST_TMPDIR/repo/.push-filter.conf" <<'EOF'
public_remote=public
branch=main
EOF
    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SCRIPT" 2>&1) || rc=$?
    assert_eq "1" "$rc" "should exit 1 when private_remote missing"
    assert_contains "$out" "private_remote not set"
}
run_test "exits with error when private_remote not set" test_missing_private_remote

# ── 4. Missing public_remote config → exits with error ─────────────────────

test_missing_public_remote() {
    create_main_repo "$TEST_TMPDIR/repo"
    cat > "$TEST_TMPDIR/repo/.push-filter.conf" <<'EOF'
private_remote=private
branch=main
EOF
    # Add the private remote so it doesn't fail on that check first
    (cd "$TEST_TMPDIR/repo" && git remote add private "https://example.com/fake.git")
    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SCRIPT" 2>&1) || rc=$?
    assert_eq "1" "$rc" "should exit 1 when public_remote missing"
    assert_contains "$out" "public_remote not set"
}
run_test "exits with error when public_remote not set" test_missing_public_remote

# ── 5. Wrong branch → exits with error ─────────────────────────────────────

test_wrong_branch() {
    setup_dual_remote_repo "$TEST_TMPDIR"
    cat > "$TEST_TMPDIR/repo/.push-filter.conf" <<'EOF'
private_remote=private
public_remote=public
branch=release
EOF
    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SCRIPT" 2>&1) || rc=$?
    assert_eq "1" "$rc" "should exit 1 on wrong branch"
    assert_contains "$out" "Expected to be on branch 'release'"
}
run_test "exits with error when on wrong branch" test_wrong_branch

# ── 6. Uncommitted changes → exits with error ──────────────────────────────

test_uncommitted_changes() {
    setup_dual_remote_repo "$TEST_TMPDIR"
    cat > "$TEST_TMPDIR/repo/.push-filter.conf" <<'EOF'
private_remote=private
public_remote=public
branch=main
EOF
    # Create an uncommitted change
    echo "dirty" > "$TEST_TMPDIR/repo/dirty.txt"
    (cd "$TEST_TMPDIR/repo" && git add dirty.txt)

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SCRIPT" 2>&1) || rc=$?
    assert_eq "1" "$rc" "should exit 1 with uncommitted changes"
    assert_contains "$out" "Uncommitted changes"
}
run_test "exits with error when uncommitted changes exist" test_uncommitted_changes

# ── 7. Remote doesn't exist → exits with error ─────────────────────────────

test_remote_not_configured_private() {
    create_main_repo "$TEST_TMPDIR/repo"
    cat > "$TEST_TMPDIR/repo/.push-filter.conf" <<'EOF'
private_remote=nonexistent
public_remote=public
branch=main
EOF
    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SCRIPT" 2>&1) || rc=$?
    assert_eq "1" "$rc" "should exit 1 when private remote not configured"
    assert_contains "$out" "Remote 'nonexistent' not configured"
}
run_test "exits with error when private remote doesn't exist" test_remote_not_configured_private

test_remote_not_configured_public() {
    create_main_repo "$TEST_TMPDIR/repo"
    create_bare_repo "$TEST_TMPDIR/private.git"
    (cd "$TEST_TMPDIR/repo" && git remote add private "$TEST_TMPDIR/private.git")
    cat > "$TEST_TMPDIR/repo/.push-filter.conf" <<'EOF'
private_remote=private
public_remote=nonexistent
branch=main
EOF
    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SCRIPT" 2>&1) || rc=$?
    assert_eq "1" "$rc" "should exit 1 when public remote not configured"
    assert_contains "$out" "Remote 'nonexistent' not configured"
}
run_test "exits with error when public remote doesn't exist" test_remote_not_configured_public

# ── 8. Config parsing: reads all config keys correctly ──────────────────────

test_config_parsing() {
    setup_dual_remote_repo "$TEST_TMPDIR"
    cat > "$TEST_TMPDIR/repo/.push-filter.conf" <<'EOF'
private_remote=private
public_remote=public
branch=main
exclude=secrets/
exclude=internal/
exclude_glob=*.private
exclude_glob=docs/*.draft
EOF

    # Use --dry-run to inspect what the script reports
    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SCRIPT" --dry-run 2>&1) || rc=$?
    assert_eq "0" "$rc" "dry-run should succeed"
    assert_contains "$out" "Private: private"
    assert_contains "$out" "Public:  public"
    assert_contains "$out" "secrets/"
    assert_contains "$out" "internal/"
    assert_contains "$out" "*.private"
    assert_contains "$out" "docs/*.draft"
}
run_test "config parsing reads all keys correctly" test_config_parsing

# ── 9. --dry-run flag: reports without pushing ──────────────────────────────

test_dry_run() {
    setup_dual_remote_repo "$TEST_TMPDIR"
    cat > "$TEST_TMPDIR/repo/.push-filter.conf" <<'EOF'
private_remote=private
public_remote=public
branch=main
exclude=secrets/
EOF
    # Add a new commit so there's something to push
    add_commit "$TEST_TMPDIR/repo" "new content"
    # Create excluded dir
    (
        cd "$TEST_TMPDIR/repo"
        mkdir -p secrets
        echo "token=abc" > secrets/vault.json
        git add secrets/
        git commit -m "add secrets" --quiet 2>/dev/null
    )

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SCRIPT" --dry-run 2>&1) || rc=$?
    assert_eq "0" "$rc" "dry-run should exit 0"
    assert_contains "$out" "[dry-run]"
    assert_contains "$out" "Would push"

    # Verify private remote did NOT receive the push
    local private_head
    private_head=$(git -C "$TEST_TMPDIR/private.git" rev-parse HEAD 2>/dev/null)
    local local_head
    local_head=$(git -C "$TEST_TMPDIR/repo" rev-parse HEAD 2>/dev/null)
    assert_neq "$local_head" "$private_head" "private remote should NOT be updated in dry-run"
}
run_test "--dry-run reports actions without pushing" test_dry_run

# ── 10. Successful full push to private remote ─────────────────────────────

test_push_to_private() {
    setup_dual_remote_repo "$TEST_TMPDIR"
    cat > "$TEST_TMPDIR/repo/.push-filter.conf" <<'EOF'
private_remote=private
public_remote=public
branch=main
exclude=secrets/
EOF
    add_commit "$TEST_TMPDIR/repo" "content for private push"

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SCRIPT" 2>&1) || rc=$?
    assert_eq "0" "$rc" "push should succeed"
    assert_contains "$out" "Pushing to private"

    # Verify private remote received the push
    local private_head
    private_head=$(git -C "$TEST_TMPDIR/private.git" rev-parse main 2>/dev/null)
    local local_head
    local_head=$(git -C "$TEST_TMPDIR/repo" rev-parse HEAD 2>/dev/null)
    assert_eq "$local_head" "$private_head" "private remote should match local HEAD"
}
run_test "successful full push to private remote" test_push_to_private

# ── 11. Filtered push excludes paths correctly ─────────────────────────────

test_filtered_push_excludes_paths() {
    setup_dual_remote_repo "$TEST_TMPDIR"
    (
        cd "$TEST_TMPDIR/repo"
        # Add files: some should be excluded, some kept
        mkdir -p secrets internal
        echo "secret data" > secrets/vault.json
        echo "internal doc" > internal/notes.txt
        echo "public content" > public-file.txt
        git add -A
        git commit -m "add mixed content" --quiet 2>/dev/null
    )
    cat > "$TEST_TMPDIR/repo/.push-filter.conf" <<'EOF'
private_remote=private
public_remote=public
branch=main
exclude=secrets/
exclude=internal/
EOF
    (cd "$TEST_TMPDIR/repo" && git add .push-filter.conf && git commit -m "add config" --quiet 2>/dev/null)

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SCRIPT" 2>&1) || rc=$?
    assert_eq "0" "$rc" "filtered push should succeed"

    # Clone the public remote and verify excluded files are absent
    # Use -b main because bare repos default HEAD to master on some systems
    git clone -b main "$TEST_TMPDIR/public.git" "$TEST_TMPDIR/public-clone" --quiet 2>/dev/null
    assert_file_not_exists "$TEST_TMPDIR/public-clone/secrets/vault.json" \
        "secrets/vault.json should be excluded from public"
    assert_file_not_exists "$TEST_TMPDIR/public-clone/internal/notes.txt" \
        "internal/notes.txt should be excluded from public"
    assert_file_exists "$TEST_TMPDIR/public-clone/public-file.txt" \
        "public-file.txt should be present in public"
}
run_test "filtered push excludes configured paths from public remote" test_filtered_push_excludes_paths

# ── 12. No-op when public repo is already up to date ───────────────────────

test_noop_public_up_to_date() {
    setup_dual_remote_repo "$TEST_TMPDIR"
    # Must have an exclude so the script uses the filtered tree path
    # (no excludes = direct push, which doesn't check tree equality)
    (
        cd "$TEST_TMPDIR/repo"
        mkdir -p secrets
        echo "token" > secrets/vault.json
        git add -A
        git commit -m "add secret" --quiet 2>/dev/null
    )
    cat > "$TEST_TMPDIR/repo/.push-filter.conf" <<'EOF'
private_remote=private
public_remote=public
branch=main
exclude=secrets/
EOF
    (cd "$TEST_TMPDIR/repo" && git add .push-filter.conf && git commit -m "add config" --quiet 2>/dev/null)

    # First push: syncs everything
    local out1 rc1=0
    out1=$(cd "$TEST_TMPDIR/repo" && bash "$SCRIPT" 2>&1) || rc1=$?
    assert_eq "0" "$rc1" "first push should succeed"

    # Second push: nothing changed, should be a no-op for public
    local out2 rc2=0
    out2=$(cd "$TEST_TMPDIR/repo" && bash "$SCRIPT" 2>&1) || rc2=$?
    assert_eq "0" "$rc2" "second push should succeed"
    assert_contains "$out2" "already up to date"
}
run_test "no-op when public repo tree is already up to date" test_noop_public_up_to_date

# ── 13. exclude_glob with no matches warns but doesn't fail ────────────────

test_exclude_glob_no_matches_warns() {
    setup_dual_remote_repo "$TEST_TMPDIR"
    add_commit "$TEST_TMPDIR/repo" "some content"
    cat > "$TEST_TMPDIR/repo/.push-filter.conf" <<'EOF'
private_remote=private
public_remote=public
branch=main
exclude_glob=*.nonexistent_extension
EOF
    (cd "$TEST_TMPDIR/repo" && git add .push-filter.conf && git commit -m "add config" --quiet 2>/dev/null)

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SCRIPT" 2>&1) || rc=$?
    assert_eq "0" "$rc" "should succeed even with no-match globs"
    assert_contains "$out" "WARNING" "should warn about non-matching glob"
    assert_contains "$out" "matched no files"
}
run_test "exclude_glob with no matches warns but doesn't fail" test_exclude_glob_no_matches_warns

# ── 14. Comments and blank lines in config are skipped ──────────────────────

test_config_comments_and_blanks() {
    setup_dual_remote_repo "$TEST_TMPDIR"
    cat > "$TEST_TMPDIR/repo/.push-filter.conf" <<'EOF'
# This is a comment
private_remote=private

# Another comment
public_remote=public

branch=main

# Exclude some paths
exclude=secrets/
EOF
    add_commit "$TEST_TMPDIR/repo" "content"
    (cd "$TEST_TMPDIR/repo" && git add .push-filter.conf && git commit -m "add config" --quiet 2>/dev/null)

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SCRIPT" --dry-run 2>&1) || rc=$?
    assert_eq "0" "$rc" "should parse config with comments and blanks"
    assert_contains "$out" "Private: private"
    assert_contains "$out" "Public:  public"
    assert_not_contains "$out" "WARNING" "comments should not trigger warnings"
}
run_test "comments and blank lines in config are skipped" test_config_comments_and_blanks

# ── 15. Unknown config keys produce warnings ───────────────────────────────

test_unknown_config_keys_warn() {
    setup_dual_remote_repo "$TEST_TMPDIR"
    cat > "$TEST_TMPDIR/repo/.push-filter.conf" <<'EOF'
private_remote=private
public_remote=public
branch=main
mystery_key=some_value
another_unknown=42
EOF

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SCRIPT" --dry-run 2>&1) || rc=$?
    assert_eq "0" "$rc" "should still succeed with unknown keys"
    assert_contains "$out" "Unknown config key 'mystery_key'"
    assert_contains "$out" "Unknown config key 'another_unknown'"
}
run_test "unknown config keys produce warnings" test_unknown_config_keys_warn

# ── 16. Commit messages pushed to public are sanitized ───────────────────────

test_commit_message_sanitized_in_public() {
    setup_dual_remote_repo "$TEST_TMPDIR"
    (
        cd "$TEST_TMPDIR/repo"
        mkdir -p secrets
        echo "token" > secrets/vault.json
        cat > .push-filter.conf <<'CONF'
private_remote=private
public_remote=public
branch=main
exclude=secrets/
CONF
        git add -A
        # The HEAD commit message contains personal data that should be sanitized
        git commit -m "Fix by user@private.com on DESKTOP-ABC123 at 10.0.0.1" --quiet 2>/dev/null
    )

    local out rc=0
    out=$(cd "$TEST_TMPDIR/repo" && bash "$SCRIPT" 2>&1) || rc=$?
    assert_eq "0" "$rc" "push should succeed"

    # Check the public remote's commit message is sanitized
    local public_msg
    public_msg=$(git -C "$TEST_TMPDIR/public.git" log -1 --format=%B)
    assert_not_contains "$public_msg" "user@private.com" "email should be redacted in public commit"
    assert_not_contains "$public_msg" "DESKTOP-ABC123" "hostname should be redacted in public commit"
    assert_not_contains "$public_msg" "10.0.0.1" "IP should be redacted in public commit"
    assert_contains "$public_msg" "[REDACTED-EMAIL]" "should have email redaction marker"
    assert_contains "$public_msg" "[REDACTED-HOST]" "should have host redaction marker"
    assert_contains "$public_msg" "[REDACTED-IP]" "should have IP redaction marker"
}
run_test "commit messages pushed to public are sanitized" test_commit_message_sanitized_in_public

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
