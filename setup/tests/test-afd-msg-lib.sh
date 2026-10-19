#!/usr/bin/env bash
# Tests for global/hooks/lib-afd-msg.sh — per-project routing of Telegram messages.
# `afd messages` consumes every pending message on the server, so whichever
# session's hook polls first used to receive ALL of them, including answers
# meant for another session (2026-10-18: "@alpha add" landed in cfg).
# The lib files each consumed message into the queue of the project it names.
source "$(dirname "$0")/test-helpers.sh"

LIB="$REPO_ROOT/global/hooks/lib-afd-msg.sh"

suite_header "lib-afd-msg.sh (Telegram message routing per project)"

setup_env() {
    export HOME="$TEST_TMPDIR/home"
    export AFD_MSG_DIR="$HOME/.afd-msgs"
    unset AFD_PROJECT_ROOTS   # the live settings env must not leak into the sandbox
    mkdir -p "$HOME/.local/bin"
    MOCK_AFD="$HOME/.local/bin/afd"
    # Mock: `afd messages` prints whatever is in $HOME/pending.jsonl once, then empties it.
    cat > "$MOCK_AFD" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "messages" && -f "$HOME/pending.jsonl" ]]; then
    cat "$HOME/pending.jsonl"; rm -f "$HOME/pending.jsonl"
fi
exit 0
EOF
    chmod +x "$MOCK_AFD"
    mkdir -p "$HOME/Alpha" "$HOME/config-repo" "$HOME/beta" "$HOME/gamma-radar"
    unset _LIB_AFD_MSG_LOADED
    # shellcheck source=/dev/null
    source "$LIB"
}

pending() { printf '%s\n' "$@" > "$HOME/pending.jsonl"; }

test_unaddressed_goes_to_me() {
    setup_env
    pending '{"id":1,"message":"hello","timestamp":"t","persona":"Bot"}'
    afd_route_messages "config-repo"
    local got; got=$(afd_take_messages "config-repo")
    assert_contains "$got" '"message":"hello"' "unaddressed message delivered to the consuming project (got: $got)"
}
run_test "unaddressed message stays with the consuming project" test_unaddressed_goes_to_me

test_addressed_goes_to_target() {
    setup_env
    pending '{"id":2,"message":"@alpha add","timestamp":"t","persona":"Bot"}'
    afd_route_messages "config-repo"
    local mine theirs
    mine=$(afd_take_messages "config-repo")
    theirs=$(afd_take_messages "alpha")
    assert_eq "" "$mine" "@alpha message not delivered to cfg (got: $mine)"
    assert_contains "$theirs" '@alpha add' "@alpha message queued for alpha (got: $theirs)"
}
run_test "@project message is queued for that project, not the consumer" test_addressed_goes_to_target

test_address_case_insensitive() {
    setup_env
    pending '{"id":3,"message":"@Alpha Quickly explain","timestamp":"t","persona":"Bot"}'
    afd_route_messages "config-repo"
    local theirs; theirs=$(afd_take_messages "alpha")
    assert_contains "$theirs" 'Quickly explain' "@Alpha matches project alpha (got: $theirs)"
}
run_test "@Project addressing is case-insensitive" test_address_case_insensitive

test_take_empties_queue() {
    setup_env
    pending '{"id":4,"message":"one","timestamp":"t","persona":"Bot"}' '{"id":5,"message":"two","timestamp":"t","persona":"Bot"}'
    afd_route_messages "beta"
    local first second n
    first=$(afd_take_messages "beta")
    n=$(printf '%s\n' "$first" | grep -c '"message"')
    second=$(afd_take_messages "beta")
    assert_eq "2" "$n" "both messages taken (got: $n)"
    assert_eq "" "$second" "queue empty after take (got: $second)"
}
run_test "take returns all queued lines and empties the queue" test_take_empties_queue

test_project_of_git_repo() {
    setup_env
    local repo="$TEST_TMPDIR/Alpha"
    mkdir -p "$repo/sub" && git -C "$repo" init -q
    local got; got=$(afd_project_of "$repo/sub")
    assert_eq "alpha" "$got" "project = lowercased repo root name (got: $got)"
}
run_test "project name is the lowercased git repo root" test_project_of_git_repo

test_project_of_plain_dir() {
    setup_env
    mkdir -p "$TEST_TMPDIR/Plain"
    local got; got=$(afd_project_of "$TEST_TMPDIR/Plain")
    assert_eq "plain" "$got" "non-git dir falls back to its lowercased name (got: $got)"
}
run_test "project name falls back to the directory name" test_project_of_plain_dir

test_no_afd_cli_is_silent() {
    setup_env
    rm -f "$MOCK_AFD"
    local rc=0
    afd_route_messages "config-repo" || rc=$?
    assert_eq "0" "$rc" "no afd CLI: routing is a no-op (rc=$rc)"
}
run_test "missing afd CLI is a silent no-op" test_no_afd_cli_is_silent


test_unknown_target_stays_with_consumer() {
    setup_env
    pending '{"id":6,"message":"@SomeBot hi","timestamp":"t","persona":"Bot"}'
    afd_route_messages "beta" >/dev/null
    local mine; mine=$(afd_take_messages "beta")
    assert_contains "$mine" "@SomeBot hi" "unknown @target delivered to the consumer, @ intact (got: $mine)"
    assert_file_not_exists "$AFD_MSG_DIR/somebot.jsonl" "no orphan queue for an unknown target"
}
run_test "unknown @target stays with the consumer" test_unknown_target_stays_with_consumer

test_unique_prefix_alias() {
    setup_env
    pending '{"id":7,"message":"@conf fix afk","timestamp":"t","persona":"Bot"}'
    afd_route_messages "alpha" >/dev/null
    local got; got=$(afd_take_messages "config-repo")
    assert_contains "$got" "fix afk" "@cfg resolves to the unique project config-repo (got: $got)"
}
run_test "a unique project-name prefix works as an alias" test_unique_prefix_alias

test_route_reports_foreign_targets() {
    setup_env
    pending '{"id":8,"message":"@alpha add","timestamp":"t","persona":"Bot"}' '{"id":9,"message":"mine","timestamp":"t","persona":"Bot"}'
    local out; out=$(afd_route_messages "config-repo")
    assert_eq "alpha" "$out" "route prints each foreign target once (got: $out)"
}
run_test "routing reports the projects it queued messages for" test_route_reports_foreign_targets

test_untagged_goes_to_single_waiter() {
    setup_env
    mkdir -p "$AFD_MSG_DIR/.waiting"; echo 3 > "$AFD_MSG_DIR/.waiting/alpha"
    pending '{"id":10,"message":"yes","timestamp":"t","persona":"Bot"}'
    afd_route_messages "config-repo" >/dev/null
    local got; got=$(afd_take_messages "alpha")
    assert_contains "$got" '"yes"' "untagged reply goes to the one waiting project (got: $got)"
}
run_test "untagged message goes to the single waiting project" test_untagged_goes_to_single_waiter

test_untagged_two_waiters_stays() {
    setup_env
    mkdir -p "$AFD_MSG_DIR/.waiting"; echo 3 > "$AFD_MSG_DIR/.waiting/alpha"; echo 4 > "$AFD_MSG_DIR/.waiting/beta"
    pending '{"id":11,"message":"yes","timestamp":"t","persona":"Bot"}'
    afd_route_messages "config-repo" >/dev/null
    local got; got=$(afd_take_messages "config-repo")
    assert_contains "$got" '"yes"' "ambiguous: two waiters, untagged stays with the consumer (got: $got)"
}
run_test "untagged message with two waiting projects stays with the consumer" test_untagged_two_waiters_stays

test_project_of_worktree() {
    setup_env
    local repo="$TEST_TMPDIR/config-repo"
    mkdir -p "$repo" && git -C "$repo" init -q && git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
    git -C "$repo" worktree add -q "$repo/.claude/worktrees/agent-x" 2>/dev/null
    local got; got=$(afd_project_of "$repo/.claude/worktrees/agent-x")
    assert_eq "config-repo" "$got" "a worktree resolves to its main repo (got: $got)"
}
run_test "project name of a git worktree is the main repo" test_project_of_worktree


test_telegram_afk_on() {
    setup_env
    pending '{"id":20,"message":"afk","timestamp":"t","persona":"Bot"}'
    local out; out=$(afd_route_messages "config-repo")
    assert_file_exists "$HOME/.afd-afk" "a Telegram 'afk' switches AFK on"
    assert_contains "$out" "afk:on" "routing reports it (got: $out)"
    assert_eq "" "$(afd_take_messages "config-repo")" "the command is not queued as a message"
}
run_test "Telegram 'afk' switches AFK on" test_telegram_afk_on

test_telegram_afk_off() {
    setup_env
    touch "$HOME/.afd-afk"
    pending '{"id":21,"message":"AFK off","timestamp":"t","persona":"Bot"}'
    local out; out=$(afd_route_messages "config-repo")
    assert_file_not_exists "$HOME/.afd-afk" "a Telegram 'afk off' switches AFK off"
    assert_contains "$out" "afk:off" "routing reports it (got: $out)"
}
run_test "Telegram 'afk off' switches AFK off" test_telegram_afk_off

test_telegram_afk_in_sentence_is_a_message() {
    setup_env
    pending '{"id":22,"message":"is afk working now?","timestamp":"t","persona":"Bot"}'
    afd_route_messages "config-repo" >/dev/null
    assert_file_not_exists "$HOME/.afd-afk" "'afk' inside a sentence is not a command"
    assert_contains "$(afd_take_messages "config-repo")" "is afk working" "it is delivered as a message"
}
run_test "'afk' inside a sentence is an ordinary message" test_telegram_afk_in_sentence_is_a_message

suite_summary
