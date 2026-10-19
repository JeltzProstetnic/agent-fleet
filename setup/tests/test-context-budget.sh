#!/usr/bin/env bash
# Tests for context budget feature:
# 1. statusline.sh writes sidecar file ~/.claude/.context-budget.json
# 2. hooks/context-budget.sh reads sidecar and outputs budget line for additionalContext
source "$(dirname "$0")/test-helpers.sh"

suite_header "context-budget"

STATUSLINE_PATH="$REPO_ROOT/setup/config/statusline-command.sh"
# Statusline-dependent tests skip when the script is absent (from the template's suite).
run_sl_test() {
    if [[ -f "$STATUSLINE_PATH" ]]; then run_test "$@"; else skip_test "$1" "statusline-command.sh not found"; fi
}
HOOK_PATH="$REPO_ROOT/global/hooks/context-budget.sh"
TMPDIR_CB=$(mktemp -d)
SIDECAR="$TMPDIR_CB/.context-budget.json"

cleanup_cb() {
    rm -rf "$TMPDIR_CB"
}
trap cleanup_cb EXIT

# Build statusline JSON input
make_json() {
    local model="${1:-Opus 4.6}"
    local pct="${2:-54}"
    local win="${3:-200000}"
    local input_tok="${4:-50000}"
    local cache_create="${5:-30000}"
    local cache_read="${6:-28000}"
    printf '{"model":{"display_name":"%s"},"context_window":{"used_percentage":%s,"context_window_size":%s,"current_usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}' \
        "$model" "$pct" "$win" "$input_tok" "$cache_create" "$cache_read"
}

# ── Statusline sidecar tests ──────────────────────────────────────────────

test_sidecar_created() {
    rm -f "$SIDECAR"
    CONTEXT_BUDGET_PATH="$SIDECAR" echo "$(make_json "TestModel" 54)" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" bash "$STATUSLINE_PATH" >/dev/null
    assert_file_exists "$SIDECAR" "statusline should create sidecar file"
}
run_sl_test "statusline creates sidecar file" test_sidecar_created

test_sidecar_contains_pct() {
    rm -f "$SIDECAR"
    CONTEXT_BUDGET_PATH="$SIDECAR" echo "$(make_json "TestModel" 54)" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" bash "$STATUSLINE_PATH" >/dev/null
    local pct
    pct=$(python3 -c "import json; print(json.load(open('$SIDECAR'))['pct'])")
    assert_eq "54" "$pct" "sidecar pct should be 54"
}
run_sl_test "sidecar contains correct percentage" test_sidecar_contains_pct

test_sidecar_contains_remaining() {
    rm -f "$SIDECAR"
    CONTEXT_BUDGET_PATH="$SIDECAR" echo "$(make_json "TestModel" 54)" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" bash "$STATUSLINE_PATH" >/dev/null
    local rem
    rem=$(python3 -c "import json; print(json.load(open('$SIDECAR'))['remaining'])")
    assert_eq "46" "$rem" "sidecar remaining should be 46"
}
run_sl_test "sidecar contains remaining percentage" test_sidecar_contains_remaining

test_sidecar_contains_size() {
    rm -f "$SIDECAR"
    CONTEXT_BUDGET_PATH="$SIDECAR" echo "$(make_json "TestModel" 54 200000)" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" bash "$STATUSLINE_PATH" >/dev/null
    local sz
    sz=$(python3 -c "import json; print(json.load(open('$SIDECAR'))['size'])")
    assert_eq "200000" "$sz" "sidecar size should be 200000"
}
run_sl_test "sidecar contains window size" test_sidecar_contains_size

test_sidecar_contains_used_k() {
    rm -f "$SIDECAR"
    CONTEXT_BUDGET_PATH="$SIDECAR" echo "$(make_json "TestModel" 54 200000)" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" bash "$STATUSLINE_PATH" >/dev/null
    local used_k
    used_k=$(python3 -c "import json; print(json.load(open('$SIDECAR'))['used_k'])")
    assert_eq "108" "$used_k" "sidecar used_k should be 108"
}
run_sl_test "sidecar contains used_k" test_sidecar_contains_used_k

test_sidecar_zero_usage() {
    rm -f "$SIDECAR"
    CONTEXT_BUDGET_PATH="$SIDECAR" echo "$(make_json "Test" 0 200000 0 0 0)" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" bash "$STATUSLINE_PATH" >/dev/null
    local pct
    pct=$(python3 -c "import json; print(json.load(open('$SIDECAR'))['pct'])")
    assert_eq "0" "$pct" "sidecar pct should be 0 at zero usage"
}
run_sl_test "sidecar at zero usage" test_sidecar_zero_usage

test_sidecar_high_usage() {
    rm -f "$SIDECAR"
    CONTEXT_BUDGET_PATH="$SIDECAR" echo "$(make_json "Test" 92 200000 92000 0 0)" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" bash "$STATUSLINE_PATH" >/dev/null
    local pct
    pct=$(python3 -c "import json; print(json.load(open('$SIDECAR'))['pct'])")
    assert_eq "92" "$pct" "sidecar pct should be 92"
}
run_sl_test "sidecar at high usage" test_sidecar_high_usage

test_sidecar_no_crash_on_invalid() {
    rm -f "$SIDECAR"
    CONTEXT_BUDGET_PATH="$SIDECAR" echo "not json" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" bash "$STATUSLINE_PATH" >/dev/null
    # Sidecar should NOT be created on invalid input
    assert_file_not_exists "$SIDECAR" "sidecar should not be created for invalid input"
}
run_sl_test "no sidecar on invalid input" test_sidecar_no_crash_on_invalid

# ── Hook tests ─────────────────────────────────────────────────────────────

test_hook_outputs_budget_line() {
    echo '{"pct":54,"remaining":46,"size":200000,"used_k":108}' > "$SIDECAR"
    local output
    output=$(CONTEXT_BUDGET_PATH="$SIDECAR" bash "$HOOK_PATH")
    assert_contains "$output" "CONTEXT_BUDGET:" "hook should output CONTEXT_BUDGET tag"
    assert_contains "$output" "54%" "hook should include percentage"
    assert_contains "$output" "108k/200k" "hook should include used/total"
}
run_test "hook outputs budget line from sidecar" test_hook_outputs_budget_line

test_hook_no_sidecar() {
    local output
    output=$(CONTEXT_BUDGET_PATH="$TMPDIR_CB/nonexistent.json" bash "$HOOK_PATH")
    assert_eq "" "$output" "hook should produce no output when sidecar missing"
}
run_test "hook silent when sidecar missing" test_hook_no_sidecar

test_hook_corrupt_sidecar() {
    echo "not json" > "$SIDECAR"
    local output
    output=$(CONTEXT_BUDGET_PATH="$SIDECAR" bash "$HOOK_PATH" 2>/dev/null)
    assert_eq "" "$output" "hook should produce no output on corrupt sidecar"
}
run_test "hook silent on corrupt sidecar" test_hook_corrupt_sidecar

test_hook_warning_at_70pct() {
    echo '{"pct":72,"remaining":28,"size":200000,"used_k":144}' > "$SIDECAR"
    local output
    output=$(CONTEXT_BUDGET_PATH="$SIDECAR" bash "$HOOK_PATH")
    assert_contains "$output" "144k/200k" "hook should show usage at 72%"
}
run_test "hook at 70%+ usage" test_hook_warning_at_70pct

test_hook_warning_at_90pct() {
    echo '{"pct":92,"remaining":8,"size":200000,"used_k":184}' > "$SIDECAR"
    local output
    output=$(CONTEXT_BUDGET_PATH="$SIDECAR" bash "$HOOK_PATH")
    assert_contains "$output" "184k/200k" "hook should show usage at 92%"
}
run_test "hook at 90%+ usage" test_hook_warning_at_90pct

# ── CFG-178: Context checkpoint nudge at >70% ─────────────────────────────

test_checkpoint_nudge_at_72pct() {
    echo '{"pct":72,"remaining":28,"size":200000,"used_k":144}' > "$SIDECAR"
    local marker="$TMPDIR_CB/.ckpt-72"
    rm -f "$marker"
    local output
    output=$(CONTEXT_BUDGET_PATH="$SIDECAR" CHECKPOINT_MARKER="$marker" bash "$HOOK_PATH")
    assert_contains "$output" "CHECKPOINT_NEEDED" "hook should emit CHECKPOINT_NEEDED at 72%"
    rm -f "$marker"
}
run_test "checkpoint nudge at 72%" test_checkpoint_nudge_at_72pct

test_no_checkpoint_nudge_at_60pct() {
    echo '{"pct":60,"remaining":40,"size":200000,"used_k":120}' > "$SIDECAR"
    local marker="$TMPDIR_CB/.ckpt-60"
    rm -f "$marker"
    local output
    output=$(CONTEXT_BUDGET_PATH="$SIDECAR" CHECKPOINT_MARKER="$marker" bash "$HOOK_PATH")
    assert_not_contains "$output" "CHECKPOINT_NEEDED" "hook should NOT emit CHECKPOINT_NEEDED at 60%"
}
run_test "no checkpoint nudge at 60%" test_no_checkpoint_nudge_at_60pct

test_checkpoint_nudge_at_85pct() {
    echo '{"pct":85,"remaining":15,"size":200000,"used_k":170}' > "$SIDECAR"
    local marker="$TMPDIR_CB/.ckpt-85"
    rm -f "$marker"
    local output
    output=$(CONTEXT_BUDGET_PATH="$SIDECAR" CHECKPOINT_MARKER="$marker" bash "$HOOK_PATH")
    assert_contains "$output" "CHECKPOINT_NEEDED" "hook should emit CHECKPOINT_NEEDED at 85%"
    rm -f "$marker"
}
run_test "checkpoint nudge at 85%" test_checkpoint_nudge_at_85pct

test_checkpoint_nudge_not_repeated() {
    echo '{"pct":75,"remaining":25,"size":200000,"used_k":150}' > "$SIDECAR"
    local marker="$TMPDIR_CB/.checkpoint-nudged"
    # First call: should emit
    local out1
    out1=$(CONTEXT_BUDGET_PATH="$SIDECAR" CHECKPOINT_MARKER="$marker" bash "$HOOK_PATH")
    assert_contains "$out1" "CHECKPOINT_NEEDED" "first call should emit nudge"
    # Second call: should NOT emit (marker exists)
    local out2
    out2=$(CONTEXT_BUDGET_PATH="$SIDECAR" CHECKPOINT_MARKER="$marker" bash "$HOOK_PATH")
    assert_not_contains "$out2" "CHECKPOINT_NEEDED" "second call should suppress nudge (marker exists)"
    rm -f "$marker"
}
run_test "checkpoint nudge fires once then suppressed" test_checkpoint_nudge_not_repeated

test_checkpoint_marker_cleared_on_low_pct() {
    local marker="$TMPDIR_CB/.checkpoint-nudged"
    touch "$marker"
    echo '{"pct":30,"remaining":70,"size":1000000,"used_k":300}' > "$SIDECAR"
    CONTEXT_BUDGET_PATH="$SIDECAR" CHECKPOINT_MARKER="$marker" bash "$HOOK_PATH" >/dev/null
    assert_file_not_exists "$marker" "marker should be cleared when pct drops below threshold (post-compact)"
}
run_test "checkpoint marker cleared after compaction (low pct)" test_checkpoint_marker_cleared_on_low_pct

# ── CFG-31b: Mid-session mobile branch check ──────────────────────────────

test_mobile_check_detects_new_branches() {
    # Set up fake mobile repo with a claude/* branch
    local fake_mobile="$TMPDIR_CB/agent-fleet-mobile"
    mkdir -p "$fake_mobile"
    git -C "$fake_mobile" init -q
    git -C "$fake_mobile" commit --allow-empty -m "init" -q
    git -C "$fake_mobile" checkout -b "claude/test-branch-abc" -q
    git -C "$fake_mobile" commit --allow-empty -m "mobile session" -q
    git -C "$fake_mobile" checkout main -q 2>/dev/null || git -C "$fake_mobile" checkout master -q 2>/dev/null

    local output
    output=$(CONTEXT_BUDGET_PATH="$SIDECAR" MOBILE_REPO="$fake_mobile" MOBILE_CHECK_INTERVAL=0 bash "$HOOK_PATH")
    assert_contains "$output" "MOBILE_DATA" "hook should detect unmerged claude/* branch"
}
run_test "mobile check detects unmerged claude/* branches" test_mobile_check_detects_new_branches

test_mobile_check_no_branches() {
    local fake_mobile="$TMPDIR_CB/agent-fleet-mobile-clean"
    mkdir -p "$fake_mobile"
    git -C "$fake_mobile" init -q
    git -C "$fake_mobile" commit --allow-empty -m "init" -q

    local output
    output=$(CONTEXT_BUDGET_PATH="$SIDECAR" MOBILE_REPO="$fake_mobile" MOBILE_CHECK_INTERVAL=0 bash "$HOOK_PATH" 2>/dev/null)
    assert_not_contains "$output" "MOBILE_DATA" "hook should not emit MOBILE_DATA when no claude branches"
}
run_test "mobile check silent when no claude branches" test_mobile_check_no_branches

test_mobile_check_timer_gate() {
    local fake_mobile="$TMPDIR_CB/agent-fleet-mobile-timer"
    mkdir -p "$fake_mobile"
    git -C "$fake_mobile" init -q
    git -C "$fake_mobile" commit --allow-empty -m "init" -q
    git -C "$fake_mobile" checkout -b "claude/timer-test" -q
    git -C "$fake_mobile" commit --allow-empty -m "mobile" -q
    git -C "$fake_mobile" checkout main -q 2>/dev/null || git -C "$fake_mobile" checkout master -q 2>/dev/null

    # Create a recent marker (should suppress check)
    local marker="$TMPDIR_CB/.mobile-last-check"
    touch "$marker"

    local output
    output=$(CONTEXT_BUDGET_PATH="$SIDECAR" MOBILE_REPO="$fake_mobile" MOBILE_CHECK_MARKER="$marker" MOBILE_CHECK_INTERVAL=600 bash "$HOOK_PATH" 2>/dev/null)
    assert_not_contains "$output" "MOBILE_DATA" "hook should skip mobile check when marker is fresh"
    rm -f "$marker"
}
run_test "mobile check respects timer gate" test_mobile_check_timer_gate

test_mobile_check_no_repo() {
    local output
    output=$(CONTEXT_BUDGET_PATH="$SIDECAR" MOBILE_REPO="$TMPDIR_CB/nonexistent-repo" MOBILE_CHECK_INTERVAL=0 bash "$HOOK_PATH" 2>/dev/null)
    assert_not_contains "$output" "MOBILE_DATA" "hook should be silent when mobile repo doesn't exist"
}
run_test "mobile check silent when repo missing" test_mobile_check_no_repo

# ── CFG-389: Live-issue trigger phrase detection ──────────────────────────

# Shared stdin template — the REAL Claude Code UserPromptSubmit shape: the user text is
# `.prompt` (afk-deactivate.sh reads it and is proven live). These tests used `.message`
# until 2026-10-19, so they passed while the hook never fired in a real session.
_live_issue_stdin() {
    printf '{"session_id":"t","hook_event_name":"UserPromptSubmit","cwd":"/tmp","prompt":"%s"}' "$1"
}

test_live_issue_stuck_phrase() {
    local output
    output=$(_live_issue_stdin "the session is stuck in the overlay right now" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" MOBILE_REPO="$TMPDIR_CB/nonexistent-repo" \
        bash "$HOOK_PATH" 2>/dev/null)
    assert_contains "$output" "LIVE_ISSUE_DETECTED" "hook should detect 'is stuck' as live-issue trigger"
}
run_test "live-issue: 'is stuck' triggers detection" test_live_issue_stuck_phrase

test_live_issue_hanging_phrase() {
    local output
    output=$(_live_issue_stdin "the overlay is hanging and won't respond" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" MOBILE_REPO="$TMPDIR_CB/nonexistent-repo" \
        bash "$HOOK_PATH" 2>/dev/null)
    assert_contains "$output" "LIVE_ISSUE_DETECTED" "hook should detect 'is hanging' and 'won't respond'"
}
run_test "live-issue: 'hanging' / 'won't respond' triggers detection" test_live_issue_hanging_phrase

test_live_issue_failed_to_load_phrase() {
    local output
    output=$(_live_issue_stdin "the catalog failed to load after I hit refresh" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" MOBILE_REPO="$TMPDIR_CB/nonexistent-repo" \
        bash "$HOOK_PATH" 2>/dev/null)
    assert_contains "$output" "LIVE_ISSUE_DETECTED" "hook should detect 'failed to load'"
}
run_test "live-issue: 'failed to load' triggers detection" test_live_issue_failed_to_load_phrase

test_live_issue_case_insensitive() {
    local output
    output=$(_live_issue_stdin "IT IS STUCK right now" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" MOBILE_REPO="$TMPDIR_CB/nonexistent-repo" \
        bash "$HOOK_PATH" 2>/dev/null)
    assert_contains "$output" "LIVE_ISSUE_DETECTED" "hook should match trigger phrases case-insensitively"
}
run_test "live-issue: case-insensitive match" test_live_issue_case_insensitive

test_live_issue_silent_on_unrelated_prompt() {
    local output
    output=$(_live_issue_stdin "please add a new backlog item for the cleanup task" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" MOBILE_REPO="$TMPDIR_CB/nonexistent-repo" \
        bash "$HOOK_PATH" 2>/dev/null)
    assert_not_contains "$output" "LIVE_ISSUE_DETECTED" "hook should NOT fire on unrelated prompts"
}
run_test "live-issue: silent on unrelated prompts" test_live_issue_silent_on_unrelated_prompt

test_live_issue_silent_on_past_tense() {
    # "was stuck" (past tense, already resolved) should not trigger.
    local output
    output=$(_live_issue_stdin "yesterday the session was stuck but I rebooted" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" MOBILE_REPO="$TMPDIR_CB/nonexistent-repo" \
        bash "$HOOK_PATH" 2>/dev/null)
    assert_not_contains "$output" "LIVE_ISSUE_DETECTED" "hook should NOT fire on past-tense reports ('was stuck')"
}
run_test "live-issue: silent on past-tense reports" test_live_issue_silent_on_past_tense

# ── Session-scoped sidecar (CFG-458) ──────────────────────────────────────
# A single global ~/.claude/.context-budget.json is last-writer-wins across
# concurrent sessions, so the CONTEXT_BUDGET line injected into one session
# could carry another session's numbers. The sidecar must be keyed by session.

SCOPE_DIR="$TMPDIR_CB/scoped"

# Statusline input carrying a session_id.
make_json_sid() {
    local sid="$1" pct="${2:-54}" win="${3:-1000000}"
    local input_tok="${4:-50000}" cache_create="${5:-30000}" cache_read="${6:-28000}"
    printf '{"session_id":"%s","model":{"display_name":"TestModel"},"context_window":{"used_percentage":%s,"context_window_size":%s,"current_usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}' \
        "$sid" "$pct" "$win" "$input_tok" "$cache_create" "$cache_read"
}

sidecar_for() { echo "$SCOPE_DIR/.context-budget-$1.json"; }

test_sidecar_is_session_scoped() {
    rm -rf "$SCOPE_DIR"; mkdir -p "$SCOPE_DIR"
    make_json_sid "sess-aaa" 54 | CONTEXT_BUDGET_DIR="$SCOPE_DIR" bash "$STATUSLINE_PATH" >/dev/null
    assert_file_exists "$(sidecar_for sess-aaa)" "sidecar must be named after the session id" || return 1
    assert_file_not_exists "$SCOPE_DIR/.context-budget.json" "must not write the shared unscoped path" || return 1
}
run_sl_test "statusline writes a session-scoped sidecar" test_sidecar_is_session_scoped

test_sessions_do_not_collide() {
    rm -rf "$SCOPE_DIR"; mkdir -p "$SCOPE_DIR"
    # Session A at ~11%, session B at ~99% of a 1M window.
    make_json_sid "sess-a" 0 1000000 40000 40000 30000 | CONTEXT_BUDGET_DIR="$SCOPE_DIR" bash "$STATUSLINE_PATH" >/dev/null
    make_json_sid "sess-b" 0 1000000 400000 300000 290000 | CONTEXT_BUDGET_DIR="$SCOPE_DIR" bash "$STATUSLINE_PATH" >/dev/null
    local a b
    a=$(python3 -c "import json; print(json.load(open('$(sidecar_for sess-a)'))['used_k'])")
    b=$(python3 -c "import json; print(json.load(open('$(sidecar_for sess-b)'))['used_k'])")
    assert_eq "110" "$a" "session A keeps its own token count" || return 1
    assert_eq "990" "$b" "session B keeps its own token count" || return 1
}
run_sl_test "concurrent sessions do not overwrite each other" test_sessions_do_not_collide

test_hook_reads_own_session() {
    rm -rf "$SCOPE_DIR"; mkdir -p "$SCOPE_DIR"
    make_json_sid "sess-a" 0 1000000 40000 40000 30000 | CONTEXT_BUDGET_DIR="$SCOPE_DIR" bash "$STATUSLINE_PATH" >/dev/null
    make_json_sid "sess-b" 0 1000000 400000 300000 290000 | CONTEXT_BUDGET_DIR="$SCOPE_DIR" bash "$STATUSLINE_PATH" >/dev/null
    local output
    output=$(printf '{"session_id":"sess-a","message":"hello"}' | \
        CONTEXT_BUDGET_DIR="$SCOPE_DIR" bash "$HOOK_PATH" 2>/dev/null)
    assert_contains "$output" "110k" "hook must report its own session's usage" || return 1
    assert_not_contains "$output" "990k" "hook must not report another session's usage" || return 1
}
run_sl_test "hook reads the sidecar for its own session" test_hook_reads_own_session

test_hook_silent_without_own_sidecar() {
    rm -rf "$SCOPE_DIR"; mkdir -p "$SCOPE_DIR"
    make_json_sid "sess-other" 0 1000000 400000 300000 290000 | CONTEXT_BUDGET_DIR="$SCOPE_DIR" bash "$STATUSLINE_PATH" >/dev/null
    local output
    output=$(printf '{"session_id":"sess-mine","message":"hello"}' | \
        CONTEXT_BUDGET_DIR="$SCOPE_DIR" bash "$HOOK_PATH" 2>/dev/null)
    assert_not_contains "$output" "CONTEXT_BUDGET" "no budget line is better than another session's number" || return 1
}
run_sl_test "hook stays silent when its own sidecar is missing" test_hook_silent_without_own_sidecar

test_stale_sidecars_pruned() {
    rm -rf "$SCOPE_DIR"; mkdir -p "$SCOPE_DIR"
    local stale="$SCOPE_DIR/.context-budget-ancient.json"
    echo '{"pct":1,"remaining":99,"size":1000000,"used_k":10}' > "$stale"
    touch -d "5 days ago" "$stale"
    make_json_sid "sess-new" 54 | CONTEXT_BUDGET_DIR="$SCOPE_DIR" bash "$STATUSLINE_PATH" >/dev/null
    assert_file_not_exists "$stale" "sidecars from long-dead sessions must be pruned" || return 1
    assert_file_exists "$(sidecar_for sess-new)" "the live session's sidecar survives pruning" || return 1
}
run_sl_test "stale session sidecars are pruned" test_stale_sidecars_pruned

suite_summary
