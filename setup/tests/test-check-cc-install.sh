#!/usr/bin/env bash
# Tests for a SessionStart check that runs cc-install-invariants.sh against the
# last-known-good snapshot — UNGATED by the daily npm-view marker and without network.
#
# TDD: written 2026-09-23, RED until the main session adds the module
# (suggested: global/hooks/checks/24-cc-install.sh; the name is not load-bearing, the
# tests only look at the hook's additionalContext). Spec:
#
#   - Runs every SessionStart. It is local and takes milliseconds, so it is NOT gated by
#     sched-lib's daily cc-dep-check marker. That marker exists to protect the 5-second
#     `npm view`; on 2026-09-23 it had been spent at 10:56, four hours before the update
#     that reset CC to 2.1.1, so no session that day could have been told.
#   - Compares the install against $CC_INSTALL_SNAPSHOT (default
#     ${XDG_CACHE_HOME:-$HOME/.cache}/cfg-agent-fleet/cc-install.snapshot). On DOWNGRADE or
#     UNREQUESTED it appends to WARNINGS with the measured values, so the session sees
#     `WARNING: … DOWNGRADE … 2.1.274 … 2.1.1 …` before doing anything else.
#   - With no snapshot it writes a baseline and stays quiet.
#   - Needs neither npm nor cc-mirror; a dead network changes nothing.
#
# Harness: the real config-check.sh with all modules, patched via test-check-helpers.sh
# (same approach as test-check-autofix.sh's 4.6 tests). The mock `npm view` answers the
# INSTALLED version, so check 4.6 stays silent and any DOWNGRADE text must come from the
# new module.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"
source "$SCRIPT_DIR/test-check-helpers.sh"
source "$SCRIPT_DIR/lib-cc-install-fixture.sh"

suite_header "SessionStart check: CC install vs last-known-good snapshot"

# Builds config repo + mock home + install fixture; sets globals for run_check.
# Usage: fx <installed_version> <team_mode> <npm_view_answer|"">
fx() {
    local version="$1" team="$2" view="$3"
    CONFIG_REPO_DIR="$TEST_TMPDIR/config-repo"
    MOCK_HOME="$TEST_TMPDIR/home"
    PROJECT_DIR="$TEST_TMPDIR/project"
    MIRROR="$MOCK_HOME/.cc-mirror/mclaude"
    LAUNCHER="$MOCK_HOME/.local/bin/mclaude"
    SNAP="$TEST_TMPDIR/cache/cfg-agent-fleet/cc-install.snapshot"
    TMPL="$CONFIG_REPO_DIR/setup/config/settings.json"
    MOCKBIN="$TEST_TMPDIR/mockbin"
    NPM_MARKER="$TEST_TMPDIR/npm-was-called"

    mkdir -p "$MOCK_HOME/.claude" "$PROJECT_DIR"
    create_mock_config_repo "$CONFIG_REPO_DIR"
    touch "$CONFIG_REPO_DIR/CLAUDE.md"
    ln -sf "$CONFIG_REPO_DIR/CLAUDE.md" "$MOCK_HOME/.claude/CLAUDE.md"
    cp "$REPO_ROOT/setup/scripts/sched-lib.sh" "$CONFIG_REPO_DIR/setup/scripts/"
    # The module under test may live in the repo's setup/scripts (guard) — mirror it into
    # the mock config repo so CONFIG_REPO-relative lookups resolve, if it exists yet.
    if [[ -f "$REPO_ROOT/setup/scripts/cc-install-invariants.sh" ]]; then
        cp "$REPO_ROOT/setup/scripts/cc-install-invariants.sh" "$CONFIG_REPO_DIR/setup/scripts/"
    fi
    make_cc_mirror_fixture "$MIRROR" "$LAUNCHER" "$version" "^$version" "$team"
    make_settings_template "$TMPL"
    mock_npm "$MOCKBIN" "$NPM_MARKER" "$view"
}

run_check() {
    local patched
    patched=$(create_patched_script "$CONFIG_REPO_DIR" "$MOCK_HOME" "$PROJECT_DIR")
    CTX=$(extract_additional_context "$(PATH="$MOCKBIN:$PATH" SCHED_MARKER_DIR="$TEST_TMPDIR/sched" \
          CC_INSTALL_SNAPSHOT="$SNAP" CC_SETTINGS_TEMPLATE="$TMPL" CC_LAUNCHER="$LAUNCHER" \
          XDG_CACHE_HOME="$TEST_TMPDIR/cache" run_hook "$patched")")
    echo "    measured context slice: [$(printf '%s' "$CTX" | grep -o -E '(DOWNGRADE|UNREQUESTED)[^|]{0,90}' | head -1 || echo none)]"
}

test_downgrade_surfaces_without_network_gate() {
    fx 2.1.1 false 2.1.1            # registry agrees with the install → 4.6 has nothing to say
    write_cc_snapshot "$SNAP" 2.1.274 false
    run_check
    assert_contains "$CTX" "DOWNGRADE" "SessionStart must report the downgrade" || return 1
    assert_contains "$CTX" "2.1.274" "must print the snapshot version" || return 1
    assert_contains "$CTX" "2.1.1" "must print the installed version" || return 1
    assert_contains "$CTX" "WARNING" "must go through WARNINGS so the session acts on it"
}
run_test "DOWNGRADE reaches additionalContext even when check 4.6 is silent" test_downgrade_surfaces_without_network_gate

test_downgrade_surfaces_with_network_down() {
    fx 2.1.1 false ""               # npm view fails → 4.6 skips entirely
    write_cc_snapshot "$SNAP" 2.1.274 false
    run_check
    assert_contains "$CTX" "DOWNGRADE" "a dead network must not hide a downgrade"
}
run_test "DOWNGRADE reported with npm view failing (offline)" test_downgrade_surfaces_with_network_down

test_team_mode_flip_surfaces() {
    fx 2.1.280 true 2.1.280
    write_cc_snapshot "$SNAP" 2.1.280 false
    run_check
    assert_contains "$CTX" "UNREQUESTED" "teamModeEnabled flip must be reported" || return 1
    assert_contains "$CTX" "teamModeEnabled" "must name the field"
}
run_test "UNREQUESTED teamModeEnabled flip reaches additionalContext" test_team_mode_flip_surfaces

test_skills_added_surface() {
    fx 2.1.280 false 2.1.280
    write_cc_snapshot "$SNAP" 2.1.280 false "lrn,simopt"
    fixture_add_skill "$MIRROR" orchestration
    run_check
    assert_contains "$CTX" "UNREQUESTED" "a skill that appeared must be reported" || return 1
    assert_contains "$CTX" "orchestration" "must name the skill"
}
run_test "UNREQUESTED skill (orchestration) reaches additionalContext" test_skills_added_surface

test_no_snapshot_is_baseline_and_quiet() {
    fx 2.1.280 false 2.1.280
    run_check
    assert_not_contains "$CTX" "DOWNGRADE" "no snapshot → no downgrade possible" || return 1
    assert_not_contains "$CTX" "UNREQUESTED" "no snapshot → nothing to differ from" || return 1
    assert_file_exists "$SNAP" "first run must write the baseline snapshot" || return 1
    assert_file_contains "$SNAP" "^version=2.1.280$" "baseline records the installed version"
}
run_test "no snapshot: baseline written, nothing reported" test_no_snapshot_is_baseline_and_quiet

test_consistent_state_is_quiet() {
    fx 2.1.280 false 2.1.280
    write_cc_snapshot "$SNAP" 2.1.280 false
    run_check
    assert_not_contains "$CTX" "DOWNGRADE" "consistent install must not warn" || return 1
    assert_not_contains "$CTX" "UNREQUESTED" "consistent install must not warn"
}
run_test "consistent install: quiet" test_consistent_state_is_quiet

suite_summary
