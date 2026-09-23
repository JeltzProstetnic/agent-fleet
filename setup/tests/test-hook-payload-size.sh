#!/usr/bin/env bash
# CFG-527: the SessionStart hook must survive a payload larger than a single argv entry.
#
# WHAT BROKE: config-check.sh passed the assembled additionalContext to `python3 -c … "$MSG"`
# as an ARGV STRING. Linux caps a single argv entry at MAX_ARG_STRLEN = 32 pages = 131,072 bytes
# (this is NOT ARG_MAX, which is ~2 MB and is not what bites). The cfg-agent-fleet inbox extract
# reached 176 KB, so execve returned E2BIG, python3 never ran, stdout was empty — and the script
# still ended `exit 0`. Silent, unlogged, and invisible in the transcript because Claude Code
# writes no hook_success record when stdout is empty. cfg-agent-fleet and a second project started blind
# for twelve days.
#
# The contract these tests defend: SessionStart stdout is either valid JSON carrying the startup
# fields, or nothing at all is wrong. It must NEVER be silently empty because the payload grew.
# CFG-503 defended the same contract from the other side (a bare echo corrupting the JSON).
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/test-check-helpers.sh"

suite_header "SessionStart hook: oversized payload (CFG-527)"

# Build a patched hook whose check modules are a synthetic directory we control, so the test
# does not depend on the real inbox's size — which is exactly the variable that broke this.
_patched_with_payload() {
    local payload_bytes="$1"
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    local checks_dir="$TEST_TMPDIR/checks-$payload_bytes"

    mkdir -p "$mock_home/.claude" "$project_dir" "$checks_dir"
    create_mock_config_repo "$config_repo"

    # One synthetic module. It sets the two identity fields a real session depends on, then pads
    # to the requested size the way 03-inbox-services.sh does — by inlining item text.
    cat > "$checks_dir/01-synthetic.sh" << SYNTH
INBOX_MSG="\${INBOX_MSG:+\$INBOX_MSG | }HOSTNAME: TEST-BOX | PERSONA: TestPersona"
INBOX_MSG="\${INBOX_MSG:+\$INBOX_MSG | }INBOX TASKS for test: \$(printf 'X%.0s' \$(seq 1 $payload_bytes))"
SYNTH

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    # Repoint the checks directory at our synthetic one.
    sed -i "s|^export CONFIG_CHECK_DIR=.*|export CONFIG_CHECK_DIR=\"$checks_dir\"|" "$patched"
    echo "$patched"
}

# Build a patched hook that runs the REAL 06a-session-state.sh (the product, not a
# stand-in) after a padding module that inflates INBOX_MSG first — mirroring reality,
# where 03-inbox-services.sh runs before the identity check does. This is the harness
# for the identity-first tests: the 2026-09-17 incident showed Claude Code spills hook
# output over ~50K chars to a file and injects only a HEAD preview, so identity fields
# assembled at the TAIL were exactly the ones lost.
_patched_with_real_identity() {
    local padding_bytes="$1"
    local config_repo="$TEST_TMPDIR/config-repo-id"
    local mock_home="$TEST_TMPDIR/home-id-$padding_bytes"
    local project_dir="$TEST_TMPDIR/project-id-$padding_bytes"
    local checks_dir="$TEST_TMPDIR/checks-id-$padding_bytes"

    mkdir -p "$mock_home/.claude" "$project_dir" "$checks_dir"
    [ -d "$config_repo" ] || create_mock_config_repo "$config_repo"
    echo "TestPersona" > "$mock_home/.claude/.active-persona"

    # Padding module named to sort BEFORE 06a, the way the inbox extract does.
    cat > "$checks_dir/01-padding.sh" << PAD
INBOX_MSG="\${INBOX_MSG:+\$INBOX_MSG | }INBOX TASKS for test: \$(printf 'X%.0s' \$(seq 1 $padding_bytes))"
PAD
    cp "$REPO_ROOT/global/hooks/checks/06a-session-state.sh" "$checks_dir/"

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    sed -i "s|^export CONFIG_CHECK_DIR=.*|export CONFIG_CHECK_DIR=\"$checks_dir\"|" "$patched"
    echo "$patched"
}

# ── The regression itself ────────────────────────────────────────────────────

test_oversized_payload_still_emits_json() {
    local patched output
    patched=$(_patched_with_payload 200000)   # 200 KB — comfortably past MAX_ARG_STRLEN
    output=$(run_hook "$patched")

    assert_neq "" "$output" "hook must not emit empty stdout on a 200 KB payload"

    echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null
    assert_eq "0" "$?" "output must be valid JSON on a 200 KB payload"
}
run_test "200 KB payload still produces valid JSON" test_oversized_payload_still_emits_json

test_oversized_payload_keeps_identity_fields() {
    local patched output ctx
    patched=$(_patched_with_payload 200000)
    output=$(run_hook "$patched")

    ctx=$(extract_additional_context "$output")

    assert_contains "$ctx" "HOSTNAME: TEST-BOX" "HOSTNAME must survive truncation"
    assert_contains "$ctx" "PERSONA: TestPersona" "PERSONA must survive truncation"
}
run_test "identity fields survive an oversized payload" test_oversized_payload_keeps_identity_fields

test_oversized_payload_is_capped_and_says_so() {
    local patched output ctx len
    patched=$(_patched_with_payload 200000)
    output=$(run_hook "$patched")

    ctx=$(extract_additional_context "$output")
    len=${#ctx}

    # Must be bounded — an unbounded fix trades a silent failure for a context bomb.
    if [ "$len" -gt 70000 ]; then
        echo "  additionalContext was $len chars — expected a cap well under 70000"
    fi
    assert_eq "1" "$([ "$len" -le 70000 ] && echo 1 || echo 0)" "oversized payload must be capped"

    # And truncation must be visible, never silent.
    assert_contains "$ctx" "TRUNCATED" "a truncated payload must say so"
}
run_test "oversized payload is capped and the truncation is visible" test_oversized_payload_is_capped_and_says_so

# ── No regression on the ordinary case ───────────────────────────────────────

test_normal_payload_is_untouched() {
    local patched output ctx
    patched=$(_patched_with_payload 500)
    output=$(run_hook "$patched")

    ctx=$(extract_additional_context "$output")

    assert_contains "$ctx" "HOSTNAME: TEST-BOX" "normal payload keeps its fields"
    assert_not_contains "$ctx" "TRUNCATED" "a normal payload must not be marked truncated"
}
run_test "ordinary payload passes through untruncated" test_normal_payload_is_untouched

# ── Identity-first ordering (2026-09-17 spill incident) ─────────────────────
# Claude Code writes hook output over ~50,000 chars to a file and injects only a
# short HEAD preview (changelog 2.1.89; a third-party report puts the threshold for
# additionalContext at 10,000 with a 2,000-char preview — unverified). Either way
# the preview keeps the HEAD, so the fields a session cannot start without must
# LEAD the payload. These tests assert position, not mere presence — presence is
# what the older tests checked, and it passed while the fleet was broken.

_IDENTITY_HEAD_WINDOW=1000   # identity block is ~150-900 chars; 1000 is generous

test_identity_leads_ordinary_payload() {
    local patched output ctx head
    patched=$(_patched_with_real_identity 10000)   # under any cap — ordering alone
    output=$(run_hook "$patched")
    ctx=$(extract_additional_context "$output")
    head="${ctx:0:$_IDENTITY_HEAD_WINDOW}"

    assert_contains "$head" "HOSTNAME: " "HOSTNAME must be in the first $_IDENTITY_HEAD_WINDOW chars"
    assert_contains "$head" "PERSONA: TestPersona" "PERSONA must be in the first $_IDENTITY_HEAD_WINDOW chars"
    assert_contains "$head" "SESSION_CONTEXT: " "SESSION_CONTEXT must be in the first $_IDENTITY_HEAD_WINDOW chars"
    assert_contains "$head" "HANDOFF: " "HANDOFF must be in the first $_IDENTITY_HEAD_WINDOW chars"
    assert_contains "$head" "PENDING_FILES: " "PENDING_FILES must be in the first $_IDENTITY_HEAD_WINDOW chars"
}
run_test "identity fields lead the payload (survive a head-only preview)" test_identity_leads_ordinary_payload

test_identity_leads_even_when_truncated() {
    local patched output ctx head
    patched=$(_patched_with_real_identity 200000)
    output=$(run_hook "$patched")
    ctx=$(extract_additional_context "$output")
    head="${ctx:0:$_IDENTITY_HEAD_WINDOW}"

    assert_contains "$ctx" "TRUNCATED" "a 200 KB payload must be truncated"
    assert_contains "$head" "HOSTNAME: " "HOSTNAME must still lead a truncated payload"
    assert_contains "$head" "PERSONA: TestPersona" "PERSONA must still lead a truncated payload"
    assert_contains "$head" "SESSION_CONTEXT: " "SESSION_CONTEXT must still lead a truncated payload"
    assert_contains "$head" "HANDOFF: " "HANDOFF must still lead a truncated payload"
    assert_contains "$head" "PENDING_FILES: " "PENDING_FILES must still lead a truncated payload"
}
run_test "identity fields lead even a truncated payload" test_identity_leads_even_when_truncated

# ── Cap below the spill threshold ────────────────────────────────────────────
# The fleet's cap sat at 60,000 — ABOVE the 50,000 spill threshold — so the hook's
# own truncation never fired and the spill did. The emitted context must stay far
# enough under 50,000 that the JSON envelope + escaping cannot push the hook's
# stdout past the threshold either.

test_payload_stays_below_spill_threshold() {
    local patched output ctx ctx_len out_len
    patched=$(_patched_with_payload 200000)
    output=$(run_hook "$patched")
    ctx=$(extract_additional_context "$output")
    ctx_len=${#ctx}
    out_len=${#output}

    if [ "$ctx_len" -gt 46000 ]; then
        echo "  additionalContext was $ctx_len chars — must stay <= 46000 (spill threshold is ~50000)"
    fi
    assert_eq "1" "$([ "$ctx_len" -le 46000 ] && echo 1 || echo 0)" \
        "emitted context must stay below the CC spill threshold with margin"

    if [ "$out_len" -gt 49000 ]; then
        echo "  raw hook stdout was $out_len chars — the JSON envelope must stay under 50000"
    fi
    assert_eq "1" "$([ "$out_len" -le 49000 ] && echo 1 || echo 0)" \
        "raw JSON stdout (what CC actually measures) must stay under the spill threshold"
}
run_test "capped payload stays below the CC 50K spill threshold" test_payload_stays_below_spill_threshold

test_truncation_marker_names_spill_risk() {
    local patched output ctx
    patched=$(_patched_with_payload 200000)
    output=$(run_hook "$patched")
    ctx=$(extract_additional_context "$output")

    assert_contains "$ctx" "spill" \
        "the truncation marker must name the spill-to-disk symptom so a future session recognises it"
}
run_test "truncation marker names the spill risk" test_truncation_marker_names_spill_risk

# ── The mechanism, asserted directly ─────────────────────────────────────────

test_payload_not_passed_as_argv() {
    # The specific defect: a large string handed to an interpreter as an argv entry.
    # Guard the shape, not just the symptom, so the next author does not reintroduce it.
    local violations
    violations=$(grep -nE '(python3|node) -e?c?.*"\$(SYSTEM_MSG|WARNINGS|INBOX_MSG)"' \
        "$REPO_ROOT/global/hooks/config-check.sh" 2>/dev/null || true)

    if [ -n "$violations" ]; then
        echo "  Payload passed as argv (MAX_ARG_STRLEN = 131072 bytes per argument):"
        echo "$violations"
    fi
    assert_eq "" "$violations" "the assembled payload must reach the encoder on stdin, not as argv"
}
run_test "payload reaches the encoder on stdin, not argv" test_payload_not_passed_as_argv

suite_summary
