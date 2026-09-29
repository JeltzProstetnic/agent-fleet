#!/usr/bin/env bash
# Tests for check 26: decisions.md monthly review due (CFG-637)
# Rule (foundation/session-protocol.md Layer 3b, owner-approved 2026-09-29): review
# docs/decisions.md monthly, dated by its "Last reviewed:" line. The check makes the
# review fire mechanically at 0 tokens instead of relying on recall. TDD: written first.
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/test-check-helpers.sh"

suite_header "config-check.sh: decisions.md review due (check 26)"

_dr_setup() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir/docs"
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    create_mock_plugin_files "$mock_home"
    create_patched_script "$config_repo" "$mock_home" "$project_dir"
}

_dr_field() {
    printf '%s' "$1" | grep -oE 'DECISIONS_REVIEW_DUE:[^|]*' | head -1
}

_dr_decisions() {   # <Last reviewed line or empty>
    {
        echo '# Decisions & Requirements — test'
        [ -n "$1" ] && echo "$1"
        echo
        echo '## 2026-01-01 — test — something'
    } > "$TEST_TMPDIR/project/docs/decisions.md"
}

test_recent_review_is_silent() {
    local patched; patched=$(_dr_setup)
    _dr_decisions "Last reviewed: $(date +%Y-%m-%d)"
    local output
    output=$(run_hook "$patched")
    assert_not_contains "$output" "DECISIONS_REVIEW_DUE" "reviewed today → silent"
}
run_test "check 26: a review within 30 days stays silent" test_recent_review_is_silent

test_old_review_is_due_with_age() {
    local patched; patched=$(_dr_setup)
    local d; d=$(date -d '-40 days' +%Y-%m-%d)
    _dr_decisions "Last reviewed: $d"
    local output field
    output=$(run_hook "$patched")
    field=$(_dr_field "$output")
    assert_contains "$field" "DECISIONS_REVIEW_DUE" "40 days old → due (measured field: '$field')" || return 1
    assert_contains "$field" "$d" "names the last review date"
    assert_contains "$field" "40 days" "states the age"
    assert_contains "$field" "decisions-archive.md" "says where superseded entries go"
}
run_test "check 26: a review older than 30 days is due, with date and age" test_old_review_is_due_with_age

test_missing_line_is_due_never() {
    local patched; patched=$(_dr_setup)
    _dr_decisions ""
    local output field
    output=$(run_hook "$patched")
    field=$(_dr_field "$output")
    assert_contains "$field" "never" "no Last reviewed line → due, 'never' (measured field: '$field')"
}
run_test "check 26: no 'Last reviewed:' line means the review is due" test_missing_line_is_due_never

test_unparseable_date_is_due() {
    local patched; patched=$(_dr_setup)
    _dr_decisions "Last reviewed: sometime last spring"
    local output field
    output=$(run_hook "$patched")
    field=$(_dr_field "$output")
    assert_contains "$field" "DECISIONS_REVIEW_DUE" "unreadable date → due, never silently fresh (measured field: '$field')"
}
run_test "check 26: an unreadable date counts as due" test_unparseable_date_is_due

test_no_decisions_file_is_silent() {
    local patched; patched=$(_dr_setup)
    rm -f "$TEST_TMPDIR/project/docs/decisions.md"
    local output
    output=$(run_hook "$patched")
    assert_not_contains "$output" "DECISIONS_REVIEW_DUE" "project without decisions.md → silent"
}
run_test "check 26: a project without docs/decisions.md stays silent" test_no_decisions_file_is_silent

test_real_repo_file_parses() {
    # Pattern 11: at least one test reads a real artifact, not only a fixture.
    local real="$REPO_ROOT/docs/decisions.md"
    [[ -f "$real" ]] || { skip_test "real decisions.md" "not present in this checkout"; return 0; }
    local line
    line=$(grep -m1 -E '^Last reviewed: [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$real" || true)
    assert_contains "$line" "Last reviewed: " "this repo's own decisions.md carries a parseable 'Last reviewed:' line (measured: '$line')"
}
run_test "check 26: this repo's real decisions.md has a parseable line" test_real_repo_file_parses

suite_summary
