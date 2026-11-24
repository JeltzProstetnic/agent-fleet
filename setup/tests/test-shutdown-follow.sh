#!/usr/bin/env bash
# Tests for CFG-1043 / CFG-1044 — after a `cls` / `end` shutdown the follow-up command is typed into the
# session by itself: global/hooks/shutdown-follow.sh (UserPromptSubmit: arm / cancel / stamp) and
# setup/scripts/shutdown-follow.sh (the detached watcher: wait for "Shutdown complete", type /clear or
# /exit, submit `startup` only while caretaking is active), plus remote-session-follow-lib.sh (the
# typing stamp, the "Next:" hint). Layers as in test-remote-session.sh (fixtures: lib-remote-session-fixture.sh):
#   H. the hook on Claude Code's UserPromptSubmit JSON, the watcher replaced by a recording stub
#   A. the watcher on a fixture /proc + fake transcripts, keystrokes stubbed (the w_main pattern)
#   B. REAL ptys: the hook arms, the user types `cls`/`end` into a fake claude under script(1), the real
#      watcher (launched detached by the hook) types the follow-up through the root injector. SKIPPED
#      with the reason where no root path exists.
# No real Claude Code session is ever touched; no real afd is called (a stub under the sandboxed HOME).
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/lib-remote-session-fixture.sh"

HOOK="$REPO_ROOT/global/hooks/shutdown-follow.sh"
WATCHER="$REPO_ROOT/setup/scripts/shutdown-follow.sh"
SAFE_RUN="$REPO_ROOT/global/hooks/safe-run.sh"

suite_header "shutdown-follow (CFG-1043 / CFG-1044: cls → /clear, end → /exit by the session itself)"

# ── H: the hook ───────────────────────────────────────────────────────────────
# h_setup: a sandboxed HOME, the claude pid fixed (SHUTDOWN_FOLLOW_PID), the watcher a stub that records
# its argv in $H_LAUNCH (H_SLEEP: seconds it keeps running, then writes $H_LAUNCH.done).
h_setup() {
    export HOME="$TEST_TMPDIR/home"; mkdir -p "$HOME/.claude/logs" "$HOME/.claude/hooks"
    export SHUTDOWN_FOLLOW_DIR="$HOME/.local/state/shutdown-follow" SHUTDOWN_FOLLOW_PID=4242
    export SHUTDOWN_FOLLOW_SCRIPT="$TEST_TMPDIR/watcher" SHUTDOWN_FOLLOW_LOG="$HOME/.claude/logs/shutdown-follow.log"
    export H_LAUNCH="$TEST_TMPDIR/launched"; unset SHUTDOWN_FOLLOW_STAMP_TTL
    H_TR="$HOME/t.jsonl"; printf '%0100d' 0 > "$H_TR"   # 100 bytes: the arming offset
    H_STATE="$SHUTDOWN_FOLLOW_DIR/4242"
    cat > "$SHUTDOWN_FOLLOW_SCRIPT" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$H_LAUNCH"
sleep "${H_SLEEP:-0}"; echo done > "$H_LAUNCH.done"
EOF
    chmod +x "$SHUTDOWN_FOLLOW_SCRIPT"
}
h_teardown() { unset SHUTDOWN_FOLLOW_DIR SHUTDOWN_FOLLOW_PID SHUTDOWN_FOLLOW_SCRIPT SHUTDOWN_FOLLOW_LOG H_LAUNCH H_SLEEP; }
# h_prompt <text> [source] — the hook on a UserPromptSubmit payload; OUT = stdout, RC = exit code
h_prompt() {
    local json; json=$(python3 -c 'import json,sys
d = {"hook_event_name": "UserPromptSubmit", "session_id": "sess-h", "prompt": sys.argv[1], "cwd": "/home/user/x", "transcript_path": sys.argv[2]}
if len(sys.argv) > 3 and sys.argv[3]: d["source"] = sys.argv[3]
print(json.dumps(d))' "$1" "$H_TR" "${2:-}")
    OUT=$(printf '%s' "$json" | bash "$HOOK" 2>"$TEST_TMPDIR/hook.err"); RC=$?
}
h_wait_launch() { local i; for i in $(seq 1 30); do [[ -s "$H_LAUNCH" ]] && return 0; sleep 0.1; done; return 1; }
h_state() { sed -n "${1}p" "$H_STATE" 2>/dev/null; }   # 1 token, 2 keywords, 3 transcript, 4 offset, 5 session, 6 epoch
h_stamp() { printf '%s\n%s\n%s\n' "$1" "${2:-$(date +%s)}" "${3:-}" > "$SHUTDOWN_FOLLOW_DIR/stamp.4242"; }

test_hook_arms_on_cls() {
    h_setup; h_prompt "cls"
    assert_eq 0 "$RC" "exit 0"; assert_eq "" "$OUT" "nothing on stdout (it would become model context)"
    assert_file_exists "$H_STATE" "a pending watcher is recorded for the claude pid"
    assert_eq cls "$(h_state 2)" "keyword cls"; assert_eq "$H_TR" "$(h_state 3)" "the transcript path from the payload"
    assert_eq 100 "$(h_state 4)" "the transcript's byte size at arming"; assert_eq sess-h "$(h_state 5)" "the session id"
    assert_success h_wait_launch; local tok; tok=$(h_state 1)
    assert_contains "$(cat "$H_LAUNCH")" "--pid 4242" "the watcher gets the pid"
    assert_contains "$(cat "$H_LAUNCH")" "--token $tok" "and the fresh token"
    assert_file_contains "$SHUTDOWN_FOLLOW_LOG" "armed" "logged"
    h_teardown
}
run_test "hook: a typed cls arms a watcher (state file + detached launch), nothing on stdout" test_hook_arms_on_cls

test_hook_word_rule() {
    h_setup; local p
    for p in "end-to-end tests" "the backend" "cls_x" "an endpoint" "class" "weekend" "Clsx"; do
        rm -f "$H_STATE" "$H_LAUNCH"; h_prompt "$p"
        assert_file_not_exists "$H_STATE" "'$p' does not arm (letters, digits, _ and - are word characters)"
    done
    for p in "the end." "CLS" "please end now" "cls!" "ok, END" "(cls)"; do
        rm -f "$H_STATE" "$H_LAUNCH"; h_prompt "$p"
        assert_file_exists "$H_STATE" "'$p' arms (a keyword as a word, anywhere, any case)"
    done
    # F3: in the raw payload a newline is the two characters \n — the pre-filter must still let these through
    for p in $'foo\ncls' $'done.\nend' $'tab\tcls' $'x\r\nend' $'first line\n\ncls\n'; do
        rm -f "$H_STATE" "$H_LAUNCH"; h_prompt "$p"
        assert_file_exists "$H_STATE" "a keyword after a line break or tab arms ($(printf '%q' "$p"))"
    done
    rm -f "$H_STATE"; h_prompt "cls then end"
    assert_eq "cls end" "$(h_state 2)" "both words in one prompt are both recorded"
    h_teardown
}
run_test "hook: word boundary — end-to-end/backend/cls_x never arm, 'the end.' and CLS do" test_hook_word_rule

test_hook_synthetic_turns_neither_arm_nor_cancel() {
    h_setup; h_prompt "cls"; assert_file_exists "$H_STATE"; local tok; tok=$(h_state 1); rm -f "$H_LAUNCH"
    h_prompt $'<task-notification>\n<summary>agent ran cls and end</summary>\n</task-notification>'
    assert_eq "$tok" "$(h_state 1)" "a task notification quoting cls keeps the pending watcher, same token"
    h_prompt $'<agent-message from="x">\n[Subagent hand-back] please cls now'
    assert_eq "$tok" "$(h_state 1)" "a subagent hand-back neither cancels nor re-arms"
    h_prompt "end" schedule_wakeup
    assert_eq "$tok" "$(h_state 1)" "a scheduled fire (source) neither cancels nor re-arms"
    assert_file_not_exists "$H_LAUNCH" "no second watcher launched"
    h_teardown
}
run_test "hook: harness-delivered turns neither arm nor cancel" test_hook_synthetic_turns_neither_arm_nor_cancel

test_hook_cancel_and_rearm() {
    h_setup; h_prompt "cls"; local tok; tok=$(h_state 1)
    h_prompt "what is the status"
    assert_file_not_exists "$H_STATE" "any later real prompt cancels the pending watcher"
    assert_file_contains "$SHUTDOWN_FOLLOW_LOG" "cancelled" "logged"
    h_prompt "cls"; local tok2; tok2=$(h_state 1); h_prompt "end"
    assert_file_exists "$H_STATE" "a prompt with a keyword re-arms"
    assert_neq "$tok2" "$(h_state 1)" "with a new token (the old watcher sees it and stops)"
    assert_eq end "$(h_state 2)" "and the new keyword"
    h_teardown
}
run_test "hook: a later prompt cancels; cls/end again re-arms with a new token" test_hook_cancel_and_rearm

test_hook_stamped_prompt_cancels_but_never_arms() {
    h_setup; h_prompt "cls"; local tok; tok=$(h_state 1); rm -f "$H_LAUNCH"
    h_stamp "cls"; h_prompt "cls"
    assert_file_not_exists "$H_STATE" "a prompt remote-session typed itself (fresh stamp) cancels the pending watcher"
    assert_file_not_exists "$SHUTDOWN_FOLLOW_DIR/stamp.4242" "the stamp is consumed once"
    assert_file_not_exists "$H_LAUNCH" "and never arms (the caretaker's cls-restart types /clear itself)"
    h_stamp "  cls  "; h_prompt "cls"
    assert_file_not_exists "$H_STATE" "surrounding whitespace does not matter"
    h_stamp "a brief that must end well"; h_prompt "a brief that must end well"
    assert_file_not_exists "$H_STATE" "a sent brief holding the word end never arms"
    h_stamp "cls"; h_prompt "end"
    assert_file_exists "$H_STATE" "a stamp for ANOTHER line does not cover this prompt: it arms"
    assert_file_exists "$SHUTDOWN_FOLLOW_DIR/stamp.4242" "and that stamp stays"
    rm -f "$H_STATE"; h_stamp "cls" "$(( $(date +%s) - 7200 ))"; h_prompt "cls"
    assert_file_exists "$H_STATE" "a stale stamp (older than the TTL) is ignored: it arms"
    h_teardown
}
run_test "hook: a fresh stamp for the same line cancels and never arms; other lines and stale stamps do not count" test_hook_stamped_prompt_cancels_but_never_arms

test_hook_own_watchers_lines_change_nothing() {
    h_setup; h_prompt "cls"; local tok; tok=$(h_state 1)
    h_stamp "startup" "" "$tok"; h_prompt "startup"
    assert_eq "$tok" "$(h_state 1)" "a line the pending watcher typed itself (stamp carries its token) neither cancels nor arms"
    assert_file_not_exists "$SHUTDOWN_FOLLOW_DIR/stamp.4242" "the stamp is consumed"
    h_teardown
}
run_test "hook: the pending watcher's own typed line (token in the stamp) changes nothing" test_hook_own_watchers_lines_change_nothing

test_hook_fast_path_and_missing_watcher() {
    h_setup; local s e
    s=$(date +%s%N); h_prompt "a prompt with nothing in it"; e=$(date +%s%N)
    assert_eq 0 "$RC" "exit 0"; assert_eq "" "$OUT" "nothing on stdout"
    assert_file_not_exists "$H_STATE" "nothing armed"
    assert_eq 1 "$(( (e - s) / 1000000 < 1000 ))" "the fast path returns in under a second (measured $(( (e - s) / 1000000 )) ms)"
    rm -f "$SHUTDOWN_FOLLOW_SCRIPT"; h_prompt "cls"
    assert_eq 0 "$RC" "a missing watcher script never fails the hook"
    assert_file_not_exists "$H_STATE" "and arms nothing"
    assert_file_contains "$SHUTDOWN_FOLLOW_LOG" "missing" "the log says why"
    h_teardown
}
run_test "hook: the fast path is quick and silent; a missing watcher script arms nothing" test_hook_fast_path_and_missing_watcher

test_hook_detaches_under_safe_run() {
    h_setup; cp "$HOOK" "$REPO_ROOT/global/hooks/lib-hook-stdin.sh" "$HOME/.claude/hooks/"
    export H_SLEEP=3; local s e json
    json=$(python3 -c 'import json; print(json.dumps({"session_id": "sess-h", "prompt": "cls", "cwd": "/x", "transcript_path": "/none"}))')
    s=$(date +%s); OUT=$(printf '%s' "$json" | bash "$SAFE_RUN" shutdown-follow.sh 2>&1); e=$(date +%s)
    assert_eq "" "$OUT" "nothing reaches the model through safe-run"
    assert_eq 1 "$(( e - s < 3 ))" "the hook returned before its watcher ended ($(( e - s )) s): the capture did not wait for it"
    local i; for i in $(seq 1 60); do [[ -f "$H_LAUNCH.done" ]] && break; sleep 0.1; done
    assert_file_exists "$H_LAUNCH.done" "the watcher outlived the hook"
    h_teardown
}
run_test "hook: through safe-run.sh the watcher is detached and the hook returns at once" test_hook_detaches_under_safe_run

# F11: the claude pid by the ancestor walk — a parent process whose argv0 is a `claude` binary. The negative half
# reads a fixture /proc (SHUTDOWN_FOLLOW_PROC) that holds no entry for the hook's parents: the suite itself may
# run under a Claude Code session, whose claude WOULD be found on the real /proc.
test_hook_finds_claude_ancestor() {
    h_setup; unset SHUTDOWN_FOLLOW_PID; mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/noproc"; cp /bin/bash "$TEST_TMPDIR/bin/claude"
    local json; json=$(python3 -c 'import json; print(json.dumps({"session_id": "sess-h", "prompt": "cls", "cwd": "/x", "transcript_path": "/none"}))')
    "$TEST_TMPDIR/bin/claude" -c 'echo $$ > "$1"; printf "%s" "$2" | bash "$3"' _ "$TEST_TMPDIR/claude.pid" "$json" "$HOOK"
    local cp; cp=$(cat "$TEST_TMPDIR/claude.pid")
    assert_file_exists "$SHUTDOWN_FOLLOW_DIR/$cp" "the state file is keyed by the nearest ancestor running a claude binary (pid $cp)"
    assert_eq 1 "$(ls "$SHUTDOWN_FOLLOW_DIR" | grep -c '^[0-9]*$')" "and by no other pid"
    rm -rf "$SHUTDOWN_FOLLOW_DIR"
    SHUTDOWN_FOLLOW_PROC="$TEST_TMPDIR/noproc" bash -c 'printf "%s" "$1" | bash "$2"' _ "$json" "$HOOK"
    assert_eq 0 "$(ls "$SHUTDOWN_FOLLOW_DIR" 2>/dev/null | grep -c '^[0-9]*$')" "no claude ancestor on the walk: nothing armed"
    h_teardown
}
run_test "hook: the claude pid comes from the ancestor walk (argv0 claude), none → nothing armed" test_hook_finds_claude_ancestor

# A machine with no readable /proc (macOS, a sandbox) or a process tree the hook cannot walk: the hook exits 0
# at once, arms nothing, launches nothing and says nothing — no log line either, this is not an event.
test_hook_without_proc_degrades_silently() {
    h_setup; unset SHUTDOWN_FOLLOW_PID; mkdir -p "$TEST_TMPDIR/noproc"
    local json rc; json=$(python3 -c 'import json; print(json.dumps({"session_id": "sess-h", "prompt": "cls", "cwd": "/x", "transcript_path": "/none"}))')
    OUT=$(printf '%s' "$json" | SHUTDOWN_FOLLOW_PROC="$TEST_TMPDIR/noproc" bash "$HOOK" 2>"$TEST_TMPDIR/hook.err"); rc=$?
    assert_eq 0 "$rc" "exit 0 (a hook must never fail the prompt)"; assert_eq "" "$OUT" "nothing on stdout"
    assert_eq "" "$(cat "$TEST_TMPDIR/hook.err")" "nothing on stderr"
    assert_eq 0 "$(ls "$SHUTDOWN_FOLLOW_DIR" 2>/dev/null | grep -c .)" "nothing armed"
    assert_file_not_exists "$H_LAUNCH" "no watcher launched"
    assert_file_not_exists "$SHUTDOWN_FOLLOW_LOG" "and no log written: without a session pid there is nothing to report"
    OUT=$(printf '%s' "$json" | SHUTDOWN_FOLLOW_PROC="$TEST_TMPDIR/does-not-exist" bash "$HOOK" 2>/dev/null); rc=$?
    assert_eq 0 "$rc" "a /proc path that does not exist at all: the same"; assert_eq "" "$OUT"
    h_teardown
}
run_test "hook: no readable /proc (macOS, a sandbox) → exit 0 at once, nothing armed, launched or logged" test_hook_without_proc_degrades_silently

# F8: a stamp must not make a multi-megabyte prompt expensive (trimming 6 MB cost ~1 s)
test_hook_huge_prompt_with_stamp_stays_cheap() {
    h_setup; local json s e plain stamped
    json=$(python3 -c 'import json; print(json.dumps({"session_id": "sess-h", "prompt": "x" * 6000000 + " end", "cwd": "/x", "transcript_path": "/none"}))')
    s=$(date +%s%N); OUT=$(printf '%s' "$json" | bash "$HOOK" 2>/dev/null); e=$(date +%s%N); plain=$(( (e - s) / 1000000 ))
    rm -f "$H_STATE"; h_stamp "cls"
    s=$(date +%s%N); OUT=$(printf '%s' "$json" | bash "$HOOK" 2>/dev/null); e=$(date +%s%N); stamped=$(( (e - s) / 1000000 ))
    assert_file_exists "$H_STATE" "the huge prompt (not the stamped line) still arms"
    assert_file_exists "$SHUTDOWN_FOLLOW_DIR/stamp.4242" "the stamp for another line is not consumed"
    assert_eq 1 "$(( stamped <= plain * 3 / 2 + 300 ))" "a stamp adds no trim of the whole prompt (measured: no stamp $plain ms, stamp $stamped ms)"
    h_teardown
}
run_test "hook: a stamp does not make a 6 MB prompt expensive (length compared before trimming)" test_hook_huge_prompt_with_stamp_stays_cheap

# ── rs_shutdown_next: the Next: hint of the shutdown turn ─────────────────────
test_shutdown_next_hint() {
    a_setup; local t="$TEST_TMPDIR/t.jsonl"; : > "$t"
    t_text "$t" "Shutdown complete. Next: /exit"; t_end "$t"; local off; off=$(t_size "$t")
    t_text "$t" $'**Repo:** pushed.\n\nShutdown complete. Next: /clear'; t_end "$t"
    assert_eq clear "$(rs_shutdown_next "$t" "$off")" "the hint of the completion AFTER the offset"
    assert_eq exit "$(rs_shutdown_next "$t" 0)" "from byte 0 the first completed turn's hint"
    : > "$t"; t_text "$t" "Shutdown complete."; t_end "$t"
    assert_eq "" "$(rs_shutdown_next "$t" 0)" "no Next: → nothing"
    : > "$t"; t_text "$t" '**Shutdown complete. Next: `/exit`**'; t_end "$t"
    assert_eq exit "$(rs_shutdown_next "$t" 0)" "markdown around the line and backticks around the command do not hide the hint"
    : > "$t"; t_text "$t" "Shutdown complete. Next: /exit"; t_tool "$t"
    assert_eq "" "$(rs_shutdown_next "$t" 0)" "a turn that did not end → nothing"
    a_teardown
}
run_test "rs_shutdown_next: /exit or /clear from the ended shutdown turn after the offset, else nothing" test_shutdown_next_hint

# F5: the watcher judges ANY completed turn after the offset (rs_shutdown_turn); rs_shutdown_reported, which
# remote-session's end-exit / cls-restart keep, judges the LAST one (a later prompt voids a shutdown there).
test_shutdown_turn_behind_a_later_turn() {
    a_setup; local t="$TEST_TMPDIR/t.jsonl"; : > "$t"; local off; off=$(t_size "$t")
    t_text "$t" $'Pushed.\n\nShutdown complete. Next: /clear'; t_end "$t"
    t_user "$t" $'<task-notification>\n<summary>Stop hook feedback</summary>\n=== Telegram message(s) for this project (woke this idle session, CFG-777) ===\n[21:00] ok thanks'
    t_text "$t" "Noted. Next: /exit is not what I will do."; t_end "$t"   # a synthetic turn right after the shutdown
    assert_eq clear "$(rs_shutdown_turn "$t" "$off")" "the shutdown turn is found behind the later turn, with ITS hint"
    assert_failure rs_shutdown_reported "$t" "$off"   # remote-session's rule: the LAST turn decides (unchanged)
    assert_failure rs_shutdown_turn "$TEST_TMPDIR/missing.jsonl" 0
    : > "$t"; t_text "$t" "Working."; t_end "$t"
    assert_failure rs_shutdown_turn "$t" 0
    a_teardown
}
run_test "rs_shutdown_turn: any completed turn after the offset counts, and its own Next: hint is used" test_shutdown_turn_behind_a_later_turn

# F6: a QUOTED completion — inside a ``` fence or on a > blockquote line — is a live answer, not the shutdown
test_shutdown_quoted_completion_ignored() {
    a_setup; local t="$TEST_TMPDIR/t.jsonl"; : > "$t"
    t_text "$t" $'The row says:\n```\nShutdown complete. Next: /exit\n```\nShall I run it?'; t_end "$t"
    assert_failure rs_shutdown_reported "$t" 0 "fenced: not the session's own completion"
    assert_failure rs_shutdown_turn "$t" 0
    : > "$t"; t_text "$t" $'You wrote:\n> Shutdown complete. Next: /exit\n\nbut the checklist is not done.'; t_end "$t"
    assert_failure rs_shutdown_reported "$t" 0 "blockquoted: not the session's own completion"
    assert_failure rs_shutdown_turn "$t" 0
    : > "$t"; t_text "$t" $'Compare:\n```\nShutdown complete. Next: /exit\n```\n\nShutdown complete. Next: /clear'; t_end "$t"
    assert_success rs_shutdown_reported "$t" 0
    assert_eq clear "$(rs_shutdown_turn "$t" 0)" "the real line after a fenced quote counts, and the hint is the real line's"
    a_teardown
}
run_test "shutdown: a completion inside a fence or a > quote never counts (both judges); the real line after it does" test_shutdown_quoted_completion_ignored

test_stamp_written_by_typing_primitive() {
    a_setup; export SHUTDOWN_FOLLOW_DIR="$TEST_TMPDIR/sf-state" RS_WSL=1 RS_INJECT="$TEST_TMPDIR/rootstub"
    a_root_stub "$RS_INJECT"; local p; p=$(a_spawn claude /dev/pts/40 /home/user/x claude)
    rs_gate_arm "$p"   # what the watcher's rs_safety_check does before any key (CFG-1083 F1)
    rs_type_text "$p" "cls" "wsl /dev/pts/40" >/dev/null 2>&1
    assert_eq cls "$(sed -n 1p "$SHUTDOWN_FOLLOW_DIR/stamp.$p")" "rs_type_text leaves the exact line"
    assert_eq 1 "$(( $(date +%s) - $(sed -n 2p "$SHUTDOWN_FOLLOW_DIR/stamp.$p") < 5 ))" "with the time"
    assert_eq "" "$(sed -n 3p "$SHUTDOWN_FOLLOW_DIR/stamp.$p")" "and no token outside a watcher"
    SHUTDOWN_FOLLOW_TOKEN=tok-9 rs_type_line "$p" "startup" >/dev/null 2>&1
    assert_eq "startup" "$(sed -n 1p "$SHUTDOWN_FOLLOW_DIR/stamp.$p")" "rs_type_line stamps too"
    assert_eq tok-9 "$(sed -n 3p "$SHUTDOWN_FOLLOW_DIR/stamp.$p")" "carrying the watcher's token"
    rs_unstamp "$p"; assert_file_not_exists "$SHUTDOWN_FOLLOW_DIR/stamp.$p" "rs_unstamp removes it"
    # F7: a write the injector refuses leaves no stamp behind (it would eat the user's next real cls for an hour)
    printf '#!/usr/bin/env bash\nexit 3\n' > "$TEST_TMPDIR/refusing"; chmod +x "$TEST_TMPDIR/refusing"
    RS_INJECT="$TEST_TMPDIR/refusing" rs_type_text "$p" "cls" "wsl /dev/pts/40" >/dev/null 2>&1; local rc=$?
    assert_neq 0 "$rc" "the refused write is reported"
    assert_file_not_exists "$SHUTDOWN_FOLLOW_DIR/stamp.$p" "and its stamp is gone (rs_type_text)"
    RS_INJECT="$TEST_TMPDIR/refusing" rs_type_line "$p" "cls" >/dev/null 2>&1; rc=$?
    assert_neq 0 "$rc"; assert_file_not_exists "$SHUTDOWN_FOLLOW_DIR/stamp.$p" "the same for rs_type_line"
    unset SHUTDOWN_FOLLOW_DIR RS_WSL RS_INJECT; a_teardown
}
run_test "stamp: the typing primitives leave '<line>\\n<epoch>\\n<token>' for the hook; a give-up removes it" test_stamp_written_by_typing_primitive

# ── A: the watcher on a fixture session ───────────────────────────────────────
# f_setup: fixture claude F_PID (record idle) with transcript F_TR; afd stub records calls in F_AFD.
f_setup() {
    a_setup; export RS_POLL=0.1 RS_KEY_GAP=0 RS_SUBMIT_WAIT=1 RS_DIALOG_WAIT=1 RS_SUBMIT_FIRST_WAIT=2
    F_PID=$(a_spawn claude /dev/pts/40 /home/user/x claude)
    mkdir -p "$CC/projects/-x" "$HOME/.local/bin"; F_TR="$CC/projects/-x/sid-$F_PID.jsonl"; : > "$F_TR"
    export SHUTDOWN_FOLLOW_DIR="$TEST_TMPDIR/sf-state" SHUTDOWN_FOLLOW_LOG="$TEST_TMPDIR/sf.log"; mkdir -p "$SHUTDOWN_FOLLOW_DIR"
    F_AFD="$TEST_TMPDIR/afd.calls"; : > "$F_AFD"; F_KEYS="$TEST_TMPDIR/keys"; : > "$F_KEYS"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$F_AFD" > "$HOME/.local/bin/afd"; chmod +x "$HOME/.local/bin/afd"
    F_TOKEN=tok-1
}
f_teardown() { unset RS_POLL RS_KEY_GAP RS_SUBMIT_WAIT RS_DIALOG_WAIT RS_SUBMIT_FIRST_WAIT SHUTDOWN_FOLLOW_DIR SHUTDOWN_FOLLOW_LOG; a_teardown; }
# f_arm <keywords> [offset] — the hook's state file: token F_TOKEN, keywords, F_TR, offset (default: now)
f_arm() { printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$F_TOKEN" "$1" "$F_TR" "${2:-$(t_size "$F_TR")}" "sid-$F_PID" "$(date +%s)" > "$SHUTDOWN_FOLLOW_DIR/$F_PID"; }
f_shutdown() { t_text "$F_TR" $'**Repo:** pushed.\n\nShutdown complete. Next: '"$1"; t_end "$F_TR"; }   # <"/clear"|"/exit"|"">
f_status() { python3 -c 'import json,sys
d = json.load(open(sys.argv[1])); d["status"] = sys.argv[2]; json.dump(d, open(sys.argv[1], "w"))' "$CC/sessions/$F_PID.json" "$1"; }
f_care_active() { printf 'active %s 999 proj-c sid-c 80\n' "$(date +%s)" > "$HOME/.afd-care"; }
# f_run [watcher args] — main in a subshell with the keys stubbed into F_KEYS (clear / text:<t> / enter);
# Enter on /exit kills the pid, on /clear gives the record a fresh session id (F_CLEAR_FAIL=1: not),
# on any other text records it as a prompt in the CURRENT session id's transcript (F_LATE=<s>: that
# many seconds later, as a cleared session whose SessionStart is still running writes it); F_DIALOG_AFTER=<line>:
# entering that line brings a dialog up (status waiting). F_ON_TEXT=<cmd>: run once the text is typed (before
# its Enter) — a cancel, a drained prompt (status busy), the user's own /clear. The fixture has an input path
# ("wsl /dev/pts/40"): a machine without one is a case of its own. F_WATCHER: another copy of the watcher to
# source (the staged one without the care lib, n_stage_layer). Echoes the exit code.
f_run() {
    ( source "${F_WATCHER:-$WATCHER}"
      rs_input_target() { echo "wsl /dev/pts/40"; }
      rs_clear_input() { echo clear >> "$F_KEYS"; return 0; }
      rs_type_text()   { echo "text:$2" >> "$F_KEYS"; printf '%s' "$2" > "$F_KEYS.box"; eval "${F_ON_TEXT:-:}"; return 0; }
      rs_press_enter() { local l tr; l=$(cat "$F_KEYS.box" 2>/dev/null); : > "$F_KEYS.box"; echo enter >> "$F_KEYS"
          [[ -n "$l" && "$l" == "${F_DIALOG_AFTER:-}" ]] && f_status waiting
          case "$l" in
            /exit)  kill "$1" 2>/dev/null ;;
            /clear) [[ -n "${F_CLEAR_FAIL:-}" ]] || python3 -c 'import json,sys
d = json.load(open(sys.argv[1])); d.update(sessionId="sid-cleared", status="idle"); json.dump(d, open(sys.argv[1], "w"))' "$CC/sessions/$1.json" ;;
            "")     ;;
            *)      tr="$CC/projects/-x/$(rs_session_field "$1" sessionId).jsonl"
                    if [[ -n "${F_LATE:-}" ]]; then ( sleep "$F_LATE"; t_user "$tr" "$l" ) & else t_user "$tr" "$l"; fi ;;
          esac; return 0; }
      main --pid "$F_PID" --token "$F_TOKEN" --wait "${F_WAIT:-2}" --clear-wait 2 --exit-wait 2 "$@" >>"$SHUTDOWN_FOLLOW_LOG" 2>&1 ); echo $?
}
f_keys() { paste -sd'|' "$F_KEYS"; }

test_watcher_clear_without_care() {
    f_setup; f_arm cls; f_shutdown /clear
    local rc; rc=$(f_run)
    assert_eq 0 "$rc" "done: $(cat "$SHUTDOWN_FOLLOW_LOG")"
    assert_eq "clear|text:/clear|enter" "$(f_keys)" "/clear typed as a line (input cleared, text, Enter alone) — and nothing else outside care"
    assert_eq sid-cleared "$(rs_session_field "$F_PID" sessionId)" "the fresh session was waited for"
    assert_file_not_exists "$SHUTDOWN_FOLLOW_DIR/$F_PID" "the pending record is gone"
    assert_eq "" "$(cat "$F_AFD")" "no Telegram on success"
    f_teardown
}
run_test "watcher: 'Next: /clear' → types /clear, waits for the fresh session, no startup outside care" test_watcher_clear_without_care

test_watcher_clear_with_care_submits_startup() {
    f_setup; f_arm cls; f_shutdown /clear; f_care_active
    local rc; rc=$(f_run)
    assert_eq 0 "$rc" "done: $(cat "$SHUTDOWN_FOLLOW_LOG")"
    assert_eq "clear|text:/clear|enter|clear|text:startup|enter" "$(f_keys)" "/clear, then startup submitted into the fresh session"
    assert_eq 1 "$(b_prompts "$CC/projects/-x/sid-cleared.jsonl" startup)" "startup confirmed in the NEW session's transcript"
    assert_file_contains "$SHUTDOWN_FOLLOW_LOG" "startup submitted" "logged"
    f_teardown
}
run_test "watcher: while caretaking is active, startup follows /clear and is confirmed in the new transcript" test_watcher_clear_with_care_submits_startup

test_watcher_startup_confirmed_by_late_transcript() {
    f_setup; f_arm cls; f_shutdown /clear; f_care_active; export F_LATE=1
    local rc; rc=$(f_run); unset F_LATE
    assert_eq 0 "$rc" "done: $(cat "$SHUTDOWN_FOLLOW_LOG")"
    assert_eq "clear|text:/clear|enter|clear|text:startup|enter" "$(f_keys)" \
        "CFG-1043 data point 1: the new transcript appears only after the prompt — ONE Enter, no retry, no clearing keys"
    f_teardown
}
run_test "watcher: a transcript that appears late (SessionStart still running) confirms startup without a second Enter" test_watcher_startup_confirmed_by_late_transcript

# Without the care machinery (the public template ships no lib-care.sh, and none is deployed) the watcher reads
# the care line's first word itself: `active` → startup after /clear; anything else, or no line → nothing.
test_watcher_care_fallback_without_lib() {
    f_setup; n_stage_layer; export F_WATCHER="$N_WATCHER"
    assert_file_not_exists "$TEST_TMPDIR/nolib/global/hooks/lib-care.sh" "no care lib beside the staged watcher"
    assert_file_not_exists "$HOME/.claude/hooks/lib-care.sh" "and none deployed in this HOME"
    f_arm cls; f_shutdown /clear; f_care_active
    local rc; rc=$(f_run)
    assert_eq 0 "$rc" "done: $(cat "$SHUTDOWN_FOLLOW_LOG")"
    assert_eq "clear|text:/clear|enter|clear|text:startup|enter" "$(f_keys)" "an 'active' line read by the watcher itself → startup after /clear"
    f_teardown; f_setup; export F_WATCHER="$N_WATCHER"
    f_arm cls; f_shutdown /clear; printf 'armed %s 999 proj-c sid-c 80\n' "$(date +%s)" > "$HOME/.afd-care"
    rc=$(f_run)
    assert_eq 0 "$rc"; assert_eq "clear|text:/clear|enter" "$(f_keys)" "'armed' is not active: no startup"
    f_teardown; f_setup; export F_WATCHER="$N_WATCHER"
    f_arm cls; f_shutdown /clear
    rc=$(f_run)
    assert_eq 0 "$rc"; assert_eq "clear|text:/clear|enter" "$(f_keys)" "no care line at all: no startup"
    assert_file_contains "$SHUTDOWN_FOLLOW_LOG" "caretaking not active" "logged as such"
    unset F_WATCHER; f_teardown
}
run_test "watcher without lib-care.sh (the public template): the care line's first word decides startup" test_watcher_care_fallback_without_lib

test_watcher_exit() {
    f_setup; f_arm end; f_shutdown /exit
    local rc; rc=$(f_run)
    assert_eq 0 "$rc" "done: $(cat "$SHUTDOWN_FOLLOW_LOG")"
    assert_eq "clear|text:/exit|enter" "$(f_keys)" "/exit typed as a line"
    assert_failure kill -0 "$F_PID"
    f_teardown
}
run_test "watcher: 'Next: /exit' → types /exit and waits for the pid to go" test_watcher_exit

test_watcher_keyword_fallback() {
    f_setup; f_arm cls; f_shutdown ""; f_run >/dev/null
    assert_eq "clear|text:/clear|enter" "$(f_keys)" "no Next: hint, armed by cls → /clear"
    f_teardown; f_setup; f_arm end; f_shutdown ""; f_run >/dev/null
    assert_eq "clear|text:/exit|enter" "$(f_keys)" "no Next: hint, armed by end → /exit"
    f_teardown; f_setup; f_arm "cls end"; f_shutdown ""; local rc; rc=$(f_run)
    assert_eq 0 "$rc" "exits 0"; assert_eq "" "$(f_keys)" "both keywords and no hint → nothing typed"
    assert_file_contains "$SHUTDOWN_FOLLOW_LOG" "both" "logged"
    f_teardown
}
run_test "watcher: no 'Next:' hint → the arming keyword decides; both keywords → nothing, logged" test_watcher_keyword_fallback

test_watcher_hint_beats_keyword() {
    f_setup; f_arm end; f_shutdown /clear; f_run >/dev/null
    assert_eq "clear|text:/clear|enter" "$(f_keys)" "the transcript's 'Next: /clear' wins over the armed end"
    f_teardown
}
run_test "watcher: the shutdown turn's own Next: hint beats the arming keyword" test_watcher_hint_beats_keyword

test_watcher_no_shutdown_is_silent() {
    f_setup; f_arm cls; touch "$HOME/.afd-afk"
    t_text "$F_TR" "Working on it."; t_end "$F_TR"
    local rc; rc=$(f_run)
    assert_eq 0 "$rc" "a false arm times out quietly"
    assert_eq "" "$(f_keys)" "nothing typed"; assert_eq "" "$(cat "$F_AFD")" "no Telegram, even with AFK on"
    assert_file_contains "$SHUTDOWN_FOLLOW_LOG" "no shutdown" "log only"
    f_teardown
}
run_test "watcher: no shutdown within the wait (a false arm) → nothing typed, log only, no Telegram" test_watcher_no_shutdown_is_silent

test_watcher_old_completion_ignored() {
    f_setup; f_shutdown /clear; f_arm cls   # the completion sits BEFORE the arming offset
    f_run >/dev/null
    assert_eq "" "$(f_keys)" "a shutdown reported before the arming prompt never counts"
    f_teardown
}
run_test "watcher: a 'Shutdown complete' written before the arming offset does not count" test_watcher_old_completion_ignored

test_watcher_cancelled_exits_silently() {
    f_setup; f_arm cls; f_shutdown /clear; rm -f "$SHUTDOWN_FOLLOW_DIR/$F_PID"
    local rc; rc=$(f_run); assert_eq 0 "$rc"; assert_eq "" "$(f_keys)" "no state file: cancelled, nothing typed"
    f_arm cls; f_shutdown /clear; F_TOKEN=tok-other f_arm cls; F_TOKEN=tok-1
    rc=$(f_run); assert_eq "" "$(f_keys)" "another token (re-armed): this watcher stops"
    f_teardown
}
run_test "watcher: a cancelled or re-armed watcher types nothing and exits 0" test_watcher_cancelled_exits_silently

test_watcher_cancel_right_before_typing() {
    f_setup; f_arm cls; f_shutdown /clear
    ( source "$WATCHER"
      rs_input_target() { rm -f "$SHUTDOWN_FOLLOW_DIR/$F_PID"; echo "wsl /dev/pts/40"; }
      rs_clear_input() { echo clear >> "$F_KEYS"; }; rs_type_text() { echo "text:$2" >> "$F_KEYS"; }; rs_press_enter() { echo enter >> "$F_KEYS"; }
      main --pid "$F_PID" --token "$F_TOKEN" --wait 2 >>"$SHUTDOWN_FOLLOW_LOG" 2>&1 )
    assert_eq "" "$(f_keys)" "the token is re-checked right before the keys: a cancel in between types nothing"
    f_teardown
}
run_test "watcher: a cancel between the shutdown check and the keys types nothing" test_watcher_cancel_right_before_typing

# F1: the token and the record are re-read before the TEXT and again before the ENTER — a cancel or a drained
# prompt (status busy: the user's queued prompt ran once the shutdown turn ended) in the 3-4 s of typing must stop
# the Enter, and the text already in the box is cleared again (as type_or_die does).
test_watcher_cancel_during_text_gives_up() {
    f_setup; f_arm cls; f_shutdown /clear; touch "$HOME/.afd-afk"
    local rc; rc=$(F_ON_TEXT='rm -f "$SHUTDOWN_FOLLOW_DIR/$F_PID"' f_run)
    assert_eq 0 "$rc" "a cancel is never a failure"
    assert_eq "clear|text:/clear|clear" "$(f_keys)" "the text went in, the cancel arrived, Enter NOT pressed, the line cleared again"
    assert_eq "" "$(cat "$F_AFD")" "no Telegram"; assert_file_contains "$SHUTDOWN_FOLLOW_LOG" "cancelled" "logged"
    f_teardown
}
run_test "watcher (F1): a cancel while the text is typed → no Enter, the text cleared, log only" test_watcher_cancel_during_text_gives_up

test_watcher_busy_after_text_stands_down() {
    f_setup; f_arm cls; f_shutdown /clear; touch "$HOME/.afd-afk"
    local rc; rc=$(F_ON_TEXT='f_status busy' f_run)
    assert_eq 0 "$rc" "someone else's prompt running is not our failure"
    assert_eq "clear|text:/clear|clear" "$(f_keys)" "status busy before the Enter: no Enter, the line cleared again"
    assert_eq "" "$(cat "$F_AFD")" "no Telegram"; assert_file_contains "$SHUTDOWN_FOLLOW_LOG" "busy" "the log names the status"
    assert_eq sid-$F_PID "$(rs_session_field "$F_PID" sessionId)" "no /clear went in"
    f_teardown
}
run_test "watcher (F1): the record turning busy before the Enter → no Enter, the text cleared, log only" test_watcher_busy_after_text_stands_down

test_watcher_busy_before_text_types_nothing() {
    f_setup; f_arm cls; f_shutdown /clear
    ( source "$WATCHER"
      rs_input_target() { f_status busy; echo "wsl /dev/pts/40"; }
      rs_clear_input() { echo clear >> "$F_KEYS"; }; rs_type_text() { echo "text:$2" >> "$F_KEYS"; }; rs_press_enter() { echo enter >> "$F_KEYS"; }
      main --pid "$F_PID" --token "$F_TOKEN" --wait 2 >>"$SHUTDOWN_FOLLOW_LOG" 2>&1 )
    assert_eq "" "$(f_keys)" "busy right before the clear: not even a clearing key goes in"
    f_teardown
}
run_test "watcher (F1): the record busy right before the first key → nothing typed" test_watcher_busy_before_text_types_nothing

# F2: the user's own /clear fires no prompt hook (a built-in command), so nothing cancels: the record's session id
# must decide — one other than the arming session's means the session was already cleared.
test_watcher_session_already_cleared_stands_down() {
    f_setup; f_arm cls; f_shutdown /clear; touch "$HOME/.afd-afk"
    python3 -c 'import json,sys
d = json.load(open(sys.argv[1])); d.update(sessionId="sid-by-user", status="idle"); json.dump(d, open(sys.argv[1], "w"))' "$CC/sessions/$F_PID.json"
    local rc; rc=$(f_run)
    assert_eq 0 "$rc"; assert_eq "" "$(f_keys)" "the user cleared the session by hand: no second /clear"
    assert_eq "" "$(cat "$F_AFD")" "no Telegram"; assert_file_contains "$SHUTDOWN_FOLLOW_LOG" "already cleared" "logged"
    f_teardown
}
run_test "watcher (F2): a record whose session id is no longer the arming one → nothing typed, log only" test_watcher_session_already_cleared_stands_down

test_watcher_cleared_during_text_gives_up() {
    f_setup; f_arm cls; f_shutdown /clear; f_care_active
    local rc; rc=$(F_ON_TEXT='python3 -c "import json,sys
d = json.load(open(sys.argv[1])); d.update(sessionId=\"sid-by-user\"); json.dump(d, open(sys.argv[1], \"w\"))" "$CC/sessions/$F_PID.json"' f_run)
    assert_eq 0 "$rc"
    assert_eq "clear|text:/clear|clear" "$(f_keys)" "the session id changed while the text was typed: no Enter, the text cleared, no startup"
    f_teardown
}
run_test "watcher (F2): the session cleared by the user while the text is typed → no Enter, no startup" test_watcher_cleared_during_text_gives_up

# F4: a machine with no typing path (no tmux pane, no Konsole tab, not WSL) — or a tty the watcher cannot
# read — gets no Telegram FAILED line for every console cls under AFK: it stops at once, log only.
test_watcher_no_input_path_is_log_only() {
    f_setup; f_arm cls; f_shutdown /clear; touch "$HOME/.afd-afk"
    local rc; rc=$( ( source "$WATCHER"
        rs_clear_input() { echo clear >> "$F_KEYS"; }; rs_type_text() { echo "text:$2" >> "$F_KEYS"; }; rs_press_enter() { echo enter >> "$F_KEYS"; }
        main --pid "$F_PID" --token "$F_TOKEN" --wait 2 >>"$SHUTDOWN_FOLLOW_LOG" 2>&1 ); echo $? )
    assert_eq 0 "$rc" "nothing this watcher could type: not a failure"
    assert_eq "" "$(f_keys)"; assert_eq "" "$(cat "$F_AFD")" "no Telegram, AFK on or not"
    assert_file_contains "$SHUTDOWN_FOLLOW_LOG" "no input path" "the log says why"
    assert_file_not_exists "$SHUTDOWN_FOLLOW_DIR/$F_PID" "and the pending record is released"
    f_teardown
}
run_test "watcher (F4): no input path on this machine → stops at once, log only, never a Telegram" test_watcher_no_input_path_is_log_only

# F5: a synthetic turn (a Telegram reply via the idle wake, a task notification) that starts and ends between
# two polls after the shutdown must not hide it.
test_watcher_sees_shutdown_behind_a_later_turn() {
    f_setup; f_arm cls; f_shutdown /clear
    t_user "$F_TR" $'<task-notification>\n<summary>Stop hook feedback</summary>\nok'; t_text "$F_TR" "Noted."; t_end "$F_TR"
    local rc; rc=$(f_run)
    assert_eq 0 "$rc"; assert_eq "clear|text:/clear|enter" "$(f_keys)" "the completed shutdown turn behind a later turn still leads to /clear"
    f_teardown
}
run_test "watcher (F5): a later synthetic turn does not hide the completed shutdown" test_watcher_sees_shutdown_behind_a_later_turn

test_watcher_busy_then_idle() {
    f_setup; f_arm cls; f_shutdown /clear; f_status busy
    ( sleep 0.5; f_status idle ) &
    local rc; rc=$(F_WAIT=3 f_run)
    assert_eq 0 "$rc"; assert_eq "clear|text:/clear|enter" "$(f_keys)" "waits while the record says busy, acts once idle"
    f_teardown
}
run_test "watcher: a busy record after the completion delays the keys until idle" test_watcher_busy_then_idle

test_watcher_dialog_stays_up_reports() {
    f_setup; f_arm cls; f_shutdown /clear; f_status waiting; touch "$HOME/.afd-afk"
    local rc; rc=$(f_run)
    assert_neq 0 "$rc" "a failure after the shutdown was seen"
    assert_eq "" "$(f_keys)" "no key goes into a dialog (status waiting)"
    assert_eq 1 "$(grep -c "notify all" "$F_AFD")" "ONE Telegram message while AFK is on"
    assert_contains "$(cat "$F_AFD")" "shutdown-follow" "naming the mechanism"
    assert_contains "$(cat "$F_AFD")" "--channel telegram" "on the telegram channel"
    assert_file_contains "$SHUTDOWN_FOLLOW_LOG" "waiting" "the log names the status"
    f_teardown
}
run_test "watcher: a dialog that stays up after the shutdown → nothing typed, one Telegram under AFK" test_watcher_dialog_stays_up_reports

test_watcher_failure_at_console_is_log_only() {
    f_setup; f_arm cls; f_shutdown /clear; f_status waiting
    local rc; rc=$(f_run)
    assert_neq 0 "$rc"; assert_eq "" "$(cat "$F_AFD")" "AFK off: no Telegram — the 'Next: /clear' line is the human fallback"
    assert_file_contains "$SHUTDOWN_FOLLOW_LOG" "FAILED" "but logged"
    f_teardown
}
run_test "watcher: the same failure at the console is logged, never sent" test_watcher_failure_at_console_is_log_only

test_watcher_clear_not_taking_reports() {
    f_setup; f_arm cls; f_shutdown /clear; touch "$HOME/.afd-afk"; export F_CLEAR_FAIL=1
    local rc; rc=$(f_run); unset F_CLEAR_FAIL
    assert_neq 0 "$rc"; assert_eq "clear|text:/clear|enter" "$(f_keys)" "/clear typed once; no retry"
    assert_eq 1 "$(grep -c "notify all" "$F_AFD")" "one Telegram: /clear did not take"
    assert_contains "$(cat "$F_AFD")" "/clear" "naming the line"
    f_teardown
}
run_test "watcher: /clear typed but no fresh session → one Telegram under AFK" test_watcher_clear_not_taking_reports

test_watcher_dialog_after_text_not_entered() {
    f_setup; f_arm cls; f_shutdown /clear; export F_DIALOG_AFTER=/clear F_CLEAR_FAIL=1
    ( source "$WATCHER"
      rs_input_target() { echo "wsl /dev/pts/40"; }
      rs_clear_input() { echo clear >> "$F_KEYS"; }
      rs_type_text() { echo "text:$2" >> "$F_KEYS"; f_status waiting; }
      rs_press_enter() { echo enter >> "$F_KEYS"; }
      main --pid "$F_PID" --token "$F_TOKEN" --wait 2 >>"$SHUTDOWN_FOLLOW_LOG" 2>&1 ); local rc=$?
    unset F_DIALOG_AFTER F_CLEAR_FAIL
    assert_neq 0 "$rc"; assert_eq "clear|text:/clear" "$(f_keys)" "a dialog after the text: Enter not pressed, and no clearing key into the dialog either (it stayed up)"
    assert_file_contains "$SHUTDOWN_FOLLOW_LOG" "STILL in its input box" "the report says the text waits behind the dialog"
    f_teardown
}
run_test "watcher: a dialog that comes up after the text → no Enter, nothing into the dialog, failure reported" test_watcher_dialog_after_text_not_entered

test_watcher_self_is_not_refused() {
    f_setup; f_arm cls; f_shutdown /clear; f_run >/dev/null
    assert_not_contains "$(cat "$SHUTDOWN_FOLLOW_LOG")" "pass --self" "a session typing into itself is exempt (Q-TYPE-SELF)"
    assert_eq "clear|text:/clear|enter" "$(f_keys)"
    f_teardown
}
run_test "watcher: typing into its own session is never refused as 'the calling session'" test_watcher_self_is_not_refused

test_watcher_pid_gone_before_shutdown() {
    f_setup; f_arm cls; kill "$F_PID"; wait "$F_PID" 2>/dev/null; touch "$HOME/.afd-afk"
    local rc; rc=$(f_run); assert_eq 0 "$rc"; assert_eq "" "$(f_keys)"; assert_eq "" "$(cat "$F_AFD")" "a session that ended on its own: nothing to do, nothing sent"
    f_teardown
}
run_test "watcher: the session gone before any shutdown → silent exit" test_watcher_pid_gone_before_shutdown

# ── B: real ptys — the hook arms, the user types cls/end, the real watcher follows ─────────────
# The hook launches the real watcher with this shell's environment: the fixture's RS_* for the root
# injector, a sandboxed state dir and log, and short waits. The fake records the lines it receives.
if (( HAVE_ROOT )); then

b_follow_env() {   # <cc dir> — export what the hook's watcher needs
    export SHUTDOWN_FOLLOW_DIR="$TEST_TMPDIR/sf-state" SHUTDOWN_FOLLOW_LOG="$TEST_TMPDIR/sf.log"
    export SHUTDOWN_FOLLOW_WAIT=30 SHUTDOWN_FOLLOW_CLEAR_WAIT=20 SHUTDOWN_FOLLOW_EXIT_WAIT=20 SHUTDOWN_FOLLOW_PID="$B_CLA"
    export RS_PROC=/proc RS_WSL=1 RS_QDBUS=/bin/true RS_TMUX=/bin/false RS_POLL=0.3 RS_INJECT="$ROOT_INJECT" RS_SUBMIT_WAIT=2 RS_CC_DIR="$1"
    mkdir -p "$SHUTDOWN_FOLLOW_DIR" "$HOME/.local/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.local/bin/afd"; chmod +x "$HOME/.local/bin/afd"
}
b_follow_teardown() {
    rm -f "$SHUTDOWN_FOLLOW_DIR"/* 2>/dev/null   # cancels a watcher still polling
    unset SHUTDOWN_FOLLOW_DIR SHUTDOWN_FOLLOW_LOG SHUTDOWN_FOLLOW_WAIT SHUTDOWN_FOLLOW_CLEAR_WAIT SHUTDOWN_FOLLOW_EXIT_WAIT SHUTDOWN_FOLLOW_PID
    unset RS_PROC RS_WSL RS_QDBUS RS_TMUX RS_POLL RS_INJECT RS_SUBMIT_WAIT RS_CC_DIR; b_teardown
}
b_user_types() {   # <text> — the user's keystrokes: the line, then Enter alone (the injector's own gap)
    $ROOT_INJECT "$INJ" --expect-pid "$B_CLA" "$B_TTY" "$1" >/dev/null 2>&1
}
b_hook_arm() {     # <prompt> — the hook on the payload Claude Code would send for that typed prompt
    python3 -c 'import json,sys; print(json.dumps({"session_id": "sid-init", "prompt": sys.argv[1], "cwd": "/x", "transcript_path": sys.argv[2]}))' \
        "$1" "$2" | bash "$HOOK" 2>>"$TEST_TMPDIR/hook.err"
}
b_wait_recv() { local i; for i in $(seq 1 "${2:-100}"); do grep -qx -- "$1" "$B_RECV" 2>/dev/null && return 0; sleep 0.2; done; return 1; }

test_real_cls_followed_by_clear() {
    local cc="$TEST_TMPDIR/cc"; mkdir -p "$cc/sessions"; b_spawn one "$cc"; b_follow_env "$cc"
    b_hook_arm cls "$cc/projects/-fake/sid-init.jsonl"
    assert_file_exists "$SHUTDOWN_FOLLOW_DIR/$B_CLA" "armed for the fake's pid"
    b_user_types cls
    assert_success b_wait_recv /clear 150 "the watcher typed /clear after the fake's 'Shutdown complete. Next: /clear' ($(cat "$SHUTDOWN_FOLLOW_LOG" 2>/dev/null))"
    sleep 1
    assert_eq "cls|/clear" "$(paste -sd'|' "$B_RECV")" "the session received cls (the user) and /clear (the watcher), nothing else: care is off"
    assert_neq sid-init "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sessionId"])' "$cc/sessions/$B_CLA.json")" "a fresh session id"
    assert_success kill -0 "$B_CLA"
    b_follow_teardown
}
run_test "real pty: cls typed by the user → the watcher types /clear into the same session" test_real_cls_followed_by_clear

test_real_cls_with_care_submits_startup() {
    local cc="$TEST_TMPDIR/cc"; mkdir -p "$cc/sessions"; b_spawn one "$cc"; b_follow_env "$cc"
    printf 'active %s 999 proj-c sid-c 80\n' "$(date +%s)" > "$HOME/.afd-care"
    b_hook_arm cls "$cc/projects/-fake/sid-init.jsonl"; b_user_types cls
    assert_success b_wait_recv startup 200 "startup submitted after /clear while caretaking is active ($(cat "$SHUTDOWN_FOLLOW_LOG" 2>/dev/null))"
    assert_eq "cls|/clear|startup" "$(paste -sd'|' "$B_RECV")" "cls, /clear, startup — each once"
    local new; new=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sessionId"])' "$cc/sessions/$B_CLA.json")
    assert_eq 1 "$(b_prompts "$cc/projects/-fake/$new.jsonl" startup)" "confirmed in the NEW session's transcript"
    b_follow_teardown
}
run_test "real pty: with care active, startup follows /clear and is confirmed in the new transcript" test_real_cls_with_care_submits_startup

test_real_end_followed_by_exit() {
    local cc="$TEST_TMPDIR/cc"; mkdir -p "$cc/sessions"; b_spawn one "$cc"; b_follow_env "$cc"
    b_hook_arm "end" "$cc/projects/-fake/sid-init.jsonl"; b_user_types end
    assert_success b_wait_recv /exit 150 "the watcher typed /exit after 'Shutdown complete. Next: /exit' ($(cat "$SHUTDOWN_FOLLOW_LOG" 2>/dev/null))"
    local i; for i in $(seq 1 50); do kill -0 "$B_CLA" 2>/dev/null || break; sleep 0.2; done
    assert_failure kill -0 "$B_CLA"
    b_follow_teardown
}
run_test "real pty: end typed by the user → the watcher types /exit and the session ends" test_real_end_followed_by_exit

else
    skip_test "real pty: cls → /clear by the watcher"              "$ROOT_WHY"
    skip_test "real pty: cls → /clear → startup under care"       "$ROOT_WHY"
    skip_test "real pty: end → /exit by the watcher"              "$ROOT_WHY"
fi

suite_summary
