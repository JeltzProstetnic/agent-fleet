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

# CFG-779 (2026-10-24): with two sessions waiting, an untagged answer fell to the consumer,
# which took it as its own. Untagged lines now go to a shared pool while any relay waits;
# the waiting relays claim from it (lib-afd-pool.sh). The waiter's own queue is for @tags.
POOL() { echo "$AFD_MSG_DIR/.untagged.jsonl"; }

test_untagged_pooled_for_single_waiter() {
    setup_env
    mkdir -p "$AFD_MSG_DIR/.waiting"; echo "$$ 3" > "$AFD_MSG_DIR/.waiting/alpha"
    pending '{"id":10,"message":"yes","timestamp":"t","persona":"Bot"}'
    afd_route_messages "config-repo" >/dev/null
    assert_file_contains "$(POOL)" '"yes"' "untagged reply goes to the pool while a relay waits"
    assert_file_contains "$(POOL)" '"pooled": *[0-9]' "with the time it was pooled (tier-2 grace runs from it)"
    assert_file_not_exists "$AFD_MSG_DIR/alpha.jsonl" "not straight into the waiter's queue"
    assert_file_not_exists "$AFD_MSG_DIR/config-repo.jsonl" "and not to the consumer"
}
run_test "untagged message with one waiting project goes to the pool" test_untagged_pooled_for_single_waiter

test_untagged_two_waiters_pooled() {
    setup_env
    mkdir -p "$AFD_MSG_DIR/.waiting"; echo "$$ 3" > "$AFD_MSG_DIR/.waiting/alpha"; echo "$$ 4" > "$AFD_MSG_DIR/.waiting/beta"
    pending '{"id":11,"message":"yes","timestamp":"t","persona":"Bot"}'
    afd_route_messages "config-repo" >/dev/null
    assert_file_contains "$(POOL)" '"yes"' "two waiters: the untagged reply is pooled, not taken by the consumer"
    assert_eq "" "$(afd_take_messages "config-repo")" "the consumer gets nothing while relays wait (the 2026-10-24 defect)"
}
run_test "untagged message with two waiting projects goes to the pool" test_untagged_two_waiters_pooled

test_bare_tag_is_a_verdict_while_waiting() {
    setup_env
    mkdir -p "$AFD_MSG_DIR/.waiting"; echo "$$ 3 claimed 10 11" > "$AFD_MSG_DIR/.waiting/alpha"
    pending '{"id":12,"message":"@beta","timestamp":"t","persona":"Bot"}' '{"id":13,"message":"@beta do this","timestamp":"t","persona":"Bot"}'
    afd_route_messages "config-repo" >/dev/null
    assert_file_contains "$(POOL)" '"@beta"' "a bare @project while a relay waits is its redirect verdict: pooled"
    assert_file_not_contains "$AFD_MSG_DIR/beta.jsonl" '"@beta"' "not an (empty) message for beta"
    assert_file_contains "$AFD_MSG_DIR/beta.jsonl" '"@beta do this"' "a tag with text is still a message for beta"
    pending '{"id":15,"message":"@beta #11","timestamp":"t","persona":"Bot"}'
    afd_route_messages "config-repo" >/dev/null
    assert_file_contains "$(POOL)" '"@beta #11"' "a tag followed only by a #number is a targeted redirect verdict: pooled too (review MAJOR 3)"
    rm -f "$AFD_MSG_DIR/.waiting/alpha"
    pending '{"id":14,"message":"@beta","timestamp":"t","persona":"Bot"}'
    afd_route_messages "config-repo" >/dev/null
    assert_file_contains "$AFD_MSG_DIR/beta.jsonl" '"id":14' "with no relay waiting a bare @project goes to that project, as before"
}
run_test "a bare @project is pooled as a verdict only while a relay waits" test_bare_tag_is_a_verdict_while_waiting

test_pool_drained_only_when_no_waiter() {
    setup_env
    mkdir -p "$AFD_MSG_DIR/.waiting"; echo "$$ 3" > "$AFD_MSG_DIR/.waiting/alpha"
    pending '{"id":12,"message":"chat","timestamp":"t","persona":"Bot"}'
    afd_route_messages "config-repo" >/dev/null
    assert_eq "" "$(afd_take_messages "beta")" "a consumer never drains the pool while a relay waits"
    rm -f "$AFD_MSG_DIR/.waiting/alpha"
    assert_contains "$(afd_take_messages "beta")" '"chat"' "with no waiter left, the next consumer takes the pool (zero waiters = consumer, as before)"
    assert_file_not_exists "$(POOL)" "and the pool is emptied"
}
run_test "pool: drained by a consumer only when no relay waits" test_pool_drained_only_when_no_waiter

test_claim_is_atomic() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"
    local i rc1 rc2 t=0
    # Two live claimers race for the same id; each passes its own pid and stays alive a while.
    ( afd_claim 50 alpha "$BASHPID"; echo $? > "$TEST_TMPDIR/rc1"; sleep 2 ) &
    ( afd_claim 50 beta "$BASHPID"; echo $? > "$TEST_TMPDIR/rc2"; sleep 2 ) &
    while [[ ! -s "$TEST_TMPDIR/rc1" || ! -s "$TEST_TMPDIR/rc2" ]] && (( t++ < 50 )); do sleep 0.1; done
    rc1=$(cat "$TEST_TMPDIR/rc1"); rc2=$(cat "$TEST_TMPDIR/rc2")
    assert_eq "1" "$(( (rc1 == 0) + (rc2 == 0) ))" "exactly one of two concurrent claimers wins (rc1=$rc1 rc2=$rc2)"
    assert_file_exists "$AFD_MSG_DIR/.claims/50/owner" "the claim records its owner"
    afd_claim 50 gamma "$$" && i=0 || i=1
    assert_eq "1" "$i" "a third claimer is refused while the owner is alive"
    wait
}
run_test "claim: two concurrent claimers, exactly one wins" test_claim_is_atomic

test_claim_reaps_dead_owner() {
    setup_env
    local dead; sleep 0 & dead=$!; wait "$dead"
    mkdir -p "$AFD_MSG_DIR/.claims/51"; echo "$dead alpha" > "$AFD_MSG_DIR/.claims/51/owner"
    afd_claim 51 beta "$$" && r=0 || r=1
    assert_eq "0" "$r" "a dead relay's claim is reaped and taken over"
    assert_eq "$$ beta" "$(cat "$AFD_MSG_DIR/.claims/51/owner")" "the new owner is recorded"
    afd_claim 51 beta "$$" && r=0 || r=1
    assert_eq "0" "$r" "re-claiming one's own claim succeeds"
    afd_release_claim 51 "$dead"
    assert_dir_exists "$AFD_MSG_DIR/.claims/51" "release by a non-owner is ignored"
    afd_release_claim 51 "$$"
    [[ -d "$AFD_MSG_DIR/.claims/51" ]] && r=1 || r=0
    assert_eq "0" "$r" "the owner's release removes the claim"
}
run_test "claim: a dead owner's claim is reaped; only the owner releases" test_claim_reaps_dead_owner

test_queue_peek_and_delete_by_id() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"
    local q="$AFD_MSG_DIR/alpha.jsonl"
    printf '%s\n' '{"id":5,"message":"old","timestamp":"t"}' '{"id":70,"message":"@alpha a","timestamp":"t"}' \
                  '{"id":71,"message":"@alpha b","timestamp":"t"}' > "$q"
    assert_contains "$(afd_queue_first_after "$q" 60)" '"@alpha a"' "peek: the first line newer than the question"
    assert_eq "" "$(afd_queue_first_after "$q" 71)" "peek: nothing newer"
    afd_queue_delete "$q" 70
    assert_file_not_contains "$q" '"@alpha a"' "delete by id removes only that line"
    assert_file_contains "$q" '"old"' "older lines stay in place (no take-and-requeue, CFG-781)"
    assert_file_contains "$q" '"@alpha b"' "newer lines stay too"
    assert_eq "2" "$(wc -l < "$q" | tr -d ' ')" "exactly one line gone"
}
run_test "queue: peek first-after-id and delete by id leave the rest in place" test_queue_peek_and_delete_by_id

test_pool_reject_and_redirect() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"
    printf '%s\n' '{"id":80,"message":"maybe","timestamp":"t","pooled":1}' '{"id":81,"message":"other","timestamp":"t","pooled":1}' > "$(POOL)"
    afd_pool_reject 80 institute
    assert_file_contains "$(POOL)" '"rejected": *\["institute"\]' "reject marks the line with the project that said n"
    afd_pool_reject 80 gamma
    assert_file_contains "$(POOL)" '"institute", *"gamma"' "a second rejection is appended"
    afd_pool_redirect 80 alpha
    assert_file_not_contains "$(POOL)" '"maybe"' "redirect removes the line from the pool"
    assert_file_contains "$(POOL)" '"other"' "the other pool line is untouched"
    assert_file_contains "$AFD_MSG_DIR/alpha.jsonl" '"maybe"' "and files it into the target's queue"
    assert_file_contains "$AFD_MSG_DIR/alpha.jsonl" '"redirected": *true' "flagged redirected, so the target skips its own ask-back"
    assert_file_not_contains "$AFD_MSG_DIR/alpha.jsonl" '"rejected"' "the rejections do not travel with it"
}
run_test "pool: reject marks, redirect re-files with the redirected flag" test_pool_reject_and_redirect

test_locked_ops_lose_nothing() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"
    local q="$AFD_MSG_DIR/alpha.jsonl" i n
    # Appends race deletes: 40 appends in one process while another deletes every even id.
    for i in $(seq 1 40); do printf '{"id":%s,"message":"m%s"}\n' "$i" "$i" >> "$q"; done
    ( for i in $(seq 41 80); do _afd_locked _afd_append_line "$q" "{\"id\":$i,\"message\":\"m$i\"}"; done ) &
    ( for i in $(seq 2 2 40); do afd_queue_delete "$q" "$i"; done ) &
    wait
    n=$(wc -l < "$q" | tr -d ' ')
    assert_eq "60" "$n" "40 appends and 20 deletes under the lock: 60 lines, none lost or duplicated (got $n)"
    for i in 1 39 41 80; do assert_file_contains "$q" "\"m$i\"" "line m$i present"; done
    assert_file_not_contains "$q" '"m40"' "deleted lines are gone"
}
run_test "lock: concurrent appends and deletes lose nothing" test_locked_ops_lose_nothing

test_lock_survives_killed_holder() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"
    local q="$AFD_MSG_DIR/alpha.jsonl"
    printf '%s\n' '{"id":1,"message":"keep"}' > "$q"
    # A real mid-hold kill: the holder owns the only descriptor on the lock (its sleep has fd 9
    # closed), so SIGKILL must free the lock at once — no fallback wait, no stale lock file.
    ( exec 9>>"$AFD_MSG_DIR/.lock"; flock 9; sleep 31.7 9>&- ) & local holder=$!
    sleep 0.3
    kill -9 "$holder"; wait "$holder" 2>/dev/null || true
    local t0=$SECONDS
    afd_queue_delete "$q" 999
    local took=$(( SECONDS - t0 ))
    assert_eq "0" "$(( took > 1 ))" "the lock is free the moment its holder dies (took ${took}s, no 3 s fallback)"
    assert_file_contains "$q" '"keep"' "the queue is intact after the kill (nothing was mid-flight outside the file)"
    assert_eq "" "$(ls "$AFD_MSG_DIR"/*.tmp "$AFD_MSG_DIR"/*.taking.* 2>/dev/null)" "no half-written temp file is left behind"
    pkill -f 'sleep 31.7' 2>/dev/null || true
}
run_test "lock: a killed holder releases the lock; the file is never outside itself" test_lock_survives_killed_holder

# ── Fable review 2026-10-25 (MERGE-AFTER-FIXES) ──────────────────────────────

# MAJOR 2: a wedged lock made _afd_locked skip the operation, and a server-consumed line
# (already acknowledged, never resent) vanished. Wait a little, then do it unlocked.
test_wedged_lock_never_drops_a_line() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"
    ( exec 9>>"$AFD_MSG_DIR/.lock"; flock 9; sleep 9.3 9>&- ) & local holder=$!
    sleep 0.3
    local t0=$SECONDS
    afd_pool_add '{"id":200,"message":"must not vanish"}'
    _afd_locked _afd_append_line "$AFD_MSG_DIR/alpha.jsonl" '{"id":201,"message":"@alpha must not vanish"}'
    local took=$(( SECONDS - t0 ))
    assert_file_contains "$(POOL)" '"must not vanish"' "a wedged lock never drops a pooled line: the add falls back to an unlocked append"
    assert_file_contains "$AFD_MSG_DIR/alpha.jsonl" '"@alpha must not vanish"' "same for a queue append"
    [[ $took -ge 2 && $took -le 7 ]] && r=0 || r=1
    assert_eq "0" "$r" "each op waits ~3 s for the lock, no more (both took ${took}s; the lock was held 9.3 s)"
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
    pkill -f 'sleep 9.3' 2>/dev/null || true
}
run_test "lock: a wedged lock delays an append by 3 s but never drops it" test_wedged_lock_never_drops_a_line

# Second review pass, A4: an append that fell back to unlocked (lock wedged > 3 s) landed in
# the file a slow rewriter had already parsed; its later os.replace dropped the line. The
# rewriter now re-appends whatever reached the old inode after it parsed.
test_slow_rewrite_keeps_a_fallback_append() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"
    local q="$AFD_MSG_DIR/alpha.jsonl"
    printf '%s\n' '{"id":1,"message":"keep"}' '{"id":2,"message":"drop me"}' > "$q"
    _AFD_REWRITE_DELAY=5 afd_queue_delete "$q" 2 & local rewriter=$!   # holds the lock ~5 s before replacing
    sleep 0.5
    _afd_locked _afd_append_line "$q" '{"id":3,"message":"appended during wedge"}'
    wait "$rewriter"
    assert_eq "2" "$(grep -c . "$q")" "the deleted line is gone and the fallback append survives (got: $(tr '\n' ' ' < "$q"))"
    assert_file_contains "$q" '"appended during wedge"' "the line appended while the rewrite stalled is still there"
    assert_file_not_contains "$q" '"drop me"' "and the delete happened"
}
run_test "lock: a rewrite that finishes after a fallback append keeps the appended line" test_slow_rewrite_keeps_a_fallback_append

# MINOR 4: the marker was rewritten with a truncating `echo >`, and a reader that caught it
# empty deleted it — a live relay demoted to non-waiter, the original bug. Markers are
# written via temp file + rename, and an empty marker is never deleted.
test_empty_marker_is_never_deleted() {
    setup_env
    mkdir -p "$AFD_MSG_DIR/.waiting"; : > "$AFD_MSG_DIR/.waiting/zeta"
    _afd_marker_live "$AFD_MSG_DIR/.waiting/zeta" && r=0 || r=1
    assert_eq "1" "$r" "an empty marker is not a live waiter"
    assert_file_exists "$AFD_MSG_DIR/.waiting/zeta" "but it is never deleted"
    afd_marker_write "$AFD_MSG_DIR/.waiting/alpha" "$$ 7 claimed 10 11"
    assert_eq "$$ 7 claimed 10 11" "$(cat "$AFD_MSG_DIR/.waiting/alpha")" "afd_marker_write writes the whole marker"
    assert_eq "alpha zeta" "$(ls "$AFD_MSG_DIR/.waiting" | tr '\n' ' ' | sed 's/ $//')" "through a temp file that is renamed away (none left)"
    afd_question_waiting alpha && r=0 || r=1
    assert_eq "0" "$r" "and the marker is live"
}
run_test "marker: written atomically; an empty marker is never deleted" test_empty_marker_is_never_deleted

# MINOR 8: the load guard was set before `source lib-afd-pool.sh || return 1`, so a failed
# first load poisoned every later one in the same shell.
test_lib_guard_set_only_after_pool_lib_loads() {
    setup_env
    local d="$TEST_TMPDIR/libs"; mkdir -p "$d"; cp "$LIB" "$d/"
    local out
    out=$(bash -c 'source "$1/lib-afd-msg.sh" 2>/dev/null; echo "rc=$? loaded=${_LIB_AFD_MSG_LOADED:-no}"; cp "$2" "$1/"; source "$1/lib-afd-msg.sh" && declare -F afd_claim >/dev/null && echo retry-ok' _ "$d" "$REPO_ROOT/global/hooks/lib-afd-pool.sh")
    assert_contains "$out" "rc=1 loaded=no" "a failed pool-lib source leaves the msg lib unloaded (out: $out)"
    assert_contains "$out" "retry-ok" "so the next source, pool lib present, loads everything"
}
run_test "lib: the load guard is set only once the pool lib loaded" test_lib_guard_set_only_after_pool_lib_loads

# MINOR 9: a pooled line every live waiter said n to waited until the last relay exited.
test_pool_line_rejected_by_all_waiters_goes_to_consumer() {
    setup_env
    mkdir -p "$AFD_MSG_DIR/.waiting"; echo "$$ 3" > "$AFD_MSG_DIR/.waiting/alpha"; echo "$$ 4" > "$AFD_MSG_DIR/.waiting/beta"
    printf '%s\n' '{"id":80,"message":"maybe","pooled":1,"rejected":["alpha","beta"]}' \
                  '{"id":81,"message":"still open","pooled":1,"rejected":["alpha"]}' > "$(POOL)"
    local got; got=$(afd_take_messages gamma)
    assert_contains "$got" '"maybe"' "a line every live waiter rejected reaches the consumer (got: $got)"
    assert_not_contains "$got" '"still open"' "a line some waiter has not judged does not"
    assert_file_contains "$(POOL)" '"still open"' "it stays pooled"
    assert_file_not_contains "$(POOL)" '"maybe"' "and the delivered line is gone from the pool"
}
run_test "pool: a line rejected by every live waiter goes to the consumer" test_pool_line_rejected_by_all_waiters_goes_to_consumer

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

# ── CFG-776: an idle session never drains its queue; another session must wake it ──
# 2026-10-19: MG's @aiware messages sat 10+ min in aiware.jsonl because aiware was
# idle and the session that routed them was blocked in an AFK wait loop.

queue_for() {  # queue_for <project> <age e.g. '-2 minutes'|now> <id>...
    local p="$1" age="$2"; shift 2
    mkdir -p "$AFD_MSG_DIR"
    for id in "$@"; do
        printf '{"id":%s,"message":"@%s hi","timestamp":"t","persona":"Bot"}\n' "$id" "$p" >> "$AFD_MSG_DIR/$p.jsonl"
    done
    [[ "$age" == now ]] || touch -d "$age" "$AFD_MSG_DIR/$p.jsonl"
}

test_wake_hint_names_stale_foreign_queue() {
    setup_env
    queue_for alpha '-2 minutes' 379 381
    local got; got=$(afd_wake_hint "config-repo" "sess-1")
    assert_contains "$got" "alpha" "the stale project is named (got: $got)"
    assert_contains "$got" "SendMessage" "the hint says how to wake it (got: $got)"
    assert_contains "$got" "379" "the waiting message ids are named (got: $got)"
}
run_test "wake hint: a foreign queue undelivered > threshold is named" test_wake_hint_names_stale_foreign_queue

test_wake_hint_silent_for_fresh_queue() {
    setup_env
    queue_for alpha now 5
    assert_eq "" "$(afd_wake_hint "config-repo" "sess-1")" "a just-filed message gets time to be picked up"
}
run_test "wake hint: silent for a queue younger than the threshold" test_wake_hint_silent_for_fresh_queue

test_wake_hint_ignores_own_queue() {
    setup_env
    queue_for config-repo '-2 minutes' 6
    assert_eq "" "$(afd_wake_hint "config-repo" "sess-1")" "a session is not told to wake itself"
}
run_test "wake hint: own queue is not reported" test_wake_hint_ignores_own_queue

test_wake_hint_once_per_session_per_message() {
    setup_env
    queue_for alpha '-2 minutes' 7
    afd_wake_hint "config-repo" "sess-1" >/dev/null
    assert_eq "" "$(afd_wake_hint "config-repo" "sess-1")" "the same session is told about a message once"
    assert_contains "$(afd_wake_hint "config-repo" "sess-2")" "alpha" "another session is still told"
    queue_for alpha '-2 minutes' 8
    assert_contains "$(afd_wake_hint "config-repo" "sess-1")" "8" "a NEW message is reported again"
}
run_test "wake hint: once per session per message, new messages re-hint" test_wake_hint_once_per_session_per_message

test_wake_hint_silent_without_queues() {
    setup_env
    assert_eq "" "$(afd_wake_hint "config-repo" "sess-1")" "no queues, no output"
}
run_test "wake hint: silent when nothing is queued" test_wake_hint_silent_without_queues

test_question_waiting() {
    setup_env
    afd_question_waiting alpha && r=0 || r=1
    assert_eq "1" "$r" "no marker: not waiting"
    mkdir -p "$AFD_MSG_DIR/.waiting"; echo "$$ 7" > "$AFD_MSG_DIR/.waiting/alpha"
    afd_question_waiting alpha && r=0 || r=1
    assert_eq "0" "$r" "marker of a live relay: waiting"
    afd_question_waiting beta && r=0 || r=1
    assert_eq "1" "$r" "another project's marker does not count"
    local dead; sleep 0 & dead=$!; wait "$dead"
    echo "$dead 7" > "$AFD_MSG_DIR/.waiting/alpha"
    afd_question_waiting alpha && r=0 || r=1
    assert_eq "1" "$r" "a dead relay's marker is a leftover"
    assert_file_not_exists "$AFD_MSG_DIR/.waiting/alpha" "and is removed where it is found"
    echo "7" > "$AFD_MSG_DIR/.waiting/alpha"
    afd_question_waiting alpha && r=0 || r=1
    assert_eq "1" "$r" "a marker without a pid is a leftover"
}
run_test "question waiting: only a live relay's marker counts" test_question_waiting

# 2026-10-20 user request: "I should not have to type the whole project name, just what the af
# matcher would also accept" — the question text suggests the shortest tag that routes.
test_short_name() {
    setup_env
    assert_eq "con" "$(afd_short_name config-repo)" "shortest unique prefix, at least 3 chars"
    assert_eq "gam" "$(afd_short_name gamma-radar)" "unique prefix"
    assert_eq "bet" "$(afd_short_name beta)" "3 chars is the floor"
    mkdir -p "$HOME/abc"
    assert_eq "abc" "$(afd_short_name abc)" "a 3-char name stays whole"
    mkdir -p "$HOME/conflux"
    assert_eq "confi" "$(afd_short_name config-repo)" "grows past a shared prefix (conflux)"
    assert_eq "config-repo" "$(_afd_resolve_target "$(afd_short_name config-repo)")" "the suggested tag routes back to the project"
}
run_test "short name: shortest prefix that still routes here" test_short_name


# Review finding (2026-10-20): a dead relay's marker kept attracting untagged replies.
test_single_waiter_ignores_dead_marker() {
    setup_env
    local dead; sleep 0 & dead=$!; wait "$dead"
    mkdir -p "$AFD_MSG_DIR/.waiting"; echo "$dead 3" > "$AFD_MSG_DIR/.waiting/alpha"
    pending '{"id":12,"message":"yes","timestamp":"t","persona":"Bot"}'
    afd_route_messages "config-repo" >/dev/null
    assert_contains "$(afd_take_messages "config-repo")" '"yes"' "a dead waiter does not receive untagged replies"
}
run_test "untagged reply skips a dead waiter" test_single_waiter_ignores_dead_marker

test_short_name_unroutable() {
    setup_env
    assert_eq "" "$(afd_short_name not-a-known-project)" "no tag that routes: empty"
}
run_test "short name: empty when the project does not route" test_short_name_unroutable

suite_summary
