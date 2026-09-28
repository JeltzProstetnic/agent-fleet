#!/usr/bin/env bash
# Tests for .githooks/pre-push — the personal-data push guard.
#
# CFG-555: the guard grepped the WORKING TREE, so a gitignored file that can never
# be pushed blocked every push, and the only way past was --no-verify, which
# disables the guard wholesale. The guard must judge what is being PUSHED: the
# commits named on stdin (or HEAD when run by hand).
source "$(dirname "$0")/test-helpers.sh"

suite_header "pre-push personal-data guard scans pushed commits, not the tree"

HOOK="$REPO_ROOT/.githooks/pre-push"
LEAK="srv943133"   # one of the hook's patterns (setup/tests/ is excluded from the scan)

make_repo() {
    local d="$TEST_TMPDIR/repo-$RANDOM"; mkdir -p "$d/.githooks"
    cp "$HOOK" "$d/.githooks/pre-push"
    (
        cd "$d" || exit 1
        git init -q; git config user.email t@t; git config user.name t
        printf 'tmp/\n' > .gitignore
        printf '# clean\n' > README.md
        git add .gitignore README.md .githooks/pre-push; git commit -qm init
    )
    printf '%s' "$d"
}

# Run the hook as git would: refs on stdin, "<local ref> <local sha> <remote ref> <remote sha>".
run_hook() {
    local d="$1" sha; sha=$(git -C "$d" rev-parse HEAD)
    printf 'refs/heads/main %s refs/heads/main %s\n' "$sha" "0000000000000000000000000000000000000000" \
        | bash "$d/.githooks/pre-push" origin https://example.invalid/repo.git >/dev/null 2>&1
}

test_ignored_file_does_not_block() {
    local d; d=$(make_repo)
    mkdir -p "$d/tmp"; printf 'host %s\n' "$LEAK" > "$d/tmp/probe.md"
    local rc=0; run_hook "$d" || rc=$?
    assert_eq "0" "$rc" "a gitignored file can never be pushed, so it must not block (rc=$rc)"
}
run_test "gitignored file with a pattern: push allowed" test_ignored_file_does_not_block

test_uncommitted_edit_does_not_block() {
    local d; d=$(make_repo)
    printf 'host %s\n' "$LEAK" >> "$d/README.md"
    local rc=0; run_hook "$d" || rc=$?
    assert_eq "0" "$rc" "an uncommitted edit is not in the push (rc=$rc)"
}
run_test "uncommitted edit with a pattern: push allowed" test_uncommitted_edit_does_not_block

test_committed_leak_blocks() {
    local d; d=$(make_repo)
    printf 'host %s\n' "$LEAK" > "$d/notes.md"
    git -C "$d" add notes.md; git -C "$d" commit -qm leak
    local rc=0; run_hook "$d" || rc=$?
    assert_eq "1" "$rc" "a committed pattern in the pushed commit must block (rc=$rc)"
}
run_test "committed pattern: push blocked" test_committed_leak_blocks

test_manual_run_uses_head() {
    local d; d=$(make_repo)
    printf 'host %s\n' "$LEAK" > "$d/notes.md"
    git -C "$d" add notes.md; git -C "$d" commit -qm leak
    local rc=0; bash "$d/.githooks/pre-push" </dev/null >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "run by hand with no stdin, HEAD is what gets checked (rc=$rc)"
}
run_test "manual run with no refs: checks HEAD" test_manual_run_uses_head

test_branch_delete_is_allowed() {
    local d; d=$(make_repo)
    local rc=0
    printf '(delete) 0000000000000000000000000000000000000000 refs/heads/gone %s\n' "$(git -C "$d" rev-parse HEAD)" \
        | bash "$d/.githooks/pre-push" origin x >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "deleting a remote branch pushes no content (rc=$rc)"
}
run_test "branch delete: allowed" test_branch_delete_is_allowed

suite_summary
