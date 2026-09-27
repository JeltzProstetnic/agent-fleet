#!/usr/bin/env bash
# Tests for global/hooks/checks/08-propagation-drift.sh — Check 34
# Real-time template propagation drift detection at session start.
source "$(dirname "$0")/test-helpers.sh"

suite_header "08-propagation-drift.sh (Check 34: real-time template drift)"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Create minimal shared state that the check module expects
# Then source the module and capture resulting WARNINGS
run_drift_check() {
    local config_repo="$1"
    local mock_home="$2"

    (
        # Set shared variables that config-check.sh normally provides
        export HOME="$mock_home"
        CONFIG_REPO="$config_repo"
        WARNINGS=""

        # Source the module under test
        source "$REPO_ROOT/global/hooks/checks/08-propagation-drift.sh" 2>/dev/null

        # Output WARNINGS so we can capture it
        echo "$WARNINGS"
    )
}

# Create a config repo with a manifest containing "Must Be Identical" entries
create_config_with_manifest() {
    local config_repo="$1"
    shift
    # Remaining args are file paths to list in manifest

    mkdir -p "$config_repo"

    local manifest="$config_repo/template-sync-manifest.md"
    cat > "$manifest" << 'HEADER'
# Template Sync Manifest

## Tracked Files — Must Be Identical

| File | Hash (CRC32, python binascii) | Date |
|------|------|------|
HEADER

    for file_path in "$@"; do
        echo "| \`$file_path\` | \`00000000\` | 2026-03-15 |" >> "$manifest"
    done

    cat >> "$manifest" << 'FOOTER'

## Tracked Files — Intentional Diffs

| File | Hash (CRC32, python binascii) | Diff reason |
|------|------|-------------|
| `global/CLAUDE.md` | `12345678` | Personal content differs |
FOOTER
}

# ── Tests ────────────────────────────────────────────────────────────────────

# ── Skip conditions ──────────────────────────────────────────────────────────

test_skip_no_template_dir() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$config_repo" "$mock_home"
    # No agent-fleet directory exists

    create_config_with_manifest "$config_repo" "setup/lib.sh"

    local output
    output=$(run_drift_check "$config_repo" "$mock_home")

    assert_eq "" "$output" "should produce no warnings when template dir missing"
}
run_test "skip: no template directory" test_skip_no_template_dir

test_skip_no_manifest() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local template_dir="$mock_home/agent-fleet"
    mkdir -p "$config_repo" "$template_dir"
    # No manifest file

    local output
    output=$(run_drift_check "$config_repo" "$mock_home")

    assert_eq "" "$output" "should produce no warnings when manifest missing"
}
run_test "skip: no manifest file" test_skip_no_manifest

# ── Clean state (no drift) ──────────────────────────────────────────────────

test_clean_identical_files() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local template_dir="$mock_home/agent-fleet"

    create_config_with_manifest "$config_repo" "setup/lib.sh" "setup/install.sh"

    # Create identical files in both repos
    mkdir -p "$config_repo/setup" "$template_dir/setup"
    echo "shared content" > "$config_repo/setup/lib.sh"
    echo "shared content" > "$template_dir/setup/lib.sh"
    echo "install script" > "$config_repo/setup/install.sh"
    echo "install script" > "$template_dir/setup/install.sh"

    local output
    output=$(run_drift_check "$config_repo" "$mock_home")

    assert_eq "" "$output" "should produce no warnings when files are identical"
}
run_test "clean: identical files produce no warning" test_clean_identical_files

# ── Drift detection ─────────────────────────────────────────────────────────

test_drift_single_file() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local template_dir="$mock_home/agent-fleet"

    create_config_with_manifest "$config_repo" "setup/lib.sh"

    mkdir -p "$config_repo/setup" "$template_dir/setup"
    echo "personal version" > "$config_repo/setup/lib.sh"
    echo "template version" > "$template_dir/setup/lib.sh"

    local output
    output=$(run_drift_check "$config_repo" "$mock_home")

    assert_contains "$output" "PROPAGATION_DRIFT" "should warn about drift"
    assert_contains "$output" "1 file(s)" "should report count"
    assert_contains "$output" "setup/lib.sh" "should name the drifted file"
}
run_test "drift: single file difference detected" test_drift_single_file

test_drift_multiple_files() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local template_dir="$mock_home/agent-fleet"

    create_config_with_manifest "$config_repo" "setup/lib.sh" "setup/install.sh" "setup/configure-claude.sh"

    mkdir -p "$config_repo/setup" "$template_dir/setup"
    echo "personal" > "$config_repo/setup/lib.sh"
    echo "template" > "$template_dir/setup/lib.sh"
    echo "same" > "$config_repo/setup/install.sh"
    echo "same" > "$template_dir/setup/install.sh"
    echo "personal cfg" > "$config_repo/setup/configure-claude.sh"
    echo "template cfg" > "$template_dir/setup/configure-claude.sh"

    local output
    output=$(run_drift_check "$config_repo" "$mock_home")

    assert_not_contains "$output" "setup/install.sh" "should not name identical file"
    assert_contains "$output" "PROPAGATION_DRIFT" "should warn about drift"
    assert_contains "$output" "2 file(s)" "should report correct count"
    assert_contains "$output" "setup/lib.sh" "should name first drifted file"
    assert_contains "$output" "setup/configure-claude.sh" "should name second drifted file"
}
run_test "drift: multiple files, mixed identical and different" test_drift_multiple_files

# ── Edge cases ───────────────────────────────────────────────────────────────

test_file_missing_in_personal() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local template_dir="$mock_home/agent-fleet"

    create_config_with_manifest "$config_repo" "setup/lib.sh"

    # File exists only in template, not in personal
    mkdir -p "$template_dir/setup"
    echo "template" > "$template_dir/setup/lib.sh"

    local output
    output=$(run_drift_check "$config_repo" "$mock_home")

    assert_eq "" "$output" "should skip files missing in personal repo"
}
run_test "edge: file missing in personal repo — skip silently" test_file_missing_in_personal

test_file_missing_in_template() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local template_dir="$mock_home/agent-fleet"

    create_config_with_manifest "$config_repo" "setup/lib.sh"

    # File exists only in personal, not in template
    mkdir -p "$config_repo/setup" "$template_dir"
    echo "personal" > "$config_repo/setup/lib.sh"

    local output
    output=$(run_drift_check "$config_repo" "$mock_home")

    assert_eq "" "$output" "should skip files missing in template repo"
}
run_test "edge: file missing in template repo — skip silently" test_file_missing_in_template

test_intentional_diffs_not_checked() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local template_dir="$mock_home/agent-fleet"

    create_config_with_manifest "$config_repo" "setup/lib.sh"

    # setup/lib.sh is identical (in Must Be Identical)
    mkdir -p "$config_repo/setup" "$template_dir/setup"
    mkdir -p "$config_repo/global" "$template_dir/global"
    echo "same" > "$config_repo/setup/lib.sh"
    echo "same" > "$template_dir/setup/lib.sh"

    # global/CLAUDE.md differs (in Intentional Diffs — should NOT trigger warning)
    echo "personal CLAUDE" > "$config_repo/global/CLAUDE.md"
    echo "template CLAUDE" > "$template_dir/global/CLAUDE.md"

    local output
    output=$(run_drift_check "$config_repo" "$mock_home")

    assert_eq "" "$output" "should not warn about intentional diff files"
}
run_test "edge: intentional diffs section files not checked" test_intentional_diffs_not_checked

test_empty_manifest_section() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local template_dir="$mock_home/agent-fleet"
    mkdir -p "$template_dir"

    # Create manifest with empty Must Be Identical section
    mkdir -p "$config_repo"
    cat > "$config_repo/template-sync-manifest.md" << 'EOF'
# Template Sync Manifest

## Tracked Files — Must Be Identical

| File | Hash (CRC32, python binascii) | Date |
|------|------|------|

## Tracked Files — Intentional Diffs

| File | Hash (CRC32, python binascii) | Diff reason |
|------|------|-------------|
EOF

    local output
    output=$(run_drift_check "$config_repo" "$mock_home")

    assert_eq "" "$output" "should produce no warnings with empty manifest"
}
run_test "edge: empty Must Be Identical section" test_empty_manifest_section

test_template_dir_with_template_marker() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local template_dir="$mock_home/agent-fleet"

    create_config_with_manifest "$config_repo" "setup/lib.sh"

    mkdir -p "$config_repo/setup" "$template_dir/setup"
    echo "personal" > "$config_repo/setup/lib.sh"
    echo "template" > "$template_dir/setup/lib.sh"
    # Template marker should not prevent the check
    touch "$template_dir/.template-repo"

    local output
    output=$(run_drift_check "$config_repo" "$mock_home")

    assert_contains "$output" "PROPAGATION_DRIFT" "should still detect drift even with .template-repo marker"
}
run_test "edge: template with .template-repo marker still checked" test_template_dir_with_template_marker

test_deeply_nested_paths() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local template_dir="$mock_home/agent-fleet"

    create_config_with_manifest "$config_repo" "global/reference/output-rules.md"

    mkdir -p "$config_repo/global/reference" "$template_dir/global/reference"
    echo "personal rules" > "$config_repo/global/reference/output-rules.md"
    echo "template rules" > "$template_dir/global/reference/output-rules.md"

    local output
    output=$(run_drift_check "$config_repo" "$mock_home")

    assert_contains "$output" "PROPAGATION_DRIFT" "should detect drift in nested paths"
    assert_contains "$output" "global/reference/output-rules.md" "should name nested file"
}
run_test "drift: deeply nested file path" test_deeply_nested_paths

# ── CFG-613 (b): a failing propagation is its own warning, naming its age ────
# The only startup signal used to be the generic "Propagation drift detected at
# last shutdown: ...", which reads the same whether propagation is one commit
# behind or has been dead for six days. The marker SessionEnd keeps
# (.template-push-failed) now carries the streak; this check names it.

_write_fail_marker() {  # $1 config_repo, $2 days ago, $3 consecutive, $4 exit code
    local epoch=$(( $(date +%s) - $2 * 86400 - 60 ))
    cat > "$1/.template-push-failed" << EOF
time=2026-09-25 08:00:00 UTC
first_failed=2026-09-19 08:00:00 UTC
first_failed_epoch=$epoch
consecutive=$3
exit_code=$4
drift_files=12
output_tail=[ERROR]     - setup/tests/test-held-a.sh
[ERROR]     - setup/tests/test-held-b.sh
[ERROR]   Held (personal data): 2 file(s) NOT propagated (3 hit line(s)) — genericize and re-run; exit 3
EOF
}

test_failing_push_is_its_own_warning_with_age() {
    local config_repo="$TEST_TMPDIR/config-repo" mock_home="$TEST_TMPDIR/home"
    mkdir -p "$config_repo" "$mock_home"
    _write_fail_marker "$config_repo" 6 4 3

    local output; output=$(run_drift_check "$config_repo" "$mock_home")
    assert_contains "$output" "TEMPLATE_PUSH_FAILING" "a failing propagation must get its own warning tag" || return 1
    assert_contains "$output" "4 consecutive" "the warning must name the streak length" || return 1
    assert_contains "$output" "6 day(s)" "the warning must name the age" || return 1
    assert_contains "$output" "2026-09-19 08:00:00 UTC" "the warning must name when the streak began" || return 1
    assert_contains "$output" "exit=3" "the warning must carry the last exit code" || return 1
    assert_contains "$output" "setup/tests/test-held-a.sh" "held files must be named" || return 1
    assert_not_contains "$output" "PROPAGATION_DRIFT" "this is not generic drift"
}
run_test "CFG-613: a failing propagation is its own warning with streak, age and held files" test_failing_push_is_its_own_warning_with_age

test_failing_push_under_a_day_reports_hours() {
    local config_repo="$TEST_TMPDIR/config-repo" mock_home="$TEST_TMPDIR/home"
    mkdir -p "$config_repo" "$mock_home"
    _write_fail_marker "$config_repo" 0 1 1
    local output; output=$(run_drift_check "$config_repo" "$mock_home")
    assert_contains "$output" "TEMPLATE_PUSH_FAILING" || return 1
    assert_contains "$output" "hour(s)" "an age under a day is named in hours, not '0 days'" || return 1
    assert_contains "$output" "exit=1" || return 1
    assert_contains "$output" "nothing propagated" "exit 1 must be told apart from a partial hold"
}
run_test "CFG-613: a failure younger than a day is aged in hours; exit 1 reads as nothing propagated" test_failing_push_under_a_day_reports_hours

test_no_marker_no_failing_warning() {
    local config_repo="$TEST_TMPDIR/config-repo" mock_home="$TEST_TMPDIR/home"
    mkdir -p "$config_repo" "$mock_home"
    local output; output=$(run_drift_check "$config_repo" "$mock_home")
    assert_not_contains "$output" "TEMPLATE_PUSH_FAILING" "no marker, no warning"
}
run_test "CFG-613: no marker, no failing-propagation warning" test_no_marker_no_failing_warning

test_legacy_marker_still_warns() {
    local config_repo="$TEST_TMPDIR/config-repo" mock_home="$TEST_TMPDIR/home"
    mkdir -p "$config_repo" "$mock_home"
    printf 'time=2026-09-11 08:00:00 UTC\nexit_code=1\ndrift_files=3\noutput_tail=x\n' > "$config_repo/.template-push-failed"
    local output; output=$(run_drift_check "$config_repo" "$mock_home")
    assert_contains "$output" "TEMPLATE_PUSH_FAILING" "a pre-CFG-613 marker must still surface" || return 1
    assert_contains "$output" "2026-09-11 08:00:00 UTC" "it must name the failure time it has"
}
run_test "CFG-613: a pre-CFG-613 marker still surfaces as its own warning" test_legacy_marker_still_warns

# An exit 3 can hold NOTHING: a template registration whose hook the template lacks
# (CFG-664 orphan) forces 3 by itself. It must not read as "held files did not
# propagate" with no names; the orphan names are in the tail and must be carried.
test_orphan_only_exit3_names_the_orphans() {
    local config_repo="$TEST_TMPDIR/config-repo" mock_home="$TEST_TMPDIR/home"
    mkdir -p "$config_repo" "$mock_home"
    cat > "$config_repo/.template-push-failed" << EOF
time=2026-09-25 08:00:00 UTC
first_failed=2026-09-25 07:00:00 UTC
first_failed_epoch=$(( $(date +%s) - 3600 ))
consecutive=1
exit_code=3
drift_files=4
output_tail=[INFO]   Skipped (unchanged): 0
$(printf '\033[0;31m[ERROR]\033[0m')   Orphan registrations: 2 in the template's settings.json arm no hook: ghost-guard.sh, spook-guard.sh; exit 3
EOF
    local output; output=$(run_drift_check "$config_repo" "$mock_home")
    assert_contains "$output" "TEMPLATE_PUSH_FAILING" || return 1
    assert_contains "$output" "ghost-guard.sh, spook-guard.sh" "the orphan registrations must be named" || return 1
    assert_not_contains "$output" "held files did not propagate" "nothing was held — the reason must not say so"
}
run_test "CFG-664: an orphan-only exit 3 names the orphans, not held files" test_orphan_only_exit3_names_the_orphans

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
