#!/usr/bin/env bash
# Tests for setup/scripts/remote-session-gate-lib.sh — the typing gate (CFG-1028): keystrokes go into a Claude
# Code session only (a) during an ACTIVE care shift, typed by the caretaker, or (b) on the user's explicit order,
# passed as `--ordered "<the user's words>"`; a session typing into ITSELF is not gated (Q-TYPE-SELF); `start`
# outside care opens the session and types nothing. Where the care machinery (lib-care.sh) exists, every care line
# a case reads was written by its own writer into this test's sandboxed HOME (Pattern 11) — never a hand-written
# string, never the live ~/.afd-care. Where it does not exist — the public template ships the gate without it — the
# documented line is written as such, and the gate's own fallback reader is what is under test.
# Layer A only (fixture /proc, typing stubbed): no real Claude Code session, no root, nothing typed anywhere.
# Fixtures (a_*, r_*, n_*): lib-remote-session-fixture.sh; R_GATE=1 keeps r_run's default `--ordered` off. The
# cases that drive remote-session.sh, remote-exit.sh or swap.sh (not part of every deployment) skip where the
# script is absent (n_run_if).
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/lib-remote-session-fixture.sh"

CARE_LIB="$REPO_ROOT/global/hooks/lib-care.sh"   # the care machinery; absent downstream
SWAP="$REPO_ROOT/setup/scripts/swap.sh"
HINT="(care shift or the user's explicit order only)"
ORDERED_HINT="--ordered \"<the user's words>\""

suite_header "remote-session typing gate (CFG-1028: care shift or the user's explicit order only)"

# g_care <state> <caretaker pid> — a care line in this test's HOME: through lib-care.sh's own writer (care_write)
# where the lib exists (Pattern 11); else the documented line "<state> <epoch> <pid> <project> <sid> <threshold>",
# which is then exactly what the gate's own fallback reader parses
g_care() {
    if [[ -f "$CARE_LIB" ]]; then ( source "$CARE_LIB" && care_paths && care_write "$1" "$(date +%s)" "$2" proj-c sid-c 80 )
    else printf '%s %s %s proj-c sid-c 80\n' "$1" "$(date +%s)" "$2" > "${CARE_FILE:-$HOME/.afd-care}"; fi
}
# g_care_off — `care off` from Telegram through lib-care.sh: the state file goes, the caretaker's tombstone stays
g_care_off() { ( CARE_CLAUDE_PID=999999999 source "$CARE_LIB" && care_disarm telegram >/dev/null ); }
g_log() { cat "$HOME/.claude/logs/remote-session.log" 2>/dev/null; }
g_sleeper() { sleep 300 >/dev/null 2>&1 & APIDS+=("$!"); echo "$!"; }   # a live pid (the caretaker named in the care line)
g_registry() { ST_DIR="$TEST_TMPDIR/alpha"; mkdir -p "$ST_DIR"; printf '| alpha | P2 | — | `%s` |\n' "$ST_DIR" >> "$RS_REGISTRY"; }

# ── the gate itself (sourced lib) ─────────────────────────────────────────────
test_gate_outside_care_refused_and_logged() {
    a_setup; local rc
    rs_typing_allowed "pid 4242" 0 "" ""; rc=$?
    assert_eq 3 "$rc" "no care state, no order → 3"
    assert_contains "$RS_REASON" "no care shift is active" "the reason says why"
    assert_contains "$RS_REASON" "$ORDERED_HINT" "and names --ordered as the way for an order the user gave"
    assert_contains "$RS_REASON" "nothing typed" "and says nothing was typed"
    assert_contains "$(g_log)" "refused" "the refusal is logged ($(g_log))"
    rs_typing_allowed "pid 4242" 0 "   " ""; rc=$?
    assert_eq 3 "$rc" "blank words are not an order"
    a_teardown
}
run_test "gate: outside care, no order → refused (exit 3), reason names --ordered, logged" test_gate_outside_care_refused_and_logged

test_gate_ordered_allowed_and_logged() {
    a_setup; local rc
    RS_GATE_WHAT=send rs_typing_allowed "pid 4242" 0 "tell alpha: restart" ""; rc=$?
    assert_eq 0 "$rc" "the user's words let the typing through (reason: ${RS_REASON:-none})"
    assert_contains "$(g_log)" "gate passed send" "the override is logged with the action (passed, not typed: F6)"
    assert_contains "$(g_log)" "by=ordered" "as an order"
    assert_contains "$(g_log)" "tell alpha: restart" "with the user's words"
    a_teardown
}
run_test "gate: --ordered words → allowed, the words logged" test_gate_ordered_allowed_and_logged

test_gate_care_states() {
    a_setup; local ct other dead rc
    ct=$(g_sleeper); other=$(g_sleeper); dead=$(g_sleeper); kill "$dead"; wait "$dead" 2>/dev/null || true
    g_care active "$ct"; assert_file_exists "$HOME/.afd-care" "the care line is in the sandboxed HOME"
    echo "  measured care line: $(cat "$HOME/.afd-care")"
    rs_typing_allowed "pid 4242" "$ct" "" ""; rc=$?
    assert_eq 0 "$rc" "care active + the caller IS the caretaker (field 3) → allowed (${RS_REASON:-ok})"
    assert_contains "$(g_log)" "by=caretaker" "logged as the caretaker's typing"
    rs_typing_allowed "pid 4242" 0 "" "$ct"; rc=$?
    assert_eq 0 "$rc" "care active + no claude above the caller, but the caretaker marker = field 3 → allowed (a care job under tmux-launch)"
    rs_typing_allowed "pid 4242" "$other" "" ""; rc=$?
    assert_eq 3 "$rc" "care active + another session typing → refused (Q-TYPE-CALLER)"
    assert_contains "$RS_REASON" "not the caretaker" "the reason names the caretaker rule"
    rs_typing_allowed "pid 4242" 0 "" "$other"; rc=$?
    assert_eq 3 "$rc" "a marker that is not field 3 is no caretaker"
    g_care active "$dead"
    rs_typing_allowed "pid 4242" "$dead" "" ""; rc=$?
    assert_eq 3 "$rc" "care active but its caretaker pid is dead → no shift, refused"
    assert_contains "$RS_REASON" "gone" "the reason says the caretaker is gone"
    g_care armed "$ct"
    rs_typing_allowed "pid 4242" "$ct" "" "$ct"; rc=$?
    assert_eq 3 "$rc" "armed is not active: refused even for the caretaker"
    assert_contains "$RS_REASON" "armed" "the reason names the state"
    a_teardown
}
run_test "gate: care active → the caretaker (caller or marker) types, nobody else; dead caretaker or armed → refused" test_gate_care_states

test_gate_after_care_off_refused() {   # conflict 9: §Stop's "caretaking ended" goes by SendMessage — no tombstone window
    a_setup; local ct rc; ct=$(g_sleeper)
    g_care active "$ct"; g_care_off
    assert_file_not_exists "$HOME/.afd-care" "care off removed the state"
    assert_file_exists "$HOME/.afd-care.off.$ct" "and left the caretaker's tombstone (a Telegram care off)"
    rs_typing_allowed "pid 4242" "$ct" "" "$ct"; rc=$?
    assert_eq 3 "$rc" "after care off the former caretaker is refused too: the shift is over (§Stop sends its line by SendMessage)"
    assert_contains "$RS_REASON" "no care shift is active" "the reason: no shift"
    a_teardown
}
n_run_if "gate: after care off (tombstone present) typing is refused — the §Stop line goes by SendMessage" test_gate_after_care_off_refused "$CARE_LIB"

# Without the care machinery (the public template: no lib-care.sh in the repo, none deployed) the gate reads the
# care line by itself — first word the state, third the caretaker pid — and judges it exactly as with the lib.
test_gate_without_care_lib_reads_the_line_itself() {
    a_setup; n_stage_layer; local ct other rc f
    ct=$(g_sleeper); other=$(g_sleeper)
    # an earlier case's rs_care_read sourced the repo's lib-care.sh into this shell: drop its functions, as a
    # shell on a fleet without the lib never had them
    for f in $(declare -F | awk '$3 ~ /^care_/ {print $3}'); do unset -f "$f"; done
    # RS_LIB_DIR becomes the staged dir, where "$RS_LIB_DIR/../../global/hooks/" holds no care lib
    source "$N_LIB"
    assert_file_not_exists "$TEST_TMPDIR/nolib/global/hooks/lib-care.sh" "no care lib beside the staged libs"
    assert_file_not_exists "$HOME/.claude/hooks/lib-care.sh" "and none deployed in this HOME"
    assert_eq "" "$(declare -F care_read)" "lib-care.sh's reader is not defined in this shell"
    rs_typing_allowed "pid 4242" "$ct" "" ""; rc=$?
    assert_eq 3 "$rc" "no care line → refused (${RS_REASON:-?})"
    printf 'active %s %s proj-c sid-c 80\n' "$(date +%s)" "$ct" > "$HOME/.afd-care"
    rs_typing_allowed "pid 4242" "$ct" "" ""; rc=$?
    assert_eq 0 "$rc" "active, caller = field 3 → allowed by the fallback reader (${RS_REASON:-ok})"
    assert_eq "active $ct" "$RS_CARE_STATE $RS_CARE_OWNER" "state and owner read from the line itself"
    rs_typing_allowed "pid 4242" "$other" "" ""; rc=$?
    assert_eq 3 "$rc" "active, another caller → refused"; assert_contains "$RS_REASON" "not the caretaker" "with the caretaker rule"
    printf 'armed %s %s proj-c sid-c 80\n' "$(date +%s)" "$ct" > "$HOME/.afd-care"
    rs_typing_allowed "pid 4242" "$ct" "" ""; rc=$?
    assert_eq 3 "$rc" "armed → refused"; assert_contains "$RS_REASON" "armed" "the reason names the state"
    printf 'nonsense\n' > "$HOME/.afd-care"
    rs_typing_allowed "pid 4242" "$ct" "" ""; rc=$?
    assert_eq 3 "$rc" "a malformed line is no shift"; assert_contains "$RS_REASON" "no care shift is active" "read as off"
    rm -f "$HOME/.afd-care"
    rs_typing_allowed "pid 4242" "$ct" "tell alpha hi" ""; rc=$?
    assert_eq 0 "$rc" "and the user's words pass as everywhere (${RS_REASON:-ok})"
    a_teardown
}
run_test "gate without lib-care.sh (the public template): the care line is read by the gate itself, same verdicts" test_gate_without_care_lib_reads_the_line_itself

test_safety_check_self_exempt() {   # Q-TYPE-SELF: shutdown-follow.sh and --self call rs_safety_check with caller == pid
    a_setup; local p q rc
    p=$(a_spawn claude /dev/pts/40 /home/user/x claude); q=$(a_spawn claude /dev/pts/41 /home/user/y claude)
    rs_safety_check "$p" "$p" 1; rc=$?
    assert_eq 0 "$rc" "a session typing into itself passes with no care and no order (${RS_REASON:-ok})"
    assert_eq "" "$(g_log)" "and the gate logs nothing for it"
    rs_safety_check "$p" "$p" 0; rc=$?
    assert_eq 3 "$rc" "without --self the calling session is still refused"; assert_contains "$RS_REASON" "pass --self" "with the old reason"
    rs_safety_check "$p" "$q" 0; rc=$?
    assert_eq 3 "$rc" "another session outside care → the gate refuses"; assert_contains "$RS_REASON" "$ORDERED_HINT" "naming --ordered"
    rs_safety_check "$p" "$q" 0 "user: end alpha" ""; rc=$?
    assert_eq 0 "$rc" "the same with the user's words → passes (${RS_REASON:-ok})"
    a_teardown
}
run_test "safety check: caller == target is exempt (Q-TYPE-SELF); another target is gated; --ordered passes it" test_safety_check_self_exempt

# ── the script: every typing action ───────────────────────────────────────────
test_actions_refused_outside_care() {
    r_setup; local old out rc a n; old=$(r_old)
    for a in "send hi" exit end-exit cls-restart relaunch; do
        out=$(R_GATE=1 R_SPAWN=1 r_run "$old" $a --start-wait 1 --max-wait 1 --end-wait 1 2>&1); rc=$?
        assert_eq 3 "$rc" "$a outside care → exit 3: $out"
        assert_contains "$out" "$ORDERED_HINT" "$a: the refusal names --ordered"
        assert_contains "$out" "nothing typed" "$a: and says nothing was typed"
    done
    assert_eq "" "$(cat "$R_TYPED")" "no key reached pid $old in any of the five"
    assert_file_not_exists "$R_CLEARED" "not even its input line was cleared"
    assert_file_not_exists "$R_LOG" "relaunch opened no terminal"
    n=$(g_log | grep -c ' refused '); assert_eq 5 "$n" "every refusal is logged (measured $n lines)"
    assert_success kill -0 "$old"
    r_teardown "$old"
}
n_run_if "script: send / exit / end-exit / cls-restart / relaunch outside care → exit 3 before anything is typed, each logged" test_actions_refused_outside_care "$RS"

test_script_ordered_allows() {
    r_setup; local old out rc; old=$(r_old)
    out=$(R_GATE=1 r_run "$old" send hi --ordered "tell alpha hi" 2>&1); rc=$?
    assert_eq 0 "$rc" "send with --ordered goes through: $out"
    assert_eq "$old hi" "$(cat "$R_SUBMITTED" 2>/dev/null)" "the line was submitted"
    assert_contains "$(g_log)" "gate passed send" "logged with the action"; assert_contains "$(g_log)" "tell alpha hi" "and the user's words"
    out=$(R_GATE=1 r_run "$old" send hi --ordered "  " 2>&1); rc=$?
    assert_eq 2 "$rc" "--ordered without words is a usage error, not an order: $out"
    out=$(R_GATE=1 r_run "$old" send hi --ordered 2>&1); rc=$?
    assert_eq 2 "$rc" "--ordered with no value → exit 2: $out"
    out=$(R_GATE=1 r_run "$old" send hi --caretaker abc 2>&1); rc=$?
    assert_eq 2 "$rc" "--caretaker needs a pid: $out"
    assert_eq "$old hi" "$(cat "$R_SUBMITTED")" "the usage errors typed nothing more"
    r_teardown "$old"
}
n_run_if "script: --ordered \"<words>\" lets the action through and is logged; empty words / bad --caretaker are usage errors" test_script_ordered_allows "$RS"

test_script_caretaker() {
    r_setup; local old ct other out rc; old=$(r_old); ct=$(g_sleeper); other=$(g_sleeper); g_care active "$ct"
    out=$(R_GATE=1 r_run "$old" send RESTART --caretaker "$ct" 2>&1); rc=$?
    assert_eq 0 "$rc" "the caretaker's job (marker = field 3) types during the shift: $out"
    assert_eq "$old RESTART" "$(cat "$R_SUBMITTED" 2>/dev/null)" "the line was submitted"
    assert_contains "$(g_log)" "by=caretaker" "logged as the caretaker's"
    out=$(R_GATE=1 r_run "$old" send hi --caretaker "$other" 2>&1); rc=$?
    assert_eq 3 "$rc" "another session during the shift → refused: $out"
    assert_contains "$out" "not the caretaker" "with the caretaker rule"
    out=$(R_GATE=1 r_run "$old" send hi 2>&1); rc=$?
    assert_eq 3 "$rc" "no claude above the caller and no marker → refused: $out"
    assert_eq "$old RESTART" "$(cat "$R_SUBMITTED")" "nothing else was submitted"
    r_teardown "$old"
}
n_run_if "script: during the shift the caretaker's marker types; another session or no marker is refused" test_script_caretaker "$RS"

test_script_caller_is_caretaker() {   # the caretaker session runs the script itself: its claude ancestor IS field 3
    r_setup; local old ct out rc; old=$(r_old)
    ct=$(a_spawn claude /dev/pts/42 /home/user/proj-c claude); g_care active "$ct"
    out=$(R_GATE=1 R_START_PID="$ct" r_run "$old" send RESTART 2>&1); rc=$?
    assert_eq 0 "$rc" "the caretaker's own shell needs no marker: $out"
    assert_eq "$old RESTART" "$(cat "$R_SUBMITTED" 2>/dev/null)" "the line was submitted"
    out=$(R_GATE=1 R_START_PID="$ct" R_CLEAR_REC="$CC/sessions/$old.json" r_run "$old" cls-restart --end-wait 3 2>&1); rc=$?
    assert_eq 0 "$rc" "and cls-restart, the caretaker's restart, runs: $out"
    assert_eq "$old RESTART|$old cls|$old /clear|$old startup" "$(paste -sd'|' "$R_TYPED")" "after the RESTART: cls, /clear, startup"
    r_teardown "$old"
}
n_run_if "script: the caretaker session itself (claude ancestor = field 3) types without a marker" test_script_caller_is_caretaker "$RS"

test_script_care_ended_or_dead() {
    r_setup; local old ct dead out rc; old=$(r_old); ct=$(g_sleeper); dead=$(g_sleeper); kill "$dead"; wait "$dead" 2>/dev/null || true
    g_care active "$dead"
    out=$(R_GATE=1 r_run "$old" send hi --caretaker "$dead" 2>&1); rc=$?
    assert_eq 3 "$rc" "a dead caretaker pid in the care line is no shift: $out"
    g_care active "$ct"; g_care_off
    out=$(R_GATE=1 r_run "$old" send "caretaking ended" --caretaker "$ct" 2>&1); rc=$?
    assert_eq 3 "$rc" "after care off (tombstone up) the former caretaker is refused — §Stop sends that line by SendMessage: $out"
    assert_eq "" "$(cat "$R_TYPED")" "nothing typed in either case"
    r_teardown "$old"
}
n_run_if "script: dead caretaker pid, or care off with the tombstone up → refused, nothing typed" test_script_care_ended_or_dead "$RS" "$CARE_LIB"

# ── start ─────────────────────────────────────────────────────────────────────
test_start_outside_care_types_nothing() {
    r_setup; g_registry; local out rc
    out=$(R_GATE=1 R_SPAWN=1 r_run start alpha --start-wait 10 2>&1); rc=$?
    assert_eq 0 "$rc" "start outside care completes: $out"
    assert_contains "$out" "started, nothing submitted (not caretaking)" "and says so"
    assert_eq "$ST_DIR|af --hotswap alpha" "$(cat "$R_LOG")" "the session was opened"
    assert_file_not_exists "$R_SUBMITTED" "nothing submitted"
    assert_eq "" "$(cat "$R_TYPED")" "nothing typed"; assert_file_not_exists "$R_CLEARED" "its input line untouched"
    r_teardown; r_setup; g_registry   # with the user's order but no --then: "start a session" never includes a first line
    out=$(R_GATE=1 R_SPAWN=1 r_run start alpha --ordered "start alpha" --start-wait 10 2>&1); rc=$?
    assert_eq 0 "$rc" "start --ordered without --then completes: $out"
    assert_contains "$out" "nothing submitted" "and still types nothing"
    assert_file_not_exists "$R_SUBMITTED" "nothing submitted"
    r_teardown
}
n_run_if "start outside care: opens the session, types NOTHING, reports 'started, nothing submitted (not caretaking)' (exit 0)" test_start_outside_care_types_nothing "$RS"

test_start_then_outside_care() {
    r_setup; g_registry; local out rc new
    out=$(R_GATE=1 R_SPAWN=1 r_run start alpha --then "do X" --start-wait 10 2>&1); rc=$?
    assert_eq 3 "$rc" "start --then outside care → exit 3: $out"
    assert_contains "$out" "$ORDERED_HINT" "the refusal names --ordered"
    assert_contains "$out" "nothing launched" "and nothing was launched"
    assert_file_not_exists "$R_LOG" "no terminal opened (refused BEFORE the launch)"
    out=$(R_GATE=1 R_SPAWN=1 r_run start alpha --then "do X" --ordered "start alpha and tell it: do X" --start-wait 10 2>&1); rc=$?
    new=$(cat "$R_NEW" 2>/dev/null)
    assert_eq 0 "$rc" "with the user's words the line goes in: $out"
    assert_eq "$new do X" "$(cat "$R_SUBMITTED" 2>/dev/null)" "the --then line was submitted into the new pid"
    r_teardown
}
n_run_if "start --then outside care: refused before launching unless --ordered" test_start_then_outside_care "$RS"

test_start_during_care() {
    r_setup; g_registry; local ct other out rc new; ct=$(g_sleeper); other=$(g_sleeper); g_care active "$ct"
    out=$(R_GATE=1 R_SPAWN=1 r_run start alpha --caretaker "$ct" --start-wait 10 2>&1); rc=$?
    new=$(cat "$R_NEW" 2>/dev/null)
    assert_eq 0 "$rc" "the caretaker's start completes: $out"
    assert_eq "$new startup" "$(cat "$R_SUBMITTED" 2>/dev/null)" "during the shift the default line startup is submitted (unchanged)"
    r_teardown; r_setup; g_registry; g_care active "$ct"
    out=$(R_GATE=1 R_SPAWN=1 r_run start alpha --caretaker "$other" --start-wait 10 2>&1); rc=$?
    assert_eq 0 "$rc" "another session's start during the shift completes: $out"
    assert_contains "$out" "nothing submitted" "but types nothing: it is not the caretaker"
    assert_file_not_exists "$R_SUBMITTED" "nothing submitted"
    r_teardown
}
n_run_if "start during care: the caretaker gets the default startup; another session opens the tab and types nothing" test_start_during_care "$RS"

test_start_dry_run_outside_care() {
    r_setup; g_registry; local out rc
    out=$(R_GATE=1 r_run start alpha --dry-run 2>&1); rc=$?
    assert_eq 0 "$rc" "dry-run outside care: $out"
    assert_contains "$out" "type nothing" "the plan says nothing would be typed"
    assert_not_contains "$out" "startup" "and names no startup"
    r_teardown
}
n_run_if "start --dry-run outside care: the plan says nothing would be typed" test_start_dry_run_outside_care "$RS"

# ── CFG-1083 F1: the key primitives type into no pid the gate was not passed for ─────────────────
test_primitives_need_the_gate() {
    a_setup; local p q f rc stub="$TEST_TMPDIR/rootstub"; a_root_stub "$stub"; export RS_WSL=1 RS_INJECT="$stub"
    p=$(a_spawn claude /dev/pts/40 /home/user/x claude); q=$(a_spawn claude /dev/pts/41 /home/user/y claude)
    for f in "rs_type_text $p hi" "rs_press_enter $p" "rs_clear_input $p" "rs_type_line $p hi" "rs_inject_wsl $p hi"; do
        RS_REASON=""; $f >/dev/null 2>&1; rc=$?
        assert_eq 3 "$rc" "$f with no gate passed → rc 3"
        assert_contains "$RS_REASON" "no gate passed for pid $p" "$f: the reason says so"
    done
    assert_file_not_exists "$stub.calls" "the injector was never called"
    assert_eq 5 "$(g_log | grep -c 'refused key')" "each refused key is logged (measured $(g_log | grep -c 'refused key'))"
    rs_safety_check "$q" "$q" 1; assert_eq "$q" "$RS_GATE_OK" "rs_safety_check (self branch) records the pid it passed for"
    RS_REASON=""; rs_type_text "$p" hi >/dev/null 2>&1; rc=$?
    assert_eq 3 "$rc" "a gate passed for pid $q opens nothing for pid $p"; assert_contains "$RS_REASON" "passed for pid $q" "the reason names that pid"
    rs_safety_check "$p" "$q" 0 "user: tell x hi"; rc=$?
    assert_eq 0 "$rc" "the gated branch passes with the user's words (${RS_REASON:-ok})"; assert_eq "$p" "$RS_GATE_OK" "and records pid $p"
    rs_type_text "$p" hi >/dev/null 2>&1; rc=$?
    assert_eq 0 "$rc" "now the text goes in (${RS_REASON:-ok})"
    assert_file_contains "$stub.calls" "--expect-pid $p /dev/pts/40 hi --no-cr" "into pid $p's own pts"
    rs_safety_check "$p" "$q" 0; rc=$?
    assert_eq 3 "$rc" "the same without the words is refused"; assert_eq "" "$RS_GATE_OK" "and a refusal clears the pass"
    rs_press_enter "$p" >/dev/null 2>&1; rc=$?; assert_eq 3 "$rc" "so the keys are refused again"
    unset RS_WSL RS_INJECT; a_teardown
}
run_test "F1: rs_type_text / rs_press_enter / rs_clear_input / rs_type_line / rs_inject_wsl refuse (rc 3, logged) any pid rs_safety_check did not pass for" test_primitives_need_the_gate

# ── CFG-1083 F5 / F6 / F7: the reasons and the log ────────────────────────────
test_gate_care_line_without_pid() {
    a_setup; g_care active -; local rc
    rs_typing_allowed "pid 4242" 0 "" ""; rc=$?
    assert_eq 3 "$rc" "active with no caretaker pid ('-') → refused"
    assert_contains "$RS_REASON" "names no caretaker pid" "the reason: the care line names no caretaker pid (F5)"
    assert_not_contains "$RS_REASON" "pid - is gone" "not 'pid - is gone'"
    a_teardown
}
run_test "F5: a care line whose owner is '-' is reported as naming no caretaker pid" test_gate_care_line_without_pid

test_gate_log_wording_and_sanitising() {
    a_setup; local rc
    rs_typing_allowed "pid 4242" 0 $'tell alpha hi\n2026-01-01T00:00:00 gate refused FORGED' ""; rc=$?
    assert_eq 0 "$rc" "words with a newline are still an order"
    assert_eq 1 "$(g_log | grep -c .)" "ONE log line (measured $(g_log | grep -c .)): a newline in the words forges no second entry (F7)"
    assert_contains "$(g_log)" "gate passed typing" "the line says the gate was PASSED, not that anything was typed (F6)"
    assert_contains "$(g_log)" "hi 2026-01-01T00:00:00 gate refused FORGED" "the newline became a space inside the words"
    assert_not_contains "$(g_log)" "allowed" "'allowed' is gone from the log"
    a_teardown
}
run_test "F6/F7: the log says 'gate passed'; control characters in the words are spaces, one line per decision" test_gate_log_wording_and_sanitising

test_remote_exit_usage_names_gate_options() {   # F4: the hint a caretaker's tmux job follows must carry the options it needs
    local out rc; out=$(bash "$EXIT_SH" 2>&1); rc=$?
    assert_eq 2 "$rc" "no target → usage, exit 2"
    assert_contains "$out" "--ordered" "remote-exit.sh usage names --ordered"; assert_contains "$out" "--caretaker" "and --caretaker"
}
n_run_if "F4: remote-exit.sh usage names --ordered and --caretaker" test_remote_exit_usage_names_gate_options "$EXIT_SH"

# ── the hints a reader acts on (conflict 4) ──────────────────────────────────
test_hints_carry_the_scope() {
    local out
    out=$(bash "$RS" --help 2>&1)
    assert_contains "$out" "$HINT" "remote-session.sh --help: the send hint carries the scope"
    assert_contains "$out" "--ordered" "and documents --ordered"; assert_contains "$out" "--caretaker" "and --caretaker"
    out=$(bash "$SWAP" --help 2>&1)
    assert_contains "$out" "$HINT" "swap --help: the relaunch hint carries the scope"
}
n_run_if "hints: remote-session.sh and swap.sh tell the reader the scope of typing" test_hints_carry_the_scope "$RS" "$SWAP"

suite_summary
