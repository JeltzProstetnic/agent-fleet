#!/usr/bin/env bash
# Tests for global/hooks/inbox-watch.sh — CFG-775: a UserPromptSubmit hook that keeps
# naming this project's open inbox items every turn until they are dispatched.
# Incident 2026-10-19: a session told to wait for another project missed two inbox
# items for ~1.5 h while reporting "still waiting" — startup reads the inbox once,
# and nothing re-surfaced items filed afterwards.
source "$(dirname "$0")/test-helpers.sh"

HOOK="$REPO_ROOT/global/hooks/inbox-watch.sh"

suite_header "inbox-watch.sh (UserPromptSubmit inbox re-surfacing)"

# A throwaway config repo with COPIES of the inbox scripts, so items are filed with the
# real inbox-file.sh exactly as sessions file them.
setup_env() {
    CFG="$TEST_TMPDIR/cfg"
    rm -rf "$CFG"; mkdir -p "$CFG/setup/scripts" "$CFG/cross-project/inbox"
    cp "$REPO_ROOT/setup/scripts/inbox-file.sh" "$REPO_ROOT/setup/scripts/inbox-lib.sh" "$CFG/setup/scripts/"
    PROJ="$TEST_TMPDIR/work/alpha"; mkdir -p "$PROJ" "$TEST_TMPDIR/work/beta"
    export CONFIG_REPO="$CFG" INBOX_REPO="$CFG"
    HOOK_TMP="$TEST_TMPDIR/tmp"; mkdir -p "$HOOK_TMP"   # only the hook gets it as TMPDIR
}

file_item() { # file_item <project> <body>
    bash "$CFG/setup/scripts/inbox-file.sh" --project "$1" --type work --body "$2" >/dev/null 2>&1
}

# turn [session] [cwd] — feeds a real UserPromptSubmit payload; sets OUT.
turn() {
    local json
    json=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","session_id":sys.argv[1],"cwd":sys.argv[2],"prompt":"status?"}))' "${1:-s1}" "${2:-$PROJ}")
    OUT=$(printf '%s' "$json" | TMPDIR="$HOOK_TMP" bash "$HOOK" 2>&1)
}

test_no_items_silent() {
    setup_env
    turn
    assert_eq "" "$OUT" "no open items: nothing printed"
}
run_test "no open items: silent" test_no_items_silent

test_one_item_announced() {
    setup_env
    file_item alpha "first thing"
    turn
    assert_contains "$OUT" "INBOX_PENDING: 1 open item(s) for alpha (1 new since last turn)" "one new item (out: $OUT)"
    assert_contains "$OUT" "cross-project/inbox/alpha.md" "names the file to read"
    assert_contains "$OUT" "dispatch" "and what to do"
}
run_test "one item: N=1, M=1" test_one_item_announced

test_next_turn_not_new() {
    setup_env
    file_item alpha "first thing"
    turn; turn
    assert_contains "$OUT" "1 open item(s) for alpha (0 new since last turn)" "still pending, nothing new (out: $OUT)"
}
run_test "next turn: still announced, M=0" test_next_turn_not_new

test_new_item_counted() {
    setup_env
    file_item alpha "first thing"
    turn
    file_item alpha "second thing"
    turn
    assert_contains "$OUT" "2 open item(s) for alpha (1 new since last turn)" "a newly filed item is new (out: $OUT)"
}
run_test "new item: M=1" test_new_item_counted

test_replaced_item_is_new() {
    setup_env
    file_item alpha "first thing"
    turn
    sed -i '/first thing/d' "$CFG/cross-project/inbox/alpha.md"
    file_item alpha "replacement thing"
    turn
    assert_contains "$OUT" "1 open item(s) for alpha (1 new since last turn)" "delete + add counts as new (out: $OUT)"
}
run_test "delete + add counts as new" test_replaced_item_is_new

test_other_project_ignored() {
    setup_env
    file_item beta "not alpha's"
    turn
    assert_eq "" "$OUT" "another project's items are not announced here"
}
run_test "other project's items are ignored" test_other_project_ignored

test_sessions_separate() {
    setup_env
    file_item alpha "first thing"
    turn s1
    turn s2
    assert_contains "$OUT" "(1 new since last turn)" "a different session has its own seen-set (out: $OUT)"
}
run_test "seen-set is per session" test_sessions_separate

test_settings_registers_hook() {
    local got
    got=$(python3 -c "
import json
s = json.load(open('$REPO_ROOT/setup/config/settings.json'))
print(sum(1 for g in s['hooks'].get('UserPromptSubmit', []) for h in g['hooks'] if 'safe-run.sh inbox-watch.sh' in h.get('command','')))")
    assert_eq "1" "$got" "registered once as a UserPromptSubmit hook via safe-run"
}
run_test "settings: registered via safe-run" test_settings_registers_hook

suite_summary
