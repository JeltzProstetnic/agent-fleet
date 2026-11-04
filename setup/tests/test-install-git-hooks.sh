#!/usr/bin/env bash
# Tests for setup/scripts/install-git-hooks.sh (CFG-892) — arms the fleet git hook
# dispatcher through the global core.hooksPath — and for the sync.sh deploy of
# global/hooks/git/, which the installer depends on.
# Run: bash setup/tests/test-install-git-hooks.sh
#
# Everything runs under the sandboxed HOME from test-helpers.sh and a GIT_CONFIG_GLOBAL
# inside the sandbox; the live ~/.gitconfig is fingerprinted by the harness and must
# come out untouched.
source "$(dirname "$0")/test-helpers.sh"

INSTALLER="$REPO_ROOT/setup/scripts/install-git-hooks.sh"
SYNC_LIB_DIR="$REPO_ROOT/sync-lib"

suite_header "install-git-hooks.sh (CFG-892: arm the pre-push scan on every machine)"

_sandbox() {
    export GIT_CONFIG_GLOBAL="$TEST_TMPDIR/gitconfig"
    : > "$GIT_CONFIG_GLOBAL"
    mkdir -p "$TEST_TMPDIR/fp"
    export CC_SECRET_FINGERPRINTS="$TEST_TMPDIR/fp/.secret-fingerprints"
    export CC_SECRET_SALT="$TEST_TMPDIR/fp/.fingerprint-salt"
    unset FLEET_PREPUSH_SCAN
}

# A minimal dispatcher dir where the installer expects it.
_fixture_dispatcher() {
    mkdir -p "$HOME/.claude/hooks/git"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.claude/hooks/git/pre-push"
    chmod +x "$HOME/.claude/hooks/git/pre-push"
}

# The real deploy_hooks() from sync-lib/deploy.sh, into the sandboxed ~/.claude.
_deploy_real() {
    (
        GLOBAL_DIR="$REPO_ROOT/global"
        CLAUDE_HOME="$HOME/.claude"
        SCRIPT_DIR="$REPO_ROOT"
        source <(sed -n '/^deploy_hooks()/,/^}/p' "$SYNC_LIB_DIR/deploy.sh" | sed 's/log_info/true/g')
        deploy_hooks
    )
}

_global_hookspath() { git config --global --get core.hooksPath 2>/dev/null || true; }

# ── 1. Unset → armed to $HOME/.claude/hooks/git ──────────────────────────────
test_arms_when_unset() {
    _sandbox; _fixture_dispatcher
    local out rc=0
    out=$(bash "$INSTALLER" 2>&1) || rc=$?
    assert_eq "0" "$rc" "installer must exit 0 (measured rc=$rc; $out)"
    assert_eq "$HOME/.claude/hooks/git" "$(_global_hookspath)" "global core.hooksPath must point at the dispatcher"
    assert_contains "$out" "armed" "arming must be reported"
}
run_test "unset global core.hooksPath is set to \$HOME/.claude/hooks/git" test_arms_when_unset

# ── 2. Idempotent ─────────────────────────────────────────────────────────────
test_idempotent() {
    _sandbox; _fixture_dispatcher
    bash "$INSTALLER" >/dev/null 2>&1 || return 1
    local out rc=0
    out=$(bash "$INSTALLER" 2>&1) || rc=$?
    assert_eq "0" "$rc" "second run must exit 0 (measured rc=$rc)"
    assert_eq "$HOME/.claude/hooks/git" "$(_global_hookspath)" "second run must leave the value"
    assert_not_contains "$out" "armed" "a no-op run must be silent"
}
run_test "idempotent — a second run changes nothing and is silent" test_idempotent

# ── 3. A foreign global value is left alone, with one warning, exit 0 ─────────
test_foreign_value_left_with_one_warning() {
    _sandbox; _fixture_dispatcher
    git config --global core.hooksPath "/somewhere/else/hooks"
    local out rc=0
    out=$(bash "$INSTALLER" 2>&1) || rc=$?
    assert_eq "0" "$rc" "a foreign value must not fail the caller (measured rc=$rc)"
    assert_eq "/somewhere/else/hooks" "$(_global_hookspath)" "a foreign value must be preserved"
    assert_contains "$out" "/somewhere/else/hooks" "the warning must name the existing value"
    assert_contains "$out" "CFG-892" "the warning must say what is NOT armed"
    local n; n=$(printf '%s\n' "$out" | grep -c "hooksPath")
    assert_eq "1" "$n" "exactly one warning line (measured $n)"
}
run_test "a different existing global value is preserved; one warning; exit 0" test_foreign_value_left_with_one_warning

# ── 4. --check reports and changes nothing ────────────────────────────────────
test_check_mode() {
    _sandbox; _fixture_dispatcher
    local out rc=0
    out=$(bash "$INSTALLER" --check 2>&1) || rc=$?
    assert_neq "0" "$rc" "--check must exit non-zero while not armed (measured rc=$rc)"
    assert_contains "$out" "not armed" "--check must say it is not armed"
    assert_eq "" "$(_global_hookspath)" "--check must not change the config"
    bash "$INSTALLER" >/dev/null 2>&1 || return 1
    rc=0; out=$(bash "$INSTALLER" --check 2>&1) || rc=$?
    assert_eq "0" "$rc" "--check must exit 0 once armed (measured rc=$rc; $out)"
    assert_contains "$out" "armed" "--check must report the armed state"
    assert_contains "$out" "FLEET_PREPUSH_SCAN" "--check documents the last-resort escape"
}
run_test "--check reports the state without changing anything" test_check_mode

# ── 5. No dispatcher deployed → do not arm, warn, exit 0 ──────────────────────
test_missing_dispatcher_does_not_arm() {
    _sandbox
    local out rc=0
    out=$(bash "$INSTALLER" 2>&1) || rc=$?
    assert_eq "0" "$rc" "a missing dispatcher must not fail the deploy (measured rc=$rc)"
    assert_eq "" "$(_global_hookspath)" "must not point core.hooksPath at a dir that does not exist"
    assert_contains "$out" "pre-push" "the warning must name what is missing"
}
run_test "with no deployed dispatcher the installer warns and does not arm" test_missing_dispatcher_does_not_arm

# ── 6. sync.sh deploy_hooks ships global/hooks/git/ (extensionless, executable) ─
test_deploy_hooks_ships_dispatcher_dir() {
    _sandbox
    mkdir -p "$HOME/.claude/hooks/git"
    echo stale > "$HOME/.claude/hooks/git/stale-hook"
    _deploy_real || return 1
    local f
    for f in pre-push pre-commit post-commit post-checkout post-merge _chain.sh; do
        assert_file_exists "$HOME/.claude/hooks/git/$f" "deploy must ship git/$f" || return 1
        [ -x "$HOME/.claude/hooks/git/$f" ] || { echo "    not executable after deploy: git/$f" >&2; return 1; }
    done
    assert_file_exists "$HOME/.claude/hooks/lib-secret-detect.sh" "deploy must ship the shared detector lib"
    assert_eq "#!/usr/bin/env bash" "$(head -1 "$HOME/.claude/hooks/git/pre-push")" "shebang must stay on line 1"
    assert_contains "$(sed -n 2p "$HOME/.claude/hooks/git/pre-push")" "MANAGED" "managed header must be injected on line 2"
    assert_file_not_exists "$HOME/.claude/hooks/git/stale-hook" "orphaned dispatcher files must be removed"
}
run_test "deploy_hooks ships global/hooks/git/* executable with the managed header and prunes orphans" \
    test_deploy_hooks_ships_dispatcher_dir

# ── 7. End to end through the DEPLOYED copy: install, then a secret push is refused
test_deployed_dispatcher_blocks_a_push() {
    _sandbox
    _deploy_real || return 1
    bash "$INSTALLER" >/dev/null 2>&1 || return 1
    assert_eq "$HOME/.claude/hooks/git" "$(_global_hookspath)" || return 1
    create_tracked_repo "$TEST_TMPDIR/repo" "$TEST_TMPDIR/remote.git" >/dev/null 2>&1
    local key; key="$(printf '%s%s' "AKIA" "IOSFODNN7EXAMPLE")"
    printf 'aws_access_key_id = %s\n' "$key" > "$TEST_TMPDIR/repo/notes.md"
    git -C "$TEST_TMPDIR/repo" add notes.md
    git -C "$TEST_TMPDIR/repo" commit -q -m notes
    local out rc=0
    out=$(git -C "$TEST_TMPDIR/repo" push origin main 2>&1) || rc=$?
    assert_neq "0" "$rc" "the deployed dispatcher must refuse a secret push (measured rc=$rc; $out)"
    assert_contains "$out" "BLOCKED (CFG-892)"
    assert_contains "$out" "notes.md"
    assert_not_contains "$out" "$key"
    # and a clean push goes through the deployed copy as well
    git -C "$TEST_TMPDIR/repo" reset -q --hard origin/main
    echo fine > "$TEST_TMPDIR/repo/ok.md"; git -C "$TEST_TMPDIR/repo" add ok.md
    git -C "$TEST_TMPDIR/repo" commit -q -m ok
    rc=0; out=$(git -C "$TEST_TMPDIR/repo" push origin main 2>&1) || rc=$?
    assert_eq "0" "$rc" "a clean push must pass through the deployed copy (measured rc=$rc; $out)"
}
run_test "deployed dispatcher + installer: a secret push is refused, a clean one passes" \
    test_deployed_dispatcher_blocks_a_push

# ── 8. Wired into sync.sh deploy, and cannot fail it ──────────────────────────
test_wired_into_cmd_deploy() {
    local body
    body=$(sed -n '/^cmd_deploy()/,/^}/p' "$SYNC_LIB_DIR/deploy.sh")
    assert_contains "$body" "install-git-hooks.sh" "cmd_deploy must run the installer"
    local line; line=$(printf '%s\n' "$body" | grep "install-git-hooks.sh")
    assert_contains "$line" "||" "the installer call must be guarded so it can never fail the deploy"
    # deploy_hooks runs before the installer, so the dir exists when hooksPath is set
    local hooks_at inst_at
    hooks_at=$(printf '%s\n' "$body" | grep -n "deploy_hooks" | head -1 | cut -d: -f1)
    inst_at=$(printf '%s\n' "$body" | grep -n "install-git-hooks.sh" | head -1 | cut -d: -f1)
    [ "$hooks_at" -lt "$inst_at" ] || { echo "    installer must run after deploy_hooks (hooks line $hooks_at, installer line $inst_at)" >&2; return 1; }
}
run_test "cmd_deploy runs the installer after deploy_hooks, guarded" test_wired_into_cmd_deploy

# ── 9. Syntax ─────────────────────────────────────────────────────────────────
# ── Sweep: a local core.hooksPath shadows the global dispatcher ───────────────
# Measured 2026-11-04 on the reference workstation: three repos carried a local
# core.hooksPath=<repo>/.git/hooks (empty of real hooks) and five carried .githooks — so
# the scan would not have run in any of them. Once the dispatcher is armed, a local value the dispatcher already chains
# (.githooks, .git/hooks, either as absolute path) is removed; anything else is reported.
_mkrepo_hp() {  # _mkrepo_hp <dir> [local hooksPath value; 'SELF' = <dir>/.git/hooks]
    mkdir -p "$1"; git -C "$1" init -q
    case "${2:-}" in
        "") ;;
        SELF) git -C "$1" config core.hooksPath "$1/.git/hooks" ;;
        *) git -C "$1" config core.hooksPath "$2" ;;
    esac
}
_local_hp() { git -C "$1" config --local --get core.hooksPath 2>/dev/null || echo "<unset>"; }

test_sweep_unsets_shadowing_locals() {
    _sandbox; _fixture_dispatcher
    _mkrepo_hp "$HOME/r1" .githooks
    _mkrepo_hp "$HOME/r2" SELF
    _mkrepo_hp "$HOME/r3" "/opt/custom-hooks"
    _mkrepo_hp "$HOME/group/r4" .githooks
    _mkrepo_hp "$HOME/r5"
    local out; out=$(bash "$INSTALLER" 2>&1)
    echo "    measured: r1=[$(_local_hp "$HOME/r1")] r2=[$(_local_hp "$HOME/r2")] r3=[$(_local_hp "$HOME/r3")] r4=[$(_local_hp "$HOME/group/r4")] r5=[$(_local_hp "$HOME/r5")]"
    assert_eq "<unset>" "$(_local_hp "$HOME/r1")" ".githooks is chained by the dispatcher — removed" || return 1
    assert_eq "<unset>" "$(_local_hp "$HOME/r2")" "<repo>/.git/hooks is chained by the dispatcher — removed" || return 1
    assert_eq "<unset>" "$(_local_hp "$HOME/group/r4")" "repos one level down (project groups) are swept too" || return 1
    assert_eq "/opt/custom-hooks" "$(_local_hp "$HOME/r3")" "a custom local value is NOT ours to remove" || return 1
    assert_contains "$out" "r3" "the custom value is reported, naming the repo" || return 1
    assert_eq "<unset>" "$(_local_hp "$HOME/r5")" "a repo without a local value is untouched"
}
run_test "sweep: local hooksPath values the dispatcher chains are removed; custom ones reported" test_sweep_unsets_shadowing_locals

test_sweep_needs_our_global() {
    _sandbox; _fixture_dispatcher
    git config --global core.hooksPath "/somewhere/else"
    _mkrepo_hp "$HOME/r1" .githooks
    bash "$INSTALLER" >/dev/null 2>&1
    assert_eq ".githooks" "$(_local_hp "$HOME/r1")" "without OUR global dispatcher a local .githooks is the only guard — keep it"
}
run_test "sweep: does nothing when the global hooksPath is not the dispatcher" test_sweep_needs_our_global

test_sweep_idempotent_silent() {
    _sandbox; _fixture_dispatcher
    _mkrepo_hp "$HOME/r1" .githooks
    bash "$INSTALLER" >/dev/null 2>&1
    local out; out=$(bash "$INSTALLER" 2>&1)
    assert_eq "" "$out" "a second run has nothing to do and says nothing"
}
run_test "sweep: a second run is silent" test_sweep_idempotent_silent

test_syntax_valid() { bash -n "$INSTALLER"; }
run_test "bash syntax is valid" test_syntax_valid

suite_summary
