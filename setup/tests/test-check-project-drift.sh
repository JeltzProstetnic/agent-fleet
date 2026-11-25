#!/usr/bin/env bash
# Tests for global/hooks/checks/31-project-drift.sh — CFG-1094 (pattern of 22-fleet-drift.sh).
#
# Exactly one PROJECT_DRIFT line per cfg session, from the date-gated sweep of every registered
# project on this machine (read-only; the fixes happen in each project's own session or in the
# one-time backfill). OK → INBOX_MSG, findings → WARNINGS. Silence never occurs: a missing
# script or an empty probe is itself reported. Every other project pays nothing.
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/lib-pc-fixture.sh"

CHECK="$REPO_ROOT/global/hooks/checks/31-project-drift.sh"

suite_header "check 31: project-drift (CFG-1094: one PROJECT_DRIFT line, cfg sessions only)"

_run() {   # <project-dir> [config-repo]
    WARNINGS=""; INBOX_MSG=""
    PROJECT_DIR="$1"; CONFIG_REPO="${2:-$REPO_ROOT}"
    PC_CACHE="$TEST_TMPDIR/cache/project-drift.status" SCHED_MARKER_DIR="$TEST_TMPDIR/sched"
    export PC_CACHE SCHED_MARKER_DIR
    # shellcheck disable=SC1090
    source "$CHECK"
    printf 'W=%s\nI=%s\n' "$WARNINGS" "$INBOX_MSG"
}

t_non_cfg_silent() {
    pcf_cfg; pcf_project other --legacy-inbox
    assert_eq "W=
I=" "$(_run "$P")" "a project session never sweeps the registry"
}
run_test "a non-cfg session emits nothing" t_non_cfg_silent

t_cfg_drift_is_a_warning() {
    pcf_cfg; pcf_project drifted --legacy-inbox
    local out; out=$(_run "$REPO_ROOT")
    assert_contains "$out" "W=PROJECT_DRIFT[WARN]: 1 registered, 0 conform, 1 to fix (drifted)" || return 1
    assert_contains "$out" "probed $(date +%Y-%m-%d)" || return 1
    assert_eq "I=" "$(printf '%s\n' "$out" | tail -1)" || return 1
    assert_eq "" "$(git -C "$P" status --porcelain)" "the cfg sweep is read-only"
}
run_test "a cfg session with drifting projects gets one PROJECT_DRIFT[WARN] line" t_cfg_drift_is_a_warning

t_cfg_all_ok_is_inbox() {
    pcf_cfg; pcf_project fine --githooks --knowledge vertical-slicing.md --knowledge needs-to-requirements.md \
        --knowledge test-isolation-guards.md --knowledge anti-chain-state.md --knowledge log-evidence-traps.md --knowledge llm-provider-integration.md
    local out; out=$(_run "$REPO_ROOT")
    assert_eq "W=" "$(printf '%s\n' "$out" | head -1)" || return 1
    assert_contains "$out" "I=PROJECT_DRIFT: 1 registered, 1 conform"
}
run_test "all conforming → PROJECT_DRIFT in the inbox channel, no warning" t_cfg_all_ok_is_inbox

t_exactly_one_line_and_gated() {
    pcf_cfg; pcf_project g1 --legacy-inbox
    _run "$REPO_ROOT" >/dev/null
    pcf_project g2 --legacy-inbox
    local out; out=$(_run "$REPO_ROOT")
    assert_eq "1" "$(printf '%s' "$out" | grep -o 'PROJECT_DRIFT' | wc -l | tr -d ' ')" || return 1
    assert_contains "$out" "1 registered" "the second start the same day renders yesterday's… today's cache, not a new probe"
}
run_test "one line per session, and the daily gate serves the cache" t_exactly_one_line_and_gated

t_script_missing_reported() {
    local fake="$TEST_TMPDIR/fake-cfg"; mkdir -p "$fake"
    assert_contains "$(_run "$fake" "$fake")" "W=PROJECT_DRIFT: probe script missing"
}
run_test "a missing script is a reported degradation" t_script_missing_reported

t_empty_probe_reported() {
    local fake="$TEST_TMPDIR/fake-cfg"; mkdir -p "$fake/setup/scripts"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/setup/scripts/project-conformance.sh"
    assert_contains "$(_run "$fake" "$fake")" "W=PROJECT_DRIFT: probe produced no output"
}
run_test "an empty probe is a reported degradation" t_empty_probe_reported

suite_summary
