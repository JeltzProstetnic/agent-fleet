#!/usr/bin/env bash
# TDD tests for setup/scripts/ensure-githooks.sh (CFG-535)
# Run: bash setup/tests/test-ensure-githooks.sh
#
# The defect this closes: ~/agent-fleet is a PUBLIC repo, and the SessionEnd hook
# commits and pushes to it with no leak check of its own. The only thing standing
# between a session's private notes and publication is the repo's .githooks/pre-push
# guard — and NOTHING installs it. `grep -c hooksPath sync.sh` was 0. It was set on
# this one workstation, in an untracked .git/config, by hand and by accident; a fresh
# clone on any other machine gets .githooks/ as files but not the setting that arms
# them, and there the push succeeds. Measured 2026-08-21: two auto-sync commits
# carrying the hostname and /home/<user> paths were sitting one config line away
# from a public repo. Publication is irreversible.
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/ensure-githooks.sh"

suite_header "ensure-githooks.sh (CFG-535: arm the pre-push guard everywhere)"

_mkrepo() {
    local d="$1" with_hooks="${2:-yes}"
    mkdir -p "$d"
    git -C "$d" init -q -b main
    if [[ "$with_hooks" == "yes" ]]; then
        mkdir -p "$d/.githooks"
        printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.githooks/pre-push"
        chmod +x "$d/.githooks/pre-push"
    fi
}

# ── A repo that ships .githooks but has the setting unset gets it armed ──────
test_arms_unset_repo() {
    local d="$TEST_TMPDIR/unset"; _mkrepo "$d"
    git -C "$d" config --unset core.hooksPath 2>/dev/null || true

    bash "$SCRIPT" "$d" >/dev/null 2>&1 || return 1
    local got; got=$(git -C "$d" config --get core.hooksPath)
    assert_eq ".githooks" "$got" "an unset repo shipping .githooks must be armed"
}
run_test "unset repo with .githooks gets core.hooksPath=.githooks" test_arms_unset_repo

# ── Idempotent: running twice changes nothing and still succeeds ─────────────
test_idempotent() {
    local d="$TEST_TMPDIR/idem"; _mkrepo "$d"
    bash "$SCRIPT" "$d" >/dev/null 2>&1 || return 1
    bash "$SCRIPT" "$d" >/dev/null 2>&1 || return 1
    local got; got=$(git -C "$d" config --get core.hooksPath)
    assert_eq ".githooks" "$got" "second run must leave it armed"
}
run_test "idempotent — safe to call on every session end" test_idempotent

# ── A repo with NO .githooks is left completely alone ────────────────────────
# Not every repo has a guard; arming a nonexistent hooks dir would silently
# disable any real .git/hooks the user has.
test_leaves_hookless_repo_alone() {
    local d="$TEST_TMPDIR/nohooks"; _mkrepo "$d" no
    bash "$SCRIPT" "$d" >/dev/null 2>&1 || return 1
    local got; got=$(git -C "$d" config --get core.hooksPath || true)
    assert_eq "" "$got" "a repo without .githooks must not be touched"
}
run_test "repo without .githooks is left untouched" test_leaves_hookless_repo_alone

# ── A deliberate non-default hooksPath is NOT silently overwritten ───────────
test_respects_custom_hookspath() {
    local d="$TEST_TMPDIR/custom"; _mkrepo "$d"
    mkdir -p "$d/myhooks"
    git -C "$d" config core.hooksPath myhooks

    bash "$SCRIPT" "$d" >/dev/null 2>&1 || return 1
    local got; got=$(git -C "$d" config --get core.hooksPath)
    assert_eq "myhooks" "$got" "a deliberate custom hooksPath must be preserved"
}
run_test "custom hooksPath is preserved, not clobbered" test_respects_custom_hookspath

# ── It REPORTS when it arms something, so a silent fix is not invisible ──────
test_reports_when_it_changes_something() {
    local d="$TEST_TMPDIR/report"; _mkrepo "$d"
    git -C "$d" config --unset core.hooksPath 2>/dev/null || true
    local out; out=$(bash "$SCRIPT" "$d" 2>&1)
    assert_contains "$out" "$d" "output must name the repo it armed" || return 1
    # and stays quiet when there was nothing to do
    local out2; out2=$(bash "$SCRIPT" "$d" 2>&1)
    assert_not_contains "$out2" "$d" "a no-op run must not be noisy"
}
run_test "arming is reported; a no-op is silent" test_reports_when_it_changes_something

# ── The guard it arms actually fires (behavioural, not config-only) ──────────
# Pattern 6 in the fleet's known-faulty-patterns: a test that reads config and
# never exercises it proves nothing. This one makes the hook block a real push.
test_armed_guard_actually_blocks() {
    local d="$TEST_TMPDIR/behave"; _mkrepo "$d"
    local remote="$TEST_TMPDIR/behave-remote"
    git -C "$d" config --unset core.hooksPath 2>/dev/null || true
    printf '#!/usr/bin/env bash\necho "GUARD FIRED" >&2\nexit 1\n' > "$d/.githooks/pre-push"
    chmod +x "$d/.githooks/pre-push"
    git init -q --bare "$remote"
    git -C "$d" remote add origin "$remote"
    echo hi > "$d/f.txt"; git -C "$d" add -A
    git -C "$d" -c user.name=t -c user.email=t@t commit -q -m init

    bash "$SCRIPT" "$d" >/dev/null 2>&1 || return 1
    local out rc=0
    out=$(git -C "$d" push origin main 2>&1) || rc=$?
    assert_neq "0" "$rc" "the armed guard must block the push" || return 1
    assert_contains "$out" "GUARD FIRED" "the guard's own message must reach the caller"
}
run_test "armed guard actually blocks a real push" test_armed_guard_actually_blocks

# ══ CFG-892: interplay with the fleet git hook dispatcher ═════════════════════
# A repo-local core.hooksPath=.githooks OVERRIDES the global dispatcher, so the
# pre-push credential scan would never run in exactly the repos that ship a
# .githooks/ guard — agent-fleet, which is PUBLIC, among them. Once the global
# dispatcher is armed it chains .githooks/* itself, so the local value must go
# and must not come back. Without the dispatcher, today's behaviour stays.

_dispatcher_armed_sandbox() {
    export GIT_CONFIG_GLOBAL="$TEST_TMPDIR/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
    mkdir -p "$HOME/.claude/hooks"
    cp -r "$REPO_ROOT/global/hooks/git" "$HOME/.claude/hooks/git"
    cp "$REPO_ROOT/global/hooks/lib-secret-detect.sh" "$HOME/.claude/hooks/"
    git config --global core.hooksPath "$HOME/.claude/hooks/git"
    export CC_SECRET_FINGERPRINTS="$TEST_TMPDIR/none" CC_SECRET_SALT="$TEST_TMPDIR/none"
    unset FLEET_PREPUSH_SCAN
}

_local_hookspath() { git -C "$1" config --local --get core.hooksPath 2>/dev/null || true; }

test_dispatcher_armed_does_not_set_local() {
    _dispatcher_armed_sandbox
    local d="$TEST_TMPDIR/nolocal"; _mkrepo "$d"
    local out; out=$(bash "$SCRIPT" "$d" 2>&1) || return 1
    assert_eq "" "$(_local_hookspath "$d")" "with the dispatcher armed no local hooksPath may be set"
    assert_not_contains "$out" "armed .githooks" "nothing to report"
}
run_test "CFG-892: dispatcher armed → a repo with .githooks gets NO local hooksPath" test_dispatcher_armed_does_not_set_local

test_dispatcher_armed_unsets_local_githooks() {
    _dispatcher_armed_sandbox
    local d="$TEST_TMPDIR/release"; _mkrepo "$d"
    git -C "$d" config core.hooksPath .githooks
    local out; out=$(bash "$SCRIPT" "$d" 2>&1) || return 1
    assert_eq "" "$(_local_hookspath "$d")" "a local .githooks value must be unset so the dispatcher runs"
    assert_contains "$out" "$d" "the release must be reported, naming the repo"
    assert_contains "$out" "CFG-892" "the report must say why"
    # idempotent and silent afterwards
    out=$(bash "$SCRIPT" "$d" 2>&1) || return 1
    assert_not_contains "$out" "$d" "second run must be silent"
}
run_test "CFG-892: dispatcher armed → a local .githooks value is unset and reported" test_dispatcher_armed_unsets_local_githooks

test_dispatcher_armed_keeps_custom_local() {
    _dispatcher_armed_sandbox
    local d="$TEST_TMPDIR/custom2"; _mkrepo "$d"
    mkdir -p "$d/myhooks"
    git -C "$d" config core.hooksPath myhooks
    local out; out=$(bash "$SCRIPT" "$d" 2>&1) || return 1
    assert_eq "myhooks" "$(_local_hookspath "$d")" "a deliberate custom local value is still preserved"
    assert_contains "$out" "myhooks" "and the warning says it shadows the dispatcher"
}
run_test "CFG-892: dispatcher armed → a custom local value is preserved, with a warning" test_dispatcher_armed_keeps_custom_local

test_dispatcher_half_installed_keeps_todays_behaviour() {
    # Global hooksPath set, but no executable pre-push there: not a dispatcher. Today's
    # rule applies unchanged — a non-default merged value is "custom", left as is.
    export GIT_CONFIG_GLOBAL="$TEST_TMPDIR/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
    mkdir -p "$HOME/.claude/hooks/git"
    git config --global core.hooksPath "$HOME/.claude/hooks/git"
    local d="$TEST_TMPDIR/half"; _mkrepo "$d"
    local out; out=$(bash "$SCRIPT" "$d" 2>&1) || return 1
    assert_eq "" "$(_local_hookspath "$d")" "today's behaviour: a custom merged value is not overridden"
    assert_contains "$out" "left as is" "today's warning"
}
run_test "CFG-892: a global hooksPath without an executable pre-push is not a dispatcher — today's behaviour" \
    test_dispatcher_half_installed_keeps_todays_behaviour

test_released_repo_guard_still_fires_through_dispatcher() {
    _dispatcher_armed_sandbox
    local d="$TEST_TMPDIR/chain"; _mkrepo "$d"
    local remote="$TEST_TMPDIR/chain-remote"
    git -C "$d" config core.hooksPath .githooks
    printf '#!/usr/bin/env bash\necho "GUARD FIRED" >&2\nexit 1\n' > "$d/.githooks/pre-push"
    chmod +x "$d/.githooks/pre-push"
    git init -q --bare "$remote"
    git -C "$d" remote add origin "$remote"
    echo hi > "$d/f.txt"; git -C "$d" add -A
    git -C "$d" -c user.name=t -c user.email=t@t commit -q -m init
    bash "$SCRIPT" "$d" >/dev/null 2>&1 || return 1
    assert_eq "" "$(_local_hookspath "$d")" "local value released" || return 1
    local out rc=0
    out=$(git -C "$d" push origin main 2>&1) || rc=$?
    assert_neq "0" "$rc" "the repo's own guard must still block through the dispatcher chain" || return 1
    assert_contains "$out" "GUARD FIRED" "the guard's own message must reach the caller"
}
run_test "CFG-892: after release the repo's .githooks/pre-push still blocks (dispatcher chains it)" \
    test_released_repo_guard_still_fires_through_dispatcher

suite_summary

