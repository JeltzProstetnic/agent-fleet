#!/usr/bin/env bash
# Tests for upgrade.sh channel selection
source "$(dirname "$0")/test-helpers.sh"

UPGRADE_SCRIPT="$REPO_ROOT/setup/upgrade.sh"

suite_header "upgrade-channel"

# ── Channel flag parsing ─────────────────────────────────────────────────────

test_channel_major_creates_file() {
    mkdir -p "$TEST_TMPDIR/repo/setup"
    cp "$UPGRADE_SCRIPT" "$TEST_TMPDIR/repo/setup/upgrade.sh"
    echo "0.0" > "$TEST_TMPDIR/repo/.agent-fleet-version"
    # Create minimal lib.sh stubs
    cat > "$TEST_TMPDIR/repo/setup/lib.sh" << 'STUB'
log_info()  { :; }
log_warn()  { :; }
log_error() { :; }
_sort_versions() { sort -V 2>/dev/null || sort -t. -k1,1n -k2,2n -k3,3n; }
STUB
    # Patch REPO_DIR to use test dir
    (cd "$TEST_TMPDIR/repo" && git init -q && git add -A && git commit -q -m init) >/dev/null 2>&1
    # Run with --channel major --dry-run (will fail at remote check, but channel file should be written first)
    bash "$TEST_TMPDIR/repo/setup/upgrade.sh" --channel major --dry-run 2>&1 || true
    [[ -f "$TEST_TMPDIR/repo/.agent-fleet-channel" ]] || fail "channel file not created"
    local ch
    ch=$(cat "$TEST_TMPDIR/repo/.agent-fleet-channel")
    assert_eq "major" "$ch"
}
run_test "--channel major creates .agent-fleet-channel" test_channel_major_creates_file

test_channel_rolling_creates_file() {
    mkdir -p "$TEST_TMPDIR/repo/setup"
    cp "$UPGRADE_SCRIPT" "$TEST_TMPDIR/repo/setup/upgrade.sh"
    echo "0.0" > "$TEST_TMPDIR/repo/.agent-fleet-version"
    cat > "$TEST_TMPDIR/repo/setup/lib.sh" << 'STUB'
log_info()  { :; }
log_warn()  { :; }
log_error() { :; }
STUB
    (cd "$TEST_TMPDIR/repo" && git init -q && git add -A && git commit -q -m init) >/dev/null 2>&1
    bash "$TEST_TMPDIR/repo/setup/upgrade.sh" --channel rolling --dry-run 2>&1 || true
    local ch
    ch=$(cat "$TEST_TMPDIR/repo/.agent-fleet-channel")
    assert_eq "rolling" "$ch"
}
run_test "--channel rolling creates .agent-fleet-channel" test_channel_rolling_creates_file

test_channel_invalid_rejected() {
    mkdir -p "$TEST_TMPDIR/repo/setup"
    cp "$UPGRADE_SCRIPT" "$TEST_TMPDIR/repo/setup/upgrade.sh"
    echo "0.0" > "$TEST_TMPDIR/repo/.agent-fleet-version"
    cat > "$TEST_TMPDIR/repo/setup/lib.sh" << 'STUB'
log_info()  { :; }
log_warn()  { :; }
log_error() { echo "$*" >&2; }
STUB
    (cd "$TEST_TMPDIR/repo" && git init -q && git add -A && git commit -q -m init) >/dev/null 2>&1
    local out
    out=$(bash "$TEST_TMPDIR/repo/setup/upgrade.sh" --channel nightly 2>&1) || true
    assert_contains "$out" "Invalid channel"
}
run_test "invalid channel rejected" test_channel_invalid_rejected

test_default_channel_is_major() {
    mkdir -p "$TEST_TMPDIR/repo/setup"
    cp "$UPGRADE_SCRIPT" "$TEST_TMPDIR/repo/setup/upgrade.sh"
    echo "0.0" > "$TEST_TMPDIR/repo/.agent-fleet-version"
    cat > "$TEST_TMPDIR/repo/setup/lib.sh" << 'STUB'
log_info()  { echo "$*"; }
log_warn()  { :; }
log_error() { :; }
STUB
    (cd "$TEST_TMPDIR/repo" && git init -q && git add -A && git commit -q -m init) >/dev/null 2>&1
    # No channel file — should default to major
    local out
    out=$(bash "$TEST_TMPDIR/repo/setup/upgrade.sh" --dry-run 2>&1) || true
    assert_contains "$out" "major"
}
run_test "default channel is major" test_default_channel_is_major

test_channel_persists_across_runs() {
    mkdir -p "$TEST_TMPDIR/repo/setup"
    cp "$UPGRADE_SCRIPT" "$TEST_TMPDIR/repo/setup/upgrade.sh"
    echo "0.0" > "$TEST_TMPDIR/repo/.agent-fleet-version"
    echo "rolling" > "$TEST_TMPDIR/repo/.agent-fleet-channel"
    cat > "$TEST_TMPDIR/repo/setup/lib.sh" << 'STUB'
log_info()  { echo "$*"; }
log_warn()  { :; }
log_error() { :; }
STUB
    (cd "$TEST_TMPDIR/repo" && git init -q && git add -A && git commit -q -m init) >/dev/null 2>&1
    local out
    out=$(bash "$TEST_TMPDIR/repo/setup/upgrade.sh" --dry-run 2>&1) || true
    assert_contains "$out" "rolling"
}
run_test "channel persists from file" test_channel_persists_across_runs

suite_summary
