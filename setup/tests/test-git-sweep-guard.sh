#!/usr/bin/env bash
# Tests for global/hooks/git-sweep-guard.sh — PreToolUse Bash guard (CFG-556).
#
# Blocks pathspec-less `git add` forms (-A / -u / . / :/) when a concurrently-
# written shared directory has pending changes, because those forms stage files
# the session never touched. Three confirmed instances of a session sweeping
# another session's in-progress cross-project/ triage into its own commit.
#
# The guard must be NARROW: a guard that false-blocks trains the bypass
# (CFG-513), so it stays silent unless a real sweep is pending.
source "$(dirname "$0")/test-helpers.sh"

GUARD="$REPO_ROOT/global/hooks/git-sweep-guard.sh"

suite_header "git-sweep-guard.sh"

# Build a throwaway git repo with a controllable dirty state, run the guard
# against it with a synthetic PreToolUse payload, and return its exit code.
_run_guard() {  # usage: _run_guard <repo> <command>; echoes stderr, returns rc
    local repo="$1" cmd="$2" rc=0
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$cmd")" \
        | (cd "$repo" && bash "$GUARD") 2>"$TEST_TMPDIR/guard.err" || rc=$?
    cat "$TEST_TMPDIR/guard.err" >&2
    return "$rc"
}

_mkrepo() {  # $1 = dirty-shared? (yes|no)
    local d; d="$(mktemp -d "$TEST_TMPDIR/repo.XXXXXX")"
    git -C "$d" init -q
    git -C "$d" config user.email t@t; git -C "$d" config user.name t
    mkdir -p "$d/cross-project/inbox" "$d/src"
    echo base > "$d/cross-project/inbox/aiware.md"
    echo base > "$d/src/app.sh"
    git -C "$d" add -A >/dev/null 2>&1
    git -C "$d" commit -qm base >/dev/null 2>&1
    echo "mine" >> "$d/src/app.sh"                      # always: my own work
    [ "$1" = "yes" ] && echo "sibling edit" >> "$d/cross-project/inbox/aiware.md"
    echo "$d"
}

test_exists_and_executable() {
    assert_file_exists "$GUARD"; [ -x "$GUARD" ] || { echo "FAIL: not executable"; return 1; }
}
run_test "guard exists and is executable" test_exists_and_executable

test_syntax_ok() { bash -n "$GUARD"; }
run_test "bash syntax is valid" test_syntax_ok

# ── The failure this exists to stop ──────────────────────────────────────────
test_blocks_add_u_when_shared_dirty() {
    local r; r="$(_mkrepo yes)"; local rc=0
    _run_guard "$r" "git add -u" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "git add -u with dirty cross-project/ must BLOCK"
}
run_test "blocks 'git add -u' while cross-project/ is dirty" test_blocks_add_u_when_shared_dirty

test_blocks_add_A_when_shared_dirty() {
    local r; r="$(_mkrepo yes)"; local rc=0
    _run_guard "$r" "git add -A" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "git add -A with dirty cross-project/ must BLOCK"
}
run_test "blocks 'git add -A' while cross-project/ is dirty" test_blocks_add_A_when_shared_dirty

test_blocks_add_dot_when_shared_dirty() {
    local r; r="$(_mkrepo yes)"; local rc=0
    _run_guard "$r" "git add ." 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "git add . with dirty cross-project/ must BLOCK"
}
run_test "blocks 'git add .' while cross-project/ is dirty" test_blocks_add_dot_when_shared_dirty

test_block_message_names_the_files() {
    local r; r="$(_mkrepo yes)"
    _run_guard "$r" "git add -u" 2>"$TEST_TMPDIR/msg" || true
    grep -q "cross-project/inbox/aiware.md" "$TEST_TMPDIR/msg" \
        || { echo "FAIL: block message must name the at-risk file"; cat "$TEST_TMPDIR/msg"; return 1; }
}
run_test "block message names the files that would be swept" test_block_message_names_the_files

# ── Narrowness: it must not fire when there is nothing to sweep ──────────────
test_allows_add_u_when_shared_clean() {
    local r; r="$(_mkrepo no)"; local rc=0
    _run_guard "$r" "git add -u" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "no pending cross-project/ changes: must ALLOW"
}
run_test "allows 'git add -u' when cross-project/ is clean" test_allows_add_u_when_shared_clean

test_allows_explicit_pathspec_even_when_dirty() {
    local r; r="$(_mkrepo yes)"; local rc=0
    _run_guard "$r" "git add src/app.sh" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "explicit pathspec is always the legal path"
}
run_test "allows an explicit pathspec while cross-project/ is dirty" test_allows_explicit_pathspec_even_when_dirty

# Staging your OWN cross-project edit by name is legitimate and must work —
# otherwise the guard has no legal path and trains the bypass (CFG-513).
test_allows_explicit_cross_project_path() {
    local r; r="$(_mkrepo yes)"; local rc=0
    _run_guard "$r" "git add cross-project/inbox/aiware.md" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "naming the cross-project file explicitly must ALLOW"
}
run_test "allows an explicitly named cross-project/ path" test_allows_explicit_cross_project_path

test_ignores_non_git_commands() {
    local r; r="$(_mkrepo yes)"; local rc=0
    _run_guard "$r" "ls -la" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "non-git command must be ignored"
}
run_test "ignores non-git commands" test_ignores_non_git_commands

test_ignores_other_git_subcommands() {
    local r; r="$(_mkrepo yes)"; local rc=0
    _run_guard "$r" "git status --porcelain" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "git status must be ignored"
}
run_test "ignores git subcommands other than add" test_ignores_other_git_subcommands

test_ignores_repo_without_shared_dir() {
    local d; d="$(mktemp -d "$TEST_TMPDIR/plain.XXXXXX")"
    git -C "$d" init -q; git -C "$d" config user.email t@t; git -C "$d" config user.name t
    mkdir -p "$d/src"; echo x > "$d/src/a.sh"
    git -C "$d" add -A >/dev/null 2>&1; git -C "$d" commit -qm base >/dev/null 2>&1
    echo y >> "$d/src/a.sh"
    local rc=0
    _run_guard "$d" "git add -u" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "repo with no cross-project/ dir must ALLOW"
}
run_test "ignores repos that have no shared directory" test_ignores_repo_without_shared_dir

test_ignores_non_bash_tool() {
    local r; r="$(_mkrepo yes)"; local rc=0
    printf '{"tool_name":"Edit","tool_input":{"command":"git add -u"}}' \
        | (cd "$r" && bash "$GUARD") 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "non-Bash tool must be ignored"
}
run_test "ignores non-Bash tool calls" test_ignores_non_bash_tool

test_outside_any_repo_is_silent() {
    local d; d="$(mktemp -d "$TEST_TMPDIR/norepo.XXXXXX")"; local rc=0
    _run_guard "$d" "git add -u" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "outside a git repo the guard must not block"
}
run_test "is silent outside any git repository" test_outside_any_repo_is_silent

suite_summary
