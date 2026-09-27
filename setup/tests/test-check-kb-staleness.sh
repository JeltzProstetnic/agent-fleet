#!/usr/bin/env bash
# Tests for check 25: cross-project knowledge-base staleness (CFG-430).
# Startup git-sync-check syncs only the CURRENT project, so a person lookup
# into a sibling KB repo (~/social 25 days behind) silently returned "not
# found" for data that existed on origin. The check fetches the few KB-bearing
# sibling repos listed in setup/config/kb-repos.conf, bounded in time, and
# warns when any is behind. Never fabricates "fresh": a repo it could not
# fetch is reported as unchecked. TDD: written before the implementation.
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/test-check-helpers.sh"

suite_header "config-check.sh: KB sibling staleness (check 25)"

# Mock config repo + home; returns the patched hook path. The KB conf lives in
# TEST_TMPDIR and is handed over via KB_REPOS_CONF.
_kb_env() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="${1:-$TEST_TMPDIR/project}"
    mkdir -p "$mock_home/.claude" "$project_dir"
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    create_patched_script "$config_repo" "$mock_home" "$project_dir"
}

# A KB repo at ~/<name> tracking a bare remote; no FETCH_HEAD yet.
_kb_repo() {
    local name="$1"
    create_tracked_repo_main "$TEST_TMPDIR/home/$name" "$TEST_TMPDIR/$name-remote.git"
    rm -f "$TEST_TMPDIR/home/$name/.git/FETCH_HEAD"
}

# Push N commits to the remote from a second clone so ~/<name> falls behind.
_kb_advance_remote() {
    local name="$1" n="$2" i
    git clone "$TEST_TMPDIR/$name-remote.git" "$TEST_TMPDIR/$name-other" --quiet 2>/dev/null
    for i in $(seq 1 "$n"); do add_commit "$TEST_TMPDIR/$name-other" "remote change $i"; done
    (cd "$TEST_TMPDIR/$name-other" && git push --quiet 2>/dev/null)
}

_kb_conf() { printf '%s\n' "$@" > "$TEST_TMPDIR/kb-repos.conf"; echo "$TEST_TMPDIR/kb-repos.conf"; }
_kb_run() { KB_REPOS_CONF="$1" run_hook "$2"; }

test_behind_repo_warns_with_count() {
    local patched conf out
    patched=$(_kb_env)
    _kb_repo social
    _kb_advance_remote social 2
    conf=$(_kb_conf "# KB-bearing repos" "~/social")
    out=$(_kb_run "$conf" "$patched")
    assert_contains "$out" "KB_STALE:" "behind sibling → warning field" || return 1
    assert_contains "$out" "social (2 behind)" "repo and count named" || return 1
    assert_contains "$out" "pull --ff-only" "remedy named" || return 1
    assert_not_contains "$out" "KB_UNCHECKED" "a fetched repo is not 'unchecked'"
}
run_test "check 25: KB repo behind origin → KB_STALE names it with the commit count" test_behind_repo_warns_with_count

test_current_repo_silent() {
    local patched conf out
    patched=$(_kb_env)
    _kb_repo social
    conf=$(_kb_conf "~/social" "~/absent-kb")   # absent-kb is not on this machine
    out=$(_kb_run "$conf" "$patched")
    assert_not_contains "$out" "KB_STALE" "up-to-date repo is silent" || return 1
    assert_not_contains "$out" "KB_UNCHECKED" "a repo absent on this machine is skipped, not reported"
}
run_test "check 25: up-to-date repo and a repo absent on this machine are silent" test_current_repo_silent

test_no_upstream_and_missing_conf_silent() {
    local patched conf out
    patched=$(_kb_env)
    create_git_repo_main "$TEST_TMPDIR/home/notes"          # no remote at all
    conf=$(_kb_conf "~/notes")
    out=$(_kb_run "$conf" "$patched")
    assert_not_contains "$out" "KB_" "repo without upstream is skipped" || return 1
    out=$(KB_REPOS_CONF="$TEST_TMPDIR/does-not-exist.conf" run_hook "$patched")
    assert_not_contains "$out" "KB_" "no conf → silent" || return 1
    assert_contains "$(extract_additional_context "$out")" "HOSTNAME:" "rest of the payload intact"
}
run_test "check 25: no upstream or no conf → silent, payload intact" test_no_upstream_and_missing_conf_silent

test_current_project_is_excluded() {
    local patched conf out
    _kb_repo social
    _kb_advance_remote social 3
    patched=$(_kb_env "$TEST_TMPDIR/home/social")   # session runs IN the KB repo
    conf=$(_kb_conf "~/social")
    out=$(_kb_run "$conf" "$patched")
    assert_not_contains "$out" "KB_STALE" "the current project is step 0's job, not this check's"
}
run_test "check 25: the current project is excluded even when behind" test_current_project_is_excluded

test_fetch_failure_reported_as_unchecked() {
    local patched conf out
    patched=$(_kb_env)
    _kb_repo social
    (cd "$TEST_TMPDIR/home/social" && git remote set-url origin "$TEST_TMPDIR/gone-remote.git")
    conf=$(_kb_conf "~/social")
    out=$(_kb_run "$conf" "$patched")
    assert_not_contains "$out" "KB_STALE" "unknown is not stale" || return 1
    assert_contains "$out" "KB_UNCHECKED:" "unknown is not fresh either" || return 1
    assert_contains "$out" "social (fetch failed)" || return 1
    assert_contains "$(extract_additional_context "$out")" "HOSTNAME:" "hook survives the failure"
}
run_test "check 25: a failed fetch is reported as unchecked, never as fresh" test_fetch_failure_reported_as_unchecked

test_budget_exhausted_reports_unfetched() {
    local patched conf out
    patched=$(_kb_env)
    _kb_repo social
    _kb_advance_remote social 1
    conf=$(_kb_conf "~/social")
    out=$(KB_FETCH_BUDGET=0 _kb_run "$conf" "$patched")
    assert_not_contains "$out" "KB_STALE" "no fetch happened, so no count is claimed" || return 1
    assert_contains "$out" "KB_UNCHECKED:" || return 1
    assert_contains "$out" "social (not fetched" "budget exhaustion is named, not hidden as 0-behind"
}
run_test "check 25: time budget exhausted → repo reported as not fetched, not as fresh" test_budget_exhausted_reports_unfetched

test_recent_fetch_is_not_repeated() {
    local patched conf out
    patched=$(_kb_env)
    _kb_repo social
    # A fetch just SUCCEEDED (fresh, non-empty FETCH_HEAD); the remote is now
    # unreachable. Within KB_FETCH_MIN_AGE no fetch may be attempted, so no
    # failure appears. (A bare `touch` is not a fetch: it is exactly the empty
    # FETCH_HEAD a FAILED fetch leaves behind — see the test below.)
    git -C "$TEST_TMPDIR/home/social" fetch --quiet 2>/dev/null
    [ -s "$TEST_TMPDIR/home/social/.git/FETCH_HEAD" ] || { echo "fixture: fetch left no FETCH_HEAD" >&2; return 1; }
    (cd "$TEST_TMPDIR/home/social" && git remote set-url origin "$TEST_TMPDIR/gone-remote.git")
    conf=$(_kb_conf "~/social")
    out=$(_kb_run "$conf" "$patched")
    assert_not_contains "$out" "KB_UNCHECKED" "no fetch attempted within the min-age window" || return 1
    assert_not_contains "$out" "KB_STALE"
    out=$(KB_FETCH_MIN_AGE=0 _kb_run "$conf" "$patched")
    assert_contains "$out" "social (fetch failed)" "with the window closed the fetch is attempted"
}
run_test "check 25: a fetch younger than KB_FETCH_MIN_AGE is not repeated" test_recent_fetch_is_not_repeated

# A FAILED or killed fetch still rewrites FETCH_HEAD — empty, with a fresh
# mtime (git truncates it before contacting the remote). Read by mtime alone,
# the next start inside KB_FETCH_MIN_AGE skipped the fetch, compared against
# the OLD remote-tracking ref, and reported nothing at all: neither KB_STALE
# nor KB_UNCHECKED — "fresh" fabricated from a failure (CFG-611).
test_failed_fetch_is_not_a_recent_fetch() {
    local patched conf out url
    patched=$(_kb_env)
    _kb_repo social
    _kb_advance_remote social 3
    url=$(git -C "$TEST_TMPDIR/home/social" remote get-url origin)
    conf=$(_kb_conf "~/social")

    # Start 1: the remote is unreachable, the fetch fails.
    git -C "$TEST_TMPDIR/home/social" remote set-url origin "$TEST_TMPDIR/gone-remote.git"
    out=$(_kb_run "$conf" "$patched")
    assert_contains "$out" "social (fetch failed)" "fixture: start 1 could not fetch" || return 1
    [ -f "$TEST_TMPDIR/home/social/.git/FETCH_HEAD" ] && [ ! -s "$TEST_TMPDIR/home/social/.git/FETCH_HEAD" ] \
        || { echo "fixture: expected the empty FETCH_HEAD a failed fetch leaves" >&2; return 1; }

    # Start 2, a minute later: the remote is back. The failure was not a fetch.
    git -C "$TEST_TMPDIR/home/social" remote set-url origin "$url"
    out=$(_kb_run "$conf" "$patched")
    assert_contains "$out" "social (3 behind)" \
        "the empty FETCH_HEAD of a failed fetch must not suppress the next fetch"
}
run_test "check 25: a failed fetch's empty FETCH_HEAD does not count as a recent fetch" test_failed_fetch_is_not_a_recent_fetch

# Without a `timeout` binary (stock macOS, no coreutils) the fetch used to run
# UNBOUNDED: only the between-fetch budget applied, so one stalled remote could
# outlast Claude Code's hook timeout and drop the WHOLE SessionStart payload —
# the GH#12 symptom. The per-fetch bound must hold on every platform.
# "No timeout binary" is simulated honestly: a PATH that mirrors the real one
# minus `timeout`, so `command -v timeout` fails exactly as it would on a Mac.
_path_without_timeout() {
    local nobin="$TEST_TMPDIR/path-without-timeout" d f
    mkdir -p "$nobin"
    local IFS=:
    for d in $PATH; do
        [ -d "$d" ] || continue
        for f in "$d"/*; do
            [ -x "$f" ] && [ ! -d "$f" ] || continue
            [ "${f##*/}" = timeout ] && continue
            [ -e "$nobin/${f##*/}" ] || ln -s "$f" "$nobin/${f##*/}"
        done
    done
    echo "$nobin"
}

test_stalled_fetch_bounded_without_timeout_binary() {
    local patched conf out start elapsed nobin
    patched=$(_kb_env)
    _kb_repo social
    # The remote accepts the connection and then stalls for 30s.
    git -C "$TEST_TMPDIR/home/social" config remote.origin.uploadpack "sleep 30; git-upload-pack"
    conf=$(_kb_conf "~/social")
    nobin=$(_path_without_timeout)
    PATH="$nobin" command -v timeout >/dev/null 2>&1 && { echo "fixture: timeout still on PATH" >&2; return 1; }

    start=$(date +%s)
    out=$(PATH="$nobin" KB_FETCH_TIMEOUT=2 _kb_run "$conf" "$patched")
    elapsed=$(( $(date +%s) - start ))
    [ "$elapsed" -lt 15 ] || { echo "hook took ${elapsed}s: the stalled fetch was not bounded" >&2; return 1; }
    assert_contains "$out" "social (fetch failed)" "a fetch killed by the bound is unchecked, not fresh" || return 1
    assert_contains "$(extract_additional_context "$out")" "HOSTNAME:" "the rest of the payload is delivered"
}
run_test "check 25: without a timeout binary a stalled fetch is still bounded" test_stalled_fetch_bounded_without_timeout_binary

suite_summary
