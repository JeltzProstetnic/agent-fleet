#!/usr/bin/env bash
# Tests for append-post-rotation.sh (post-rotation commit tracking)
source "$(dirname "$0")/test-helpers.sh"

APPEND_SCRIPT="$REPO_ROOT/setup/scripts/append-post-rotation.sh"

suite_header "append-post-rotation.sh"

# Helper: create a git repo with a session-log entry and rotation marker
setup_post_rotation_repo() {
    local dir="$1"
    local marker_hash="${2:-}"
    local marker_ts="${3:-$(date +%s)}"

    git -C "$dir" init -q
    git -C "$dir" config user.email "test@test"
    git -C "$dir" config user.name "test"
    mkdir -p "$dir/docs"

    cat > "$dir/docs/session-log.md" <<'EOF'
# Session Log

Full session history. Newest first. Never pruned.

### 2026-03-27T22:45Z — Steam Deck
**Goal:** Test session
**Completed:**
- Did stuff
**Key Decisions:**
- Made choices
**Pending at shutdown:** None
**Recovery/Next session:**
All done.
EOF

    git -C "$dir" add -A && git -C "$dir" commit -qm "init session"

    if [[ -z "$marker_hash" ]]; then
        marker_hash=$(git -C "$dir" rev-parse HEAD)
    fi
    echo "$marker_hash $marker_ts" > "$dir/.post-rotation-commit"
}

# ── Happy path ────────────────────────────────────────────────────────────────

test_appends_post_rotation_commits() {
    setup_post_rotation_repo "$TEST_TMPDIR"

    # Make a post-rotation commit
    echo "fix" > "$TEST_TMPDIR/fix.txt"
    git -C "$TEST_TMPDIR" add fix.txt && git -C "$TEST_TMPDIR" commit -qm "lrn: important fix"

    bash "$APPEND_SCRIPT" "$TEST_TMPDIR"

    assert_file_contains "$TEST_TMPDIR/docs/session-log.md" "Post-shutdown:"
    assert_file_contains "$TEST_TMPDIR/docs/session-log.md" "lrn: important fix"
    assert_file_not_exists "$TEST_TMPDIR/.post-rotation-commit"
}
run_test "appends post-rotation commits to session-log" test_appends_post_rotation_commits

test_inserts_before_key_decisions() {
    setup_post_rotation_repo "$TEST_TMPDIR"

    echo "fix" > "$TEST_TMPDIR/fix.txt"
    git -C "$TEST_TMPDIR" add fix.txt && git -C "$TEST_TMPDIR" commit -qm "post-fix"

    bash "$APPEND_SCRIPT" "$TEST_TMPDIR"

    # Post-shutdown should appear BEFORE Key Decisions
    local post_line decisions_line
    post_line=$(grep -n 'Post-shutdown:' "$TEST_TMPDIR/docs/session-log.md" | head -1 | cut -d: -f1)
    decisions_line=$(grep -n 'Key Decisions:' "$TEST_TMPDIR/docs/session-log.md" | head -1 | cut -d: -f1)
    local order="wrong"
    [[ -n "$post_line" && -n "$decisions_line" && "$post_line" -lt "$decisions_line" ]] && order="correct"
    assert_eq "correct" "$order" "Post-shutdown should appear before Key Decisions"
}
run_test "inserts before Key Decisions line" test_inserts_before_key_decisions

test_multiple_post_commits() {
    setup_post_rotation_repo "$TEST_TMPDIR"

    echo "a" > "$TEST_TMPDIR/a.txt"
    git -C "$TEST_TMPDIR" add a.txt && git -C "$TEST_TMPDIR" commit -qm "first post-fix"
    echo "b" > "$TEST_TMPDIR/b.txt"
    git -C "$TEST_TMPDIR" add b.txt && git -C "$TEST_TMPDIR" commit -qm "second post-fix"

    bash "$APPEND_SCRIPT" "$TEST_TMPDIR"

    assert_file_contains "$TEST_TMPDIR/docs/session-log.md" "first post-fix"
    assert_file_contains "$TEST_TMPDIR/docs/session-log.md" "second post-fix"
}
run_test "handles multiple post-rotation commits" test_multiple_post_commits

# ── No-op cases ───────────────────────────────────────────────────────────────

test_no_marker_is_noop() {
    mkdir -p "$TEST_TMPDIR/docs"
    echo "# log" > "$TEST_TMPDIR/docs/session-log.md"

    bash "$APPEND_SCRIPT" "$TEST_TMPDIR"

    # No marker → no changes
    assert_file_not_contains "$TEST_TMPDIR/docs/session-log.md" "Post-shutdown"
}
run_test "no-op when marker doesn't exist" test_no_marker_is_noop

test_same_hash_cleans_marker() {
    setup_post_rotation_repo "$TEST_TMPDIR"
    # No new commits — hash matches HEAD

    bash "$APPEND_SCRIPT" "$TEST_TMPDIR"

    assert_file_not_exists "$TEST_TMPDIR/.post-rotation-commit"
    assert_file_not_contains "$TEST_TMPDIR/docs/session-log.md" "Post-shutdown"
}
run_test "cleans marker without changes when no new commits" test_same_hash_cleans_marker

# ── Stale marker (HIGH priority fix) ─────────────────────────────────────────

test_stale_marker_rejected() {
    setup_post_rotation_repo "$TEST_TMPDIR"

    # Make a post-rotation commit
    echo "fix" > "$TEST_TMPDIR/fix.txt"
    git -C "$TEST_TMPDIR" add fix.txt && git -C "$TEST_TMPDIR" commit -qm "stale fix"

    # Overwrite marker with a timestamp from 7 hours ago (>6h max)
    local old_hash
    old_hash=$(head -1 "$TEST_TMPDIR/.post-rotation-commit" | cut -d' ' -f1)
    local stale_ts=$(( $(date +%s) - 25200 ))  # 7 hours ago
    echo "$old_hash $stale_ts" > "$TEST_TMPDIR/.post-rotation-commit"

    bash "$APPEND_SCRIPT" "$TEST_TMPDIR" 2>/dev/null

    # Marker should be removed but session-log should NOT have post-shutdown
    assert_file_not_exists "$TEST_TMPDIR/.post-rotation-commit"
    assert_file_not_contains "$TEST_TMPDIR/docs/session-log.md" "Post-shutdown"
}
run_test "rejects stale marker (>6 hours old)" test_stale_marker_rejected

test_fresh_marker_accepted() {
    setup_post_rotation_repo "$TEST_TMPDIR"

    echo "fix" > "$TEST_TMPDIR/fix.txt"
    git -C "$TEST_TMPDIR" add fix.txt && git -C "$TEST_TMPDIR" commit -qm "fresh fix"

    # Marker is fresh (default timestamp = now)
    bash "$APPEND_SCRIPT" "$TEST_TMPDIR"

    assert_file_contains "$TEST_TMPDIR/docs/session-log.md" "Post-shutdown"
    assert_file_contains "$TEST_TMPDIR/docs/session-log.md" "fresh fix"
}
run_test "accepts fresh marker (<6 hours old)" test_fresh_marker_accepted

# ── Invalid marker ────────────────────────────────────────────────────────────

test_garbage_hash_cleaned() {
    mkdir -p "$TEST_TMPDIR/docs"
    git -C "$TEST_TMPDIR" init -q
    git -C "$TEST_TMPDIR" config user.email "test@test"
    git -C "$TEST_TMPDIR" config user.name "test"
    echo "# log" > "$TEST_TMPDIR/docs/session-log.md"
    git -C "$TEST_TMPDIR" add -A && git -C "$TEST_TMPDIR" commit -qm "init"

    echo "not_a_real_hash $(date +%s)" > "$TEST_TMPDIR/.post-rotation-commit"

    bash "$APPEND_SCRIPT" "$TEST_TMPDIR" 2>/dev/null

    assert_file_not_exists "$TEST_TMPDIR/.post-rotation-commit"
    assert_file_not_contains "$TEST_TMPDIR/docs/session-log.md" "Post-shutdown"
}
run_test "cleans up garbage hash without corrupting log" test_garbage_hash_cleaned

# ── Fallback insertion point ──────────────────────────────────────────────────

test_fallback_when_no_anchor() {
    # Session-log entry with no "Key Decisions" or "Pending at shutdown"
    git -C "$TEST_TMPDIR" init -q
    git -C "$TEST_TMPDIR" config user.email "test@test"
    git -C "$TEST_TMPDIR" config user.name "test"
    mkdir -p "$TEST_TMPDIR/docs"

    cat > "$TEST_TMPDIR/docs/session-log.md" <<'EOF'
# Session Log

### 2026-03-27T22:45Z — Test
**Goal:** Minimal entry
**Completed:**
- Something

### 2026-03-26T20:00Z — Previous
**Goal:** Old
EOF

    git -C "$TEST_TMPDIR" add -A && git -C "$TEST_TMPDIR" commit -qm "init"
    echo "$(git -C "$TEST_TMPDIR" rev-parse HEAD) $(date +%s)" > "$TEST_TMPDIR/.post-rotation-commit"

    echo "fix" > "$TEST_TMPDIR/fix.txt"
    git -C "$TEST_TMPDIR" add fix.txt && git -C "$TEST_TMPDIR" commit -qm "fallback fix"

    bash "$APPEND_SCRIPT" "$TEST_TMPDIR"

    assert_file_contains "$TEST_TMPDIR/docs/session-log.md" "Post-shutdown"
    assert_file_contains "$TEST_TMPDIR/docs/session-log.md" "fallback fix"
    # Should be in the first entry, not the second
    local post_line second_entry
    post_line=$(grep -n 'Post-shutdown' "$TEST_TMPDIR/docs/session-log.md" | head -1 | cut -d: -f1)
    second_entry=$(grep -n '^### ' "$TEST_TMPDIR/docs/session-log.md" | sed -n '2p' | cut -d: -f1)
    local order="wrong"
    [[ -n "$post_line" && -n "$second_entry" && "$post_line" -lt "$second_entry" ]] && order="correct"
    assert_eq "correct" "$order" "Post-shutdown should be in first entry, before second entry"
}
run_test "falls back to end of entry when no anchor found" test_fallback_when_no_anchor

# ── No session-log ────────────────────────────────────────────────────────────

test_no_session_log_cleans_marker() {
    git -C "$TEST_TMPDIR" init -q
    git -C "$TEST_TMPDIR" config user.email "test@test"
    git -C "$TEST_TMPDIR" config user.name "test"
    echo "x" > "$TEST_TMPDIR/x.txt"
    git -C "$TEST_TMPDIR" add -A && git -C "$TEST_TMPDIR" commit -qm "init"
    echo "$(git -C "$TEST_TMPDIR" rev-parse HEAD) $(date +%s)" > "$TEST_TMPDIR/.post-rotation-commit"
    echo "y" > "$TEST_TMPDIR/y.txt"
    git -C "$TEST_TMPDIR" add y.txt && git -C "$TEST_TMPDIR" commit -qm "post"

    bash "$APPEND_SCRIPT" "$TEST_TMPDIR"

    assert_file_not_exists "$TEST_TMPDIR/.post-rotation-commit"
}
run_test "cleans marker when no session-log exists" test_no_session_log_cleans_marker

suite_summary
