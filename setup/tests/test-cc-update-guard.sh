#!/usr/bin/env bash
# Tests for the GUARD behaviour of setup/scripts/cc-update.sh — the fleet's own update
# wrapper, which must become the ONLY documented Claude Code update path.
#
# TDD: written 2026-09-23. The existing 12 tests in test-cc-update.sh cover today's script
# (backup, launcher rewrite, variant.json, rollback text). This file specifies what is
# MISSING, and is RED until the main session adds it:
#
#   1. Downgrade refusal. The target is resolved to a concrete x.y.z BEFORE anything runs
#      (`latest` is resolved via `npm view`, never passed on). If target < current, exit
#      non-zero, print DOWNGRADE with both numbers, touch nothing. --allow-downgrade
#      overrides. --dry-run prints the same DOWNGRADE line so the operator sees it first.
#   2. Post-condition = cc-install-invariants.sh --expect-version <target> (spec in
#      test-cc-install-invariants.sh). If it fails, restore the Phase 1 backup (npm/,
#      launcher, variant.json), print ROLLED BACK, exit non-zero. Exit 0 must mean the
#      install is verified, not that the installer exited 0.
#   3. After a verified update, write the snapshot (cc-install-invariants.sh --write-snapshot).
#   4. `--via cc-mirror` (native-layout machines have no npm/ tree to `npm install` into):
#      the wrapper invokes `npx -y cc-mirror@$CC_MIRROR_PIN update <variant>
#      --claude-version <x.y.z> --no-tweak` — a PINNED cc-mirror through npx, NEVER a bare
#      `cc-mirror` from PATH, and never the literal `latest`. Then the post-condition runs.
#
# Why: on WSL 2026-09-23 the bare `cc-mirror` on PATH was the Windows-side 1.6.2
# (/mnt/c/Users/Matthias/AppData/Roaming/npm, PATH position 28), whose bundle contains no
# `--claude-version` at all; it re-provisioned from claudeOrig=2.1.1, flipped the launcher
# to cli.js, re-asserted team mode, and exited 0. mock_cc_mirror_1_6_2 reproduces that.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"
source "$SCRIPT_DIR/lib-cc-install-fixture.sh"

CC_UPDATE="$REPO_ROOT/setup/scripts/cc-update.sh"

suite_header "cc-update.sh guard behaviour (downgrade refusal, post-condition, pinned cc-mirror)"

fx() {
    local version="$1" team="${2:-false}"
    MIRROR="$HOME/.cc-mirror/mclaude"
    LAUNCHER="$HOME/.local/bin/mclaude"
    SNAP="$TEST_TMPDIR/cache/cfg-agent-fleet/cc-install.snapshot"
    TMPL="$TEST_TMPDIR/template/settings.json"
    MOCKBIN="$TEST_TMPDIR/mockbin"
    NPM_MARKER="$TEST_TMPDIR/npm-argv"
    NPX_MARKER="$TEST_TMPDIR/npx-argv"
    CCM_MARKER="$TEST_TMPDIR/cc-mirror-argv"
    make_cc_mirror_fixture "$MIRROR" "$LAUNCHER" "$version" "^$version" "$team"
    make_settings_template "$TMPL"
    mkdir -p "$MOCKBIN"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true
}

update() {
    local rc=0
    OUT=$(PATH="$MOCKBIN:$PATH" CC_INSTALL_SNAPSHOT="$SNAP" CC_SETTINGS_TEMPLATE="$TMPL" \
          XDG_CACHE_HOME="$TEST_TMPDIR/cache" bash "$CC_UPDATE" "$@" 2>&1) || rc=$?
    RC=$rc
    echo "    measured rc=$RC; tail: [$(printf '%s\n' "$OUT" | tail -1 | cut -c1-120)]"
}

installed_version() {
    python3 -c "import json; print(json.load(open('$MIRROR/npm/node_modules/@anthropic-ai/claude-code/package.json'))['version'])" 2>/dev/null || echo "unreadable"
}

# ── Downgrade refusal ────────────────────────────────────────────────────────
test_refuses_downgrade() {
    fx 2.1.274
    mock_installer_ok "$MOCKBIN" npm "$NPM_MARKER" "$MIRROR" 2.1.1
    update --version 2.1.1
    assert_neq "0" "$RC" "2.1.274 → 2.1.1 must be refused" || return 1
    assert_contains "$OUT" "DOWNGRADE" "must say DOWNGRADE" || return 1
    assert_contains "$OUT" "2.1.274" "must print the current version" || return 1
    assert_file_not_exists "$NPM_MARKER" "npm must not have been invoked" || return 1
    assert_eq "2.1.274" "$(installed_version)" "install must be untouched"
}
run_test "refuses a downgrade: DOWNGRADE printed, installer never called, files untouched" test_refuses_downgrade

test_dry_run_shows_downgrade() {
    fx 2.1.274
    mock_installer_ok "$MOCKBIN" npm "$NPM_MARKER" "$MIRROR" 2.1.1
    update --dry-run --version 2.1.1
    assert_contains "$OUT" "DOWNGRADE" "--dry-run must already show the DOWNGRADE verdict" || return 1
    assert_file_not_exists "$NPM_MARKER" "dry run never installs"
}
run_test "--dry-run surfaces DOWNGRADE before anything runs" test_dry_run_shows_downgrade

test_allow_downgrade_proceeds() {
    fx 2.1.274
    mock_installer_ok "$MOCKBIN" npm "$NPM_MARKER" "$MIRROR" 2.1.1
    update --version 2.1.1 --allow-downgrade
    assert_file_exists "$NPM_MARKER" "--allow-downgrade must let the install proceed" || return 1
    assert_eq "2.1.1" "$(installed_version)" "installed version must be the requested one"
}
run_test "--allow-downgrade proceeds explicitly" test_allow_downgrade_proceeds

test_latest_is_resolved_before_compare() {
    fx 2.1.274
    # `npm view` answers 2.1.1 (a registry that is, for whatever reason, behind us).
    mock_installer_ok "$MOCKBIN" npm "$NPM_MARKER" "$MIRROR" 2.1.1
    update --version latest
    assert_neq "0" "$RC" "latest resolving below current must be refused, not installed" || return 1
    assert_contains "$OUT" "DOWNGRADE" "must say DOWNGRADE for a resolved 'latest' too" || return 1
    assert_eq "2.1.274" "$(installed_version)" "install must be untouched"
}
run_test "'latest' is resolved to a number and compared — a behind-registry cannot downgrade" test_latest_is_resolved_before_compare

# ── Post-condition and rollback ──────────────────────────────────────────────
test_postcondition_rolls_back_wrong_version() {
    fx 2.1.274
    # Installer exits 0 but leaves 2.1.1 behind — the 2026-09-23 shape, seen through npm.
    mock_cc_mirror_1_6_2 "$MOCKBIN" npm "$NPM_MARKER" "$MIRROR" "$LAUNCHER"
    update --version 2.1.280
    assert_neq "0" "$RC" "post-condition failure must exit non-zero" || return 1
    assert_contains "$OUT" "ROLLED BACK" "must say it rolled back" || return 1
    assert_eq "2.1.274" "$(installed_version)" "npm tree must be restored from the Phase 1 backup" || return 1
    assert_contains "$(tail -1 "$LAUNCHER")" "claude.exe" "launcher must be restored to the pre-update target" || return 1
    assert_file_contains "$MIRROR/variant.json" '"npmVersion": "2.1.274"' "variant.json must be restored"
}
run_test "post-condition: installer exits 0 but leaves 2.1.1 → ROLLED BACK to 2.1.274" test_postcondition_rolls_back_wrong_version

test_success_writes_snapshot() {
    fx 2.1.274
    mock_installer_ok "$MOCKBIN" npm "$NPM_MARKER" "$MIRROR" 2.1.280
    update --version 2.1.280
    assert_eq "0" "$RC" "verified update must exit 0" || return 1
    assert_file_exists "$SNAP" "a verified update must record the snapshot" || return 1
    assert_file_contains "$SNAP" "^version=2.1.280$" "snapshot must carry the new version"
}
run_test "verified update writes the last-known-good snapshot" test_success_writes_snapshot

# ── --via cc-mirror: pinned, through npx, never bare, never 'latest' ─────────
test_via_cc_mirror_never_uses_path_binary() {
    fx 2.1.274
    mock_npm "$MOCKBIN" "$NPM_MARKER" 2.1.280                       # npm view → 2.1.280
    mock_cc_mirror_1_6_2 "$MOCKBIN" cc-mirror "$CCM_MARKER" "$MIRROR" "$LAUNCHER"   # the trap on PATH
    mock_installer_ok "$MOCKBIN" npx "$NPX_MARKER" "$MIRROR" 2.1.280               # the sanctioned road
    update --via cc-mirror --version latest
    assert_file_not_exists "$CCM_MARKER" "a bare cc-mirror on PATH must never be invoked" || return 1
    assert_file_exists "$NPX_MARKER" "cc-mirror must be reached through npx"
}
run_test "--via cc-mirror: bare cc-mirror on PATH is never invoked; npx is" test_via_cc_mirror_never_uses_path_binary

test_via_cc_mirror_is_pinned_and_concrete() {
    fx 2.1.274
    mock_npm "$MOCKBIN" "$NPM_MARKER" 2.1.280
    mock_installer_ok "$MOCKBIN" npx "$NPX_MARKER" "$MIRROR" 2.1.280
    update --via cc-mirror --version latest
    local argv; argv=$(cat "$NPX_MARKER" 2>/dev/null || echo "<npx not called>")
    echo "    measured npx argv: [$argv]"
    assert_contains "$argv" "cc-mirror@" "cc-mirror version must be pinned (cc-mirror@<ver>)" || return 1
    assert_contains "$argv" "--claude-version 2.1.280" "must pass the RESOLVED version" || return 1
    assert_not_contains "$argv" "--claude-version latest" "must never hand 'latest' to cc-mirror" || return 1
    assert_contains "$argv" "--no-tweak" "must keep --no-tweak (native binaries: no code patches)"
}
run_test "--via cc-mirror: npx cc-mirror@<pin> … --claude-version <x.y.z> --no-tweak" test_via_cc_mirror_is_pinned_and_concrete

test_via_cc_mirror_catches_1_6_2_behaviour() {
    fx 2.1.274
    mock_npm "$MOCKBIN" "$NPM_MARKER" 2.1.280
    # Even the sanctioned road misbehaves like 1.6.2 did: reset to 2.1.1, team mode, cli.js.
    mock_cc_mirror_1_6_2 "$MOCKBIN" npx "$NPX_MARKER" "$MIRROR" "$LAUNCHER"
    update --via cc-mirror --version latest
    assert_neq "0" "$RC" "a misbehaving cc-mirror must not produce exit 0" || return 1
    assert_contains "$OUT" "ROLLED BACK" "must roll back" || return 1
    assert_eq "2.1.274" "$(installed_version)" "npm tree restored" || return 1
    assert_file_contains "$MIRROR/variant.json" '"teamModeEnabled": false' "teamModeEnabled restored" || return 1
    assert_contains "$(tail -1 "$LAUNCHER")" "claude.exe" "launcher restored" || return 1
    assert_dir_exists "$MIRROR/config/skills/lrn" "existing skills untouched"
}
run_test "--via cc-mirror: 1.6.2-style reset (2.1.1, team mode, cli.js) is detected and ROLLED BACK" test_via_cc_mirror_catches_1_6_2_behaviour

suite_summary
