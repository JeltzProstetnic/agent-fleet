#!/usr/bin/env bash
# Native Windows installer prerequisites — CFG-1087 slice 3 (setup/preflight.sh, setup/install.sh).
#
# Decision 2026-11-20 (docs/decisions.md "Native Windows targets the public line"): admin rights and
# the PowerShell rights the fleet needs are PREREQUISITES — the installer checks and states them,
# nothing works around them; no non-admin path, no group-policy handling. So the check runs first,
# on native Windows only, never elevates or changes a policy, prints exactly what is missing plus
# the one command the user applies, and stops with its own exit code (3) — also under
# --skip-preflight, which bypasses the advisory checks only.
#
# Everything Windows-side is STUBBED here (powershell.exe, net, OSTYPE); the stubs record every
# argv so the test can prove nothing was changed. The real check on the metal lives in
# test-windows-gitbash.sh (Git for Windows bash on this host).
source "$(dirname "$0")/test-helpers.sh"

suite_header "Native Windows prerequisites (admin + execution policy) — preflight.sh / install.sh"

PREFLIGHT="$REPO_ROOT/setup/preflight.sh"
PREREQ_RC=3   # the distinct exit code: a prerequisite is missing (1 stays "a preflight check failed")

# ── stubs ────────────────────────────────────────────────────────────────────────────────────
# PF_STUB_NET_RC     — what `net session` exits (0 elevated, 2 "System error 5 … Access is denied")
# PF_STUB_ELEVATED   — what IsInRole(Administrator) prints (True/False)
# PF_STUB_POLICY     — the five scope lines, "Scope=Value", newline-separated
# PF_STUB_EFFECTIVE  — what Get-ExecutionPolicy (effective) prints
# PF_STUB_LOG        — every powershell.exe / net argv is appended here (CRLF output, as Windows writes it)
_make_stubs() {   # <dir> [no-powershell]
    local d="$1"; mkdir -p "$d"
    cat > "$d/net" <<'EOF'
#!/usr/bin/env bash
echo "net $*" >> "${PF_STUB_LOG:-/dev/null}"
[ "$1" = session ] || { echo "stub: unexpected net verb $1" >&2; exit 9; }
if [ "${PF_STUB_NET_RC:-2}" = 0 ]; then printf 'There are no entries in the list.\r\n'; exit 0; fi
printf 'System error 5 has occurred.\r\n\r\nAccess is denied.\r\n' >&2; exit "${PF_STUB_NET_RC:-2}"
EOF
    chmod +x "$d/net"
    [ "${2:-}" = no-powershell ] && return 0
    cat > "$d/powershell.exe" <<'EOF'
#!/usr/bin/env bash
echo "powershell.exe $*" >> "${PF_STUB_LOG:-/dev/null}"
case "$*" in
    *IsInRole*)            printf '%s\r\n' "${PF_STUB_ELEVATED:-False}" ;;
    *Get-ExecutionPolicy*) printf '%s\r\n' ${PF_STUB_POLICY:-} "Effective=${PF_STUB_EFFECTIVE:-Restricted}" ;;
    *) echo "stub: unexpected powershell command: $*" >&2; exit 9 ;;
esac
EOF
    chmod +x "$d/powershell.exe"
}

# _policy <MachinePolicy> <UserPolicy> <Process> <CurrentUser> <LocalMachine> <Effective>
_policy() {
    PF_STUB_POLICY=$(printf 'MachinePolicy=%s\nUserPolicy=%s\nProcess=%s\nCurrentUser=%s\nLocalMachine=%s' "$1" "$2" "$3" "$4" "$5")
    PF_STUB_EFFECTIVE="$6"
    export PF_STUB_POLICY PF_STUB_EFFECTIVE
}
_all_undefined() { _policy Undefined Undefined Undefined Undefined Undefined Restricted; }
_cu() { _policy Undefined Undefined Undefined "$1" Undefined "$1"; }   # CurrentUser = effective

# _prereq <ostype> [preflight args…] — run preflight.sh with the stubs first on PATH. Output in
# OUT, exit code in OUT_RC (set as globals, so call it as a statement, not inside `$(…)`). PATH
# keeps only system dirs so WSL's real powershell.exe (on PATH via interop) can never answer
# instead of the stub.
OUT="" OUT_RC=0
_prereq() {
    local ostype="$1"; shift
    OUT_RC=0
    OUT=$(OSTYPE="$ostype" PATH="$TEST_TMPDIR/stubs:/usr/bin:/bin" PF_STUB_LOG="$TEST_TMPDIR/stub.log" \
        bash "$PREFLIGHT" --no-color "$@" 2>&1) || OUT_RC=$?
}
_elevated()     { export PF_STUB_NET_RC=0 PF_STUB_ELEVATED=True; }
_not_elevated() { export PF_STUB_NET_RC=2 PF_STUB_ELEVATED=False; }
_stub_calls()   { if [[ -f "$TEST_TMPDIR/stub.log" ]]; then wc -l < "$TEST_TMPDIR/stub.log" | tr -d ' '; else echo 0; fi; }

# ── 1. no-op off native Windows ─────────────────────────────────────────────────────────────
test_linux_noop() {
    _make_stubs "$TEST_TMPDIR/stubs"; _not_elevated; _all_undefined
    _prereq linux-gnu --prerequisites-only
    assert_eq "0" "$OUT_RC" "Linux: --prerequisites-only exits 0 (got $OUT_RC)"
    assert_eq "" "$OUT" "Linux: and prints nothing"
    assert_eq "0" "$(_stub_calls)" "Linux: neither powershell.exe nor net was called"
    _prereq linux-gnu --skip-network
    assert_not_contains "$OUT" "Native Windows prerequisites" "Linux: the full preflight has no Windows section"
    assert_contains "$OUT" "--- Commands ---" "Linux: the full preflight still runs its own checks"
}
run_test "off native Windows the check is a no-op: exit 0, silent, no probe" test_linux_noop

# ── 2. both prerequisites present ───────────────────────────────────────────────────────────
test_both_present() {
    _make_stubs "$TEST_TMPDIR/stubs"; _elevated; _cu RemoteSigned
    _prereq cygwin --prerequisites-only
    echo "$OUT" | sed 's/^/    | /'
    assert_eq "0" "$OUT_RC" "elevated + RemoteSigned: exit 0 (got $OUT_RC)"
    assert_contains "$OUT" "[PASS] Administrator rights" ""
    assert_contains "$OUT" "[PASS] PowerShell execution policy" ""
    assert_contains "$OUT" "RemoteSigned" "the effective policy is named"
    assert_contains "$OUT" "PREREQ: elevated=yes policy=RemoteSigned result=ok" "machine-readable summary line"
    _prereq msys --prerequisites-only
    assert_eq "0" "$OUT_RC" "the msys OSTYPE spelling is native Windows too (got $OUT_RC)"
}
run_test "elevated shell + RemoteSigned: both PASS, exit 0" test_both_present

test_policy_values_pass() {
    _make_stubs "$TEST_TMPDIR/stubs"; _elevated
    local p
    for p in RemoteSigned Unrestricted Bypass; do
        _cu "$p"; _prereq cygwin --prerequisites-only
        assert_eq "0" "$OUT_RC" "effective $p lets the fleet's scripts run: exit 0 (got $OUT_RC)"
        assert_contains "$OUT" "policy=$p result=ok" ""
    done
    # effective RemoteSigned from LocalMachine while CurrentUser is Undefined is fine too
    _policy Undefined Undefined Undefined Undefined RemoteSigned RemoteSigned
    _prereq cygwin --prerequisites-only
    assert_eq "0" "$OUT_RC" "LocalMachine RemoteSigned, CurrentUser Undefined: effective RemoteSigned passes (got $OUT_RC)"
}
run_test "each permissive effective policy (RemoteSigned, Unrestricted, Bypass) passes" test_policy_values_pass

# ── 3. not elevated ─────────────────────────────────────────────────────────────────────────
test_not_elevated() {
    _make_stubs "$TEST_TMPDIR/stubs"; _not_elevated; _cu RemoteSigned
    _prereq cygwin --prerequisites-only
    echo "$OUT" | sed 's/^/    | /'
    assert_eq "$PREREQ_RC" "$OUT_RC" "not elevated: exit $PREREQ_RC, the prerequisite code (got $OUT_RC)"
    assert_contains "$OUT" "[FAIL] Administrator rights" "states what is missing"
    assert_contains "$OUT" "Run as administrator" "and the one thing to do: start Git Bash as administrator"
    assert_contains "$OUT" "[PASS] PowerShell execution policy" "the policy is still reported"
    assert_contains "$OUT" "PREREQ: elevated=no policy=RemoteSigned result=missing" ""
}
run_test "not elevated: FAIL names admin rights + 'Run as administrator', exit 3" test_not_elevated

test_net_down_isinrole_decides() {
    _make_stubs "$TEST_TMPDIR/stubs"; export PF_STUB_NET_RC=2 PF_STUB_ELEVATED=True; _cu RemoteSigned
    _prereq cygwin --prerequisites-only
    assert_eq "0" "$OUT_RC" "net session cannot answer but IsInRole says True: counts as elevated (got $OUT_RC)"
    assert_contains "$OUT" "elevated=yes" ""
}
run_test "elevation: when 'net session' cannot answer, IsInRole(Administrator) decides" test_net_down_isinrole_decides

# ── 4. execution policy missing ─────────────────────────────────────────────────────────────
test_policy_restricted() {
    _make_stubs "$TEST_TMPDIR/stubs"; _elevated; _cu Restricted
    _prereq cygwin --prerequisites-only
    echo "$OUT" | sed 's/^/    | /'
    assert_eq "$PREREQ_RC" "$OUT_RC" "Restricted: exit $PREREQ_RC (got $OUT_RC)"
    assert_contains "$OUT" "[FAIL] PowerShell execution policy" ""
    assert_contains "$OUT" "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned" "the one command the user runs"
    assert_contains "$OUT" "[PASS] Administrator rights" ""
    assert_contains "$OUT" "PREREQ: elevated=yes policy=Restricted result=missing" ""
}
run_test "effective Restricted: FAIL names the policy + the Set-ExecutionPolicy command, exit 3" test_policy_restricted

test_policy_values_fail() {
    _make_stubs "$TEST_TMPDIR/stubs"; _elevated
    local p
    for p in AllSigned Restricted; do
        _cu "$p"; _prereq cygwin --prerequisites-only
        assert_eq "$PREREQ_RC" "$OUT_RC" "effective $p refuses unsigned fleet scripts: exit $PREREQ_RC (got $OUT_RC)"
    done
    _all_undefined; _prereq cygwin --prerequisites-only
    assert_eq "$PREREQ_RC" "$OUT_RC" "every scope Undefined (effective Restricted, the Windows client default): exit $PREREQ_RC (got $OUT_RC)"
    assert_contains "$OUT" "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned" ""
}
run_test "AllSigned, Restricted and all-Undefined are each a missing prerequisite" test_policy_values_fail

test_policy_per_scope_stated() {
    _make_stubs "$TEST_TMPDIR/stubs"; _elevated
    _policy Undefined Undefined Undefined Undefined Undefined Restricted
    _prereq cygwin --prerequisites-only
    local s
    for s in MachinePolicy UserPolicy Process CurrentUser LocalMachine; do
        assert_contains "$OUT" "$s = Undefined" "scope $s is stated with its value"
    done
    assert_contains "$OUT" "effective Restricted" "and the effective policy"
    assert_not_contains "$OUT" $'\r' "CRs from the Windows output are stripped"
}
run_test "the policy is stated per scope plus the effective value" test_policy_per_scope_stated

test_group_policy_is_stated_not_handled() {
    _make_stubs "$TEST_TMPDIR/stubs"; _elevated
    _policy Restricted Undefined Undefined RemoteSigned Undefined Restricted
    _prereq cygwin --prerequisites-only
    echo "$OUT" | sed 's/^/    | /'
    assert_eq "$PREREQ_RC" "$OUT_RC" "MachinePolicy Restricted: exit $PREREQ_RC (got $OUT_RC)"
    assert_contains "$OUT" "Group Policy" "says the policy comes from Group Policy"
    assert_contains "$OUT" "MachinePolicy" "and which scope"
    assert_not_contains "$OUT" "Set-ExecutionPolicy" "no Set-ExecutionPolicy suggestion — it cannot override a group policy, and the installer does not handle group policies"
    _policy Undefined AllSigned Undefined Undefined Undefined AllSigned
    _prereq cygwin --prerequisites-only
    assert_eq "$PREREQ_RC" "$OUT_RC" "UserPolicy AllSigned: exit $PREREQ_RC (got $OUT_RC)"
    assert_contains "$OUT" "UserPolicy" ""
}
run_test "a restrictive policy set by Group Policy is stated as such and not worked around" test_group_policy_is_stated_not_handled

# ── 5. both missing — the state of this host (every scope Undefined, effective Restricted) ──
test_both_missing() {
    _make_stubs "$TEST_TMPDIR/stubs"; _not_elevated; _all_undefined
    _prereq cygwin          # the FULL preflight, not --prerequisites-only
    echo "$OUT" | sed 's/^/    | /'
    assert_eq "$PREREQ_RC" "$OUT_RC" "both missing: exit $PREREQ_RC (got $OUT_RC)"
    assert_eq "2" "$(echo "$OUT" | grep -c '^  \[FAIL\]')" "exactly two FAIL lines, one per prerequisite"
    assert_contains "$OUT" "Run as administrator" ""
    assert_contains "$OUT" "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned" ""
    assert_not_contains "$OUT" "--- Commands ---" "stops right there: no other preflight section runs"
    assert_not_contains "$OUT" "--- Summary ---" ""
}
run_test "both missing: both stated, the full preflight stops before any other check" test_both_missing

test_powershell_missing() {
    _make_stubs "$TEST_TMPDIR/stubs" no-powershell; _elevated
    _prereq cygwin --prerequisites-only
    assert_eq "$PREREQ_RC" "$OUT_RC" "no powershell.exe: exit $PREREQ_RC (got $OUT_RC)"
    assert_contains "$OUT" "[FAIL] PowerShell execution policy" ""
    assert_contains "$OUT" "powershell.exe" "says PowerShell itself did not answer"
}
run_test "powershell.exe absent: the policy prerequisite fails and says so" test_powershell_missing

# ── 6. read-only: the check changes nothing ─────────────────────────────────────────────────
test_read_only() {
    _make_stubs "$TEST_TMPDIR/stubs"; _not_elevated; _all_undefined
    _prereq cygwin --prerequisites-only
    _elevated; _cu Restricted; _prereq cygwin --prerequisites-only
    local log; log=$(cat "$TEST_TMPDIR/stub.log")
    echo "$log" | sed 's/^/    | /'
    assert_not_contains "$log" "Set-ExecutionPolicy" "never sets a policy"
    assert_not_contains "$log" "RunAs" "never elevates"
    assert_not_contains "$log" "Start-Process" ""
    assert_contains "$log" "net session" "the elevation probe is 'net session'"
    assert_contains "$log" "Get-ExecutionPolicy" "the policy probe is Get-ExecutionPolicy"
    assert_contains "$log" "-NoProfile" "PowerShell is called without a profile (nothing of the user's runs)"
}
run_test "read-only: no Set-ExecutionPolicy, no elevation attempt, -NoProfile" test_read_only

# ── 7. install.sh wiring: never skipped, distinct exit, no bypass hint ───────────────────────
_stage_installer() {   # a minimal repo: install.sh sources lib.sh, lib.sh sources lib-portable
    local r="$TEST_TMPDIR/repo"
    mkdir -p "$r/setup" "$r/global/hooks"
    cp "$REPO_ROOT/setup/install.sh" "$REPO_ROOT/setup/lib.sh" "$REPO_ROOT/setup/preflight.sh" "$r/setup/"
    cp "$REPO_ROOT/global/hooks/lib-portable.sh" "$r/global/hooks/"
}
_install() {   # <ostype> <args…> — HOME is the sandbox (run_test); stubs first on PATH; OUT / OUT_RC
    local ostype="$1"; shift
    OUT_RC=0
    OUT=$(OSTYPE="$ostype" PATH="$TEST_TMPDIR/stubs:/usr/bin:/bin" PF_STUB_LOG="$TEST_TMPDIR/stub.log" \
        bash "$TEST_TMPDIR/repo/setup/install.sh" --no-color "$@" </dev/null 2>&1) || OUT_RC=$?
}
test_install_skip_preflight_still_checks() {
    _make_stubs "$TEST_TMPDIR/stubs"; _not_elevated; _all_undefined; _stage_installer
    _install cygwin --skip-preflight --dry-run
    echo "$OUT" | sed 's/^/    | /'
    assert_eq "$PREREQ_RC" "$OUT_RC" "install.sh --skip-preflight on Windows without the prerequisites: exit $PREREQ_RC (got $OUT_RC)"
    assert_contains "$OUT" "[FAIL] Administrator rights" "the prerequisite check ran although --skip-preflight was given"
    assert_contains "$OUT" "prerequisite" "install.sh says a prerequisite is missing"
    assert_not_contains "$OUT" "--skip-preflight to bypass" "and does not offer a bypass"
    assert_not_contains "$OUT" "Claude Code Setup - Preview" "nothing of the installation ran"
}
run_test "install.sh --skip-preflight does not skip the prerequisites (exit 3, no bypass hint)" test_install_skip_preflight_still_checks

test_install_full_preflight_prereq_exit() {
    _make_stubs "$TEST_TMPDIR/stubs"; _elevated; _cu Restricted; _stage_installer
    _install cygwin --dry-run
    assert_eq "$PREREQ_RC" "$OUT_RC" "install.sh: a missing prerequisite exits $PREREQ_RC, not the generic 1 (got $OUT_RC)"
    assert_contains "$OUT" "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned" ""
    assert_not_contains "$OUT" "Preflight checks failed" "a prerequisite is not 'a failed check' with a bypass"
    assert_not_contains "$OUT" "--skip-preflight to bypass" ""
}
run_test "install.sh: the prerequisite exit code passes through untouched, without the bypass hint" test_install_full_preflight_prereq_exit

test_install_linux_unchanged() {
    _make_stubs "$TEST_TMPDIR/stubs"; _not_elevated; _all_undefined; _stage_installer
    _install linux-gnu --skip-preflight --dry-run
    echo "$OUT" | head -5 | sed 's/^/    | /'
    assert_not_contains "$OUT" "prerequisite" "Linux: no prerequisite talk"
    assert_not_contains "$OUT" "Native Windows" ""
    assert_eq "0" "$(_stub_calls)" "Linux: no Windows probe ran"
    assert_contains "$OUT" "Claude Code Setup - Preview" "Linux: install.sh went on into the preview (exit $OUT_RC)"
    [[ "$OUT_RC" -ne "$PREREQ_RC" ]] || { echo "    install.sh exited $PREREQ_RC on Linux"; return 1; }
}
run_test "install.sh on Linux with --skip-preflight: no prerequisite check, no probe, preview runs" test_install_linux_unchanged

suite_summary
