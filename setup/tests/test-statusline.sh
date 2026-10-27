#!/usr/bin/env bash
# Tests for setup/config/statusline.sh — context usage statusline rendering
source "$(dirname "$0")/test-helpers.sh"

suite_header "statusline.sh"

SCRIPT_PATH="$REPO_ROOT/setup/config/statusline-command.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Build a valid JSON input payload for the statusline script.
# Args: model_name percentage window_size input_tokens cache_creation cache_read
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

# Unicode block characters used in the bar
FILLED=$'\u2593'   # ▓
EMPTY=$'\u2591'    # ░

# ── Tests ────────────────────────────────────────────────────────────────────

test_basic_output_format() {
    local output
    output=$(echo "$(make_json "Opus 4.6" 54)" | bash "$SCRIPT_PATH")
    assert_contains "$output" "[Opus 4.6]" "output should contain model name in brackets"
}
run_test "basic output format: model name in brackets" test_basic_output_format

test_percentage_bar_54pct() {
    local output
    # Use non-override model so CC's pct is trusted (tests pct→bar mapping,
    # not token recomputation). Opus 4.6 would trigger 1M override.
    output=$(echo "$(make_json "TestModel" 54)" | bash "$SCRIPT_PATH")
    # 54% of 10 chars = 5 filled, 5 empty (int(54*10/100) = 5)
    local expected_bar
    expected_bar=$(printf '%s' "${FILLED}${FILLED}${FILLED}${FILLED}${FILLED}${EMPTY}${EMPTY}${EMPTY}${EMPTY}${EMPTY}")
    assert_contains "$output" "$expected_bar" "54% should produce 5 filled + 5 empty"
}
run_test "percentage calculation: 54% bar width" test_percentage_bar_54pct

test_percentage_bar_25pct() {
    local output
    output=$(echo "$(make_json "Test" 25 200000 25000 0 0)" | bash "$SCRIPT_PATH")
    # 25% of 10 = 2.5 segments → rounds half-up to 3 (Max, 2026-10-26: same rounding as the 5h bar)
    local expected_bar
    expected_bar=$(printf '%s' "${FILLED}${FILLED}${FILLED}${EMPTY}${EMPTY}${EMPTY}${EMPTY}${EMPTY}${EMPTY}${EMPTY}")
    assert_contains "$output" "$expected_bar" "25% should produce 3 filled + 7 empty"
}
run_test "percentage calculation: 25% bar width" test_percentage_bar_25pct

test_context_fill_rounds_to_nearest_segment() {
    # Floor division left the context bar empty below 10%; it now rounds like the 5h bar.
    local pct want_filled out bar
    for pair in "0:0" "4:0" "5:1" "9:1" "14:1" "15:2" "95:10" "100:10"; do
        pct="${pair%%:*}"; want_filled="${pair#*:}"
        # Zero tokens: at 0% the script otherwise recomputes from tokens (make_json defaults to 108k).
        out=$(make_json "TestModel" "$pct" 200000 0 0 0 | HOME="$TEST_TMPDIR/nohome" bash "$SCRIPT_PATH")
        bar=""; for ((i=0; i<want_filled; i++)); do bar+="$FILLED"; done
        for ((i=want_filled; i<10; i++)); do bar+="$EMPTY"; done
        assert_contains "$out" "$bar " "context ${pct}% → ${want_filled}/10 segments (out: $out)" || return 1
    done
}
run_test "context bar: fill rounds to the nearest 10% segment" test_context_fill_rounds_to_nearest_segment

test_context_float_percentage_rounded() {
    local out
    out=$(make_json "TestModel" 42.6 | HOME="$TEST_TMPDIR/nohome" bash "$SCRIPT_PATH")
    assert_contains "$out" "(43%)" "42.6% shown as 43% (out: $out)"
}
run_test "context bar: float percentage rounded half-up" test_context_float_percentage_rounded

test_green_color_low_usage() {
    local raw_output
    raw_output=$(echo "$(make_json "Test" 40 200000 40000 0 0)" | bash "$SCRIPT_PATH")
    # Green ANSI: \033[32m — used for <50% usage
    local green_esc=$'\033[32m'
    assert_contains "$raw_output" "$green_esc" "<50% usage should use green ANSI color"
}
run_test "green color for low usage (<50%)" test_green_color_low_usage

test_yellow_color_medium_usage() {
    local raw_output
    raw_output=$(echo "$(make_json "Test" 75 200000 75000 0 0)" | bash "$SCRIPT_PATH")
    # Bright yellow: \033[93m — used for 70-79% usage
    local yellow_esc=$'\033[93m'
    assert_contains "$raw_output" "$yellow_esc" "70-79% usage should use bright yellow ANSI color"
}
run_test "yellow color for medium usage (70-79%)" test_yellow_color_medium_usage

test_yellow_at_boundary_70() {
    local raw_output
    raw_output=$(echo "$(make_json "Test" 70 200000 70000 0 0)" | bash "$SCRIPT_PATH")
    local yellow_esc=$'\033[93m'
    assert_contains "$raw_output" "$yellow_esc" "exactly 70% should use bright yellow"
}
run_test "yellow color at boundary (exactly 70%)" test_yellow_at_boundary_70

test_red_color_high_usage() {
    local raw_output
    raw_output=$(echo "$(make_json "Test" 95 200000 95000 0 0)" | bash "$SCRIPT_PATH")
    local red_esc=$'\033[31m'
    assert_contains "$raw_output" "$red_esc" "90%+ usage should use red ANSI color"
}
run_test "red color for high usage (90%+)" test_red_color_high_usage

test_red_at_boundary_90() {
    local raw_output
    raw_output=$(echo "$(make_json "Test" 90 200000 90000 0 0)" | bash "$SCRIPT_PATH")
    local red_esc=$'\033[31m'
    assert_contains "$raw_output" "$red_esc" "exactly 90% should use red"
}
run_test "red color at boundary (exactly 90%)" test_red_at_boundary_90

test_orange_at_boundary_69() {
    local raw_output
    raw_output=$(echo "$(make_json "Test" 69 200000 69000 0 0)" | bash "$SCRIPT_PATH")
    # Orange 256-color: \033[38;5;208m — used for 60-69%
    local orange_esc=$'\033[38;5;208m'
    assert_contains "$raw_output" "$orange_esc" "69% should use orange (60-69% range)"
}
run_test "orange color at boundary (69%)" test_orange_at_boundary_69

test_token_count_display() {
    local output
    # 54% of 200000 = 108000 tokens → 108k. used_k = int(200000 * 54 / 100000) = 108
    # Use non-overridden model name so CC's reported window size is honored.
    output=$(echo "$(make_json "TestModel" 54 200000 50000 30000 28000)" | bash "$SCRIPT_PATH")
    assert_contains "$output" "108k/200k" "should show derived token count as Xk/Yk"
}
run_test "token count display: Xk/Yk format" test_token_count_display

test_token_count_percentage_display() {
    local output
    # Non-override model so CC's pct is trusted for display.
    output=$(echo "$(make_json "TestModel" 54 200000 50000 30000 28000)" | bash "$SCRIPT_PATH")
    assert_contains "$output" "(54%)" "should show percentage in parentheses"
}
run_test "token count display: percentage in parens" test_token_count_percentage_display

test_error_handling_invalid_json() {
    local output
    output=$(echo "this is not json at all" | bash "$SCRIPT_PATH")
    assert_eq "[?] ..." "$output" "invalid JSON should produce fallback output"
}
run_test "error handling: invalid JSON produces fallback" test_error_handling_invalid_json

test_error_handling_partial_json() {
    local output
    output=$(echo '{"model": {}}' | bash "$SCRIPT_PATH")
    # This is valid JSON but with missing fields — python should handle gracefully
    # with defaults: model=?, pct=0, win=200000
    assert_contains "$output" "[?]" "partial JSON should use ? as model name"
}
run_test "error handling: partial JSON uses fallback model name" test_error_handling_partial_json

test_empty_input() {
    local output
    output=$(echo "" | bash "$SCRIPT_PATH")
    assert_eq "[?] ..." "$output" "empty stdin should produce fallback output"
}
run_test "empty input: produces fallback output" test_empty_input

test_zero_usage() {
    local output
    output=$(echo "$(make_json "Test" 0 200000 0 0 0)" | bash "$SCRIPT_PATH")
    # 0% → 0 filled, 10 empty
    local all_empty
    all_empty=$(printf '%s' "${EMPTY}${EMPTY}${EMPTY}${EMPTY}${EMPTY}${EMPTY}${EMPTY}${EMPTY}${EMPTY}${EMPTY}")
    assert_contains "$output" "$all_empty" "0% should show all empty bar characters"
    assert_contains "$output" "(0%)" "should show 0%"
}
run_test "zero usage: empty bar with all light shade chars" test_zero_usage

test_full_usage() {
    local output
    output=$(echo "$(make_json "Test" 100 200000 100000 50000 50000)" | bash "$SCRIPT_PATH")
    # 100% → 10 filled, 0 empty
    local all_filled
    all_filled=$(printf '%s' "${FILLED}${FILLED}${FILLED}${FILLED}${FILLED}${FILLED}${FILLED}${FILLED}${FILLED}${FILLED}")
    assert_contains "$output" "$all_filled" "100% should show all filled bar characters"
    assert_contains "$output" "(100%)" "should show 100%"
}
run_test "full usage: full bar with all dark shade chars" test_full_usage

test_reset_ansi_at_end() {
    local raw_output
    raw_output=$(echo "$(make_json "Test" 50 200000 50000 0 0)" | bash "$SCRIPT_PATH")
    local reset_esc=$'\033[0m'
    assert_contains "$raw_output" "$reset_esc" "output should end with ANSI reset code"
}
run_test "ANSI reset code at end of output" test_reset_ansi_at_end

test_different_window_size() {
    local output
    # 50% of 128000 → used_k = int(128000 * 50 / 100000) = 64
    output=$(echo "$(make_json "Sonnet" 50 128000 32000 16000 16000)" | bash "$SCRIPT_PATH")
    assert_contains "$output" "[Sonnet]" "should show correct model name"
    assert_contains "$output" "64k/128k" "should compute token counts from window size"
    assert_contains "$output" "(50%)" "should show correct percentage"
}
run_test "different window size: 128k context" test_different_window_size

# ── rsync progress indicator tests ──────────────────────────────────────────

test_rsync_log_running() {
    # Rsync indicator was replaced by GPI (Grind Progress Indicator) system
    true
}
skip_test "rsync indicator: running transfer shows progress" "replaced by GPI system"

test_rsync_log_complete() {
    true
}
skip_test "rsync indicator: completed transfer shows DONE" "replaced by GPI system"

test_rsync_log_missing() {
    # Ensure no log file exists
    local tmp_script="/tmp/test-statusline-$$.sh"
    sed "s|/tmp/rsync-fms.log|/tmp/rsync-fms-nonexistent-$$.log|" "$SCRIPT_PATH" > "$tmp_script"
    local output
    output=$(echo "$(make_json "Test" 10)" | bash "$tmp_script")
    assert_not_contains "$output" "[rsync" "should NOT show rsync indicator when no log"
    rm -f "$tmp_script"
}
run_test "rsync indicator: no log file means no indicator" test_rsync_log_missing

test_rsync_log_malformed() {
    local test_log="/tmp/rsync-fms-test-$$.log"
    printf '\x00\xff\xfe garbage data' > "$test_log"
    local tmp_script="/tmp/test-statusline-$$.sh"
    sed "s|/tmp/rsync-fms.log|$test_log|" "$SCRIPT_PATH" > "$tmp_script"
    local output
    output=$(echo "$(make_json "Test" 10)" | bash "$tmp_script")
    # Should not crash — either no indicator or gracefully handles it
    assert_neq "" "$output" "should produce output even with malformed log"
    assert_not_contains "$output" "[?] ..." "should not fall to error handler"
    rm -f "$test_log" "$tmp_script"
}
run_test "rsync indicator: malformed log handled gracefully" test_rsync_log_malformed

# ── project name and cost tests ─────────────────────────────────────────────

make_json_with_workspace() {
    local model="${1:-Opus 4.6}"
    local pct="${2:-54}"
    local project_dir="${3:-/home/user/my-project}"
    local cost="${4:-0}"
    printf '{"model":{"display_name":"%s"},"context_window":{"used_percentage":%s,"context_window_size":200000,"current_usage":{"input_tokens":50000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"workspace":{"project_dir":"%s"},"cost":{"total_cost_usd":%s}}' \
        "$model" "$pct" "$project_dir" "$cost"
}

test_project_name_displayed() {
    local output
    output=$(echo "$(make_json_with_workspace "Test" 10 "/home/user/my-cool-project" 0)" | bash "$SCRIPT_PATH")
    assert_contains "$output" "my-cool-project" "should show project directory basename"
}
run_test "project name: displays basename of project dir" test_project_name_displayed

test_cost_displayed() {
    local output
    output=$(echo "$(make_json_with_workspace "Test" 10 "/home/user/proj" 3.57)" | STATUSLINE_SHOW_COST=1 bash "$SCRIPT_PATH")
    assert_contains "$output" '$3.57' "should show cost when > 0"
}
run_test "cost: displayed when > 0" test_cost_displayed

test_cost_hidden_when_zero() {
    local output
    output=$(echo "$(make_json_with_workspace "Test" 10 "/home/user/proj" 0)" | bash "$SCRIPT_PATH")
    assert_not_contains "$output" '$0.00' "should not show cost when 0"
}
run_test "cost: hidden when zero" test_cost_hidden_when_zero

# ── Model-name context-window override (1M-variant display_name) ──────────
# CC has two SKUs per model: plain 'Opus 4.7' (200k) and 'Opus 4.7 (1M context)'
# (1M opt-in). CC reports context_window_size correctly for plain names but
# may misreport for 1M variants — statusline overrides on the '(1M context)'
# suffix only. Plain names fall through to CC's value (200k).

test_opus_4_7_1m_overrides_to_1m() {
    # '(1M context)' variant — override to 1M regardless of CC's value.
    local output
    output=$(echo "$(make_json "Opus 4.7 (1M context)" 10 200000 20000 0 0)" | bash "$SCRIPT_PATH")
    assert_contains "$output" "1000k" "Opus 4.7 (1M context) must display 1M window"
    assert_not_contains "$output" "/200k" "Opus 4.7 (1M context) must NOT display 200k"
}
run_test "model override: Opus 4.7 (1M context) forces 1M window" test_opus_4_7_1m_overrides_to_1m

test_sonnet_4_6_1m_overrides_to_1m() {
    local output
    output=$(echo "$(make_json "Sonnet 4.6 (1M context)" 10 200000 20000 0 0)" | bash "$SCRIPT_PATH")
    assert_contains "$output" "1000k" "Sonnet 4.6 (1M context) must display 1M window"
}
run_test "model override: Sonnet 4.6 (1M context) forces 1M window" test_sonnet_4_6_1m_overrides_to_1m

test_plain_opus_4_7_trusts_cc_200k() {
    # Plain 'Opus 4.7' is the 200k default SKU — no override, trust CC.
    local output
    output=$(echo "$(make_json "Opus 4.7" 10 200000 20000 0 0)" | bash "$SCRIPT_PATH")
    assert_contains "$output" "/200k" "plain Opus 4.7 must display CC's reported 200k"
    assert_not_contains "$output" "1000k" "plain Opus 4.7 must NOT be overridden to 1M"
}
run_test "no override: plain Opus 4.7 stays at CC-reported 200k" test_plain_opus_4_7_trusts_cc_200k

test_plain_sonnet_4_6_trusts_cc_200k() {
    local output
    output=$(echo "$(make_json "Sonnet 4.6" 10 200000 20000 0 0)" | bash "$SCRIPT_PATH")
    assert_contains "$output" "/200k" "plain Sonnet 4.6 must display CC's reported 200k"
}
run_test "no override: plain Sonnet 4.6 stays at CC-reported 200k" test_plain_sonnet_4_6_trusts_cc_200k

test_haiku_4_5_trusts_cc_value() {
    # Haiku is 200k only (no 1M variant). CC's value is authoritative.
    local output
    output=$(echo "$(make_json "Haiku 4.5" 10 200000 20000 0 0)" | bash "$SCRIPT_PATH")
    assert_contains "$output" "/200k" "Haiku 4.5 must display 200k window"
}
run_test "no override: Haiku 4.5 stays at 200k" test_haiku_4_5_trusts_cc_value

test_unknown_model_falls_back_to_cc_value() {
    local output
    output=$(echo "$(make_json "Future Model X" 10 500000 50000 0 0)" | bash "$SCRIPT_PATH")
    assert_contains "$output" "/500k" "unknown model falls back to CC's reported window size"
}
run_test "model override: unknown model uses CC-reported size" test_unknown_model_falls_back_to_cc_value

# ── pct must be recomputed from raw tokens when window is overridden ────────
# Regression: CC reports used_percentage against its own reported window.
# When we override to 1M, multiplying that pct by 1M can produce inflation.
# Fix: for overridden models, use raw token count, compute pct = tokens/win_size.

test_opus_4_7_1m_pct_recomputed_from_raw_tokens() {
    # CC reports pct=50 (its 200k view), raw tokens = 100k actual.
    # Correct display: 100k/1000k (10%). Bug would show 500k/1000k (50%).
    local output
    output=$(echo "$(make_json "Opus 4.7 (1M context)" 50 200000 50000 25000 25000)" | bash "$SCRIPT_PATH")
    assert_contains "$output" "100k/1000k" "overridden model must compute used_k from raw tokens, not pct*win"
    assert_contains "$output" "(10%)" "overridden model must recompute pct from tokens/win_size"
    assert_not_contains "$output" "500k/1000k" "must not show inflated used_k from pct-based calc"
    assert_not_contains "$output" "(50%)" "must not reuse CC's pct when overriding window"
}
run_test "override regression: pct recomputed from raw tokens, not CC pct" test_opus_4_7_1m_pct_recomputed_from_raw_tokens

test_sonnet_4_6_1m_pct_recomputed() {
    # 200k of tokens on 1M window = 20%, not the 80% CC would report on 200k
    local output
    output=$(echo "$(make_json "Sonnet 4.6 (1M context)" 80 200000 100000 50000 50000)" | bash "$SCRIPT_PATH")
    assert_contains "$output" "200k/1000k" "Sonnet 4.6 (1M context) must use raw tokens for display"
    assert_contains "$output" "(20%)" "Sonnet 4.6 (1M context) must recompute pct"
}
run_test "override regression: Sonnet 4.6 (1M context) pct recomputed" test_sonnet_4_6_1m_pct_recomputed

test_plain_opus_4_7_trusts_cc_pct() {
    # Plain Opus 4.7 is 200k — no override, so trust CC's pct.
    # pct=40 with 200k window → 80k/200k
    local output
    output=$(echo "$(make_json "Opus 4.7" 40 200000 40000 20000 20000)" | bash "$SCRIPT_PATH")
    assert_contains "$output" "80k/200k" "plain Opus 4.7 non-override path uses CC's pct"
    assert_contains "$output" "(40%)" "plain Opus 4.7 preserves CC's pct"
}
run_test "non-override path: plain Opus 4.7 trusts CC pct" test_plain_opus_4_7_trusts_cc_pct

# ── Persona display (CFG-700: colours come from personas.md, not a hard-coded table) ──

# mock_personas <home> — a personas.md with two personas and their Color fields.
mock_personas() {
    mkdir -p "$1/.claude/foundation"
    cat > "$1/.claude/foundation/personas.md" << 'EOF'
# Default Personas
## Persona
### Assistant
- **Name**: Assistant
- **Color**: bright-yellow
### Supporter
- **Name**: Supporter
- **Color**: pink
EOF
}

run_with_persona() {   # <persona-or-empty|-> ; sets OUT
    local h="$TEST_TMPDIR/home"
    rm -rf "$h"; mkdir -p "$h/.claude"; mock_personas "$h"
    [[ "$1" != "-" ]] && printf '%s\n' "$1" > "$h/.claude/.active-persona"
    OUT=$(make_json "Opus 4.6" 50 | HOME="$h" bash "$SCRIPT_PATH")
}

test_persona_name_shown() {
    run_with_persona "Assistant"
    assert_contains "$OUT" "Assistant" "persona name from .active-persona"
}
run_test "persona: displays name from .active-persona file" test_persona_name_shown

test_persona_color_from_personas_md() {
    run_with_persona "Assistant"
    assert_contains "$OUT" $'\033[93mAssistant' "bright-yellow from its personas.md Color field"
    run_with_persona "Supporter"
    assert_contains "$OUT" $'\033[95mSupporter' "pink maps to bright-magenta"
}
run_test "persona: colour is read from personas.md" test_persona_color_from_personas_md

test_persona_local_override() {
    local h="$TEST_TMPDIR/home"
    rm -rf "$h"; mkdir -p "$h/.claude"; mock_personas "$h"
    printf '### Night\n- **Color**: bright-red\n' > "$h/.claude/foundation/personas.local.md"
    echo "Night" > "$h/.claude/.active-persona"
    OUT=$(make_json "Opus 4.6" 50 | HOME="$h" bash "$SCRIPT_PATH")
    assert_contains "$OUT" $'\033[91mNight' "a persona defined in personas.local.md gets its colour"
}
run_test "persona: personas.local.md personas are coloured too" test_persona_local_override

test_persona_unknown_cyan() {
    run_with_persona "Unknown"
    assert_contains "$OUT" $'\033[36mUnknown' "unknown persona: default cyan, name still shown"
}
run_test "persona: unknown persona uses cyan default color" test_persona_unknown_cyan

test_persona_empty_or_missing() {
    run_with_persona ""
    assert_contains "$OUT" "[Opus 4.6]" "empty .active-persona: still renders"
    run_with_persona "-"
    assert_contains "$OUT" "(50%)" "missing .active-persona: still renders"
}
run_test "persona: empty or missing .active-persona renders without error" test_persona_empty_or_missing

test_no_hardcoded_persona_or_server() {
    local hits
    hits=$(grep -nE "PERSONA_COLORS = \{[^}]*'[A-Z][a-z]+'|https://afd\." "$SCRIPT_PATH" || true)
    assert_eq "" "$hits" "no hard-coded persona table, no default afd server URL"
}
run_test "source: no hard-coded persona names or afd server" test_no_hardcoded_persona_or_server

# ── Lock heartbeat (CFG-700: no bearer token to a default server) ──────────

# run_heartbeat <AFD_URL or "-" to unset> ; sets CURL_LOG contents in HB
run_heartbeat() {
    local h="$TEST_TMPDIR/home" bin="$TEST_TMPDIR/bin"
    rm -rf "$h" "$bin"; mkdir -p "$h/.claude" "$bin"
    printf '#!/usr/bin/env bash\necho "$@" >> "%s/curl.log"\n' "$TEST_TMPDIR" > "$bin/curl"; chmod +x "$bin/curl"
    rm -f "$TEST_TMPDIR/curl.log"
    local json; json=$(make_json_with_workspace "Opus 4.6" 10 "/tmp/proj-x" 0)
    if [[ "$1" == "-" ]]; then
        printf '%s' "$json" | env -u AFD_URL HOME="$h" PATH="$bin:$PATH" AFLEET_SESSION_ID=s1 AFD_TOKEN=tok bash "$SCRIPT_PATH" >/dev/null
    else
        printf '%s' "$json" | HOME="$h" PATH="$bin:$PATH" AFLEET_SESSION_ID=s1 AFD_TOKEN=tok AFD_URL="$1" bash "$SCRIPT_PATH" >/dev/null
    fi
    sleep 0.5
    HB=$(cat "$TEST_TMPDIR/curl.log" 2>/dev/null)
}

test_heartbeat_needs_afd_url() {
    run_heartbeat "-"
    assert_eq "" "$HB" "no AFD_URL: no heartbeat, so the token goes nowhere"
}
run_test "heartbeat: nothing sent without AFD_URL" test_heartbeat_needs_afd_url

test_heartbeat_uses_afd_url() {
    run_heartbeat "http://afd.test"
    assert_contains "$HB" "http://afd.test/api/locks/proj-x" "heartbeat goes to the configured server (log: $HB)"
}
run_test "heartbeat: sent to the configured AFD_URL" test_heartbeat_uses_afd_url


# ── 5-hour rolling usage window (rate_limits.five_hour) ─────────────────────
# CC (verified in the 2.1.303 binary) passes rate_limits.five_hour.{used_percentage,
# resets_at} to the statusline for claude.ai plan sessions; null or absent otherwise.

# Merge a rate_limits object (JSON string, or "null") into a make_json payload on stdin.
add_rl() {
    python3 -c 'import json,sys; d=json.load(sys.stdin); d["rate_limits"]=json.loads(sys.argv[1]); print(json.dumps(d))' "$1"
}

# Everything after the "5h " label, so colour/bar assertions cannot match the context bar.
five_h_segment() { printf '%s' "${1#* 5h }"; }

test_5h_bar_rendered() {
    local out seg
    out=$(make_json "TestModel" 10 | add_rl '{"five_hour":{"used_percentage":42,"resets_at":1793000000}}' | bash "$SCRIPT_PATH")
    assert_contains "$out" " 5h " "5h label present (out: $out)"
    seg=$(five_h_segment "$out")
    assert_contains "$seg" "${FILLED}${FILLED}${FILLED}${FILLED}${EMPTY}${EMPTY}${EMPTY}${EMPTY}${EMPTY}${EMPTY} 42%" "42% → 4 filled + 6 empty, then the percentage (seg: $seg)"
}
run_test "5h window: 10-segment bar and percentage" test_5h_bar_rendered

test_5h_segment_at_right_end() {
    # Persona stays left, next to the context bar; the 5h segment is the last thing on the line.
    local h="$TEST_TMPDIR/home" out
    rm -rf "$h"; mkdir -p "$h/.claude"; mock_personas "$h"
    echo "Assistant" > "$h/.claude/.active-persona"
    out=$(make_json "TestModel" 10 | add_rl '{"five_hour":{"used_percentage":42,"resets_at":1793000000}}' | HOME="$h" TZ=UTC bash "$SCRIPT_PATH")
    assert_contains "$out" " 5h " "5h segment present (out: $out)" || return 1
    local before_persona="${out%%Assistant*}" before_5h="${out%% 5h *}"
    [[ ${#before_5h} -gt ${#before_persona} ]] || { echo "  persona should come before the 5h segment (out: $out)"; return 1; }
    local tail_part="${out##* 5h }"
    assert_contains "$tail_part" $'07:33\033[0m' "line ends with the reset time (tail: $tail_part)" || return 1
    assert_not_contains "$tail_part" "Assistant" "nothing from the persona after the 5h segment"
}
run_test "5h window: rightmost segment, persona stays left" test_5h_segment_at_right_end

# Visible width of a rendered line: ANSI stripped, trailing newline dropped, counted in characters.
visible_len() { printf '%s' "$1" | python3 -c 'import re,sys; print(len(re.sub(r"\x1b\[[0-9;]*m","",sys.stdin.read()).rstrip("\n")))'; }
strip_ansi() { printf '%s' "$1" | python3 -c 'import re,sys; print(re.sub(r"\x1b\[[0-9;]*m","",sys.stdin.read()).rstrip("\n"))'; }

test_5h_right_aligned_to_width() {
    local out vis
    out=$(make_json "TestModel" 10 | add_rl '{"five_hour":{"used_percentage":42,"resets_at":1793000000}}' \
        | STATUSLINE_WIDTH=120 STATUSLINE_RIGHT_MARGIN=0 TZ=UTC bash "$SCRIPT_PATH")
    vis=$(visible_len "$out")
    assert_eq "$vis" "120" "line padded to exactly the width, 5h segment flush right (visible width: $vis)" || return 1
    assert_contains "$(strip_ansi "$out")" "07:33" "reset time still present"
}
run_test "5h window: right-aligned to STATUSLINE_WIDTH" test_5h_right_aligned_to_width

test_5h_alignment_counts_wide_chars() {  # Fable review of iv-agent-fleet #4: a wide glyph in free text must not wrap the line
    local h="$TEST_TMPDIR/wide" out w
    mkdir -p "$h/.claude"; echo "Bartl漢字" > "$h/.claude/.active-persona"
    out=$(make_json "TestModel" 10 | add_rl '{"five_hour":{"used_percentage":42,"resets_at":1793000000}}' \
        | HOME="$h" STATUSLINE_WIDTH=120 STATUSLINE_RIGHT_MARGIN=0 TZ=UTC bash "$SCRIPT_PATH")
    w=$(printf '%s' "$out" | python3 -c 'import re,sys,unicodedata as u; s=re.sub(r"\x1b\[[0-9;]*m","",sys.stdin.read()).rstrip("\n"); print(sum(2 if u.east_asian_width(c) in "WF" else 1 for c in s))')
    assert_eq "$w" "120" "display width with two wide chars is exactly 120 (got: $w)"
}
run_test "5h window: alignment counts East-Asian wide chars as 2 columns" test_5h_alignment_counts_wide_chars

test_5h_non_dict_rate_limits_does_not_break_line() {
    local out
    out=$(make_json "TestModel" 10 | add_rl '"weird"' | TZ=UTC bash "$SCRIPT_PATH")
    assert_not_contains "$out" "[?]" "a non-dict rate_limits leaves the line intact (out: $out)" || return 1
    assert_contains "$out" "TestModel" "rest of the line still rendered"
}
run_test "5h window: non-dict rate_limits does not break the line" test_5h_non_dict_rate_limits_does_not_break_line

test_5h_right_margin_respected() {
    local out vis
    out=$(make_json "TestModel" 10 | add_rl '{"five_hour":{"used_percentage":42,"resets_at":1793000000}}' \
        | STATUSLINE_WIDTH=120 STATUSLINE_RIGHT_MARGIN=3 bash "$SCRIPT_PATH")
    vis=$(visible_len "$out")
    assert_eq "$vis" "117" "right margin keeps 3 columns free (visible width: $vis)"
}
run_test "5h window: right margin respected" test_5h_right_margin_respected

test_5h_width_from_columns_env() {
    local out vis
    out=$(make_json "TestModel" 10 | add_rl '{"five_hour":{"used_percentage":42,"resets_at":1793000000}}' \
        | env -u STATUSLINE_WIDTH COLUMNS=100 STATUSLINE_RIGHT_MARGIN=0 bash "$SCRIPT_PATH")
    vis=$(visible_len "$out")
    assert_eq "$vis" "100" "COLUMNS used when STATUSLINE_WIDTH is unset (visible width: $vis)"
}
run_test "5h window: width taken from COLUMNS" test_5h_width_from_columns_env

test_5h_gap_between_persona_and_5h() {
    local h="$TEST_TMPDIR/home" out plain gap
    rm -rf "$h"; mkdir -p "$h/.claude"; mock_personas "$h"
    echo "Assistant" > "$h/.claude/.active-persona"
    out=$(make_json "TestModel" 10 | add_rl '{"five_hour":{"used_percentage":42,"resets_at":1793000000}}' \
        | HOME="$h" STATUSLINE_WIDTH=120 STATUSLINE_RIGHT_MARGIN=0 bash "$SCRIPT_PATH")
    plain=$(strip_ansi "$out")
    gap=$(python3 -c 'import re,sys; m=re.search(r"Assistant( +)5h ",sys.argv[1]); print(len(m.group(1)) if m else -1)' "$plain")
    [[ "$gap" -ge 10 ]] || { echo "  expected a wide gap between persona and 5h, got $gap spaces (plain: $plain)"; return 1; }
}
run_test "5h window: visible gap between persona and 5h segment" test_5h_gap_between_persona_and_5h

test_5h_no_width_single_space() {
    local out plain
    out=$(make_json "TestModel" 10 | add_rl '{"five_hour":{"used_percentage":42,"resets_at":1793000000}}' \
        | HOME="$TEST_TMPDIR/nohome" STATUSLINE_WIDTH=0 bash "$SCRIPT_PATH")
    plain=$(strip_ansi "$out")
    assert_contains "$plain" "(10%) 5h " "STATUSLINE_WIDTH=0 disables alignment: single space (plain: $plain)"
}
run_test "5h window: alignment disabled → single space" test_5h_no_width_single_space

test_5h_narrow_terminal_no_overflow() {
    local out plain
    out=$(make_json "TestModel" 10 | add_rl '{"five_hour":{"used_percentage":42,"resets_at":1793000000}}' \
        | HOME="$TEST_TMPDIR/nohome" STATUSLINE_WIDTH=40 STATUSLINE_RIGHT_MARGIN=0 bash "$SCRIPT_PATH")
    plain=$(strip_ansi "$out")
    assert_contains "$plain" "(10%) 5h " "too narrow to pad: falls back to a single space (plain: $plain)"
}
run_test "5h window: narrow terminal falls back to a single space" test_5h_narrow_terminal_no_overflow

test_5h_colour_thresholds() {
    local pct esc seg
    for pair in "40:"$'\033[32m' "55:"$'\033[36m' "65:"$'\033[38;5;208m' "75:"$'\033[93m' "85:"$'\033[31m'; do
        pct="${pair%%:*}"; esc="${pair#*:}"
        seg=$(five_h_segment "$(make_json "TestModel" 10 | add_rl "{\"five_hour\":{\"used_percentage\":$pct,\"resets_at\":1793000000}}" | bash "$SCRIPT_PATH")")
        assert_contains "$seg" "$esc" "5h at ${pct}% uses the context bar's colour for that band" || return 1
    done
}
run_test "5h window: same colour bands as the context bar" test_5h_colour_thresholds

test_5h_float_percentage_rounded() {
    # CC sends round(utilization*1000)/10, i.e. one decimal; show it rounded half-up.
    local seg
    seg=$(five_h_segment "$(make_json "TestModel" 10 | add_rl '{"five_hour":{"used_percentage":42.7,"resets_at":1793000000}}' | bash "$SCRIPT_PATH")")
    assert_contains "$seg" " 43%" "42.7 shown as 43% (seg: $seg)" || return 1
    seg=$(five_h_segment "$(make_json "TestModel" 10 | add_rl '{"five_hour":{"used_percentage":42.5,"resets_at":1793000000}}' | bash "$SCRIPT_PATH")")
    assert_contains "$seg" " 43%" "42.5 rounds half-up to 43% (seg: $seg)"
}
run_test "5h window: float percentage rounded half-up" test_5h_float_percentage_rounded

test_5h_fill_rounds_to_nearest_segment() {
    # Each segment is 10% of the DISPLAYED (rounded) percentage, so bar and number agree.
    # Floor division showed an EMPTY bar at 9.4% (measured live, 2026-10-26).
    local pct want_filled seg bar
    for pair in "0:0" "4.4:0" "4.5:1" "9.4:1" "14.4:1" "14.5:2" "54:5" "95:10" "100:10"; do
        pct="${pair%%:*}"; want_filled="${pair#*:}"
        seg=$(five_h_segment "$(make_json "TestModel" 10 | add_rl "{\"five_hour\":{\"used_percentage\":$pct}}" | bash "$SCRIPT_PATH")")
        bar=""; for ((i=0; i<want_filled; i++)); do bar+="$FILLED"; done
        for ((i=want_filled; i<10; i++)); do bar+="$EMPTY"; done
        assert_contains "$seg" "$bar " "${pct}% → ${want_filled}/10 segments (seg: $seg)" || return 1
    done
}
run_test "5h window: bar fill rounds to the nearest 10% segment" test_5h_fill_rounds_to_nearest_segment

test_5h_reset_time_epoch() {
    local seg
    seg=$(five_h_segment "$(make_json "TestModel" 10 | add_rl '{"five_hour":{"used_percentage":42,"resets_at":1793000000}}' | TZ=UTC bash "$SCRIPT_PATH")")
    # 1793000000 = 2026-10-26 07:33:20 UTC
    assert_contains "$seg" "07:33" "epoch resets_at rendered as local HH:MM (seg: $seg)" || return 1
    assert_contains "$seg" $'\u21bb 07:33' "a space separates the reset icon from the time (seg: $seg)"
}
run_test "5h window: reset time from epoch seconds" test_5h_reset_time_epoch

test_5h_reset_time_iso() {
    local seg
    seg=$(five_h_segment "$(make_json "TestModel" 10 | add_rl '{"five_hour":{"used_percentage":42,"resets_at":"2026-10-26T07:33:20Z"}}' | TZ=UTC bash "$SCRIPT_PATH")")
    assert_contains "$seg" "07:33" "ISO resets_at rendered as local HH:MM (seg: $seg)"
}
run_test "5h window: reset time from ISO-8601 string" test_5h_reset_time_iso

test_5h_absent_no_segment() {
    local out
    out=$(make_json "TestModel" 54 | bash "$SCRIPT_PATH")
    assert_not_contains "$out" " 5h " "no rate_limits → no 5h segment (out: $out)"
    assert_contains "$out" "(54%)" "context bar unaffected"
}
run_test "5h window: absent rate_limits → no segment" test_5h_absent_no_segment

test_5h_null_no_crash() {
    local out
    out=$(make_json "TestModel" 54 | add_rl 'null' | bash "$SCRIPT_PATH")
    assert_not_contains "$out" " 5h " "rate_limits null → no 5h segment"
    assert_not_contains "$out" "[?] ..." "rate_limits null must not hit the fallback (out: $out)"
    out=$(make_json "TestModel" 54 | add_rl '{"five_hour":null}' | bash "$SCRIPT_PATH")
    assert_not_contains "$out" " 5h " "five_hour null → no 5h segment"
    assert_contains "$out" "(54%)" "context bar still rendered (out: $out)"
}
run_test "5h window: null rate_limits / five_hour handled" test_5h_null_no_crash

test_5h_malformed_keeps_context_bar() {
    local out
    out=$(make_json "TestModel" 54 | add_rl '{"five_hour":{"used_percentage":"n/a","resets_at":"garbage"}}' | bash "$SCRIPT_PATH")
    assert_not_contains "$out" "[?] ..." "malformed five_hour must not hit the fallback (out: $out)"
    assert_not_contains "$out" " 5h " "malformed percentage → no 5h segment"
    assert_contains "$out" "(54%)" "context bar still rendered"
}
run_test "5h window: malformed values keep the context bar" test_5h_malformed_keeps_context_bar

test_5h_missing_reset_still_renders() {
    local seg
    seg=$(five_h_segment "$(make_json "TestModel" 10 | add_rl '{"five_hour":{"used_percentage":30}}' | bash "$SCRIPT_PATH")")
    assert_contains "$seg" " 30%" "bar renders without resets_at (seg: $seg)"
}
run_test "5h window: missing resets_at still renders the bar" test_5h_missing_reset_still_renders

test_5h_in_sidecar() {
    local sc="$TEST_TMPDIR/budget-5h.json"
    rm -f "$sc"
    make_json "TestModel" 10 | add_rl '{"five_hour":{"used_percentage":42,"resets_at":1793000000}}' \
        | CONTEXT_BUDGET_PATH="$sc" bash "$SCRIPT_PATH" >/dev/null
    local v
    v=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("five_hour_pct"))' "$sc" 2>&1)
    assert_eq "$v" "42" "sidecar carries five_hour_pct (got: $v)"
}
run_test "5h window: five_hour_pct written to the context-budget sidecar" test_5h_in_sidecar

# ── Deployment (from the template's suite, CFG-700) ─────────────────────────

test_settings_json_has_statusline_key() {
    local settings="$REPO_ROOT/setup/config/settings.json"
    assert_file_exists "$settings"
    assert_file_contains "$settings" '"statusLine"'
    assert_file_contains "$settings" 'statusline-command.sh'
}
run_test "settings.json has statusLine key pointing to statusline-command.sh" test_settings_json_has_statusline_key

test_statusline_refresh_interval_survives_deploy_merge() {
    # CC re-runs the statusline only on token/mode/model changes, not on a terminal
    # resize, so the right-aligned 5h segment needs statusLine.refreshInterval to follow
    # the window width. Run json-merge.py (the deploy merge) against a live fixture that
    # lacks the key: statusLine is template-authoritative, so the key must arrive.
    local live="$TEST_TMPDIR/live-settings.json" out
    printf '{"model":"opus[1m]","statusLine":{"type":"command","command":"old"}}' > "$live"
    out=$(HOME="$TEST_TMPDIR" python3 "$REPO_ROOT/setup/scripts/json-merge.py" "$REPO_ROOT/setup/config/settings.json" "$live" "$TEST_TMPDIR/no-override.json" \
        | python3 -c 'import json,sys; s=json.load(sys.stdin)["statusLine"]; print(s.get("refreshInterval"), s.get("command"), s.get("type"))')
    assert_eq "$out" "10 bash ~/.claude/statusline-command.sh command" "merged statusLine, interval 10 s (an ungated AFD heartbeat fires per render) (got: $out)"
}
run_test "statusLine.refreshInterval survives the deploy merge" test_statusline_refresh_interval_survives_deploy_merge

test_configure_deploys_statusline_to_claude_dir() {
    local config="$REPO_ROOT/setup/configure-claude.sh"
    assert_file_exists "$config"
    assert_file_contains "$config" 'dest_statusline="${HOME}/.claude/statusline-command.sh"'
    assert_file_contains "$config" 'src_statusline='
}
run_test "configure-claude.sh deploys statusline-command.sh to ~/.claude/" test_configure_deploys_statusline_to_claude_dir

test_statusline_script_reads_active_persona() {
    assert_file_contains "$SCRIPT_PATH" '.active-persona'
    assert_file_contains "$SCRIPT_PATH" 'PERSONA_COLORS'
}
run_test "statusline-command.sh source reads .active-persona and uses PERSONA_COLORS" test_statusline_script_reads_active_persona

suite_summary
