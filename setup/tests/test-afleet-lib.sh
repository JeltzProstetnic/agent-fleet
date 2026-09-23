#!/usr/bin/env bash
# Tests for setup/scripts/afleet-lib.sh — shared library for agent fleet launcher
# Tests pure utility functions: registry parsing, dashboard cache parsing,
# display list building, selection resolution. Skips TUI/interactive functions.
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/afleet-lib.sh"

suite_header "afleet-lib.sh (shared library functions)"

# ── Basic Validation ─────────────────────────────────────────────────────────

test_script_exists() {
    assert_file_exists "$SCRIPT"
}
run_test "script exists" test_script_exists

test_shebang() {
    local first_line
    first_line=$(head -1 "$SCRIPT")
    assert_eq "#!/usr/bin/env bash" "$first_line"
}
run_test "has correct shebang" test_shebang

test_not_executable_directly() {
    # afleet-lib.sh says "not meant to be executed directly" — verify it's a library
    assert_file_contains "$SCRIPT" "Sourced by" "should indicate it is sourced, not executed"
}
run_test "documents that it is sourced, not executed directly" test_not_executable_directly

# ── Helper to source the library with required globals ───────────────────────

# Source afleet-lib.sh in a subshell with necessary variables set
# Usage: source_lib <registry_path> <dashboard_cache_path> <config_repo_path>
source_lib_and_run() {
    local registry="$1" cache="$2" config_repo="$3"
    shift 3
    (
        export NO_COLOR=1
        export REGISTRY="$registry"
        export DASHBOARD_CACHE="$cache"
        export CONFIG_REPO="$config_repo"
        export INBOX_FILE="$config_repo/cross-project/inbox.md"
        source "$SCRIPT"
        "$@"
    )
}

# ── parse_registry tests ────────────────────────────────────────────────────

test_parse_registry_basic() {
    local reg="$TEST_TMPDIR/registry.md"
    cat > "$reg" << 'EOF'
# Project Registry

## Projects

| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
| cfg-agent-fleet | P1 | — | `~/cfg-agent-fleet` | | all | meta | active | Config |
| social | P2 | — | `~/social` | | wsl | web | active | Social |
EOF

    local output
    output=$(source_lib_and_run "$reg" "/dev/null" "$TEST_TMPDIR" parse_registry)

    assert_contains "$output" "cfg-agent-fleet|" "should parse first project"
    assert_contains "$output" "social|" "should parse second project"
    assert_contains "$output" "$HOME/cfg-agent-fleet" "should expand ~ to HOME"
    assert_contains "$output" "$HOME/social" "should expand ~ for social"
}
run_test "parse_registry extracts name|path from registry.md" test_parse_registry_basic

test_parse_registry_skips_headers() {
    local reg="$TEST_TMPDIR/registry.md"
    cat > "$reg" << 'EOF'
| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
| cfg | P1 | — | `~/cfg` | | all | meta | active | Config |
EOF

    local output
    output=$(source_lib_and_run "$reg" "/dev/null" "$TEST_TMPDIR" parse_registry)
    local line_count
    line_count=$(echo "$output" | grep -c '|')

    assert_eq "1" "$line_count" "should only parse data rows, not headers"
}
run_test "parse_registry skips header and separator rows" test_parse_registry_skips_headers

test_parse_registry_missing_creates_minimal() {
    local reg="$TEST_TMPDIR/no-such-registry.md"

    local output
    output=$(source_lib_and_run "$reg" "/dev/null" "$TEST_TMPDIR" parse_registry 2>&1)

    assert_file_exists "$reg" "should auto-create registry"
    assert_file_contains "$reg" "Project Registry" "auto-created registry should have header"
}
run_test "parse_registry auto-creates minimal registry when missing" test_parse_registry_missing_creates_minimal

test_parse_registry_empty_on_first_run() {
    local config="$TEST_TMPDIR/config"
    mkdir -p "$config"
    touch "$config/.setup-pending"
    local reg="$config/registry.md"

    local output
    output=$(source_lib_and_run "$reg" "/dev/null" "$config" parse_registry)

    # Should return empty (no error) when .setup-pending exists
    assert_eq "" "$output" "should return empty on first run"
}
run_test "parse_registry returns empty during first run" test_parse_registry_empty_on_first_run

# ── parse_dashboard_cache tests ──────────────────────────────────────────────

test_parse_dashboard_cache_basic() {
    local cache="$TEST_TMPDIR/dashboard-cache.md"
    cat > "$cache" << 'EOF'
| Project | Priority | Parent | Path | Type | Tasks | Size | Machines | P1 Names | Last Done |
|---------|----------|--------|------|------|-------|------|----------|----------|-----------|
| cfg-agent-fleet | P1 | — | `~/cfg-agent-fleet` | meta | 3/12 | 2.1M | all | CFG-1; CFG-2 | 2026-04-10 |
| social | P2 | — | `~/social` | web | 1/5 | 500K | wsl | SOC-1 | 2026-04-09 |
EOF

    local output
    output=$(source_lib_and_run "/dev/null" "$cache" "$TEST_TMPDIR" parse_dashboard_cache)

    assert_contains "$output" "cfg-agent-fleet|P1|" "should parse project with priority"
    assert_contains "$output" "social|P2|" "should parse second project"
    assert_contains "$output" "3/12" "should include task counts"
    assert_contains "$output" "CFG-1; CFG-2" "should include P1 names"
}
run_test "parse_dashboard_cache extracts project data" test_parse_dashboard_cache_basic

test_parse_dashboard_cache_missing_file() {
    local output
    output=$(source_lib_and_run "/dev/null" "$TEST_TMPDIR/no-cache.md" "$TEST_TMPDIR" parse_dashboard_cache 2>&1)
    local rc=$?

    assert_neq "0" "$rc" "should fail when cache missing"
    assert_contains "$output" "Error" "should report error"
}
run_test "parse_dashboard_cache fails gracefully when file missing" test_parse_dashboard_cache_missing_file

# ── build_display_list tests ─────────────────────────────────────────────────

test_build_display_list_numbers_parents() {
    local cache="$TEST_TMPDIR/dashboard-cache.md"
    cat > "$cache" << 'EOF'
| Project | Priority | Parent | Path | Type | Tasks | Size | Machines | P1 Names | Last Done |
|---------|----------|--------|------|------|-------|------|----------|----------|-----------|
| alpha | P1 | — | `~/alpha` | meta | 3/12 | 1M | all | A-1 | 2026-04-10 |
| beta | P2 | — | `~/beta` | web | 1/5 | 500K | wsl | B-1 | 2026-04-09 |
EOF

    local output
    output=$(source_lib_and_run "/dev/null" "$cache" "$TEST_TMPDIR" bash -c '
        source "'"$SCRIPT"'"
        parse_dashboard_cache | build_display_list
    ')

    # First parent should get label "1", second "2"
    local first_line
    first_line=$(echo "$output" | head -1)
    assert_contains "$first_line" "1|alpha" "first parent should be labeled 1"

    local second_line
    second_line=$(echo "$output" | sed -n '2p')
    assert_contains "$second_line" "2|beta" "second parent should be labeled 2"
}
run_test "build_display_list assigns numbers to parents" test_build_display_list_numbers_parents

test_build_display_list_children_get_letters() {
    local cache="$TEST_TMPDIR/dashboard-cache.md"
    cat > "$cache" << 'EOF'
| Project | Priority | Parent | Path | Type | Tasks | Size | Machines | P1 Names | Last Done |
|---------|----------|--------|------|------|-------|------|----------|----------|-----------|
| parent | P1 | — | `~/parent` | meta | 3/12 | 1M | all | P-1 | 2026-04-10 |
| child1 | P1 | parent | `~/child1` | web | 1/5 | 500K | wsl | C-1 | 2026-04-09 |
| child2 | P2 | parent | `~/child2` | web | 0/3 | 200K | wsl | — | 2026-04-08 |
EOF

    local output
    output=$(source_lib_and_run "/dev/null" "$cache" "$TEST_TMPDIR" bash -c '
        export NO_COLOR=1
        export REGISTRY="/dev/null"
        export DASHBOARD_CACHE="'"$cache"'"
        export CONFIG_REPO="'"$TEST_TMPDIR"'"
        source "'"$SCRIPT"'"
        parse_dashboard_cache | build_display_list
    ')

    # Children nested under parent should get letters
    assert_contains "$output" "a|child1" "first child should be labeled 'a'"
}
run_test "build_display_list assigns letters to children" test_build_display_list_children_get_letters

test_build_display_list_excludes_p4p5() {
    local cache="$TEST_TMPDIR/dashboard-cache.md"
    cat > "$cache" << 'EOF'
| Project | Priority | Parent | Path | Type | Tasks | Size | Machines | P1 Names | Last Done |
|---------|----------|--------|------|------|-------|------|----------|----------|-----------|
| active | P1 | — | `~/active` | meta | 1/1 | 1M | all | — | 2026-04-10 |
| paused | P4 | — | `~/paused` | web | 0/0 | 100K | wsl | — | 2026-03-01 |
| dormant | P5 | — | `~/dormant` | web | 0/0 | 50K | wsl | — | 2026-01-01 |
EOF

    local output
    output=$(source_lib_and_run "/dev/null" "$cache" "$TEST_TMPDIR" bash -c '
        export NO_COLOR=1
        export REGISTRY="/dev/null"
        export DASHBOARD_CACHE="'"$cache"'"
        export CONFIG_REPO="'"$TEST_TMPDIR"'"
        export PICKER_SHOW_ALL=0
        source "'"$SCRIPT"'"
        parse_dashboard_cache | build_display_list
    ')

    assert_contains "$output" "active" "should include P1 projects"
    assert_not_contains "$output" "paused" "should exclude P4 by default"
    assert_not_contains "$output" "dormant" "should exclude P5 by default"
}
run_test "build_display_list excludes P4-P5 by default" test_build_display_list_excludes_p4p5

test_build_display_list_includes_p4p5_with_show_all() {
    local cache="$TEST_TMPDIR/dashboard-cache.md"
    cat > "$cache" << 'EOF'
| Project | Priority | Parent | Path | Type | Tasks | Size | Machines | P1 Names | Last Done |
|---------|----------|--------|------|------|-------|------|----------|----------|-----------|
| active | P1 | — | `~/active` | meta | 1/1 | 1M | all | — | 2026-04-10 |
| paused | P4 | — | `~/paused` | web | 0/0 | 100K | wsl | — | 2026-03-01 |
EOF

    local output
    output=$(source_lib_and_run "/dev/null" "$cache" "$TEST_TMPDIR" bash -c '
        export NO_COLOR=1
        export REGISTRY="/dev/null"
        export DASHBOARD_CACHE="'"$cache"'"
        export CONFIG_REPO="'"$TEST_TMPDIR"'"
        export PICKER_SHOW_ALL=1
        source "'"$SCRIPT"'"
        parse_dashboard_cache | build_display_list
    ')

    assert_contains "$output" "paused" "should include P4 when PICKER_SHOW_ALL=1"
}
run_test "build_display_list includes P4-P5 with PICKER_SHOW_ALL=1" test_build_display_list_includes_p4p5_with_show_all

# ── resolve_selection tests ──────────────────────────────────────────────────

test_resolve_selection_by_number() {
    local input="1|alpha|meta|3/12|1M|P1|0|—|/home/test/alpha|A-1
2|beta|web|1/5|500K|P2|0|—|/home/test/beta|B-1"

    local output
    output=$(echo "$input" | (
        export NO_COLOR=1
        source "$SCRIPT"
        resolve_selection "2"
    ))

    assert_eq "beta|/home/test/beta" "$output" "should resolve number 2 to beta"
}
run_test "resolve_selection finds project by number label" test_resolve_selection_by_number

test_resolve_selection_by_letter() {
    local input="1|parent|meta|3/12|1M|P1|0|—|/home/test/parent|P-1
a|child|web|1/5|500K|P1|1|parent|/home/test/child|C-1"

    local output
    output=$(echo "$input" | (
        export NO_COLOR=1
        source "$SCRIPT"
        resolve_selection "a"
    ))

    assert_eq "child|/home/test/child" "$output" "should resolve letter 'a' to child"
}
run_test "resolve_selection finds project by letter label" test_resolve_selection_by_letter

test_resolve_selection_not_found() {
    local input="1|alpha|meta|3/12|1M|P1|0|—|/home/test/alpha|A-1"

    local output rc=0
    output=$(echo "$input" | (
        export NO_COLOR=1
        source "$SCRIPT"
        resolve_selection "99"
    )) || rc=$?

    assert_neq "0" "$rc" "should return non-zero for unknown selection"
}
run_test "resolve_selection returns non-zero for unknown label" test_resolve_selection_not_found

# ── Color handling ───────────────────────────────────────────────────────────

test_no_color_support() {
    # When NO_COLOR=1, all color variables should be empty
    local output
    output=$(
        export NO_COLOR=1
        source "$SCRIPT"
        echo "RED=${C_RED}END"
    )
    assert_eq "RED=END" "$output" "colors should be empty when NO_COLOR=1"
}
run_test "respects NO_COLOR=1 environment variable" test_no_color_support

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
