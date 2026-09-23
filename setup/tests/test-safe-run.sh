#!/usr/bin/env bash
# Tests for global/hooks/safe-run.sh — the hook lockout backstop.
#
# Every hook in settings.json routes through safe-run.sh, so a defect here is
# fleet-wide and silent. Until this suite existed the wrapper had NO runtime
# test at all (the anti-lockout and pre-deploy suites only build stub copies).
#
# The bug that motivated the suite: the stderr capture file was hard-coded to
# /tmp. Claude Code's Bash sandbox mounts /tmp READ-ONLY and points $TMPDIR at a
# writable scratchpad, so mktemp failed, `2>"$_sr_tmp"` became an ambiguous
# redirect, the hook never ran, and EVERY hook reported "HOOK FAILED (exit 1)"
# on a healthy machine. The read-only /tmp is reproduced for real with bwrap
# (rootless mount namespace); when bwrap is absent a mktemp shim that refuses
# /tmp templates stands in, and the test prints which method it used.
source "$(dirname "$0")/test-helpers.sh"

# Test-only knobs (never read by the product):
#   SAFE_RUN_UNDER_TEST=<file>   run the suite against another copy of the wrapper
#                                (e.g. `git show HEAD:global/hooks/safe-run.sh > x`)
#                                to replay the before/after proof.
#   SAFE_RUN_TEST_NO_BWRAP=1     force the mktemp-shim path even when bwrap exists,
#                                so the fallback used on bwrap-less machines is
#                                exercised here too.
SAFE_RUN="${SAFE_RUN_UNDER_TEST:-$REPO_ROOT/global/hooks/safe-run.sh}"

suite_header "safe-run.sh (hook safety wrapper)"

# ── Helpers ─────────────────────────────────────────────────────────────────

# safe-run.sh resolves hooks at $HOME/.claude/hooks/<name>; HOME is sandboxed
# by setup_test, so install a copy of the REAL wrapper plus fixture hooks there.
install_hooks() {
    local hooks="$HOME/.claude/hooks"
    mkdir -p "$hooks"
    cp "$SAFE_RUN" "$hooks/safe-run.sh"
    printf '#!/usr/bin/env bash\necho "hook-ran-ok"\n' > "$hooks/ok.sh"
    printf '#!/usr/bin/env bash\necho "partial-stdout"\necho "BLOCKED: nope" >&2\nexit 2\n' > "$hooks/block.sh"
    printf '#!/usr/bin/env bash\necho "before-crash"\necho "boom-stderr" >&2\nexit 1\n' > "$hooks/crash.sh"
    printf '#!/usr/bin/env bash\nif [[ ; then\n' > "$hooks/broken.sh"
    echo "$hooks"
}

# Run `bash safe-run.sh <args>` with /tmp read-only. Prefers a real read-only
# bind mount (bwrap); falls back to a mktemp shim that refuses /tmp templates.
# Sets RO_TMP_METHOD for the caller to print. Env passed by the caller (TMPDIR,
# HOME) is inherited by both methods.
RO_TMP_METHOD=""
have_bwrap() { [[ "${SAFE_RUN_TEST_NO_BWRAP:-0}" != "1" ]] && command -v bwrap >/dev/null 2>&1; }
run_with_ro_tmp() {
    local scratch="$1"; shift
    if have_bwrap; then
        RO_TMP_METHOD="bwrap --ro-bind /tmp"
        # --tmpfs after the ro-bind re-exposes the scratch dir writable even when
        # it lives under /tmp (the harness's TEST_TMPDIR usually does).
        bwrap --dev-bind / / --ro-bind /tmp /tmp --tmpfs "$scratch" -- \
            bash "$HOME/.claude/hooks/safe-run.sh" "$@"
        return $?
    fi
    RO_TMP_METHOD="mktemp shim"
    local shim="$TEST_TMPDIR/shimbin" real_mktemp
    real_mktemp="$(command -v mktemp)"
    mkdir -p "$shim"
    # Refuse /tmp but keep the scratch dir writable — it usually lives under
    # /tmp too (the harness's TEST_TMPDIR), exactly like bwrap's --tmpfs overlay.
    cat > "$shim/mktemp" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
    case "\$a" in
        "$scratch"/*) ;;
        /tmp/*) echo "mktemp: failed to create file via template '\$a': Read-only file system" >&2; exit 1 ;;
    esac
done
exec "$real_mktemp" "\$@"
EOF
    chmod +x "$shim/mktemp"
    PATH="$shim:$PATH" bash "$HOME/.claude/hooks/safe-run.sh" "$@"
}

# Precondition probe: inside the same read-only-/tmp arrangement, mktemp on
# /tmp MUST fail, otherwise the bug tests below would pass vacuously.
probe_ro_tmp() {
    local scratch="$1" out
    if have_bwrap; then
        out=$(bwrap --dev-bind / / --ro-bind /tmp /tmp --tmpfs "$scratch" -- \
            bash -c 'mktemp /tmp/sr-probe.XXXXXX >/dev/null 2>&1; echo "tmp_mktemp_rc=$?"' 2>&1)
    else
        out=$(PATH="$TEST_TMPDIR/shimbin:$PATH" bash -c 'mktemp /tmp/sr-probe.XXXXXX >/dev/null 2>&1; echo "tmp_mktemp_rc=$?"' 2>&1)
    fi
    echo "$out"
}

# ── Regression guards (behaviour that must survive the fix) ─────────────────

test_healthy_hook_passes_stdout() {
    install_hooks >/dev/null
    local rc=0 output
    output=$(bash "$HOME/.claude/hooks/safe-run.sh" ok.sh 2>&1) || rc=$?
    echo "    measured: rc=$rc output=[$output]"
    assert_eq "0" "$rc" "healthy hook must exit 0" || return 1
    assert_eq "hook-ran-ok" "$output" "healthy hook stdout must pass through unchanged"
}
run_test "healthy hook: stdout passes through, exit 0" test_healthy_hook_passes_stdout

test_block_passes_exit2_and_stderr() {
    install_hooks >/dev/null
    local rc=0 out err
    err="$TEST_TMPDIR/err.txt"
    out=$(bash "$HOME/.claude/hooks/safe-run.sh" block.sh 2>"$err") || rc=$?
    echo "    measured: rc=$rc stdout=[$out] stderr=[$(cat "$err")]"
    assert_eq "2" "$rc" "deliberate block (exit 2 + stderr) must pass through as exit 2" || return 1
    assert_contains "$(cat "$err")" "BLOCKED: nope" "block reason must reach stderr" || return 1
    assert_contains "$out" "partial-stdout" "stdout emitted before the block must be preserved"
}
run_test "PreToolUse block: exit 2 and stderr pass through" test_block_passes_exit2_and_stderr

test_crash_degrades_to_exit0() {
    install_hooks >/dev/null
    local rc=0 output
    output=$(bash "$HOME/.claude/hooks/safe-run.sh" crash.sh 2>&1) || rc=$?
    echo "    measured: rc=$rc output=[$output]"
    assert_eq "0" "$rc" "crashing hook must degrade to exit 0 (never lock the user out)" || return 1
    assert_contains "$output" "HOOK FAILED: crash.sh (exit 1)" "crash must be reported with the hook name and exit code" || return 1
    assert_contains "$output" "before-crash" "stdout before the crash must be preserved" || return 1
    assert_contains "$output" "boom-stderr" "stderr of the crash must be surfaced"
}
run_test "crashing hook: reported as HOOK FAILED, exit 0" test_crash_degrades_to_exit0

test_missing_hook_is_skipped() {
    install_hooks >/dev/null
    local rc=0 output
    output=$(bash "$HOME/.claude/hooks/safe-run.sh" does-not-exist.sh 2>&1) || rc=$?
    echo "    measured: rc=$rc output=[$output]"
    assert_eq "0" "$rc" || return 1
    assert_contains "$output" "HOOK MISSING: does-not-exist.sh"
}
run_test "missing hook: HOOK MISSING, exit 0" test_missing_hook_is_skipped

test_syntax_error_hook_is_skipped() {
    install_hooks >/dev/null
    local rc=0 output
    output=$(bash "$HOME/.claude/hooks/safe-run.sh" broken.sh 2>&1) || rc=$?
    echo "    measured: rc=$rc output=[$output]"
    assert_eq "0" "$rc" || return 1
    assert_contains "$output" "HOOK SYNTAX ERROR: broken.sh"
}
run_test "syntax-error hook: HOOK SYNTAX ERROR, exit 0" test_syntax_error_hook_is_skipped

test_wrapper_passes_bash_n() {
    local rc=0
    bash -n "$SAFE_RUN" 2>/dev/null || rc=$?
    echo "    measured: bash -n rc=$rc"
    assert_eq "0" "$rc" "safe-run.sh must be syntactically valid (a syntax error here locks every hook out)"
}
run_test "safe-run.sh itself passes bash -n" test_wrapper_passes_bash_n

# ── TMPDIR handling ─────────────────────────────────────────────────────────

test_tmpdir_empty_string_falls_back_to_tmp() {
    # CC < 2.1.278 exports TMPDIR="" (set-but-EMPTY) for commands outside the
    # sandbox while sandboxing is enabled. ${TMPDIR:-/tmp} (colon form) treats
    # empty like unset and yields /tmp; the colon-less ${TMPDIR-/tmp} would
    # expand to "" and mktemp would try "/safe-run-stderr.XXXXXX".
    install_hooks >/dev/null
    local expansion rc=0 output
    expansion=$(TMPDIR="" bash -c 'printf "%s" "${TMPDIR:-/tmp}"')
    output=$(TMPDIR="" bash "$HOME/.claude/hooks/safe-run.sh" ok.sh 2>&1) || rc=$?
    echo "    measured: \${TMPDIR:-/tmp} with TMPDIR=\"\" expands to [$expansion]; rc=$rc output=[$output]"
    assert_eq "/tmp" "$expansion" "empty TMPDIR must fall back to /tmp in the expansion" || return 1
    assert_eq "0" "$rc" || return 1
    assert_eq "hook-ran-ok" "$output" "hook must run normally with TMPDIR set-but-empty"
}
run_test "TMPDIR set-but-empty: falls back to /tmp, hook runs" test_tmpdir_empty_string_falls_back_to_tmp

test_tmpdir_unwritable_falls_back_to_tmp() {
    install_hooks >/dev/null
    local rc=0 output
    output=$(TMPDIR="$TEST_TMPDIR/does/not/exist" bash "$HOME/.claude/hooks/safe-run.sh" ok.sh 2>&1) || rc=$?
    echo "    measured: rc=$rc output=[$output]"
    assert_eq "0" "$rc" || return 1
    assert_eq "hook-ran-ok" "$output" "unwritable TMPDIR must fall back to /tmp, not fail the hook"
}
run_test "TMPDIR unwritable: falls back to /tmp, hook runs" test_tmpdir_unwritable_falls_back_to_tmp

test_no_temp_file_leaks() {
    install_hooks >/dev/null
    local scratch="$TEST_TMPDIR/scratch" leftovers
    mkdir -p "$scratch"
    TMPDIR="$scratch" bash "$HOME/.claude/hooks/safe-run.sh" ok.sh >/dev/null 2>&1 || true
    TMPDIR="$scratch" bash "$HOME/.claude/hooks/safe-run.sh" crash.sh >/dev/null 2>&1 || true
    TMPDIR="$scratch" bash "$HOME/.claude/hooks/safe-run.sh" block.sh >/dev/null 2>&1 || true
    leftovers=$(find "$scratch" -name 'safe-run-stderr.*' | wc -l)
    echo "    measured: leftover capture files in TMPDIR after ok/crash/block = $leftovers"
    assert_eq "0" "$leftovers" "stderr capture files must be removed on every exit path"
}
run_test "no stderr capture file is leaked in TMPDIR (ok, crash, block paths)" test_no_temp_file_leaks

# ── The reported bug: /tmp read-only, $TMPDIR writable ──────────────────────

test_readonly_tmp_with_writable_tmpdir() {
    install_hooks >/dev/null
    local scratch="$TEST_TMPDIR/scratch" probe rc=0 output
    mkdir -p "$scratch"
    # Build the shim eagerly so probe_ro_tmp can use it when bwrap is absent.
    run_with_ro_tmp "$scratch" ok.sh >/dev/null 2>&1 || true
    probe=$(probe_ro_tmp "$scratch")
    echo "    precondition ($RO_TMP_METHOD): $probe"
    assert_contains "$probe" "tmp_mktemp_rc=1" "precondition: mktemp on /tmp must FAIL inside the arrangement, else the test is vacuous" || return 1

    output=$(TMPDIR="$scratch" run_with_ro_tmp "$scratch" ok.sh 2>&1) || rc=$?
    echo "    measured ($RO_TMP_METHOD): rc=$rc output=[$output]"
    assert_not_contains "$output" "HOOK FAILED" "a healthy hook must not report HOOK FAILED just because /tmp is read-only" || return 1
    assert_eq "0" "$rc" || return 1
    assert_eq "hook-ran-ok" "$output" "hook must run and its stdout pass through with /tmp read-only and TMPDIR writable"
}
run_test "BUG: /tmp read-only + writable TMPDIR: healthy hook still runs" test_readonly_tmp_with_writable_tmpdir

test_readonly_tmp_block_still_blocks() {
    install_hooks >/dev/null
    local scratch="$TEST_TMPDIR/scratch" rc=0 out err
    mkdir -p "$scratch"
    err="$scratch/err.txt"
    out=$(TMPDIR="$scratch" run_with_ro_tmp "$scratch" block.sh 2>"$err") || rc=$?
    echo "    measured ($RO_TMP_METHOD): rc=$rc stdout=[$out] stderr=[$(cat "$err" 2>/dev/null)]"
    assert_eq "2" "$rc" "PreToolUse block must still pass through as exit 2 with /tmp read-only" || return 1
    assert_contains "$(cat "$err" 2>/dev/null)" "BLOCKED: nope" "block reason must still reach stderr"
}
run_test "BUG: /tmp read-only + writable TMPDIR: PreToolUse block still blocks" test_readonly_tmp_block_still_blocks

test_no_writable_temp_anywhere_is_explicit() {
    # Double failure: /tmp read-only AND TMPDIR empty (so the fallback is /tmp
    # again). Nothing can be captured. Today this is "HOOK FAILED (exit 1)" —
    # a lie about the hook. It must say what actually happened instead.
    install_hooks >/dev/null
    local scratch="$TEST_TMPDIR/scratch" rc=0 output
    mkdir -p "$scratch"
    output=$(TMPDIR="" run_with_ro_tmp "$scratch" ok.sh 2>&1) || rc=$?
    echo "    measured ($RO_TMP_METHOD): rc=$rc output=[$output]"
    assert_eq "0" "$rc" "must never exit non-zero (lockout)" || return 1
    assert_not_contains "$output" "HOOK FAILED" "must not blame the hook for a missing temp dir" || return 1
    assert_contains "$output" "HOOK SKIPPED: ok.sh" "must name the hook and say it was skipped" || return 1
    assert_contains "$output" "no writable temp dir" "must name the real cause"
}
run_test "BUG: no writable temp dir at all: explicit HOOK SKIPPED, not HOOK FAILED" test_no_writable_temp_anywhere_is_explicit

suite_summary
