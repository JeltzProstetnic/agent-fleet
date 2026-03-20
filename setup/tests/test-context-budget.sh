#!/usr/bin/env bash
# Tests for context budget feature:
# 1. statusline.sh writes sidecar file ~/.claude/.context-budget.json
# 2. hooks/context-budget.sh reads sidecar and outputs budget line for systemMessage
source "$(dirname "$0")/test-helpers.sh"

suite_header "context-budget"

STATUSLINE_PATH="$REPO_ROOT/setup/config/statusline-command.sh"
HOOK_PATH="$REPO_ROOT/global/hooks/context-budget.sh"
TMPDIR_CB=$(mktemp -d)
SIDECAR="$TMPDIR_CB/.context-budget.json"
HAS_STATUSLINE=false
[[ -f "$STATUSLINE_PATH" ]] && HAS_STATUSLINE=true

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

# ── Statusline sidecar tests (require statusline.sh) ─────────────────────

if $HAS_STATUSLINE; then

test_sidecar_created() {
    rm -f "$SIDECAR"
    CONTEXT_BUDGET_PATH="$SIDECAR" echo "$(make_json "Opus 4.6" 54)" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" bash "$STATUSLINE_PATH" >/dev/null
    assert_file_exists "$SIDECAR" "statusline should create sidecar file"
}
run_test "statusline creates sidecar file" test_sidecar_created

test_sidecar_contains_pct() {
    rm -f "$SIDECAR"
    CONTEXT_BUDGET_PATH="$SIDECAR" echo "$(make_json "Opus 4.6" 54)" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" bash "$STATUSLINE_PATH" >/dev/null
    local pct
    pct=$(python3 -c "import json; print(json.load(open('$SIDECAR'))['pct'])")
    assert_eq "54" "$pct" "sidecar pct should be 54"
}
run_test "sidecar contains correct percentage" test_sidecar_contains_pct

test_sidecar_contains_remaining() {
    rm -f "$SIDECAR"
    CONTEXT_BUDGET_PATH="$SIDECAR" echo "$(make_json "Opus 4.6" 54)" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" bash "$STATUSLINE_PATH" >/dev/null
    local rem
    rem=$(python3 -c "import json; print(json.load(open('$SIDECAR'))['remaining'])")
    assert_eq "46" "$rem" "sidecar remaining should be 46"
}
run_test "sidecar contains remaining percentage" test_sidecar_contains_remaining

test_sidecar_contains_size() {
    rm -f "$SIDECAR"
    CONTEXT_BUDGET_PATH="$SIDECAR" echo "$(make_json "Opus 4.6" 54 200000)" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" bash "$STATUSLINE_PATH" >/dev/null
    local sz
    sz=$(python3 -c "import json; print(json.load(open('$SIDECAR'))['size'])")
    assert_eq "200000" "$sz" "sidecar size should be 200000"
}
run_test "sidecar contains window size" test_sidecar_contains_size

test_sidecar_contains_used_k() {
    rm -f "$SIDECAR"
    CONTEXT_BUDGET_PATH="$SIDECAR" echo "$(make_json "Opus 4.6" 54 200000)" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" bash "$STATUSLINE_PATH" >/dev/null
    local used_k
    used_k=$(python3 -c "import json; print(json.load(open('$SIDECAR'))['used_k'])")
    assert_eq "108" "$used_k" "sidecar used_k should be 108"
}
run_test "sidecar contains used_k" test_sidecar_contains_used_k

test_sidecar_zero_usage() {
    rm -f "$SIDECAR"
    CONTEXT_BUDGET_PATH="$SIDECAR" echo "$(make_json "Test" 0 200000 0 0 0)" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" bash "$STATUSLINE_PATH" >/dev/null
    local pct
    pct=$(python3 -c "import json; print(json.load(open('$SIDECAR'))['pct'])")
    assert_eq "0" "$pct" "sidecar pct should be 0 at zero usage"
}
run_test "sidecar at zero usage" test_sidecar_zero_usage

test_sidecar_high_usage() {
    rm -f "$SIDECAR"
    CONTEXT_BUDGET_PATH="$SIDECAR" echo "$(make_json "Test" 92 200000 92000 0 0)" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" bash "$STATUSLINE_PATH" >/dev/null
    local pct
    pct=$(python3 -c "import json; print(json.load(open('$SIDECAR'))['pct'])")
    assert_eq "92" "$pct" "sidecar pct should be 92"
}
run_test "sidecar at high usage" test_sidecar_high_usage

test_sidecar_no_crash_on_invalid() {
    rm -f "$SIDECAR"
    CONTEXT_BUDGET_PATH="$SIDECAR" echo "not json" | \
        CONTEXT_BUDGET_PATH="$SIDECAR" bash "$STATUSLINE_PATH" >/dev/null
    # Sidecar should NOT be created on invalid input
    assert_file_not_exists "$SIDECAR" "sidecar should not be created for invalid input"
}
run_test "no sidecar on invalid input" test_sidecar_no_crash_on_invalid

else
    skip_test "statusline creates sidecar file" "statusline.sh not found"
    skip_test "sidecar contains correct percentage" "statusline.sh not found"
    skip_test "sidecar contains remaining percentage" "statusline.sh not found"
    skip_test "sidecar contains window size" "statusline.sh not found"
    skip_test "sidecar contains used_k" "statusline.sh not found"
    skip_test "sidecar at zero usage" "statusline.sh not found"
    skip_test "sidecar at high usage" "statusline.sh not found"
    skip_test "no sidecar on invalid input" "statusline.sh not found"
fi

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

suite_summary
