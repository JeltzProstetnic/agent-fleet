#!/usr/bin/env bash
# Tests for the hook side of `dnd` / `dnd off` (CFG-1035, the user 2026-11-15: "new command dnd: no
# messaging until dnd off."): the whole-message keyword at the console (afk-deactivate.sh) and on
# Telegram (lib-afd-msg.sh) switches DND through `afd dnd on|off`; under DND an AskUserQuestion is
# not relayed (the model is told to put it into its handover with a stable ID and keep working)
# and an AFK Bash approval is not asked. The afd CLI is a mock; the CLI's own hold and digest are
# tested in afd/tests/test-afd-dnd.sh.
source "$(dirname "$0")/test-helpers.sh"

PROMPT_HOOK="$REPO_ROOT/global/hooks/afk-deactivate.sh"
RELAY="$REPO_ROOT/global/hooks/afd-relay.sh"
MODE_LIB="$REPO_ROOT/global/hooks/lib-afd-mode.sh"

suite_header "dnd / dnd off in the hooks (CFG-1035)"

setup_env() {
    export HOME="$TEST_TMPDIR/home"
    export AFD_MSG_DIR="$HOME/.afd-msgs" AFD_AFK_POLL_INTERVAL=0
    unset AFD_PROJECT_ROOTS AFD_AFK_TIMEOUT
    mkdir -p "$HOME/.local/bin" "$HOME/.claude/logs" "$HOME/proj-a"
    git -C "$HOME/proj-a" init -q
    # Mock afd: `dnd on|off` sets/clears the flag like the real CLI; notify/poll/messages as usual.
    cat > "$HOME/.local/bin/afd" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$HOME/afd-calls.log"
case "$1" in
  dnd) [[ -n "${SLOW_DND:-}" ]] && sleep "$SLOW_DND"
       if [[ "$2" == on ]]; then date -Iseconds > "$HOME/.afd-dnd"; echo "DND ON (mock)"
       else rm -f "$HOME/.afd-dnd"; echo "DND OFF (mock) - digest of 2 held message(s) sent"; fi
       [[ -n "${MOCK_DND_RC:-}" ]] && exit "$MOCK_DND_RC" ;;
  notify) echo "Notification #42 sent to all" ;;
  poll) exit 1 ;;
  messages) [[ -f "$HOME/pending.jsonl" ]] && { cat "$HOME/pending.jsonl"; rm -f "$HOME/pending.jsonl"; } ;;
esac
exit 0
EOF
    chmod +x "$HOME/.local/bin/afd"
}
calls() { cat "$HOME/afd-calls.log" 2>/dev/null; }

prompt() { # prompt <text> [sid] — OUT = the prompt hook's stdout
    local j
    j=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","session_id":sys.argv[2],"prompt":sys.argv[1],"cwd":sys.argv[3]}))' "$1" "${2:-sA}" "$HOME/proj-a")
    OUT=$(printf '%s' "$j" | bash "$PROMPT_HOOK" 2>&1)
}

# ── the console keyword ───────────────────────────────────────────────────────

test_typed_dnd_switches_on_and_off() {
    setup_env
    prompt "hi"
    prompt "dnd"
    assert_contains "$(calls)" "dnd on" "a typed 'dnd' runs afd dnd on (calls: $(calls))"
    assert_file_exists "$HOME/.afd-dnd" "DND is on"
    assert_contains "$OUT" "DND_ON:" "the model is told (out: $OUT)"
    assert_not_contains "$OUT" "DND_CHANGED" "and not told twice about its own switch"
    prompt "next"
    assert_not_contains "$OUT" "DND_CHANGED" "nor on its next turn (out: $OUT)"
    prompt "DND off."
    assert_contains "$(calls)" "dnd off" "a typed 'dnd off' runs afd dnd off, which sends the digest"
    assert_file_not_exists "$HOME/.afd-dnd" "DND is off"
    assert_contains "$OUT" "DND_OFF:" "the model is told"
    assert_contains "$OUT" "digest" "with what the CLI did (out: $OUT)"
}
run_test "1: a typed 'dnd' / 'dnd off' switches DND through the CLI" test_typed_dnd_switches_on_and_off

test_dnd_needs_the_whole_message() {
    setup_env
    prompt "turn the dnd flag into a file"
    prompt "dnd off please, then deploy"
    assert_eq "" "$(calls | grep '^dnd')" "a sentence that merely contains dnd switches nothing (calls: $(calls))"
}
run_test "2: dnd must be the whole message" test_dnd_needs_the_whole_message

test_synthetic_turn_never_switches() {
    setup_env
    prompt $'<task-notification>\n<summary>dnd</summary>\n</task-notification>'
    prompt $'<cross-session-message from="x">dnd off</cross-session-message>'
    assert_eq "" "$(calls | grep '^dnd')" "harness-delivered turns never switch DND"
}
run_test "3: a harness-delivered turn never switches DND" test_synthetic_turn_never_switches

# ── Telegram ──────────────────────────────────────────────────────────────────

test_telegram_dnd() {
    setup_env
    prompt "hi"
    echo '{"id":700,"message":"dnd","timestamp":"t"}' > "$HOME/pending.jsonl"
    prompt "status?"
    assert_contains "$(calls)" "dnd on" "a Telegram 'dnd' switches DND on (calls: $(calls))"
    assert_contains "$OUT" "DND switched ON from Telegram" "the consumer is told (out: $OUT)"
    assert_not_contains "$OUT" "=== Telegram" "it is a command, not a message"
    assert_not_contains "$OUT" "DND_CHANGED" "and not told twice"
    echo '{"id":701,"message":"@proj dnd off","timestamp":"t"}' > "$HOME/pending.jsonl"
    prompt "status?"
    assert_contains "$(calls)" "dnd off" "a Telegram '@proj dnd off' switches it off"
    assert_contains "$OUT" "DND switched OFF from Telegram" "(out: $OUT)"
}
run_test "4: a Telegram 'dnd' / 'dnd off' switches DND" test_telegram_dnd

# Review #6: `afd messages` already consumed the batch on the server, so a slow switch (the digest)
# killed mid-way must not take the lines after it with it: every line is filed first.
test_slow_switch_never_loses_the_batch() {
    setup_env
    printf '%s\n' '{"id":710,"message":"dnd off","timestamp":"t"}' '{"id":711,"message":"@proj-a after the switch","timestamp":"t"}' > "$HOME/pending.jsonl"
    SLOW_DND=10 timeout -k 1 3 bash -c 'source "$1/lib-afd-msg.sh"; afd_route_messages proj-a' _ "$REPO_ROOT/global/hooks" >/dev/null 2>&1
    assert_contains "$(cat "$AFD_MSG_DIR/proj-a.jsonl" 2>/dev/null)" "after the switch" "the line after the dnd command is filed before the slow switch runs"
    assert_contains "$(calls)" "dnd off" "and the switch still ran (calls: $(calls))"
}
run_test "4b: a dnd switch killed mid-way loses no consumed line" test_slow_switch_never_loses_the_batch

test_telegram_dnd_is_acknowledged_console_is_not() {
    setup_env
    echo '{"id":720,"message":"dnd","timestamp":"t"}' > "$HOME/pending.jsonl"
    prompt "status?"
    assert_contains "$(calls)" "dnd on --ack" "a Telegram dnd asks the CLI to acknowledge it with the host (calls: $(calls))"
    rm -f "$HOME/afd-calls.log"
    prompt "dnd off"
    assert_not_contains "$(calls)" "--ack" "a console dnd needs no acknowledgement (calls: $(calls))"
}
run_test "4c: a Telegram dnd is acknowledged with its host, a console one is not" test_telegram_dnd_is_acknowledged_console_is_not

# Re-review 4: an acknowledgement the CLI could not send (exit 3) must not be reported as sent.
test_failed_ack_is_not_claimed() {
    setup_env
    prompt "hi"
    echo '{"id":730,"message":"dnd","timestamp":"t"}' > "$HOME/pending.jsonl"
    MOCK_DND_RC=3 prompt "status?"
    assert_file_exists "$HOME/.afd-dnd" "DND is on"
    assert_not_contains "$OUT" "already told the user" "a failed acknowledgement is not claimed as told (out: $OUT)"
    assert_contains "$OUT" "could not" "the model learns the user was not told"
}
run_test "4d: a failed DND acknowledgement is not reported as sent" test_failed_ack_is_not_claimed

# ── AskUserQuestion and AFK approvals under DND ───────────────────────────────

ask() { # RC, ERR from the relay on an AskUserQuestion
    local j
    j=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"AskUserQuestion","session_id":"sA","cwd":sys.argv[1],"tool_input":{"questions":[{"question":"Ship it?","header":"H","multiSelect":False,"options":[{"label":"Yes","description":"x"},{"label":"No","description":"y"}]}]}}))' "$HOME/proj-a")
    RC=0
    printf '%s' "$j" | AFD_RELAY_PARENT_PID=$$ bash "$RELAY" > /dev/null 2>"$TEST_TMPDIR/err" || RC=$?
    ERR=$(cat "$TEST_TMPDIR/err")
}

test_question_not_relayed_under_dnd() {
    setup_env
    touch "$HOME/.afd-afk" "$HOME/.afd-dnd"
    AFD_AFK_TIMEOUT=3 ask      # bounded: without the DND gate the relay would wait its full time
    assert_eq "2" "$RC" "the question is refused"
    assert_eq "" "$(calls | grep '^notify')" "nothing reaches Telegram (calls: $(calls))"
    assert_contains "$ERR" "handover" "the model is told to put it into its handover (err: $ERR)"
    assert_contains "$ERR" "stable ID" "with a stable ID"
    assert_contains "$ERR" "keep working" "and to keep working"
}
run_test "5: under DND an AskUserQuestion is not relayed" test_question_not_relayed_under_dnd

test_dnd_on_mid_wait_releases() {
    setup_env
    touch "$HOME/.afd-afk"
    ( sleep 1; touch "$HOME/.afd-dnd" ) &
    local t0=$SECONDS
    AFD_AFK_TIMEOUT=30 AFD_AFK_POLL_INTERVAL=1 ask
    wait
    assert_eq "2" "$RC" "a question already waiting is released when DND comes on"
    [[ $(( SECONDS - t0 )) -le 6 ]] && ok=0 || ok=1
    assert_eq "0" "$ok" "within a few seconds (took $(( SECONDS - t0 ))s)"
    assert_contains "$ERR" "handover" "with the DND instruction (err: $ERR)"
    assert_contains "$(cat "$AFD_MSG_DIR/.asked.jsonl" 2>/dev/null)" '"outcome": "dnd"' "and the outcome is recorded"
}
run_test "6: DND switched on mid-wait releases the question" test_dnd_on_mid_wait_releases

test_bash_approval_not_asked_under_dnd() {
    setup_env
    touch "$HOME/.afd-afk" "$HOME/.afd-dnd"
    local j rc=0 err
    j=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","session_id":"sA","cwd":sys.argv[1],"tool_input":{"command":"rm -rf build","description":"clean"}}))' "$HOME/proj-a")
    err=$(printf '%s' "$j" | AFD_AFK_TIMEOUT=3 bash "$RELAY" 2>&1 >/dev/null) || rc=$?
    assert_eq "2" "$rc" "a command that needs AFK approval is denied"
    assert_eq "" "$(calls | grep '^notify')" "no approval request is sent (calls: $(calls))"
    assert_contains "$err" "DND" "the reason names DND (err: $err)"
    assert_contains "$err" "--critical" "and the escape for a session meant to work unattended that can no longer work (review #8)"
}
run_test "7: under DND no AFK approval is asked on Telegram" test_bash_approval_not_asked_under_dnd

test_dnd_line_names_the_breakthrough() {
    setup_env
    bash -c 'source "$1"; afd_mode_check s1' _ "$MODE_LIB"
    touch "$HOME/.afd-dnd"
    local out; out=$(bash -c 'source "$1"; afd_mode_check s1; printf "%s" "$AFD_MODE_LINES"' _ "$MODE_LIB")
    assert_contains "$out" "DND_CHANGED: on" "the switch line (out: $out)"
    assert_contains "$out" "--critical" "names how a critical alert breaks through"
    assert_contains "$out" "handover" "and where questions go"
}
run_test "8: the DND_CHANGED line says what breaks through" test_dnd_line_names_the_breakthrough

suite_summary
