#!/usr/bin/env bash
# Tests for global/hooks/lib-afd-mode.sh and its three callers (CFG-1036): every live session
# learns of an AFK or DND switch made elsewhere at its next hook turn — a prompt
# (afk-deactivate.sh), a tool call (afd-relay.sh) or an idle wake (afd-idle-wake.sh) — once.
# Measured 2026-11-14: a caretaker told the user "AFK mode is still on" hours after he had
# switched it off in another session, because nothing told the other sessions.
source "$(dirname "$0")/test-helpers.sh"

LIB="$REPO_ROOT/global/hooks/lib-afd-mode.sh"
PROMPT_HOOK="$REPO_ROOT/global/hooks/afk-deactivate.sh"
RELAY_HOOK="$REPO_ROOT/global/hooks/afd-relay.sh"
WAKE_HOOK="$REPO_ROOT/global/hooks/afd-idle-wake.sh"

suite_header "lib-afd-mode.sh (AFK/DND switches reach every session, CFG-1036)"

export TZ=UTC

setup_env() {
    export HOME="$TEST_TMPDIR/home"
    export AFD_MSG_DIR="$HOME/.afd-msgs"
    unset AFD_PROJECT_ROOTS AFD_AFK_TIMEOUT
    mkdir -p "$HOME/.local/bin" "$HOME/.claude/logs" "$HOME/proj-a" "$HOME/proj-b"
    git -C "$HOME/proj-a" init -q; git -C "$HOME/proj-b" init -q
    # Mock afd: `messages` prints $HOME/pending.jsonl once; nothing ever reaches a network.
    cat > "$HOME/.local/bin/afd" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$HOME/afd-calls.log"
if [[ "$1" == "messages" && -f "$HOME/pending.jsonl" ]]; then
    cat "$HOME/pending.jsonl"; rm -f "$HOME/pending.jsonl"
fi
exit 0
EOF
    chmod +x "$HOME/.local/bin/afd"
}

today_at() { echo "$(date -u +%Y-%m-%d)T$1:00+00:00"; }   # today_at 09:05 — an ISO switch time

# check <sid> — run afd_mode_check in a fresh shell; OUT = the lines, ERR = its stderr
check() {
    OUT=$(bash -c 'source "$1"; afd_mode_check "$2"; printf "%s" "$AFD_MODE_LINES"' _ "$LIB" "$1" 2>"$TEST_TMPDIR/err")
    ERR=$(cat "$TEST_TMPDIR/err")
}
marker() { echo "$AFD_MSG_DIR/.mode/$1"; }

# ── the lib ──────────────────────────────────────────────────────────────────

# Changed in the fix round (review #8): a first turn that finds a mode ON gets one state line, so a
# session started during AFK or DND knows it; with everything off the first turn stays silent.
test_first_turn_states_what_is_on() {
    setup_env
    today_at 07:45 > "$HOME/.afd-afk"
    check s1
    assert_contains "$OUT" "AFK_STATE: on (switched 07:45)" "a first turn with AFK on says so once (out: $OUT)"
    assert_eq "1" "$(grep -c . <<< "$OUT")" "one line, nothing about DND, which is off (out: $OUT)"
    assert_eq "on off" "$(cat "$(marker s1)" 2>/dev/null)" "and records the state it saw"
    check s1
    assert_eq "" "$OUT" "the next turn says nothing (out: $OUT)"
    check s2
    touch "$HOME/.afd-dnd"; rm -f "$HOME/.afd-afk"
    check s3
    assert_contains "$OUT" "DND_STATE: on" "another session's first turn under DND (out: $OUT)"
    rm -f "$HOME/.afd-dnd"
    check s4
    assert_eq "" "$OUT" "a first turn with both off stays silent (out: $OUT)"
}
run_test "1: a first turn states the modes that are on, once; all off stays silent" test_first_turn_states_what_is_on

test_afk_on_elsewhere_reported_once() {
    setup_env
    check s1
    today_at 09:05 > "$HOME/.afd-afk"
    check s1
    assert_contains "$OUT" "AFK_CHANGED: on (switched 09:05)" "the switch and its time from the flag (out: $OUT)"
    assert_eq "1" "$(grep -c . <<< "$OUT")" "one line (got: $OUT)"
    check s1
    assert_eq "" "$OUT" "the same change is never reported twice (out: $OUT)"
}
run_test "2: AFK switched on elsewhere is reported once, with its time" test_afk_on_elsewhere_reported_once

test_afk_off_with_stamp() {
    setup_env
    touch "$HOME/.afd-afk"
    check s1
    touch -d '-1 minute' "$(marker s1)"
    rm -f "$HOME/.afd-afk"; today_at 14:32 > "$HOME/.afd-afk.off"
    check s1
    assert_contains "$OUT" "AFK_CHANGED: off (switched 14:32)" "the switch-off time comes from the .off stamp (out: $OUT)"
}
run_test "3: AFK switched off elsewhere shows the stamp's time" test_afk_off_with_stamp

test_afk_off_without_stamp() {
    setup_env
    touch "$HOME/.afd-afk"
    check s1
    rm -f "$HOME/.afd-afk"
    check s1
    assert_contains "$OUT" "AFK_CHANGED: off (noticed " "no stamp: it says when it was noticed (out: $OUT)"
}
run_test "4: a switch-off without a stamp is reported as noticed" test_afk_off_without_stamp

test_stale_stamp_ignored() {
    setup_env
    touch "$HOME/.afd-afk"
    today_at 03:00 > "$HOME/.afd-afk.off"; touch -d '-2 hours' "$HOME/.afd-afk.off"
    check s1
    touch -d '-1 hour' "$(marker s1)"
    rm -f "$HOME/.afd-afk"
    check s1
    assert_not_contains "$OUT" "03:00" "a stamp older than the session's marker is an earlier switch (out: $OUT)"
    assert_contains "$OUT" "AFK_CHANGED: off (noticed " "so the line says noticed"
}
run_test "5: a stamp older than the session's marker is not shown" test_stale_stamp_ignored

test_same_state_is_no_change() {
    setup_env
    touch "$HOME/.afd-afk"
    check s1
    rm -f "$HOME/.afd-afk"; today_at 10:00 > "$HOME/.afd-afk"
    check s1
    assert_eq "" "$OUT" "off and on again between two turns leaves the state the session knows (out: $OUT)"
}
run_test "6: a re-switch to the same state is no change" test_same_state_is_no_change

test_dnd_and_both() {
    setup_env
    check s1
    today_at 11:11 > "$HOME/.afd-dnd"
    check s1
    assert_contains "$OUT" "DND_CHANGED: on (switched 11:11)" "a DND switch is reported too (out: $OUT)"
    rm -f "$HOME/.afd-dnd"; today_at 12:00 > "$HOME/.afd-afk"
    check s1
    assert_contains "$OUT" "AFK_CHANGED: on" "both modes changed: AFK (out: $OUT)"
    assert_contains "$OUT" "DND_CHANGED: off" "and DND"
    assert_eq "2" "$(grep -c . <<< "$OUT")" "one line each (got: $OUT)"
}
run_test "7: DND switches are reported, one line per changed mode" test_dnd_and_both

test_seen_suppresses_echo() {
    setup_env
    check s1
    touch "$HOME/.afd-afk"
    bash -c 'source "$1"; afd_mode_seen "$2"' _ "$LIB" s1
    check s1
    assert_eq "" "$OUT" "a switch the session recorded itself is not echoed back (out: $OUT)"
}
run_test "8: afd_mode_seen records an own switch silently" test_seen_suppresses_echo

# Review #7: recording this session's own AFK switch must not swallow a DND switch made elsewhere.
test_seen_keeps_the_other_mode() {
    setup_env
    check s1
    touch "$HOME/.afd-dnd"                       # switched elsewhere, not yet told to s1
    touch "$HOME/.afd-afk"                       # s1's own switch
    bash -c 'source "$1"; afd_mode_seen "$2" afk' _ "$LIB" s1
    check s1
    assert_contains "$OUT" "DND_CHANGED: on" "the DND switch made elsewhere is still told (out: $OUT)"
    assert_not_contains "$OUT" "AFK_CHANGED" "the session's own AFK switch is not echoed"
}
run_test "8b: afd_mode_seen <sid> afk keeps the DND field as the session last saw it" test_seen_keeps_the_other_mode

test_fast_path_runs_nothing() {
    setup_env
    touch "$HOME/.afd-afk"
    check s1
    local before; before=$(stat -c %Y.%N "$(marker s1)")
    OUT=$(PATH=/nonexistent "$BASH" -c 'source "$1"; afd_mode_check "$2"; afd_mode_check "$2"; printf "%s" "$AFD_MODE_LINES"' _ "$LIB" s1 2>"$TEST_TMPDIR/err")
    ERR=$(cat "$TEST_TMPDIR/err")
    assert_eq "" "$ERR" "no external command on the fast path: nothing fails with an empty PATH (stderr: $ERR)"
    assert_eq "" "$OUT" "nothing to say"
    assert_eq "$before" "$(stat -c %Y.%N "$(marker s1)")" "and the marker is not rewritten"
}
run_test "9: the fast path needs no external command" test_fast_path_runs_nothing

# Re-review item 3 (exp4): without a writable marker the first-turn line repeated on EVERY turn and
# "Permission denied" leaked to the model. A marker that cannot be written now means silence.
test_unwritable_marker_is_silent() {
    setup_env
    touch "$HOME/.afd-afk"
    mkdir -p "$AFD_MSG_DIR/.mode"; chmod 500 "$AFD_MSG_DIR/.mode"
    check s1
    local first="$OUT" e1="$ERR"
    touch "$HOME/.afd-dnd"
    check s1
    chmod 700 "$AFD_MSG_DIR/.mode"
    assert_eq "" "$first" "an unwritable .mode says nothing, rather than the same state line every turn (out: $first)"
    assert_eq "" "$OUT" "nor a CHANGED line it cannot record (out: $OUT)"
    assert_eq "" "$e1$ERR" "and no shell error reaches the model (stderr: $e1$ERR)"
    rm -rf "$AFD_MSG_DIR"; echo "not a dir" > "$AFD_MSG_DIR"
    check s2
    assert_eq "" "$OUT$ERR" "AFD_MSG_DIR that is not a directory: silent too (out: $OUT, stderr: $ERR)"
}
run_test "10b: a marker that cannot be written means silence, not a line every turn" test_unwritable_marker_is_silent

test_no_session_id() {
    setup_env
    check ""
    assert_eq "" "$OUT" "no session id: nothing printed"
    check nosession
    assert_eq "" "$OUT" "the waiter's placeholder id counts as none"
    assert_file_not_exists "$AFD_MSG_DIR/.mode" "and no marker written"
}
run_test "10: without a session id nothing is tracked" test_no_session_id

test_stamp_off_writes_parseable_time() {
    setup_env
    bash -c 'source "$1"; afd_mode_stamp_off "$HOME/.afd-afk"' _ "$LIB"
    local t; t=$(cat "$HOME/.afd-afk.off" 2>/dev/null)
    assert_contains "$t" "$(date +%Y-%m-%d)T" "the stamp holds today's switch time (got: '$t')"
    assert_neq "" "$(date -d "$t" +%H:%M 2>/dev/null)" "in a form date -d reads (got: '$t')"
}
run_test "11: afd_mode_stamp_off writes a readable switch time" test_stamp_off_writes_parseable_time

# ── the prompt hook (afk-deactivate.sh) ───────────────────────────────────────

prompt() { # prompt <sid> <text> [cwd] — OUT = the hook's stdout
    local j
    j=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","session_id":sys.argv[1],"prompt":sys.argv[2],"cwd":sys.argv[3]}))' "$1" "$2" "${3:-$HOME/proj-a}")
    OUT=$(printf '%s' "$j" | bash "$PROMPT_HOOK" 2>&1)
}

test_typed_afk_off_reaches_the_other_session() {
    setup_env
    touch "$HOME/.afd-afk"
    prompt sA "hi"; prompt sB "hi" "$HOME/proj-b"
    prompt sA "afk off"
    assert_contains "$OUT" "AFK mode deactivated" "session A switches AFK off (out: $OUT)"
    assert_not_contains "$OUT" "AFK_CHANGED" "and is not told about its own switch"
    prompt sB "what next" "$HOME/proj-b"
    assert_contains "$OUT" "AFK_CHANGED: off (switched " "session B learns it at its next prompt, with the time (out: $OUT)"
    prompt sB "and then" "$HOME/proj-b"
    assert_not_contains "$OUT" "AFK_CHANGED" "once (out: $OUT)"
}
run_test "12: a typed 'afk off' in one session reaches the other at its next prompt" test_typed_afk_off_reaches_the_other_session

test_telegram_afk_off_reaches_others() {
    setup_env
    touch "$HOME/.afd-afk"
    prompt sA "hi"; prompt sB "hi" "$HOME/proj-b"
    echo '{"id":700,"message":"afk off","timestamp":"t","persona":"Bot"}' > "$HOME/pending.jsonl"
    prompt sA "status?"
    assert_contains "$OUT" "AFK switched OFF from Telegram" "the consumer is told by the Telegram line (out: $OUT)"
    assert_not_contains "$OUT" "AFK_CHANGED" "not twice"
    assert_file_exists "$HOME/.afd-afk.off" "the Telegram switch-off leaves its stamp"
    prompt sB "status?" "$HOME/proj-b"
    assert_contains "$OUT" "AFK_CHANGED: off (switched " "the other session learns it (out: $OUT)"
}
run_test "13: a Telegram 'afk off' reaches the sessions that did not consume it" test_telegram_afk_off_reaches_others

# Re-review 5: a dnd off cut short on the Telegram path (its failure token is discarded by the
# background hooks) leaves held messages that would sit for days. The prompt hook says so, once per
# session per change of the held files.
test_unsent_held_messages_are_noticed() {
    setup_env
    prompt sA "hi"
    echo '{"at":"x","message":"[p] stuck"}' > "$HOME/.afd-dnd.held"
    touch -d '-1 minute' "$HOME/.afd-dnd.held"
    prompt sA "status?"
    assert_contains "$OUT" "DND_HELD:" "DND is off but messages are still held: one line (out: $OUT)"
    assert_contains "$OUT" "afd dnd off" "naming the command that sends them"
    prompt sA "next"
    assert_not_contains "$OUT" "DND_HELD" "not again while nothing changed (out: $OUT)"
    echo '{"at":"y","message":"[p] stuck too"}' > "$HOME/.afd-dnd.held.sending.999999"
    touch -d '+1 minute' "$HOME/.afd-dnd.held.sending.999999"
    prompt sA "next"
    assert_contains "$OUT" "DND_HELD:" "a new dead claim says so again (out: $OUT)"
    touch "$HOME/.afd-dnd"
    prompt sB "hi" "$HOME/proj-b"
    assert_not_contains "$OUT" "DND_HELD" "while DND is on, held messages are expected (out: $OUT)"
}
run_test "13b: held DND messages that were never sent are noticed once" test_unsent_held_messages_are_noticed

# ── the tool-call hook (afd-relay.sh) ─────────────────────────────────────────

tool() { # tool <sid> [extra json fields] — OUT = stdout, RC
    local j extra="${2:-}"
    [[ -n "$extra" ]] || extra='{}'
    j=$(python3 -c 'import json,sys; d={"tool_name":"Bash","session_id":sys.argv[1],"cwd":sys.argv[2],"tool_input":{"command":"ls -la"}}; d.update(json.loads(sys.argv[3])); print(json.dumps(d))' "$1" "$HOME/proj-b" "$extra")
    RC=0
    OUT=$(printf '%s' "$j" | bash "$RELAY_HOOK" 2>/dev/null) || RC=$?
}
context_of() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null; }

test_tool_call_reports_once() {
    setup_env
    tool sB
    assert_eq "" "$OUT" "nothing to report on the first call"
    today_at 08:30 > "$HOME/.afd-afk"
    tool sB
    assert_eq "0" "$RC" "the call is allowed"
    assert_contains "$(context_of "$OUT")" "AFK_CHANGED: on (switched 08:30)" "the next tool call carries the line as additionalContext (out: $OUT)"
    tool sB
    assert_eq "" "$OUT" "once (out: $OUT)"
}
run_test "14: a tool call reports the switch once, as additionalContext" test_tool_call_reports_once

test_subagent_neither_reports_nor_consumes() {
    setup_env
    tool sB
    touch "$HOME/.afd-afk"
    tool sB '{"agent_id":"sub-1","agent_type":"general-purpose"}'
    assert_eq "" "$OUT" "a subagent's tool call says nothing (out: $OUT)"
    tool sB
    assert_contains "$(context_of "$OUT")" "AFK_CHANGED: on" "so the main thread still learns it (out: $OUT)"
}
run_test "15: a subagent's tool call does not consume the main thread's news" test_subagent_neither_reports_nor_consumes

test_tool_call_one_json_with_wake_hint() {
    setup_env
    export AFD_WAKE_AFTER=0
    tool sB
    mkdir -p "$AFD_MSG_DIR"
    echo '{"id":801,"message":"@proj-a hello","timestamp":"t"}' > "$AFD_MSG_DIR/proj-a.jsonl"
    touch "$HOME/.afd-dnd"
    tool sB
    local ctx; ctx=$(context_of "$OUT")
    assert_contains "$ctx" "DND_CHANGED: on" "the mode line (out: $OUT)"
    assert_contains "$ctx" "TELEGRAM_UNDELIVERED" "and the wake hint, in one JSON object"
    unset AFD_WAKE_AFTER
}
run_test "16: the mode line and the wake hint share one hook output" test_tool_call_one_json_with_wake_hint

# Review #4: a Bash call the relay then BLOCKS (exit 2) has its stdout JSON ignored by Claude Code,
# so the line must reach the model on stderr too, or the switch is marked seen and never told.
blocked_call() { # blocked_call <sid> — a command that needs AFK approval; RC, ERR
    local j
    j=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","session_id":sys.argv[1],"cwd":sys.argv[2],"tool_input":{"command":"rm -rf build","description":"clean"}}))' "$1" "$HOME/proj-b")
    RC=0
    ERR=$(printf '%s' "$j" | AFD_AFK_TIMEOUT=3 bash "$RELAY_HOOK" 2>&1 >/dev/null) || RC=$?
}

test_blocked_call_still_tells() {
    setup_env
    tool sB
    touch "$HOME/.afd-afk" "$HOME/.afd-dnd"
    blocked_call sB
    assert_eq "2" "$RC" "the DND block denies the call"
    assert_contains "$ERR" "DND_CHANGED: on" "and the switch reaches the model with the denial (err: $ERR)"
    assert_contains "$ERR" "AFK_CHANGED: on" "both switches"
    rm -f "$HOME/.afd-afk" "$HOME/.afd-dnd"
    tool sC
    touch "$HOME/.afd-afk"
    blocked_call sC
    assert_eq "2" "$RC" "an approval that cannot be sent denies the call"
    assert_contains "$ERR" "AFK_CHANGED: on" "and still carries the switch (err: $ERR)"
}
run_test "16b: a blocked Bash call still tells the model about the switch" test_blocked_call_still_tells

# ── the idle wake (afd-idle-wake.sh) ──────────────────────────────────────────

test_idle_wake_carries_the_line() {
    setup_env
    export AFD_IDLE_POLL=1 AFD_IDLE_MAX=6 AFD_IDLE_PARENT_PID=$$
    prompt sA "hi"
    rm -f "$HOME/.afd-afk"; touch "$HOME/.afd-dnd"
    echo '{"id":901,"message":"@proj-a ping","timestamp":"t","persona":"Bot"}' > "$HOME/pending.jsonl"
    local rc=0 err
    err=$(printf '{"hook_event_name":"Stop","session_id":"sA","cwd":"%s"}' "$HOME/proj-a" | bash "$WAKE_HOOK" 2>&1 >/dev/null) || rc=$?
    assert_eq "2" "$rc" "the message wakes the session"
    assert_contains "$err" "DND_CHANGED: on" "the wake carries the switch (err: $err)"
    assert_contains "$err" "ping" "and the message"
    unset AFD_IDLE_POLL AFD_IDLE_MAX AFD_IDLE_PARENT_PID
}
run_test "17: an idle wake carries the switch line" test_idle_wake_carries_the_line

# ── the writers leave the switch-off stamp ────────────────────────────────────

test_cli_afk_off_stamps() {
    setup_env
    touch "$HOME/.afd-afk"
    AFD_URL="http://[::1]:9" AFD_TOKEN="sandbox-not-a-token" node "$REPO_ROOT/afd/client/afd" afk off >/dev/null 2>&1
    assert_file_not_exists "$HOME/.afd-afk" "afd afk off clears the flag"
    local t; t=$(cat "$HOME/.afd-afk.off" 2>/dev/null)
    assert_contains "$t" "$(date -u +%Y-%m-%d)T" "and leaves a switch-off stamp with today's time (got: '$t')"
    assert_neq "" "$(date -d "$t" +%H:%M 2>/dev/null)" "in a form date -d reads (got: '$t')"
}
if command -v node >/dev/null 2>&1 && [[ -f "$REPO_ROOT/afd/client/afd" ]]; then
    run_test "18: afd afk off leaves the switch-off stamp" test_cli_afk_off_stamps
else
    skip_test "18: afd afk off leaves the switch-off stamp" "node or afd/client/afd not here (the template ships no afd client)"
fi

suite_summary
