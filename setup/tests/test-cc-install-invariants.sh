#!/usr/bin/env bash
# Tests for setup/scripts/cc-install-invariants.sh — the local, network-free post-condition
# check for the Claude Code install under ~/.cc-mirror/<variant>.
#
# TDD: written 2026-09-23 BEFORE the script exists. Every test is RED until the main
# session implements it. The script is specified here, not elsewhere:
#
#   cc-install-invariants.sh [--expect-version X.Y.Z] [--write-snapshot]
#     env: CC_MIRROR_DIR         (default $HOME/.cc-mirror/mclaude)
#          CC_LAUNCHER           (default $HOME/.local/bin/mclaude)
#          CC_INSTALL_SNAPSHOT   (default ${XDG_CACHE_HOME:-$HOME/.cache}/cfg-agent-fleet/cc-install.snapshot)
#          CC_SETTINGS_TEMPLATE  (default <repo>/setup/config/settings.json)
#
#   Reads ONLY the filesystem. Never calls npm, never calls cc-mirror, never touches the
#   network — the daily `npm view` gate in check 4.6 must not be able to silence this.
#   Prints one line per check, each carrying the MEASURED values:
#     OK: …            FAIL: <TAG> …          WARN: …          INFO: …
#   Tags: DOWNGRADE (installed < snapshot), RANGE (installed outside npm/package.json
#   range), VARIANT (variant.json npmVersion != installed), LAUNCHER (exec target missing),
#   UNREQUESTED (teamModeEnabled or skill set changed vs snapshot), SETTINGS (live env key
#   absent from the repo template), EXPECT (--expect-version mismatch), UNKNOWN (no
#   version determinable — LOUD, never silent). Exit 1 on any FAIL, else 0.
#   Snapshot format (key=value): version=, teamModeEnabled=, skills=<csv, sorted>.
#   With no snapshot the run is a baseline: no DOWNGRADE/UNREQUESTED can fire, and
#   --write-snapshot records the current state.
#
# Why each check exists — measured on WSL 2026-09-23 after `cc-mirror update`:
#   installed 2.1.274 → 2.1.1 (a reset to variant.json's creation-time pin), exit 0;
#   npm/package.json still declared ^2.1.274; variant.json npmVersion rewritten to 2.1.1;
#   launcher rewritten to `exec node …/cli.js`; teamModeEnabled re-asserted; orchestration
#   and task-manager skills reinstalled. Check 4.6 had already spent its daily gate at
#   10:56, so no SessionStart that day could have reported any of it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"
source "$SCRIPT_DIR/lib-cc-install-fixture.sh"

GUARD="$REPO_ROOT/setup/scripts/cc-install-invariants.sh"

suite_header "cc-install-invariants.sh (local CC install post-conditions)"

# ── Per-test fixture ─────────────────────────────────────────────────────────
# Sets MIRROR, LAUNCHER, SNAP, TMPL, MOCKBIN, NPM_MARKER, CCM_MARKER for the current test.
# A recording npm mock (network DOWN) and a recording cc-mirror mock sit first on PATH so
# every test also proves the guard is local: neither marker may ever appear.
fx() {
    local version="$1" range="$2" team="$3" layout="${4:-npm}"
    MIRROR="$HOME/.cc-mirror/mclaude"
    LAUNCHER="$HOME/.local/bin/mclaude"
    SNAP="$TEST_TMPDIR/cache/cfg-agent-fleet/cc-install.snapshot"
    TMPL="$TEST_TMPDIR/template/settings.json"
    MOCKBIN="$TEST_TMPDIR/mockbin"
    NPM_MARKER="$TEST_TMPDIR/npm-was-called"
    CCM_MARKER="$TEST_TMPDIR/cc-mirror-was-called"
    make_cc_mirror_fixture "$MIRROR" "$LAUNCHER" "$version" "$range" "$team" "$layout"
    make_settings_template "$TMPL"
    mock_npm "$MOCKBIN" "$NPM_MARKER"
    printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$CCM_MARKER" > "$MOCKBIN/cc-mirror"
    chmod +x "$MOCKBIN/cc-mirror"
}

guard() {
    local rc=0
    OUT=$(PATH="$MOCKBIN:$PATH" CC_MIRROR_DIR="$MIRROR" CC_LAUNCHER="$LAUNCHER" \
          CC_INSTALL_SNAPSHOT="$SNAP" CC_SETTINGS_TEMPLATE="$TMPL" \
          bash "$GUARD" "$@" 2>&1) || rc=$?
    RC=$rc
    echo "    measured rc=$RC; first FAIL line: [$(printf '%s\n' "$OUT" | grep -m1 '^FAIL:' || echo none)]"
}

# ── 1. A consistent install passes and prints what it measured ───────────────
test_consistent_install_passes() {
    fx 2.1.280 '^2.1.280' false
    guard
    assert_eq "0" "$RC" "consistent npm-layout install must exit 0" || return 1
    assert_contains "$OUT" "OK:" "must print OK lines" || return 1
    assert_contains "$OUT" "2.1.280" "must print the measured installed version"
}
run_test "consistent install: exit 0, prints measured version" test_consistent_install_passes

# ── 2. DOWNGRADE: installed below the last-known-good snapshot ────────────────
test_downgrade_vs_snapshot_fails() {
    fx 2.1.1 '^2.1.1' false
    write_cc_snapshot "$SNAP" 2.1.274 false
    guard
    assert_neq "0" "$RC" "installed 2.1.1 with snapshot 2.1.274 must FAIL" || return 1
    assert_contains "$OUT" "DOWNGRADE" "must name the failure DOWNGRADE" || return 1
    assert_contains "$OUT" "2.1.274" "must print the snapshot version" || return 1
    assert_contains "$OUT" "2.1.1" "must print the installed version"
}
run_test "DOWNGRADE: installed 2.1.1 < snapshot 2.1.274 fails, both values printed" test_downgrade_vs_snapshot_fails

# ── 3. An upgrade is not a downgrade ─────────────────────────────────────────
test_upgrade_vs_snapshot_passes() {
    fx 2.1.280 '^2.1.280' false
    write_cc_snapshot "$SNAP" 2.1.274 false
    guard
    assert_eq "0" "$RC" "2.1.274 → 2.1.280 must pass" || return 1
    assert_not_contains "$OUT" "DOWNGRADE" "an upgrade must not be reported as DOWNGRADE"
}
run_test "upgrade 2.1.274 → 2.1.280 passes" test_upgrade_vs_snapshot_passes

# ── 4. Comparison is ordinal (sort -V), not lexical ───────────────────────────
test_version_compare_is_ordinal() {
    fx 2.1.10 '^2.1.10' false
    write_cc_snapshot "$SNAP" 2.1.9 false
    guard
    assert_eq "0" "$RC" "2.1.9 → 2.1.10 is an upgrade (lexically it looks like a downgrade)" || return 1
    assert_not_contains "$OUT" "DOWNGRADE" "must compare ordinally, not as strings"
}
run_test "ordinal compare: 2.1.9 → 2.1.10 is not a downgrade" test_version_compare_is_ordinal

# ── 5. RANGE: installed outside the mirror's own declared dependency range ────
test_declared_range_violation_fails() {
    fx 2.1.1 '^2.1.274' false
    guard
    assert_neq "0" "$RC" "installed 2.1.1 vs declared ^2.1.274 must FAIL" || return 1
    assert_contains "$OUT" "RANGE" "must name the failure RANGE" || return 1
    assert_contains "$OUT" "^2.1.274" "must print the declared range"
}
run_test "RANGE: installed 2.1.1 violates npm/package.json ^2.1.274" test_declared_range_violation_fails

# ── 6. VARIANT: variant.json disagrees with the installed package ─────────────
test_variant_json_mismatch_fails() {
    fx 2.1.280 '^2.1.280' false
    fixture_set_variant_field "$MIRROR" npmVersion '"2.1.1"'
    guard
    assert_neq "0" "$RC" "variant.json npmVersion 2.1.1 vs installed 2.1.280 must FAIL" || return 1
    assert_contains "$OUT" "VARIANT" "must name the failure VARIANT"
}
run_test "VARIANT: variant.json npmVersion != installed package version" test_variant_json_mismatch_fails

# ── 7. LAUNCHER: the exec target does not exist ───────────────────────────────
test_launcher_target_missing_fails() {
    fx 2.1.280 '^2.1.280' false
    fixture_set_launcher_target "$LAUNCHER" \
        "$MIRROR/npm/node_modules/@anthropic-ai/claude-code/cli.js" node
    guard
    assert_neq "0" "$RC" "launcher exec'ing a missing cli.js must FAIL" || return 1
    assert_contains "$OUT" "LAUNCHER" "must name the failure LAUNCHER" || return 1
    assert_contains "$OUT" "cli.js" "must print the missing target"
}
run_test "LAUNCHER: exec target (cli.js) missing" test_launcher_target_missing_fails

# ── 8. UNREQUESTED: teamModeEnabled flipped since the snapshot ────────────────
test_team_mode_flip_fails() {
    fx 2.1.280 '^2.1.280' true
    write_cc_snapshot "$SNAP" 2.1.280 false
    guard
    assert_neq "0" "$RC" "teamModeEnabled false → true must FAIL" || return 1
    assert_contains "$OUT" "UNREQUESTED" "must name the failure UNREQUESTED" || return 1
    assert_contains "$OUT" "teamModeEnabled" "must say which field changed"
}
run_test "UNREQUESTED: teamModeEnabled flipped vs snapshot" test_team_mode_flip_fails

# ── 9. UNREQUESTED: skills appeared that were not there at the snapshot ───────
test_skills_added_fails() {
    fx 2.1.280 '^2.1.280' false
    write_cc_snapshot "$SNAP" 2.1.280 false "lrn,simopt"
    fixture_add_skill "$MIRROR" orchestration
    fixture_add_skill "$MIRROR" task-manager
    guard
    assert_neq "0" "$RC" "new orchestration/task-manager skills must FAIL" || return 1
    assert_contains "$OUT" "UNREQUESTED" "must name the failure UNREQUESTED" || return 1
    assert_contains "$OUT" "orchestration" "must name the added skill"
}
run_test "UNREQUESTED: orchestration + task-manager skills added vs snapshot" test_skills_added_fails

# ── 10. SETTINGS: live env key that the repo template does not declare ────────
test_settings_env_not_in_template_fails() {
    fx 2.1.280 '^2.1.280' false
    fixture_settings_env "$MIRROR" CLAUDE_CODE_TEAM_MODE 1
    guard
    assert_neq "0" "$RC" "live CLAUDE_CODE_TEAM_MODE absent from template must FAIL" || return 1
    assert_contains "$OUT" "SETTINGS" "must name the failure SETTINGS" || return 1
    assert_contains "$OUT" "CLAUDE_CODE_TEAM_MODE" "must name the leaked key"
}
run_test "SETTINGS: live env CLAUDE_CODE_TEAM_MODE not declared by template" test_settings_env_not_in_template_fails

test_settings_env_declared_by_template_passes() {
    fx 2.1.280 '^2.1.280' false
    fixture_settings_env "$MIRROR" CLAUDE_CODE_TEAM_MODE 1
    make_settings_template "$TMPL" CLAUDE_CODE_TEAM_MODE 1
    guard
    assert_eq "0" "$RC" "a key the template declares is policy, not drift" || return 1
    assert_not_contains "$OUT" "SETTINGS" "must not report a template-declared key"
}
run_test "SETTINGS: key declared by template is not drift (template is the policy)" test_settings_env_declared_by_template_passes

# ── 11. EXPECT: caller states the version it just installed ───────────────────
test_expect_version_mismatch_fails() {
    fx 2.1.1 '^2.1.1' false
    guard --expect-version 2.1.280
    assert_neq "0" "$RC" "installed 2.1.1 vs --expect-version 2.1.280 must FAIL" || return 1
    assert_contains "$OUT" "EXPECT" "must name the failure EXPECT" || return 1
    assert_contains "$OUT" "2.1.280" "must print the expected version"
}
run_test "EXPECT: --expect-version 2.1.280 vs installed 2.1.1" test_expect_version_mismatch_fails

# ── 12. Baseline + snapshot round trip ───────────────────────────────────────
test_baseline_writes_snapshot_and_round_trips() {
    fx 2.1.280 '^2.1.280' false
    guard --write-snapshot
    assert_eq "0" "$RC" "first run with no snapshot is a baseline and must pass" || return 1
    assert_not_contains "$OUT" "DOWNGRADE" "no snapshot → nothing to be below" || return 1
    assert_file_exists "$SNAP" "--write-snapshot must create the snapshot" || return 1
    assert_file_contains "$SNAP" "^version=2.1.280$" "snapshot records version=" || return 1
    assert_file_contains "$SNAP" "^teamModeEnabled=false$" "snapshot records teamModeEnabled=" || return 1
    guard
    assert_eq "0" "$RC" "second run against its own snapshot must pass"
}
run_test "baseline: --write-snapshot records version + teamModeEnabled, round-trips clean" test_baseline_writes_snapshot_and_round_trips

# ── 13. Native layout (Deck/NUC/office): no npm/, version from the binary ─────
test_native_layout_passes_without_range_check() {
    fx 2.1.240 '' false native
    guard
    assert_eq "0" "$RC" "native layout with consistent state must pass" || return 1
    assert_not_contains "$OUT" "RANGE" "no npm/package.json → no RANGE failure" || return 1
    assert_contains "$OUT" "2.1.240" "must print the version read from the binary"
}
run_test "native layout: passes, version from native/claude --version, no RANGE" test_native_layout_passes_without_range_check

# ── 14. UNKNOWN is loud ──────────────────────────────────────────────────────
test_unknown_version_is_loud() {
    fx 2.1.280 '^2.1.280' false
    rm -rf "$MIRROR/npm" "$MIRROR/native"
    fixture_set_variant_field "$MIRROR" npmVersion '"latest"'
    fixture_set_variant_field "$MIRROR" claudeOrig '"npm:@anthropic-ai/claude-code@latest"'
    fixture_set_variant_field "$MIRROR" binaryPath '"/nonexistent/claude"'
    guard
    assert_neq "0" "$RC" "no determinable version must FAIL, never pass silently" || return 1
    assert_contains "$OUT" "UNKNOWN" "must say UNKNOWN"
}
run_test "UNKNOWN: no version anywhere → loud FAIL, not silence" test_unknown_version_is_loud

# ── 15/16. Local only: never npm, never cc-mirror ────────────────────────────
test_never_calls_npm() {
    fx 2.1.1 '^2.1.274' false
    write_cc_snapshot "$SNAP" 2.1.274 false
    guard
    assert_file_not_exists "$NPM_MARKER" "the guard must not invoke npm (no network, no daily gate)"
}
run_test "local only: npm is never invoked" test_never_calls_npm

test_never_calls_cc_mirror() {
    fx 2.1.1 '^2.1.274' true
    guard --write-snapshot
    assert_file_not_exists "$CCM_MARKER" "the guard must never invoke cc-mirror"
}
run_test "local only: cc-mirror is never invoked" test_never_calls_cc_mirror

suite_summary
