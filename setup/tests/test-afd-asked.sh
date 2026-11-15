#!/usr/bin/env bash
# Tests for global/hooks/lib-afd-asked.sh and its callers (CFG-1034, the user 2026-11-15: "no questions
# while afk defeats the purpose of afk. afk is not dnd."): an AskUserQuestion relayed under AFK
# waits 15 min during a care shift and 45 min otherwise; every relayed question is recorded with
# its outcome; on a timeout the session states its default in one AFK_DEFAULT line, which the Stop
# hook records; a Telegram `re-ask` re-sends every timed-out question still open and sends one
# summary of the defaults taken. Nothing here reaches a network: afd is a mock on PATH-less HOME.
source "$(dirname "$0")/test-helpers.sh"

LIB="$REPO_ROOT/global/hooks/lib-afd-asked.sh"
RELAY="$REPO_ROOT/global/hooks/afd-relay.sh"
PROMPT_HOOK="$REPO_ROOT/global/hooks/afk-deactivate.sh"
WAKE_HOOK="$REPO_ROOT/global/hooks/afd-idle-wake.sh"

suite_header "lib-afd-asked.sh (question waits, record, re-ask — CFG-1034)"

setup_env() {
    export HOME="$TEST_TMPDIR/home"
    export AFD_MSG_DIR="$HOME/.afd-msgs" AFD_AFK_POLL_INTERVAL=0
    unset AFD_PROJECT_ROOTS AFD_AFK_TIMEOUT CARE_FILE
    mkdir -p "$HOME/.local/bin" "$HOME/.claude/logs" "$HOME/proj-a" "$HOME/proj-b"
    git -C "$HOME/proj-a" init -q; git -C "$HOME/proj-b" init -q
    # Mock afd: notify numbers from #42 and logs its argv; poll answers $HOME/poll-answer or
    # times out; messages hands out $HOME/pending.jsonl once.
    cat > "$HOME/.local/bin/afd" << 'EOF'
#!/usr/bin/env bash
case "$1" in
  notify)
    [[ -n "${SLOW_NOTIFY:-}" ]] && sleep "$SLOW_NOTIFY"
    n=$(( $(cat "$HOME/next-id" 2>/dev/null || echo 41) + 1 )); echo "$n" > "$HOME/next-id"
    python3 -c 'import json,sys; print(json.dumps({"id":int(sys.argv[1]),"args":sys.argv[2:]}))' "$n" "${@:2}" >> "$HOME/notify.jsonl"
    echo "Notification #$n sent to all" ;;
  poll) [[ -f "$HOME/poll-answer" ]] && { cat "$HOME/poll-answer"; exit 0; }; exit 1 ;;
  messages) [[ -f "$HOME/pending.jsonl" ]] && { cat "$HOME/pending.jsonl"; rm -f "$HOME/pending.jsonl"; } ;;
esac
exit 0
EOF
    chmod +x "$HOME/.local/bin/afd"
    touch "$HOME/.afd-afk"
}

REC() { echo "$AFD_MSG_DIR/.asked.jsonl"; }
# events <ev> [field] — one line per recorded event of that kind (the field's value, or the JSON)
events() {
    python3 -c '
import json, sys
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e.get("ev") == sys.argv[2]:
        print(e.get(sys.argv[3], "") if len(sys.argv) > 3 else json.dumps(e))' "$(REC)" "$@" 2>/dev/null
}
# sent <n> — the message text of the n-th notify call (1-based)
sent() { python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[int(sys.argv[2])-1])["args"][1])' "$HOME/notify.jsonl" "$1" 2>/dev/null; }
sent_count() { grep -c . "$HOME/notify.jsonl" 2>/dev/null || echo 0; }

# ask <sid> <question> [cwd] — run the relay on an AskUserQuestion; RC, OUT, ERR
ask() {
    local j
    j=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"AskUserQuestion","session_id":sys.argv[1],"cwd":sys.argv[3],"tool_input":{"questions":[{"question":sys.argv[2],"header":"H","multiSelect":False,"options":[{"label":"Alpha","description":"x"},{"label":"Beta","description":"y"}]}]}}))' "$1" "$2" "${3:-$HOME/proj-a}")
    RC=0
    OUT=$(printf '%s' "$j" | AFD_RELAY_PARENT_PID="${PARENT:-$$}" bash "$RELAY" 2>"$TEST_TMPDIR/err") || RC=$?
    ERR=$(cat "$TEST_TMPDIR/err")
}

# ── the wait ──────────────────────────────────────────────────────────────────

wait_of() { bash -c 'source "$1"; afd_asked_wait; echo "$ASK_WAIT"' _ "$LIB"; }

test_wait_lengths() {
    setup_env
    assert_eq "2700" "$(wait_of)" "no care shift: 45 min"
    echo "armed 1 2 p s 75" > "$HOME/.afd-care"
    assert_eq "2700" "$(wait_of)" "care only armed: still 45 min"
    echo "active 1 2 p s 75" > "$HOME/.afd-care"
    assert_eq "900" "$(wait_of)" "a care shift running: 15 min"
    assert_eq "70" "$(AFD_AFK_TIMEOUT=100 wait_of)" "AFD_AFK_TIMEOUT overrides, 30 s early as before"
    assert_eq "5" "$(AFD_AFK_TIMEOUT=5 wait_of)" "a short override is kept"
}
run_test "1: a question waits 15 min under care, 45 min otherwise" test_wait_lengths

test_message_names_the_wait() {
    setup_env
    echo "Alpha" > "$HOME/poll-answer"
    echo "active 1 2 p s 75" > "$HOME/.afd-care"
    ask s1 "Which schema?"
    assert_contains "$(sent 1)" "15 min" "the Telegram question says how long it waits (sent: $(sent 1))"
    assert_contains "$(sent 1)" "re-ask" "and how to bring it back"
    rm -f "$HOME/.afd-care"
    ask s1 "Which schema?"
    assert_contains "$(sent 2)" "45 min" "45 min outside a care shift (sent: $(sent 2))"
}
run_test "2: the Telegram question names its wait and re-ask" test_message_names_the_wait

# ── the record ────────────────────────────────────────────────────────────────

test_answered_recorded() {
    setup_env
    echo "Alpha" > "$HOME/poll-answer"
    ask s1 "Which schema?"
    assert_eq "0" "$RC" "answered (rc=$RC, err: $ERR)"
    local a; a=$(events asked)
    assert_contains "$a" '"q": 42' "the question is recorded with its id (rec: $a)"
    assert_contains "$a" '"project": "proj-a"' "its project"
    assert_contains "$a" '"sid": "s1"' "its session"
    assert_contains "$a" 'Which schema?' "its text"
    assert_contains "$a" "\"pid\": \"$$\"" "and the Claude Code pid it belongs to"
    assert_eq "answered" "$(events outcome outcome)" "outcome answered"
}
run_test "3: an answered question is recorded with its outcome" test_answered_recorded

test_timeout_recorded_and_told() {
    setup_env
    export AFD_AFK_TIMEOUT=2
    ask s1 "Which schema?"
    assert_eq "2" "$RC" "a timeout returns control to the model"
    assert_contains "$ERR" "AFK_DEFAULT #42:" "the model is told to state its default in one AFK_DEFAULT line (err: $ERR)"
    assert_contains "$ERR" "re-ask" "and that the user can bring the question back"
    assert_eq "timeout" "$(events outcome outcome)" "outcome timeout"
    assert_contains "$(events outcome told)" "AFK_DEFAULT #42:" "with what the session was told"
    assert_eq "42 0" "$(cat "$AFD_MSG_DIR/.asked-default/s1" 2>/dev/null)" "the Stop hook is left a marker to read the default from"
    unset AFD_AFK_TIMEOUT
}
run_test "4: a timeout is recorded, and the model is told to state its default" test_timeout_recorded_and_told

test_other_outcomes() {
    setup_env
    echo "denied" > "$HOME/poll-answer"
    ask s1 "Q1?"
    assert_eq "declined" "$(events outcome outcome | tail -1)" "a Telegram d is recorded as declined"
    rm -f "$HOME/poll-answer"
    ( sleep 1; rm -f "$HOME/.afd-afk" ) &
    AFD_AFK_TIMEOUT=30 AFD_AFK_POLL_INTERVAL=1 ask s1 "Q2?"
    wait
    assert_eq "afk-off" "$(events outcome outcome | tail -1)" "afk off mid-wait is recorded"
    touch "$HOME/.afd-afk"
    sleep 0 & local dead=$!; wait "$dead"
    PARENT=$dead AFD_AFK_TIMEOUT=30 AFD_AFK_POLL_INTERVAL=1 ask s1 "Q3?"
    assert_eq "gone" "$(events outcome outcome | tail -1)" "a gone Claude Code is recorded"
}
run_test "5: declined, afk-off and gone outcomes are recorded" test_other_outcomes

# ── the default line (Stop hook) ──────────────────────────────────────────────

stop() { # stop <sid> <payload-extra-json> — run the Stop hook once (no afd: it returns at once)
    rm -f "$HOME/.local/bin/afd.off"; mv "$HOME/.local/bin/afd" "$HOME/.local/bin/afd.off"
    python3 -c 'import json,sys; d={"hook_event_name":"Stop","session_id":sys.argv[1],"cwd":sys.argv[2]}; d.update(json.loads(sys.argv[3])); print(json.dumps(d))' "$1" "$HOME/proj-a" "$2" | bash "$WAKE_HOOK" >/dev/null 2>&1
    mv "$HOME/.local/bin/afd.off" "$HOME/.local/bin/afd"
}
seed_timeout() { # seed_timeout <q> <sid> — a recorded timeout awaiting its default
    mkdir -p "$AFD_MSG_DIR/.asked-default"
    python3 -c '
import json, sys, time
f = open(sys.argv[1], "a")
f.write(json.dumps({"ev":"asked","q":int(sys.argv[2]),"project":"proj-a","sid":sys.argv[3],"pid":"","question":"Which schema?","wait":900,"at":int(time.time())}) + "\n")
f.write(json.dumps({"ev":"outcome","q":int(sys.argv[2]),"outcome":"timeout","told":"x","at":int(time.time())}) + "\n")' "$(REC)" "$1" "$2"
    echo "$1 0" >> "$AFD_MSG_DIR/.asked-default/$2"
}

test_default_from_last_message() {
    setup_env
    seed_timeout 42 s1
    stop s1 '{"last_assistant_message":"No answer, so: AFK_DEFAULT #42: keep the old schema\nGoing on."}'
    assert_eq "keep the old schema" "$(events default text)" "the stated default is recorded"
    assert_file_not_exists "$AFD_MSG_DIR/.asked-default/s1" "and the marker is gone"
}
run_test "6: the Stop hook records the AFK_DEFAULT line of the last message" test_default_from_last_message

test_default_from_transcript_not_from_instruction() {
    setup_env
    seed_timeout 42 s1
    local tp="$TEST_TMPDIR/t.jsonl"
    python3 -c '
import json, sys
f = open(sys.argv[1], "w")
f.write(json.dumps({"type":"user","message":{"content":[{"type":"tool_result","content":"state it: AFK_DEFAULT #42: <your decision>"}]}}) + "\n")
f.write(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"AFK_DEFAULT #42: `ship Alpha`"}]}}) + "\n")
f.write(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"Done with the rest."}]}}) + "\n")' "$tp"
    stop s1 "{\"transcript_path\":\"$tp\",\"last_assistant_message\":\"Done with the rest.\"}"
    assert_eq "ship Alpha" "$(events default text)" "found in an earlier assistant message of the transcript, markup stripped"
}
run_test "7: the default is read from the transcript, never from the instruction" test_default_from_transcript_not_from_instruction

test_default_missing_after_three_turns() {
    setup_env
    seed_timeout 42 s1
    stop s1 '{"last_assistant_message":"nothing"}'
    assert_eq "42 1" "$(cat "$AFD_MSG_DIR/.asked-default/s1" 2>/dev/null)" "not found: tried again next turn"
    stop s1 '{"last_assistant_message":"nothing"}'; stop s1 '{"last_assistant_message":"nothing"}'
    assert_file_not_exists "$AFD_MSG_DIR/.asked-default/s1" "given up after three turns"
    assert_contains "$(events default)" '"missing": true' "recorded as not stated"
}
run_test "8: a default never stated is recorded as missing after three turns" test_default_missing_after_three_turns

# ── re-ask ────────────────────────────────────────────────────────────────────

pstart_of() { python3 -c 'import sys; print(open("/proc/%s/stat" % sys.argv[1]).read().rsplit(")",1)[1].split()[19])' "$1"; }
seed_reask() { # 42: timed out, its session alive, default stated; 43: timed out, session gone; 44: answered
    sleep 0 & local dead=$!; wait "$dead"
    python3 -c '
import json, sys, time
now = int(time.time())
ev = [
 {"ev":"asked","q":42,"project":"proj-a","sid":"s1","pid":sys.argv[2],"pstart":sys.argv[3],"question":"Which schema?\n  1) Alpha\n  2) Beta","wait":2700,"at":now-3000},
 {"ev":"outcome","q":42,"outcome":"timeout","told":"x","at":now-300},
 {"ev":"default","q":42,"text":"keep the old schema","at":now-290},
 {"ev":"asked","q":43,"project":"proj-b","sid":"s2","pid":sys.argv[4],"pstart":"1","question":"Deploy now?","wait":900,"at":now-2000},
 {"ev":"outcome","q":43,"outcome":"timeout","told":"x","at":now-1100},
 {"ev":"default","q":43,"text":"","missing":True,"at":now-1000},
 {"ev":"asked","q":44,"project":"proj-a","sid":"s1","pid":sys.argv[2],"pstart":sys.argv[3],"question":"Answered one?","wait":900,"at":now-500},
 {"ev":"outcome","q":44,"outcome":"answered","told":"","at":now-400}]
with open(sys.argv[1], "a") as f:
    for e in ev: f.write(json.dumps(e) + "\n")' "$(REC)" "$$" "$(pstart_of $$)" "$dead"
    echo 99 > "$HOME/next-id"
}
prompt() { # prompt <sid> <text> [cwd] — OUT = the prompt hook's stdout
    local j
    j=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","session_id":sys.argv[1],"prompt":sys.argv[2],"cwd":sys.argv[3]}))' "$1" "$2" "${3:-$HOME/proj-b}")
    OUT=$(printf '%s' "$j" | bash "$PROMPT_HOOK" 2>&1)
}

test_reask_resends_open_and_summarises() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"; seed_reask
    echo '{"id":900,"message":"re-ask","timestamp":"t","persona":"Bot"}' > "$HOME/pending.jsonl"
    prompt s9 "hi"
    assert_eq "2" "$(sent_count)" "one re-send (only #42 is open) and one summary (sent $(sent_count))"
    local r s; r=$(sent 1); s=$(sent 2)
    assert_contains "$r" "[proj-a] Re-ask of #42" "the re-send is tagged with its project, so a Reply routes there (sent: $r)"
    assert_contains "$r" "Which schema?" "it carries the question"
    assert_contains "$r" "keep the old schema" "and the default the session took"
    assert_contains "$r" "no answer within 45 min" "and how long it waited"
    assert_not_contains "$r$s" "Answered one?" "an answered question is never re-sent"
    assert_contains "$s" "#42" "the summary lists the default of #42 (sent: $s)"
    assert_contains "$s" "keep the old schema" "with its text"
    assert_contains "$s" "#43" "and #43, whose session is gone"
    assert_contains "$OUT" "REASK:" "the consumer is told what happened (out: $OUT)"
    assert_not_contains "$OUT" "=== Telegram" "re-ask is a command, not a message for the session"
    assert_eq "100" "$(events reasked as)" "the re-send is recorded with its notification id"
}
run_test "9: re-ask re-sends the open timed-out questions and summarises the defaults" test_reask_resends_open_and_summarises

test_second_reask() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"; seed_reask
    echo '{"id":900,"message":"re-ask","timestamp":"t"}' > "$HOME/pending.jsonl"; prompt s9 "hi"
    echo '{"id":901,"message":"@cfg re-ask","timestamp":"t"}' > "$HOME/pending.jsonl"; prompt s9 "hi"
    assert_eq "4" "$(sent_count)" "the second re-ask re-sends #42 again and sends a summary (sent $(sent_count))"
    assert_contains "$(sent 3)" "Re-ask of #42" "still open, so re-sent again"
    assert_not_contains "$(sent 4)" "keep the old schema" "defaults already summarised are not repeated (sent: $(sent 4))"
}
run_test "10: a second re-ask re-sends what is still open, without old defaults" test_second_reask

test_late_answer_routes_labels_and_closes() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"; seed_reask
    echo '{"id":900,"message":"re-ask","timestamp":"t"}' > "$HOME/pending.jsonl"; prompt s9 "hi"
    echo '{"id":950,"message":"Beta after all","timestamp":"t","reply_to":100,"reply_to_project":"proj-a"}' > "$HOME/pending.jsonl"
    prompt s9 "hi"
    assert_contains "$(cat "$AFD_MSG_DIR/proj-a.jsonl" 2>/dev/null)" '"late_answer_to": 42' "a Reply to the re-send goes to proj-a, labelled with the question"
    prompt s1 "status?" "$HOME/proj-a"
    assert_contains "$OUT" "Beta after all" "proj-a gets the late answer as a Telegram message (out: $OUT)"
    assert_contains "$OUT" "late answer to your AFK question #42" "labelled with the question it answers"
    echo '{"id":951,"message":"re-ask","timestamp":"t"}' > "$HOME/pending.jsonl"; prompt s9 "hi"
    assert_not_contains "$(sent 3)" "Re-ask of #42" "an answered question is not re-sent again (sent: $(sent 3))"
}
run_test "11: a late answer reaches its project, labelled, and closes the question" test_late_answer_routes_labels_and_closes

test_late_answer_never_answers_a_newer_question() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"
    echo '{"id":960,"message":"Beta after all","late_answer_to":42}' > "$AFD_MSG_DIR/proj-a.jsonl"
    local got; got=$(bash -c 'source "$1/lib-afd-msg.sh"; afd_queue_first_after "$2" 950' _ "$REPO_ROOT/global/hooks" "$AFD_MSG_DIR/proj-a.jsonl")
    assert_eq "" "$got" "a waiting relay never takes a late answer to an older question as its own (got: $got)"
}
run_test "12: a late answer is never the answer to a newer question" test_late_answer_never_answers_a_newer_question

# Review #6: re-ask makes one network call per open question; killed mid-way it must not take the
# rest of the consumed batch with it.
test_slow_reask_never_loses_the_batch() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"; seed_reask
    printf '%s\n' '{"id":900,"message":"re-ask","timestamp":"t"}' '{"id":901,"message":"@proj-b after re-ask","timestamp":"t"}' > "$HOME/pending.jsonl"
    SLOW_NOTIFY=10 timeout -k 1 3 bash -c 'source "$1/lib-afd-msg.sh"; afd_route_messages proj-b' _ "$REPO_ROOT/global/hooks" >/dev/null 2>&1
    assert_contains "$(cat "$AFD_MSG_DIR/proj-b.jsonl" 2>/dev/null)" "after re-ask" "the line after re-ask is filed before the slow re-ask runs"
}
run_test "13b: a re-ask killed mid-way loses no consumed line" test_slow_reask_never_loses_the_batch

test_reask_summary_names_the_host() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"; seed_reask
    echo '{"id":900,"message":"re-ask","timestamp":"t"}' > "$HOME/pending.jsonl"
    AFD_HOSTNAME=testbox prompt s9 "hi"
    assert_contains "$(sent 2)" "testbox" "the summary says which machine's record it covers (sent: $(sent 2))"
    echo '{"id":901,"message":"re-ask","timestamp":"t"}' > "$HOME/pending.jsonl"
    AFD_HOSTNAME=testbox prompt s9 "hi"
    assert_contains "$(sent 4)" "on testbox" "an empty summary speaks for this machine only, never fleet-wide (sent: $(sent 4))"
}
run_test "13c: the re-ask summary names its host" test_reask_summary_names_the_host

# Review #8: the record is pruned when a question is asked too (not only at re-ask), and a default
# marker of a session that is gone is dropped, its default recorded as not stated.
test_ask_prunes_and_sweeps() {
    setup_env
    mkdir -p "$AFD_MSG_DIR/.asked-default"
    sleep 0 & local dead=$!; wait "$dead"
    python3 -c '
import json, sys, time
now = int(time.time())
with open(sys.argv[1], "w") as f:
    for e in [{"ev":"asked","q":7,"project":"proj-a","sid":"old","pid":"","question":"Ancient?","wait":900,"at":now - 8*86400},
              {"ev":"asked","q":8,"project":"proj-a","sid":"gone","pid":sys.argv[2],"pstart":"1","question":"Orphan?","wait":900,"at":now - 600},
              {"ev":"outcome","q":8,"outcome":"timeout","told":"x","at":now - 300}]:
        f.write(json.dumps(e) + "\n")' "$(REC)" "$dead"
    echo "8 0" > "$AFD_MSG_DIR/.asked-default/gone"
    echo "Alpha" > "$HOME/poll-answer"
    ask s1 "Fresh?"
    assert_not_contains "$(events asked)" "Ancient?" "a question older than 7 days is pruned when a new one is asked"
    assert_contains "$(events asked)" "Fresh?" "the new one is recorded"
    assert_file_not_exists "$AFD_MSG_DIR/.asked-default/gone" "the default marker of a session that is gone is dropped"
    assert_contains "$(events default)" '"missing": true' "its default is recorded as not stated"
}
run_test "13d: asking prunes old questions and drops dead sessions' default markers" test_ask_prunes_and_sweeps

# Re-review 6: the timeout append (afd_asked_end), the Stop hook's rewrite (capture) and the sweep
# share .asked-default/.lock, so an os.replace can never drop a concurrent append. Proven by
# holding the lock from outside: every writer waits for it.
ms_now() { echo $(( $(date +%s%N) / 1000000 )); }
test_marker_writers_take_the_lock() {
    setup_env
    seed_timeout 42 s1
    local L="$AFD_MSG_DIR/.asked-default/.lock" t0 w1 w2 w3 holder
    flock "$L" sleep 2 & holder=$!; sleep 0.3
    t0=$(ms_now); bash -c 'source "$1"; afd_asked_end 43 timeout s1 told' _ "$LIB"; w1=$(( $(ms_now) - t0 ))
    wait "$holder"
    assert_contains "$(cat "$AFD_MSG_DIR/.asked-default/s1")" "43 0" "the appended row is there"
    flock "$L" sleep 2 & holder=$!; sleep 0.3
    t0=$(ms_now); stop s1 '{"last_assistant_message":"AFK_DEFAULT #42: keep it"}'; w2=$(( $(ms_now) - t0 ))
    wait "$holder"
    assert_eq "43 1" "$(cat "$AFD_MSG_DIR/.asked-default/s1")" "the rewrite kept the other row (marker: $(cat "$AFD_MSG_DIR/.asked-default/s1"))"
    echo "Alpha" > "$HOME/poll-answer"
    flock "$L" sleep 3 & holder=$!; sleep 0.3
    t0=$(ms_now); ask s2 "Sweep?"; w3=$(( $(ms_now) - t0 ))
    wait "$holder"
    (( w1 >= 1200 )) && r=0 || r=1; assert_eq "0" "$r" "afd_asked_end waits for the lock (waited ${w1} ms)"
    (( w2 >= 1200 )) && r=0 || r=1; assert_eq "0" "$r" "the Stop hook's rewrite waits for the lock (waited ${w2} ms)"
    (( w3 >= 2200 )) && r=0 || r=1; assert_eq "0" "$r" "the sweep at ask waits for the lock (waited ${w3} ms)"
}
run_test "13e: every writer of the default markers takes their lock" test_marker_writers_take_the_lock

test_reask_prunes_old_questions() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"
    python3 -c '
import json, sys, time
old = int(time.time()) - 8 * 86400
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"ev":"asked","q":7,"project":"proj-a","sid":"s","pid":"","question":"Ancient?","wait":900,"at":old}) + "\n")
    f.write(json.dumps({"ev":"outcome","q":7,"outcome":"timeout","told":"x","at":old}) + "\n")' "$(REC)"
    echo '{"id":900,"message":"re-ask","timestamp":"t"}' > "$HOME/pending.jsonl"; prompt s9 "hi"
    assert_eq "" "$(events asked)" "a question older than 7 days is pruned from the record"
    assert_not_contains "$(sent 1)" "Ancient?" "and not re-sent (sent: $(sent 1))"
}
run_test "13: re-ask prunes questions older than 7 days" test_reask_prunes_old_questions

suite_summary
