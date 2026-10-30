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
SHAPES="$REPO_ROOT/.githooks/leak-shapes.sh"
LEAK="srv123456"   # a hostname SHAPE the hook flags (setup/tests/ is excluded from the scan)

make_repo() {
    local d="$TEST_TMPDIR/repo-$RANDOM"; mkdir -p "$d/.githooks"
    cp "$HOOK" "$d/.githooks/pre-push"
    [ -f "$SHAPES" ] && cp "$SHAPES" "$d/.githooks/leak-shapes.sh"
    (
        cd "$d" || exit 1
        git init -q; git config user.email t@t; git config user.name t
        printf 'tmp/\n' > .gitignore
        printf '# clean\n' > README.md
        git add .gitignore README.md .githooks; git commit -qm init
    )
    printf '%s' "$d"
}

# Commit <content> as notes.md and run the hook; prints the rc.
commit_and_run() {  # commit_and_run <repo> <content>
    printf '%s\n' "$2" > "$1/notes.md"
    git -C "$1" add notes.md; git -C "$1" commit -qm probe
    local rc=0; run_hook "$1" || rc=$?
    printf '%s' "$rc"
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

# ── CFG-869: SHAPES, not one owner's literals ────────────────────────────────
# The hook used to carry the owner's name, four e-mail addresses, two hostnames
# and two IPs as its pattern list: the leak detector was the leak. It now flags
# identifier CLASSES — a home directory, a Windows/VPS hostname shape, an IPv4
# address, an e-mail address — and a deployment's own literals live outside the
# repo, in the optional gitignored .githooks/personal-patterns.local.

test_hook_carries_no_owner_literals() {
    # The owner's literals come from the deployment's own gitignored list, never from
    # this file: a needle spelled out here (even split by concatenation) would publish
    # exactly what the hook stopped publishing. No local list → nothing to compare.
    local list="$REPO_ROOT/.githooks/personal-patterns.local"
    if [[ ! -f "$list" ]]; then
        echo "    measured: no .githooks/personal-patterns.local in this clone — skipped"
        return 0
    fi
    local owner; owner=$(PERSONAL_PATTERNS=""; source "$list"; printf '%s' "$PERSONAL_PATTERNS")
    if [[ -z "$owner" ]]; then
        echo "    measured: personal-patterns.local defines no PERSONAL_PATTERNS — skipped"
        return 0
    fi
    local hits; hits=$(grep -cE "$owner" "$HOOK" "$SHAPES" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')
    echo "    measured: owner-literal lines in the hook and its shapes file = $hits"
    assert_eq "0" "$hits" "the public hook must carry pattern SHAPES only (CFG-869)"
}
run_test "hook source carries no owner literals (CFG-869)" test_hook_carries_no_owner_literals

test_shape_home_path_blocks() {
    local d; d=$(make_repo)
    local rc; rc=$(commit_and_run "$d" "key at /home/alice/.ssh/id_ed25519")
    assert_eq "1" "$rc" "a committed /home/<name> path must block (rc=$rc)"
}
run_test "shape: a home directory path blocks" test_shape_home_path_blocks

test_shape_desktop_hostname_blocks() {
    local d; d=$(make_repo)
    local rc; rc=$(commit_and_run "$d" "session on DESKTOP-ABC1234 done")
    assert_eq "1" "$rc" "a committed DESKTOP-XXXXXXX hostname must block (rc=$rc)"
}
run_test "shape: a DESKTOP-* hostname blocks" test_shape_desktop_hostname_blocks

test_shape_srv_hostname_blocks() {
    local d; d=$(make_repo)
    local rc; rc=$(commit_and_run "$d" "deploy to $LEAK via ssh")
    assert_eq "1" "$rc" "a committed srvNNNNNN hostname must block (rc=$rc)"
}
run_test "shape: an srvNNNNNN hostname blocks" test_shape_srv_hostname_blocks

test_shape_private_ip_blocks() {
    local d; d=$(make_repo)
    local rc; rc=$(commit_and_run "$d" "NAS lives at 192.168.77.42")
    assert_eq "1" "$rc" "a committed RFC 1918 address must block (rc=$rc)"
}
run_test "shape: a private IPv4 address blocks" test_shape_private_ip_blocks

test_shape_public_ip_blocks() {
    local d; d=$(make_repo)
    # 198.18.0.9 is reserved (RFC 2544 benchmarking), so it is fictional, yet it is
    # NOT a documentation range — those three (RFC 5737) are allowed in docs.
    local rc; rc=$(commit_and_run "$d" "VPS is 198.18.0.9")
    assert_eq "1" "$rc" "a committed public-shaped address must block (rc=$rc)"
}
run_test "shape: a public IPv4 address blocks" test_shape_public_ip_blocks

test_shape_email_blocks() {
    local d; d=$(make_repo)
    local rc; rc=$(commit_and_run "$d" "contact alice@example.com for access")
    assert_eq "1" "$rc" "a committed e-mail address must block (rc=$rc)"
}
run_test "shape: an e-mail address blocks" test_shape_email_blocks

test_placeholders_do_not_block() {
    # The tokens a template legitimately contains: generic homes, loopback/any/
    # resolver/docker-bridge addresses, placeholder and service e-mail accounts.
    local d; d=$(make_repo)
    local rc; rc=$(commit_and_run "$d" "see /home/user/.bashrc and /home/username/x; bind 127.0.0.1 or 0.0.0.0; dns 8.8.8.8; bridge 172.17.0.1; docs 192.0.2.10 and 203.0.113.9; mail you@example.com, your-email@gmail.com, name@domain.com, git@github.com, noreply@anthropic.com, notifications@github.com")
    assert_eq "0" "$rc" "placeholder tokens must not block (rc=$rc) — a false block trains the bypass"
}
run_test "shape: documentation placeholders do not block" test_placeholders_do_not_block

test_local_pattern_file_is_honoured() {
    local d; d=$(make_repo)
    local rc; rc=$(commit_and_run "$d" "the zebra-unicorn-7 box")
    assert_eq "0" "$rc" "setup: a word no shape matches passes without a .local (rc=$rc)" || return 1
    printf "PERSONAL_PATTERNS='(zebra-unicorn-7)'\n" > "$d/.githooks/personal-patterns.local"
    rc=0; run_hook "$d" || rc=$?
    assert_eq "1" "$rc" "with .githooks/personal-patterns.local present its literals must block (rc=$rc)"
}
run_test ".githooks/personal-patterns.local is sourced when present" test_local_pattern_file_is_honoured

test_local_allow_exempts_a_line() {
    local d; d=$(make_repo)
    printf "PERSONAL_PATTERNS='(zebra-unicorn-7)'\nPERSONAL_ALLOW='github\\\\.com/zebra-unicorn-7/agent-fleet'\n" > "$d/.githooks/personal-patterns.local"
    local rc; rc=$(commit_and_run "$d" "clone https://github.com/zebra-unicorn-7/agent-fleet")
    assert_eq "0" "$rc" "a line matching PERSONAL_ALLOW is exempt (rc=$rc)" || return 1
    rc=$(commit_and_run "$d" "owner zebra-unicorn-7 elsewhere")
    assert_eq "1" "$rc" "the same literal outside the allowed form still blocks (rc=$rc)"
}
run_test "PERSONAL_ALLOW in the .local file exempts an intended form (clone URL)" test_local_allow_exempts_a_line

test_local_pattern_file_is_gitignored() {
    local rc=0; git -C "$REPO_ROOT" check-ignore -q .githooks/personal-patterns.local || rc=$?
    assert_eq "0" "$rc" ".githooks/personal-patterns.local must be gitignored (it holds the literals)"
}
run_test ".githooks/personal-patterns.local is gitignored" test_local_pattern_file_is_gitignored

suite_summary
