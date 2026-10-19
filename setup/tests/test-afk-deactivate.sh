#!/usr/bin/env bash
# Tests for global/hooks/afk-deactivate.sh — UserPromptSubmit: end AFK only on a
# typed "afk off", and inject Telegram messages meant for this project (CFG-770).
# Measured 2026-10-18: task notifications and cross-session messages also fire
# UserPromptSubmit, and each one deleted the AFK flag with no human present.
source "$(dirname "$0")/test-helpers.sh"

HOOK="$REPO_ROOT/global/hooks/afk-deactivate.sh"

suite_header "afk-deactivate.sh (UserPromptSubmit AFK end + message injection)"

setup_env() {
    export HOME="$TEST_TMPDIR/home"
    export AFD_MSG_DIR="$HOME/.afd-msgs"
    unset AFD_PROJECT_ROOTS   # the live settings env must not leak into the sandbox
    mkdir -p "$HOME/.local/bin" "$HOME/.claude/logs" "$HOME/OtherProj"
    PROJ="$TEST_TMPDIR/cfg-agent-fleet"
    mkdir -p "$PROJ" && git -C "$PROJ" init -q
    cat > "$HOME/.local/bin/afd" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "messages" && -f "$HOME/pending.jsonl" ]]; then
    cat "$HOME/pending.jsonl"; rm -f "$HOME/pending.jsonl"
fi
exit 0
EOF
    chmod +x "$HOME/.local/bin/afd"
}

# run_prompt <prompt text> — feeds CC's UserPromptSubmit JSON to the hook.
run_prompt() {
    local json
    json=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","session_id":"sess-t","prompt":sys.argv[1],"cwd":sys.argv[2]}))' "$1" "$PROJ")
    OUT=$(printf '%s' "$json" | bash "$HOOK" 2>&1)
}

test_typed_prompt_keeps_afk() {
    setup_env
    touch "$HOME/.afd-afk"
    run_prompt "what is the status"
    assert_file_exists "$HOME/.afd-afk" "typing at the console does not end AFK"
    assert_file_not_exists "$HOME/.afd-user-active" "no user-active marker (secondary deactivation is gone)"
}
run_test "typed prompt keeps AFK on" test_typed_prompt_keeps_afk

test_afk_off_ends_afk() {
    setup_env
    touch "$HOME/.afd-afk"
    run_prompt "afk off, I'm back"
    assert_file_not_exists "$HOME/.afd-afk" "'afk off' ends AFK"
    assert_file_contains "$HOME/.claude/logs/afk.log" "project=cfg-agent-fleet" "deactivation is logged with its project"
    assert_contains "$OUT" "AFK mode deactivated" "the model is told (out: $OUT)"
}
run_test "typed 'afk off' ends AFK and logs it" test_afk_off_ends_afk

test_afk_off_word_boundary() {
    setup_env
    touch "$HOME/.afd-afk"
    run_prompt "the afk offline cache"
    assert_file_exists "$HOME/.afd-afk" "'afk offline' is not 'afk off'"
}
run_test "'afk off' needs word boundaries" test_afk_off_word_boundary

test_notification_with_afk_off_keeps_afk() {
    setup_env
    touch "$HOME/.afd-afk"
    run_prompt $'<task-notification>\n<summary>agent said afk off</summary>\n</task-notification>'
    assert_file_exists "$HOME/.afd-afk" "a task notification never ends AFK, whatever it quotes"
}
run_test "task notification quoting 'afk off' keeps AFK" test_notification_with_afk_off_keeps_afk

test_cross_session_message_keeps_afk() {
    setup_env
    touch "$HOME/.afd-afk"
    run_prompt $'<cross-session-message from="x">please afk off</cross-session-message>'
    assert_file_exists "$HOME/.afd-afk" "a message from another session never ends AFK"
}
run_test "cross-session message keeps AFK" test_cross_session_message_keeps_afk

test_injects_own_messages_only() {
    setup_env
    printf '%s\n' '{"id":1,"message":"for anyone","timestamp":"2026-10-19T00:10","persona":"Bot"}' \
                  '{"id":2,"message":"@otherproj add","timestamp":"2026-10-19T00:11","persona":"Bot"}' > "$HOME/pending.jsonl"
    run_prompt "hi"
    assert_contains "$OUT" "for anyone" "unaddressed message injected here (out: $OUT)"
    assert_not_contains "$OUT" "@otherproj add" "message for otherproj not injected here"
    assert_file_contains "$AFD_MSG_DIR/otherproj.jsonl" "@otherproj add" "message for otherproj queued for otherproj"
}
run_test "injects this project's messages, queues others for their project" test_injects_own_messages_only

test_injects_previously_queued() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"
    printf '%s\n' '{"id":3,"message":"@cfg-agent-fleet fix afk","timestamp":"2026-10-19T00:12","persona":"Bot"}' > "$AFD_MSG_DIR/cfg-agent-fleet.jsonl"
    run_prompt "hi"
    assert_contains "$OUT" "fix afk" "message another session queued for us is injected (out: $OUT)"
    assert_file_not_exists "$AFD_MSG_DIR/cfg-agent-fleet.jsonl" "queue consumed after injection"
}
run_test "injects messages other sessions queued for this project" test_injects_previously_queued

test_notification_turn_still_injects() {
    setup_env
    printf '%s\n' '{"id":4,"message":"any news?","timestamp":"2026-10-19T00:13","persona":"Bot"}' > "$HOME/pending.jsonl"
    run_prompt "<task-notification><status>completed</status></task-notification>"
    assert_contains "$OUT" "any news?" "a notification turn still delivers Telegram messages (out: $OUT)"
}
run_test "notification turns still deliver Telegram messages" test_notification_turn_still_injects


test_foreign_message_wakes_target() {
    setup_env
    mkdir -p "$HOME/OtherProj"
    printf '%s\n' '{"id":5,"message":"@otherproj add","timestamp":"2026-10-19T00:20","persona":"Bot"}' > "$HOME/pending.jsonl"
    run_prompt "hi"
    assert_contains "$OUT" "SendMessage" "the model is told to wake the target session (out: $OUT)"
    assert_contains "$OUT" "otherproj" "the target is named"
}
run_test "a message for another project asks the model to wake that session" test_foreign_message_wakes_target

test_lib_missing_falls_back() {
    setup_env
    local d="$TEST_TMPDIR/hooks"; mkdir -p "$d"; cp "$HOOK" "$d/"
    printf '%s\n' '{"id":6,"message":"still delivered","timestamp":"2026-10-19T00:21","persona":"Bot"}' > "$HOME/pending.jsonl"
    local json; json=$(python3 -c 'import json,sys; print(json.dumps({"prompt":"hi","cwd":sys.argv[1]}))' "$PROJ")
    OUT=$(printf '%s' "$json" | bash "$d/afk-deactivate.sh" 2>&1)
    assert_contains "$OUT" "still delivered" "without the lib, messages are injected directly (out: $OUT)"
    assert_contains "$OUT" "lib-afd-msg.sh" "and the missing lib is named"
}
run_test "missing routing lib falls back to direct injection with a warning" test_lib_missing_falls_back


test_untagged_message_asks_for_triage() {
    setup_env
    printf '%s\n' '{"id":30,"message":"host that graph on our website","timestamp":"2026-10-19T09:40","persona":"Bot"}' > "$HOME/pending.jsonl"
    run_prompt "hi"
    assert_contains "$OUT" "host that graph" "untagged message injected (out: $OUT)"
    assert_contains "$OUT" "not addressed" "the model is told to triage it (out: $OUT)"
    assert_contains "$OUT" "SendMessage" "and how to relay it"
}
run_test "untagged message comes with a triage-and-relay instruction" test_untagged_message_asks_for_triage

test_tagged_message_no_triage() {
    setup_env
    printf '%s\n' '{"id":31,"message":"@cfg-agent-fleet ping","timestamp":"2026-10-19T09:41","persona":"Bot"}' > "$HOME/pending.jsonl"
    run_prompt "hi"
    assert_contains "$OUT" "ping" "tagged message injected"
    assert_not_contains "$OUT" "not addressed" "no triage note for a message addressed here"
}
run_test "message addressed to this project needs no triage" test_tagged_message_no_triage

# 2026-10-20: a second consumer of the queue took the answer a waiting relay needed.
test_waiting_question_keeps_its_answer() {
    setup_env
    mkdir -p "$AFD_MSG_DIR/.waiting"
    echo "$$ 900" > "$AFD_MSG_DIR/.waiting/cfg-agent-fleet"
    printf '%s\n' '{"id":901,"message":"@cfg 1","timestamp":"2026-10-20T00:01","persona":"Bot"}' > "$HOME/pending.jsonl"
    run_prompt "hi"
    assert_not_contains "$OUT" "@cfg 1" "the answer is not injected here (out: $OUT)"
    assert_contains "$(cat "$AFD_MSG_DIR/cfg-agent-fleet.jsonl" 2>/dev/null)" "@cfg 1" "it stays queued for the waiting relay"
}
run_test "a waiting question keeps its answer in the queue" test_waiting_question_keeps_its_answer

# CFG-700: the hook ships to other fleets — the user's name comes from the env, the
# persona from the message, and nothing personal is hard-coded.
test_header_names_configured_user() {
    setup_env
    printf '%s\n' '{"id":40,"message":"@cfg-agent-fleet hi","timestamp":"2026-10-20T01:00","persona":"Bot"}' > "$HOME/pending.jsonl"
    local json
    json=$(python3 -c 'import json,sys; print(json.dumps({"prompt":"x","cwd":sys.argv[1]}))' "$PROJ")
    OUT=$(printf '%s' "$json" | AFD_USER_LABEL=Sam bash "$HOOK" 2>&1)
    assert_contains "$OUT" "=== Telegram from Sam ===" "header names AFD_USER_LABEL (out: $OUT)"
}
run_test "header names the configured user" test_header_names_configured_user

test_header_default_is_generic() {
    setup_env
    printf '%s\n' '{"id":41,"message":"@cfg-agent-fleet hi","timestamp":"2026-10-20T01:00","persona":""}' > "$HOME/pending.jsonl"
    local json
    json=$(python3 -c 'import json,sys; print(json.dumps({"prompt":"x","cwd":sys.argv[1]}))' "$PROJ")
    OUT=$(printf '%s' "$json" | env -u AFD_USER_LABEL bash "$HOOK" 2>&1)
    assert_contains "$OUT" "=== Telegram from the user ===" "generic header without AFD_USER_LABEL (out: $OUT)"
}
run_test "header is generic when no user is configured" test_header_default_is_generic

test_persona_channel_from_message() {
    setup_env
    printf '%s\n' '{"id":42,"message":"@cfg-agent-fleet miss you","timestamp":"2026-10-20T01:00","persona":"Nova"}' > "$HOME/pending.jsonl"
    run_prompt "x"
    assert_contains "$OUT" "(Nova channel) " "message labelled with its persona channel (out: $OUT)"
    assert_contains "$OUT" "--persona Nova" "reply goes out on that persona (out: $OUT)"
}
run_test "persona channel is read from the message" test_persona_channel_from_message

# Names and handles are the propagation leak gate's job; this pins the two things it
# cannot see: the header is never a hard-coded name, and no bash-4-only mapfile.
test_header_not_hardcoded() {
    local hits
    hits=$(grep -nE '=== Telegram from [A-Za-z]+ ===|^[^#]*mapfile' "$HOOK" || true)
    assert_eq "" "$hits" "no hard-coded name in the header, no mapfile"
}
run_test "header is not hard-coded, no mapfile" test_header_not_hardcoded

test_prompt_with_newlines_parsed() {
    setup_env
    touch "$HOME/.afd-afk"
    run_prompt $'line one\nafk off\nline three'
    assert_file_not_exists "$HOME/.afd-afk" "a multi-line prompt containing 'afk off' still ends AFK"
}
run_test "multi-line prompt is parsed whole" test_prompt_with_newlines_parsed

test_telegram_afk_on_confirmed() {
    setup_env
    printf '%s\n' '{"id":32,"message":"afk on","timestamp":"2026-10-19T09:42","persona":"Bot"}' > "$HOME/pending.jsonl"
    run_prompt "<task-notification><status>completed</status></task-notification>"
    assert_file_exists "$HOME/.afd-afk" "AFK on from Telegram"
    assert_contains "$OUT" "AFK switched ON from Telegram" "the model is told, to confirm on Telegram (out: $OUT)"
}
run_test "AFK switched on from Telegram is reported to the model" test_telegram_afk_on_confirmed

# CFG-776: a prompt in ANY session reports another project's undelivered queue,
# so an idle target gets woken instead of waiting forever.
test_stale_foreign_queue_is_reported() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"
    echo '{"id":379,"message":"@otherproj hi","timestamp":"t","persona":"Bot"}' > "$AFD_MSG_DIR/otherproj.jsonl"
    touch -d '-2 minutes' "$AFD_MSG_DIR/otherproj.jsonl"
    run_prompt "status?"
    assert_contains "$OUT" "TELEGRAM_UNDELIVERED" "the model is told about the stuck queue (out: $OUT)"
    assert_contains "$OUT" "@otherproj: #379" "naming project and message (out: $OUT)"
}
run_test "undelivered queue of another project is reported on a prompt" test_stale_foreign_queue_is_reported


# Review finding (2026-10-20): the server tags EVERY message with a persona (default bot
# = the default persona); only a non-default persona asks for a persona switch.
test_default_persona_no_switch() {
    setup_env
    printf '%s\n' '{"id":43,"message":"@cfg-agent-fleet hi","timestamp":"t","persona":"Main"}' > "$HOME/pending.jsonl"
    local json; json=$(python3 -c 'import json,sys; print(json.dumps({"prompt":"x","cwd":sys.argv[1]}))' "$PROJ")
    OUT=$(printf '%s' "$json" | AFD_DEFAULT_PERSONA=Main bash "$HOOK" 2>&1)
    assert_not_contains "$OUT" "ACTION:" "default persona: no switch instruction (out: $OUT)"
    assert_contains "$OUT" "(Main channel) @cfg-agent-fleet hi" "still labelled with its channel"
    assert_contains "$OUT" 'afd notify all "[cfg-agent-fleet] your reply" --channel telegram' "tagged default reply"
}
run_test "default persona channel asks for no persona switch" test_default_persona_no_switch

test_other_persona_untagged_reply() {
    setup_env
    printf '%s\n' '{"id":44,"message":"@cfg-agent-fleet hey","timestamp":"t","persona":"Nova"}' > "$HOME/pending.jsonl"
    local json; json=$(python3 -c 'import json,sys; print(json.dumps({"prompt":"x","cwd":sys.argv[1]}))' "$PROJ")
    OUT=$(printf '%s' "$json" | AFD_DEFAULT_PERSONA=Main bash "$HOOK" 2>&1)
    assert_contains "$OUT" "ACTION:" "another persona: switch instruction"
    assert_contains "$OUT" 'afd notify all "<your reply>" --channel telegram --persona Nova' "persona reply carries no project prefix (out: $OUT)"
}
run_test "other persona channel: switch, untagged persona reply" test_other_persona_untagged_reply

suite_summary
