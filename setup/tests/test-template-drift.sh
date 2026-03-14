#!/usr/bin/env bash
# Tests for template drift detection and personal data leak checking
# Part of CFG-24: Dependency Propagation System
source "$(dirname "$0")/test-helpers.sh"

SYNC_SCRIPT="$REPO_ROOT/sync.sh"

suite_header "Template Drift Detection"

# ── Helper: create a mock manifest ───────────────────────────────────────────

create_mock_manifest() {
    local dir="$1"
    local file_path="$2"
    local hash="$3"
    cat > "$dir/template-sync-manifest.md" <<EOF
# Template Sync Manifest

## Tracked Files — Must Be Identical

| File | Hash (CRC32, python binascii) | Date |
|------|------|------|
| \`$file_path\` | \`$hash\` | 2026-03-02 |
EOF
}

# Helper: compute CRC32 the same way sync.sh does
compute_crc32() {
    python3 -c "import binascii,sys;print(format(binascii.crc32(open(sys.argv[1],'rb').read())&0xFFFFFFFF,'08x'))" "$1"
}

# ── Template drift detection ─────────────────────────────────────────────────

test_drift_detects_changed_file() {
    # Set up a mock repo with a tracked file
    mkdir -p "$TEST_TMPDIR/repo"
    echo "original content" > "$TEST_TMPDIR/repo/test-file.sh"
    local original_hash
    original_hash=$(compute_crc32 "$TEST_TMPDIR/repo/test-file.sh")

    # Create manifest with the original hash
    create_mock_manifest "$TEST_TMPDIR/repo" "test-file.sh" "$original_hash"

    # Modify the file (hash will no longer match)
    echo "modified content" > "$TEST_TMPDIR/repo/test-file.sh"

    # Run the check subcommand — should report drift
    local out rc=0
    out=$(bash "$SYNC_SCRIPT" check --repo-root "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_contains "$out" "test-file.sh"
    assert_contains "$out" "drifted"
}
run_test "drift detection reports changed file" test_drift_detects_changed_file

test_drift_clean_when_hashes_match() {
    # Set up a mock repo with a tracked file
    mkdir -p "$TEST_TMPDIR/repo"
    echo "stable content" > "$TEST_TMPDIR/repo/test-file.sh"
    local hash
    hash=$(compute_crc32 "$TEST_TMPDIR/repo/test-file.sh")

    # Create manifest with matching hash
    create_mock_manifest "$TEST_TMPDIR/repo" "test-file.sh" "$hash"

    # Run the check subcommand — should report clean
    local out rc=0
    out=$(bash "$SYNC_SCRIPT" check --repo-root "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_not_contains "$out" "drifted"
}
run_test "drift detection is clean when hashes match" test_drift_clean_when_hashes_match

test_drift_handles_missing_manifest() {
    # No manifest file exists
    mkdir -p "$TEST_TMPDIR/repo"

    # Should warn gracefully, not crash
    local out rc=0
    out=$(bash "$SYNC_SCRIPT" check --repo-root "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    # Should not crash (rc=0 or known exit) and mention manifest
    assert_contains "$out" "manifest"
}
run_test "drift detection handles missing manifest gracefully" test_drift_handles_missing_manifest

test_drift_handles_missing_file() {
    # Manifest references a file that doesn't exist
    mkdir -p "$TEST_TMPDIR/repo"
    create_mock_manifest "$TEST_TMPDIR/repo" "nonexistent.sh" "00000000"

    # Should warn about missing file, not crash
    local out rc=0
    out=$(bash "$SYNC_SCRIPT" check --repo-root "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_not_contains "$out" "No such file"
    # Should not have a bash error — graceful handling
    [[ "$rc" -eq 0 ]]
}
run_test "drift detection handles missing tracked file gracefully" test_drift_handles_missing_file

# ── Personal data leak check ─────────────────────────────────────────────────

test_leak_check_detects_personal_data() {
    # Create a mock template dir with personal data
    mkdir -p "$TEST_TMPDIR/template"
    echo "Contact: test-user@example.com" > "$TEST_TMPDIR/template/README.md"

    # PERSONAL_DATA_PATTERNS must be set for the leak check to activate
    local out rc=0
    out=$(PERSONAL_DATA_PATTERNS='test-user@example\.com' bash "$SYNC_SCRIPT" check --template-dir "$TEST_TMPDIR/template" --repo-root "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_contains "$out" "personal"
}
run_test "leak check detects personal data in template" test_leak_check_detects_personal_data

test_leak_check_clean() {
    # Create a mock template dir with NO personal data
    mkdir -p "$TEST_TMPDIR/template"
    echo "Generic template content" > "$TEST_TMPDIR/template/README.md"
    mkdir -p "$TEST_TMPDIR/repo"
    create_mock_manifest "$TEST_TMPDIR/repo" "dummy.sh" "00000000"
    echo "dummy" > "$TEST_TMPDIR/repo/dummy.sh"

    local out rc=0
    out=$(bash "$SYNC_SCRIPT" check --template-dir "$TEST_TMPDIR/template" --repo-root "$TEST_TMPDIR/repo" 2>&1) || rc=$?
    assert_not_contains "$out" "personal"
    assert_not_contains "$out" "leak"
}
run_test "leak check is clean when no personal data present" test_leak_check_clean

# ── Check subcommand integration ─────────────────────────────────────────────

test_check_subcommand_runs() {
    mkdir -p "$TEST_TMPDIR/repo"
    create_mock_manifest "$TEST_TMPDIR/repo" "dummy.sh" "00000000"
    echo "dummy" > "$TEST_TMPDIR/repo/dummy.sh"

    local rc=0
    bash "$SYNC_SCRIPT" check --repo-root "$TEST_TMPDIR/repo" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "check subcommand should always exit 0 (warning-only)"
}
run_test "check subcommand runs without crashing" test_check_subcommand_runs

test_check_reports_template_drift() {
    mkdir -p "$TEST_TMPDIR/repo"
    echo "original" > "$TEST_TMPDIR/repo/test.sh"
    local hash
    hash=$(compute_crc32 "$TEST_TMPDIR/repo/test.sh")
    create_mock_manifest "$TEST_TMPDIR/repo" "test.sh" "$hash"

    # Modify the file
    echo "changed" > "$TEST_TMPDIR/repo/test.sh"

    local out
    out=$(bash "$SYNC_SCRIPT" check --repo-root "$TEST_TMPDIR/repo" 2>&1)
    assert_contains "$out" "drifted"
    assert_contains "$out" "issue(s) found"
}
run_test "check reports template drift in summary" test_check_reports_template_drift

test_check_reports_all_clean() {
    mkdir -p "$TEST_TMPDIR/repo"
    echo "stable" > "$TEST_TMPDIR/repo/test.sh"
    local hash
    hash=$(compute_crc32 "$TEST_TMPDIR/repo/test.sh")
    create_mock_manifest "$TEST_TMPDIR/repo" "test.sh" "$hash"

    local out
    out=$(bash "$SYNC_SCRIPT" check --repo-root "$TEST_TMPDIR/repo" 2>&1)
    assert_contains "$out" "clean"
    assert_not_contains "$out" "drifted"
}
run_test "check reports all clean when no drift" test_check_reports_all_clean

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
