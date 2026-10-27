#!/usr/bin/env bash
# Tests for setup/scripts/tmp-sweep.sh (CFG-851): the fleet never deleted its own scratch.
# Ages out untracked files in <project>/tmp/ (TMP_SWEEP_DAYS, default 14) and in staging dirs
# (TMP_SWEEP_STAGING, default 7 days), never touches git-tracked files, writes a one-line report.
source "$(dirname "$0")/test-helpers.sh"
SCRIPT="$REPO_ROOT/setup/scripts/tmp-sweep.sh"
suite_header "tmp-sweep.sh"

setup_tree() {
    H="$TEST_TMPDIR/home"; rm -rf "$H"; mkdir -p "$H/proj/tmp/sub" "$H/stage" "$H/norepo/tmp"
    git -C "$H/proj" init -q
    printf 'old' > "$H/proj/tmp/old.txt";  touch -d '20 days ago' "$H/proj/tmp/old.txt"
    printf 'new' > "$H/proj/tmp/new.txt"
    printf 'deep' > "$H/proj/tmp/sub/deep.bin"; touch -d '20 days ago' "$H/proj/tmp/sub/deep.bin"
    printf 'tracked' > "$H/proj/tmp/tracked.txt"; touch -d '20 days ago' "$H/proj/tmp/tracked.txt"
    git -C "$H/proj" add -f tmp/tracked.txt; git -C "$H/proj" -c user.email=t@t -c user.name=t commit -qm t
    touch -d '20 days ago' "$H/proj/tmp/tracked.txt"
    printf 's' > "$H/stage/old.html"; touch -d '9 days ago' "$H/stage/old.html"
    printf 's' > "$H/stage/fresh.html"; touch -d '3 days ago' "$H/stage/fresh.html"
    printf 'x' > "$H/norepo/tmp/keep.txt"; touch -d '20 days ago' "$H/norepo/tmp/keep.txt"
    REPORT="$TEST_TMPDIR/report"
}
sweep() { TMP_SWEEP_HOME="$H" TMP_SWEEP_STAGING="$H/stage" TMP_SWEEP_REPORT="$REPORT" bash "$SCRIPT" "$@" 2>&1; }

test_ages_out_untracked_old_files() {
    setup_tree; sweep >/dev/null
    assert_file_not_exists "$H/proj/tmp/old.txt" "20-day-old untracked file removed" || return 1
    assert_file_not_exists "$H/proj/tmp/sub/deep.bin" "nested old file removed" || return 1
    assert_file_exists "$H/proj/tmp/new.txt" "fresh file kept"
}
run_test "project tmp/: untracked files older than 14 days are removed" test_ages_out_untracked_old_files

test_never_touches_tracked() {
    setup_tree; sweep >/dev/null
    assert_file_exists "$H/proj/tmp/tracked.txt" "git-tracked file under tmp/ is never removed"
}
run_test "project tmp/: git-tracked files are never removed" test_never_touches_tracked

test_skips_non_repos() {
    setup_tree; sweep >/dev/null
    assert_file_exists "$H/norepo/tmp/keep.txt" "a dir that is not a git repo is left alone"
}
run_test "non-repo directories are skipped" test_skips_non_repos

test_staging_seven_days() {
    setup_tree; sweep >/dev/null
    assert_file_not_exists "$H/stage/old.html" "9-day-old staging file removed" || return 1
    assert_file_exists "$H/stage/fresh.html" "3-day-old staging file kept"
}
run_test "staging dirs age out after 7 days" test_staging_seven_days

test_dry_run_deletes_nothing() {
    setup_tree; local out; out=$(sweep --dry-run)
    assert_file_exists "$H/proj/tmp/old.txt" "dry run deletes nothing" || return 1
    assert_contains "$out" "old.txt" "dry run lists what it would remove"
}
run_test "--dry-run lists and deletes nothing" test_dry_run_deletes_nothing

test_report_line() {
    setup_tree; sweep >/dev/null
    assert_contains "$(cat "$REPORT")" "TMP_SWEEP:" "report line written" || return 1
    assert_contains "$(cat "$REPORT")" "files" "report names the file count"
}
run_test "writes a one-line report" test_report_line

test_skips_venvs_and_reports_them() {  # using a venv never touches its mtimes; deleting it breaks a tool in daily use
    setup_tree; mkdir -p "$H/proj/tmp/myvenv/lib"; : > "$H/proj/tmp/myvenv/pyvenv.cfg"
    printf 'x' > "$H/proj/tmp/myvenv/lib/mod.py"; touch -d '30 days ago' "$H/proj/tmp/myvenv/lib/mod.py" "$H/proj/tmp/myvenv/pyvenv.cfg"
    sweep >/dev/null
    assert_file_exists "$H/proj/tmp/myvenv/lib/mod.py" "files inside a venv under tmp/ are kept" || return 1
    assert_file_not_exists "$H/proj/tmp/old.txt" "the rest of tmp/ is still swept" || return 1
    assert_contains "$(cat "$REPORT")" "venv in tmp" "report names the venv to move" || return 1
    assert_contains "$(cat "$REPORT")" "proj/tmp/myvenv" "report gives its path"
}
run_test "venvs under tmp/ are skipped and reported" test_skips_venvs_and_reports_them

test_session_start_surfaces_report() {
    local h="$TEST_TMPDIR/ss"; mkdir -p "$h/.claude"; echo "TMP_SWEEP: freed 12 MB in 3 files (2026-10-27)" > "$h/.claude/.tmp-sweep-last"
    local w; w=$(HOME="$h" CONFIG_REPO="$REPO_ROOT" WARNINGS="" bash -c 'source "$CONFIG_REPO/global/hooks/checks/05-stale-detection.sh" >/dev/null 2>&1; printf "%s" "$WARNINGS"')
    assert_contains "$w" "TMP_SWEEP: freed 12 MB" "check 5.1b surfaces the last sweep report"
}
run_test "SessionStart surfaces the last sweep report" test_session_start_surfaces_report

test_session_end_runs_sweep() {
    local sync="$REPO_ROOT/global/hooks/config-auto-sync.sh"
    assert_contains "$(grep -E '^[^#]*tmp-sweep\.sh' "$sync")" "setup/scripts/tmp-sweep.sh" "SessionEnd names the sweep script" || return 1
    assert_contains "$(grep -E '^[^#]*setsid bash "\$TMP_SWEEP_SCRIPT"' "$sync")" "setsid" "SessionEnd starts it detached"
}
run_test "SessionEnd starts the sweep detached" test_session_end_runs_sweep

suite_summary
