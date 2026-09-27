#!/usr/bin/env bash
# Tests for check-project-marker.sh — the agent-fleet-managed marker must be line 1 (CFG-484)
source "$(dirname "$0")/test-helpers.sh"

suite_header "check-project-marker.sh (CFG-484: marker on line 1 of every project CLAUDE.md)"

SCRIPT="$REPO_ROOT/setup/scripts/check-project-marker.sh"
MARKER='<!-- agent-fleet-managed: DO NOT run /init — this file is configured by agent-fleet -->'

mkproj() {   # mkproj <name> <line1-or-empty> [where=root|dotclaude]
    local dir="$TEST_TMPDIR/$1" f
    mkdir -p "$dir/.claude"
    f="$dir/CLAUDE.md"; [[ "${3:-root}" == dotclaude ]] && f="$dir/.claude/CLAUDE.md"
    { [[ -n "$2" ]] && printf '%s\n' "$2"; printf '# %s\n\nBody.\n' "$1"; } > "$f"
    printf '%s' "$dir"
}

run_check() { bash "$SCRIPT" "$@" > "$TEST_TMPDIR/out.log" 2>&1; }

test_marker_on_line_one_passes() {
    local d; d=$(mkproj good "$MARKER")
    run_check "$d" || { cat "$TEST_TMPDIR/out.log"; return 1; }
}
run_test "marker on line 1: passes" test_marker_on_line_one_passes

test_missing_marker_fails() {
    local d; d=$(mkproj bare "")
    assert_failure run_check "$d" || return 1
    assert_file_contains "$TEST_TMPDIR/out.log" "$d" || return 1
    assert_file_contains "$TEST_TMPDIR/out.log" "^MISSING .*no agent-fleet-managed marker"
}
run_test "no marker: fails and names the project" test_missing_marker_fails

test_marker_not_on_line_one_fails() {
    # The marker somewhere in the file satisfies the /init guard's grep but not the contract.
    local d; d=$(mkproj late "")
    printf '%s\n' "$MARKER" >> "$d/CLAUDE.md"
    assert_failure run_check "$d" || return 1
    assert_file_contains "$TEST_TMPDIR/out.log" "line 4"
}
run_test "marker present but not on line 1: fails, says where it is" test_marker_not_on_line_one_fails

test_dotclaude_location_is_honoured() {
    local d; d=$(mkproj nested "$MARKER" dotclaude)
    run_check "$d" || { cat "$TEST_TMPDIR/out.log"; return 1; }
}
run_test "CLAUDE.md under .claude/ is checked too" test_dotclaude_location_is_honoured

test_no_claude_md_fails() {
    mkdir -p "$TEST_TMPDIR/empty"
    assert_failure run_check "$TEST_TMPDIR/empty" || return 1
    assert_file_contains "$TEST_TMPDIR/out.log" "no CLAUDE.md"
}
run_test "a project without any CLAUDE.md fails" test_no_claude_md_fails

test_check_never_writes() {
    local d; d=$(mkproj bare "")
    cp "$d/CLAUDE.md" "$TEST_TMPDIR/before"
    run_check "$d" || true
    cmp -s "$TEST_TMPDIR/before" "$d/CLAUDE.md" || { echo "    the check modified CLAUDE.md"; return 1; }
}
run_test "the check is read-only" test_check_never_writes

test_registry_mode() {
    mkproj good "$MARKER" >/dev/null
    mkproj bare "" >/dev/null
    cat > "$TEST_TMPDIR/registry.md" << 'EOF'
# Project Registry

## Projects

| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
| good | P1 | — | `~/good` | private | all | code | active | |
| bare | P2 | good | `~/bare` | private | all | code | active | |
| elsewhere | P3 | — | `~/not-on-this-machine` | private | other | code | active | |

## Machines

| Machine | Platform | Home | Location | Notes |
|---------|----------|------|----------|-------|
| box | Linux | `~/` | `~/bare` | its 4th cell sits where a project's Path is, and is a real path |
EOF
    local rc=0
    HOME="$TEST_TMPDIR" bash "$SCRIPT" --registry "$TEST_TMPDIR/registry.md" > "$TEST_TMPDIR/out.log" 2>&1 || rc=$?
    assert_eq "1" "$rc" "exit 1 when a registered project fails" || return 1
    assert_file_contains "$TEST_TMPDIR/out.log" "bare" || return 1
    assert_file_not_contains "$TEST_TMPDIR/out.log" "MISSING $TEST_TMPDIR/good" || return 1
    assert_file_not_contains "$TEST_TMPDIR/out.log" "not-on-this-machine" "absent projects are skipped, not failed" || return 1
    assert_grep_count "$TEST_TMPDIR/out.log" "^MISSING" 1 "the Machines table is not read as projects"
}
run_test "--registry: checks every registered project present here" test_registry_mode

test_templates_carry_the_marker() {
    local t bad=""
    for t in "$REPO_ROOT"/setup/projects/_templates/*/CLAUDE.md.template; do
        [[ -f "$t" ]] || continue
        head -1 "$t" | grep -q 'agent-fleet-managed' || bad="$bad $t"
    done
    assert_eq "" "$bad" "every project template must start with the marker"
}
run_test "every CLAUDE.md template starts with the marker" test_templates_carry_the_marker

suite_summary
