#!/usr/bin/env bash
# Tests for setup/scripts/remote-session-submit-lib.sh (CFG-1006, review round 2): what a submission
# leaves in the target session's INPUT BOX. Whatever sits there when Enter lands goes out WITH the
# order as one merged prompt — and runs. So the input line is cleared (Ctrl+K, then Ctrl+U) before
# typing and again whenever we give up, and a merged prompt is reported as such, never as "retry".
#   A. fixture /proc + fake transcripts, keystrokes stubbed (s_* in lib-remote-session-fixture.sh)
#   B. the tmux and Konsole key paths, with fake tmux / qdbus binaries on PATH
#   C. tty-inject.py --clear parse refusals (no device)
#   D. REAL ptys: a fake claude whose input box Ctrl+U empties, typed into by the root injector.
#      SKIPPED with the reason where no root path exists.
# No real Claude Code session is ever touched.
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/lib-remote-session-fixture.sh"

suite_header "remote-session submit lib: the input box (CFG-1006)"

# ── A. rs_prompt_state: submitted / queued / merged / none ────────────────────
test_prompt_state_words() {
    a_setup; local d="$TEST_TMPDIR"
    t_user "$d/s.jsonl" "hello there"
    assert_eq submitted "$(rs_prompt_state "$d/s.jsonl" 0 "hello there")" "a prompt that IS the text → submitted"
    t_queued "$d/q.jsonl" "hello there"
    assert_eq queued "$(rs_prompt_state "$d/q.jsonl" 0 "hello there")" "an enqueue of it, not pulled back → queued"
    t_user "$d/m.jsonl" "a stale drafthello there"
    assert_eq merged "$(rs_prompt_state "$d/m.jsonl" 0 "hello there")" "the box's old text + ours in one prompt → merged"
    t_user "$d/n.jsonl" "hello therea stale draft"
    assert_eq merged "$(rs_prompt_state "$d/n.jsonl" 0 "hello there")" "ours + text after the cursor → merged"
    t_queued "$d/mq.jsonl" "a stale drafthello there"
    assert_eq merged "$(rs_prompt_state "$d/mq.jsonl" 0 "hello there")" "merged in a busy session's queue → merged"
    t_user "$d/o.jsonl" "something else"
    assert_eq none "$(rs_prompt_state "$d/o.jsonl" 0 "hello there")" "an unrelated prompt → none"
    assert_eq none "$(rs_prompt_state "$d/missing.jsonl" 0 "hello there")" "no transcript → none"
    t_user "$d/x.jsonl" "a stale drafthello there"; t_user "$d/x.jsonl" "hello there"
    assert_eq submitted "$(rs_prompt_state "$d/x.jsonl" 0 "hello there")" "an exact prompt wins over a merged one"
    a_teardown
}
run_test "prompt state: submitted, queued, merged (the text inside a longer line) or none" test_prompt_state_words

# A multi-line draft (Shift+Enter) the clear did not fully remove puts other LINES around ours. Only
# queued prompts are legitimately sent together, and each of those is confirmed by its own enqueue.
test_prompt_state_draft_lines_are_merged() {
    a_setup; local d="$TEST_TMPDIR"
    t_user "$d/a.jsonl" $'hello there\ne'
    assert_eq merged "$(rs_prompt_state "$d/a.jsonl" 0 "hello there")" "a draft line left after ours, no enqueue → merged, never submitted"
    t_user "$d/b.jsonl" $'x\nhello there'
    assert_eq merged "$(rs_prompt_state "$d/b.jsonl" 0 "hello there")" "a draft line left before ours → merged, not none"
    t_queued "$d/c.jsonl" $'hello there\ne'
    assert_eq merged "$(rs_prompt_state "$d/c.jsonl" 0 "hello there")" "a busy session's enqueue of ours plus a draft line → merged"
    t_queued "$d/q.jsonl" "other order"; t_queued "$d/q.jsonl" "hello there"; t_user "$d/q.jsonl" $'other order\nhello there'
    assert_eq submitted "$(rs_prompt_state "$d/q.jsonl" 0 "hello there")" "ours enqueued, then sent merged with another queued prompt → submitted"
    a_teardown
}
run_test "prompt state: our text on one line among others is merged, unless its own enqueue confirms it" test_prompt_state_draft_lines_are_merged

# ── A. rs_submit_line: the input box before typing and after giving up ────────
test_submit_preclear_failure_types_nothing() {
    s_setup
    local r; r=$(S_ON=1 S_CLEAR_FAIL_ON=1 s_submit "startup")
    assert_eq "3 0" "$r" "the input line cannot be cleared → rc 3"
    assert_eq "clear" "$(s_keys)" "no text typed onto whatever may sit in the box"
    assert_file_contains "$TEST_TMPDIR/err" "nothing typed" "the reason says nothing was typed"
    s_teardown
}
run_test "submit: an input line that cannot be cleared first → rc 3, the text never typed" test_submit_preclear_failure_types_nothing

test_submit_merged_is_reported_not_retried() {
    s_setup
    local r; r=$(S_ON=1 S_MERGE="a stale draft " s_submit "hello there")
    assert_eq "4 1" "$r" "a merged prompt → rc 4 after the ONE Enter that sent it"
    assert_eq "clear|text:hello there|enter|clear" "$(s_keys)" "no further Enter; the line is cleared once more"
    assert_eq merged "$(cat "$TEST_TMPDIR/state")" "RS_SUBMIT_STATE says merged"
    assert_file_contains "$TEST_TMPDIR/err" "MERGED" "the reason says merged"
    assert_file_contains "$TEST_TMPDIR/err" "has run" "and that the merged prompt has run (or is queued)"
    assert_file_contains "$TEST_TMPDIR/err" "transcript" "and to read the target's transcript first"
    assert_file_not_contains "$TEST_TMPDIR/err" "may still sit" "never an invitation to retry"
    s_teardown
}
run_test "submit: an order merged with old box text → rc 4 'MERGED … has run', no more Enters" test_submit_merged_is_reported_not_retried

test_submit_queued_state() {
    s_setup
    local r; r=$(S_ON=1 S_QUEUE=1 s_submit "hello there")
    assert_eq "0 1" "$r" "an enqueue of the text → rc 0 after one Enter"
    assert_eq queued "$(cat "$TEST_TMPDIR/state")" "RS_SUBMIT_STATE says queued, not submitted"
    s_teardown; s_setup
    r=$(S_ON=1 s_submit "hello there")
    assert_eq submitted "$(cat "$TEST_TMPDIR/state")" "a user prompt → RS_SUBMIT_STATE submitted"
    s_teardown
}
run_test "submit: a busy session's enqueue is state 'queued', a user prompt 'submitted'" test_submit_queued_state

test_submit_late_enter_counts() {
    s_setup; : > "$S_TR"   # a session WITH a transcript (one without gets no retry and no clear: CFG-1043, below)
    local r; r=$(S_ON=0 S_LATE_ON_CLEAR=2 s_submit "hello there")
    assert_eq "0 3" "$r" "the prompt landed while we gave up → the final transcript read confirms it, rc 0"
    assert_eq "clear|text:hello there|enter|enter|enter|clear" "$(s_keys)" "the give-up clear ran first"
    assert_eq submitted "$(cat "$TEST_TMPDIR/state")" "state submitted"
    s_teardown
}
run_test "submit: a late Enter is read from the transcript after the give-up clear → rc 0" test_submit_late_enter_counts

test_submit_dialog_then_cleared() {
    s_setup; export RS_DIALOG_WAIT=5
    # the dialog closes 0.3 s after it came up (the typing stub raises it)
    ( for _ in $(seq 1 50); do grep -q waiting "$CC/sessions/$S_PID.json" && break; sleep 0.1; done
      sleep 0.3; s_status idle ) & local bg=$!
    local r; r=$(S_ON=1 S_DIALOG_ON_TYPE=1 s_submit "startup")
    wait "$bg"
    assert_eq "4 0" "$r" "a dialog after the text → no Enter, rc 4"
    assert_eq "clear|text:startup|clear" "$(s_keys)" "once the dialog is gone our text is cleared — never Enter"
    assert_file_contains "$TEST_TMPDIR/err" "cleared from its input line" "the reason says the text was cleared"
    s_teardown
}
run_test "submit: a dialog after the text → wait it out, then clear our text (never Enter)" test_submit_dialog_then_cleared

# The guard is read once before the clear; a dialog that comes up after that read — during the clear or
# the key gap — must still never receive the text (a '2' in it would pick a selector option).
test_submit_dialog_during_preclear() {
    s_setup
    local r; r=$(S_ON=1 S_DIALOG_ON_CLEAR=1 s_submit "update 2 files")
    assert_eq "3 0" "$r" "a dialog up by the time the line is cleared → rc 3, no Enter"
    assert_eq "clear" "$(s_keys)" "not one character of the text reaches the selector"
    assert_file_contains "$TEST_TMPDIR/err" "dialog" "the reason names the dialog"
    assert_file_contains "$TEST_TMPDIR/err" "NOT typed" "and says the text was not typed"
    s_teardown
}
run_test "submit: a dialog that comes up during the pre-clear → the text is never typed, rc 3" test_submit_dialog_during_preclear

test_submit_giveup_clear_fails_loudly() {
    s_setup; : > "$S_TR"   # a session WITH a transcript
    local r; r=$(S_ON=0 S_CLEAR_FAIL_ON=2 s_submit "startup")
    assert_eq "4 3" "$r" "never submitted → rc 4"
    assert_file_contains "$TEST_TMPDIR/err" "could NOT be cleared" "a failed give-up clear is said out loud"
    assert_file_contains "$TEST_TMPDIR/err" "Ctrl+U" "with the key that clears it by hand"
    s_teardown
}
run_test "submit: a give-up clear that fails says so, with the key to clear it by hand" test_submit_giveup_clear_fails_loudly

test_submit_reason_names_the_real_rule() {
    s_setup; : > "$S_TR"   # a session WITH a transcript
    S_ON=0 s_submit "startup" >/dev/null
    assert_file_contains "$TEST_TMPDIR/err" "equal to the text" "the reason states the rule the matcher applies"
    assert_file_not_contains "$TEST_TMPDIR/err" "starting with" "not the retired 'starting with the text'"
    assert_file_contains "$TEST_TMPDIR/err" "before sending again" "and says what to do before any resend"
    s_teardown
}
run_test "submit: the not-submitted reason names the equality rule and says read before resending" test_submit_reason_names_the_real_rule

# ── CFG-1043 data point 1: a session with NO transcript yet ──────────────────────────────────
# A /clear-ed (or brand-new) session writes its transcript with its first PROCESSED prompt — after its
# SessionStart hooks, ~100 s here (measured 2026-11-19). Live: `startup` typed right after /clear was taken,
# no file showed for 24 s, two more Enters and a clear went into the live session, exit 4 "NOT submitted".
test_submit_no_transcript_waits_for_the_file() {
    s_setup; assert_file_not_exists "$S_TR" "no transcript before the first prompt"
    ( sleep 1.5; t_user "$S_TR" "startup" ) & local bg=$!   # the session processes the prompt after its hooks
    local r; r=$(S_ON=0 s_submit "startup"); wait "$bg"
    assert_eq "0 1" "$r" "confirmed once the file appears — after ONE Enter, no retry"
    assert_eq "clear|text:startup|enter" "$(s_keys)" "no second Enter and no clearing keys while the file is awaited"
    assert_eq submitted "$(cat "$TEST_TMPDIR/state")" "state submitted"
    s_teardown
}
run_test "submit (CFG-1043): no transcript yet → the first prompt's file is waited for, Enter pressed once" test_submit_no_transcript_waits_for_the_file

test_submit_no_transcript_never_appears() {
    s_setup; export SHUTDOWN_FOLLOW_DIR="$TEST_TMPDIR/sf-state"; mkdir -p "$SHUTDOWN_FOLLOW_DIR"
    printf 'startup\n%s\n\n' "$(date +%s)" > "$SHUTDOWN_FOLLOW_DIR/stamp.$S_PID"   # as the typing primitive leaves it
    local s=$SECONDS r; r=$(S_ON=0 s_submit "startup")
    assert_eq "4 1" "$r" "no file within RS_SUBMIT_FIRST_WAIT → rc 4 after exactly one Enter"
    assert_eq 1 "$(( SECONDS - s >= 2 ))" "it waited RS_SUBMIT_FIRST_WAIT (2 s) for the file ($(( SECONDS - s )) s)"
    assert_eq "clear|text:startup|enter" "$(s_keys)" "no retry Enter and NO give-up clear: the line may already be in"
    assert_file_contains "$TEST_TMPDIR/err" "no transcript appeared" "the reason says why it cannot be confirmed"
    assert_file_contains "$TEST_TMPDIR/err" "NOT cleared" "and that nothing was cleared"
    assert_file_exists "$SHUTDOWN_FOLLOW_DIR/stamp.$S_PID" "the typing stamp stays: the line may still fire the prompt hook"
    unset SHUTDOWN_FOLLOW_DIR; s_teardown
}
run_test "submit (CFG-1043): no transcript ever → rc 4 after one Enter, nothing retried, nothing cleared" test_submit_no_transcript_never_appears

test_submit_giveup_clear_removes_the_stamp() {
    s_setup; : > "$S_TR"; export SHUTDOWN_FOLLOW_DIR="$TEST_TMPDIR/sf-state"; mkdir -p "$SHUTDOWN_FOLLOW_DIR"
    printf 'startup\n%s\n\n' "$(date +%s)" > "$SHUTDOWN_FOLLOW_DIR/stamp.$S_PID"
    local r; r=$(S_ON=0 s_submit "startup")
    assert_eq "4 3" "$r" "a session with a transcript: retried, then given up"
    assert_file_not_exists "$SHUTDOWN_FOLLOW_DIR/stamp.$S_PID" "the give-up clear took the stamp with the line"
    unset SHUTDOWN_FOLLOW_DIR; s_teardown
}
run_test "submit: a give-up that clears the line removes its typing stamp" test_submit_giveup_clear_removes_the_stamp

# On WSL each tty lookup is a root exec (~0.12 s). The dialog guard is only as good as the time between
# its read and the key: the input target is resolved ONCE, before the guard, so no lookup sits between a
# guard read and its injection — on send (rs_submit_line, incl. its give-up clear) and, where the driver
# remote-session.sh is shipped, on its exit command line too (the lib alone where it is not).
test_guard_read_is_next_to_its_key() {
    a_setup; local p gaps want=6 what="send (clear, text, 3 Enters, give-up clear)"
    p=$(a_spawn claude /dev/pts/40 /home/user/x claude); mkdir -p "$CC/projects/-x"
    export S_TR="$CC/projects/-x/sid-$p.jsonl" S_SEQ="$TEST_TMPDIR/seq" S_BOX="$TEST_TMPDIR/box"; : > "$S_SEQ"
    : > "$S_TR"   # a session WITH a transcript: the retries and the give-up clear measured here need one (CFG-1043)
    s_wsl_stub "$TEST_TMPDIR/root"
    export RS_WSL=1 RS_INJECT="$TEST_TMPDIR/root" RS_TMUX=/bin/false RS_POLL=0.1 RS_KEY_GAP=0 RS_SUBMIT_WAIT=1 RS_CLEAR_PRESSES=8
    if [[ -f "$RS" ]]; then
        want=9; what="$what + exit (clear, text, Enter, clear)"
        ( source "$RS"; rs_dialog_up() { echo guard >> "$S_SEQ"; [[ "$(rs_session_field "$1" status)" == waiting ]]; }
          rs_gate_arm "$p"; S_NOREC=1 rs_submit_line "$p" "hello there" 2>/dev/null   # armed as the caller's rs_safety_check would (CFG-1083 F1)
          RS_START_PID=1 main "$p" exit --max-wait 1 --ordered "test: the user's order" >/dev/null 2>&1 )   # past the typing gate (CFG-1028)
    else
        ( source "$LIB"; rs_dialog_up() { echo guard >> "$S_SEQ"; [[ "$(rs_session_field "$1" status)" == waiting ]]; }
          rs_gate_arm "$p"; S_NOREC=1 rs_submit_line "$p" "hello there" 2>/dev/null )
    fi
    gaps=$(s_guard_gaps "$S_SEQ")
    assert_eq 1 "$(( $(wc -l <<<"$gaps") >= want ))" "$what: every key had its guard read (measured guard→key pairs: $(wc -l <<<"$gaps"), expected at least $want)"
    assert_eq "" "$(grep -v '^0$' <<<"$gaps" | paste -sd,)" "no root lookup between a guard read and its key (measured lookups per pair: $(paste -sd, <<<"$gaps"))"
    unset S_TR S_SEQ S_BOX RS_WSL RS_INJECT RS_TMUX RS_POLL RS_KEY_GAP RS_SUBMIT_WAIT RS_CLEAR_PRESSES
    a_teardown
}
run_test "dialog guard: the input target is resolved before the guard read, so the key follows it directly (WSL)" test_guard_read_is_next_to_its_key

# ── B. tmux and Konsole branches, fake binaries on PATH ────────────────────────
# k_bin — fake `tmux` (display answers the pane's tty from $FAKE_LOG/pane-tty; anything else is logged,
# %q-quoted, its start time to tmux.times) and fake `qdbus` (one Konsole service with /Sessions/1,
# processId from $FAKE_LOG/konsole-pid, sendText logged %q-quoted, its payload length to konsole.len and
# its start time to konsole.times) in $FB, to be put first on PATH.
k_bin() {
    FB="$TEST_TMPDIR/fakebin"; FAKE_LOG="$TEST_TMPDIR/fake"; mkdir -p "$FB" "$FAKE_LOG"; export FAKE_LOG
    cat > "$FB/tmux" << 'EOF'
#!/usr/bin/env bash
[[ "$1" == display ]] && { cat "$FAKE_LOG/pane-tty"; exit 0; }
date +%s.%N >> "$FAKE_LOG/tmux.times"
printf '%q ' "$@" >> "$FAKE_LOG/tmux.log"; echo >> "$FAKE_LOG/tmux.log"
EOF
    cat > "$FB/qdbus" << 'EOF'
#!/usr/bin/env bash
case $# in
  0) printf 'org.freedesktop.DBus\norg.kde.konsole-4711\n' ;;
  1) printf '/Windows/1\n/Sessions/1\n' ;;
  *) case "$3" in
       org.kde.konsole.Session.processId) cat "$FAKE_LOG/konsole-pid" ;;
       org.kde.konsole.Session.sendText) date +%s.%N >> "$FAKE_LOG/konsole.times"; echo "${#4}" >> "$FAKE_LOG/konsole.len"
                                         printf '%s %q\n' "$1$2" "$4" >> "$FAKE_LOG/konsole.log" ;;
     esac ;;
esac
EOF
    chmod +x "$FB/tmux" "$FB/qdbus"
}
# k_min_gap <times-file> — the shortest pause between two consecutive writes, in seconds (9 if < 2 writes)
k_min_gap() { awk 'NR > 1 { d = $1 - p; if (m == "" || d < m) m = d } { p = $1 } END { printf "%.3f\n", (m == "" ? 9 : m) }' "$1"; }

test_tmux_branch_keys() {
    a_setup; k_bin
    local p; p=$(a_spawn claude /dev/pts/40 /home/user/x claude)
    printf 'TMUX_PANE=%%7\0' > "$PROC/$p/environ"; echo /dev/pts/40 > "$FAKE_LOG/pane-tty"
    ( PATH="$FB:$PATH"; RS_TMUX=tmux RS_CLEAR_PRESSES=3
      rs_gate_arm "$p"; rs_type_text "$p" "hello there"; rs_press_enter "$p"; rs_clear_input "$p" )   # armed (CFG-1083 F1)
    assert_eq "send-keys -t %7 -l hello\\ there |send-keys -t %7 Enter |send-keys -t %7 C-k C-k C-k C-u C-u C-u " \
        "$(paste -sd'|' "$FAKE_LOG/tmux.log")" \
        "tmux: the text literally (-l) with no Enter, Enter alone, then 3× Ctrl+K + 3× Ctrl+U as key names"
    assert_file_not_exists "$FAKE_LOG/konsole.log" "nothing went to Konsole"
    unset FAKE_LOG; a_teardown
}
run_test "keys (tmux): rs_type_text types without Enter; Enter and the line clear are separate send-keys" test_tmux_branch_keys

# Claude Code 2.1.280 reads a control byte as a key ONLY when it arrives in a read of fewer than 64 bytes;
# a read of 64+ bytes is one text token whose control bytes do nothing (bin/claude.exe offset 191421218).
# So the default clear never goes in as one burst — 128 bytes of Ctrl+K/Ctrl+U were read as [21,107],
# [50,78], [37,91]: 0 Ctrl+U keys — but in writes of a few keys, paused between, on every path.
test_default_clear_small_writes() {
    a_setup; k_bin
    local p n gap max ks; p=$(a_spawn claude /dev/pts/40 /home/user/x claude)
    printf 'TMUX_PANE=%%7\0' > "$PROC/$p/environ"; echo /dev/pts/40 > "$FAKE_LOG/pane-tty"
    read -r n gap < <( unset RS_CLEAR_PRESSES RS_CLEAR_BATCH RS_CLEAR_GAP; source "$LIB"; PATH="$FB:$PATH"; RS_TMUX=tmux
                       rs_gate_arm "$p"; rs_clear_input "$p" >/dev/null 2>&1; echo "$RS_CLEAR_PRESSES ${RS_CLEAR_GAP:-0}" )
    ks=$(tr ' ' '\n' < "$FAKE_LOG/tmux.log")
    assert_eq "$n $n" "$(grep -cx 'C-k' <<<"$ks") $(grep -cx 'C-u' <<<"$ks")" "tmux: the default clear is ${n}× Ctrl+K then ${n}× Ctrl+U"
    max=$(awk '{ if (NF - 3 > m) m = NF - 3 } END { print m + 0 }' "$FAKE_LOG/tmux.log")
    assert_eq 1 "$(( max <= 16 ))" "tmux: no write carries more than 16 keys (measured: largest $max keys in $(wc -l < "$FAKE_LOG/tmux.log") write(s))"
    assert_eq 1 "$(awk -v g="$gap" 'BEGIN { print (g > 0) }')" "a pause between the writes is configured (RS_CLEAR_GAP: $gap)"
    assert_eq 1 "$(awk -v m="$(k_min_gap "$FAKE_LOG/tmux.times")" -v g="$gap" 'BEGIN { print (m >= g) }')" \
        "tmux: consecutive writes are at least RS_CLEAR_GAP ($gap s) apart (measured shortest: $(k_min_gap "$FAKE_LOG/tmux.times") s)"
    : > "$FAKE_LOG/tmux.log"; echo "$p" > "$FAKE_LOG/konsole-pid"; rm -f "$PROC/$p/environ"   # now a Konsole tab
    ( unset RS_CLEAR_PRESSES RS_CLEAR_BATCH RS_CLEAR_GAP; source "$LIB"; PATH="$FB:$PATH"; RS_TMUX=tmux RS_QDBUS=qdbus
      rs_gate_arm "$p"; rs_clear_input "$p" >/dev/null 2>&1 )
    assert_eq "$(( 2 * n ))" "$(awk '{ s += $1 } END { print s + 0 }' "$FAKE_LOG/konsole.len")" "Konsole: ${n}+${n} clearing bytes in all"
    max=$(sort -n "$FAKE_LOG/konsole.len" | tail -1)
    assert_eq 1 "$(( max <= 16 ))" "Konsole: no sendText carries more than 16 bytes (measured: largest $max)"
    assert_eq 1 "$(awk -v m="$(k_min_gap "$FAKE_LOG/konsole.times")" -v g="$gap" 'BEGIN { print (m >= g) }')" \
        "Konsole: consecutive writes at least $gap s apart (measured shortest: $(k_min_gap "$FAKE_LOG/konsole.times") s)"
    unset FAKE_LOG; a_teardown
}
run_test "keys: the default clear goes in as writes of ≤ 16 keys, paused between (tmux, Konsole)" test_default_clear_small_writes

test_konsole_branch_keys() {
    a_setup; k_bin
    local p; p=$(a_spawn claude /dev/pts/40 /home/user/x claude)
    echo "$p" > "$FAKE_LOG/konsole-pid"   # the Konsole session's process is the target (no tmux pane)
    ( PATH="$FB:$PATH"; RS_TMUX=tmux RS_QDBUS=qdbus RS_CLEAR_PRESSES=3
      rs_gate_arm "$p"; rs_type_text "$p" "hello there"; rs_press_enter "$p"; rs_clear_input "$p" )   # armed (CFG-1083 F1)
    local svc="org.kde.konsole-4711/Sessions/1"
    assert_eq "$svc hello\\ there|$svc $(printf '%q' $'\r')|$svc $(printf '%q' $'\x0b\x0b\x0b\x15\x15\x15')" \
        "$(paste -sd'|' "$FAKE_LOG/konsole.log")" \
        "Konsole: sendText of the text alone, then a CR alone, then 3× Ctrl+K + 3× Ctrl+U"
    assert_file_not_exists "$FAKE_LOG/tmux.log" "nothing went to tmux"
    unset FAKE_LOG; a_teardown
}
run_test "keys (Konsole): rs_type_text sends no CR; Enter and the line clear are separate sendTexts" test_konsole_branch_keys

test_no_target_no_keys() {
    a_setup; k_bin
    local p; p=$(a_spawn claude /dev/pts/40 /home/user/x claude)
    echo 999999 > "$FAKE_LOG/konsole-pid"   # a Konsole tab that is NOT the target's
    local rc1 rc2; rs_gate_arm "$p"   # armed, so the rc 3 below is the missing target, not the gate (CFG-1083 F1)
    ( PATH="$FB:$PATH"; RS_TMUX=tmux RS_QDBUS=qdbus; rs_type_text "$p" "hello" ); rc1=$?
    ( PATH="$FB:$PATH"; RS_TMUX=tmux RS_QDBUS=qdbus; rs_clear_input "$p" ); rc2=$?
    assert_eq "3 3" "$rc1 $rc2" "no pane, a foreign Konsole tab, not WSL → rc 3 for typing and clearing"
    assert_file_not_exists "$FAKE_LOG/konsole.log" "nothing sent to the foreign tab"
    unset FAKE_LOG; a_teardown
}
run_test "keys: a foreign Konsole tab and no pane → rc 3, no key sent anywhere" test_no_target_no_keys

# The target is resolved once per submission (round 3), so a claude that exits mid-submission leaves a
# pre-resolved tmux pane / Konsole tab holding a bare shell: text + Enter would run there as a command.
# Every tmux/Konsole key write re-checks that the pid is alive (no root call: the WSL injector checks
# --expect-pid itself).
test_dead_pid_with_resolved_target_no_keys() {
    a_setup; k_bin
    local p t rc1 rc2 rc3 rc4 rc5 rc6
    p=$(a_spawn claude /dev/pts/40 /home/user/x claude)
    printf 'TMUX_PANE=%%7\0' > "$PROC/$p/environ"; echo /dev/pts/40 > "$FAKE_LOG/pane-tty"
    t=$( PATH="$FB:$PATH"; RS_TMUX=tmux; rs_input_target "$p" ); rs_gate_arm "$p"   # armed: the rc 3 below is the dead pid (CFG-1083 F1)
    kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
    ( PATH="$FB:$PATH"; RS_TMUX=tmux; rs_type_text "$p" "hello" "$t" ); rc1=$?
    ( PATH="$FB:$PATH"; RS_TMUX=tmux; rs_press_enter "$p" "$t" ); rc2=$?
    ( PATH="$FB:$PATH"; RS_TMUX=tmux RS_CLEAR_PRESSES=3; rs_clear_input "$p" "$t" ); rc3=$?
    assert_eq "tmux 3 3 3" "${t%% *} $rc1 $rc2 $rc3" "tmux target resolved while alive; after the pid died: rc 3 for text, Enter and clear"
    assert_file_not_exists "$FAKE_LOG/tmux.log" "no key reached the pane of the dead pid"
    local q; q=$(a_spawn claude /dev/pts/41 /home/user/x claude); echo "$q" > "$FAKE_LOG/konsole-pid"
    t=$( PATH="$FB:$PATH"; RS_TMUX=tmux RS_QDBUS=qdbus; rs_input_target "$q" ); rs_gate_arm "$q"
    kill "$q" 2>/dev/null; wait "$q" 2>/dev/null
    ( PATH="$FB:$PATH"; RS_QDBUS=qdbus; rs_type_text "$q" "hello" "$t" ); rc4=$?
    ( PATH="$FB:$PATH"; RS_QDBUS=qdbus; rs_press_enter "$q" "$t" ); rc5=$?
    ( PATH="$FB:$PATH"; RS_QDBUS=qdbus RS_CLEAR_PRESSES=3; rs_clear_input "$q" "$t" ); rc6=$?
    assert_eq "konsole 3 3 3" "${t%% *} $rc4 $rc5 $rc6" "Konsole target resolved while alive; after the pid died: rc 3 for text, Enter and clear"
    assert_file_not_exists "$FAKE_LOG/konsole.log" "no key reached the Konsole tab of the dead pid"
    unset FAKE_LOG; a_teardown
}
run_test "keys: a pid that died after its target was resolved gets no key (tmux, Konsole)" test_dead_pid_with_resolved_target_no_keys

# ── C. tty-inject.py --clear: parse refusals (no device opened) ───────────────
test_injector_clear_parse() {
    local rc
    python3 "$INJ" --clear /dev/pts/999999 >/dev/null 2>&1; rc=$?
    assert_eq 2 "$rc" "--clear without a count → exit 2"
    python3 "$INJ" --clear 0 --no-cr /dev/pts/999999 >/dev/null 2>&1; rc=$?
    assert_eq 2 "$rc" "--clear 0 → exit 2"
    python3 "$INJ" --clear 65 --no-cr /dev/pts/999999 >/dev/null 2>&1; rc=$?
    assert_eq 2 "$rc" "--clear above 64 → exit 2"
    python3 "$INJ" --no-cr /dev/pts/999999 >/dev/null 2>&1; rc=$?
    assert_eq 2 "$rc" "no text, no CR, no clear → nothing to type, exit 2"
    python3 "$INJ" --clear 2 --no-cr /dev/pts/999999 >/dev/null 2>&1; rc=$?
    assert_eq 4 "$rc" "--clear 2 --no-cr parses; only the missing device refuses it (exit 4)"
}
run_test "injector: --clear needs a count 1-64; a clear alone is a valid injection" test_injector_clear_parse

# i_writes <tty-inject.py args, PTY for the device> — run the injector on a private pty with TIOCSTI and
# time.sleep RECORDED, not performed (no root needed): one line per write — the bytes between two
# pauses — as "<pause-before> <length> <hex>". I_PROC: a fixture /proc for --expect-pid (TTY_INJECT_PROC);
# I_DIE_AFTER=<n>: that fixture's pid dies during the n-th pause. Last line: "rc <exit code>".
i_writes() {
    TTY_INJECT_PROC="${I_PROC:-/proc}" python3 - "$INJ" "$@" <<'PY'
import contextlib, fcntl, importlib.util, io, os, shutil, sys, time
spec = importlib.util.spec_from_file_location("tty_inject", sys.argv[1]); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
master, slave = os.openpty(); name = os.ttyname(slave)
writes, pauses = [[0.0, b""]], [0]
def ioctl(fd, req, arg): writes[-1][1] += arg
def sleep(s):
    pauses[0] += 1; writes.append([s, b""])
    if str(pauses[0]) == os.environ.get("I_DIE_AFTER"): shutil.rmtree(os.environ["I_PROC"] + "/" + os.environ["I_PID"])
fcntl.ioctl, time.sleep = ioctl, sleep
sys.argv = ["tty-inject.py"] + [a.replace("PTY", name) for a in sys.argv[2:]]
if os.environ.get("I_PROC"):
    d = os.environ["I_PROC"] + "/" + os.environ["I_PID"]; os.makedirs(d + "/fd")
    os.symlink(name, d + "/fd/0"); os.symlink("/opt/x/claude", d + "/exe")
rc = 0
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    try: m.main()
    except SystemExit as e: rc = e.code
for gap, data in writes:
    if data: print("%.2f %d %s" % (gap, len(data), data.hex()))
print("rc", rc)
PY
}
# i_check <i_writes output> — "<writes> <largest write holding a control byte> <writes after the first not paused before>"
i_check() { awk '$1 == "rc" { next } { n++; if ($3 ~ /^(..)*(0[0-9a-f]|1[0-9a-f])/ && $2 > c) c = $2; if (n > 1 && $1 + 0 <= 0) u++ }
                 END { print n + 0, c + 0, u + 0 }' <<<"$1"; }
# i_bytes <i_writes output> <hex byte> — how many of that byte were written in all
i_bytes() { awk '$1 != "rc" { printf "%s", $3 }' <<<"$1" | fold -w2 | grep -cx "$2"; }

# Claude Code 2.1.280 acts on a control byte only in a read of fewer than 64 bytes. Every injection the
# injector makes — the clear, a text followed by its Enter (rs_type_line, remote-poweroff) — goes in as
# separate writes with a pause before each, so no control byte ever shares a read of 64+ bytes.
test_injector_writes_keys_small_and_apart() {
    local out long n c u; long=$(printf 'order-%03d ' $(seq 1 33))
    out=$(i_writes --clear 64 --no-cr PTY)
    read -r n c u <<<"$(i_check "$out")"
    assert_eq "64 64" "$(i_bytes "$out" 0b) $(i_bytes "$out" 15)" "--clear 64: 64 Ctrl+K and 64 Ctrl+U in all"
    assert_eq "0b" "$(awk '$1 != "rc" { print substr($3, 1, 2); exit }' <<<"$out")" "--clear: Ctrl+K first, then Ctrl+U"
    assert_eq 1 "$(( c <= 16 ))" "--clear 64: no write of more than 16 bytes (measured: $n writes, largest $c bytes)"
    assert_eq 0 "$u" "--clear 64: a pause before every write after the first (measured unpaused: $u)"
    out=$(i_writes PTY "$long"); read -r n c u <<<"$(i_check "$out")"
    assert_eq "2 1" "$n $c" "a ${#long}-byte TEXT and its Enter: the text, then the CR in a write of its own (measured: $n writes, largest with a control byte $c)"
    assert_eq 0 "$u" "a pause before the Enter (measured unpaused: $u)"
    out=$(i_writes --clear 2 PTY "hello"); read -r n c u <<<"$(i_check "$out")"
    assert_eq "3 0" "$n $u" "--clear 2 + TEXT + Enter: three writes, each paused before (measured: $n writes, $u unpaused)"
    assert_eq "rc 0" "$(tail -1 <<<"$out")" "and the injection succeeds"
}
run_test "injector: the clear in writes of ≤ 16 keys and a text's Enter in a write of its own, paused between" test_injector_writes_keys_small_and_apart

# The pid check (--expect-pid) holds for every write, not just the first: the injection now spans pauses.
test_injector_reverifies_each_write() {
    local out; export I_PROC="$TEST_TMPDIR/iproc" I_PID=4242
    out=$(I_DIE_AFTER=2 i_writes --expect-pid 4242 --clear 64 --no-cr PTY)
    assert_eq "rc 5" "$(tail -1 <<<"$out")" "the pid gone during the 2nd pause → exit 5 (stopped part-way): $(tail -1 <<<"$out")"
    assert_eq 2 "$(grep -vc '^rc' <<<"$out")" "nothing written after the pid check failed (measured writes: $(grep -vc '^rc' <<<"$out"))"
    rm -rf "$I_PROC"; out=$(i_writes --expect-pid 4242 --clear 64 --no-cr PTY)
    assert_eq "rc 0" "$(tail -1 <<<"$out")" "control: the same pid alive throughout → exit 0"
    unset I_PROC I_PID
}
run_test "injector: --expect-pid is re-checked before every write; a pid gone part-way stops it (exit 5)" test_injector_reverifies_each_write

# ── D. real ptys + root injector ──────────────────────────────────────────────
if (( HAVE_ROOT )); then

test_real_draft_does_not_merge() {
    local cc="$TEST_TMPDIR/cc"; mkdir -p "$cc/sessions"
    b_spawn one "$cc"; local one=$B_CLA tty1=$B_TTY
    $ROOT_INJECT "$INJ" --expect-pid "$one" --no-cr "$tty1" "a stale draft " >/dev/null 2>&1   # text left in its box
    local out rc; out=$(env "${B_RS_ENV[@]}" RS_CC_DIR="$cc" bash "$RS" "$one" send "hello there" --ordered "test: the user's order" 2>&1); rc=$?
    local tr="$cc/projects/-fake/sid-init.jsonl"
    assert_eq 0 "$rc" "send confirmed: $out"
    assert_eq 1 "$(b_prompts "$tr" "hello there")" "the prompt is exactly the order"
    assert_eq 0 "$(b_prompts_holding "$tr" "a stale draft")" "the draft in the box did not go out with it"
    b_teardown
}
n_run_if "real pty: a draft left in the input box is cleared, not merged into the order" test_real_draft_does_not_merge "$RS"

test_real_giveup_leaves_box_empty() {
    local cc="$TEST_TMPDIR/cc"; mkdir -p "$cc/sessions"
    b_spawn one "$cc"; local one=$B_CLA tty1=$B_TTY recv1=$B_RECV
    local tr="$cc/projects/-fake/sid-init.jsonl"
    # control: the probe can see a leftover — text left by eaten Enters goes out on the next bare Enter
    touch "$recv1.stuck"; $ROOT_INJECT "$INJ" --expect-pid "$one" "$tty1" "leftover" >/dev/null 2>&1; sleep 0.3
    rm -f "$recv1.stuck"; $ROOT_INJECT "$INJ" --expect-pid "$one" "$tty1" >/dev/null 2>&1
    local i; for i in $(seq 1 20); do [[ "$(b_prompts "$tr" leftover)" == 1 ]] && break; sleep 0.2; done
    assert_eq 1 "$(b_prompts "$tr" leftover)" "control: a leftover in the box is sent by the next bare Enter"
    # every Enter is eaten → we give up; then someone presses Enter: nothing of ours may go out
    touch "$recv1.stuck"
    local out rc; out=$(env "${B_RS_ENV[@]}" RS_CC_DIR="$cc" bash "$RS" "$one" send "hello there" --ordered "test: the user's order" 2>&1); rc=$?
    assert_eq 4 "$rc" "never submitted → exit 4: $out"
    assert_contains "$out" "cleared from its input line" "the report says our text was cleared"
    rm -f "$recv1.stuck"; $ROOT_INJECT "$INJ" --expect-pid "$one" "$tty1" >/dev/null 2>&1; sleep 1
    assert_eq 0 "$(b_prompts_holding "$tr" "hello there")" "a later Enter sends nothing of the given-up order"
    b_teardown
}
n_run_if "real pty: a given-up order is cleared — a later Enter sends nothing of it" test_real_giveup_leaves_box_empty "$RS"

# The injector's full clear, read by a session that tokenizes as Claude Code does (a read of 64+ bytes is
# text): the keys must arrive in reads small enough to act, or the draft survives and goes out next Enter.
test_real_full_clear_empties_box() {
    local cc="$TEST_TMPDIR/cc"; mkdir -p "$cc/sessions"
    b_spawn one "$cc"; local one=$B_CLA tty1=$B_TTY tr="$cc/projects/-fake/sid-init.jsonl" i
    $ROOT_INJECT "$INJ" --expect-pid "$one" --no-cr "$tty1" "a control draft" >/dev/null 2>&1
    $ROOT_INJECT "$INJ" --expect-pid "$one" "$tty1" >/dev/null 2>&1
    for i in $(seq 1 10); do [[ "$(b_prompts "$tr" "a control draft")" == 1 ]] && break; sleep 0.2; done
    assert_eq 1 "$(b_prompts "$tr" "a control draft")" "control: a draft in the box goes out on a bare Enter"
    $ROOT_INJECT "$INJ" --expect-pid "$one" --no-cr "$tty1" "a stale draft" >/dev/null 2>&1
    $ROOT_INJECT "$INJ" --expect-pid "$one" --clear 64 --no-cr "$tty1" >/dev/null 2>&1
    $ROOT_INJECT "$INJ" --expect-pid "$one" "$tty1" >/dev/null 2>&1   # a bare Enter sends whatever the box holds
    for i in $(seq 1 10); do [[ "$(b_prompts_holding "$tr" "a stale draft")" == 0 ]] || break; sleep 0.2; done
    assert_eq 0 "$(b_prompts_holding "$tr" "a stale draft")" "after --clear 64 a bare Enter sends nothing of the draft (prompts holding it: $(b_prompts_holding "$tr" "a stale draft"))"
    b_teardown
}
run_test "real pty: --clear 64 empties the box of a session that reads 64+ bytes as text" test_real_full_clear_empties_box

# The 2026-11-13 incident, as a regression guard: a 330-byte text and its CR in ONE burst is one read of
# 64+ bytes — the CR is text and nothing is submitted (the order sits in the box until the next Enter).
# The text and a SEPARATE lone CR submit; so does the injector given text + Enter in one call.
test_real_long_text_enter_separate() {
    local cc="$TEST_TMPDIR/cc"; mkdir -p "$cc/sessions"
    b_spawn one "$cc"; local one=$B_CLA tty1=$B_TTY recv1=$B_RECV tr="$cc/projects/-fake/sid-init.jsonl"
    local a b c i; a=$(printf 'burst-%03d ' $(seq 1 33)); b=$(printf 'split-%03d ' $(seq 1 33)); c=$(printf 'onecall-%02d ' $(seq 1 30))
    printf 'import fcntl,os,sys,termios\nfd = os.open(sys.argv[1], os.O_WRONLY | os.O_NOCTTY)\nfor x in sys.argv[2].encode() + b"\\r": fcntl.ioctl(fd, termios.TIOCSTI, bytes([x]))\n' > "$TEST_TMPDIR/burst.py"
    $ROOT_INJECT "$TEST_TMPDIR/burst.py" "$tty1" "$a" >/dev/null 2>&1; sleep 1
    assert_eq 0 "$(b_prompts "$tr" "$a")" "control: text + CR in one ${#a}-byte burst submits nothing (prompts: $(b_prompts "$tr" "$a"))"
    assert_file_not_exists "$recv1" "the CR in that burst never acted as Enter"
    $ROOT_INJECT "$INJ" --expect-pid "$one" "$tty1" >/dev/null 2>&1   # the next Enter sends what sat in the box
    for i in $(seq 1 10); do [[ "$(b_prompts "$tr" "$a")" == 1 ]] && break; sleep 0.2; done
    assert_eq 1 "$(b_prompts "$tr" "$a")" "control: the order sat unsent in the box until the next Enter"
    $ROOT_INJECT "$INJ" --expect-pid "$one" --no-cr "$tty1" "$b" >/dev/null 2>&1
    $ROOT_INJECT "$INJ" --expect-pid "$one" "$tty1" >/dev/null 2>&1
    for i in $(seq 1 10); do [[ "$(b_prompts "$tr" "$b")" == 1 ]] && break; sleep 0.2; done
    assert_eq 1 "$(b_prompts "$tr" "$b")" "a ${#b}-byte text, then a separate lone CR → submitted"
    $ROOT_INJECT "$INJ" --expect-pid "$one" "$tty1" "$c" >/dev/null 2>&1
    for i in $(seq 1 10); do [[ "$(b_prompts "$tr" "$c")" == 1 ]] && break; sleep 0.2; done
    assert_eq 1 "$(b_prompts "$tr" "$c")" "the injector given a ${#c}-byte text AND its Enter in one call → submitted (prompts: $(b_prompts "$tr" "$c"))"
    b_teardown
}
run_test "real pty: text + CR in one 64+-byte burst is not submitted; text then a lone CR is (incident guard)" test_real_long_text_enter_separate

else
    skip_test "real pty: a draft is cleared, not merged"    "$ROOT_WHY"
    skip_test "real pty: a given-up order is cleared"       "$ROOT_WHY"
    skip_test "real pty: --clear 64 empties the box"        "$ROOT_WHY"
    skip_test "real pty: text + CR burst vs separate CR"    "$ROOT_WHY"
fi

suite_summary
