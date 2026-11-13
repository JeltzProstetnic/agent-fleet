#!/usr/bin/env bash
# CFG-911: the UserPromptSubmit detectors in context-budget.sh (LIVE_ISSUE_DETECTED,
# LRN_TRIGGERED) skip SCHEDULED fires — CronCreate tasks, ScheduleWakeup, /loop — and a
# scheduled fire never ends AFK in afk-deactivate.sh (CFG-770: only a typed "afk off" does).
#
# Measured 2026-11-13 (Claude Code 2.1.280):
# - A scheduled fire runs UserPromptSubmit (the hook_success rows follow the fire's user
#   row in the transcript), and its prompt is the task's prompt VERBATIM: 7 fires in
#   6 projects matched their CronCreate prompt byte for byte, each with its own opening
#   line ("22:07 wake-up", "It is 22:15.", "[Scheduled resume, …]", "NOON GPU HANDOFF"…).
#   There is no harness frame to test for. Only the transcript row says scheduled
#   (scheduledTaskId, turnOrigin "scheduled", promptSource "system", isMeta).
# - Claude Code's hook schema gives UserPromptSubmit an optional `source`
#   (user | sdk | system | loop_wakeup | schedule_wakeup | poll_event, "payloads may omit
#   it while the field rolls out"); the 2.1.280 builder compiles that spread out, so the
#   payload today is session_id, transcript_path, cwd, scratchpad_dir, prompt_id,
#   permission_mode, effort, hook_event_name, prompt, session_title.
# - The Stop payload does carry `session_crons: [{id, schedule, recurring, prompt}]`, the
#   prompt clipped at 1000 UTF-16 units plus "… [+N chars]". The Stop hook
#   (afd-idle-wake.sh) records those prompts and the prompt hook matches against them.
source "$(dirname "$0")/test-helpers.sh"

suite_header "CFG-911: detectors skip scheduled fires (payload source + Stop-recorded crons)"

HOOK_PATH="$REPO_ROOT/global/hooks/context-budget.sh"
WAKE_HOOK="$REPO_ROOT/global/hooks/afd-idle-wake.sh"

# A scheduled resume shaped like the real ones: over 1000 UTF-16 units (so the Stop payload
# clips it), astral characters before and after the cut (the one after it makes the clipped
# count "+N chars" differ between UTF-16 units and code points), and trigger words.
SCHED_HEAD="[Scheduled resume, the user's order relayed by the config session, 2026-10-27 22:15] Tokens have reset. Resume without MG. If the relay is stuck again or the overlay is hanging, capture it; there is a bug in the retry path. Run lrn on the planner afterwards. 🚀"
SCHED_LONG="$SCHED_HEAD$(printf ' Step %02d: run the health check, change nothing, file findings to docs/.' $(seq 1 30)) Done 🏁"
SCHED_SHORT="22:07 wake-up: the queue is stuck AGAIN, check the bug list and run lrn now."

# _ups_json <prompt> [source] [session_id] — the UserPromptSubmit payload Claude Code
# 2.1.280 builds, plus `source` when given (the shape the schema documents).
_ups_json() {
    python3 -c '
import json, sys
p, src, sid = sys.argv[1], sys.argv[2], sys.argv[3]
d = {"session_id": sid, "transcript_path": "/home/u/.claude/projects/-home-u-proj/%s.jsonl" % sid,
     "cwd": "/home/u/proj", "scratchpad_dir": "/tmp/claude-1000/-home-u-proj/%s/scratchpad" % sid,
     "prompt_id": "de0dd204-9103-4617-93ff-55c053d36de3", "permission_mode": "auto",
     "effort": {"level": "high"}, "hook_event_name": "UserPromptSubmit", "prompt": p}
if src:
    d["source"] = src
d["session_title"] = "proj"
print(json.dumps(d))' "$1" "${2-}" "${3:-sess-911}"
}

# _stop_json <session_id> [cron prompt]... — the Stop payload, session_crons clipped the way
# Claude Code clips them (first 1000 UTF-16 units, a dangling high surrogate dropped).
_stop_json() {
    python3 - "$@" << 'EOF'
import json, sys
sid, prompts = sys.argv[1], sys.argv[2:]
def clip(s, n=1000):
    u = s.encode("utf-16-le", "surrogatepass")
    if len(u) // 2 <= n:
        return s
    head = u[:2 * n]
    if 0xD800 <= int.from_bytes(head[-2:], "little") <= 0xDBFF:
        head = head[:-2]
    return "%s… [+%d chars]" % (head.decode("utf-16-le", "surrogatepass"), (len(u) - len(head)) // 2)
crons = [{"id": "c%d" % i, "schedule": "15 22 27 10 *", "recurring": False, "prompt": clip(p)}
         for i, p in enumerate(prompts)]
print(json.dumps({"session_id": sid, "transcript_path": "/home/u/.claude/projects/-home-u-proj/%s.jsonl" % sid,
                  "cwd": "/home/u/proj", "permission_mode": "auto", "hook_event_name": "Stop",
                  "stop_hook_active": False, "last_assistant_message": "Timer set for 22:15.",
                  "background_tasks": [], "session_crons": crons}))
EOF
}

# _record <stop-json> — the real Stop hook on that payload. No afd here, so it records the
# crons and exits before its idle wait.
_record() {
    local rc=0
    printf '%s' "$1" | bash "$WAKE_HOOK" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "the Stop hook exits 0 without afd" || return 1
}

# _run <payload> — context-budget.sh with a budget sidecar, so its normal line is present.
_run() {
    local sc="$TEST_TMPDIR/budget.json"
    echo '{"pct":30,"remaining":70,"size":1000000,"used_k":300}' > "$sc"
    printf '%s' "$1" | CONTEXT_BUDGET_PATH="$sc" MOBILE_REPO="$TEST_TMPDIR/no-repo" \
        CHECKPOINT_MARKER="$TEST_TMPDIR/.ckpt" bash "$HOOK_PATH" 2>/dev/null
}
_silent() {  # <label> <payload>
    local out; out=$(_run "$2")
    assert_not_contains "$out" "LIVE_ISSUE_DETECTED" "$1: live-issue detector must skip it (out: $out)" || return 1
    assert_not_contains "$out" "LRN_TRIGGERED" "$1: lrn detector must skip it (out: $out)" || return 1
    assert_contains "$out" "CONTEXT_BUDGET: 30%" "$1: the budget line stays (out: $out)" || return 1
}
_fires() {  # <label> <payload>
    local out; out=$(_run "$2")
    assert_contains "$out" "LIVE_ISSUE_DETECTED" "$1: live-issue detector must fire (out: $out)" || return 1
    assert_contains "$out" "LRN_TRIGGERED" "$1: lrn detector must fire (out: $out)" || return 1
}

# ── The payload's `source` field, once Claude Code sends it ──
test_source_schedule_wakeup_silent() {
    _silent "source=schedule_wakeup" "$(_ups_json "$SCHED_LONG" schedule_wakeup)"
}
run_test "source=schedule_wakeup: a scheduled fire fires no detector" test_source_schedule_wakeup_silent

test_source_machine_values_silent() {
    local s
    for s in loop_wakeup system poll_event; do
        _silent "source=$s" "$(_ups_json "$SCHED_SHORT" "$s")" || return 1
    done
}
run_test "source=loop_wakeup / system / poll_event fire no detector" test_source_machine_values_silent

test_source_user_values_fire() {
    local s
    for s in user sdk some_future_value; do
        _fires "source=$s" "$(_ups_json "the overlay is stuck again, lrn" "$s")" || return 1
    done
}
run_test "source=user / sdk / an unknown value: typed text still fires" test_source_user_values_fire

test_source_system_telegram_wake_fires() {
    local wake
    wake=$(printf '<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>\n<system-reminder>\nStop hook blocking error from command "Stop": %s\n\n</system-reminder>' \
        $'=== Telegram message(s) for this project (woke this idle session, CFG-777) ===\n[2026-11-13 21:17] (persona: Sam) @proj the overlay is stuck again, lrn\nReply via: afd notify all "[proj] your reply" --channel telegram\n===')
    _fires "source=system idle wake" "$(_ups_json "$wake" system)"
}
run_test "source=system: the user's Telegram lines in an idle wake still fire" test_source_system_telegram_wake_fires

# ── Claude Code 2.1.280: no `source`; the Stop hook's session_crons identify the fire ──
test_recorded_long_fire_silent() {
    _fires "before any Stop records the cron" "$(_ups_json "$SCHED_LONG")" || return 1
    _record "$(_stop_json sess-911 "$SCHED_LONG")" || return 1
    _silent "recorded scheduled fire (clipped in the Stop payload)" "$(_ups_json "$SCHED_LONG")" || return 1
}
run_test "no source: a long scheduled fire recorded by the Stop hook fires nothing" test_recorded_long_fire_silent

test_recorded_short_fire_silent() {
    _record "$(_stop_json sess-911 "the overlay is fine" "$SCHED_SHORT")" || return 1
    _silent "recorded short scheduled fire" "$(_ups_json "$SCHED_SHORT")" || return 1
}
run_test "no source: a short (unclipped) scheduled fire fires nothing" test_recorded_short_fire_silent

test_record_is_per_session() {
    _record "$(_stop_json sess-911 "$SCHED_SHORT")" || return 1
    _fires "the same text in another session" "$(_ups_json "$SCHED_SHORT" "" sess-other)" || return 1
}
run_test "no source: a cron of one session does not silence another session" test_record_is_per_session

test_user_text_with_crons_fires() {
    _record "$(_stop_json sess-911 "$SCHED_LONG" "$SCHED_SHORT")" || return 1
    _fires "typed text in a session with crons" "$(_ups_json "the overlay is stuck again, lrn")" || return 1
    _fires "typed text sharing the clipped prefix, longer" "$(_ups_json "$SCHED_LONG and one more line")" || return 1
    _fires "typed text sharing the clipped prefix, shorter" "$(_ups_json "${SCHED_LONG% Step 30*}")" || return 1
    _fires "a short cron's text with more appended" "$(_ups_json "$SCHED_SHORT really")" || return 1
}
run_test "no source: typed text still fires, even when it shares a cron's opening" test_user_text_with_crons_fires

test_stop_without_crons_clears() {
    _record "$(_stop_json sess-911 "$SCHED_SHORT")" || return 1
    _record "$(_stop_json sess-911)" || return 1
    _fires "after a Stop with no crons left" "$(_ups_json "$SCHED_SHORT")" || return 1
    assert_eq "" "$(ls -A "$HOME/.claude/.session-crons" 2>/dev/null)" "no record is left behind" || return 1
}
run_test "no source: a Stop with no crons clears the record" test_stop_without_crons_clears

test_stop_without_field_records_nothing() {
    _record '{"session_id":"sess-911","cwd":"/home/u/proj","hook_event_name":"Stop","stop_hook_active":false}' || return 1
    _record 'not json' || return 1
    _fires "Stop payloads without session_crons" "$(_ups_json "$SCHED_SHORT")" || return 1
}
run_test "no source: a Stop payload without session_crons records nothing, exits 0" test_stop_without_field_records_nothing

# Portable (GNU and BSD alike; `touch -d` and `stat -c` are GNU-only): python3 is
# already required by the hooks under test.
_age_days() {  # <file> <days> — set its mtime that many days back
    python3 -c 'import os, sys, time; t = time.time() - float(sys.argv[2]) * 86400; os.utime(sys.argv[1], (t, t))' "$1" "$2"
}
_mode_of() {  # <file> — permission bits in octal, e.g. 600
    python3 -c 'import os, stat, sys; print("%o" % stat.S_IMODE(os.stat(sys.argv[1]).st_mode))' "$1" 2>/dev/null
}

test_dead_session_records_pruned() {
    local dir="$HOME/.claude/.session-crons"
    mkdir -p "$dir"
    echo '["old"]' > "$dir/sess-dead.json"; _age_days "$dir/sess-dead.json" 9
    echo '["recent"]' > "$dir/sess-idle.json"; _age_days "$dir/sess-idle.json" 2
    _record "$(_stop_json sess-911 "$SCHED_SHORT")" || return 1
    assert_file_not_exists "$dir/sess-dead.json" "a record untouched for 9 days is pruned" || return 1
    assert_file_exists "$dir/sess-idle.json" "a 2-day-old record survives" || return 1
    assert_file_exists "$dir/sess-911.json" "this session's record is written" || return 1
    assert_eq "600" "$(_mode_of "$dir/sess-911.json")" "the record is owner-only, like the transcripts" || return 1
}
run_test "no source: records of long-dead sessions are pruned" test_dead_session_records_pruned

# ── afk-deactivate.sh: a scheduled fire never ends AFK (CFG-770 x CFG-911) ──
AFK_HOOK="$REPO_ROOT/global/hooks/afk-deactivate.sh"
AFK_CRON="night run: afk off is forbidden, keep working through the queue and the bug list."

# _afk <payload> [hook] — the AFK hook on that payload, with no afd CLI and no live afd env.
_afk() {
    printf '%s' "$1" | env -u AFD_URL -u AFD_TOKEN -u AFD_PROJECT_ROOTS AFD_MSG_DIR="$HOME/.afd-msgs" \
        bash "${2:-$AFK_HOOK}" 2>&1
}
_afk_kept() {  # <label> <payload> [hook]
    local out; touch "$HOME/.afd-afk"; out=$(_afk "$2" "${3-}")
    assert_file_exists "$HOME/.afd-afk" "$1: AFK stays on (out: $out)" || return 1
    assert_not_contains "$out" "AFK mode deactivated" "$1: nothing claims AFK ended (out: $out)" || return 1
}
_afk_ended() {  # <label> <payload> [hook]
    local out; touch "$HOME/.afd-afk"; out=$(_afk "$2" "${3-}")
    assert_file_not_exists "$HOME/.afd-afk" "$1: AFK ends (out: $out)" || return 1
    assert_contains "$out" "AFK mode deactivated" "$1: the model is told (out: $out)" || return 1
}

test_afk_recorded_fire_keeps_afk() {
    _record "$(_stop_json sess-911 "$AFK_CRON")" || return 1
    _afk_kept "recorded scheduled fire quoting 'afk off'" "$(_ups_json "$AFK_CRON")" || return 1
}
run_test "afk: a recorded scheduled fire quoting 'afk off' does not end AFK" test_afk_recorded_fire_keeps_afk

test_afk_machine_source_keeps_afk() {
    local s
    for s in schedule_wakeup loop_wakeup system poll_event; do
        _afk_kept "source=$s" "$(_ups_json "$AFK_CRON" "$s")" || return 1
    done
}
run_test "afk: a machine-injected source quoting 'afk off' does not end AFK" test_afk_machine_source_keeps_afk

test_afk_typed_off_still_ends() {
    _record "$(_stop_json sess-911 "$AFK_CRON")" || return 1
    _afk_ended "typed in a session with crons" "$(_ups_json "afk off, I'm back")" || return 1
    _afk_ended "source=user" "$(_ups_json "afk off, I'm back" user)" || return 1
}
run_test "afk: a typed 'afk off' still ends AFK in a session with crons" test_afk_typed_off_still_ends

# ── A partial deploy: lib-hook-stdin.sh one version older (text tests only, no payload
#    functions) next to the new hooks. The text tests still apply, as before this lib grew.
_older_lib_dir() {
    local d="$TEST_TMPDIR/hooks-older-lib" h="$REPO_ROOT/global/hooks"
    mkdir -p "$d"
    cp "$HOOK_PATH" "$AFK_HOOK" "$h/lib-portable.sh" "$h/lib-afd-msg.sh" "$h/lib-afd-pool.sh" "$d/"
    { cat "$h/lib-hook-stdin.sh"; echo 'unset -f hook_prompt_user_text hook_prompt_is_synthetic'; } > "$d/lib-hook-stdin.sh"
    echo "$d"
}

test_older_lib_detectors_skip_handback() {
    local d out sc="$TEST_TMPDIR/budget.json" handback
    d=$(_older_lib_dir)
    handback=$'<agent-message from="a1">\n[Subagent hand-back] the overlay is stuck, bug found, lrn\n</agent-message>'
    echo '{"pct":30,"remaining":70,"size":1000000,"used_k":300}' > "$sc"
    out=$(_ups_json "$handback" | CONTEXT_BUDGET_PATH="$sc" MOBILE_REPO="$TEST_TMPDIR/no-repo" \
        CHECKPOINT_MARKER="$TEST_TMPDIR/.ckpt" bash "$d/context-budget.sh" 2>/dev/null)
    assert_contains "$out" "CONTEXT_BUDGET: 30%" "the budget line stays (out: $out)" || return 1
    assert_not_contains "$out" "LIVE_ISSUE_DETECTED" "older lib: a hand-back fires no live-issue detector (out: $out)" || return 1
    assert_not_contains "$out" "LRN_TRIGGERED" "older lib: a hand-back fires no lrn detector (out: $out)" || return 1
    out=$(_ups_json "the overlay is stuck again, lrn" | CONTEXT_BUDGET_PATH="$sc" MOBILE_REPO="$TEST_TMPDIR/no-repo" \
        CHECKPOINT_MARKER="$TEST_TMPDIR/.ckpt" bash "$d/context-budget.sh" 2>/dev/null)
    assert_contains "$out" "LIVE_ISSUE_DETECTED" "older lib: typed text still fires (out: $out)" || return 1
}
run_test "older lib-hook-stdin.sh: the detectors still skip a hand-back, typed text fires" test_older_lib_detectors_skip_handback

test_older_lib_afk() {
    local d; d=$(_older_lib_dir)
    _afk_kept "older lib, hand-back quoting 'afk off'" \
        "$(_ups_json $'<agent-message from="a1">\n[Subagent hand-back] The user said afk off earlier.\n</agent-message>')" "$d/afk-deactivate.sh" || return 1
    _afk_ended "older lib, typed" "$(_ups_json "afk off, I'm back")" "$d/afk-deactivate.sh" || return 1
}
run_test "older lib-hook-stdin.sh: a hand-back keeps AFK, a typed 'afk off' ends it" test_older_lib_afk

# ── The suites reach the template (CFG-497/CFG-614): a guarded file with no manifest row
#    aborts every template-push, and a leak-gate hit holds the file. cfg only: neither the
#    push conf nor the manifest ships downstream.
_leak_hits() {  # <repo-relative file> — the shared leak gate's hits, with the push conf's patterns
    local pp; pp=$(grep '^personal_patterns=' "$REPO_ROOT/setup/config/template-push.conf" | head -1)
    ( source "$REPO_ROOT/setup/scripts/lib-leak-gate.sh" && check_leaks "${pp#personal_patterns=}" "$REPO_ROOT/$1" )
}
test_cfg911_suites_reach_template() {
    local f hits rc
    for f in setup/tests/test-hook-prompt-source.sh setup/tests/test-context-budget.sh; do
        grep -q "^| \`$f\` |" "$REPO_ROOT/template-sync-manifest.md" \
            || { echo "    $f has no row in template-sync-manifest.md" >&2; return 1; }
        rc=0; hits=$(_leak_hits "$f" 2>&1) || rc=$?
        assert_eq "0" "$rc" "$f passes the leak gate (hits: $hits)" || return 1
    done
}
if [[ -f "$REPO_ROOT/setup/config/template-push.conf" && -f "$REPO_ROOT/template-sync-manifest.md" \
      && -f "$REPO_ROOT/setup/scripts/lib-leak-gate.sh" ]]; then
    run_test "the CFG-911 suites have manifest rows and pass the leak gate" test_cfg911_suites_reach_template
else
    skip_test "the CFG-911 suites have manifest rows and pass the leak gate" "no template-push conf here (downstream copy)"
fi

suite_summary
