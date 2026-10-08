#!/usr/bin/env bash
# Tests for global/hooks/checks/09-backup-gaps.sh (CFG-702).
# The check is sourced by config-check.sh; here it is sourced directly against a
# fixture CONFIG_REPO holding a copy of the real dms-stats.sh and small catalogs.
source "$(dirname "$0")/test-helpers.sh"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$REPO_ROOT/global/hooks/checks/09-backup-gaps.sh"

suite_header "config-check.sh: DMS backup gaps (check 09)"

# The check no-ops without a DMS, and downstream installs ship none (CFG-709).
if [[ ! -f "$REPO_ROOT/dms/scripts/dms-stats.sh" ]]; then
    skip_test "check 09 suite" "no dms/scripts/dms-stats.sh in this install — the check is a no-op here"
    suite_summary; exit 0
fi

_fixture() {   # <dir> — config repo with dms/scripts/dms-stats.sh + catalogs
    local d="$1"
    mkdir -p "$d/dms/scripts" "$d/dms/catalogs"
    cp "$REPO_ROOT/dms/scripts/dms-stats.sh" "$d/dms/scripts/"
    printf '# Map\n' > "$d/dms/storage-map.md"
    cat > "$d/dms/catalogs/mixed.md" << 'CATALOG'
| ID | Name | Date | Type | Storage | Backup | Tags | Notes |
|----|------|------|------|---------|--------|------|-------|
| ACA-001 | Paper A | 2020 | pdf | nas:/a |  |  |  |
| ACA-002 | Paper B | 2020 | pdf | nas:/b |  |  |  |
| CRE-001 | Draft C | 2020 | pdf | nas:/c |  |  |  |
| CRE-002 | Draft D | 2020 | pdf | nas:/d |  |  |  |
| CRE-003 | Draft E | 2020 | pdf | nas:/e |  |  |  |
| ACA-003 | Paper F | 2020 | pdf | nas:/f |  |  |  |
| LEG-001 | Contract | 2020 | pdf | nas:/g |  |  |  |
| PER-001 | Passport | 2020 | pdf | nas:/h |  |  |  |
| FIN-001 | Tax return | 2020 | pdf | nas:/i | ext8tb:/i |  |  |
CATALOG
}

_run_check() {   # <config_repo> — prints the WARNINGS the check leaves behind
    (
        CONFIG_REPO="$1"; WARNINGS=""
        # never scan the real Dropbox from a test
        DROPBOX_ROOT="${DROPBOX_ROOT:-$TEST_TMPDIR/no-dropbox}"
        SCHED_MARKER_DIR="$TEST_TMPDIR/markers"; mkdir -p "$SCHED_MARKER_DIR"
        source "$CHECK"
        printf '%s' "$WARNINGS"
    )
}

test_counts_every_gap() {
    local repo="$TEST_TMPDIR/cfg-a" out
    _fixture "$repo"
    out="$(_run_check "$repo")"
    assert_contains "$out" "DMS backup gaps: 8 document(s)" \
        "all 8 empty Backup cells are counted (measured: ${out:0:60})"
}
run_test "check 09: counts every empty Backup cell" test_counts_every_gap

test_tier0_prefixes_are_critical() {
    local repo="$TEST_TMPDIR/cfg-b" out crit
    _fixture "$repo"
    out="$(_run_check "$repo")"
    crit="${out#*Critical: }"
    # Tier 0/1 categories must lead the list; 6 ACA/CRE rows precede them in the
    # catalog, so a first-5 CRE/ACA filter (the old :27) never showed them.
    assert_contains "$crit" "LEG-001" "Tier-0 legal gap is listed as critical (measured: $crit)"
    assert_contains "$crit" "PER-001" "Tier-0 identity gap is listed as critical (measured: $crit)"
    assert_not_contains "$crit" "FIN-001" "a document WITH a backup is never listed"
}
run_test "check 09: Tier-0/1 gaps (LEG/PER) are the critical ones" test_tier0_prefixes_are_critical

test_daily_gate() {
    local repo="$TEST_TMPDIR/cfg-c" first second
    _fixture "$repo"
    first="$(_run_check "$repo")"
    second="$(_run_check "$repo")"
    assert_contains "$first" "DMS backup gaps" "first run of the day reports (measured: ${first:0:40})"
    assert_eq "" "$second" "second run the same day is silent (measured: '${second:0:40}')"
}
run_test "check 09: runs once per day" test_daily_gate

# --- Dropbox budget (dropbox-budget.sh) ---
_dropbox_fixture() {   # <repo> <dropbox_root> <bytes> — repo with the guard + a fake Dropbox
    local repo="$1" root="$2" bytes="$3"
    _fixture "$repo"
    cp "$REPO_ROOT/dms/scripts/dropbox-budget.sh" "$repo/dms/scripts/"
    mkdir -p "$root/DMS-Sync"
    head -c "$bytes" /dev/zero > "$root/DMS-Sync/a.pdf"
}

test_dropbox_over_budget_warns() {
    local repo="$TEST_TMPDIR/cfg-d" root="$TEST_TMPDIR/dbx-d" out
    _dropbox_fixture "$repo" "$root" 500
    out="$(DROPBOX_ROOT="$root" DROPBOX_BUDGET_BYTES=100 _run_check "$repo")"
    assert_contains "$out" "DROPBOX_OVER_BUDGET" "over-budget Dropbox is surfaced (measured: ${out##*| })"
    assert_contains "$out" "500 bytes" "warning carries the measured size"
}
run_test "check 09: Dropbox over budget is surfaced" test_dropbox_over_budget_warns

test_dropbox_under_budget_silent() {
    local repo="$TEST_TMPDIR/cfg-e" root="$TEST_TMPDIR/dbx-e" out
    _dropbox_fixture "$repo" "$root" 50
    out="$(DROPBOX_ROOT="$root" DROPBOX_BUDGET_BYTES=100 _run_check "$repo")"
    assert_not_contains "$out" "DROPBOX" "Dropbox within budget adds nothing (measured: '${out:0:60}')"
}
run_test "check 09: Dropbox within budget is silent" test_dropbox_under_budget_silent

test_dropbox_absent_silent() {
    local repo="$TEST_TMPDIR/cfg-f" out
    _dropbox_fixture "$repo" "$TEST_TMPDIR/dbx-f" 500
    out="$(DROPBOX_ROOT="$TEST_TMPDIR/no-dropbox-here" DROPBOX_BUDGET_BYTES=100 _run_check "$repo")"
    assert_not_contains "$out" "DROPBOX" "machine without Dropbox adds nothing (measured: '${out:0:60}')"
}
run_test "check 09: machine without Dropbox is silent" test_dropbox_absent_silent

suite_summary
