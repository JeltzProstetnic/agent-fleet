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

suite_summary
