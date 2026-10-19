#!/usr/bin/env bash
# Tests for cross-project-transfer.sh — one-call file handoff between projects (CFG-427)
source "$(dirname "$0")/test-helpers.sh"

suite_header "cross-project-transfer.sh (CFG-427: one-call cross-project handoff)"

# ── Fixture ──────────────────────────────────────────────────────────────────
# A throwaway config repo holding COPIES of the scripts (so inbox-file.sh resolves its
# repo root to the sandbox and can never write the real inbox), a registry naming the
# two projects, and two real git repos under a sandboxed HOME.
make_world() {
    local cfg="$TEST_TMPDIR/cfg"
    mkdir -p "$cfg/setup/scripts" "$cfg/cross-project"
    cp "$REPO_ROOT/setup/scripts/cross-project-transfer.sh" \
       "$REPO_ROOT/setup/scripts/inbox-file.sh" \
       "$REPO_ROOT/setup/scripts/inbox-lib.sh" \
       "$REPO_ROOT/setup/scripts/session-lock.sh" "$cfg/setup/scripts/"
    # The commit path runs the same staged-diff credential scan a hand-typed commit gets.
    mkdir -p "$cfg/global/hooks"
    cp "$REPO_ROOT/global/hooks/secret-commit-guard.sh" "$cfg/global/hooks/"
    cat > "$cfg/registry.md" << 'EOF'
# Project Registry

## Projects

| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
| srcproj | P1 | — | `~/srcproj` | private | all | research | active | |
| dst-renamed | P2 | — | `~/dstproj` | private | all | code | active | |

## Machines
EOF
    local r
    for r in srcproj dstproj; do
        mkdir -p "$TEST_TMPDIR/$r"
        git -C "$TEST_TMPDIR/$r" init -q
        echo "# $r" > "$TEST_TMPDIR/$r/README.md"
        git -C "$TEST_TMPDIR/$r" add README.md
        git -C "$TEST_TMPDIR/$r" commit -qm init
    done
    mkdir -p "$TEST_TMPDIR/srcproj/docs"
    cat > "$TEST_TMPDIR/srcproj/docs/spec.md" << 'EOF'
# Widget Spec

The widget turns input into output without losing the plot.

## Details

More text here.
EOF
    git -C "$TEST_TMPDIR/srcproj" add docs/spec.md
    git -C "$TEST_TMPDIR/srcproj" commit -qm "add spec"
}

# Run as from a plain terminal: without the environment Claude Code gives its tool
# subprocesses. Inside a session whose sandbox hides every CC process (CFG-673), the
# boundary check now refuses — these tests are about the transfer itself, and must not
# depend on whether the machine running the suite can see its own session. The
# session-context cases set that environment explicitly (see "cannot see" below).
xfer() {
    env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CC_SESSION_ID \
        bash "$TEST_TMPDIR/cfg/setup/scripts/cross-project-transfer.sh" "$@" > "$TEST_TMPDIR/out.log" 2>&1
}

commits() { git -C "$TEST_TMPDIR/$1" rev-list --count HEAD; }
inbox()   { cat "$TEST_TMPDIR/cfg/cross-project/inbox/"*.md 2>/dev/null; }

# ── Tests ────────────────────────────────────────────────────────────────────

test_copies_into_target_docs() {
    make_world
    xfer "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" || { cat "$TEST_TMPDIR/out.log"; return 1; }
    assert_file_exists "$TEST_TMPDIR/dstproj/docs/spec.md" || return 1
    cmp -s "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/spec.md" \
        || { echo "    copy differs from the source"; return 1; }
    assert_file_contains "$TEST_TMPDIR/srcproj/docs/spec.md" "turns input into output" "source untouched without --replace-with-pointer"
}
run_test "copies the file into the target's docs/ (source untouched by default)" test_copies_into_target_docs

test_project_root_target_means_docs() {
    make_world
    xfer "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj" || { cat "$TEST_TMPDIR/out.log"; return 1; }
    assert_file_exists "$TEST_TMPDIR/dstproj/docs/spec.md"
}
run_test "a project-root target lands in its docs/ (created if missing)" test_project_root_target_means_docs

test_files_inbox_item() {
    make_world
    xfer "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" || { cat "$TEST_TMPDIR/out.log"; return 1; }
    local items
    items=$(inbox)
    assert_contains "$items" "- [ ] **dst-renamed** [work]" "item addressed to the REGISTRY name, typed" || return 1
    assert_contains "$items" "Widget Spec" "auto-description carries the title" || return 1
    assert_contains "$items" "docs/spec.md" || return 1
    assert_contains "$items" "srcproj" "names where it came from" || return 1
    assert_eq "1" "$(inbox | grep -c '^- \[ \]')" "exactly one single-line item"
}
run_test "files one typed inbox item for the target, via inbox-file.sh" test_files_inbox_item

test_pointer_stub_replaces_source() {
    make_world
    xfer "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" --replace-with-pointer \
        || { cat "$TEST_TMPDIR/out.log"; return 1; }
    local stub="$TEST_TMPDIR/srcproj/docs/spec.md"
    assert_file_contains "$stub" "~/dstproj/docs/spec.md" "canonical location" || return 1
    assert_file_contains "$stub" "dst-renamed" "target project named" || return 1
    assert_file_contains "$stub" "Widget Spec" "title kept" || return 1
    assert_file_contains "$stub" "turns input into output" "summary kept" || return 1
    assert_file_not_contains "$stub" "More text here." "body moved, not duplicated"
}
run_test "--replace-with-pointer leaves a stub: canonical location + summary" test_pointer_stub_replaces_source

test_commits_both_repos_only_their_paths() {
    make_world
    # Another session's staged work in the target must NOT be swept into our commit.
    echo "unrelated" > "$TEST_TMPDIR/dstproj/other.txt"
    git -C "$TEST_TMPDIR/dstproj" add other.txt
    local s0 d0
    s0=$(commits srcproj); d0=$(commits dstproj)
    xfer "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" --replace-with-pointer \
        || { cat "$TEST_TMPDIR/out.log"; return 1; }
    assert_eq "$((s0 + 1))" "$(commits srcproj)" "one commit in the source" || return 1
    assert_eq "$((d0 + 1))" "$(commits dstproj)" "one commit in the target" || return 1
    assert_eq "docs/spec.md" "$(git -C "$TEST_TMPDIR/dstproj" show --name-only --format= HEAD)" || return 1
    assert_eq "docs/spec.md" "$(git -C "$TEST_TMPDIR/srcproj" show --name-only --format= HEAD)" || return 1
    git -C "$TEST_TMPDIR/dstproj" diff --cached --name-only | grep -qx other.txt \
        || { echo "    the unrelated staged file was committed or unstaged"; return 1; }
}
run_test "commits exactly the transferred paths in both repos" test_commits_both_repos_only_their_paths

test_no_commit_flag() {
    make_world
    local s0 d0
    s0=$(commits srcproj); d0=$(commits dstproj)
    xfer "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" --replace-with-pointer --no-commit \
        || { cat "$TEST_TMPDIR/out.log"; return 1; }
    assert_eq "$s0" "$(commits srcproj)" || return 1
    assert_eq "$d0" "$(commits dstproj)" || return 1
    assert_file_exists "$TEST_TMPDIR/dstproj/docs/spec.md"
}
run_test "--no-commit copies and stubs but commits nothing" test_no_commit_flag

test_refuses_to_overwrite_destination() {
    make_world
    mkdir -p "$TEST_TMPDIR/dstproj/docs"
    echo "their own spec" > "$TEST_TMPDIR/dstproj/docs/spec.md"
    assert_failure xfer "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" --replace-with-pointer || return 1
    assert_file_contains "$TEST_TMPDIR/dstproj/docs/spec.md" "their own spec" || return 1
    assert_file_contains "$TEST_TMPDIR/srcproj/docs/spec.md" "More text here." "source untouched" || return 1
    assert_eq "" "$(inbox)" "no inbox item for a refused transfer"
}
run_test "refuses to overwrite an existing destination; changes nothing" test_refuses_to_overwrite_destination

test_unknown_target_project_rolls_back() {
    make_world
    mkdir -p "$TEST_TMPDIR/stranger"
    git -C "$TEST_TMPDIR/stranger" init -q
    assert_failure xfer "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/stranger/docs/" --replace-with-pointer || return 1
    assert_file_not_exists "$TEST_TMPDIR/stranger/docs/spec.md" "copy rolled back" || return 1
    assert_file_contains "$TEST_TMPDIR/srcproj/docs/spec.md" "More text here." "source untouched"
}
run_test "an unregistered target: inbox refuses, the copy is rolled back" test_unknown_target_project_rolls_back

test_refuses_same_project() {
    make_world
    assert_failure xfer "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/srcproj/archive/" || return 1
    assert_file_contains "$TEST_TMPDIR/out.log" "same project"
}
run_test "refuses a transfer within one project" test_refuses_same_project

test_pointer_only_for_text_docs() {
    make_world
    printf 'print("hi")\n' > "$TEST_TMPDIR/srcproj/tool.py"
    assert_failure xfer "$TEST_TMPDIR/srcproj/tool.py" "$TEST_TMPDIR/dstproj/docs/" --replace-with-pointer || return 1
    assert_file_not_exists "$TEST_TMPDIR/dstproj/docs/tool.py" || return 1
    assert_file_contains "$TEST_TMPDIR/srcproj/tool.py" 'print("hi")'
}
run_test "a pointer stub is refused for non-document files (would break them)" test_pointer_only_for_text_docs

test_dry_run_changes_nothing() {
    make_world
    local s0 d0
    s0=$(commits srcproj); d0=$(commits dstproj)
    xfer "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" --replace-with-pointer --dry-run \
        || { cat "$TEST_TMPDIR/out.log"; return 1; }
    assert_file_not_exists "$TEST_TMPDIR/dstproj/docs/spec.md" || return 1
    assert_file_contains "$TEST_TMPDIR/srcproj/docs/spec.md" "More text here." || return 1
    assert_eq "" "$(inbox)" || return 1
    assert_eq "$s0" "$(commits srcproj)" || return 1
    assert_file_contains "$TEST_TMPDIR/out.log" "dstproj/docs/spec.md"
}
run_test "--dry-run prints the plan and changes nothing" test_dry_run_changes_nothing

test_refuses_target_with_live_session() {
    # The boundary rule: never write into a project whose session is running. A fake "CC"
    # (matched through the liveness check's own override) sits in the target repo.
    make_world
    ( cd "$TEST_TMPDIR/dstproj" && exec sleep 37.5 ) </dev/null >/dev/null 2>&1 &
    local fake=$! i
    for i in $(seq 1 20); do
        [[ "$(readlink "/proc/$fake/cwd" 2>/dev/null)" == "$TEST_TMPDIR/dstproj" ]] && break
        sleep 0.1
    done
    local rc=0
    _CC_PROC_RE='sleep 37\.5' xfer "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" \
        --replace-with-pointer || rc=$?
    kill "$fake" 2>/dev/null; wait "$fake" 2>/dev/null
    [[ "$rc" -ne 0 ]] || { echo "    transfer into a live project was not refused"; return 1; }
    assert_file_not_exists "$TEST_TMPDIR/dstproj/docs/spec.md" || return 1
    assert_file_contains "$TEST_TMPDIR/srcproj/docs/spec.md" "More text here." || return 1
    assert_eq "" "$(inbox)" || return 1
    assert_file_contains "$TEST_TMPDIR/out.log" "live Claude Code session"
}
if [[ -d /proc/self ]]; then
    run_test "refuses to write into a project with a live session" test_refuses_target_with_live_session
else
    skip_test "refuses to write into a project with a live session" "needs /proc"
fi

# ── CFG-427 repair: WHOSE session is live ────────────────────────────────────────
# Run the transfer under a fake "CC" ANCESTOR cwd'd in <dir> — the way Claude Code is the
# ancestor of every Bash-tool command. `rc=…; exit` keeps bash from exec'ing the child in
# place of the marker process.
xfer_from_session_in() {
    local dir="$1"; shift
    ( cd "$dir" && _CC_PROC_RE='FAKECC-MARKER' bash -c 'rc=0; bash "$@" || rc=$?; exit $rc' FAKECC-MARKER \
        "$TEST_TMPDIR/cfg/setup/scripts/cross-project-transfer.sh" "$@" ) > "$TEST_TMPDIR/out.log" 2>&1
}

# A live CC (not the caller) cwd'd in <dir>: sets FAKE_PID.
start_live_session_in() {
    ( cd "$1" && exec sleep 38.5 ) </dev/null >/dev/null 2>&1 &
    FAKE_PID=$!
    local i
    for i in $(seq 1 20); do
        [[ "$(readlink "/proc/$FAKE_PID/cwd" 2>/dev/null)" == "$1" ]] && break
        sleep 0.1
    done
}

test_session_in_target_may_pull() {
    # ⛔ The check excluded only the script's own DESCENDANTS ($$). The calling session's CC
    #    is an ANCESTOR, so a session working in the target that pulled a file into its own
    #    repo was refused as "has a live Claude Code session".
    make_world
    local rc=0
    xfer_from_session_in "$TEST_TMPDIR/dstproj" "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" || rc=$?
    assert_eq "0" "$rc" "exit status ($(tr '\n' ' ' < "$TEST_TMPDIR/out.log"))" || return 1
    assert_file_exists "$TEST_TMPDIR/dstproj/docs/spec.md"
}

test_live_source_blocks_pointer() {
    # ⛔ Only the TARGET was checked, but --replace-with-pointer rewrites and commits in the
    #    SOURCE — into a live project, which the boundary rule forbids whoever writes.
    make_world
    start_live_session_in "$TEST_TMPDIR/srcproj"
    local rc=0 before; before="$(commits srcproj)"
    _CC_PROC_RE='sleep 38\.5' xfer "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" \
        --replace-with-pointer || rc=$?
    kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null
    [[ "$rc" -ne 0 ]] || { echo "    a pointer stub was written into a live source project"; return 1; }
    assert_file_contains "$TEST_TMPDIR/srcproj/docs/spec.md" "More text here." || return 1
    assert_eq "$before" "$(commits srcproj)" "no commit in the live source" || return 1
    assert_file_not_exists "$TEST_TMPDIR/dstproj/docs/spec.md" || return 1
    assert_eq "" "$(inbox)" || return 1
    assert_file_contains "$TEST_TMPDIR/out.log" "srcproj has a live Claude Code session"
}

test_live_source_does_not_block_plain_copy() {
    # Without --replace-with-pointer the source is only READ — a live source is no reason to refuse.
    make_world
    start_live_session_in "$TEST_TMPDIR/srcproj"
    local rc=0
    _CC_PROC_RE='sleep 38\.5' xfer "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" || rc=$?
    kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null
    assert_eq "0" "$rc" "exit status ($(tr '\n' ' ' < "$TEST_TMPDIR/out.log"))" || return 1
    assert_file_exists "$TEST_TMPDIR/dstproj/docs/spec.md"
}

test_session_in_source_may_stub_its_own_file() {
    # The usual caller: the source's own session hands a file off and stubs it.
    make_world
    local rc=0
    xfer_from_session_in "$TEST_TMPDIR/srcproj" "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" \
        --replace-with-pointer || rc=$?
    assert_eq "0" "$rc" "exit status ($(tr '\n' ' ' < "$TEST_TMPDIR/out.log"))" || return 1
    assert_file_contains "$TEST_TMPDIR/srcproj/docs/spec.md" "Moved."
}

if [[ -d /proc/self ]]; then
    run_test "the target's own session may pull a file in (its CC is the caller's ancestor)" test_session_in_target_may_pull
    run_test "--replace-with-pointer refuses a source with a live session (not the caller's)" test_live_source_blocks_pointer
    run_test "a live source does not block a plain copy (the source is only read)" test_live_source_does_not_block_plain_copy
    run_test "the source's own session may stub its file" test_session_in_source_may_stub_its_own_file
else
    skip_test "liveness: caller exclusion and source check" "needs /proc"
fi

# ── CFG-427 x CFG-673: a scan that can see no Claude Code process proves nothing ──────
# ⛔ Inside Claude Code's Bash sandbox a PID namespace hides the host's processes — the
#    caller's own CC and every rival alike. check_lock answers "cannot determine" (rc 4)
#    there since CFG-673; this script called _project_has_live_cc directly, found nobody
#    because it could see nobody, and copied, committed and filed an inbox item into a
#    project with a live session — from exactly the context it is meant to run in.
# A session-context run whose scan sees no CC: _CC_SELF_PID set empty = no resolvable own
# CC, a matcher that recognises nothing = no CC anywhere. Real run unless $1 is --dry-run.
xfer_blind_in_session() {
    CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=blind-test-session _CC_SELF_PID= _CC_PROC_RE='NO-CC-PROCESS-MATCHES-THIS' \
        bash "$TEST_TMPDIR/cfg/setup/scripts/cross-project-transfer.sh" "$@" > "$TEST_TMPDIR/out.log" 2>&1
}

test_blind_scan_in_session_refuses() {
    make_world
    local s0 d0 rc=0
    s0=$(commits srcproj); d0=$(commits dstproj)
    xfer_blind_in_session "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" --replace-with-pointer || rc=$?
    assert_eq "2" "$rc" "a blind scan inside a session must refuse ($(tr '\n' ' ' < "$TEST_TMPDIR/out.log"))" || return 1
    assert_file_contains "$TEST_TMPDIR/out.log" "cannot see any Claude Code process" || return 1
    assert_file_not_exists "$TEST_TMPDIR/dstproj/docs/spec.md" "nothing copied" || return 1
    assert_file_contains "$TEST_TMPDIR/srcproj/docs/spec.md" "More text here." "no stub" || return 1
    assert_eq "$d0" "$(commits dstproj)" "no commit in the target" || return 1
    assert_eq "$s0" "$(commits srcproj)" "no commit in the source" || return 1
    assert_eq "" "$(inbox)" "no inbox item"
}
run_test "CFG-427 x CFG-673: inside a session that can see no CC process, a transfer refuses" test_blind_scan_in_session_refuses

test_blind_scan_in_session_refuses_dry_run() {
    # The dry-run gives the same verdict: it passed with "DRY RUN ... copy ... commit".
    make_world
    local rc=0
    xfer_blind_in_session "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" --dry-run || rc=$?
    assert_eq "2" "$rc" "the dry-run must refuse as the real run does" || return 1
    assert_file_not_contains "$TEST_TMPDIR/out.log" "DRY RUN" "no plan is printed for a transfer that would be refused"
}
run_test "CFG-427 x CFG-673: ... and its --dry-run gives the same verdict" test_blind_scan_in_session_refuses_dry_run

test_blind_scan_from_terminal_warns_and_proceeds() {
    # From a plain terminal (`afleet transfer`, no session environment) seeing no CC is the
    # normal case — as for afleet's own lock scan before any CC exists: say so, and go on.
    make_world
    local rc=0
    env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CC_SESSION_ID _CC_SELF_PID= _CC_PROC_RE='NO-CC-PROCESS-MATCHES-THIS' \
        bash "$TEST_TMPDIR/cfg/setup/scripts/cross-project-transfer.sh" \
        "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" > "$TEST_TMPDIR/out.log" 2>&1 || rc=$?
    assert_eq "0" "$rc" "exit status ($(tr '\n' ' ' < "$TEST_TMPDIR/out.log"))" || return 1
    assert_file_exists "$TEST_TMPDIR/dstproj/docs/spec.md" || return 1
    assert_file_contains "$TEST_TMPDIR/out.log" "no Claude Code process is visible" "the limitation is named"
}
run_test "CFG-427 x CFG-673: from a plain terminal, seeing no CC warns and proceeds" test_blind_scan_from_terminal_warns_and_proceeds

test_visible_own_session_still_proceeds() {
    # Control: a session that CAN see itself (its CC is the caller's ancestor) is not blind.
    make_world
    local rc=0
    ( cd "$TEST_TMPDIR/dstproj" && CLAUDECODE=1 _CC_PROC_RE='FAKECC-MARKER' bash -c 'rc=0; bash "$@" || rc=$?; exit $rc' FAKECC-MARKER \
        "$TEST_TMPDIR/cfg/setup/scripts/cross-project-transfer.sh" \
        "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" ) > "$TEST_TMPDIR/out.log" 2>&1 || rc=$?
    assert_eq "0" "$rc" "exit status ($(tr '\n' ' ' < "$TEST_TMPDIR/out.log"))" || return 1
    assert_file_not_contains "$TEST_TMPDIR/out.log" "no Claude Code process" "a visible session is not warned about"
}
if [[ -d /proc/self ]]; then
    run_test "CFG-427 x CFG-673: a session that can see its own CC is not blind" test_visible_own_session_still_proceeds
else
    skip_test "CFG-427 x CFG-673: a session that can see its own CC is not blind" "needs /proc"
fi

# The mechanism itself, where this machine allows it: a fresh PID namespace with its own
# /proc hides every process outside it, as the Bash sandbox does — no overrides at all.
test_pid_namespace_refuses() {
    make_world
    local rc=0
    ( cd "$TEST_TMPDIR" && CLAUDECODE=1 unshare -p -f --mount-proc \
        bash "$TEST_TMPDIR/cfg/setup/scripts/cross-project-transfer.sh" \
        "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" --dry-run ) > "$TEST_TMPDIR/out.log" 2>&1 || rc=$?
    assert_eq "2" "$rc" "inside a PID namespace the transfer must refuse ($(tr '\n' ' ' < "$TEST_TMPDIR/out.log"))" || return 1
    assert_file_contains "$TEST_TMPDIR/out.log" "cannot see any Claude Code process"
}
test_missing_lock_lib_is_blind_too() {
    # No session-lock.sh, no check at all: refused inside a session, warned from a terminal.
    make_world
    rm -f "$TEST_TMPDIR/cfg/setup/scripts/session-lock.sh"
    local rc=0
    ( CLAUDECODE=1 bash "$TEST_TMPDIR/cfg/setup/scripts/cross-project-transfer.sh" \
        "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" ) > "$TEST_TMPDIR/out.log" 2>&1 || rc=$?
    assert_eq "2" "$rc" "no liveness library inside a session must refuse" || return 1
    assert_file_not_exists "$TEST_TMPDIR/dstproj/docs/spec.md" "nothing copied" || return 1
    xfer "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" || { cat "$TEST_TMPDIR/out.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/out.log" "session-lock.sh not found" "the terminal run names the missing check"
}
run_test "CFG-427 x CFG-673: no session-lock.sh is the same blindness (refuse in a session, warn outside)" test_missing_lock_lib_is_blind_too

if command -v unshare >/dev/null 2>&1 && unshare -p -f --mount-proc true >/dev/null 2>&1; then
    run_test "CFG-427 x CFG-673: in a real PID namespace (the sandbox's view) the transfer refuses" test_pid_namespace_refuses
else
    skip_test "CFG-427 x CFG-673: in a real PID namespace (the sandbox's view) the transfer refuses" "cannot create a PID namespace here"
fi

# ── CFG-427 repair: the tool's own commits get the credential scan ──────────────────
# ⛔ secret-commit-guard.sh is a PreToolUse hook: it sees the Bash command TEXT, which for a
#    transfer is `bash …/cross-project-transfer.sh …`, not a `git commit`. The script's own
#    commits (into ANOTHER project's repo) were therefore never scanned — a token in a
#    transferred doc was committed silently, while the same commit typed by hand is blocked.

# A token-shaped value, built at run time so this file never contains one.
fake_token() { printf 'ghp_%s' "$(printf 'A%.0s' $(seq 1 36))"; }

add_notes_with_token() {
    printf '# Notes\n\nThe deploy token is %s for now.\n' "$(fake_token)" > "$TEST_TMPDIR/srcproj/docs/notes.md"
    git -C "$TEST_TMPDIR/srcproj" add docs/notes.md
    git -C "$TEST_TMPDIR/srcproj" commit -qm notes
}

test_secret_in_file_is_never_committed() {
    make_world
    add_notes_with_token
    local s0 d0 rc=0
    s0=$(commits srcproj); d0=$(commits dstproj)
    xfer "$TEST_TMPDIR/srcproj/docs/notes.md" "$TEST_TMPDIR/dstproj/docs/" --replace-with-pointer || rc=$?
    [[ "$rc" -ne 0 ]] || { echo "    a token-bearing file was transferred and committed"; return 1; }
    assert_file_contains "$TEST_TMPDIR/out.log" "BLOCKED (CFG-652)" "the guard's own report is shown" || return 1
    assert_eq "$d0" "$(commits dstproj)" "no commit in the target" || return 1
    assert_eq "$s0" "$(commits srcproj)" "no commit in the source" || return 1
    assert_file_not_exists "$TEST_TMPDIR/dstproj/docs/notes.md" "copy rolled back" || return 1
    assert_eq "" "$(git -C "$TEST_TMPDIR/dstproj" diff --cached --name-only)" "target index left clean" || return 1
    assert_file_contains "$TEST_TMPDIR/srcproj/docs/notes.md" "The deploy token is" "no stub written" || return 1
    assert_eq "" "$(inbox)" "no inbox item"
}
run_test "a credential in the file: blocked by the commit guard before anything is committed" \
    test_secret_in_file_is_never_committed

test_secret_in_stub_is_never_committed() {
    # The stub carries the summary; a --summary holding a credential would be committed
    # into the SOURCE repo. Scanned too, before either repo gets a commit.
    make_world
    local s0 d0 rc=0
    s0=$(commits srcproj); d0=$(commits dstproj)
    xfer "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" --replace-with-pointer \
        --summary "use $(fake_token) to deploy" || rc=$?
    [[ "$rc" -ne 0 ]] || { echo "    a token-bearing stub was committed"; return 1; }
    assert_file_contains "$TEST_TMPDIR/out.log" "BLOCKED (CFG-652)" || return 1
    assert_eq "$s0" "$(commits srcproj)" "no commit in the source" || return 1
    assert_eq "$d0" "$(commits dstproj)" "no commit in the target" || return 1
    assert_file_contains "$TEST_TMPDIR/srcproj/docs/spec.md" "More text here." "source restored" || return 1
    assert_eq "" "$(git -C "$TEST_TMPDIR/srcproj" status --porcelain)" "source tree left clean" || return 1
    assert_file_not_exists "$TEST_TMPDIR/dstproj/docs/spec.md" "copy rolled back"
}
run_test "a credential in the pointer stub: blocked before either repo gets a commit" \
    test_secret_in_stub_is_never_committed

test_missing_guard_fails_closed() {
    make_world
    rm -f "$TEST_TMPDIR/cfg/global/hooks/secret-commit-guard.sh"
    local d0 rc=0; d0=$(commits dstproj)
    xfer "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" || rc=$?
    [[ "$rc" -ne 0 ]] || { echo "    committed without the credential scan"; return 1; }
    assert_file_contains "$TEST_TMPDIR/out.log" "secret-commit-guard" || return 1
    assert_eq "$d0" "$(commits dstproj)" || return 1
    assert_file_not_exists "$TEST_TMPDIR/dstproj/docs/spec.md" || return 1
    # --no-commit needs no scan here: the hand commit that follows goes through the hook.
    xfer "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" --no-commit \
        || { cat "$TEST_TMPDIR/out.log"; return 1; }
    assert_file_exists "$TEST_TMPDIR/dstproj/docs/spec.md"
}
run_test "no guard to scan with: refuses to commit (fail closed); --no-commit still works" \
    test_missing_guard_fails_closed

test_ignored_target_path_changes_nothing() {
    # A gitignored target path cannot be committed; the run used to die after the inbox item
    # and the stub were written, leaving the only canonical copy an ignored, untracked file.
    make_world
    echo "docs/" > "$TEST_TMPDIR/dstproj/.gitignore"
    git -C "$TEST_TMPDIR/dstproj" add .gitignore
    git -C "$TEST_TMPDIR/dstproj" commit -qm ignore
    local rc=0
    xfer "$TEST_TMPDIR/srcproj/docs/spec.md" "$TEST_TMPDIR/dstproj/docs/" --replace-with-pointer || rc=$?
    [[ "$rc" -ne 0 ]] || { echo "    transfer into an ignored path reported success"; return 1; }
    assert_file_not_exists "$TEST_TMPDIR/dstproj/docs/spec.md" "copy rolled back" || return 1
    assert_file_contains "$TEST_TMPDIR/srcproj/docs/spec.md" "More text here." "no stub" || return 1
    assert_eq "" "$(inbox)" "no inbox item"
}
run_test "an ignored target path: refused before the inbox item or the stub" test_ignored_target_path_changes_nothing

test_afleet_transfer_subcommand() {
    local out
    out=$(CONFIG_REPO="$TEST_TMPDIR" bash "$REPO_ROOT/setup/scripts/afleet.sh" transfer --help 2>&1) || true
    assert_contains "$out" "cross-project-transfer" "afleet transfer delegates to the transfer script"
}
run_test "afleet transfer delegates to cross-project-transfer.sh" test_afleet_transfer_subcommand

test_afleet_transfer_skips_the_pre_picker_pull() {
    # ⛔ afleet.sh pulls the config repo before it even parses its arguments (the picker needs
    #    a current registry). A transfer run from inside a live session inherited that pull —
    #    and on divergence its rebase/stash — as a side effect. The launcher's pull is for
    #    the picker; `transfer` never shows one.
    local cfg="$TEST_TMPDIR/cfgrepo"
    mkdir -p "$cfg/.git" "$cfg/setup/scripts"
    printf '#!/usr/bin/env bash\ntouch "%s/pulled"\n' "$TEST_TMPDIR" > "$cfg/setup/scripts/git-sync-check.sh"
    CONFIG_REPO="$cfg" bash "$REPO_ROOT/setup/scripts/afleet.sh" --help >/dev/null 2>&1 || true
    [[ -e "$TEST_TMPDIR/pulled" ]] || { echo "    control: the stub pull never ran for a normal launch"; return 1; }
    rm -f "$TEST_TMPDIR/pulled"
    CONFIG_REPO="$cfg" bash "$REPO_ROOT/setup/scripts/afleet.sh" transfer --help >/dev/null 2>&1 || true
    assert_file_not_exists "$TEST_TMPDIR/pulled" "afleet transfer must not pull the config repo"
}
run_test "afleet transfer does not pull the config repo first" test_afleet_transfer_skips_the_pre_picker_pull

suite_summary
