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
# CFG-667: the fleet now EXPORTS CC_SECRET_FINGERPRINTS/CC_SECRET_SALT from
# settings.json, so they are present in any real session's environment and would
# silently override every fixture below — the guard would consult the fleet's
# real fingerprints instead of the throwaway ones each test writes, and three
# cases went red the moment the export landed. Point them at the repo under test
# by default so the suite controls its own inputs; a case that wants the ambient
# or absent behaviour sets them explicitly. See knowledge/test-isolation-guards.md.
_run_guard() {  # usage: _run_guard <repo> <command> [salt_dir]; returns rc
    local repo="$1" cmd="$2" rc=0
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$cmd")" \
        | (cd "$repo" \
           && export CC_SECRET_FINGERPRINTS="${CC_SECRET_FINGERPRINTS_OVERRIDE:-$repo/secrets/.secret-fingerprints}" \
           && export CC_SECRET_SALT="${CC_SECRET_SALT_OVERRIDE:-$repo/secrets/.fingerprint-salt}" \
           && bash "$GUARD") 2>"$TEST_TMPDIR/guard.err" || rc=$?
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

# ── 1b. The SAME failure in any repo but cfg-agent-fleet ──────────────────────
# CFG-667. FP_FILE is "$ROOT/secrets/.secret-fingerprints" — repo-relative. Only
# cfg-agent-fleet has that file, so in the other 14 fleet repos the guard
# silently degrades to shape-only, which is the half that provably cannot match
# prose. Three of the four historical leaks were prose, and one of them was in
# a customer-facing project. The env override exists in the code and was set
# nowhere, so the detector that matters was inert exactly where it was needed.
test_env_override_arms_a_repo_without_its_own_fingerprints() {
    local repo fpdir
    repo="$(_mkrepo)"
    # A separate repo supplies the fingerprints — as cfg-agent-fleet does for the fleet.
    fpdir="$(_mkrepo)"
    _mkfingerprints "$fpdir" "correct-horse-battery-staple"
    # The repo under test has NO fingerprints of its own. This is the real case.
    [ -e "$repo/secrets/.secret-fingerprints" ] && return 1
    _stage "$repo" "docs/pending-next-session.md" \
        "Console login is jeltz, the password is correct-horse-battery-staple."
    local rc=0
    CC_SECRET_FINGERPRINTS_OVERRIDE="$fpdir/secrets/.secret-fingerprints" \
    CC_SECRET_SALT_OVERRIDE="$fpdir/secrets/.fingerprint-salt" \
        _run_guard "$repo" "git commit -m handover" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "a repo without its own fingerprints must still value-match via CC_SECRET_FINGERPRINTS"
}
run_test "env override arms value-matching in a repo with no fingerprints of its own" test_env_override_arms_a_repo_without_its_own_fingerprints

# The deployment half: the override must actually be SET, or the code path above
# is dead everywhere. Asserts the shipped settings template arms it.
test_settings_template_arms_the_override() {
    local out
    out=$(python3 - "$REPO_ROOT/setup/config/settings.json" <<'PYEOF'
import json,sys
env=json.load(open(sys.argv[1])).get("env",{})
print(env.get("CC_SECRET_FINGERPRINTS",""), env.get("CC_SECRET_SALT",""))
PYEOF
)
    assert_contains "$out" ".secret-fingerprints" "settings template must export CC_SECRET_FINGERPRINTS" || return 1
    assert_contains "$out" ".fingerprint-salt" "settings template must export CC_SECRET_SALT"
}
run_test "settings template arms the fingerprint override fleet-wide" test_settings_template_arms_the_override

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
        | CC_SECRET_FINGERPRINTS="$repo/secrets/.secret-fingerprints" \
          CC_SECRET_SALT="$repo/secrets/.fingerprint-salt" \
          bash "$GUARD" 2>/dev/null || rc=$?
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

# ── 10. CFG-668: the commit forms that never touch the index first ───────────
# The guard read `git diff --cached` and nothing else, so a commit that stages
# and commits in one step — a modified TRACKED file, which is exactly the shape
# of a handover or a knowledge file being edited — went through unexamined.
# This suite had zero such cases, so the gap was invisible from inside it.
#
# Every case below modifies a tracked file WITHOUT staging it, then issues the
# form of commit that would carry it. The staged diff is clean in all of them.

# Modify a tracked file in the working tree without staging it.
_modify() {  # _modify <repo> <relpath> <content>
    printf '%s\n' "$3" >> "$1/$2"
}

# Like _run_guard, but the Bash call's cwd is <cwd> — pathspecs resolve there.
_run_guard_in() {  # usage: _run_guard_in <repo> <cwd> <command>; returns rc
    local repo="$1" cwd="$2" cmd="$3" rc=0
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$cmd")" \
        | (cd "$cwd" \
           && export CC_SECRET_FINGERPRINTS="$repo/secrets/.secret-fingerprints" \
           && export CC_SECRET_SALT="$repo/secrets/.fingerprint-salt" \
           && bash "$GUARD") 2>"$TEST_TMPDIR/guard.err" || rc=$?
    cat "$TEST_TMPDIR/guard.err" >&2
    return "$rc"
}

# A repo with one unstaged secret in a tracked file and nothing staged.
_mkrepo_with_unstaged_secret() {
    local repo; repo="$(_mkrepo)"
    _mkfingerprints "$repo" "correct-horse-battery-staple"
    _modify "$repo" "docs/session-log.md" "NAS admin password is correct-horse-battery-staple"
    echo "$repo"
}

test_blocks_commit_dash_a() {
    local repo; repo="$(_mkrepo_with_unstaged_secret)"
    local rc=0 out
    out="$( _run_guard "$repo" "git commit -a -m log" 2>&1 >/dev/null )" || rc=$?
    assert_eq "2" "$rc" "'git commit -a' commits the unstaged edit, so it must BLOCK" || return 1
    assert_contains "$out" "docs/session-log.md" "the block message must name the file the -a commit carries"
}
run_test "blocks 'git commit -a' carrying an unstaged secret (CFG-668)" test_blocks_commit_dash_a

test_blocks_commit_dash_am() {
    local repo; repo="$(_mkrepo_with_unstaged_secret)"
    local rc=0; _run_guard "$repo" "git commit -am 'log update'" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "'git commit -am' must BLOCK"
}
run_test "blocks 'git commit -am' (CFG-668)" test_blocks_commit_dash_am

test_blocks_commit_all_long() {
    local repo; repo="$(_mkrepo_with_unstaged_secret)"
    local rc=0; _run_guard "$repo" "git commit --all -m log" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "'git commit --all' must BLOCK"
}
run_test "blocks 'git commit --all' (CFG-668)" test_blocks_commit_all_long

test_blocks_commit_short_cluster_with_a() {
    local repo; repo="$(_mkrepo_with_unstaged_secret)"
    local rc=0; _run_guard "$repo" "git commit -qam log" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "'-qam' carries -a inside a short-flag cluster and must BLOCK"
}
run_test "blocks '-a' inside a short-flag cluster (-qam) (CFG-668)" test_blocks_commit_short_cluster_with_a

test_blocks_commit_am_with_heredoc_message() {
    local repo; repo="$(_mkrepo_with_unstaged_secret)"
    local rc=0
    _run_guard "$repo" "git commit -am \"\$(cat <<'EOF'
log update

Body text.
EOF
)\"" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "-am with a heredoc message is still an -a commit and must BLOCK"
}
run_test "blocks '-am' with a heredoc message (CFG-668)" test_blocks_commit_am_with_heredoc_message

test_blocks_commit_dash_a_via_C_flag() {
    local repo; repo="$(_mkrepo_with_unstaged_secret)"
    local rc=0
    _run_guard_in "$repo" "$TEST_TMPDIR" "git -C $repo commit -am log" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "'git -C <dir> commit -am' must resolve the repo and BLOCK"
}
run_test "blocks 'git -C <dir> commit -am' (CFG-668)" test_blocks_commit_dash_a_via_C_flag

test_blocks_commit_with_pathspec() {
    local repo; repo="$(_mkrepo_with_unstaged_secret)"
    local rc=0; _run_guard "$repo" "git commit -m log docs/session-log.md" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "'git commit <path>' commits the working-tree file and must BLOCK"
}
run_test "blocks 'git commit <path>' carrying an unstaged secret (CFG-668)" test_blocks_commit_with_pathspec

test_blocks_commit_with_pathspec_after_double_dash() {
    local repo; repo="$(_mkrepo_with_unstaged_secret)"
    local rc=0; _run_guard "$repo" "git commit -m log -- docs/session-log.md" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "'git commit -- <path>' must BLOCK"
}
run_test "blocks 'git commit -- <path>' (CFG-668)" test_blocks_commit_with_pathspec_after_double_dash

test_blocks_commit_only() {
    local repo; repo="$(_mkrepo_with_unstaged_secret)"
    local rc=0; _run_guard "$repo" "git commit --only docs/session-log.md -m log" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "'git commit --only <path>' must BLOCK" || return 1
    rc=0; _run_guard "$repo" "git commit -o docs/session-log.md -m log" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "'git commit -o <path>' must BLOCK"
}
run_test "blocks 'git commit --only/-o <path>' (CFG-668)" test_blocks_commit_only

test_blocks_commit_include() {
    local repo; repo="$(_mkrepo_with_unstaged_secret)"
    local rc=0; _run_guard "$repo" "git commit --include docs/session-log.md -m log" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "'git commit --include <path>' must BLOCK" || return 1
    rc=0; _run_guard "$repo" "git commit -i docs/session-log.md -m log" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "'git commit -i <path>' must BLOCK"
}
run_test "blocks 'git commit --include/-i <path>' (CFG-668)" test_blocks_commit_include

test_include_still_scans_the_index() {
    # --include = index PLUS the named paths; a staged secret elsewhere must not
    # slip through just because a clean path was named.
    local repo; repo="$(_mkrepo)"
    _mkfingerprints "$repo" "correct-horse-battery-staple"
    _stage "$repo" "reports/audit.md" "passphrase correct-horse-battery-staple"
    _modify "$repo" "docs/session-log.md" "ordinary line"
    local rc=0; _run_guard "$repo" "git commit -i docs/session-log.md -m log" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "--include must scan the index as well as the named paths"
}
run_test "--include scans the index as well as the named paths (CFG-668)" test_include_still_scans_the_index

test_pathspec_resolves_against_command_cwd() {
    # A Bash call issued from a subdirectory names the path relative to it.
    local repo; repo="$(_mkrepo_with_unstaged_secret)"
    local rc=0
    _run_guard_in "$repo" "$repo/docs" "git commit -m log session-log.md" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "a pathspec relative to the call's cwd must still be scanned"
}
run_test "pathspec resolves against the call's cwd, not the repo root (CFG-668)" test_pathspec_resolves_against_command_cwd

# ── 10b. Narrowness: the working tree is read ONLY when the commit carries it ─
# A guard that false-blocks trains the bypass (CFG-513). A plain commit must
# stay index-only, message words must never be mistaken for pathspecs, and an
# untracked file is never part of a -a commit.

test_plain_commit_ignores_unstaged_working_tree() {
    local repo; repo="$(_mkrepo_with_unstaged_secret)"
    _stage "$repo" "docs/notes.md" "ordinary staged line"
    local rc=0; _run_guard "$repo" "git commit -m notes" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "a plain commit records the index only; the unstaged secret is not in it"
}
run_test "plain commit does not scan unstaged working-tree edits" test_plain_commit_ignores_unstaged_working_tree

test_message_words_are_not_pathspecs() {
    # 'docs' is a real directory holding an unstaged secret. Naive word-splitting
    # of the -m body would hand it to the pathspec scan and false-block.
    local repo; repo="$(_mkrepo_with_unstaged_secret)"
    _stage "$repo" "docs/notes.md" "ordinary staged line"
    local rc=0
    _run_guard "$repo" "git commit -m 'update docs and README' --author 'docs <d@d>'" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "words inside a quoted -m body or an option value must not be read as pathspecs"
}
run_test "message words and option values are not mistaken for pathspecs" test_message_words_are_not_pathspecs

test_dash_a_ignores_untracked_files() {
    local repo; repo="$(_mkrepo)"
    _mkfingerprints "$repo" "correct-horse-battery-staple"
    _modify "$repo" "docs/session-log.md" "ordinary edit"
    printf '%s\n' "passphrase correct-horse-battery-staple" > "$repo/docs/untracked.md"
    local rc=0; _run_guard "$repo" "git commit -am log" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "-a never commits an untracked file, so it must not be scanned"
}
run_test "-a does not scan untracked files" test_dash_a_ignores_untracked_files

# ── 10c. CFG-668 repair: the index is ALWAYS read ───────────────────────────
# The first CFG-668 fix scanned the working tree for named paths and then
# STOPPED reading the index. The word-splitter did not know redirections, heredoc
# bodies or line continuations, so `2>&1`, `>/dev/null`, `<<'EOF'` and a
# message with "(x)" in it became "pathspecs", the index was skipped, and a
# STAGED credential in an everyday commit shape was committed unexamined. The
# base guard blocked every one of these because it always read --cached. So
# each shape below stages a secret and must BLOCK: whatever else the guard
# learns to read, it may never read less than the index.

# A repo with one STAGED shaped token and an otherwise clean tree.
_mkrepo_with_staged_token() {
    local repo; repo="$(_mkrepo)"
    _stage "$repo" "docs/notes.md" "token ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"  # pragma: allowlist secret
    echo "$repo"
}

_assert_staged_blocks() {  # _assert_staged_blocks <command> <label>
    local repo; repo="$(_mkrepo_with_staged_token)"
    local rc=0; _run_guard "$repo" "$1" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "staged secret must BLOCK for: $2"
}

test_staged_blocks_stderr_merge_and_pipe() {
    _assert_staged_blocks 'git commit -m "update docs" 2>&1 | tail -5' "2>&1 | tail"
}
run_test "staged secret blocks: commit ... 2>&1 | tail (CFG-668 repair)" test_staged_blocks_stderr_merge_and_pipe

test_staged_blocks_stderr_to_devnull() {
    _assert_staged_blocks 'git commit -q -m x 2>/dev/null' "2>/dev/null"
}
run_test "staged secret blocks: commit ... 2>/dev/null (CFG-668 repair)" test_staged_blocks_stderr_to_devnull

test_staged_blocks_stdout_to_devnull() {
    _assert_staged_blocks 'git commit -m "update docs" > /dev/null' "> /dev/null"
}
run_test "staged secret blocks: commit ... > /dev/null (CFG-668 repair)" test_staged_blocks_stdout_to_devnull

test_staged_blocks_stdin_from_devnull() {
    _assert_staged_blocks 'git commit -m "update docs" </dev/null' "</dev/null"
}
run_test "staged secret blocks: commit ... </dev/null (CFG-668 repair)" test_staged_blocks_stdin_from_devnull

test_staged_blocks_message_from_stdin_heredoc() {
    _assert_staged_blocks "git commit -F - <<'EOF'
update docs
EOF" "-F - <<'EOF'"
}
run_test "staged secret blocks: commit -F - <<'EOF' (CFG-668 repair)" test_staged_blocks_message_from_stdin_heredoc

test_staged_blocks_line_continuation() {
    _assert_staged_blocks 'git commit \
  -m "update docs" \
  -m "second paragraph"' "backslash-newline continuation"
}
run_test "staged secret blocks: commit split over continued lines (CFG-668 repair)" test_staged_blocks_line_continuation

test_staged_blocks_heredoc_message_with_parenthesis_and_quote() {
    # A ")" in the body used to end the $( early; the next '"' then closed the
    # quote and the rest of the message spilled into "pathspecs".
    _assert_staged_blocks "git commit -m \"\$(cat <<'EOF'
Fix guard (CFG-1) so \"up to date\" holds
EOF
)\"" "heredoc message with (x) and a quote"
}
run_test "staged secret blocks: heredoc message containing '(x)' and '\"' (CFG-668 repair)" \
    test_staged_blocks_heredoc_message_with_parenthesis_and_quote

test_staged_blocks_heredoc_message_with_odd_quote_then_redirect() {
    _assert_staged_blocks "git commit -m \"\$(cat <<'EOF'
fix (x): handle 12\" screens
EOF
)\" 2>&1 | tail -3" "heredoc message with an odd quote, then 2>&1 | tail"
}
run_test "staged secret blocks: heredoc message with an odd quote, then a pipe (CFG-668 repair)" \
    test_staged_blocks_heredoc_message_with_odd_quote_then_redirect

test_staged_blocks_after_comment_with_apostrophe() {
    # An apostrophe in a comment must not open a quote that swallows the commit.
    _assert_staged_blocks "# don't forget the notes
git commit -m notes" "comment line containing an apostrophe"
}
run_test "staged secret blocks: commit after a comment with an apostrophe (CFG-668 repair)" \
    test_staged_blocks_after_comment_with_apostrophe

test_second_commit_in_chain_is_scanned() {
    # The first commit names a clean path; the second records the staged index.
    local repo; repo="$(_mkrepo_with_staged_token)"
    _modify "$repo" "docs/session-log.md" "ordinary edit"
    local rc=0
    _run_guard "$repo" "git commit -m a docs/session-log.md && git commit -m b" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "every commit in the command is scanned, not only the first"
}
run_test "a second commit in the same command is scanned (CFG-668 repair)" test_second_commit_in_chain_is_scanned

test_distinct_pathspec_lists_are_both_scanned() {
    # "docs/x y.md" (one path) and docs/x y.md (two paths) must not be merged
    # into one scan job just because they read the same when joined by spaces.
    local repo; repo="$(_mkrepo)"
    printf 'base\n' > "$repo/docs/x"; printf 'base\n' > "$repo/docs/x y.md"; printf 'base\n' > "$repo/y.md"
    git -C "$repo" add -A >/dev/null 2>&1; git -C "$repo" commit -qm files >/dev/null 2>&1
    _modify "$repo" "docs/x y.md" "harmless edit"
    _modify "$repo" "docs/x" "export GH=ghp_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"  # pragma: allowlist secret
    _modify "$repo" "y.md" "harmless edit"
    local rc=0
    _run_guard "$repo" 'git commit -m a "docs/x y.md" && git commit -m b docs/x y.md' 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "the second commit's pathspecs carry the secret and must be scanned"
}
run_test "two commits whose pathspecs join to the same text are both scanned (CFG-668 repair)" \
    test_distinct_pathspec_lists_are_both_scanned

# ── 10d. CFG-668 repair: the repo a leading `cd` moves into is the target ────
# The hook runs in the session's cwd. `cd <other repo> && git commit -am …`
# commits the OTHER repo, so its working tree is what -a records. Reading the
# session repo's tree instead false-blocks on unrelated edits there, and never
# looks at the content actually being committed.

test_cd_into_other_repo_ignores_session_repo_tree() {
    local a b; a="$(_mkrepo_with_unstaged_secret)"; b="$(_mkrepo)"
    _modify "$b" "docs/session-log.md" "harmless edit"
    local rc=0
    _run_guard_in "$a" "$a" "cd $b && git commit -am 'sync notes'" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "the session repo's unrelated unstaged edits are not part of a commit in another repo"
}
run_test "'cd <other> && git commit -am' ignores the session repo's tree (CFG-668 repair)" \
    test_cd_into_other_repo_ignores_session_repo_tree

test_cd_into_other_repo_scans_that_repo() {
    local a b; a="$(_mkrepo)"; b="$(_mkrepo_with_unstaged_secret)"
    local rc=0
    _run_guard_in "$b" "$a" "cd $b && git commit -am 'sync notes'" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "'cd <repo> && git commit -am' must scan the repo it moved into"
}
run_test "'cd <other> && git commit -am' scans the repo it moved into (CFG-668 repair)" \
    test_cd_into_other_repo_scans_that_repo

test_cd_in_subshell_scans_that_repo() {
    local a b; a="$(_mkrepo)"; b="$(_mkrepo_with_unstaged_secret)"
    local rc=0
    _run_guard_in "$b" "$a" "(cd $b && git commit -am 'sync notes')" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "'(cd <repo> && git commit -am)' must scan the repo it moved into"
}
run_test "'(cd <other> && git commit -am)' scans the repo it moved into (CFG-668 repair)" \
    test_cd_in_subshell_scans_that_repo

test_cd_then_plain_commit_scans_that_index() {
    local a b; a="$(_mkrepo)"; b="$(_mkrepo_with_staged_token)"
    local rc=0
    _run_guard_in "$b" "$a" "cd $b; git commit -m notes" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "'cd <repo>; git commit' must scan that repo's index"
}
run_test "'cd <other>; git commit' scans that repo's index (CFG-668 repair)" \
    test_cd_then_plain_commit_scans_that_index

# ── 10e. CFG-668 repair: forms that carry the working tree some other way ────

test_env_prefixed_commit_is_scanned() {
    local repo; repo="$(_mkrepo_with_unstaged_secret)"
    local rc=0; _run_guard "$repo" "GIT_AUTHOR_NAME=x git commit -am log" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "an env-prefixed 'git commit -am' is still a commit and must BLOCK"
}
run_test "blocks an env-prefixed 'VAR=x git commit -am' (CFG-668 repair)" test_env_prefixed_commit_is_scanned

test_pathspec_from_file_is_scanned() {
    local repo; repo="$(_mkrepo_with_unstaged_secret)"
    printf 'docs/session-log.md\n' > "$repo/list.txt"
    local rc=0
    _run_guard "$repo" "git commit -m log --pathspec-from-file=list.txt" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "--pathspec-from-file commits the working-tree content of the listed paths"
}
run_test "blocks '--pathspec-from-file' carrying an unstaged secret (CFG-668 repair)" test_pathspec_from_file_is_scanned

test_unresolvable_pathspec_scans_tracked_tree() {
    # "$F" is unknown before the command runs; it may name any tracked file.
    local repo; repo="$(_mkrepo_with_unstaged_secret)"
    local rc=0; _run_guard "$repo" 'git commit -m log "$F"' 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "a pathspec the shell computes at run time must not be assumed harmless"
}
run_test "an unresolvable pathspec scans the tracked working tree (CFG-668 repair)" \
    test_unresolvable_pathspec_scans_tracked_tree

# ── 10f. CFG-668 repair: narrowness kept ──────────────────────────────────────

test_redirect_target_is_not_a_pathspec() {
    local repo; repo="$(_mkrepo_with_unstaged_secret)"
    _stage "$repo" "docs/notes.md" "ordinary staged line"
    local rc=0
    _run_guard "$repo" "git commit -m log >> docs/session-log.md" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "a redirection target is where output goes, not a path the commit records"
}
run_test "a redirection target is not mistaken for a pathspec (CFG-668 repair)" \
    test_redirect_target_is_not_a_pathspec

test_abbreviated_message_option_takes_its_value() {
    # git accepts unique prefixes of long options: --mess is --message.
    local repo; repo="$(_mkrepo_with_unstaged_secret)"
    _stage "$repo" "docs/notes.md" "ordinary staged line"
    local rc=0; _run_guard "$repo" "git commit --mess docs" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "the value of an abbreviated --message is a message, not a pathspec"
}
run_test "an abbreviated --message option consumes its value (CFG-668 repair)" \
    test_abbreviated_message_option_takes_its_value

# ── 10g. CFG-668 repair: cost and degradation ─────────────────────────────────
test_large_message_is_parsed_quickly() {
    # The guard runs on every Bash call that mentions "git " and "commit". A
    # quadratic word-splitter took ~24 s on a 100 KB heredoc; the hook timeout
    # is 60 s and Git-Bash is slower still.
    local repo; repo="$(_mkrepo_with_staged_token)"
    local body; body="$(python3 -c 'print(("prose line (x) with a \" quote\n" * 3300)[:100000])')"
    local cmd="git commit -m \"\$(cat <<'EOF'
subject
$body
EOF
)\""
    local rc=0 start end
    start=$(date +%s)
    _run_guard "$repo" "$cmd" 2>/dev/null || rc=$?
    end=$(date +%s)
    assert_eq "2" "$rc" "the staged secret must still block under a 100 KB message" || return 1
    [ $((end - start)) -le 5 ] || { echo "    took $((end - start)) s for a 100 KB message" >&2; return 1; }
}
run_test "a 100 KB heredoc message is parsed in seconds, not minutes (CFG-668 repair)" \
    test_large_message_is_parsed_quickly

# Run the guard with a python3 that exits 127, as if it were not installed. The
# payload is built first, while python3 still works.
_run_guard_without_python() {  # usage: _run_guard_without_python <repo> <command>; returns rc
    local repo="$1" cmd="$2" rc=0 payload
    local shim="$TEST_TMPDIR/no-python-bin"; mkdir -p "$shim"
    printf '#!/usr/bin/env bash\nexit 127\n' > "$shim/python3"; chmod +x "$shim/python3"
    payload=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$cmd")")
    printf '%s' "$payload" \
        | (cd "$repo" && export PATH="$shim:$PATH" && bash "$GUARD") 2>/dev/null || rc=$?
    return "$rc"
}

test_without_parser_lib_index_is_still_scanned() {
    # The parser lives in lib-commit-scan.sh. A deploy that carries the hook but
    # not the lib must degrade to the base walk, never to no scan.
    local repo; repo="$(_mkrepo_with_staged_token)"
    local lone="$TEST_TMPDIR/lone-hook"; mkdir -p "$lone"
    cp "$GUARD" "$lone/secret-commit-guard.sh"
    local rc=0
    GUARD="$lone/secret-commit-guard.sh" _run_guard "$repo" 'git commit -m "update docs" 2>&1 | tail -3' 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "a staged secret must block when lib-commit-scan.sh is missing"
}
run_test "without lib-commit-scan.sh the guard still reads the index (CFG-668 repair)" \
    test_without_parser_lib_index_is_still_scanned

test_without_python_index_is_still_scanned() {
    # Without a working python3 the guard must degrade to at least the base
    # scan (the index), never to nothing.
    local repo; repo="$(_mkrepo_with_staged_token)"
    local rc=0
    _run_guard_without_python "$repo" 'git commit -m "update docs" 2>&1 | tail -3' || rc=$?
    assert_eq "2" "$rc" "a staged secret must block even when python3 is unusable" || return 1
    local repo2; repo2="$(_mkrepo)"
    _modify "$repo2" "docs/session-log.md" "export GH=ghp_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"  # pragma: allowlist secret
    rc=0; _run_guard_without_python "$repo2" "git commit -am log" || rc=$?
    assert_eq "2" "$rc" "an -a commit must still read the tree when python3 is unusable"
}
run_test "without python3 the guard still reads the index and -a (CFG-668 repair)" \
    test_without_python_index_is_still_scanned

# ── 11. Syntax ────────────────────────────────────────────────────────────────
test_syntax_valid() {
    assert_success bash -n "$GUARD"
}
run_test "bash syntax is valid" test_syntax_valid

suite_summary
