#!/usr/bin/env bash
# Tests for the AskUserQuestion answer handshake in global/hooks/afd-relay.sh + lib-afd-ask.sh
# (CFG-779). 2026-10-24: two projects both waited on relayed questions; the user's untagged
# Telegram replies for the first (#472, #484) were consumed by the second, whose relay took #484
# just because 484 > its own question id. Now an untagged line is pooled, a relay CLAIMS it
# (tier 0: a Telegram reply to the question; tier 1: it maps onto the question; tier 2: any
# newer line after a grace), asks the user back "[proj] was #M for me? y / n / @project" when
# another relay is waiting too, and confirms "[proj] working on #M" once the user says y.
# test-afd-relay.sh is over the 1500-line split threshold, hence this file.
source "$(dirname "$0")/test-helpers.sh"

HOOK="$REPO_ROOT/global/hooks/afd-relay.sh"

suite_header "afd-relay.sh (AskUserQuestion answer handshake, CFG-779)"

# Mock afd. notify answers "#<n>" from a shared id sequence like the server's (n = 1 + the
# larger of the last id handed out and the highest message id served), logs every call, and
# releases $HOME/verdict.jsonl into pending when it sends an ask-back ("was #"), so the user's
# verdict arrives on the next poll. poll never answers (free text comes as a message).
setup_env() {
    MOCK_HOME="$TEST_TMPDIR/home"
    mkdir -p "$MOCK_HOME/.local/bin"
    export MOCK_AFD_LOG="$TEST_TMPDIR/afd-calls.log" AFD_MSG_DIR="$MOCK_HOME/.afd-msgs"
    unset AFD_PROJECT_ROOTS   # the live settings env must not leak into the sandbox
    local p; for p in alpha institute aiware; do mkdir -p "$MOCK_HOME/$p"; git -C "$MOCK_HOME/$p" init -q; done
    touch "$MOCK_HOME/.afd-afk"
    echo "${SEQ0:-100}" > "$MOCK_HOME/seq"
    cat > "$MOCK_HOME/.local/bin/afd" << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$MOCK_AFD_LOG"
case "$1" in
  notify)
    if [[ "$3" == *"was #"* && -n "${MOCK_ASKBACK_FAIL:-}" ]]; then echo "error: telegram down"; exit 1; fi
    n=$(( $(cat "$HOME/seq") + 1 )); echo "$n" > "$HOME/seq"
    echo "Notification #$n sent to all"
    [[ "$3" == *"was #"* && -f "$HOME/verdict.jsonl" ]] && mv "$HOME/verdict.jsonl" "$HOME/pending.jsonl" ;;
  poll) cat "$AFD_MSG_DIR/.waiting/"* >> "$HOME/marker.hist" 2>/dev/null; exit 1 ;;
  messages)
    if [[ -f "$HOME/pending.jsonl" ]]; then
        cat "$HOME/pending.jsonl"
        top=$(grep -oE '"id": ?[0-9]+' "$HOME/pending.jsonl" | grep -oE '[0-9]+' | sort -n | tail -1)
        [[ -n "$top" && "$top" -gt "$(cat "$HOME/seq")" ]] && echo "$top" > "$HOME/seq"
        rm -f "$HOME/pending.jsonl"
    fi ;;
esac
exit 0
MOCK
    chmod +x "$MOCK_HOME/.local/bin/afd"
    POOL="$AFD_MSG_DIR/.untagged.jsonl"
}

msg() { # msg <id> <text> [extra json fields] — one `afd messages` line
    printf '{"id":%s,"message":%s,"timestamp":"t","persona":"Bot"%s}' "$1" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$2")" "${3:+,$3}"
}
pending() { printf '%s\n' "$@" >> "$MOCK_HOME/pending.jsonl"; }   # served on the next poll
verdict() { printf '%s\n' "$@" >> "$MOCK_HOME/verdict.jsonl"; }   # served after the ask-back
other_waiter() { # other_waiter <project> <question id> [claimed M C] — another live relay
    mkdir -p "$AFD_MSG_DIR/.waiting"; echo "$$ $2${3:+ $3}" > "$AFD_MSG_DIR/.waiting/$1"
}
ask_json() { # ask_json <project> — one question with options Add / Skip
    python3 -c 'import json,sys; print(json.dumps({"tool_name":"AskUserQuestion","cwd":sys.argv[1],"tool_input":{"questions":[{"question":"Add the caveat to P4?","header":"P4","multiSelect":False,"options":[{"label":"Add","description":"x"},{"label":"Skip","description":"y"}]}]}}))' "$MOCK_HOME/$1"
}
ask2_json() { # two questions
    python3 -c 'import json,sys; print(json.dumps({"tool_name":"AskUserQuestion","cwd":sys.argv[1],"tool_input":{"questions":[{"question":"Q one?","header":"A","multiSelect":False,"options":[{"label":"A1","description":"x"},{"label":"A2","description":"y"}]},{"question":"Q two?","header":"B","multiSelect":False,"options":[{"label":"B1","description":"x"},{"label":"B2","description":"y"},{"label":"B3","description":"z"}]}]}}))' "$MOCK_HOME/$1"
}
# run_relay <json> [env VAR=val ...] — sets RC, OUT, ERR, TOOK. Poll every second; the wait
# ends after HOOK_AFK_TIMEOUT (default 8) s; tier-2 grace ASK_GRACE (default 0) s.
run_relay() {
    local json="$1" t0=$SECONDS; shift
    RC=0
    HOME="$MOCK_HOME" AFD_AFK_TIMEOUT="${HOOK_AFK_TIMEOUT:-8}" AFD_AFK_POLL_INTERVAL=1 AFD_ASK_GRACE="${ASK_GRACE:-0}" \
        "$@" bash "$HOOK" < <(printf '%s' "$json") > "$TEST_TMPDIR/out" 2> "$TEST_TMPDIR/err" || RC=$?
    OUT=$(cat "$TEST_TMPDIR/out"); ERR=$(cat "$TEST_TMPDIR/err"); TOOK=$(( SECONDS - t0 ))
}
answer_of() { # answer_of <question> — the answer in the allow JSON, "" otherwise
    printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin)["hookSpecificOutput"]; print(d["updatedInput"]["answers"].get(sys.argv[1],"")) if d.get("permissionDecision")=="allow" else print("")' "$1" 2>/dev/null
}
notifies() { # afd calls containing <text> literally; 0 when afd was never called
    [[ -f "$MOCK_AFD_LOG" ]] || { echo 0; return; }
    grep -cF -- "$1" "$MOCK_AFD_LOG" || true
}
pool_has() { grep -qE "\"id\": ?$1[,}]" "$POOL" 2>/dev/null; }
claim_owner() { cat "$AFD_MSG_DIR/.claims/$1/owner" 2>/dev/null; }

# ── Single waiter: no ask-back, in-place peek (CFG-781) ───────────────────────

test_single_waiter_takes_untagged_without_askback() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"; echo "$(msg 5 'old chatter')" > "$AFD_MSG_DIR/alpha.jsonl"
    pending "$(msg 105 'skip')"
    run_relay "$(ask_json alpha)"
    assert_eq "0" "$RC" "answer delivered as an allowed tool call (rc=$RC, err: $ERR)"
    assert_eq "Skip" "$(answer_of 'Add the caveat to P4?')" "the pooled untagged reply is the answer (out: $OUT)"
    assert_eq "0" "$(notifies 'was #')" "the only waiter does not ask back"
    assert_eq "0" "$(notifies 'working on')" "and sends no confirmation"
    pool_has 105 && r=1 || r=0
    assert_eq "0" "$r" "the answer is deleted from the pool by id"
    assert_file_contains "$AFD_MSG_DIR/alpha.jsonl" '"old chatter"' "an older queued line stays in place, never requeued (CFG-781)"
    assert_eq "" "$(claim_owner 105)" "the claim is released"
    assert_file_not_exists "$AFD_MSG_DIR/.waiting/alpha" "the waiting marker is gone"
}
run_test "single waiter: untagged reply taken from the pool, no ask-back" test_single_waiter_takes_untagged_without_askback

# ── Two waiters: ask back, then y / n / redirect ─────────────────────────────

test_two_waiters_ask_back_then_yes() {
    setup_env
    other_waiter institute 90
    pending "$(msg 105 '1 and maybe 2')"
    verdict "$(msg 110 'y')"
    run_relay "$(ask_json alpha)"
    assert_eq "0" "$RC" "answered (rc=$RC, err: $ERR)"
    assert_eq "1 and maybe 2" "$(answer_of 'Add the caveat to P4?')" "after y the claimed line is the answer (out: $OUT)"
    local ask; ask=$(grep -- 'was #105' "$MOCK_AFD_LOG")
    assert_contains "$ask" "notify all [alpha] was #105 for me? y / n / @project alone" "ask-back text names the project and message, and asks for the tag ALONE (log: $ask)"
    assert_contains "$ask" "--type info" "ask-back is an info notification, so a Telegram d cannot hit it (CFG-771c)"
    assert_not_contains "$ask" "--type permission" "never a permission notification"
    assert_eq "1" "$(notifies '[alpha] working on #105')" "the session confirms it is working on #105"
    assert_contains "$(cat "$MOCK_HOME/marker.hist")" " 101 claimed 105 106" "the marker carried the claim and the ask-back id while waiting for the verdict"
    pool_has 105 && r=1 || r=0; assert_eq "0" "$r" "the answer left the pool"
    pool_has 110 && r=1 || r=0; assert_eq "0" "$r" "the verdict line is consumed too"
    assert_eq "" "$(claim_owner 105)" "the claim is released"
}
run_test "two waiters: ask back as info, y takes the answer, confirm sent" test_two_waiters_ask_back_then_yes

test_two_waiters_n_releases_and_rejects() {
    setup_env
    other_waiter institute 90
    pending "$(msg 105 'add')"
    verdict "$(msg 110 'n')"
    HOOK_AFK_TIMEOUT=5 run_relay "$(ask_json alpha)"
    assert_eq "2" "$RC" "no answer: the relay keeps waiting until its timeout (rc=$RC)"
    assert_contains "$ERR" "No answer" "and reports the timeout (err: $ERR)"
    assert_file_contains "$POOL" '"rejected": \["alpha"\]' "n marks #105 rejected by alpha (pool: $(cat "$POOL"))"
    pool_has 110 && r=1 || r=0; assert_eq "0" "$r" "the verdict line is consumed"
    assert_eq "" "$(claim_owner 105)" "the claim is released for the other relay"
    assert_eq "0" "$(notifies 'working on')" "no confirmation"
    assert_eq "" "$(tail -1 "$MOCK_HOME/marker.hist" | cut -d' ' -f3-)" "the marker is back to '<pid> <question>' while waiting again"
}
run_test "two waiters: n releases the claim and marks the line rejected" test_two_waiters_n_releases_and_rejects

test_two_waiters_redirect_refiles() {
    setup_env
    other_waiter institute 90
    pending "$(msg 105 'add')"
    verdict "$(msg 110 '@institute')"
    HOOK_AFK_TIMEOUT=5 run_relay "$(ask_json alpha)"
    assert_eq "2" "$RC" "alpha keeps waiting (rc=$RC)"
    assert_file_contains "$AFD_MSG_DIR/institute.jsonl" '"add"' "the line is re-filed for institute"
    assert_file_contains "$AFD_MSG_DIR/institute.jsonl" '"redirected": true' "flagged redirected, so institute skips its own ask-back"
    pool_has 105 && r=1 || r=0; assert_eq "0" "$r" "and left the pool"
    pool_has 110 && r=1 || r=0; assert_eq "0" "$r" "the verdict line is consumed"
    assert_eq "0" "$(notifies 'working on')" "no confirmation from alpha"
}
run_test "two waiters: a project name re-files the line as redirected" test_two_waiters_redirect_refiles

test_verdict_by_hash_reference() {
    setup_env
    other_waiter institute 90
    pending "$(msg 105 'add')"
    verdict "$(msg 110 '#999 y')" "$(msg 111 '#106 y')"
    run_relay "$(ask_json alpha)"
    assert_eq "0" "$RC" "answered (rc=$RC, err: $ERR)"
    assert_eq "Add" "$(answer_of 'Add the caveat to P4?')" "the verdict naming #106 (our ask-back) confirms"
    pool_has 110 && r=0 || r=1; assert_eq "0" "$r" "a verdict naming another ask-back (#999) is left alone"
    pool_has 111 && r=1 || r=0; assert_eq "0" "$r" "ours is consumed"
}
run_test "verdict: '#C' in the text binds it to this ask-back; another #N is not ours" test_verdict_by_hash_reference

test_verdict_by_reply_to() {
    setup_env
    other_waiter institute 90
    pending "$(msg 105 'add')"
    verdict "$(msg 110 'yes' '"reply_to":106')"
    run_relay "$(ask_json alpha)"
    assert_eq "Add" "$(answer_of 'Add the caveat to P4?')" "a Telegram reply to the ask-back is its verdict (out: $OUT, err: $ERR)"
}
run_test "verdict: a reply_to the ask-back counts" test_verdict_by_reply_to

# ── Tier 0: a Telegram reply to the question itself needs no ask-back ────────

test_reply_to_question_is_tier0() {
    setup_env
    other_waiter institute 90
    pending "$(msg 105 'skip' '"reply_to":101')"
    run_relay "$(ask_json alpha)"
    assert_eq "Skip" "$(answer_of 'Add the caveat to P4?')" "reply_to == Q is taken directly (out: $OUT, err: $ERR)"
    assert_eq "0" "$(notifies 'was #')" "no ask-back for a reply to the question (decided 2026-10-25)"
}
run_test "tier 0: a reply to the question is taken without ask-back" test_reply_to_question_is_tier0

test_reply_to_question_preempts_handshake() {
    setup_env
    other_waiter institute 90
    pending "$(msg 105 'add')"
    verdict "$(msg 110 'skip' '"reply_to":101')"   # the user replies to the question while the ask-back is out
    run_relay "$(ask_json alpha)"
    assert_eq "Skip" "$(answer_of 'Add the caveat to P4?')" "the reply to the question wins over the pending ask-back (out: $OUT, err: $ERR)"
    assert_eq "" "$(claim_owner 105)" "the claim on the asked-about line is released"
    pool_has 105 && r=0 || r=1; assert_eq "0" "$r" "and that line stays pooled for the others"
    assert_eq "0" "$(notifies 'working on')" "a direct reply needs no confirmation"
}
run_test "tier 0: a reply to the question wins during a pending ask-back" test_reply_to_question_preempts_handshake

test_reply_to_other_question_is_not_ours() {
    setup_env
    other_waiter institute 90
    pending "$(msg 105 'skip' '"reply_to":90')"
    HOOK_AFK_TIMEOUT=4 run_relay "$(ask_json alpha)"
    assert_eq "2" "$RC" "a reply to institute's question is never alpha's answer (rc=$RC)"
    pool_has 105 && r=0 || r=1; assert_eq "0" "$r" "it stays pooled for institute"
    assert_eq "0" "$(notifies 'was #')" "and is not even asked about"
}
run_test "tier 0: a reply to another relay's question is left alone" test_reply_to_other_question_is_not_ours

# ── Tier 1 vs tier 2: fit and grace ──────────────────────────────────────────

test_tier2_waits_out_the_grace() {
    setup_env
    pending "$(msg 105 'yes to both')"   # two questions, one unmappable reply
    HOOK_AFK_TIMEOUT=12 ASK_GRACE=3 run_relay "$(ask2_json alpha)"
    assert_eq "2" "$RC" "unmappable: handed to the model as the block reason (rc=$RC)"
    assert_contains "$ERR" "yes to both" "with the reply text (err: $ERR)"
    [[ $TOOK -ge 3 ]] && r=0 || r=1
    assert_eq "0" "$r" "claimed only after the 3 s grace (took ${TOOK}s)"
}
run_test "tier 2: a reply that does not fit is claimed only after the grace" test_tier2_waits_out_the_grace

test_tier1_fit_is_immediate() {
    setup_env
    pending "$(msg 105 '2 3')"
    HOOK_AFK_TIMEOUT=12 ASK_GRACE=8 run_relay "$(ask2_json alpha)"
    assert_eq "A2" "$(answer_of 'Q one?')" "one token per question maps (out: $OUT)"
    assert_eq "B3" "$(answer_of 'Q two?')" "second token"
    [[ $TOOK -lt 8 ]] && r=0 || r=1
    assert_eq "0" "$r" "a fitting reply is claimed before the grace (took ${TOOK}s)"
}
run_test "tier 1: a reply that fits the question is claimed at once" test_tier1_fit_is_immediate

# ── Claims: another relay's live claim and its pending verdict are untouchable ─

test_other_relays_claim_and_verdict_untouched() {
    setup_env
    other_waiter institute 90 "claimed 105 106"
    mkdir -p "$AFD_MSG_DIR/.claims/105"; echo "$$ institute" > "$AFD_MSG_DIR/.claims/105/owner"
    pending "$(msg 105 'add')" "$(msg 110 'n')"
    HOOK_AFK_TIMEOUT=4 run_relay "$(ask_json alpha)"
    assert_eq "2" "$RC" "alpha finds nothing it may take (rc=$RC, err: $ERR)"
    assert_eq "$$ institute" "$(claim_owner 105)" "institute's live claim stands"
    pool_has 110 && r=0 || r=1; assert_eq "0" "$r" "institute's pending verdict 'n' (#110 > its ask-back #106) is not taken as alpha's answer"
    assert_eq "0" "$(notifies 'was #')" "alpha asks about nothing"
}
run_test "claims: a live claim and the verdict it awaits belong to the other relay" test_other_relays_claim_and_verdict_untouched

test_dead_claim_is_reaped() {
    setup_env
    local dead; sleep 0 & dead=$!; wait "$dead"
    mkdir -p "$AFD_MSG_DIR/.claims/105"; echo "$dead institute" > "$AFD_MSG_DIR/.claims/105/owner"
    pending "$(msg 105 'skip')"
    run_relay "$(ask_json alpha)"
    assert_eq "Skip" "$(answer_of 'Add the caveat to P4?')" "a claim whose relay died is reaped and the line taken (out: $OUT, err: $ERR)"
    assert_eq "" "$(claim_owner 105)" "no claim left behind"
}
run_test "claims: a dead relay's claim is reaped" test_dead_claim_is_reaped

test_askback_send_failure_releases_claim() {
    setup_env
    other_waiter institute 90
    pending "$(msg 105 'add')"
    HOOK_AFK_TIMEOUT=4 run_relay "$(ask_json alpha)" env MOCK_ASKBACK_FAIL=1
    assert_eq "2" "$RC" "no verdict can come: the relay times out (rc=$RC)"
    assert_eq "" "$(claim_owner 105)" "a failed ask-back releases the claim"
    pool_has 105 && r=0 || r=1; assert_eq "0" "$r" "the line stays pooled for a retry or the other relay"
    assert_eq "0" "$(notifies 'working on')" "nothing was taken"
}
run_test "ask-back: a failed send releases the claim and keeps the line" test_askback_send_failure_releases_claim

# ── Redirected lines and tagged answers ──────────────────────────────────────

test_redirected_line_taken_without_askback() {
    setup_env
    other_waiter institute 90
    mkdir -p "$AFD_MSG_DIR"; echo "$(msg 105 'add' '"redirected":true')" > "$AFD_MSG_DIR/alpha.jsonl"
    run_relay "$(ask_json alpha)"
    assert_eq "Add" "$(answer_of 'Add the caveat to P4?')" "a line the user redirected here is the answer (out: $OUT, err: $ERR)"
    assert_eq "0" "$(notifies 'was #')" "no second ask-back: the user already routed it"
    assert_eq "1" "$(notifies '[alpha] working on #105')" "but the session still confirms it is working"
}
run_test "redirected: taken without ask-back, confirmation sent" test_redirected_line_taken_without_askback

test_tagged_answer_wins_during_handshake() {
    setup_env
    other_waiter institute 90
    pending "$(msg 105 'add')"
    verdict "$(msg 110 '@alpha 2')"
    run_relay "$(ask_json alpha)"
    assert_eq "Skip" "$(answer_of 'Add the caveat to P4?')" "a tagged answer arriving mid-handshake wins (out: $OUT, err: $ERR)"
    assert_eq "" "$(claim_owner 105)" "the pending claim is released"
    pool_has 105 && r=0 || r=1; assert_eq "0" "$r" "the claimed line goes back to the pool for the others"
    assert_eq "0" "$(notifies 'working on')" "tagged answers need no confirmation"
}
run_test "a tagged answer during a handshake wins and releases the claim" test_tagged_answer_wins_during_handshake

# ── The 2026-10-24 incident, both ways round ─────────────────────────────────

test_incident_aiware_gets_its_answer() {
    SEQ0=482 setup_env                      # aiware's question becomes #483
    other_waiter institute 470
    pending "$(msg 484 '1 and maybe 2')"
    verdict "$(msg 486 'y')"
    run_relay "$(ask_json aiware)"
    assert_eq "1 and maybe 2" "$(answer_of 'Add the caveat to P4?')" "#484 answers aiware's #483 (out: $OUT, err: $ERR)"
    assert_eq "1" "$(notifies '[aiware] was #484 for me? y / n / @project')" "aiware asked back first, institute was waiting too"
    assert_eq "1" "$(notifies '[aiware] working on #484')" "and confirmed"
    assert_file_not_exists "$AFD_MSG_DIR/institute.jsonl" "nothing landed in institute's queue"
}
run_test "2026-10-24: aiware asks back and gets #484" test_incident_aiware_gets_its_answer

# ── Fable review 2026-10-25 (MERGE-AFTER-FIXES) ──────────────────────────────

# scan <mode> <pool line>... — the pool scan run directly for alpha (Q 101), with the ask-back
# state in ASK_M_SIM / ASK_C_SIM. Markers for OTHER relays must carry a live pid that is not
# this shell's: $PPID (the timeout/runner process) serves.
scan() {
    local mode="$1"; shift
    mkdir -p "$AFD_MSG_DIR"; printf '%s\n' "$@" > "$POOL"
    ( set +eu; export HOME="$MOCK_HOME"
      source "$REPO_ROOT/global/hooks/lib-afd-ask.sh"
      ME=alpha; NOTIF_ID=101; ASK_M="${ASK_M_SIM:-}"; ASK_C="${ASK_C_SIM:-}"; ASK_QN=1; AFD_ASK_GRACE=0
      _afd_ask_scan "$mode" )
}

# MAJOR 1: `known` is every dir under $HOME, and prefix / any-token matching read ordinary
# answers as redirects ("cru" -> cruncher, "add it to life" -> life). A verdict is now only a
# sole y/n token or a sole @tag.
test_verdict_parser_is_strict() {
    setup_env
    local p; for p in cruncher life go music; do mkdir -p "$MOCK_HOME/$p"; done
    mkdir -p "$AFD_MSG_DIR/.waiting"; echo "$$ 101 claimed 105 106" > "$AFD_MSG_DIR/.waiting/alpha"
    local txt got
    # Second pass A1: the ask-back grammar is "@project", so a bare project name ("go", "life")
    # is NOT a redirect — only an @tag is (exact or unique prefix, as routing resolves it).
    for txt in "cru" "add it to life" "music please" "inst" "2" "skip" "not for you" "no, institute" "yes please" "go" "life" "institute" "ok" "sure"; do
        got=$(ASK_M_SIM=105 ASK_C_SIM=106 scan verdict "$(msg 105 'add' '"pooled":1')" "$(msg 110 "$txt" '"pooled":1')")
        assert_eq "" "$got" "\"$txt\" is not a verdict (got: $got)"
    done
    local want
    for txt in "yes:yes -" "Y:yes -" "n:no -" "nope.:no -" "@institute:redirect institute" "@inst:redirect institute" "y #106:yes -" "y #105:yes -" "@institute #105:redirect institute"; do
        want="${txt#*:}"; txt="${txt%%:*}"
        got=$(ASK_M_SIM=105 ASK_C_SIM=106 scan verdict "$(msg 105 'add' '"pooled":1')" "$(msg 110 "$txt" '"pooled":1')")
        assert_eq "$want 110" "$got" "\"$txt\" is the verdict '$want' (got: $got)"
    done
    # An EXPLICIT reply to the ask-back (reply_to == C, or naming #C / #M) is classified by its
    # FIRST token: a yes-word (incl. ok, sure, yeah, correct, right, mine, jo, passt), a no-word
    # (incl. nah, nicht, not), an @project — and anything else is SKIPPED, left in place as
    # nobody's verdict (second pass A2; "yes please" as a reply must never be a no).
    for txt in "yes please:yes -" "nope, not mine:no -" "ja passt:yes -" "@institute thanks:redirect institute" "y #105 sure:yes -" "sure:yes -" "ok:yes -" "yeah:yes -" "correct:yes -" "mine:yes -" "jo:yes -" "nah:no -" "nicht meins:no -" "not mine:no -"; do
        want="${txt#*:}"; txt="${txt%%:*}"
        got=$(ASK_M_SIM=105 ASK_C_SIM=106 scan verdict "$(msg 105 'add' '"pooled":1')" "$(msg 110 "$txt" '"reply_to":106,"pooled":1')")
        assert_eq "$want 110" "$got" "explicit reply \"$txt\" is the verdict '$want' (got: $got)"
    done
    for txt in "maybe" "whatever" "that one is mine"; do
        got=$(ASK_M_SIM=105 ASK_C_SIM=106 scan verdict "$(msg 105 'add' '"pooled":1')" "$(msg 110 "$txt" '"reply_to":106,"pooled":1')")
        assert_eq "" "$got" "explicit reply \"$txt\" is skipped, not a no (got: $got)"
    done
    got=$(ASK_M_SIM=105 ASK_C_SIM=106 scan verdict "$(msg 105 'add' '"pooled":1')" "$(msg 110 'nope, not mine #106' '"pooled":1')")
    assert_eq "no - 110" "$got" "naming #C makes it explicit too (got: $got)"
    # An explicit skip must not hide a later real verdict in the same pool.
    got=$(ASK_M_SIM=105 ASK_C_SIM=106 scan verdict "$(msg 105 'add' '"pooled":1')" "$(msg 110 'maybe' '"reply_to":106,"pooled":1')" "$(msg 112 'y #105' '"pooled":1')")
    assert_eq "yes - 112" "$got" "a skipped explicit line does not shadow the real verdict behind it (got: $got)"
}
run_test "MAJOR 1: only a sole y / n / @tag / exact project name is a verdict" test_verdict_parser_is_strict

test_project_named_free_text_stays_pooled_during_askback() {
    setup_env
    mkdir -p "$MOCK_HOME/life"
    other_waiter institute 90
    pending "$(msg 105 'add')"
    verdict "$(msg 110 'add it to life')"
    HOOK_AFK_TIMEOUT=5 run_relay "$(ask_json alpha)"
    assert_eq "2" "$RC" "alpha keeps waiting: the free text is nobody's verdict (rc=$RC)"
    pool_has 110 && r=0 || r=1; assert_eq "0" "$r" "it stays pooled for its real owner"
    assert_file_not_exists "$AFD_MSG_DIR/life.jsonl" "and is not re-filed to a project it happens to mention"
    assert_file_not_contains "$POOL" '"rejected"' "nor read as a no"
}
run_test "MAJOR 1: a project-named free-text answer during an ask-back is left alone" test_project_named_free_text_stays_pooled_during_askback

# MAJOR 3 (decided 2026-10-25, "Require a target"): while two or more ask-backs are open, a bare
# verdict counts only as a Telegram reply to the ask-back or with the message number
# (y #105 — the hook knows M when it asks; #C is accepted too). The ask-back says so.
test_bare_verdict_needs_target_with_two_askbacks() {
    setup_env
    mkdir -p "$AFD_MSG_DIR/.waiting"
    echo "$$ 101 claimed 105 106" > "$AFD_MSG_DIR/.waiting/alpha"
    echo "$PPID 90 claimed 107 108" > "$AFD_MSG_DIR/.waiting/institute"
    local lines=("$(msg 105 'add' '"pooled":1')" "$(msg 107 'skip' '"pooled":1')")
    assert_eq "nudge - 110" "$(ASK_M_SIM=105 ASK_C_SIM=106 scan verdict "${lines[@]}" "$(msg 110 'y' '"pooled":1')")" "two ask-backs open: a bare y is nobody's verdict, only a nudge (A6)"
    assert_eq "nudge - 110" "$(ASK_M_SIM=105 ASK_C_SIM=106 scan verdict "${lines[@]}" "$(msg 110 '@aiware' '"pooled":1')")" "nor a bare @project"
    assert_eq "yes - 110" "$(ASK_M_SIM=105 ASK_C_SIM=106 scan verdict "${lines[@]}" "$(msg 110 'y #105' '"pooled":1')")" "y #M is alpha's"
    assert_eq "" "$(ASK_M_SIM=105 ASK_C_SIM=106 scan verdict "${lines[@]}" "$(msg 110 'y #107' '"pooled":1')")" "y #107 is institute's, not alpha's"
    assert_eq "yes - 110" "$(ASK_M_SIM=105 ASK_C_SIM=106 scan verdict "${lines[@]}" "$(msg 110 'y' '"reply_to":106,"pooled":1')")" "a Telegram reply to alpha's ask-back is alpha's"
    assert_eq "" "$(ASK_M_SIM= ASK_C_SIM= scan candidate "$(msg 110 'y' '"pooled":1')")" "and no relay may claim the bare y as an answer while an ask-back is open"
}
run_test "MAJOR 3: with two ask-backs open a bare verdict needs its target" test_bare_verdict_needs_target_with_two_askbacks

test_relay_ignores_bare_y_while_another_askback_is_open() {
    setup_env
    other_waiter institute 90 "claimed 95 96"
    mkdir -p "$AFD_MSG_DIR/.claims/95"; echo "$$ institute" > "$AFD_MSG_DIR/.claims/95/owner"
    pending "$(msg 105 'add')"
    verdict "$(msg 110 'y')"
    HOOK_AFK_TIMEOUT=5 run_relay "$(ask_json alpha)"
    assert_eq "2" "$RC" "alpha does not take a bare y while institute's ask-back is open (rc=$RC)"
    assert_eq "1" "$(notifies '[alpha] was #105 for me? y #105 / n #105 / @project #105')" "the ask-back asks for the number when another session is asking too"
    pool_has 110 && r=0 || r=1; assert_eq "0" "$r" "the bare y stays pooled"
    assert_eq "0" "$(notifies 'working on')" "nothing is taken"
    # Second pass A6: the orphan bare y earns one nudge per asked-about message, not one per poll.
    assert_eq "1" "$(notifies '[alpha] two sessions are asking - reply y #105 / n #105')" "one nudge names the numbered form (log: $(grep -c 'two sessions' "$MOCK_AFD_LOG" || true) over several polls)"
}
run_test "MAJOR 3: relay leaves a bare y alone while another ask-back is open, nudges once" test_relay_ignores_bare_y_while_another_askback_is_open

# Second pass A3: the atomic marker write leaves ".<project>.tmp.<pid>" in .waiting for an
# instant; a dot-name is never another relay's marker.
test_marker_temp_file_is_not_a_waiter() {
    setup_env
    mkdir -p "$AFD_MSG_DIR/.waiting"
    echo "$$ 101 claimed 105 106" > "$AFD_MSG_DIR/.waiting/alpha"
    echo "$PPID 90 claimed 107 108" > "$AFD_MSG_DIR/.waiting/.institute.tmp.99999"
    local got; got=$(ASK_M_SIM=105 ASK_C_SIM=106 scan verdict "$(msg 105 'add' '"pooled":1')" "$(msg 110 'y' '"pooled":1')")
    assert_eq "yes - 110" "$got" "a stray marker temp file does not count as an open ask-back (got: $got)"
}
run_test "A3: a marker temp file in .waiting is not another relay" test_marker_temp_file_is_not_a_waiter

# Second pass A5: with lib-afd-ask.sh unusable (here: lib-afd-scan.sh missing) the relay could
# never read a free-text answer; it must fail fast to the console instead of waiting an hour.
test_relay_fails_fast_without_the_answer_lib() {
    setup_env
    local d="$TEST_TMPDIR/hooks"; mkdir -p "$d"
    cp "$HOOK" "$REPO_ROOT/global/hooks/lib-afd-msg.sh" "$REPO_ROOT/global/hooks/lib-afd-pool.sh" "$REPO_ROOT/global/hooks/lib-afd-ask.sh" "$d/"
    local t0=$SECONDS rc=0
    HOME="$MOCK_HOME" AFD_AFK_TIMEOUT=30 AFD_AFK_POLL_INTERVAL=1 bash "$d/afd-relay.sh" < <(ask_json alpha) > "$TEST_TMPDIR/out" 2> "$TEST_TMPDIR/err" || rc=$?
    local took=$(( SECONDS - t0 ))
    assert_eq "2" "$rc" "exit 2 at once, not after the hour (rc=$rc)"
    [[ $took -le 3 ]] && r=0 || r=1
    assert_eq "0" "$r" "fails fast (took ${took}s)"
    assert_contains "$(cat "$TEST_TMPDIR/err")" "lib-afd-ask.sh" "names the broken library (err: $(cat "$TEST_TMPDIR/err"))"
    assert_eq "0" "$(notifies 'Question from Claude')" "and never sends a question it could not read the answer to"
}
run_test "A5: relay exits 2 at once when the answer library cannot load" test_relay_fails_fast_without_the_answer_lib

test_relay_takes_targeted_y_while_another_askback_is_open() {
    setup_env
    other_waiter institute 90 "claimed 95 96"
    mkdir -p "$AFD_MSG_DIR/.claims/95"; echo "$$ institute" > "$AFD_MSG_DIR/.claims/95/owner"
    pending "$(msg 105 'add')"
    verdict "$(msg 110 'y #105')"
    run_relay "$(ask_json alpha)"
    assert_eq "Add" "$(answer_of 'Add the caveat to P4?')" "y #105 confirms #105 for alpha (out: $OUT, err: $ERR)"
    assert_eq "1" "$(notifies '[alpha] working on #105')" "and alpha confirms"
}
run_test "MAJOR 3: y #M is taken while another ask-back is open" test_relay_takes_targeted_y_while_another_askback_is_open

test_three_waiters_one_askback() {
    setup_env
    other_waiter institute 90
    other_waiter aiware 95
    pending "$(msg 105 '1 and maybe 2')"
    verdict "$(msg 110 'y')"
    run_relay "$(ask_json alpha)"
    assert_eq "1 and maybe 2" "$(answer_of 'Add the caveat to P4?')" "three waiters, one ask-back: a bare y confirms (out: $OUT, err: $ERR)"
    assert_eq "1" "$(notifies '[alpha] was #105 for me? y / n / @project alone')" "one ask-back open: the plain form"
    assert_eq "1" "$(notifies '[alpha] working on #105')" "confirmed"
    assert_file_not_exists "$AFD_MSG_DIR/institute.jsonl" "institute untouched"
    assert_file_not_exists "$AFD_MSG_DIR/aiware.jsonl" "aiware untouched"
}
run_test "three waiters: one ask-back, bare y, the others untouched" test_three_waiters_one_askback

# MINOR 5: a pooled bare "@beta" (no text once the tag is stripped) was claimed, deleted and
# then found empty — consumed for nothing. A line without text is never an answer candidate.
test_empty_bare_tag_line_is_not_consumed() {
    setup_env
    mkdir -p "$AFD_MSG_DIR"; echo "$(msg 105 '@beta' '"pooled":1')" > "$POOL"
    pending "$(msg 107 'skip')"
    run_relay "$(ask_json alpha)"
    assert_eq "Skip" "$(answer_of 'Add the caveat to P4?')" "the real answer behind it is taken (out: $OUT, err: $ERR)"
    pool_has 105 && r=0 || r=1; assert_eq "0" "$r" "the bare @beta line is still pooled, not eaten"
    assert_eq "" "$(claim_owner 105)" "and not left claimed"
}
run_test "MINOR 5: a text-less bare-tag line is never consumed as an answer" test_empty_bare_tag_line_is_not_consumed

# MINOR 7: reply_to naming no live question or ask-back (e.g. a reply to the "working on"
# message) is an ordinary untagged line.
test_reply_to_nothing_live_is_untagged() {
    setup_env
    pending "$(msg 105 'skip' '"reply_to":77')"
    run_relay "$(ask_json alpha)"
    assert_eq "Skip" "$(answer_of 'Add the caveat to P4?')" "a reply to a message nobody waits on is claimed like an untagged line (out: $OUT, err: $ERR)"
}
run_test "MINOR 7: reply_to pointing at nothing live is treated as untagged" test_reply_to_nothing_live_is_untagged

test_incident_institute_redirects_to_aiware() {
    SEQ0=469 setup_env                      # institute's question becomes #470
    other_waiter aiware 483
    pending "$(msg 484 '1 and maybe 2')"
    verdict "$(msg 486 '@aiware')"
    HOOK_AFK_TIMEOUT=5 run_relay "$(ask_json institute)"
    assert_eq "2" "$RC" "institute does not take #484 (rc=$RC)"
    assert_eq "1" "$(notifies '[institute] was #484 for me? y / n / @project')" "it asked first"
    assert_file_contains "$AFD_MSG_DIR/aiware.jsonl" '"1 and maybe 2"' "and the user's @aiware sends #484 to aiware's queue"
    assert_file_contains "$AFD_MSG_DIR/aiware.jsonl" '"redirected": true' "as redirected"
    assert_eq "0" "$(notifies '[institute] working on')" "institute never claims to work on it"
}
run_test "2026-10-24: institute asks back and the user redirects #484 to aiware" test_incident_institute_redirects_to_aiware

suite_summary
