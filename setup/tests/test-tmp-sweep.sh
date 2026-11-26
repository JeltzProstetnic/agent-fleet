#!/usr/bin/env bash
# Tests for setup/scripts/tmp-sweep.sh (CFG-851, CFG-1112): the fleet never deleted its own scratch,
# then deleted too much. Untracked files in <project>/tmp/ older than TMP_SWEEP_DAYS (14) are MOVED
# into a dated quarantine (TMP_SWEEP_QUARANTINE/<date>/<path relative to home>) and purged after
# TMP_SWEEP_QUARANTINE_DAYS (30); staging dirs (TMP_SWEEP_STAGING, 7 days) are still deleted;
# git-tracked files are never touched; one-line report. Everything runs in a sandbox: HOME is the
# test tmpdir and every TMP_SWEEP_* path is set explicitly — never the real home or quarantine.
source "$(dirname "$0")/test-helpers.sh"
SCRIPT="$REPO_ROOT/setup/scripts/tmp-sweep.sh"
suite_header "tmp-sweep.sh"

TODAY=$(date +%Y-%m-%d)
days_ago() { date -d "$TODAY -$1 days" +%Y-%m-%d; }
present() { [[ -e "$1" ]] && echo present || echo absent; }

setup_tree() {
    H="$TEST_TMPDIR/home"; Q="$TEST_TMPDIR/quarantine"; rm -rf "$H" "$Q"
    mkdir -p "$H/proj/tmp/sub" "$H/stage" "$H/norepo/tmp"
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
sweep() {
    TMP_SWEEP_HOME="$H" TMP_SWEEP_STAGING="$H/stage" TMP_SWEEP_REPORT="$REPORT" \
    TMP_SWEEP_QUARANTINE="$Q" bash "$SCRIPT" "$@" 2>&1
}

test_quarantines_old_untracked_files() {
    setup_tree; local m1 m2; m1=$(stat -c %Y "$H/proj/tmp/old.txt"); m2=$(stat -c %Y "$H/proj/tmp/sub/deep.bin")
    sweep >/dev/null
    assert_file_not_exists "$H/proj/tmp/old.txt" "20-day-old untracked file left tmp/" || return 1
    assert_file_not_exists "$H/proj/tmp/sub/deep.bin" "nested old file left tmp/" || return 1
    assert_file_exists "$H/proj/tmp/new.txt" "fresh file kept" || return 1
    assert_file_exists "$Q/$TODAY/proj/tmp/old.txt" "old file sits in today's day-dir under its path relative to home" || return 1
    assert_file_exists "$Q/$TODAY/proj/tmp/sub/deep.bin" "nested file keeps its relative path" || return 1
    assert_eq "old" "$(cat "$Q/$TODAY/proj/tmp/old.txt")" "quarantined content intact" || return 1
    assert_eq "deep" "$(cat "$Q/$TODAY/proj/tmp/sub/deep.bin")" "nested quarantined content intact" || return 1
    assert_eq "$m1" "$(stat -c %Y "$Q/$TODAY/proj/tmp/old.txt")" "mtime preserved (old.txt: $m1)" || return 1
    assert_eq "$m2" "$(stat -c %Y "$Q/$TODAY/proj/tmp/sub/deep.bin")" "mtime preserved (deep.bin: $m2)"
}
run_test "project tmp/: untracked files older than 14 days are quarantined, not deleted" test_quarantines_old_untracked_files

test_never_touches_tracked() {
    setup_tree; sweep >/dev/null
    assert_file_exists "$H/proj/tmp/tracked.txt" "git-tracked file under tmp/ is never removed" || return 1
    assert_eq "absent" "$(present "$Q/$TODAY/proj/tmp/tracked.txt")" "and never quarantined either"
}
run_test "project tmp/: git-tracked files are never touched" test_never_touches_tracked

test_skips_non_repos() {
    setup_tree; sweep >/dev/null
    assert_file_exists "$H/norepo/tmp/keep.txt" "a dir that is not a git repo is left alone"
}
run_test "non-repo directories are skipped" test_skips_non_repos

test_never_overwrites_quarantined_file() {
    setup_tree; mkdir -p "$Q/$TODAY/proj/tmp"
    printf 'earlier' > "$Q/$TODAY/proj/tmp/old.txt"; printf 'earlier1' > "$Q/$TODAY/proj/tmp/old.txt.1"
    sweep >/dev/null
    assert_eq "earlier" "$(cat "$Q/$TODAY/proj/tmp/old.txt")" "existing quarantine file untouched" || return 1
    assert_eq "earlier1" "$(cat "$Q/$TODAY/proj/tmp/old.txt.1")" "existing .1 untouched" || return 1
    assert_file_exists "$Q/$TODAY/proj/tmp/old.txt.2" "colliding file gets the next free numeric suffix" || return 1
    assert_eq "old" "$(cat "$Q/$TODAY/proj/tmp/old.txt.2")" "suffixed file carries the swept content" || return 1
    assert_file_not_exists "$H/proj/tmp/old.txt" "and the source left tmp/"
}
run_test "quarantine never overwrites: an existing destination gets a numeric suffix" test_never_overwrites_quarantined_file

test_purge_boundary() {
    setup_tree; local d31 d30; d31=$(days_ago 31); d30=$(days_ago 30)
    mkdir -p "$Q/$d31" "$Q/$d30" "$Q/notadate" "$Q/$d31-notes"
    printf 'a' > "$Q/$d31/a.txt"; printf 'b' > "$Q/$d30/b.txt"; printf 'c' > "$Q/notadate/c.txt"
    printf 'd' > "$Q/$d31-notes/d.txt"; printf 'r' > "$Q/README"
    sweep >/dev/null
    assert_eq "absent" "$(present "$Q/$d31")" "day-dir 31 days old ($d31) purged" || return 1
    assert_file_exists "$Q/$d30/b.txt" "day-dir 30 days old ($d30) kept — purge is strictly older than 30 d" || return 1
    assert_file_exists "$Q/notadate/c.txt" "non-date dir under the quarantine root never touched" || return 1
    assert_file_exists "$Q/$d31-notes/d.txt" "dir whose name merely starts with a date never touched" || return 1
    assert_file_exists "$Q/README" "a plain file under the quarantine root never touched" || return 1
    assert_contains "$(cat "$REPORT")" "purged 1 day-dir" "report counts the purge"
}
run_test "purge removes only YYYY-MM-DD day-dirs older than 30 days" test_purge_boundary

test_purge_days_override() {
    setup_tree; local d6 d5; d6=$(days_ago 6); d5=$(days_ago 5)
    mkdir -p "$Q/$d6" "$Q/$d5"; printf 'a' > "$Q/$d6/a.txt"; printf 'b' > "$Q/$d5/b.txt"
    TMP_SWEEP_QUARANTINE_DAYS=5 sweep >/dev/null
    assert_eq "absent" "$(present "$Q/$d6")" "6-day-old day-dir purged at TMP_SWEEP_QUARANTINE_DAYS=5" || return 1
    assert_file_exists "$Q/$d5/b.txt" "5-day-old day-dir kept at TMP_SWEEP_QUARANTINE_DAYS=5" || return 1
    assert_contains "$(cat "$REPORT")" "older than 5 d" "report names the configured retention"
}
run_test "TMP_SWEEP_QUARANTINE_DAYS sets the purge boundary" test_purge_days_override

test_staging_seven_days() {
    setup_tree; sweep >/dev/null
    assert_file_not_exists "$H/stage/old.html" "9-day-old staging file removed" || return 1
    assert_file_exists "$H/stage/fresh.html" "3-day-old staging file kept" || return 1
    assert_not_contains "$(find "$Q" -type f 2>/dev/null)" "old.html" "staging files are deleted, never quarantined"
}
run_test "staging dirs still age out after 7 days, deleted not quarantined" test_staging_seven_days

test_dry_run_changes_nothing() {
    setup_tree; local d31; d31=$(days_ago 31); mkdir -p "$Q/$d31"; printf 'a' > "$Q/$d31/a.txt"
    local out; out=$(sweep --dry-run)
    assert_file_exists "$H/proj/tmp/old.txt" "dry run moves nothing" || return 1
    assert_eq "absent" "$(present "$Q/$TODAY")" "dry run creates no day-dir" || return 1
    assert_file_exists "$Q/$d31/a.txt" "dry run purges nothing" || return 1
    assert_file_exists "$H/stage/old.html" "dry run deletes no staging file" || return 1
    assert_file_not_exists "$REPORT" "dry run writes no report" || return 1
    assert_contains "$out" "would quarantine" "dry run says what it would quarantine" || return 1
    assert_contains "$out" "old.txt" "dry run names the file" || return 1
    assert_contains "$out" "would purge" "dry run says what it would purge" || return 1
    assert_contains "$out" "$d31" "dry run names the day-dir"
}
run_test "--dry-run lists quarantine and purge candidates and changes nothing" test_dry_run_changes_nothing

test_unmovable_file_stays_in_place() {  # dest dir exists but refuses writes: mv AND cp fail
    setup_tree; mkdir -p "$Q/$TODAY/proj/tmp"; chmod 0555 "$Q/$TODAY/proj/tmp"
    sweep >/dev/null; chmod 0755 "$Q/$TODAY/proj/tmp"
    assert_file_exists "$H/proj/tmp/old.txt" "file whose move and copy both failed stays in tmp/" || return 1
    assert_eq "old" "$(cat "$H/proj/tmp/old.txt")" "and is intact" || return 1
    assert_file_exists "$H/proj/tmp/sub/deep.bin" "file whose day-dir could not be created stays in tmp/" || return 1
    assert_eq "" "$(ls -A "$Q/$TODAY/proj/tmp")" "no partial copy left in quarantine" || return 1
    assert_contains "$(cat "$REPORT")" "2 files could not be quarantined" "report counts both errors"
}
if [[ $EUID -eq 0 ]]; then skip_test "a file that can be neither moved nor copied stays in place" "running as root, chmod cannot refuse mv/cp"
else run_test "a file that can be neither moved nor copied stays in place" test_unmovable_file_stays_in_place; fi

stub_bin() { # <name> <body> → a PATH dir in which <name> runs <body> instead of the real tool
    local d="$TEST_TMPDIR/stub"; mkdir -p "$d"
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$d/$1"; chmod +x "$d/$1"; echo "$d"
}

test_copy_fallback_when_mv_fails() {
    setup_tree; local stub m1; stub=$(stub_bin mv 'touch "$STUB_MARK"; exit 1'); m1=$(stat -c %Y "$H/proj/tmp/old.txt")
    STUB_MARK="$TEST_TMPDIR/mv-called" PATH="$stub:$PATH" sweep >/dev/null
    assert_file_exists "$TEST_TMPDIR/mv-called" "the sweep called the (stubbed, failing) mv" || return 1
    assert_file_exists "$Q/$TODAY/proj/tmp/old.txt" "file copied into quarantine when mv failed" || return 1
    assert_eq "old" "$(cat "$Q/$TODAY/proj/tmp/old.txt")" "copied content intact" || return 1
    assert_eq "$m1" "$(stat -c %Y "$Q/$TODAY/proj/tmp/old.txt")" "cp -p kept the mtime ($m1)" || return 1
    assert_file_not_exists "$H/proj/tmp/old.txt" "source removed only after the verified copy" || return 1
    assert_contains "$(cat "$REPORT")" "quarantined 2 files" "copied files count as quarantined"
}
run_test "when mv fails the file is copied, verified and only then removed" test_copy_fallback_when_mv_fails

test_unverified_copy_never_deletes() {  # mv fails and cmp says the copy differs: the source must survive
    setup_tree; local stub; stub=$(stub_bin mv 'exit 1'); stub=$(stub_bin cmp 'exit 1')
    PATH="$stub:$PATH" sweep >/dev/null
    assert_file_exists "$H/proj/tmp/old.txt" "source stays when the copy cannot be verified" || return 1
    assert_eq "old" "$(cat "$H/proj/tmp/old.txt")" "and is intact" || return 1
    assert_eq "absent" "$(present "$Q/$TODAY/proj/tmp/old.txt")" "the unverified copy is removed" || return 1
    assert_contains "$(cat "$REPORT")" "2 files could not be quarantined" "report counts the errors"
}
run_test "an unverified copy never costs the source" test_unverified_copy_never_deletes

test_unusable_quarantine_root_leaves_files() {  # the root is a plain file: no day-dir can exist
    setup_tree; : > "$Q"; sweep >/dev/null
    assert_file_exists "$H/proj/tmp/old.txt" "nothing leaves tmp/ when the quarantine root is unusable" || return 1
    assert_file_exists "$H/proj/tmp/sub/deep.bin" "nested file also stays" || return 1
    assert_contains "$(cat "$REPORT")" "2 files could not be quarantined" "report counts the errors"
}
run_test "an unusable quarantine root leaves every file in place" test_unusable_quarantine_root_leaves_files

test_report_line() {
    setup_tree; sweep >/dev/null; local r; r=$(cat "$REPORT")
    assert_eq "1" "$(wc -l < "$REPORT" | tr -d ' ')" "report is one line" || return 1
    assert_contains "$r" "TMP_SWEEP: quarantined 2 files (0 MB) to ~/quarantine/$TODAY/" "report names the count and the restore location (home shown as ~)" || return 1
    assert_contains "$r" "purged 0 day-dirs older than 30 d (0 MB)" "report names the purge" || return 1
    assert_contains "$r" "staging freed 0 MB in 1 files" "report keeps the staging numbers" || return 1
    assert_contains "$r" "($TODAY)" "report is dated" || return 1
    assert_not_contains "$r" "could not be quarantined" "no error note when nothing failed"
}
run_test "writes a one-line report with quarantine, purge and staging facts" test_report_line

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

test_header_describes_quarantine() {
    local hdr; hdr=$(head -30 "$SCRIPT" | grep '^#')
    assert_contains "$hdr" "quarantine" "header describes the quarantine" || return 1
    assert_contains "$hdr" "TMP_SWEEP_QUARANTINE_DAYS" "header names the retention knob"
}
run_test "script header describes the quarantine" test_header_describes_quarantine

test_session_start_surfaces_report() {
    local h="$TEST_TMPDIR/ss"; mkdir -p "$h/.claude"
    echo "TMP_SWEEP: quarantined 3 files (12 MB) to ~/.local/share/tmp-sweep-quarantine/2026-11-26/ (restore from there within 30 d), purged 0 day-dirs older than 30 d (0 MB), staging freed 2 MB in 5 files (2026-11-26)" > "$h/.claude/.tmp-sweep-last"
    local w; w=$(HOME="$h" CONFIG_REPO="$REPO_ROOT" WARNINGS="" bash -c 'source "$CONFIG_REPO/global/hooks/checks/05-stale-detection.sh" >/dev/null 2>&1; printf "%s" "$WARNINGS"')
    assert_contains "$w" "TMP_SWEEP: quarantined 3 files" "check 5.1b surfaces the last sweep report" || return 1
    assert_contains "$w" "~/.local/share/tmp-sweep-quarantine/2026-11-26/" "the startup line says where to restore from"
}
run_test "SessionStart surfaces the last sweep report incl. the restore location" test_session_start_surfaces_report

test_session_end_runs_sweep() {
    local sync="$REPO_ROOT/global/hooks/config-auto-sync.sh"
    assert_contains "$(grep -E '^[^#]*tmp-sweep\.sh' "$sync")" "setup/scripts/tmp-sweep.sh" "SessionEnd names the sweep script" || return 1
    assert_contains "$(grep -E '^[^#]*setsid bash "\$TMP_SWEEP_SCRIPT"' "$sync")" "setsid" "SessionEnd starts it detached"
}
run_test "SessionEnd starts the sweep detached" test_session_end_runs_sweep

suite_summary
