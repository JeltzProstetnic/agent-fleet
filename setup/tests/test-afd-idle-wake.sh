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

# --- CFG-797: a new cross-project inbox item wakes the idle session, but only while its
# context use is under 45 % of its window (owner decision 2026-10-21). Unknown budget → no wake.
setup_inbox() {
    setup_env
    CFG="$TEST_TMPDIR/cfg"
    rm -rf "$CFG"; mkdir -p "$CFG/setup/scripts" "$CFG/cross-project/inbox"
    cp "$REPO_ROOT/setup/scripts/inbox-file.sh" "$REPO_ROOT/setup/scripts/inbox-lib.sh" "$CFG/setup/scripts/"
    export INBOX_REPO="$CFG" CONFIG_REPO="$CFG"
    mkdir -p "$HOME/.claude"
}
budget() { # budget <sid> <pct> <size>
    printf '{"pct": %s, "remaining": %s, "size": %s, "used_k": %s}' \
        "$2" "$((100 - $2))" "$3" "$(( $3 * $2 / 100000 ))" > "$HOME/.claude/.context-budget-$1.json"
}
file_item() { bash "$CFG/setup/scripts/inbox-file.sh" --project "$1" --type work --body "$2" >/dev/null 2>&1; }

test_inbox_item_wakes_under_threshold() {
    setup_inbox; budget s1 20 1000000
    ( sleep 2; file_item proj-a "rebuild the widget" ) &
    run_waiter s1 "$HOME/proj-a"
    wait
    assert_eq "2" "$RC" "a new inbox item wakes the idle session at 20 %"
    assert_contains "$ERR" "INBOX_PENDING" "framed like the prompt hook's signal"
    assert_contains "$ERR" "proj-a.md" "names the inbox file to read"
    [[ "$ERR" != *"rebuild the widget"* ]] && ok=0 || ok=1
    assert_eq "0" "$ok" "item bodies (written by other sessions) are not injected — Fable F1"
    [[ $TOOK -le 5 ]] && ok=0 || ok=1
    assert_eq "0" "$ok" "woken within a few seconds of filing (took ${TOOK}s)"
}
run_test "CFG-797: new inbox item wakes an idle session under 45 %" test_inbox_item_wakes_under_threshold

test_inbox_threshold_is_share_of_window() {
    setup_inbox; budget s1 40 200000          # 80k of a 200k window: under 45 %
    ( sleep 2; file_item proj-a "small window item" ) &
    run_waiter s1 "$HOME/proj-a"; wait
    assert_eq "2" "$RC" "40 % of a 200k window wakes (relative, not absolute 450k)"
}
run_test "CFG-797: threshold is 45 % of the window" test_inbox_threshold_is_share_of_window

test_inbox_at_or_over_threshold_no_wake() {
    setup_inbox; budget s1 45 1000000
    ( sleep 2; file_item proj-a "too full" ) &
    run_waiter s1 "$HOME/proj-a"; wait
    assert_eq "0" "$RC" "45 % (450k of 1M) does not wake — strictly below only"
}
run_test "CFG-797: at/over 45 % the item waits for the next prompt" test_inbox_at_or_over_threshold_no_wake

test_inbox_unknown_budget_no_wake() {
    setup_inbox
    ( sleep 2; file_item proj-a "no sidecar" ) &
    run_waiter s1 "$HOME/proj-a"; wait
    assert_eq "0" "$RC" "no budget sidecar: no wake"
}
run_test "CFG-797: unknown context use → no wake" test_inbox_unknown_budget_no_wake

test_inbox_existing_item_no_wake() {
    setup_inbox; budget s1 20 1000000
    file_item proj-a "already there at turn end"
    run_waiter s1 "$HOME/proj-a"
    assert_eq "0" "$RC" "items open when the turn ended do not wake (the session saw them)"
}
run_test "CFG-797: items already open at turn end do not wake" test_inbox_existing_item_no_wake

test_inbox_foreign_item_no_wake() {
    setup_inbox; budget s1 20 1000000
    ( sleep 2; file_item proj-b "for b only" ) &
    run_waiter s1 "$HOME/proj-a"; wait
    assert_eq "0" "$RC" "another project's item does not wake this session"
}
run_test "CFG-797: another project's inbox item does not wake" test_inbox_foreign_item_no_wake

# Fable F6: the next turn's waiter rebaselines, so one item cannot wake twice.
test_inbox_same_item_wakes_once() {
    setup_inbox; budget s1 20 1000000
    ( sleep 2; file_item proj-a "wake me once" ) &
    run_waiter s1 "$HOME/proj-a"; wait
    assert_eq "2" "$RC" "first waiter wakes" || return 1
    run_waiter s1 "$HOME/proj-a"
    assert_eq "0" "$RC" "the next waiter, item still open, does not wake again"
}
run_test "CFG-797: an undispatched item wakes only once" test_inbox_same_item_wakes_once

# --- CFG-806: a session that is shutting down must not be woken. Claude Code is still
# alive while its SessionEnd hooks run (up to CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS), so an
# exit 2 in that window opens a new turn in a session the user has already left. The
# SessionEnd hook marks the session as ending ($AFD_MSG_DIR/.idle/<sid>.ending) and sends
# the waiter SIGTERM; the waiter honours both and leaves every message where the next
# session's prompt hook finds it.
ending_file() { echo "$AFD_MSG_DIR/.idle/$1.ending"; }

# start_waiter <sid> <cwd> — in the background; wait_rc collects RC (exit code or "none").
start_waiter() {
    BG_RC_FILE="$TEST_TMPDIR/rc.$1"; BG_ERR_FILE="$TEST_TMPDIR/err.$1"
    rm -f "$BG_RC_FILE"; : > "$BG_ERR_FILE"
    ( stop_json "$1" "$2" | bash "$HOOK" 2>"$BG_ERR_FILE" >/dev/null; echo $? > "$BG_RC_FILE" ) &
    BG_PID=$!
}
wait_rc() { # wait_rc <max-seconds>
    local t0=$SECONDS
    while [[ ! -s "$BG_RC_FILE" ]] && (( SECONDS - t0 < $1 )); do sleep 0.2; done
    RC=$(cat "$BG_RC_FILE" 2>/dev/null || echo none); TOOK=$(( SECONDS - t0 ))
    if [[ "$RC" == none ]]; then   # still running: do not let a red test hang the suite
        local p; p=$(cat "$AFD_MSG_DIR/.idle/"*.pid 2>/dev/null); [[ -n "$p" ]] && kill "$p" 2>/dev/null
        kill "$BG_PID" 2>/dev/null
    fi
    wait "$BG_PID" 2>/dev/null || true
}

test_ending_marker_blocks_inbox_wake() {
    setup_inbox; budget s1 20 1000000
    export AFD_IDLE_MAX=30
    start_waiter s1 "$HOME/proj-a"
    sleep 1.5
    : > "$(ending_file s1)"
    file_item proj-a "filed while the session shuts down"
    wait_rc 8
    assert_eq "0" "$RC" "session marked ending: a new inbox item does not wake (exit 0, not 2)"
    [[ $TOOK -le 5 ]] && ok=0 || ok=1
    assert_eq "0" "$ok" "the waiter stops within a poll of the marker (took ${TOOK}s)"
    assert_eq "" "$(cat "$BG_ERR_FILE")" "nothing is printed for the model to read"
}
run_test "CFG-806: the ending marker blocks an inbox wake" test_ending_marker_blocks_inbox_wake

test_ending_marker_keeps_telegram_queued() {
    setup_env; export AFD_IDLE_MAX=30
    start_waiter s1 "$HOME/proj-a"
    sleep 1.5
    : > "$(ending_file s1)"
    echo '{"id":806,"message":"@proj-a sent during /exit","timestamp":"t","persona":"Bot"}' > "$HOME/pending.jsonl"
    wait_rc 8
    assert_eq "0" "$RC" "session marked ending: a Telegram message does not wake"
    assert_eq "" "$(cat "$BG_ERR_FILE")" "and is not printed"
    assert_contains "$(cat "$AFD_MSG_DIR/proj-a.jsonl" "$HOME/pending.jsonl" 2>/dev/null)" "sent during /exit" \
        "the message is not lost: it waits (queued or unconsumed) for the next session's prompt hook"
}
run_test "CFG-806: the ending marker leaves a Telegram message for the next session" test_ending_marker_keeps_telegram_queued

test_sigterm_stops_quietly_and_promptly() {
    setup_env; export AFD_IDLE_MAX=60 AFD_IDLE_POLL=20
    start_waiter s1 "$HOME/proj-a"
    sleep 1.5
    local wpid; wpid=$(cat "$AFD_MSG_DIR/.idle/s1.pid" 2>/dev/null)
    assert_neq "" "$wpid" "the waiter wrote its pidfile" || { wait_rc 1; return 1; }
    local t0=$SECONDS
    kill -TERM "$wpid"
    wait_rc 10
    local took=$(( SECONDS - t0 ))
    assert_eq "0" "$RC" "SIGTERM from the SessionEnd hook ends the waiter with exit 0 (not 143)"
    [[ $took -le 3 ]] && ok=0 || ok=1
    assert_eq "0" "$ok" "even mid-poll (poll 20 s) it stops at once (took ${took}s)"
    assert_eq "" "$(cat "$BG_ERR_FILE")" "no stderr, so safe-run has nothing to pass through"
    assert_file_not_exists "$AFD_MSG_DIR/.idle/s1.pid" "its pidfile is released"
}
run_test "CFG-806: SIGTERM stops the waiter quietly and at once" test_sigterm_stops_quietly_and_promptly

test_stale_marker_is_ignored() {
    setup_env
    mkdir -p "$AFD_MSG_DIR/.idle"; : > "$(ending_file s1)"   # left by an earlier life of session s1 (/resume)
    ( sleep 2; echo '{"id":807,"message":"@proj-a still awake","timestamp":"t","persona":"Bot"}' > "$HOME/pending.jsonl" ) &
    run_waiter s1 "$HOME/proj-a"; wait
    assert_eq "2" "$RC" "a marker older than this waiter does not silence a resumed session"
    assert_file_not_exists "$(ending_file s1)" "the stale marker is cleared at start"
}
run_test "CFG-806: a marker older than the waiter is cleared, not obeyed" test_stale_marker_is_ignored

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
