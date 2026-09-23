#!/usr/bin/env bash
# Tests for clean-permissions.sh — removes stale permissions blocks from settings.local.json
source "$(dirname "$0")/test-helpers.sh"

CLEAN_SCRIPT="$REPO_ROOT/setup/scripts/clean-permissions.sh"

suite_header "Clean Permissions Tests"

# ── Core behavior ────────────────────────────────────────────────────────────

test_removes_permissions_block() {
    local slj="$TEST_TMPDIR/project/.claude/settings.local.json"
    mkdir -p "$(dirname "$slj")"
    cat > "$slj" << 'EOF'
{
  "enableAllProjectMcpServers": true,
  "permissions": {
    "allow": [
      "Bash(echo:*)"
    ]
  },
  "enabledMcpjsonServers": ["serena"]
}
EOF

    bash "$CLEAN_SCRIPT" "$TEST_TMPDIR" 2>/dev/null
    assert_file_not_contains "$slj" '"permissions"'
    assert_file_contains "$slj" '"enableAllProjectMcpServers"'
    assert_file_contains "$slj" '"enabledMcpjsonServers"'
}
run_test "removes permissions block, preserves other keys" test_removes_permissions_block

test_no_permissions_block_noop() {
    local slj="$TEST_TMPDIR/project/.claude/settings.local.json"
    mkdir -p "$(dirname "$slj")"
    cat > "$slj" << 'EOF'
{
  "enableAllProjectMcpServers": true,
  "enabledMcpjsonServers": ["serena"]
}
EOF

    local before
    before=$(cat "$slj")
    bash "$CLEAN_SCRIPT" "$TEST_TMPDIR" 2>/dev/null
    local after
    after=$(cat "$slj")
    assert_eq "$before" "$after"
}
run_test "no-op when no permissions block exists" test_no_permissions_block_noop

test_handles_multiple_projects() {
    for proj in alpha beta gamma; do
        local slj="$TEST_TMPDIR/$proj/.claude/settings.local.json"
        mkdir -p "$(dirname "$slj")"
        cat > "$slj" << 'EOF'
{
  "enableAllProjectMcpServers": true,
  "permissions": {
    "allow": ["Bash(cat:*)"]
  }
}
EOF
    done

    bash "$CLEAN_SCRIPT" "$TEST_TMPDIR" 2>/dev/null

    for proj in alpha beta gamma; do
        local slj="$TEST_TMPDIR/$proj/.claude/settings.local.json"
        assert_file_not_contains "$slj" '"permissions"'
        assert_file_contains "$slj" '"enableAllProjectMcpServers"'
    done
}
run_test "cleans permissions from multiple projects" test_handles_multiple_projects

test_skips_files_without_permissions() {
    # One with permissions, one without
    local slj1="$TEST_TMPDIR/dirty/.claude/settings.local.json"
    local slj2="$TEST_TMPDIR/clean/.claude/settings.local.json"
    mkdir -p "$(dirname "$slj1")" "$(dirname "$slj2")"

    cat > "$slj1" << 'EOF'
{
  "permissions": { "allow": ["Bash(ls:*)"] },
  "enabledMcpjsonServers": ["serena"]
}
EOF
    cat > "$slj2" << 'EOF'
{
  "enabledMcpjsonServers": ["serena"]
}
EOF

    local clean_before
    clean_before=$(cat "$slj2")
    bash "$CLEAN_SCRIPT" "$TEST_TMPDIR" 2>/dev/null
    assert_file_not_contains "$slj1" '"permissions"'
    local clean_after
    clean_after=$(cat "$slj2")
    assert_eq "$clean_before" "$clean_after"
}
run_test "only modifies files that have permissions blocks" test_skips_files_without_permissions

test_reports_cleaned_count() {
    for proj in a b; do
        local slj="$TEST_TMPDIR/$proj/.claude/settings.local.json"
        mkdir -p "$(dirname "$slj")"
        cat > "$slj" << 'EOF'
{
  "permissions": { "allow": [] }
}
EOF
    done

    local output
    output=$(bash "$CLEAN_SCRIPT" "$TEST_TMPDIR" 2>&1)
    assert_contains "$output" "2"
}
run_test "reports number of cleaned files" test_reports_cleaned_count

test_no_output_when_nothing_to_clean() {
    local slj="$TEST_TMPDIR/proj/.claude/settings.local.json"
    mkdir -p "$(dirname "$slj")"
    echo '{"enabledMcpjsonServers": []}' > "$slj"

    local output
    output=$(bash "$CLEAN_SCRIPT" "$TEST_TMPDIR" 2>&1)
    assert_eq "" "$output"
}
run_test "silent when nothing to clean" test_no_output_when_nothing_to_clean

test_exits_zero_always() {
    # Even with no files found
    assert_exit_code 0 bash "$CLEAN_SCRIPT" "$TEST_TMPDIR"
}
run_test "exits 0 even when no settings files found" test_exits_zero_always

test_default_scans_home() {
    # When called without args, should default to $HOME
    # We can't test the actual $HOME behavior in isolation, but verify it runs
    assert_exit_code 0 bash "$CLEAN_SCRIPT"
}
run_test "runs without arguments (defaults to HOME)" test_default_scans_home


# ─────────────────────────────────────────────────────────────────────────────
# CFG-468-adjacent / inbox 2026-08-15: AUTHORED-BLOCK PROTECTION
#
# Everything above pins the script's ORIGINAL purpose and predates this work.
# What follows pins the fix for the defect that made it destructive: it deleted
# the whole `permissions` key from every project unconditionally, so a block MG
# authored on 2026-08-15 (a project allow-list, so an unattended GPU run would
# not stop on prompts) was written, verified, and deleted at the next session
# start. A user-authored permissions block could not survive one session boundary.
#
# The contract added here:
#   1. `<project>/.claude/.permissions-authored` protects a block absolutely.
#   2. An unmarked block is still cleaned, but backed up first, so the operation
#      stops being unrecoverable.
#   3. One unparseable file no longer aborts the whole sweep.
#
# Cleaning is deliberately all-or-nothing: per knowledge/claude-code-permissions.md
# a project-level `permissions` key REPLACES the global one rather than merging,
# so a partial block left behind would still shadow global and re-create the
# prompt storm. There is no half-clean that works.
# ─────────────────────────────────────────────────────────────────────────────

CLEAN="$CLEAN_SCRIPT"
MARKER=".permissions-authored"

# Build <root>/<name>/.claude/settings.local.json with the given JSON body.
_mk_proj() {
    local root="$1" name="$2" body="$3"
    mkdir -p "$root/$name/.claude"
    printf '%s\n' "$body" > "$root/$name/.claude/settings.local.json"
}

_PERMS_JSON='{
  "enabledPlugins": {},
  "permissions": { "allow": ["Bash(python3:*)"], "deny": [] }
}'

_has_perms() { grep -q '"permissions"' "$1" 2>/dev/null; }

# ── the original purpose must still work ─────────────────────────────────────

test_unmarked_block_is_cleaned() {
    local root="$TEST_TMPDIR/r1"
    _mk_proj "$root" proj "$_PERMS_JSON"
    bash "$CLEAN" "$root" >/dev/null 2>&1
    local f="$root/proj/.claude/settings.local.json"
    _has_perms "$f" && { printf "    unmarked permissions block survived\n"; return 1; }
    return 0
}
run_test "unmarked: accumulated block is still cleaned" test_unmarked_block_is_cleaned

test_cleaning_preserves_other_keys() {
    local root="$TEST_TMPDIR/r2"
    _mk_proj "$root" proj '{"enabledPlugins":{"a":true},"enableAllProjectMcpServers":true,"permissions":{"allow":["Bash(ls:*)"]}}'
    bash "$CLEAN" "$root" >/dev/null 2>&1
    local f="$root/proj/.claude/settings.local.json"
    assert_file_contains "$f" "enabledPlugins" "unrelated keys survive the clean" \
      && assert_file_contains "$f" "enableAllProjectMcpServers" "all unrelated keys survive, not just the first"
}
run_test "unmarked: cleaning leaves every other key intact" test_cleaning_preserves_other_keys

# ── the defect this suite was written for ────────────────────────────────────

test_authored_block_survives() {
    local root="$TEST_TMPDIR/r3"
    _mk_proj "$root" proj "$_PERMS_JSON"
    touch "$root/proj/.claude/$MARKER"          # the user declared this block theirs
    bash "$CLEAN" "$root" >/dev/null 2>&1
    local f="$root/proj/.claude/settings.local.json"
    _has_perms "$f" || { printf "    AUTHORED permissions block was deleted\n"; return 1; }
    assert_file_contains "$f" "Bash(python3" "the authored rules themselves are intact, not just the key"
}
run_test "authored: a marked block is never deleted" test_authored_block_survives

test_authored_block_survives_repeated_runs() {
    # The failure was per-session-start, so surviving ONE run proves nothing.
    local root="$TEST_TMPDIR/r4"
    _mk_proj "$root" proj "$_PERMS_JSON"
    touch "$root/proj/.claude/$MARKER"
    local i
    for i in 1 2 3 4 5; do bash "$CLEAN" "$root" >/dev/null 2>&1; done
    local f="$root/proj/.claude/settings.local.json"
    _has_perms "$f" || { printf "    authored block eroded after repeated runs\n"; return 1; }
    return 0
}
run_test "authored: survives five consecutive session starts" test_authored_block_survives_repeated_runs

test_marker_is_per_project() {
    # A marker in one project must not shield another.
    local root="$TEST_TMPDIR/r5"
    _mk_proj "$root" kept "$_PERMS_JSON";  touch "$root/kept/.claude/$MARKER"
    _mk_proj "$root" swept "$_PERMS_JSON"
    bash "$CLEAN" "$root" >/dev/null 2>&1
    _has_perms "$root/kept/.claude/settings.local.json"  || { printf "    marked project was swept\n"; return 1; }
    _has_perms "$root/swept/.claude/settings.local.json" && { printf "    unmarked project was shielded\n"; return 1; }
    return 0
}
run_test "authored: the marker protects one project only" test_marker_is_per_project

# ── deletion must stop being unrecoverable ───────────────────────────────────

test_cleaned_block_is_backed_up() {
    local root="$TEST_TMPDIR/r6"
    _mk_proj "$root" proj "$_PERMS_JSON"
    bash "$CLEAN" "$root" >/dev/null 2>&1
    local n
    n=$(find "$root/proj/.claude" -name '.permissions-backup-*.json' -type f 2>/dev/null | wc -l)
    assert_eq "1" "$n" "the removed block is written to a backup before deletion" || return 1
    local b
    b=$(find "$root/proj/.claude" -name '.permissions-backup-*.json' -type f 2>/dev/null | head -1)
    assert_file_contains "$b" "Bash(python3" "the backup actually contains the removed rules"
}
run_test "recovery: a cleaned block is backed up first" test_cleaned_block_is_backed_up

test_no_backup_when_nothing_removed() {
    local root="$TEST_TMPDIR/r7"
    _mk_proj "$root" proj '{"enabledPlugins":{}}'      # no permissions key at all
    bash "$CLEAN" "$root" >/dev/null 2>&1
    local n
    n=$(find "$root/proj/.claude" -name '.permissions-backup-*.json' -type f 2>/dev/null | wc -l)
    assert_eq "0" "$n" "no backup churn when there was nothing to remove"
}
run_test "recovery: no backup written when there is no block" test_no_backup_when_nothing_removed

test_no_backup_for_authored() {
    local root="$TEST_TMPDIR/r8"
    _mk_proj "$root" proj "$_PERMS_JSON"
    touch "$root/proj/.claude/$MARKER"
    bash "$CLEAN" "$root" >/dev/null 2>&1
    local n
    n=$(find "$root/proj/.claude" -name '.permissions-backup-*.json' -type f 2>/dev/null | wc -l)
    assert_eq "0" "$n" "a protected project produces no backup churn either"
}
run_test "recovery: no backup churn for a protected project" test_no_backup_for_authored

# ── safety ───────────────────────────────────────────────────────────────────

test_malformed_json_left_alone() {
    local root="$TEST_TMPDIR/r9"
    _mk_proj "$root" proj '{"permissions": {"allow": [ BROKEN'
    bash "$CLEAN" "$root" >/dev/null 2>&1
    assert_file_contains "$root/proj/.claude/settings.local.json" "BROKEN" \
        "unparseable settings are left exactly as found, never truncated"
}
run_test "safety: malformed JSON is not rewritten" test_malformed_json_left_alone

test_exits_zero_on_malformed() {
    # It runs from a SessionStart hook; a non-zero exit must never break startup.
    local root="$TEST_TMPDIR/r10"
    _mk_proj "$root" proj '{"permissions": {"allow": [ BROKEN'
    local rc=0
    bash "$CLEAN" "$root" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "always exits 0 so a SessionStart hook can never be broken by it"
}
run_test "safety: always exits 0 on malformed input" test_exits_zero_on_malformed

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
