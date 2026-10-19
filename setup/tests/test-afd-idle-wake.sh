#!/usr/bin/env bash
# Tests for global/hooks/afd-idle-wake.sh — CFG-777: wake an IDLE session mechanically.
# Registered as a Stop hook with asyncRewake: it runs in the background after every
# turn, polls afd, routes messages, and exits 2 (= wake the model, stderr = what it
# reads) the moment a Telegram message for its own project arrives. No other session
# has to be reading (2026-10-19: the user's @<project> messages sat 10+ min in an idle session).
source "$(dirname "$0")/test-helpers.sh"

HOOK="$REPO_ROOT/global/hooks/afd-idle-wake.sh"

suite_header "afd-idle-wake.sh (asyncRewake idle waiter)"

setup_env() {
    export HOME="$TEST_TMPDIR/home"
    export AFD_MSG_DIR="$HOME/.afd-msgs"
    export AFD_IDLE_POLL=1
    export AFD_IDLE_MAX=6
    unset AFD_PROJECT_ROOTS
    mkdir -p "$HOME/.local/bin" "$HOME/proj-a" "$HOME/proj-b"
    git -C "$HOME/proj-a" init -q; git -C "$HOME/proj-b" init -q
    # Mock afd: `messages` prints $HOME/pending.jsonl once, then empties it.
    cat > "$HOME/.local/bin/afd" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "messages" && -f "$HOME/pending.jsonl" ]]; then
    cat "$HOME/pending.jsonl"; rm -f "$HOME/pending.jsonl"
fi
exit 0
EOF
    chmod +x "$HOME/.local/bin/afd"
    export AFD_IDLE_PARENT_PID=$$   # the test shell stands in for the Claude Code process
}

stop_json() { printf '{"hook_event_name":"Stop","session_id":"%s","cwd":"%s"}' "$1" "$2"; }

# run_waiter <sid> <cwd> — runs in the foreground; sets RC, ERR, TOOK
run_waiter() {
    local t0=$SECONDS
    RC=0
    ERR=$(stop_json "$1" "$2" | bash "$HOOK" 2>&1 >/dev/null) || RC=$?
    TOOK=$(( SECONDS - t0 ))
}

test_message_for_me_wakes() {
    setup_env
    ( sleep 2; echo '{"id":501,"message":"@proj-a ping","timestamp":"2026-10-19 20:50:00","persona":"Bot"}' > "$HOME/pending.jsonl" ) &
    run_waiter s1 "$HOME/proj-a"
    wait
    assert_eq "2" "$RC" "exit 2 wakes the model"
    assert_contains "$ERR" "ping" "the message text reaches the model (stderr: $ERR)"
    assert_contains "$ERR" "Telegram message" "framed as a Telegram message"
    assert_contains "$ERR" "afd notify all" "says how to reply"
    [[ $TOOK -le 5 ]] && ok=0 || ok=1
    assert_eq "0" "$ok" "woken within a few seconds of arrival (took ${TOOK}s)"
    assert_eq "" "$(cat "$AFD_MSG_DIR/proj-a.jsonl" 2>/dev/null)" "the message is taken, so the prompt hook does not deliver it twice"
}
run_test "a message for this project wakes the session" test_message_for_me_wakes

test_already_queued_wakes_at_once() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"
    echo '{"id":502,"message":"@proj-a queued earlier","timestamp":"t","persona":"Bot"}' > "$AFD_MSG_DIR/proj-a.jsonl"
    run_waiter s1 "$HOME/proj-a"
    assert_eq "2" "$RC" "a message already in the local queue wakes"
    assert_contains "$ERR" "queued earlier" "with its text"
}
run_test "a message already queued locally wakes immediately" test_already_queued_wakes_at_once

test_foreign_message_does_not_wake() {
    setup_env
    echo '{"id":503,"message":"@proj-b for b","timestamp":"t","persona":"Bot"}' > "$HOME/pending.jsonl"
    run_waiter s1 "$HOME/proj-a"
    assert_eq "0" "$RC" "another project's message does not wake this one (ends at max wait)"
    assert_contains "$(cat "$AFD_MSG_DIR/proj-b.jsonl" 2>/dev/null)" "for b" "it is filed for its own project's waiter"
}
run_test "another project's message is routed, not delivered here" test_foreign_message_does_not_wake

# 2026-10-20: the previous turn's waiter is still alive while this turn's AskUserQuestion
# relay waits, and it took the Telegram answer from the shared queue first — the relay
# never saw it and stayed blocked (#406/#408). A waiting question owns the queue.
test_waiting_question_owns_the_queue() {
    setup_env
    mkdir -p "$AFD_MSG_DIR/.waiting"
    echo "$$ 900" > "$AFD_MSG_DIR/.waiting/proj-a"
    echo '{"id":901,"message":"@proj-a 1","timestamp":"t","persona":"Bot"}' > "$HOME/pending.jsonl"
    run_waiter s1 "$HOME/proj-a"
    assert_eq "0" "$RC" "no wake while this project's question waits (ends at max wait)"
    assert_contains "$(cat "$AFD_MSG_DIR/proj-a.jsonl" 2>/dev/null)" "@proj-a 1" "the answer stays queued for the waiting relay"
}
run_test "a waiting AskUserQuestion relay owns the project's queue" test_waiting_question_owns_the_queue

test_resumes_after_question_answered() {
    setup_env
    mkdir -p "$AFD_MSG_DIR/.waiting"
    echo "$$ 900" > "$AFD_MSG_DIR/.waiting/proj-a"
    echo '{"id":902,"message":"@proj-a later","timestamp":"t","persona":"Bot"}' > "$AFD_MSG_DIR/proj-a.jsonl"
    ( sleep 2; rm -f "$AFD_MSG_DIR/.waiting/proj-a" ) &
    run_waiter s1 "$HOME/proj-a"
    wait
    assert_eq "2" "$RC" "once the question is gone the waiter delivers again"
    assert_contains "$ERR" "later" "with the queued text"
}
run_test "the waiter resumes delivery once the question is answered" test_resumes_after_question_answered

test_newer_waiter_supersedes() {
    setup_env
    export AFD_IDLE_MAX=30
    stop_json s1 "$HOME/proj-a" | bash "$HOOK" >/dev/null 2>&1 &
    local first=$!
    sleep 1.5
    stop_json s1 "$HOME/proj-a" | bash "$HOOK" >/dev/null 2>&1 &
    local second=$!
    local i; for i in 1 2 3 4 5 6; do kill -0 "$first" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$first" 2>/dev/null && ok=1 || ok=0
    assert_eq "0" "$ok" "the older waiter of the same session exits"
    kill -0 "$second" 2>/dev/null && ok=0 || ok=1
    assert_eq "0" "$ok" "the newer waiter keeps waiting"
    kill "$second" 2>/dev/null; wait 2>/dev/null
}
run_test "a newer waiter of the same session supersedes the older" test_newer_waiter_supersedes

test_parent_gone_exits() {
    setup_env
    export AFD_IDLE_MAX=30
    sleep 1 & local p=$!
    export AFD_IDLE_PARENT_PID=$p
    wait "$p"
    run_waiter s1 "$HOME/proj-a"
    assert_eq "0" "$RC" "exit quietly when Claude Code is gone"
    [[ $TOOK -le 4 ]] && ok=0 || ok=1
    assert_eq "0" "$ok" "and promptly (took ${TOOK}s)"
}
run_test "no orphan: exits when its Claude Code process is gone" test_parent_gone_exits

test_no_afd_cli_is_silent() {
    setup_env
    rm -f "$HOME/.local/bin/afd"
    run_waiter s1 "$HOME/proj-a"
    assert_eq "0" "$RC" "no afd CLI: nothing to wait for"
    [[ $TOOK -le 2 ]] && ok=0 || ok=1
    assert_eq "0" "$ok" "returns at once (took ${TOOK}s)"
}
run_test "no afd CLI: exits at once" test_no_afd_cli_is_silent

test_settings_registers_async_rewake_stop_hook() {
    local got
    got=$(python3 -c "
import json
s = json.load(open('$REPO_ROOT/setup/config/settings.json'))
for g in s['hooks'].get('Stop', []):
    for h in g['hooks']:
        if 'afd-idle-wake.sh' in h.get('command', ''):
            print(h.get('asyncRewake'), 'safe-run.sh' in h['command'], h.get('timeout', 0))")
    assert_eq "True True 43260" "$got" "Stop hook: asyncRewake, routed via safe-run, timeout outlasts the 43200 s wait"
}
run_test "settings: Stop hook registered with asyncRewake via safe-run" test_settings_registers_async_rewake_stop_hook

suite_summary
