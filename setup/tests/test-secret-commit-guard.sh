#!/usr/bin/env bash
# Tests for global/hooks/secret-commit-guard.sh — PreToolUse Bash guard (CFG-652/653).
#
# Why this guard exists (the lrn audit of 2026-09-21): a secret scan ALREADY
# existed, inside config-auto-sync.sh's own commit path. That path carried 213
# of 2,583 commits, so ~92% of commits — including all four CFG-608 leaks —
# were never scanned at all. The guard was bound to the SessionEnd event
# instead of to the commit event.
#
# Two properties this suite pins down, because they are the two things the old
# scan got wrong:
#   1. It must fire on an ORDINARY `git commit` typed in a Bash call, which is
#      how ~92% of this repo's commits are made.
#   2. It must catch a secret written as PROSE. The old patterns were
#      shape-based (`password\s*[:=]`, `ghp_…`), and three of the four leaked
#      values were human-memorable strings in sentences, which have no shape.
#      That is what the fingerprint path is for.
#
# And one thing it must NOT do: match the commit MESSAGE. CFG-621 is a live
# defect where vault-read-guard.sh blocks ordinary commits because the English
# word "more" appears in an -m body. A guard that false-blocks trains the
# bypass (CFG-513), so this one reads the staged diff and nothing else.
source "$(dirname "$0")/test-helpers.sh"

GUARD="$REPO_ROOT/global/hooks/secret-commit-guard.sh"

suite_header "secret-commit-guard.sh"

# Run the guard against a repo with a synthetic PreToolUse payload.
_run_guard() {  # usage: _run_guard <repo> <command> [salt_dir]; returns rc
    local repo="$1" cmd="$2" rc=0
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$cmd")" \
        | (cd "$repo" && bash "$GUARD") 2>"$TEST_TMPDIR/guard.err" || rc=$?
    cat "$TEST_TMPDIR/guard.err" >&2
    return "$rc"
}

_run_guard_tool() {  # non-Bash tool payload
    local tool="$1" rc=0
    printf '{"tool_name":"%s","tool_input":{"file_path":"/tmp/x"}}' "$tool" \
        | bash "$GUARD" 2>"$TEST_TMPDIR/guard.err" || rc=$?
    return "$rc"
}

# A repo whose staged diff we control.
_mkrepo() {
    local d; d="$(mktemp -d "$TEST_TMPDIR/repo.XXXXXX")"
    git -C "$d" init -q
    git -C "$d" config user.email t@t; git -C "$d" config user.name t
    mkdir -p "$d/docs" "$d/secrets"
    echo base > "$d/docs/session-log.md"
    git -C "$d" add -A >/dev/null 2>&1
    git -C "$d" commit -qm base >/dev/null 2>&1
    echo "$d"
}

_stage() {  # _stage <repo> <relpath> <content>
    mkdir -p "$(dirname "$1/$2")"
    printf '%s\n' "$3" >> "$1/$2"
    git -C "$1" add "$2" >/dev/null 2>&1
}

# Write a salted fingerprint set the way vault-manage.sh will.
_mkfingerprints() {  # _mkfingerprints <repo> <secret-value>...
    local repo="$1"; shift
    local salt="testsalt0123456789"
    printf '%s' "$salt" > "$repo/secrets/.fingerprint-salt"
    : > "$repo/secrets/.secret-fingerprints"
    local v
    for v in "$@"; do
        python3 -c 'import hashlib,sys;print(hashlib.sha256((sys.argv[1]+sys.argv[2]).encode()).hexdigest())' \
            "$salt" "$v" >> "$repo/secrets/.secret-fingerprints"
    done
}

# ── 1. The failure that actually happened: prose, no shape ────────────────────
# The vault passphrase entered via a sentence in a tracked report. No
# shape-based pattern can match this; only a value fingerprint can.
test_blocks_prose_secret_via_fingerprint() {
    local repo; repo="$(_mkrepo)"
    _mkfingerprints "$repo" "correct-horse-battery-staple"
    _stage "$repo" "reports/audit.md" \
        "The audit found the passphrase correct-horse-battery-staple in a gitignored file."
    local rc=0; _run_guard "$repo" "git commit -m 'audit report'" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "prose secret matching a fingerprint must BLOCK"
}
run_test "blocks a secret written as prose, matched by fingerprint" test_blocks_prose_secret_via_fingerprint

# ── 2. Shape-based secrets still blocked ──────────────────────────────────────
test_blocks_shaped_token() {
    local repo; repo="$(_mkrepo)"
    _stage "$repo" "docs/notes.md" "export GH=ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"  # pragma: allowlist secret
    local rc=0; _run_guard "$repo" "git commit -m notes" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "a shaped credential token must BLOCK"
}
run_test "blocks a shape-matched credential token" test_blocks_shaped_token

# ── 3. It must fire on an ORDINARY git commit, not only the hook's own path ───
test_fires_on_plain_commit_with_c_flag() {
    local repo; repo="$(_mkrepo)"
    _mkfingerprints "$repo" "correct-horse-battery-staple"
    _stage "$repo" "docs/session-log.md" "NAS admin password is correct-horse-battery-staple"
    local rc=0
    # invoked from elsewhere, targeting the repo with -C — the common fleet form
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "git -C $repo commit -m log")" \
        | bash "$GUARD" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "guard must resolve the repo from 'git -C <dir> commit'"
}
run_test "fires on 'git -C <dir> commit', not just the cwd repo" test_fires_on_plain_commit_with_c_flag

# ── 4. Clean diff passes ──────────────────────────────────────────────────────
test_allows_clean_diff() {
    local repo; repo="$(_mkrepo)"
    _mkfingerprints "$repo" "correct-horse-battery-staple"
    _stage "$repo" "docs/session-log.md" "Nothing sensitive here, just ordinary prose."
    local rc=0; _run_guard "$repo" "git commit -m log" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "a clean staged diff must pass"
}
run_test "allows a clean staged diff" test_allows_clean_diff

# ── 5. CFG-621 lesson: never match the commit MESSAGE ─────────────────────────
# vault-read-guard.sh blocks commits because the word "more" appears in an -m
# body. This guard must read the staged diff only, so a message that quotes a
# secret-shaped string while the diff is clean still passes.
test_ignores_commit_message_content() {
    local repo; repo="$(_mkrepo)"
    _mkfingerprints "$repo" "correct-horse-battery-staple"
    _stage "$repo" "docs/session-log.md" "ordinary line"
    local rc=0
    _run_guard "$repo" "git commit -m 'rotate the password: see vault-ops for more'" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "guard must not scan the commit message, only the staged diff"
}
run_test "does not match the commit message (CFG-621 class)" test_ignores_commit_message_content

# ── 6. Narrowness: unrelated commands and tools are untouched ─────────────────
test_ignores_non_commit_bash() {
    local repo; repo="$(_mkrepo)"
    _mkfingerprints "$repo" "correct-horse-battery-staple"
    _stage "$repo" "docs/session-log.md" "passphrase correct-horse-battery-staple"
    local rc=0; _run_guard "$repo" "git status" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "a non-commit git command must pass even with a dirty index"
}
run_test "ignores Bash commands that are not a commit" test_ignores_non_commit_bash

test_ignores_non_bash_tool() {
    local rc=0; _run_guard_tool "Read" || rc=$?
    assert_eq "0" "$rc" "non-Bash tools must pass"
}
run_test "ignores non-Bash tools" test_ignores_non_bash_tool

# ── 7. Degradation: no fingerprint file means shape-only, never a hard error ──
test_degrades_without_fingerprints() {
    local repo; repo="$(_mkrepo)"   # no _mkfingerprints call
    _stage "$repo" "docs/session-log.md" "ordinary line"
    local rc=0; _run_guard "$repo" "git commit -m log" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "absent fingerprint file must degrade to shape-only, not error"
}
run_test "degrades to shape-only when no fingerprint file exists" test_degrades_without_fingerprints

# ── 8. The guard must never print the secret value ────────────────────────────
# A block message that echoes the matched line would put the credential into the
# transcript and the scrollback — the exact exposure being prevented.
test_block_message_hides_value() {
    local repo; repo="$(_mkrepo)"
    _mkfingerprints "$repo" "correct-horse-battery-staple"
    _stage "$repo" "reports/audit.md" "passphrase correct-horse-battery-staple here"
    local out; out="$( _run_guard "$repo" "git commit -m audit" 2>&1 >/dev/null || true )"
    assert_not_contains "$out" "correct-horse-battery-staple" \
        "block message must name the file, never the value"
    assert_contains "$out" "reports/audit.md" "block message must name the offending file"
}
run_test "block message names the file but never the value" test_block_message_hides_value

# ── 9. The allowlist marker, and its narrowness ───────────────────────────────
# Documentation about secret scanning has to contain secret-shaped examples;
# this guard blocked its own first real commit for exactly that reason. The
# marker must exempt the line that carries it and NOTHING else, so an unmarked
# line with identical content still blocks.
test_allowlist_marker_exempts_that_line() {
    local repo; repo="$(_mkrepo)"
    _stage "$repo" "docs/notes.md" \
        "example only: ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  # pragma: allowlist secret"
    local rc=0; _run_guard "$repo" "git commit -m notes" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "a line carrying the allowlist marker must pass"
}
run_test "allowlist marker exempts the line that carries it" test_allowlist_marker_exempts_that_line

test_allowlist_marker_does_not_exempt_neighbours() {
    local repo; repo="$(_mkrepo)"
    _stage "$repo" "docs/notes.md" \
        "documented: ghp_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  # pragma: allowlist secret"
    _stage "$repo" "docs/notes.md" \
        "real leak: ghp_cccccccccccccccccccccccccccccccccccc"  # pragma: allowlist secret
    local rc=0; _run_guard "$repo" "git commit -m notes" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "an unmarked line in the same file must still BLOCK"
}
run_test "allowlist marker does not exempt neighbouring lines" test_allowlist_marker_does_not_exempt_neighbours

# ── 10. Syntax ────────────────────────────────────────────────────────────────
test_syntax_valid() {
    assert_success bash -n "$GUARD"
}
run_test "bash syntax is valid" test_syntax_valid

suite_summary
