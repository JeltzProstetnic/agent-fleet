#!/usr/bin/env bash
# Tests for setup/scripts/lib-dashboard.sh — the backlog summariser lsd-refresh.sh and
# dashboard-row.sh --auto share (CFG-1093 P-SHUTDOWN), and the dir → project lookup that
# session-close.sh uses. One summariser for both writers, so the row a session writes at
# shutdown and the row the next lsd-refresh computes cannot disagree.
source "$(dirname "$0")/test-helpers.sh"

LIB="$REPO_ROOT/setup/scripts/lib-dashboard.sh"

suite_header "lib-dashboard.sh (CFG-1093: shared dashboard helpers)"

_cache() {
    cat > "$TEST_TMPDIR/cache.md" <<EOF
# Dashboard Cache

| Project | Priority | Parent | Path | Type | Tasks | Size | Deadline | P1Names | LastDone |
|---------|----------|--------|------|------|-------|------|----------|---------|----------|
| alpha | P1 | — | \`~/alpha\` | code | — | 1M |  |  |  |
| alpha-two | P3 | alpha | ~/alpha-two | code | — | 1M |  |  |  |
| abs | P2 | — | $TEST_TMPDIR/home/abs | code | — | 1M |  |  |  |
EOF
}

t_summarise_counts_open_by_priority() {
    cat > "$TEST_TMPDIR/backlog.md" <<'EOF'
# Backlog
- [ ] [P1] `A-1` **First thing**: x
- [>] [P2] `A-2` y
- [?] [P2] `A-3` z
- [ ] `A-4` untagged
## Done
- [x] [P1] `A-0` old
EOF
    local out
    out=$( source "$LIB"; summarise_backlog "$TEST_TMPDIR/backlog.md" )
    assert_eq "1P1 2P2 1P3" "$(sed -n 1p <<<"$out")" "tasks line" || return 1
    assert_eq "First thing" "$(sed -n 3p <<<"$out")" "P1 names line"
}
run_test "summarise_backlog counts open items by priority (untagged → P3)" t_summarise_counts_open_by_priority

t_summarise_nothing_open() {
    printf '# Backlog\n## Done\n- [x] [P1] `A-0` shipped it\n' > "$TEST_TMPDIR/backlog.md"
    local out
    out=$( source "$LIB"; summarise_backlog "$TEST_TMPDIR/backlog.md" )
    assert_eq "—" "$(sed -n 1p <<<"$out")" "no open items" || return 1
    assert_contains "$(sed -n 4p <<<"$out")" "shipped it" "last done shown when nothing is open"
}
run_test "summarise_backlog with nothing open shows a dash and the last done item" t_summarise_nothing_open

t_project_for_dir_tilde_and_backticks() {
    mkdir -p "$TEST_TMPDIR/home/alpha" "$TEST_TMPDIR/home/alpha-two"
    _cache
    local out
    out=$( HOME="$TEST_TMPDIR/home"; source "$LIB"; dashboard_project_for_dir "$TEST_TMPDIR/cache.md" "$TEST_TMPDIR/home/alpha" )
    assert_eq "alpha" "$out" "~ and backticks in the Path cell resolve"
}
run_test "dashboard_project_for_dir resolves a ~/ path in backticks" t_project_for_dir_tilde_and_backticks

t_project_for_dir_exact_not_prefix() {
    mkdir -p "$TEST_TMPDIR/home/alpha" "$TEST_TMPDIR/home/alpha-two"
    _cache
    local out
    out=$( HOME="$TEST_TMPDIR/home"; source "$LIB"; dashboard_project_for_dir "$TEST_TMPDIR/cache.md" "$TEST_TMPDIR/home/alpha-two/" )
    assert_eq "alpha-two" "$out" "alpha-two, not alpha"
}
run_test "dashboard_project_for_dir matches the whole path, not a prefix" t_project_for_dir_exact_not_prefix

t_project_for_dir_absolute() {
    mkdir -p "$TEST_TMPDIR/home/abs"
    _cache
    local out
    out=$( HOME="$TEST_TMPDIR/home"; source "$LIB"; dashboard_project_for_dir "$TEST_TMPDIR/cache.md" "$TEST_TMPDIR/home/abs" )
    assert_eq "abs" "$out" "an absolute Path cell resolves"
}
run_test "dashboard_project_for_dir resolves an absolute path" t_project_for_dir_absolute

t_project_for_dir_unknown() {
    mkdir -p "$TEST_TMPDIR/home/other"
    _cache
    local rc=0 out
    out=$( HOME="$TEST_TMPDIR/home"; source "$LIB"; dashboard_project_for_dir "$TEST_TMPDIR/cache.md" "$TEST_TMPDIR/home/other" ) || rc=$?
    assert_eq "1" "$rc" "exit 1 for a dir with no row" || return 1
    assert_eq "" "$out" "prints nothing"
}
run_test "dashboard_project_for_dir returns 1 for an unregistered dir" t_project_for_dir_unknown

# Fable review 2026-11-27 #5: live Path cells can carry a note, e.g. `~/some-project (build/canonical)`.
t_project_for_dir_annotated_path() {
    mkdir -p "$TEST_TMPDIR/home/ivaf"
    printf '| Project | Priority | Parent | Path |\n|---|---|---|---|\n| ivaf | P2 | — | ~/ivaf (build/canonical) |\n' > "$TEST_TMPDIR/cache.md"
    local out
    out=$( HOME="$TEST_TMPDIR/home"; source "$LIB"; dashboard_project_for_dir "$TEST_TMPDIR/cache.md" "$TEST_TMPDIR/home/ivaf" )
    assert_eq "ivaf" "$out" "a trailing ' (…)' annotation is not part of the path"
}
run_test "dashboard_project_for_dir ignores a trailing (annotation) in the Path cell" t_project_for_dir_annotated_path

suite_summary
