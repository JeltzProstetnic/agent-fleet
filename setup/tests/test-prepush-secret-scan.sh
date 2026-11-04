#!/usr/bin/env bash
# Tests for global/hooks/git/pre-push — the fleet pre-push credential scan (CFG-892)
# and its pass-through dispatcher dir, plus global/hooks/lib-secret-detect.sh.
# Run: bash setup/tests/test-prepush-secret-scan.sh
#
# Why this exists (owner decision 2026-10-30: a credential must never reach a remote,
# above all not a public one): secret-commit-guard.sh is bound to the
# Claude Bash tool, so a credential committed by a script, by the SessionEnd
# auto-sync or by MG's own shell reaches the remote unscanned. The pre-push hook
# runs the SAME two detectors over every commit about to leave the machine.
#
# Isolation (CFG-667): the live session exports CC_SECRET_FINGERPRINTS/CC_SECRET_SALT
# for the real fleet files. Every push here runs under fixture paths, a sandboxed
# GIT_CONFIG_GLOBAL and the sandboxed HOME from test-helpers.sh, never the live ones.
# Every secret-shaped fixture is built at run time by concatenation, so this file
# itself carries no shape for either guard to trip on.
source "$(dirname "$0")/test-helpers.sh"

DISPATCHER="$REPO_ROOT/global/hooks/git"
PREPUSH="$DISPATCHER/pre-push"
LIB="$REPO_ROOT/global/hooks/lib-secret-detect.sh"

suite_header "pre-push secret scan (CFG-892)"

# ── Fixtures ──────────────────────────────────────────────────────────────────

# Sandboxed global git config pointing at a dispatcher dir (default: the repo's),
# fixture fingerprint paths, no escape hatch in the environment.
_arm() {  # _arm [hooks-dir]
    export GIT_CONFIG_GLOBAL="$TEST_TMPDIR/gitconfig"
    : > "$GIT_CONFIG_GLOBAL"
    git config --global core.hooksPath "${1:-$DISPATCHER}"
    mkdir -p "$TEST_TMPDIR/fp"
    export CC_SECRET_FINGERPRINTS="$TEST_TMPDIR/fp/.secret-fingerprints"
    export CC_SECRET_SALT="$TEST_TMPDIR/fp/.fingerprint-salt"
    unset FLEET_PREPUSH_SCAN
}

# Fingerprints the way vault-manage.sh writes them: salted sha256, one per line.
_mkfp() {  # _mkfp <secret-value>...
    local salt="testsalt0123456789"
    printf '%s' "$salt" > "$CC_SECRET_SALT"
    : > "$CC_SECRET_FINGERPRINTS"
    local v
    for v in "$@"; do
        python3 -c 'import hashlib,sys;print(hashlib.sha256((sys.argv[1]+sys.argv[2]).encode()).hexdigest())' \
            "$salt" "$v" >> "$CC_SECRET_FINGERPRINTS"
    done
}

# A working repo tracking a bare remote on main.
_mkpair() {  # echoes the repo path; the remote is $TEST_TMPDIR/remote.git
    create_tracked_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git" >/dev/null 2>&1
    echo "$TEST_TMPDIR/repo"
}

_commit() {  # _commit <repo> <relpath> <content> [msg]
    mkdir -p "$(dirname "$1/$2")"
    printf '%s\n' "$3" >> "$1/$2"
    git -C "$1" add "$2" >/dev/null 2>&1
    git -C "$1" commit -q -m "${4:-edit $2}" >/dev/null 2>&1
}

# Secret-shaped fixtures, assembled at run time.
_aws() { printf '%s%s' "AKIA" "IOSFODNN7EXAMPLE"; }
_ghp() { printf 'ghp_%s' "$(printf 'A%.0s' $(seq 36))"; }

OUT=""
_push() {  # _push <repo> <git push args…>; sets OUT, returns git's rc
    local repo="$1"; shift
    local rc=0
    OUT=$(git -C "$repo" push "$@" 2>&1) || rc=$?
    return "$rc"
}

_remote_sha() { git -C "$TEST_TMPDIR/remote.git" rev-parse -q --verify "${1:-main}" 2>/dev/null || true; }

# ── 1. A provider-shaped key in a pushed commit refuses the push ───────────────
test_aws_key_push_refused() {
    _arm
    local repo; repo="$(_mkpair)"
    local before; before="$(_remote_sha)"
    _commit "$repo" "docs/notes.md" "aws_access_key_id = $(_aws)"
    local rc=0; _push "$repo" origin main || rc=$?
    assert_neq "0" "$rc" "a push carrying an AWS key id must be refused (measured rc=$rc)"
    assert_contains "$OUT" "BLOCKED (CFG-892)" "the refusal must name CFG-892"
    assert_contains "$OUT" "docs/notes.md" "the refusal must name the file"
    assert_not_contains "$OUT" "$(_aws)" "the matched value must never be printed"
    assert_eq "$before" "$(_remote_sha)" "the remote must not have moved"
}
run_test "an AWS-shaped key in a pushed commit is refused, file named, value hidden" test_aws_key_push_refused

# ── 2. A value-fingerprint hit (prose, no shape) refuses the push ──────────────
test_value_fingerprint_refused() {
    _arm
    _mkfp "correct-horse-battery-staple"
    local repo; repo="$(_mkpair)"
    _commit "$repo" "docs/handover.md" "Console login is jeltz, the passphrase is correct-horse-battery-staple."
    local rc=0; _push "$repo" origin main || rc=$?
    assert_neq "0" "$rc" "a prose secret matching a fingerprint must be refused (measured rc=$rc)"
    assert_contains "$OUT" "value match" "the refusal must say which detector matched"
    assert_contains "$OUT" "docs/handover.md"
    assert_not_contains "$OUT" "correct-horse-battery-staple"
}
run_test "a value-fingerprint hit in prose is refused" test_value_fingerprint_refused

# ── 2b. Outside Claude Code (no CC_SECRET_* env, no repo-local secrets/): the value
#        detector falls back to the fleet config repo's secrets/ (CONFIG_REPO), so MG's
#        own terminal pushes in any repo still value-match the fleet's secrets.
test_value_fingerprint_config_repo_fallback() {
    _arm
    _mkfp "correct-horse-battery-staple"
    local cfg="$TEST_TMPDIR/cfgrepo"; mkdir -p "$cfg/secrets"
    cp "$CC_SECRET_FINGERPRINTS" "$cfg/secrets/.secret-fingerprints"
    cp "$CC_SECRET_SALT" "$cfg/secrets/.fingerprint-salt"
    unset CC_SECRET_FINGERPRINTS CC_SECRET_SALT
    export CONFIG_REPO="$cfg"
    local repo; repo="$(_mkpair)"
    _commit "$repo" "notes/login.md" "The passphrase is correct-horse-battery-staple."
    local rc=0; _push "$repo" origin main || rc=$?
    echo "    measured: rc=$rc value-match=[$(printf '%s' "$OUT" | grep -c 'value match')]"
    unset CONFIG_REPO
    assert_neq "0" "$rc" "without CC env the fleet config repo's fingerprints must still apply" || return 1
    assert_contains "$OUT" "value match" "the value detector must be the one that matched" || return 1
    assert_not_contains "$OUT" "correct-horse-battery-staple"
}
run_test "value detector falls back to \$CONFIG_REPO/secrets outside Claude Code" test_value_fingerprint_config_repo_fallback


# ── 3. Clean pushes succeed; already-pushed history is never rescanned ─────────
test_clean_push_and_range() {
    export GIT_CONFIG_GLOBAL="$TEST_TMPDIR/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
    local repo; repo="$(_mkpair)"
    # A secret lands on the remote BEFORE the dispatcher is armed (history we cannot change).
    _commit "$repo" "old/leak.md" "token = $(_ghp)" "old leak"
    git -C "$repo" push -q origin main >/dev/null 2>&1 || return 1
    _arm
    _commit "$repo" "docs/clean.md" "nothing to see"
    local rc=0; _push "$repo" origin main || rc=$?
    assert_eq "0" "$rc" "a clean commit on top of leaked-but-pushed history must push (measured rc=$rc; $OUT)"
    assert_not_contains "$OUT" "BLOCKED" "only remote..local is scanned"
    assert_eq "$(git -C "$repo" rev-parse main)" "$(_remote_sha)" "the remote must carry the new commit"
    # A second clean push of only new commits also passes.
    _commit "$repo" "docs/clean2.md" "still nothing"
    rc=0; _push "$repo" origin main || rc=$?
    assert_eq "0" "$rc" "second clean push (measured rc=$rc)"
}
run_test "clean push succeeds; an old already-pushed secret is not rescanned" test_clean_push_and_range

# ── 4. A new branch scans only commits not on any remote ref ──────────────────
test_new_branch_scans_only_unpushed() {
    export GIT_CONFIG_GLOBAL="$TEST_TMPDIR/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
    local repo; repo="$(_mkpair)"
    _commit "$repo" "old/leak.md" "token = $(_ghp)" "old leak"
    git -C "$repo" push -q origin main >/dev/null 2>&1 || return 1
    _arm
    git -C "$repo" checkout -q -b feat
    _commit "$repo" "feat.md" "clean feature"
    local rc=0; _push "$repo" origin feat || rc=$?
    assert_eq "0" "$rc" "a new branch whose only new commit is clean must push (measured rc=$rc; $OUT)"
    git -C "$repo" checkout -q -b feat2 main
    _commit "$repo" "feat2.md" "aws_secret_access_key = $(_aws)"
    rc=0; _push "$repo" origin feat2 || rc=$?
    assert_neq "0" "$rc" "a new branch carrying a fresh secret must be refused (measured rc=$rc)"
    assert_contains "$OUT" "feat2.md"
    assert_eq "" "$(_remote_sha feat2)" "feat2 must not reach the remote"
}
run_test "a new branch push scans only commits not on any remote ref" test_new_branch_scans_only_unpushed

# ── 5. The allowlist marker ────────────────────────────────────────────────────
test_allowlist_marker_passes() {
    _arm
    local repo; repo="$(_mkpair)"
    _commit "$repo" "docs/scanner.md" "example id $(_aws)  # pragma: allowlist secret"
    local rc=0; _push "$repo" origin main || rc=$?
    assert_eq "0" "$rc" "a line carrying the allowlist marker must pass (measured rc=$rc; $OUT)"
}
run_test "a 'pragma: allowlist secret' line is allowed" test_allowlist_marker_passes

# ── 6. filtered-push style: <sha>:refs/heads/main ─────────────────────────────
test_sha_refspec_push_is_scanned() {
    _arm
    local repo; repo="$(_mkpair)"
    _commit "$repo" "docs/clean.md" "fine"
    local rc=0; _push "$repo" origin "$(git -C "$repo" rev-parse HEAD):refs/heads/main" || rc=$?
    assert_eq "0" "$rc" "a clean <sha>:refs/heads/main push must succeed (measured rc=$rc; $OUT)"
    _commit "$repo" "docs/leak.md" "slack xoxb-$(printf '1%.0s' $(seq 12))-leak"
    rc=0; _push "$repo" origin "$(git -C "$repo" rev-parse HEAD):refs/heads/main" || rc=$?
    assert_neq "0" "$rc" "a <sha>:refs/heads/main push carrying a secret must be refused (measured rc=$rc)"
    assert_contains "$OUT" "docs/leak.md"
}
run_test "a <sha>:refs/heads/main push (filtered-push.sh) is scanned" test_sha_refspec_push_is_scanned

# ── 7. Chaining: the repo's tracked .githooks/pre-push still runs ─────────────
test_githooks_prepush_is_chained() {
    _arm
    local repo; repo="$(_mkpair)"
    mkdir -p "$repo/.githooks"
    printf '#!/usr/bin/env bash\necho "GUARD FIRED" >&2\nexit 1\n' > "$repo/.githooks/pre-push"
    chmod +x "$repo/.githooks/pre-push"
    git -C "$repo" config --unset core.hooksPath 2>/dev/null || true
    _commit "$repo" "docs/clean.md" "fine"
    local rc=0; _push "$repo" origin main || rc=$?
    assert_neq "0" "$rc" "a failing .githooks/pre-push must fail the push through the dispatcher (measured rc=$rc)"
    assert_contains "$OUT" "GUARD FIRED" "the chained hook's own output must reach the caller"
}
run_test "a repo .githooks/pre-push that exits 1 fails the push" test_githooks_prepush_is_chained

# ── 8. Chaining: $GIT_DIR/hooks/pre-push (git-lfs style) gets args + stdin ────
test_gitdir_prepush_receives_same_stdin() {
    _arm
    local repo; repo="$(_mkpair)"
    local rec="$TEST_TMPDIR/rec"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s.args"\ncat > "%s.stdin"\n' "$rec" "$rec" \
        > "$repo/.git/hooks/pre-push"
    chmod +x "$repo/.git/hooks/pre-push"
    local old; old="$(_remote_sha)"
    _commit "$repo" "docs/clean.md" "fine"
    local new; new="$(git -C "$repo" rev-parse main)"
    local rc=0; _push "$repo" origin main || rc=$?
    assert_eq "0" "$rc" "push with an LFS-style .git/hooks/pre-push must succeed (measured rc=$rc; $OUT)"
    assert_file_exists "$rec.stdin" "the .git/hooks pre-push must have run"
    assert_eq "refs/heads/main $new refs/heads/main $old" "$(cat "$rec.stdin")" \
        "the chained hook must receive git's stdin line verbatim"
    assert_eq "origin $TEST_TMPDIR/remote.git" "$(cat "$rec.args")" "the chained hook must receive the same args"
    # and its failure is the push's failure
    printf '#!/usr/bin/env bash\necho "LFS SAYS NO" >&2\nexit 3\n' > "$repo/.git/hooks/pre-push"
    _commit "$repo" "docs/clean2.md" "fine"
    rc=0; _push "$repo" origin main || rc=$?
    assert_neq "0" "$rc" "a failing .git/hooks/pre-push must fail the push (measured rc=$rc)"
    assert_contains "$OUT" "LFS SAYS NO"
}
run_test "a .git/hooks/pre-push (git-lfs style) receives the same stdin and args; its failure propagates" \
    test_gitdir_prepush_receives_same_stdin

# ── 9. Pass-through stubs keep repo-level hooks alive ─────────────────────────
test_passthrough_stubs_chain() {
    _arm
    local repo; repo="$(_mkpair)"
    printf '#!/usr/bin/env bash\necho ran > "%s/post-commit.marker"\n' "$TEST_TMPDIR" > "$repo/.git/hooks/post-commit"
    chmod +x "$repo/.git/hooks/post-commit"
    _commit "$repo" "a.md" "x"
    assert_file_exists "$TEST_TMPDIR/post-commit.marker" ".git/hooks/post-commit must still run under the global dispatcher"
    # a tracked .githooks/pre-commit (the project template's commit-size guard shape) still blocks
    mkdir -p "$repo/.githooks"
    printf '#!/usr/bin/env bash\necho "PRE-COMMIT FIRED" >&2\nexit 1\n' > "$repo/.githooks/pre-commit"
    chmod +x "$repo/.githooks/pre-commit"
    echo y > "$repo/b.md"; git -C "$repo" add b.md
    local out rc=0
    out=$(git -C "$repo" commit -q -m b 2>&1) || rc=$?
    assert_neq "0" "$rc" "a failing .githooks/pre-commit must block the commit via the stub (measured rc=$rc)"
    assert_contains "$out" "PRE-COMMIT FIRED"
}
run_test "pass-through stubs chain .git/hooks and .githooks hooks of the same name" test_passthrough_stubs_chain

# ── 10. The escape hatch is loud, and still chains ────────────────────────────
test_escape_hatch_is_loud() {
    _arm
    local repo; repo="$(_mkpair)"
    mkdir -p "$repo/.githooks"
    printf '#!/usr/bin/env bash\necho chained > "%s/chain.marker"\nexit 0\n' "$TEST_TMPDIR" > "$repo/.githooks/pre-push"
    chmod +x "$repo/.githooks/pre-push"
    _commit "$repo" "docs/leak.md" "token = $(_ghp)"
    local rc=0
    OUT=$(FLEET_PREPUSH_SCAN=0 git -C "$repo" push origin main 2>&1) || rc=$?
    assert_eq "0" "$rc" "FLEET_PREPUSH_SCAN=0 must let the push through (measured rc=$rc; $OUT)"
    assert_contains "$OUT" "CFG-892" "the skip must be announced, naming CFG-892"
    assert_contains "$OUT" "SKIPPED" "the skip must say the scan was skipped"
    assert_file_exists "$TEST_TMPDIR/chain.marker" "the escape hatch must still chain the repo's hooks"
}
run_test "FLEET_PREPUSH_SCAN=0 lets a secret through but warns loudly and still chains" test_escape_hatch_is_loud

# ── 11. Fail closed: a dispatcher without its detector lib refuses every push ──
test_missing_lib_fails_closed() {
    mkdir -p "$TEST_TMPDIR/lonely"
    cp -r "$DISPATCHER" "$TEST_TMPDIR/lonely/git"
    _arm "$TEST_TMPDIR/lonely/git"
    local repo; repo="$(_mkpair 2>/dev/null)"
    _commit "$repo" "docs/clean.md" "fine"
    local rc=0; _push "$repo" origin main || rc=$?
    assert_neq "0" "$rc" "a dispatcher that cannot find lib-secret-detect.sh must refuse (measured rc=$rc)"
    assert_contains "$OUT" "lib-secret-detect.sh" "the refusal must name the missing lib"
}
run_test "a missing lib-secret-detect.sh refuses the push (fail closed)" test_missing_lib_fails_closed

# ── 12. Without python3 the shape detector still runs; degrade is announced ───
test_without_python_shape_still_blocks() {
    _arm
    local shim="$TEST_TMPDIR/no-python-bin"; mkdir -p "$shim"
    printf '#!/usr/bin/env bash\nexit 127\n' > "$shim/python3"; chmod +x "$shim/python3"
    local repo; repo="$(_mkpair)"
    _commit "$repo" "docs/leak.md" "aws_access_key_id = $(_aws)"
    local rc=0
    OUT=$(PATH="$shim:$PATH" git -C "$repo" push origin main 2>&1) || rc=$?
    assert_neq "0" "$rc" "the grep-only shape detector must block without python3 (measured rc=$rc)"
    assert_contains "$OUT" "BLOCKED (CFG-892)"
    # With fingerprints configured but python3 unusable, a clean push passes and SAYS the
    # value detector is off — never silently.
    git -C "$repo" reset -q --hard origin/main
    _mkfp "correct-horse-battery-staple"
    _commit "$repo" "docs/clean.md" "fine"
    rc=0
    OUT=$(PATH="$shim:$PATH" git -C "$repo" push origin main 2>&1) || rc=$?
    assert_eq "0" "$rc" "a clean push must pass without python3 (measured rc=$rc; $OUT)"
    assert_contains "$OUT" "python3" "the degraded value detector must be announced"
}
run_test "without python3 the shape detector still blocks; the degrade is announced" test_without_python_shape_still_blocks

# ── 13. Deleting a remote branch is not scanned and not refused ───────────────
test_delete_push_passes() {
    _arm
    local repo; repo="$(_mkpair)"
    git -C "$repo" checkout -q -b feat; _commit "$repo" "f.md" "x"
    _push "$repo" origin feat || return 1
    local rc=0; _push "$repo" origin :feat || rc=$?
    assert_eq "0" "$rc" "a delete push has nothing to scan (measured rc=$rc; $OUT)"
}
run_test "a branch delete push is allowed" test_delete_push_passes

# ── 14. Pushing from a linked worktree: scan runs, common-dir hooks chain ──────
test_worktree_push() {
    _arm
    local repo; repo="$(_mkpair)"
    local rec="$TEST_TMPDIR/wt-rec"
    printf '#!/usr/bin/env bash\ncat > "%s"\n' "$rec" > "$repo/.git/hooks/pre-push"
    chmod +x "$repo/.git/hooks/pre-push"
    git -C "$repo" worktree add -q -b wt "$TEST_TMPDIR/wt" main >/dev/null 2>&1 || return 1
    _commit "$TEST_TMPDIR/wt" "wt.md" "token = $(_ghp)"
    local rc=0; _push "$TEST_TMPDIR/wt" origin wt || rc=$?
    assert_neq "0" "$rc" "a secret pushed from a worktree must be refused (measured rc=$rc)"
    git -C "$TEST_TMPDIR/wt" reset -q --hard main
    _commit "$TEST_TMPDIR/wt" "wt.md" "clean"
    rc=0; _push "$TEST_TMPDIR/wt" origin wt || rc=$?
    assert_eq "0" "$rc" "a clean worktree push must pass (measured rc=$rc; $OUT)"
    assert_file_exists "$rec" "the main repo's .git/hooks/pre-push must chain from a worktree"
}
run_test "a push from a linked worktree is scanned and chains the common-dir hook" test_worktree_push

# ── 15. A typical push stays fast ─────────────────────────────────────────────
test_typical_push_is_fast() {
    _arm
    _mkfp "correct-horse-battery-staple"
    local repo; repo="$(_mkpair)"
    _commit "$repo" "docs/clean.md" "one ordinary commit"
    local t0 t1 ms
    t0=$(date +%s%N)
    _push "$repo" origin main || return 1
    t1=$(date +%s%N)
    ms=$(( (t1 - t0) / 1000000 ))
    echo "    measured: one-commit push incl. scan = ${ms} ms"
    [ "$ms" -lt 2000 ] || { echo "    push took ${ms} ms (limit 2000)" >&2; return 1; }
}
run_test "a one-commit push with the scan completes well under a second" test_typical_push_is_fast

# ── 16. The shared detector's contract ────────────────────────────────────────
test_lib_contract() {
    _arm
    _mkfp "correct-horse-battery-staple"
    local got
    got=$(printf 'id %s\n' "$(_aws)" | bash -c "source '$LIB'; secret_detect /nonexistent")
    assert_eq "shape" "$got" "a provider-shaped token alone reports 'shape'"
    got=$(printf 'the passphrase is correct-horse-battery-staple\n' | bash -c "source '$LIB'; secret_detect /nonexistent")
    assert_eq "value" "$got" "a fingerprinted value alone reports 'value'"
    got=$(printf 'id %s\nphrase correct-horse-battery-staple\n' "$(_aws)" | bash -c "source '$LIB'; secret_detect /nonexistent")
    assert_eq "shape+value" "$got" "both detectors report 'shape+value'"
    got=$(printf 'id %s  # pragma: allowlist secret\n' "$(_aws)" | bash -c "source '$LIB'; secret_detect /nonexistent")
    assert_eq "" "$got" "an allowlisted line reports nothing"
    got=$(printf 'nothing here\n' | bash -c "source '$LIB'; secret_detect /nonexistent")
    assert_eq "" "$got" "clean input reports nothing"
}
run_test "lib-secret-detect.sh: secret_detect prints shape / value / shape+value / nothing" test_lib_contract

# ── 17. Syntax of every shipped file ──────────────────────────────────────────
test_syntax_valid() {
    local f
    bash -n "$LIB" || return 1
    for f in "$DISPATCHER"/*; do
        bash -n "$f" || { echo "    syntax error: $f" >&2; return 1; }
        [ -x "$f" ] || { echo "    not executable in the repo: $f" >&2; return 1; }
    done
}
run_test "bash syntax is valid and every dispatcher file is executable" test_syntax_valid

# ── 18. The refactored commit guard's own suite is green ──────────────────────
test_commit_guard_suite_still_passes() {
    local out total passed
    out=$(bash "$REPO_ROOT/setup/tests/test-secret-commit-guard.sh" 2>&1)
    total=$(printf '%s\n' "$out" | sed -n 's/^ *Total: *\([0-9]*\).*/\1/p' | tail -1)
    passed=$(printf '%s\n' "$out" | sed -n 's/^ *Passed: *\([0-9]*\).*/\1/p' | tail -1)
    echo "    measured: secret-commit-guard suite total=${total:-?} passed=${passed:-?}"
    [ -n "$total" ] && [ "$total" -gt 0 ] || return 1
    assert_eq "$total" "$passed" "every secret-commit-guard test must still pass after the lib extraction"
}
run_test "secret-commit-guard.sh suite passes unchanged against the shared lib" test_commit_guard_suite_still_passes

suite_summary
