#!/usr/bin/env bash
# Tests for lsd-refresh.sh — dashboard cache generation
source "$(dirname "$0")/test-helpers.sh"

suite_header "lsd-refresh.sh"

# ── Fixture: create a minimal registry + backlogs ────────────────────────────

create_registry() {
    local dir="$1"
    cat > "$dir/registry.md" << 'EOF'
# Project Registry

| Project | Priority | Parent | Path | GitHub | Machines | Type |
|---------|----------|--------|------|--------|----------|------|
| alpha | P1 | — | `~/alpha` | private | all | research (p) |
| beta | P2 | — | `~/beta` | dual push | all | code (d) |
| gamma | P3 | alpha | `~/gamma` | private | all | code |
| delta | P4 | — | `~/delta` | — | all | code |
EOF
}

create_backlog_with_p1() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/backlog.md" << 'EOF'
# Backlog — alpha

## Open

- [ ] [P1] **Fix critical auth bug**: Users can't login after OAuth migration
- [ ] [P1] **Deploy hotfix v2.1**: Patch production ASAP
- [ ] [P2] **Add user settings page**: New feature for profile management
- [ ] [P3] **Refactor API layer**: Clean up endpoint structure

## Done

### 2026-02-28
- [x] Fixed database migration script
- [x] Added rate limiting to API
EOF
}

create_backlog_empty_open() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/backlog.md" << 'EOF'
# Backlog — beta

## Open

## Done

### 2026-02-27
- [x] Shipped v3.0 release
- [x] Updated CI pipeline
EOF
}

create_backlog_no_p1() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/backlog.md" << 'EOF'
# Backlog — gamma

## Open

- [ ] [P2] **Add caching layer**: Redis integration
- [ ] [P3] **Write API docs**: OpenAPI spec

## Done

### 2026-02-26
- [x] Migrated to TypeScript
EOF
}

# ── Tests ────────────────────────────────────────────────────────────────────

test_cache_has_header() {
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"

    REGISTRY="$TEST_TMPDIR/registry.md" CACHE="$TEST_TMPDIR/cache.md" \
        HOME="$TEST_TMPDIR" bash -c '
        source <(sed "s|REGISTRY=.*|REGISTRY=\"$REGISTRY\"|; s|CACHE=.*|CACHE=\"$CACHE\"|" '"$REPO_ROOT"'/setup/scripts/lsd-refresh.sh | grep -v "^set -euo")
    ' 2>/dev/null || true

    # Run it properly — override vars inside the script
    HOME="$TEST_TMPDIR" bash -c '
        export REGISTRY="'"$TEST_TMPDIR"'/registry.md"
        export CACHE="'"$TEST_TMPDIR"'/cache.md"
        sed "s|^REGISTRY=.*|REGISTRY=\"\$REGISTRY\"|; s|^CACHE=.*|CACHE=\"\$CACHE\"|" \
            '"$REPO_ROOT"'/setup/scripts/lsd-refresh.sh | bash
    ' 2>/dev/null

    assert_file_exists "$TEST_TMPDIR/cache.md"
    assert_file_contains "$TEST_TMPDIR/cache.md" "Dashboard Cache"
    assert_file_contains "$TEST_TMPDIR/cache.md" "Last refreshed:"
}
run_test "cache file has correct header" test_cache_has_header

test_cache_has_all_projects() {
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"

    HOME="$TEST_TMPDIR" bash -c '
        export REGISTRY="'"$TEST_TMPDIR"'/registry.md"
        export CACHE="'"$TEST_TMPDIR"'/cache.md"
        sed "s|^REGISTRY=.*|REGISTRY=\"\$REGISTRY\"|; s|^CACHE=.*|CACHE=\"\$CACHE\"|" \
            '"$REPO_ROOT"'/setup/scripts/lsd-refresh.sh | bash
    ' 2>/dev/null

    assert_file_contains "$TEST_TMPDIR/cache.md" "alpha"
    assert_file_contains "$TEST_TMPDIR/cache.md" "beta"
    assert_file_contains "$TEST_TMPDIR/cache.md" "gamma"
    assert_file_contains "$TEST_TMPDIR/cache.md" "delta"
}
run_test "cache contains all registry projects" test_cache_has_all_projects

test_task_counts_with_p1() {
    create_registry "$TEST_TMPDIR"
    create_backlog_with_p1 "$TEST_TMPDIR/alpha"
    mkdir -p "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"

    HOME="$TEST_TMPDIR" bash -c '
        export REGISTRY="'"$TEST_TMPDIR"'/registry.md"
        export CACHE="'"$TEST_TMPDIR"'/cache.md"
        sed "s|^REGISTRY=.*|REGISTRY=\"\$REGISTRY\"|; s|^CACHE=.*|CACHE=\"\$CACHE\"|" \
            '"$REPO_ROOT"'/setup/scripts/lsd-refresh.sh | bash
    ' 2>/dev/null

    local alpha_row
    alpha_row=$(grep "^| alpha" "$TEST_TMPDIR/cache.md")
    assert_contains "$alpha_row" "2P1"
    assert_contains "$alpha_row" "1P2"
    assert_contains "$alpha_row" "1P3"
}
run_test "task counts extracted correctly with P1 items" test_task_counts_with_p1

test_p1_task_names_extracted() {
    create_registry "$TEST_TMPDIR"
    create_backlog_with_p1 "$TEST_TMPDIR/alpha"
    mkdir -p "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"

    HOME="$TEST_TMPDIR" bash -c '
        export REGISTRY="'"$TEST_TMPDIR"'/registry.md"
        export CACHE="'"$TEST_TMPDIR"'/cache.md"
        sed "s|^REGISTRY=.*|REGISTRY=\"\$REGISTRY\"|; s|^CACHE=.*|CACHE=\"\$CACHE\"|" \
            '"$REPO_ROOT"'/setup/scripts/lsd-refresh.sh | bash
    ' 2>/dev/null

    local alpha_row
    alpha_row=$(grep "^| alpha" "$TEST_TMPDIR/cache.md")
    # P1 task names should appear in a P1Names column
    assert_contains "$alpha_row" "Fix critical auth bug"
    assert_contains "$alpha_row" "Deploy hotfix v2.1"
}
run_test "P1 task names extracted into cache" test_p1_task_names_extracted

test_last_done_for_empty_backlog() {
    create_registry "$TEST_TMPDIR"
    create_backlog_empty_open "$TEST_TMPDIR/beta"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"

    HOME="$TEST_TMPDIR" bash -c '
        export REGISTRY="'"$TEST_TMPDIR"'/registry.md"
        export CACHE="'"$TEST_TMPDIR"'/cache.md"
        sed "s|^REGISTRY=.*|REGISTRY=\"\$REGISTRY\"|; s|^CACHE=.*|CACHE=\"\$CACHE\"|" \
            '"$REPO_ROOT"'/setup/scripts/lsd-refresh.sh | bash
    ' 2>/dev/null

    local beta_row
    beta_row=$(grep "^| beta" "$TEST_TMPDIR/cache.md")
    # Should have last done item when no open tasks
    assert_contains "$beta_row" "Shipped v3.0 release"
}
run_test "last done item shown for projects with no open tasks" test_last_done_for_empty_backlog

test_no_last_done_when_tasks_exist() {
    create_registry "$TEST_TMPDIR"
    create_backlog_no_p1 "$TEST_TMPDIR/gamma"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/delta"

    HOME="$TEST_TMPDIR" bash -c '
        export REGISTRY="'"$TEST_TMPDIR"'/registry.md"
        export CACHE="'"$TEST_TMPDIR"'/cache.md"
        sed "s|^REGISTRY=.*|REGISTRY=\"\$REGISTRY\"|; s|^CACHE=.*|CACHE=\"\$CACHE\"|" \
            '"$REPO_ROOT"'/setup/scripts/lsd-refresh.sh | bash
    ' 2>/dev/null

    local gamma_row
    gamma_row=$(grep "^| gamma" "$TEST_TMPDIR/cache.md")
    # Should NOT have last done when there are open tasks
    assert_not_contains "$gamma_row" "Migrated to TypeScript"
}
run_test "no last done item when open tasks exist" test_no_last_done_when_tasks_exist

test_no_backlog_shows_dash() {
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"
    # No backlog files created

    HOME="$TEST_TMPDIR" bash -c '
        export REGISTRY="'"$TEST_TMPDIR"'/registry.md"
        export CACHE="'"$TEST_TMPDIR"'/cache.md"
        sed "s|^REGISTRY=.*|REGISTRY=\"\$REGISTRY\"|; s|^CACHE=.*|CACHE=\"\$CACHE\"|" \
            '"$REPO_ROOT"'/setup/scripts/lsd-refresh.sh | bash
    ' 2>/dev/null

    local delta_row
    delta_row=$(grep "^| delta" "$TEST_TMPDIR/cache.md")
    # Tasks column should be —
    assert_contains "$delta_row" "—"
}
run_test "projects without backlog show dash" test_no_backlog_shows_dash

test_parent_preserved() {
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"

    HOME="$TEST_TMPDIR" bash -c '
        export REGISTRY="'"$TEST_TMPDIR"'/registry.md"
        export CACHE="'"$TEST_TMPDIR"'/cache.md"
        sed "s|^REGISTRY=.*|REGISTRY=\"\$REGISTRY\"|; s|^CACHE=.*|CACHE=\"\$CACHE\"|" \
            '"$REPO_ROOT"'/setup/scripts/lsd-refresh.sh | bash
    ' 2>/dev/null

    local gamma_row
    gamma_row=$(grep "^| gamma" "$TEST_TMPDIR/cache.md")
    assert_contains "$gamma_row" "alpha" "gamma should have parent alpha"
}
run_test "parent project preserved in cache" test_parent_preserved

test_type_indicators() {
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"

    HOME="$TEST_TMPDIR" bash -c '
        export REGISTRY="'"$TEST_TMPDIR"'/registry.md"
        export CACHE="'"$TEST_TMPDIR"'/cache.md"
        sed "s|^REGISTRY=.*|REGISTRY=\"\$REGISTRY\"|; s|^CACHE=.*|CACHE=\"\$CACHE\"|" \
            '"$REPO_ROOT"'/setup/scripts/lsd-refresh.sh | bash
    ' 2>/dev/null

    local alpha_row beta_row
    alpha_row=$(grep "^| alpha" "$TEST_TMPDIR/cache.md")
    beta_row=$(grep "^| beta" "$TEST_TMPDIR/cache.md")
    # alpha is (p) from type field, beta has dual push in github column
    assert_contains "$alpha_row" "(p)" "alpha should have (p) indicator"
    assert_contains "$beta_row" "(d)" "beta should have (d) indicator"
}
run_test "type indicators (p) and (d) rendered" test_type_indicators

test_human_prose_survives_a_refresh() {
    # ⛔ Regression: the refresh used to overwrite the cache wholesale, destroying the
    #    state-snapshot prose that the shutdown checklist tells every project to maintain.
    #    A project with no active session never noticed. (First seen 2026-08-25.)
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"

    HOME="$TEST_TMPDIR" bash -c '
        export REGISTRY="'"$TEST_TMPDIR"'/registry.md"
        export CACHE="'"$TEST_TMPDIR"'/cache.md"
        sed "s|^REGISTRY=.*|REGISTRY=\"\$REGISTRY\"|; s|^CACHE=.*|CACHE=\"\$CACHE\"|" \
            '"$REPO_ROOT"'/setup/scripts/lsd-refresh.sh | bash
    ' 2>/dev/null

    # A session writes prose into its own row, and a hand-written task count.
    local prose="Direction changed: the two arms are limited by different things, and this is prose."
    local line cells
    : > "$TEST_TMPDIR/cache.new"
    while IFS= read -r line; do
        if [[ "$line" == "| alpha "* ]]; then
            IFS='|' read -r -a cells <<< "$line"
            cells[6]=" 111 open / 26 done "
            cells[9]=" $prose "
            line=$(IFS='|'; printf '%s' "${cells[*]}")
        fi
        printf '%s\n' "$line" >> "$TEST_TMPDIR/cache.new"
    done < "$TEST_TMPDIR/cache.md"
    mv "$TEST_TMPDIR/cache.new" "$TEST_TMPDIR/cache.md"

    HOME="$TEST_TMPDIR" bash -c '
        export REGISTRY="'"$TEST_TMPDIR"'/registry.md"
        export CACHE="'"$TEST_TMPDIR"'/cache.md"
        sed "s|^REGISTRY=.*|REGISTRY=\"\$REGISTRY\"|; s|^CACHE=.*|CACHE=\"\$CACHE\"|" \
            '"$REPO_ROOT"'/setup/scripts/lsd-refresh.sh | bash
    ' 2>/dev/null

    local alpha_row
    alpha_row=$(grep "^| alpha" "$TEST_TMPDIR/cache.md")
    assert_contains "$alpha_row" "$prose" "prose snapshot must survive a refresh"
    assert_contains "$alpha_row" "111 open / 26 done" "hand-written count must survive a refresh"
    assert_file_exists "$TEST_TMPDIR/cache.md.bak"
}
run_test "human prose and hand-written counts survive a refresh" test_human_prose_survives_a_refresh

# ── CFG-576: counter formats, clobber safety, row shape ─────────────────────

run_refresh() {
    HOME="$TEST_TMPDIR" bash -c '
        export REGISTRY="'"$TEST_TMPDIR"'/registry.md"
        export CACHE="'"$TEST_TMPDIR"'/cache.md"
        sed "s|^REGISTRY=.*|REGISTRY=\"\$REGISTRY\"|; s|^CACHE=.*|CACHE=\"\$CACHE\"|" \
            '"$REPO_ROOT"'/setup/scripts/lsd-refresh.sh | bash
    ' 2>/dev/null
}

# Trimmed cell N (1-based: 1=Project … 6=Tasks 7=Size 8=Deadline 9=P1Names 10=LastDone).
cache_cell() {
    grep "^| $1 |" "$TEST_TMPDIR/cache.md" | awk -F'|' -v c="$(( $2 + 1 ))" '{v=$c; gsub(/^ +| +$/, "", v); print v}'
}

test_counts_paren_priorities_without_open_section() {
    # ⛔ A backlog with no `## Open` section and `(P1)`-style tags (the track-sectioned
    #    format some projects use) was reported as `1P3` or `—` instead of its real count.
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"
    cat > "$TEST_TMPDIR/alpha/backlog.md" << 'EOF'
# alpha — Backlog

States: `[ ]` open · `[>]` in-progress · `[x]` done.

## Track A — rig

- [x] **ALP-1** (P1): done already
- [ ] **ALP-2** (P1): open one
- [>] **ALP-3** (P2 proposed — owner 2026-07-15): in progress
- [ ] **ALP-4** (P3): open three

## Open questions

- [ ] **ALP-5** (P1): another open one

## Track B — scaffolding

- [?] **ALP-6** (P2): awaiting verification
EOF
    run_refresh
    assert_eq "2P1 2P2 1P3" "$(cache_cell alpha 6)"
}
run_test "counts (Pn) tags in a backlog without a ## Open section" test_counts_paren_priorities_without_open_section

test_done_items_inside_open_not_counted() {
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"
    cat > "$TEST_TMPDIR/alpha/backlog.md" << 'EOF'
# Backlog — alpha

## Open

- [ ] [P1] `ALP-1` **Open one**: x
- [x] [P1] `ALP-2` **Done but not yet groomed out**: x
- [>] [P0] `ALP-3` **Being worked on**: x
- [ ] [P2] `ALP-4` **Open two**: x

## Done

- [x] [P1] `ALP-0` **Old**: x
EOF
    run_refresh
    assert_eq "1P0 1P1 1P2" "$(cache_cell alpha 6)"
}
run_test "done items left inside ## Open are not counted; P0 is counted as P0" test_done_items_inside_open_not_counted

test_untagged_only_backlog_is_not_invented_p3() {
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"
    cat > "$TEST_TMPDIR/alpha/backlog.md" << 'EOF'
# Backlog — alpha

## Open

- [ ] First untagged item
- [ ] Second untagged item
- [ ] Third untagged item
EOF
    run_refresh
    assert_eq "3 open" "$(cache_cell alpha 6)"
}
run_test "a backlog with no priority tags at all reports 'N open', not NP3" test_untagged_only_backlog_is_not_invented_p3

test_p1_names_do_not_split_the_row() {
    create_registry "$TEST_TMPDIR"
    create_backlog_with_p1 "$TEST_TMPDIR/alpha"
    mkdir -p "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"
    run_refresh
    local ncells
    ncells=$(grep "^| alpha |" "$TEST_TMPDIR/cache.md" | awk -F'|' '{print NF - 2}')
    assert_eq "10" "$ncells" "row must have exactly the header's 10 cells" || return 1
    assert_eq "Fix critical auth bug; Deploy hotfix v2.1" "$(cache_cell alpha 9)"
}
run_test "P1 names are joined with '; ' so the row keeps 10 cells" test_p1_names_do_not_split_the_row

test_project_not_on_this_machine_keeps_its_row() {
    # ⛔ A refresh on a machine that does not hold a project used to blank that project's
    #    Tasks / Size / snapshot — clobbering another machine's row with "—".
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma"   # no delta here
    cat > "$TEST_TMPDIR/cache.md" << 'EOF'
# Dashboard Cache

| Project | Priority | Parent | Path | Type | Tasks | Size | Deadline | P1Names | LastDone |
|---------|----------|--------|------|------|-------|------|----------|---------|----------|
| delta | P4 | — | ~/delta | code | 5P1 2P2 | 3.1G | 2026-09-01 | Short note | Shipped |
EOF
    run_refresh
    assert_eq "5P1 2P2" "$(cache_cell delta 6)" "tasks" || return 1
    assert_eq "3.1G" "$(cache_cell delta 7)" "size" || return 1
    assert_eq "2026-09-01" "$(cache_cell delta 8)" "deadline" || return 1
    assert_eq "Short note" "$(cache_cell delta 9)" "p1names" || return 1
    assert_eq "Shipped" "$(cache_cell delta 10)" "lastdone"
}
run_test "a project not on this machine keeps its previous cells" test_project_not_on_this_machine_keeps_its_row

test_row_written_during_refresh_survives() {
    # ⛔ The clobber class itself: the refresh read the cache at START, spent seconds in
    #    `du`, then wrote the whole file — reverting any row a session updated meanwhile.
    #    A `du` shim performs that concurrent row update deterministically.
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"
    run_refresh
    mkdir -p "$TEST_TMPDIR/shim"
    cat > "$TEST_TMPDIR/shim/du" << EOF
#!/usr/bin/env bash
if [[ ! -e "$TEST_TMPDIR/shim/done" ]]; then
    touch "$TEST_TMPDIR/shim/done"
    DASHBOARD_CACHE="$TEST_TMPDIR/cache.md" bash "$REPO_ROOT/setup/scripts/dashboard-row.sh" \
        gamma --deadline "Written by another session while the refresh was running." >/dev/null
fi
printf '1.0M\t%s\n' "\$2"
EOF
    chmod +x "$TEST_TMPDIR/shim/du"
    PATH="$TEST_TMPDIR/shim:$PATH" run_refresh
    [[ -e "$TEST_TMPDIR/shim/done" ]] || { echo "    shim never ran"; return 1; }
    assert_eq "Written by another session while the refresh was running." "$(cache_cell gamma 8)"
}
run_test "a row written while the refresh runs is not reverted" test_row_written_during_refresh_survives

test_refresh_respects_the_row_lock() {
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"
    run_refresh
    cp "$TEST_TMPDIR/cache.md" "$TEST_TMPDIR/before.md"
    create_backlog_with_p1 "$TEST_TMPDIR/alpha"
    mkdir "$TEST_TMPDIR/cache.md.lock"
    DASHBOARD_LOCK_TIMEOUT=1 run_refresh || true
    diff -q "$TEST_TMPDIR/before.md" "$TEST_TMPDIR/cache.md" >/dev/null \
        || { echo "    refresh wrote through a held lock"; return 1; }
    rmdir "$TEST_TMPDIR/cache.md.lock"
    run_refresh
    assert_contains "$(cache_cell alpha 6)" "2P1" "refresh proceeds once the lock is free"
}
run_test "the refresh waits on the same lock as dashboard-row.sh" test_refresh_respects_the_row_lock

# ── CFG-576 repair: a GENERATED cell over PROSE_MIN must not freeze as "prose" ─────
# ⛔ P1 names are joined with '; ' into one cell. Two names easily pass 40 characters, and
#    the refresh then took its OWN list for human prose on every later run: the dashboard
#    kept listing closed P1 items while Tasks showed the new count. (Base re-generated it
#    only because its broken parse read just the first pipe-split name.)

write_alpha_backlog_moved_on() {
    cat > "$TEST_TMPDIR/alpha/backlog.md" << 'EOF'
# Backlog — alpha

## Open

- [ ] [P1] **Brand new thing**: next up
- [ ] [P2] **Add user settings page**: New feature for profile management

## Done

- [x] [P1] **Fix critical auth bug**: Users can't login after OAuth migration
- [x] [P1] **Deploy hotfix v2.1**: Patch production ASAP
EOF
}

test_generated_p1names_refresh_on_the_next_run() {
    create_registry "$TEST_TMPDIR"
    create_backlog_with_p1 "$TEST_TMPDIR/alpha"
    mkdir -p "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"
    run_refresh
    local first; first="$(cache_cell alpha 9)"
    assert_eq "Fix critical auth bug; Deploy hotfix v2.1" "$first" || return 1
    (( ${#first} > 40 )) || { echo "    fixture no longer exceeds PROSE_MIN — the test would be vacuous"; return 1; }
    write_alpha_backlog_moved_on
    run_refresh
    assert_eq "1P1 1P2" "$(cache_cell alpha 6)" "tasks" || return 1
    assert_eq "Brand new thing" "$(cache_cell alpha 9)" "the refresh's own P1 list must be regenerated"
}
run_test "a generated P1Names list over 40 chars is regenerated, not frozen as prose" \
    test_generated_p1names_refresh_on_the_next_run

test_generated_lastdone_refresh_on_the_next_run() {
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"
    cat > "$TEST_TMPDIR/beta/backlog.md" << 'EOF'
# Backlog — beta

## Open

## Done

- [x] Shipped the v3.0 release to every production region
EOF
    run_refresh
    assert_eq "Shipped the v3.0 release to every production region" "$(cache_cell beta 10)" || return 1
    cat > "$TEST_TMPDIR/beta/backlog.md" << 'EOF'
# Backlog — beta

## Open

## Done

- [x] Retired the legacy v2 API after the migration window
- [x] Shipped the v3.0 release to every production region
EOF
    run_refresh
    assert_eq "Retired the legacy v2 API after the migration window" "$(cache_cell beta 10)"
}
run_test "a generated LastDone over 40 chars is regenerated, not frozen as prose" \
    test_generated_lastdone_refresh_on_the_next_run

test_session_prose_over_a_generated_cell_survives() {
    # The fix must not cost the prose rule: a session that REPLACES the refresh's list with its
    # own snapshot (dashboard-row.sh) keeps it across refreshes.
    create_registry "$TEST_TMPDIR"
    create_backlog_with_p1 "$TEST_TMPDIR/alpha"
    mkdir -p "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"
    run_refresh
    local prose="Auth fix is blocked on the IdP vendor; hotfix waits for it."
    DASHBOARD_CACHE="$TEST_TMPDIR/cache.md" bash "$REPO_ROOT/setup/scripts/dashboard-row.sh" \
        alpha --p1names "$prose" >/dev/null || { echo "    dashboard-row failed"; return 1; }
    run_refresh
    assert_eq "$prose" "$(cache_cell alpha 9)" "after one refresh" || return 1
    write_alpha_backlog_moved_on
    run_refresh
    assert_eq "$prose" "$(cache_cell alpha 9)" "after the backlog moved on"
}
run_test "session prose written over a generated cell still survives refreshes" \
    test_session_prose_over_a_generated_cell_survives

test_generated_mark_survives_a_refresh_elsewhere() {
    # A machine that does not hold the project keeps its row whole — and must keep the
    # knowledge that the long cell is generated, or the owning machine freezes it next time.
    create_registry "$TEST_TMPDIR"
    create_backlog_with_p1 "$TEST_TMPDIR/alpha"
    mkdir -p "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"
    run_refresh
    mv "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/alpha.away"
    run_refresh
    assert_eq "Fix critical auth bug; Deploy hotfix v2.1" "$(cache_cell alpha 9)" "row kept elsewhere" || return 1
    mv "$TEST_TMPDIR/alpha.away" "$TEST_TMPDIR/alpha"
    write_alpha_backlog_moved_on
    run_refresh
    assert_eq "Brand new thing" "$(cache_cell alpha 9)"
}
run_test "a refresh on a machine without the project keeps the cell's generated mark" \
    test_generated_mark_survives_a_refresh_elsewhere

test_generated_mark_survives_dashboard_row() {
    # dashboard-row.sh rewrites the file around its one row; the generated marks must survive
    # a write to ANOTHER column of the same row (a shutdown --tasks/--size update).
    create_registry "$TEST_TMPDIR"
    create_backlog_with_p1 "$TEST_TMPDIR/alpha"
    mkdir -p "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"
    run_refresh
    DASHBOARD_CACHE="$TEST_TMPDIR/cache.md" bash "$REPO_ROOT/setup/scripts/dashboard-row.sh" \
        alpha --size "9.9M" >/dev/null || { echo "    dashboard-row failed"; return 1; }
    write_alpha_backlog_moved_on
    run_refresh
    assert_eq "Brand new thing" "$(cache_cell alpha 9)"
}
run_test "a dashboard-row write to another cell keeps the generated mark" test_generated_mark_survives_dashboard_row

# ── CFG-576 repair 2: a generated value must survive the round trip through the row ────
# ⛔ The generated mark only helps if the cell READ BACK equals the value recorded. A '|' in a
#    P1 name or a done line split the row; split_row folded the fragments back with '; ', so
#    the read-back never matched and the cell froze as prose again — mangled (`|| true` read
#    `; true`, a LastDone kept only its last fragment). Live data: the cfg backlog has a P1
#    named "`template-push.sh`'s `|| true` skip-check…". Stray whitespace, CRLF line endings
#    and a '-->' (which cannot sit in the comment block) broke the match the same way.

row_ncells() { grep "^| $1 |" "$TEST_TMPDIR/cache.md" | awk -F'|' '{print NF - 2}'; }

test_generated_p1names_with_a_pipe_refresh() {
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"
    cat > "$TEST_TMPDIR/alpha/backlog.md" << 'EOF'
# Backlog — alpha

## Open

- [ ] [P1] **Fix the `|| true` skip-check in template-push**: invalid ERE
- [ ] [P2] **Add user settings page**: New feature for profile management
EOF
    run_refresh
    assert_eq "10" "$(row_ncells alpha)" "a '|' in a generated cell must not add columns" || return 1
    local first; first="$(cache_cell alpha 9)"
    assert_contains "$first" "skip-check in template-push" || return 1
    (( ${#first} > 40 )) || { echo "    fixture no longer exceeds PROSE_MIN — the test would be vacuous"; return 1; }
    run_refresh
    assert_eq "$first" "$(cache_cell alpha 9)" "an unchanged backlog must give the same cell" || return 1
    write_alpha_backlog_moved_on
    run_refresh
    assert_eq "1P1 1P2" "$(cache_cell alpha 6)" "tasks" || return 1
    assert_eq "Brand new thing" "$(cache_cell alpha 9)" "a P1 list with a '|' must be regenerated"
}
run_test "a generated P1Names cell containing '|| true' is regenerated, not frozen" \
    test_generated_p1names_with_a_pipe_refresh

test_generated_lastdone_with_a_pipe_refresh() {
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"
    cat > "$TEST_TMPDIR/beta/backlog.md" << 'EOF'
# Backlog — beta

## Done

- [x] Fixed the `sync.sh status | grep` pipeline that dropped long lines in the report
EOF
    run_refresh
    assert_eq "10" "$(row_ncells beta)" "a '|' in a generated cell must not add columns" || return 1
    local first; first="$(cache_cell beta 10)"
    assert_contains "$first" "Fixed the \`sync.sh status" "the whole line, not its last fragment" || return 1
    assert_contains "$first" "pipeline that dropped long lines in the report" || return 1
    run_refresh
    assert_eq "$first" "$(cache_cell beta 10)" "an unchanged backlog must give the same cell" || return 1
    cat > "$TEST_TMPDIR/beta/backlog.md" << 'EOF'
# Backlog — beta

## Done

- [x] Retired the legacy v2 API after the migration window
- [x] Fixed the `sync.sh status | grep` pipeline that dropped long lines in the report
EOF
    run_refresh
    assert_eq "Retired the legacy v2 API after the migration window" "$(cache_cell beta 10)"
}
run_test "a generated LastDone containing '|' keeps the whole line and is regenerated" \
    test_generated_lastdone_with_a_pipe_refresh

test_generated_cells_with_stray_whitespace_refresh() {
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"
    # beta: CRLF line endings; gamma: trailing spaces (a markdown line break) after the item.
    printf '# Backlog — beta\r\n\r\n## Done\r\n\r\n- [x] Shipped the v3.0 release to every production region\r\n' \
        > "$TEST_TMPDIR/beta/backlog.md"
    printf '# Backlog — gamma\n\n## Done\n\n- [x] Migrated every service to TypeScript in one sweep  \n' \
        > "$TEST_TMPDIR/gamma/backlog.md"
    run_refresh
    assert_eq "Shipped the v3.0 release to every production region" "$(cache_cell beta 10)" "crlf" || return 1
    printf '# Backlog — beta\r\n\r\n## Done\r\n\r\n- [x] Retired the legacy v2 API after the migration window\r\n' \
        > "$TEST_TMPDIR/beta/backlog.md"
    printf '# Backlog — gamma\n\n## Done\n\n- [x] Wrote the OpenAPI spec for the public endpoints\n' \
        > "$TEST_TMPDIR/gamma/backlog.md"
    run_refresh
    assert_eq "Retired the legacy v2 API after the migration window" "$(cache_cell beta 10)" "crlf backlog" || return 1
    assert_eq "Wrote the OpenAPI spec for the public endpoints" "$(cache_cell gamma 10)" "trailing spaces"
}
run_test "a generated cell from a CRLF or trailing-space line is regenerated, not frozen" \
    test_generated_cells_with_stray_whitespace_refresh

test_generated_cell_with_comment_closer_refresh() {
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"
    cat > "$TEST_TMPDIR/alpha/backlog.md" << 'EOF'
# Backlog — alpha

## Open

- [ ] [P1] **Migrate the old --> new pipeline for every region**: x
EOF
    run_refresh
    assert_eq "Migrate the old --> new pipeline for every region" "$(cache_cell alpha 9)" || return 1
    # The record block is one HTML comment: nothing inside it may close it early.
    local closers
    closers=$(awk '/^<!-- lsd-refresh generated cells/ {inb=1; next} inb && /^-->/ {exit} inb && /-->/ {n++} END {print n+0}' \
        "$TEST_TMPDIR/cache.md")
    assert_eq "0" "$closers" "a '-->' inside the generated-cells comment" || return 1
    write_alpha_backlog_moved_on
    run_refresh
    assert_eq "Brand new thing" "$(cache_cell alpha 9)" "a P1 list with '-->' must be regenerated"
}
run_test "a generated cell containing '-->' is recorded safely and regenerated" \
    test_generated_cell_with_comment_closer_refresh

test_generated_mark_holds_across_locales() {
    # A refresh from a UTF-8 shell and one from a C-locale hook count a '—' differently (1 char
    # vs 3 bytes). A cell that is 40 characters but more than 40 bytes must still be recorded,
    # or the C-locale run sees an unrecorded long cell and freezes it.
    local utf8="$LSD_UTF8_LOCALE"
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"
    local line="Shipped v3 — every region — no downtime!"
    [[ "$(LC_ALL=$utf8 bash -c 'v="$1"; echo ${#v}' _ "$line")" == 40 ]] \
        || { echo "    fixture must be exactly 40 characters"; return 1; }
    printf '# Backlog — beta\n\n## Done\n\n- [x] %s\n' "$line" > "$TEST_TMPDIR/beta/backlog.md"
    LC_ALL=$utf8 run_refresh
    assert_eq "$line" "$(cache_cell beta 10)" || return 1
    printf '# Backlog — beta\n\n## Done\n\n- [x] Retired the legacy v2 API\n' > "$TEST_TMPDIR/beta/backlog.md"
    LC_ALL=C run_refresh
    assert_eq "Retired the legacy v2 API" "$(cache_cell beta 10)"
}
LSD_UTF8_LOCALE=""
for loc in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if [[ "$(LC_ALL=$loc bash -c 'v="—"; echo ${#v}' 2>/dev/null)" == 1 ]]; then LSD_UTF8_LOCALE=$loc; break; fi
done
if [[ -n "$LSD_UTF8_LOCALE" ]]; then
    run_test "a generated cell's mark holds when the next refresh runs in another locale" \
        test_generated_mark_holds_across_locales
else
    skip_test "a generated cell's mark holds when the next refresh runs in another locale" \
        "no UTF-8 locale on this machine"
fi

test_first_run_creates_the_cache_directory() {
    # The lock lives next to the cache, so the directory must exist BEFORE the lock is
    # taken — otherwise a first run waits out the timeout and blames a lock that never was.
    create_registry "$TEST_TMPDIR"
    mkdir -p "$TEST_TMPDIR/alpha" "$TEST_TMPDIR/beta" "$TEST_TMPDIR/gamma" "$TEST_TMPDIR/delta"
    local rc=0
    HOME="$TEST_TMPDIR" DASHBOARD_LOCK_TIMEOUT=2 bash -c '
        export REGISTRY="'"$TEST_TMPDIR"'/registry.md"
        export CACHE="'"$TEST_TMPDIR"'/fresh/cross-project/cache.md"
        sed "s|^REGISTRY=.*|REGISTRY=\"\$REGISTRY\"|; s|^CACHE=.*|CACHE=\"\$CACHE\"|" \
            '"$REPO_ROOT"'/setup/scripts/lsd-refresh.sh | bash
    ' > "$TEST_TMPDIR/out.log" 2>&1 || rc=$?
    assert_eq "0" "$rc" "exit status ($(tr '\n' ' ' < "$TEST_TMPDIR/out.log"))" || return 1
    assert_file_exists "$TEST_TMPDIR/fresh/cross-project/cache.md"
}
run_test "a first run creates the cache directory before taking the lock" test_first_run_creates_the_cache_directory

suite_summary
