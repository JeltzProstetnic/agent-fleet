#!/usr/bin/env bash
# Tests for dashboard-row.sh — row-scoped, locked writer for dashboard-cache.md (CFG-576)
source "$(dirname "$0")/test-helpers.sh"

suite_header "dashboard-row.sh (CFG-576: row-scoped dashboard writer)"

SCRIPT="$REPO_ROOT/setup/scripts/dashboard-row.sh"

# ── Fixture ──────────────────────────────────────────────────────────────────
# Mirrors the real cache's shape, including the two malformed row kinds seen live:
# a row missing its trailing cell (9 cells) and one whose P1Names were pipe-joined.
create_cache() {
    cat > "$TEST_TMPDIR/cache.md" << 'EOF'
# Dashboard Cache

Last refreshed: 2026-09-01 10:00 UTC on testhost

| Project | Priority | Parent | Path | Type | Tasks | Size | Deadline | P1Names | LastDone |
|---------|----------|--------|------|------|-------|------|----------|---------|----------|
| alpha | P1 | — | ~/alpha | research (p) | 2P1 1P2 | 1.2G | 2026-09-01 | Alpha state snapshot that is long enough to be prose. |  |
| beta | P2 | — | ~/beta | code (d) | 1P2 | 340M |  |  | Shipped v3.0 |
| gamma | P3 | alpha | ~/gamma | code | 3P3 | 12M | 2026-08-01 | Gamma prose snapshot without a trailing cell at all
| delta | P2 | — | ~/delta | config | 2P1 | 22M | 2026-03-13 | DEL-1: first|DEL-2: second|DEL-3: third |  |
| alpha-two | P3 | alpha | ~/alpha-two | code | — | 1M |  |  |  |
EOF
}

run_row() {
    DASHBOARD_CACHE="$TEST_TMPDIR/cache.md" bash "$SCRIPT" "$@"
}

# Number of cells in a project's row (a well-formed row has exactly 10).
cell_count() {
    grep "^| $1 |" "$TEST_TMPDIR/cache.md" | awk -F'|' '{print NF - 2}'
}

# Field N (1-based cell index) of a project's row, trimmed.
cell() {
    grep "^| $1 |" "$TEST_TMPDIR/cache.md" | awk -F'|' -v c="$(( $2 + 1 ))" '{v=$c; gsub(/^ +| +$/, "", v); print v}'
}

# ── Tests ────────────────────────────────────────────────────────────────────

test_updates_only_the_named_row() {
    create_cache
    cp "$TEST_TMPDIR/cache.md" "$TEST_TMPDIR/before.md"
    run_row beta --tasks "2P1 1P2" --size "400M" || return 1
    # Every line except beta's is byte-identical.
    diff <(grep -v '^| beta |' "$TEST_TMPDIR/before.md") <(grep -v '^| beta |' "$TEST_TMPDIR/cache.md") || return 1
    assert_eq "2P1 1P2" "$(cell beta 6)" "tasks updated" || return 1
    assert_eq "400M" "$(cell beta 7)" "size updated" || return 1
    assert_eq "Shipped v3.0" "$(cell beta 10)" "unnamed fields untouched"
}
run_test "updates only the named row; other lines byte-identical" test_updates_only_the_named_row

test_replaces_never_appends() {
    create_cache
    run_row alpha --deadline "First snapshot text" || return 1
    run_row alpha --deadline "Second snapshot text" || return 1
    assert_eq "Second snapshot text" "$(cell alpha 8)" || return 1
    assert_file_not_contains "$TEST_TMPDIR/cache.md" "First snapshot text"
}
run_test "a field is REPLACED, never appended" test_replaces_never_appends

test_exact_project_match() {
    create_cache
    run_row alpha --size "9.9G" || return 1
    assert_eq "9.9G" "$(cell alpha 7)" || return 1
    assert_eq "1M" "$(cell alpha-two 7)" "a prefix-sharing project must not be touched"
}
run_test "matches the project name exactly (alpha vs alpha-two)" test_exact_project_match

test_all_snapshot_fields() {
    create_cache
    run_row beta --deadline "2026-10-01" --p1names "Fix it" --lastdone "Did a thing" || return 1
    assert_eq "2026-10-01" "$(cell beta 8)" || return 1
    assert_eq "Fix it" "$(cell beta 9)" || return 1
    assert_eq "Did a thing" "$(cell beta 10)"
}
run_test "writes Deadline / P1Names / LastDone" test_all_snapshot_fields

test_unknown_project_fails_and_leaves_file() {
    create_cache
    cp "$TEST_TMPDIR/cache.md" "$TEST_TMPDIR/before.md"
    assert_failure run_row nosuch --size "1K" || return 1
    diff -q "$TEST_TMPDIR/before.md" "$TEST_TMPDIR/cache.md" >/dev/null
}
run_test "unknown project: non-zero exit, file unchanged" test_unknown_project_fails_and_leaves_file

test_no_fields_is_an_error() {
    create_cache
    assert_failure run_row alpha
}
run_test "no field flags: usage error" test_no_fields_is_an_error

test_missing_cache_is_an_error() {
    assert_failure env DASHBOARD_CACHE="$TEST_TMPDIR/missing.md" bash "$SCRIPT" alpha --size 1K
}
run_test "missing cache file: non-zero exit" test_missing_cache_is_an_error

test_pipes_and_newlines_cannot_break_the_row() {
    create_cache
    run_row beta --p1names "BET-1: one|BET-2: two" --deadline "line one
line two" || return 1
    assert_eq "10" "$(cell_count beta)" "row must stay 10 cells" || return 1
    assert_eq "BET-1: one; BET-2: two" "$(cell beta 9)" || return 1
    assert_eq "line one line two" "$(cell beta 8)"
}
run_test "a value with '|' or a newline cannot add columns" test_pipes_and_newlines_cannot_break_the_row

test_short_row_is_normalized() {
    create_cache
    run_row gamma --size "13M" || return 1
    assert_eq "10" "$(cell_count gamma)" || return 1
    assert_eq "Gamma prose snapshot without a trailing cell at all" "$(cell gamma 9)"
}
run_test "a row missing its trailing cell is padded to 10 cells" test_short_row_is_normalized

test_long_row_is_normalized() {
    create_cache
    run_row delta --size "23M" || return 1
    assert_eq "10" "$(cell_count delta)" || return 1
    assert_eq "DEL-1: first; DEL-2: second; DEL-3: third" "$(cell delta 9)"
}
run_test "pipe-split P1Names are re-joined into one cell" test_long_row_is_normalized

test_concurrent_writers_do_not_clobber() {
    # ⛔ The incident: a session wrote the file from a stale whole-file buffer and reverted
    #    another project's row. Many writers at once must all land.
    local i
    {
        sed -n '1,6p' <<'EOF'
# Dashboard Cache

Last refreshed: 2026-09-01 10:00 UTC on testhost

| Project | Priority | Parent | Path | Type | Tasks | Size | Deadline | P1Names | LastDone |
|---------|----------|--------|------|------|-------|------|----------|---------|----------|
EOF
        for i in $(seq 1 20); do
            printf '| p%s | P2 | — | ~/p%s | code | — | — |  |  |  |\n' "$i" "$i"
        done
    } > "$TEST_TMPDIR/cache.md"
    local pids=()
    for i in $(seq 1 20); do
        run_row "p$i" --deadline "snapshot-from-writer-$i" &
        pids+=($!)
    done
    local rc=0 p
    for p in "${pids[@]}"; do wait "$p" || rc=1; done
    assert_eq "0" "$rc" "every writer must succeed" || return 1
    for i in $(seq 1 20); do
        assert_eq "snapshot-from-writer-$i" "$(cell "p$i" 8)" "writer $i's update was lost" || return 1
    done
    assert_grep_count "$TEST_TMPDIR/cache.md" '^| p[0-9]' 20
}
run_test "20 concurrent writers on different rows: every update lands" test_concurrent_writers_do_not_clobber

test_waits_for_a_held_lock_then_gives_up() {
    create_cache
    cp "$TEST_TMPDIR/cache.md" "$TEST_TMPDIR/before.md"
    mkdir "$TEST_TMPDIR/cache.md.lock"
    assert_failure env DASHBOARD_CACHE="$TEST_TMPDIR/cache.md" DASHBOARD_LOCK_TIMEOUT=1 \
        bash "$SCRIPT" alpha --size 1K || return 1
    diff -q "$TEST_TMPDIR/before.md" "$TEST_TMPDIR/cache.md" >/dev/null || return 1
    assert_dir_exists "$TEST_TMPDIR/cache.md.lock" "someone else's lock must not be removed"
}
run_test "a held lock blocks the write (timeout, file unchanged)" test_waits_for_a_held_lock_then_gives_up

test_proceeds_once_lock_released() {
    create_cache
    mkdir "$TEST_TMPDIR/cache.md.lock"
    ( sleep 1; rmdir "$TEST_TMPDIR/cache.md.lock" ) &
    DASHBOARD_CACHE="$TEST_TMPDIR/cache.md" DASHBOARD_LOCK_TIMEOUT=10 \
        bash "$SCRIPT" alpha --size 7G || return 1
    wait
    assert_eq "7G" "$(cell alpha 7)"
}
run_test "the write proceeds once the lock is released" test_proceeds_once_lock_released

test_stale_lock_is_broken() {
    create_cache
    mkdir "$TEST_TMPDIR/cache.md.lock"
    touch -d '10 minutes ago' "$TEST_TMPDIR/cache.md.lock"
    DASHBOARD_CACHE="$TEST_TMPDIR/cache.md" DASHBOARD_LOCK_TIMEOUT=2 \
        bash "$SCRIPT" alpha --size 8G || return 1
    assert_eq "8G" "$(cell alpha 7)"
}
run_test "a stale lock (left by a killed writer) is broken" test_stale_lock_is_broken

test_lock_released_and_no_temp_left() {
    create_cache
    run_row alpha --size 5G || return 1
    [[ ! -e "$TEST_TMPDIR/cache.md.lock" ]] || { echo "    lock left behind"; return 1; }
    local extra
    extra=$(find "$TEST_TMPDIR" -maxdepth 1 -name 'cache.md.*' | wc -l | tr -d ' ')
    assert_eq "0" "$extra" "no temp or lock files left next to the cache"
}
run_test "lock released and no temp file left after a write" test_lock_released_and_no_temp_left

test_file_mode_preserved() {
    create_cache
    chmod 644 "$TEST_TMPDIR/cache.md"
    run_row alpha --size 5G || return 1
    local mode
    mode=$(stat -c %a "$TEST_TMPDIR/cache.md" 2>/dev/null || stat -f %Lp "$TEST_TMPDIR/cache.md")
    assert_eq "644" "$mode"
}
run_test "the atomic replace keeps the cache's file mode" test_file_mode_preserved

# ── --auto (CFG-1093 P-SHUTDOWN): Tasks and Size computed from the row's Path ──
# session-close.sh passes only --deadline; the counts come from the same summariser
# lsd-refresh.sh uses (lib-dashboard.sh) and the same `du -sh`.
_auto_project() {
    mkdir -p "$TEST_TMPDIR/home/beta"
    cat > "$TEST_TMPDIR/home/beta/backlog.md" <<'EOF'
# Backlog
- [ ] [P1] `B-1` **Fix it**: x
- [ ] [P2] `B-2` y
## Done
- [x] [P2] `B-0` z
EOF
    head -c 20000 /dev/zero > "$TEST_TMPDIR/home/beta/blob.bin"
}

test_auto_computes_tasks_and_size() {
    create_cache
    _auto_project
    HOME="$TEST_TMPDIR/home" run_row beta --auto || return 1
    local want_size
    want_size=$(du -sh "$TEST_TMPDIR/home/beta" | awk '{print $1}')
    assert_eq "1P1 1P2" "$(cell beta 6)" "tasks computed from the backlog" || return 1
    assert_eq "$want_size" "$(cell beta 7)" "size is du -sh of the row's path" || return 1
    assert_eq "Shipped v3.0" "$(cell beta 10)" "LastDone untouched"
}
run_test "--auto computes Tasks and Size from the row's Path" test_auto_computes_tasks_and_size

test_auto_with_deadline() {
    create_cache
    _auto_project
    HOME="$TEST_TMPDIR/home" run_row beta --auto --deadline "ship 2026-12-01" || return 1
    assert_eq "1P1 1P2" "$(cell beta 6)" "tasks set" || return 1
    assert_eq "ship 2026-12-01" "$(cell beta 8)" "deadline set alongside"
}
run_test "--auto combines with --deadline" test_auto_with_deadline

test_auto_no_backlog_is_dash() {
    create_cache
    mkdir -p "$TEST_TMPDIR/home/beta"
    HOME="$TEST_TMPDIR/home" run_row beta --auto || return 1
    assert_eq "—" "$(cell beta 6)" "no backlog → dash"
}
run_test "--auto without a backlog writes a dash" test_auto_no_backlog_is_dash

test_auto_missing_path_fails_unchanged() {
    create_cache
    cp "$TEST_TMPDIR/cache.md" "$TEST_TMPDIR/before.md"
    local rc=0
    HOME="$TEST_TMPDIR/home" run_row beta --auto 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "a row whose path does not exist here fails" || return 1
    diff -q "$TEST_TMPDIR/before.md" "$TEST_TMPDIR/cache.md" >/dev/null
    assert_eq "0" "$?" "file unchanged"
}
run_test "--auto with a path absent on this machine: exit 1, file unchanged" test_auto_missing_path_fails_unchanged

test_auto_conflicts_with_explicit_tasks() {
    create_cache
    _auto_project
    assert_failure env HOME="$TEST_TMPDIR/home" DASHBOARD_CACHE="$TEST_TMPDIR/cache.md" bash "$SCRIPT" beta --auto --tasks "9P1"
}
run_test "--auto with --tasks or --size is a usage error" test_auto_conflicts_with_explicit_tasks

# Fable review 2026-11-27 #1: the live cache lists a child row (Parent = P) BEFORE P's own row, and a
# substring match on "| P |" took the child's Path for the parent.
test_auto_ignores_a_child_row_naming_it_as_parent() {
    cat > "$TEST_TMPDIR/cache.md" << 'EOF'
| Project | Priority | Parent | Path | Type | Tasks | Size | Deadline | P1Names | LastDone |
|---------|----------|--------|------|------|-------|------|----------|---------|----------|
| kid | P2 | beta | ~/kid | code | 9P1 | 9G |  |  |  |
| beta | P2 | — | ~/beta | code | 1P2 | 340M |  |  |  |
EOF
    _auto_project
    mkdir -p "$TEST_TMPDIR/home/kid"
    printf '# Backlog\n- [ ] [P3] `K-1` kid item\n' > "$TEST_TMPDIR/home/kid/backlog.md"
    HOME="$TEST_TMPDIR/home" run_row beta --auto || return 1
    assert_eq "1P1 1P2" "$(cell beta 6)" "beta's own backlog, not kid's" || return 1
    assert_eq "$(du -sh "$TEST_TMPDIR/home/beta" | awk '{print $1}')" "$(cell beta 7)" "beta's own size" || return 1
    assert_eq "9P1" "$(cell kid 6)" "the child row is untouched"
}
run_test "--auto uses the row whose Project cell is the name, not a child naming it as Parent" test_auto_ignores_a_child_row_naming_it_as_parent

# Fable review #6: a cold `du` on a large tree must not push a shutdown past the Bash tool's 120 s.
test_auto_du_is_time_bounded() {
    create_cache
    _auto_project
    mkdir -p "$TEST_TMPDIR/slowbin"
    printf '#!/usr/bin/env bash\nsleep 5\necho "99G x"\n' > "$TEST_TMPDIR/slowbin/du"
    chmod +x "$TEST_TMPDIR/slowbin/du"
    local t0=$SECONDS
    HOME="$TEST_TMPDIR/home" PATH="$TEST_TMPDIR/slowbin:$PATH" DASHBOARD_DU_TIMEOUT=1 run_row beta --auto || return 1
    assert_eq "—" "$(cell beta 7)" "a du that times out writes a dash" || return 1
    assert_eq "1P1 1P2" "$(cell beta 6)" "tasks still written" || return 1
    (( SECONDS - t0 < 4 )) || { echo "    took $((SECONDS - t0)) s" >&2; return 1; }
}
run_test "--auto bounds du with DASHBOARD_DU_TIMEOUT (Size '—' on timeout)" test_auto_du_is_time_bounded

# Fable second pass #4: an unreadable backlog killed --auto with exit 2, the usage code.
test_auto_unreadable_backlog_fails_cleanly() {
    create_cache
    _auto_project
    chmod 000 "$TEST_TMPDIR/home/beta/backlog.md"
    cp "$TEST_TMPDIR/cache.md" "$TEST_TMPDIR/before.md"
    local rc=0 out
    out=$(HOME="$TEST_TMPDIR/home" run_row beta --auto 2>&1) || rc=$?
    chmod 644 "$TEST_TMPDIR/home/beta/backlog.md"
    assert_eq "1" "$rc" "exit 1, not the usage code" || return 1
    assert_contains "$out" "cannot read" "says why" || return 1
    diff -q "$TEST_TMPDIR/before.md" "$TEST_TMPDIR/cache.md" >/dev/null
    assert_eq "0" "$?" "row unchanged"
}
run_test "--auto with an unreadable backlog: exit 1 with a reason, row unchanged" test_auto_unreadable_backlog_fails_cleanly

suite_summary
