#!/usr/bin/env bash
# Tests for fleet-issue.sh — privacy scrubbing, dedup, formatting, recording
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/fleet-issue.sh"

suite_header "fleet-issue.sh"

# ══════════════════════════════════════════════════════════════════════════════
# Privacy Scrubber Tests (scrub_check / --scrub)
# ══════════════════════════════════════════════════════════════════════════════

# NOTE: These tests use the placeholder pattern. After customizing your
# PRIVACY_PATTERNS in fleet-issue.sh, add tests for your actual patterns.

test_scrub_catches_placeholder_pattern() {
    local body="$TEST_TMPDIR/body.md"
    echo "Found CUSTOMIZE_PRIVACY_PATTERNS in the output" > "$body"
    local out rc=0
    out=$(bash "$SCRIPT" --scrub "$body" 2>&1) || rc=$?
    assert_eq "1" "$rc" "should exit 1 on placeholder pattern match"
    assert_contains "$out" "CUSTOMIZE_PRIVACY_PATTERNS"
}
run_test "scrub catches placeholder pattern" test_scrub_catches_placeholder_pattern

# ── Clean content passes ─────────────────────────────────────────────────────

test_scrub_passes_clean_content() {
    local body="$TEST_TMPDIR/body.md"
    cat > "$body" << 'EOF'
## Description
The session hook does not detect when a symlink target is missing.
This causes silent failures during startup.

## Reproduction
1. Remove a target file that a symlink points to
2. Run the session start hook
3. No error is reported

## Proposed Solution
Add a symlink target validation step to config-check.sh.
EOF
    local out rc=0
    out=$(bash "$SCRIPT" --scrub "$body" 2>&1) || rc=$?
    assert_eq "0" "$rc" "clean content should pass scrub"
}
run_test "scrub passes clean content with no personal data" test_scrub_passes_clean_content

# ── Missing body file ────────────────────────────────────────────────────────

test_scrub_missing_file() {
    local out rc=0
    out=$(bash "$SCRIPT" --scrub "$TEST_TMPDIR/nonexistent.md" 2>&1) || rc=$?
    assert_eq "1" "$rc" "should exit 1 on missing file"
    assert_contains "$out" "not found"
}
run_test "scrub exits 1 when body file does not exist" test_scrub_missing_file

# ══════════════════════════════════════════════════════════════════════════════
# Dedup Tests (dedup_check)
# ══════════════════════════════════════════════════════════════════════════════

test_dedup_detects_exact_match() {
    local index="$TEST_TMPDIR/.fleet-issues.jsonl"
    echo '{"title":"Hook fails on missing symlink","number":42,"date":"2026-03-12"}' > "$index"
    local out rc=0
    out=$(bash "$SCRIPT" --dedup "Hook fails on missing symlink" "$index" 2>&1) || rc=$?
    assert_eq "2" "$rc" "should exit 2 on exact title match"
    assert_contains "$out" "duplicate"
}
run_test "dedup detects exact title match" test_dedup_detects_exact_match

test_dedup_detects_fuzzy_match() {
    local index="$TEST_TMPDIR/.fleet-issues.jsonl"
    echo '{"title":"Hook fails on missing symlink target","number":42,"date":"2026-03-12"}' > "$index"
    local out rc=0
    out=$(bash "$SCRIPT" --dedup "Hook fails on missing symlink" "$index" 2>&1) || rc=$?
    assert_eq "2" "$rc" "should exit 2 on fuzzy (substring) title match"
    assert_contains "$out" "duplicate"
}
run_test "dedup detects fuzzy (substring) match" test_dedup_detects_fuzzy_match

test_dedup_passes_no_match() {
    local index="$TEST_TMPDIR/.fleet-issues.jsonl"
    echo '{"title":"Completely different issue","number":42,"date":"2026-03-12"}' > "$index"
    local out rc=0
    out=$(bash "$SCRIPT" --dedup "Hook fails on missing symlink" "$index" 2>&1) || rc=$?
    assert_eq "0" "$rc" "should exit 0 when no title match"
}
run_test "dedup passes when no title match exists" test_dedup_passes_no_match

test_dedup_passes_empty_index() {
    local index="$TEST_TMPDIR/.fleet-issues.jsonl"
    touch "$index"
    local out rc=0
    out=$(bash "$SCRIPT" --dedup "New issue title" "$index" 2>&1) || rc=$?
    assert_eq "0" "$rc" "should exit 0 on empty index"
}
run_test "dedup passes on empty index file" test_dedup_passes_empty_index

test_dedup_passes_missing_index() {
    local out rc=0
    out=$(bash "$SCRIPT" --dedup "New issue title" "$TEST_TMPDIR/nonexistent.jsonl" 2>&1) || rc=$?
    assert_eq "0" "$rc" "should exit 0 when index file does not exist"
}
run_test "dedup passes when index file does not exist" test_dedup_passes_missing_index

test_dedup_case_insensitive() {
    local index="$TEST_TMPDIR/.fleet-issues.jsonl"
    echo '{"title":"Hook Fails On Missing Symlink","number":42,"date":"2026-03-12"}' > "$index"
    local out rc=0
    out=$(bash "$SCRIPT" --dedup "hook fails on missing symlink" "$index" 2>&1) || rc=$?
    assert_eq "2" "$rc" "should exit 2 on case-insensitive match"
}
run_test "dedup is case-insensitive" test_dedup_case_insensitive

# ══════════════════════════════════════════════════════════════════════════════
# Record Tests (record_issue via --record)
# ══════════════════════════════════════════════════════════════════════════════

test_record_creates_new_index() {
    local index="$TEST_TMPDIR/.fleet-issues.jsonl"
    assert_file_not_exists "$index"
    local out rc=0
    out=$(bash "$SCRIPT" --record "Test issue title" "99" "$index" 2>&1) || rc=$?
    assert_eq "0" "$rc" "record should succeed"
    assert_file_exists "$index"
    assert_file_contains "$index" '"title":"Test issue title"'
    assert_file_contains "$index" '"number":99'
}
run_test "record creates new JSONL index file" test_record_creates_new_index

test_record_appends_to_existing() {
    local index="$TEST_TMPDIR/.fleet-issues.jsonl"
    echo '{"title":"First issue","number":1,"date":"2026-03-01"}' > "$index"
    local out rc=0
    out=$(bash "$SCRIPT" --record "Second issue" "2" "$index" 2>&1) || rc=$?
    assert_eq "0" "$rc" "record should succeed"
    assert_line_count "$index" 2
    assert_file_contains "$index" '"title":"Second issue"'
    assert_file_contains "$index" '"title":"First issue"'
}
run_test "record appends to existing JSONL index" test_record_appends_to_existing

test_record_includes_date() {
    local index="$TEST_TMPDIR/.fleet-issues.jsonl"
    local out rc=0
    out=$(bash "$SCRIPT" --record "Dated issue" "55" "$index" 2>&1) || rc=$?
    assert_eq "0" "$rc" "record should succeed"
    local today
    today=$(date +%Y-%m-%d)
    assert_file_contains "$index" "\"date\":\"$today\""
}
run_test "record includes current date in JSONL entry" test_record_includes_date

# ══════════════════════════════════════════════════════════════════════════════
# Format Tests (--format)
# ══════════════════════════════════════════════════════════════════════════════

test_format_produces_valid_markdown() {
    local body="$TEST_TMPDIR/body.md"
    echo "The session hook silently fails when a symlink target is missing." > "$body"
    local out rc=0
    out=$(bash "$SCRIPT" --format "Hook silent failure" "bug" "medium" "$body" 2>&1) || rc=$?
    assert_eq "0" "$rc" "format should succeed on clean content"
    assert_contains "$out" "## Description"
    assert_contains "$out" "## Context"
    assert_contains "$out" "## Reproduction / Rationale"
    assert_contains "$out" "## Proposed Solution"
    assert_contains "$out" "Fleet Metadata"
    assert_contains "$out" "**Category:** bug"
    assert_contains "$out" "**Severity:** medium"
}
run_test "format produces valid markdown with all sections" test_format_produces_valid_markdown

test_format_includes_config_version_hash() {
    local body="$TEST_TMPDIR/body.md"
    echo "Clean issue description." > "$body"
    local out rc=0
    out=$(bash "$SCRIPT" --format "Hash test" "improvement" "low" "$body" 2>&1) || rc=$?
    assert_eq "0" "$rc" "format should succeed"
    assert_contains "$out" "Config version:"
}
run_test "format includes config version hash in metadata" test_format_includes_config_version_hash

test_format_includes_date() {
    local body="$TEST_TMPDIR/body.md"
    echo "Clean issue description." > "$body"
    local out rc=0
    out=$(bash "$SCRIPT" --format "Date test" "docs" "low" "$body" 2>&1) || rc=$?
    assert_eq "0" "$rc" "format should succeed"
    assert_contains "$out" "Session:"
    local today
    today=$(date +%Y-%m-%d)
    assert_contains "$out" "$today"
}
run_test "format includes session date in metadata" test_format_includes_date

test_format_rejects_dirty_body() {
    local body="$TEST_TMPDIR/body.md"
    echo "Found CUSTOMIZE_PRIVACY_PATTERNS in the output" > "$body"
    local out rc=0
    out=$(bash "$SCRIPT" --format "Dirty issue" "bug" "high" "$body" 2>&1) || rc=$?
    assert_eq "1" "$rc" "format should exit 1 on dirty body (privacy violation)"
}
run_test "format rejects body that fails privacy scrub" test_format_rejects_dirty_body

test_format_missing_body_file() {
    local out rc=0
    out=$(bash "$SCRIPT" --format "No body" "bug" "high" "$TEST_TMPDIR/missing.md" 2>&1) || rc=$?
    assert_eq "1" "$rc" "format should exit 1 on missing body"
    assert_contains "$out" "not found"
}
run_test "format exits 1 when body file is missing" test_format_missing_body_file

# ══════════════════════════════════════════════════════════════════════════════
# Main Entry Point / Exit Code Tests
# ══════════════════════════════════════════════════════════════════════════════

test_no_args_shows_usage() {
    local out rc=0
    out=$(bash "$SCRIPT" 2>&1) || rc=$?
    assert_eq "1" "$rc" "no args should exit 1"
    assert_contains "$out" "Usage"
}
run_test "no arguments shows usage and exits 1" test_no_args_shows_usage

test_unknown_command_shows_usage() {
    local out rc=0
    out=$(bash "$SCRIPT" --unknown 2>&1) || rc=$?
    assert_eq "1" "$rc" "unknown command should exit 1"
    assert_contains "$out" "Usage"
}
run_test "unknown command shows usage and exits 1" test_unknown_command_shows_usage

test_scrub_exit_0_on_clean() {
    local body="$TEST_TMPDIR/body.md"
    echo "This is a perfectly clean issue body with no personal data." > "$body"
    assert_exit_code 0 bash "$SCRIPT" --scrub "$body"
}
run_test "scrub exits 0 on clean content" test_scrub_exit_0_on_clean

test_scrub_exit_1_on_violation() {
    local body="$TEST_TMPDIR/body.md"
    echo "Found CUSTOMIZE_PRIVACY_PATTERNS marker" > "$body"
    assert_exit_code 1 bash "$SCRIPT" --scrub "$body"
}
run_test "scrub exits 1 on privacy violation" test_scrub_exit_1_on_violation

test_dedup_exit_2_on_duplicate() {
    local index="$TEST_TMPDIR/.fleet-issues.jsonl"
    echo '{"title":"Duplicate issue","number":1,"date":"2026-03-12"}' > "$index"
    assert_exit_code 2 bash "$SCRIPT" --dedup "Duplicate issue" "$index"
}
run_test "dedup exits 2 on duplicate found" test_dedup_exit_2_on_duplicate

test_dedup_exit_0_on_no_duplicate() {
    local index="$TEST_TMPDIR/.fleet-issues.jsonl"
    echo '{"title":"Something else","number":1,"date":"2026-03-12"}' > "$index"
    assert_exit_code 0 bash "$SCRIPT" --dedup "Completely unique issue" "$index"
}
run_test "dedup exits 0 on no duplicate" test_dedup_exit_0_on_no_duplicate

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════

suite_summary
