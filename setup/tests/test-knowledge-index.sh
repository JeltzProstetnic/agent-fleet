#!/usr/bin/env bash
# Tests for 23-knowledge-index.sh — every knowledge file must have an INDEX row.
#
# CFG-635: the index listed 31 of 49 files, so 18 were undiscoverable to any
# session that looked there. The whole knowledge design is conditional loading —
# an unindexed file is loaded only by someone who already knows its name, which
# defeats the mechanism for exactly the sessions that need it most (a new
# machine, a cold start, an emergency). This check exists so the next 18 cannot
# accumulate silently.
source "$(dirname "$0")/test-helpers.sh"

suite_header "Knowledge Index Check (23-knowledge-index.sh)"

CHECK="$REPO_ROOT/global/hooks/checks/23-knowledge-index.sh"

# Build a mock repo: $1.. = knowledge filenames; INDEX rows come from stdin.
setup_repo() {
    local kdir="$TEST_TMPDIR/config-repo/global/knowledge"
    rm -rf "$TEST_TMPDIR/config-repo"
    mkdir -p "$kdir"
    local f
    for f in "$@"; do printf '# %s\n' "$f" > "$kdir/$f"; done
    cat > "$kdir/INDEX.md"
}

run_check() {
    export CONFIG_REPO="$TEST_TMPDIR/config-repo"
    WARNINGS=""
    rm -f "/tmp/.knowledge-index-check-$(date +%Y-%m-%d)" 2>/dev/null || true
    source "$CHECK"
    echo "$WARNINGS"
}

test_all_indexed_silent() {
    setup_repo alpha.md beta.md <<'EOF'
# Index
| File | Trigger | Content |
|------|---------|---------|
| `alpha.md` | x | y |
| `beta.md` | x | y |
EOF
    local out; out=$(run_check)
    assert_not_contains "$out" "KNOWLEDGE_INDEX" "fully indexed knowledge dir must be silent"
}
run_test "every knowledge file indexed — silent" test_all_indexed_silent

test_missing_row_warns() {
    setup_repo alpha.md beta.md gamma.md <<'EOF'
# Index
| File | Trigger | Content |
|------|---------|---------|
| `alpha.md` | x | y |
EOF
    local out; out=$(run_check)
    assert_contains "$out" "KNOWLEDGE_INDEX" "missing rows must warn" || return 1
    assert_contains "$out" "beta.md" "warning must name the missing file" || return 1
    assert_contains "$out" "gamma.md" "warning must name every missing file"
}
run_test "knowledge file with no INDEX row warns and is named" test_missing_row_warns

test_stale_row_warns() {
    setup_repo alpha.md <<'EOF'
# Index
| File | Trigger | Content |
|------|---------|---------|
| `alpha.md` | x | y |
| `deleted.md` | x | y |
EOF
    local out; out=$(run_check)
    assert_contains "$out" "deleted.md" "an INDEX row whose file is gone must warn"
}
run_test "INDEX row with no file (stale) warns" test_stale_row_warns

# The check must report what it examined, so "inspected nothing" is visibly
# distinct from "found nothing" (CFG-611 / knowledge/log-evidence-traps.md).
test_reports_count_examined() {
    setup_repo alpha.md beta.md gamma.md <<'EOF'
# Index
| File | Trigger | Content |
|------|---------|---------|
| `alpha.md` | x | y |
EOF
    local out; out=$(run_check)
    assert_contains "$out" "of 3" "warning must state how many files were examined"
}
run_test "warning states how many files were examined" test_reports_count_examined

test_missing_index_warns() {
    local kdir="$TEST_TMPDIR/config-repo/global/knowledge"
    rm -rf "$TEST_TMPDIR/config-repo"; mkdir -p "$kdir"
    printf '# a\n' > "$kdir/alpha.md"
    local out; out=$(run_check)
    assert_contains "$out" "KNOWLEDGE_INDEX" "an absent INDEX.md must warn, not pass silently"
}
run_test "absent INDEX.md warns rather than passing" test_missing_index_warns

test_no_knowledge_dir_silent() {
    rm -rf "$TEST_TMPDIR/config-repo"; mkdir -p "$TEST_TMPDIR/config-repo"
    local out; out=$(run_check)
    assert_not_contains "$out" "KNOWLEDGE_INDEX" "no knowledge dir at all must be silent (not this repo)"
}
run_test "repo without a knowledge dir is silent" test_no_knowledge_dir_silent

test_syntax_valid() {
    bash -n "$CHECK"
    assert_eq "0" "$?" "check module must be syntactically valid"
}
run_test "bash syntax is valid" test_syntax_valid

suite_summary
