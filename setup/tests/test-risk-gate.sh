#!/usr/bin/env bash
# Tests for risk-gate.sh PreToolUse hook
# Verifies T1 edits are blocked without clearance, allowed with fresh clearance,
# and that T2/T3/non-infrastructure files pass through.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

HOOK="$SCRIPT_DIR/../../global/hooks/risk-gate.sh"

suite_header "Risk Gate Hook Tests"

# Helper: simulate a PreToolUse hook call
run_gate() {
    local tool_name="$1"
    local file_path="$2"
    local mock_home="${3:-$TEST_TMPDIR/home}"

    local input
    if [ "$tool_name" = "Write" ]; then
        input="{\"tool_name\":\"$tool_name\",\"tool_input\":{\"file_path\":\"$file_path\",\"content\":\"test\"}}"
    elif [ "$tool_name" = "Edit" ]; then
        input="{\"tool_name\":\"$tool_name\",\"tool_input\":{\"file_path\":\"$file_path\",\"old_string\":\"a\",\"new_string\":\"b\"}}"
    else
        input="{\"tool_name\":\"$tool_name\",\"tool_input\":{\"command\":\"echo hi\"}}"
    fi

    echo "$input" | HOME="$mock_home" bash "$HOOK" 2>&1
}

# ── T1 Blocking Tests ──

test_blocks_mclaude_without_clearance() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.local/bin"

    local output rc=0
    output=$(run_gate "Write" "$mock_home/.local/bin/mclaude" "$mock_home") || rc=$?

    assert_eq "2" "$rc" "Should block mclaude edit without clearance"
    assert_contains "$output" "RISK_GATE TIER 1" "Should include RISK_GATE TIER 1 in message"
}

test_blocks_afleet_without_clearance() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.local/bin"

    local output rc=0
    output=$(run_gate "Edit" "$mock_home/.local/bin/afleet" "$mock_home") || rc=$?

    assert_eq "2" "$rc" "Should block afleet edit without clearance"
    assert_contains "$output" "RISK_GATE TIER 1" "Should include tier label"
}

test_blocks_settings_json_without_clearance() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.cc-mirror/mclaude/config"

    local output rc=0
    output=$(run_gate "Write" "$mock_home/.cc-mirror/mclaude/config/settings.json" "$mock_home") || rc=$?

    assert_eq "2" "$rc" "Should block settings.json edit without clearance"
    assert_contains "$output" "RISK_GATE TIER 1" "Should include tier label"
}

test_blocks_mcp_json_without_clearance() {
    local mock_home="$TEST_TMPDIR/home"

    local output rc=0
    output=$(run_gate "Edit" "$mock_home/.mcp.json" "$mock_home") || rc=$?

    assert_eq "2" "$rc" "Should block .mcp.json edit without clearance"
}

test_blocks_sync_sh_without_clearance() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/cfg-agent-fleet"

    local output rc=0
    output=$(run_gate "Write" "$mock_home/cfg-agent-fleet/sync.sh" "$mock_home") || rc=$?

    assert_eq "2" "$rc" "Should block cfg-agent-fleet/sync.sh edit without clearance"
}

test_blocks_agent_fleet_sync_sh() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/agent-fleet"

    local output rc=0
    output=$(run_gate "Write" "$mock_home/agent-fleet/sync.sh" "$mock_home") || rc=$?

    assert_eq "2" "$rc" "Should block agent-fleet/sync.sh edit without clearance"
}

# ── Clearance Tests ──

test_allows_with_fresh_clearance() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.local/bin"

    local file_path="$mock_home/.local/bin/mclaude"
    local hash
    hash=$(echo "$file_path" | md5sum | cut -c1-16)
    touch "/tmp/.risk-gate-clearance-${hash}"

    local output rc=0
    output=$(run_gate "Write" "$file_path" "$mock_home") || rc=$?

    rm -f "/tmp/.risk-gate-clearance-${hash}"
    assert_eq "0" "$rc" "Should allow T1 edit with fresh clearance"
}

test_blocks_with_stale_clearance() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.local/bin"

    local file_path="$mock_home/.local/bin/mclaude"
    local hash
    hash=$(echo "$file_path" | md5sum | cut -c1-16)
    local clearance_file="/tmp/.risk-gate-clearance-${hash}"
    touch -d "15 minutes ago" "$clearance_file"

    local output rc=0
    output=$(run_gate "Write" "$file_path" "$mock_home") || rc=$?

    rm -f "$clearance_file"
    assert_eq "2" "$rc" "Should block T1 edit with stale (>10 min) clearance"
}

test_clearance_is_per_file() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.local/bin" "$mock_home/.cc-mirror/mclaude/config"

    # Create clearance for mclaude only
    local mclaude_path="$mock_home/.local/bin/mclaude"
    local mclaude_hash
    mclaude_hash=$(echo "$mclaude_path" | md5sum | cut -c1-16)
    touch "/tmp/.risk-gate-clearance-${mclaude_hash}"

    # mclaude should pass
    local rc1=0
    run_gate "Write" "$mclaude_path" "$mock_home" >/dev/null 2>&1 || rc1=$?

    # settings.json should still block
    local settings_path="$mock_home/.cc-mirror/mclaude/config/settings.json"
    local rc2=0
    run_gate "Write" "$settings_path" "$mock_home" >/dev/null 2>&1 || rc2=$?

    rm -f "/tmp/.risk-gate-clearance-${mclaude_hash}"

    assert_eq "0" "$rc1" "mclaude should pass with its own clearance"
    assert_eq "2" "$rc2" "settings.json should still block without its own clearance"
}

# ── Pass-Through Tests ──

test_t2_files_pass_through() {
    local mock_home="$TEST_TMPDIR/home"

    local output rc=0
    output=$(run_gate "Write" "$mock_home/.claude/hooks/some-hook.sh" "$mock_home") || rc=$?

    assert_eq "0" "$rc" "T2 files (hooks) should pass through"
}

test_t3_files_pass_through() {
    local mock_home="$TEST_TMPDIR/home"

    local output rc=0
    output=$(run_gate "Edit" "$mock_home/.claude/reference/some-ref.md" "$mock_home") || rc=$?

    assert_eq "0" "$rc" "T3 files (reference) should pass through"
}

test_non_write_tools_ignored() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.local/bin"

    local output rc=0
    output=$(run_gate "Bash" "$mock_home/.local/bin/mclaude" "$mock_home") || rc=$?

    assert_eq "0" "$rc" "Non-Write/Edit tools should be ignored"
}

test_regular_project_files_pass() {
    local mock_home="$TEST_TMPDIR/home"

    local output rc=0
    output=$(run_gate "Write" "$mock_home/my-project/src/main.py" "$mock_home") || rc=$?

    assert_eq "0" "$rc" "Regular project files should pass through"
}

# ── Stderr Message Content Tests ──

test_stderr_includes_instructions() {
    local mock_home="$TEST_TMPDIR/home"
    mkdir -p "$mock_home/.local/bin"

    local output rc=0
    output=$(run_gate "Write" "$mock_home/.local/bin/mclaude" "$mock_home") || rc=$?

    assert_contains "$output" "risk-analysis-protocol.md" "Should reference protocol file"
    assert_contains "$output" "clearance" "Should mention clearance"
}

# ── Fingerprinted clearance (CFG-949) ──
# A clearance records sha256 of the exact payload the risk subagent assessed
# (Write: content; Edit: old_string + new_string + replace_all). The gate
# blocks when the payload about to be written differs. TTL stays as a second
# limit; an old-format (empty, touch) clearance still passes until it expires,
# with a one-line warning.

# Build a PreToolUse JSON payload from raw strings (jq handles the escaping).
#   gate_json Write <file_path> <content>
#   gate_json Edit  <file_path> <old> <new> [true|false]
gate_json() {
    jq -cn --arg t "$1" --arg f "$2" --arg a "$3" --arg b "${4:-}" --arg r "${5:-false}" '
        if $t == "Write" then {tool_name: $t, tool_input: {file_path: $f, content: $a}}
        else {tool_name: $t, tool_input: {file_path: $f, old_string: $a, new_string: $b, replace_all: ($r == "true")}} end'
}
run_gate_json() { echo "$1" | HOME="$2" bash "$HOOK" 2>&1; }
clearance_path_for() { printf '/tmp/.risk-gate-clearance-%s' "$(echo "$1" | md5sum | cut -c1-16)"; }

test_fingerprint_verb_is_deterministic_and_tool_bound() {
    local d="$TEST_TMPDIR/fp"; mkdir -p "$d"
    printf 'line one\nline two\n' > "$d/content.txt"
    printf 'line one\n' > "$d/old.txt"; printf 'line two\n' > "$d/new.txt"
    local w1 w2 e1 e2 e3
    w1=$(bash "$HOOK" fingerprint write "$d/content.txt")
    w2=$(bash "$HOOK" fingerprint write "$d/content.txt")
    e1=$(bash "$HOOK" fingerprint edit "$d/old.txt" "$d/new.txt")
    e2=$(bash "$HOOK" fingerprint edit "$d/old.txt" "$d/new.txt" --replace-all)
    e3=$(bash "$HOOK" fingerprint edit "$d/new.txt" "$d/old.txt")
    echo "    measured: write=$w1 edit=$e1 edit-all=$e2"
    assert_eq "$w1" "$w2" "fingerprint write is deterministic"
    assert_eq "64" "${#w1}" "fingerprint is 64 hex chars"
    assert_neq "$w1" "$e1" "write and edit fingerprints differ for the same bytes"
    assert_neq "$e1" "$e2" "replace_all changes the edit fingerprint"
    assert_neq "$e1" "$e3" "swapping old/new changes the edit fingerprint"
}

test_clearance_verb_writes_fingerprint_file() {
    local mock_home="$TEST_TMPDIR/home"; mkdir -p "$mock_home/.local/bin" "$TEST_TMPDIR/fp"
    local file_path="$mock_home/.local/bin/mclaude" cl; cl=$(clearance_path_for "$file_path")
    printf 'exec old\n' > "$TEST_TMPDIR/fp/old.txt"; printf 'exec new\n' > "$TEST_TMPDIR/fp/new.txt"
    local out fp
    out=$(bash "$HOOK" clearance "$file_path" edit "$TEST_TMPDIR/fp/old.txt" "$TEST_TMPDIR/fp/new.txt" 2>&1)
    fp=$(bash "$HOOK" fingerprint edit "$TEST_TMPDIR/fp/old.txt" "$TEST_TMPDIR/fp/new.txt")
    local line; line=$(cat "$cl" 2>/dev/null); rm -f "$cl"
    echo "    measured: clearance line=[$line]"
    assert_eq "sha256=$fp" "$line" "clearance file holds sha256=<fingerprint of the edit payload>"
    assert_contains "$out" "$cl" "the verb names the clearance path it wrote"
}

test_matching_edit_fingerprint_passes() {
    local mock_home="$TEST_TMPDIR/home"; mkdir -p "$mock_home/.local/bin" "$TEST_TMPDIR/fp"
    local file_path="$mock_home/.local/bin/mclaude" cl; cl=$(clearance_path_for "$file_path")
    printf 'exec "old"\n' > "$TEST_TMPDIR/fp/old.txt"; printf 'exec "new"\n' > "$TEST_TMPDIR/fp/new.txt"
    bash "$HOOK" clearance "$file_path" edit "$TEST_TMPDIR/fp/old.txt" "$TEST_TMPDIR/fp/new.txt" >/dev/null 2>&1
    # $(cat; printf x) + ${var%x} keeps the files' trailing newlines byte-exact.
    local old new; old=$(cat "$TEST_TMPDIR/fp/old.txt"; printf x); old=${old%x}; new=$(cat "$TEST_TMPDIR/fp/new.txt"; printf x); new=${new%x}
    local output rc=0
    output=$(run_gate_json "$(gate_json Edit "$file_path" "$old" "$new" false)" "$mock_home") || rc=$?
    rm -f "$cl"
    echo "    measured: rc=$rc output=[$output]"
    assert_eq "0" "$rc" "Edit whose old/new match the cleared fingerprint passes"
    assert_not_contains "$output" "no fingerprint" "a fingerprinted clearance raises no old-format warning"
}

test_changed_edit_after_clearance_blocks_naming_mismatch() {
    local mock_home="$TEST_TMPDIR/home"; mkdir -p "$mock_home/.local/bin" "$TEST_TMPDIR/fp"
    local file_path="$mock_home/.local/bin/mclaude" cl; cl=$(clearance_path_for "$file_path")
    printf 'exec old\n' > "$TEST_TMPDIR/fp/old.txt"; printf 'exec new\n' > "$TEST_TMPDIR/fp/new.txt"
    bash "$HOOK" clearance "$file_path" edit "$TEST_TMPDIR/fp/old.txt" "$TEST_TMPDIR/fp/new.txt" >/dev/null 2>&1
    local cleared; cleared=$(sed -n 's/^sha256=//p' "$cl")
    local output rc=0
    output=$(run_gate_json "$(gate_json Edit "$file_path" $'exec old\n' $'exec new; rm -rf /\n' false)" "$mock_home") || rc=$?
    rm -f "$cl"
    echo "    measured: rc=$rc"
    assert_eq "2" "$rc" "an Edit whose new_string changed after clearance is blocked"
    assert_contains "$output" "RISK_GATE TIER 1" "block carries the tier label"
    assert_contains "$output" "changed after clearance" "block names the reason: payload changed after clearance"
    assert_contains "$output" "${cleared:0:12}" "block names the cleared fingerprint"
}

test_write_clearance_does_not_cover_an_edit() {
    local mock_home="$TEST_TMPDIR/home"; mkdir -p "$mock_home/.local/bin" "$TEST_TMPDIR/fp"
    local file_path="$mock_home/.local/bin/mclaude" cl; cl=$(clearance_path_for "$file_path")
    printf 'exec new\n' > "$TEST_TMPDIR/fp/content.txt"
    bash "$HOOK" clearance "$file_path" write "$TEST_TMPDIR/fp/content.txt" >/dev/null 2>&1
    local output rc=0
    output=$(run_gate_json "$(gate_json Edit "$file_path" "exec old" $'exec new\n' false)" "$mock_home") || rc=$?
    rm -f "$cl"
    assert_eq "2" "$rc" "a clearance fingerprinted for a Write blocks an Edit (different operation)"
    assert_contains "$output" "changed after clearance" "block names the mismatch"
}

test_replace_all_flip_blocks() {
    local mock_home="$TEST_TMPDIR/home"; mkdir -p "$mock_home/.local/bin" "$TEST_TMPDIR/fp"
    local file_path="$mock_home/.local/bin/mclaude" cl; cl=$(clearance_path_for "$file_path")
    printf 'a' > "$TEST_TMPDIR/fp/old.txt"; printf 'b' > "$TEST_TMPDIR/fp/new.txt"
    bash "$HOOK" clearance "$file_path" edit "$TEST_TMPDIR/fp/old.txt" "$TEST_TMPDIR/fp/new.txt" >/dev/null 2>&1
    local output rc=0
    output=$(run_gate_json "$(gate_json Edit "$file_path" a b true)" "$mock_home") || rc=$?
    rm -f "$cl"
    assert_eq "2" "$rc" "replace_all=true against a single-replacement clearance is blocked"
    assert_contains "$output" "changed after clearance" "blocked for the mismatch, not for a missing clearance"
}

test_matching_write_fingerprint_passes() {
    local mock_home="$TEST_TMPDIR/home"; mkdir -p "$mock_home/cfg-agent-fleet" "$TEST_TMPDIR/fp"
    local file_path="$mock_home/cfg-agent-fleet/sync.sh" cl; cl=$(clearance_path_for "$file_path")
    printf '#!/usr/bin/env bash\necho "deploy"\n' > "$TEST_TMPDIR/fp/content.txt"
    bash "$HOOK" clearance "$file_path" write "$TEST_TMPDIR/fp/content.txt" >/dev/null 2>&1
    local content; content=$(cat "$TEST_TMPDIR/fp/content.txt"; printf x); content=${content%x}
    local rc=0
    run_gate_json "$(gate_json Write "$file_path" "$content")" "$mock_home" >/dev/null 2>&1 || rc=$?
    rm -f "$cl"
    assert_eq "0" "$rc" "Write whose content matches the cleared fingerprint passes"
}

test_old_format_clearance_passes_with_warning() {
    local mock_home="$TEST_TMPDIR/home"; mkdir -p "$mock_home/.local/bin"
    local file_path="$mock_home/.local/bin/mclaude" cl; cl=$(clearance_path_for "$file_path")
    touch "$cl"
    local output rc=0
    output=$(run_gate_json "$(gate_json Edit "$file_path" a b false)" "$mock_home") || rc=$?
    rm -f "$cl"
    echo "    measured: rc=$rc output=[$output]"
    assert_eq "0" "$rc" "old-format (touch) clearance still passes within the TTL"
    assert_contains "$output" "no fingerprint" "old-format clearance raises a one-line warning"
}

test_expired_fingerprinted_clearance_blocks() {
    local mock_home="$TEST_TMPDIR/home"; mkdir -p "$mock_home/.local/bin" "$TEST_TMPDIR/fp"
    local file_path="$mock_home/.local/bin/mclaude" cl; cl=$(clearance_path_for "$file_path")
    printf 'a' > "$TEST_TMPDIR/fp/old.txt"; printf 'b' > "$TEST_TMPDIR/fp/new.txt"
    bash "$HOOK" clearance "$file_path" edit "$TEST_TMPDIR/fp/old.txt" "$TEST_TMPDIR/fp/new.txt" >/dev/null 2>&1
    touch -d "15 minutes ago" "$cl"
    local output rc=0
    output=$(run_gate_json "$(gate_json Edit "$file_path" a b false)" "$mock_home") || rc=$?
    rm -f "$cl"
    assert_eq "2" "$rc" "a matching fingerprint does not rescue an expired clearance (TTL is the second limit)"
    assert_contains "$output" "expired" "block says the clearance expired"
}

test_malformed_fingerprint_line_blocks() {
    local mock_home="$TEST_TMPDIR/home"; mkdir -p "$mock_home/.local/bin"
    local file_path="$mock_home/.local/bin/mclaude" cl; cl=$(clearance_path_for "$file_path")
    printf 'sha256=not-a-hash\n' > "$cl"
    local output rc=0
    output=$(run_gate_json "$(gate_json Edit "$file_path" a b false)" "$mock_home") || rc=$?
    rm -f "$cl"
    assert_eq "2" "$rc" "a clearance with a malformed sha256 line fails closed"
    assert_contains "$output" "malformed" "block names the malformed fingerprint"
}

# ── Run ──

run_test "blocks mclaude Write without clearance" test_blocks_mclaude_without_clearance
run_test "blocks afleet Edit without clearance" test_blocks_afleet_without_clearance
run_test "blocks settings.json Write without clearance" test_blocks_settings_json_without_clearance
run_test "blocks .mcp.json Edit without clearance" test_blocks_mcp_json_without_clearance
run_test "blocks cfg-agent-fleet/sync.sh Write without clearance" test_blocks_sync_sh_without_clearance
run_test "blocks agent-fleet/sync.sh Write without clearance" test_blocks_agent_fleet_sync_sh
run_test "allows T1 edit with fresh clearance file" test_allows_with_fresh_clearance
run_test "blocks T1 edit with stale clearance (>10 min)" test_blocks_with_stale_clearance
run_test "clearance is per-file (mclaude clearance doesn't clear settings.json)" test_clearance_is_per_file
run_test "T2 files (hooks) pass through" test_t2_files_pass_through
run_test "T3 files (reference) pass through" test_t3_files_pass_through
run_test "non-Write/Edit tools ignored" test_non_write_tools_ignored
run_test "regular project files pass through" test_regular_project_files_pass
run_test "stderr includes protocol reference and clearance instructions" test_stderr_includes_instructions
run_test "CFG-949: fingerprint verb is deterministic, tool-bound, replace_all-aware" test_fingerprint_verb_is_deterministic_and_tool_bound
run_test "CFG-949: clearance verb writes sha256=<fingerprint> to the per-file clearance" test_clearance_verb_writes_fingerprint_file
run_test "CFG-949: Edit matching the cleared fingerprint passes without warning" test_matching_edit_fingerprint_passes
run_test "CFG-949: Edit changed after clearance blocks, naming the mismatch" test_changed_edit_after_clearance_blocks_naming_mismatch
run_test "CFG-949: a Write clearance does not cover an Edit" test_write_clearance_does_not_cover_an_edit
run_test "CFG-949: replace_all flip after clearance blocks" test_replace_all_flip_blocks
run_test "CFG-949: Write matching the cleared fingerprint passes" test_matching_write_fingerprint_passes
run_test "CFG-949: old-format (touch) clearance passes with a one-line warning" test_old_format_clearance_passes_with_warning
run_test "CFG-949: expired fingerprinted clearance blocks as before" test_expired_fingerprinted_clearance_blocks
run_test "CFG-949: malformed sha256 line fails closed" test_malformed_fingerprint_line_blocks

suite_summary
