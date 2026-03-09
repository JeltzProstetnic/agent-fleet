#!/usr/bin/env bash
# Tests for the lrn/learn quick command — validates CLAUDE.md integration and protocol structure
source "$(dirname "$0")/test-helpers.sh"

CLAUDE_MD="$REPO_ROOT/global/CLAUDE.md"
LEARN_PROTOCOL="$REPO_ROOT/global/knowledge/learn-protocol.md"

suite_header "lrn/learn quick command"

# ── 1. Quick command table entry ─────────────────────────────────────────────

test_quick_command_entry_exists() {
    assert_file_exists "$CLAUDE_MD"
    local content
    content=$(cat "$CLAUDE_MD")
    # The table row should contain lrn keyword
    assert_contains "$content" '| `lrn`'
}
run_test "quick command table has lrn entry" test_quick_command_entry_exists

test_quick_command_mentions_self_audit() {
    local line
    line=$(grep '| `lrn` |' "$CLAUDE_MD" | head -1)
    assert_contains "$line" "Self-audit"
}
run_test "quick command entry describes self-audit" test_quick_command_mentions_self_audit

test_quick_command_mentions_protocol_file() {
    local line
    line=$(grep '| `lrn` |' "$CLAUDE_MD" | head -1)
    assert_contains "$line" "learn-protocol.md"
}
run_test "quick command entry references learn-protocol.md" test_quick_command_mentions_protocol_file

test_quick_command_mentions_learn_context_sensitivity() {
    local content
    content=$(cat "$CLAUDE_MD")
    # The lrn entry or nearby text should clarify that `learn` is context-sensitive
    assert_contains "$content" 'learn'
    assert_contains "$content" 'context-sensitive'
}
run_test "CLAUDE.md explains learn vs lrn distinction" test_quick_command_mentions_learn_context_sensitivity

# ── 2. Conditional loading trigger ───────────────────────────────────────────

test_conditional_loading_trigger_exists() {
    local content
    content=$(cat "$CLAUDE_MD")
    # Should have a conditional loading row that maps lrn/learn to the protocol file
    assert_contains "$content" 'lrn'
    assert_contains "$content" 'learn-protocol.md'
}
run_test "conditional loading table maps lrn/learn to learn-protocol.md" test_conditional_loading_trigger_exists

test_conditional_loading_in_trigger_section() {
    # The trigger should be in the conditional loading table (between "Conditional loading"
    # and "All paths relative to"), not just anywhere in the file
    local in_section
    in_section=$(sed -n '/Conditional loading/,/All paths relative/p' "$CLAUDE_MD")
    assert_contains "$in_section" "learn-protocol.md"
    assert_contains "$in_section" "lrn"
}
run_test "lrn trigger is in the conditional loading section" test_conditional_loading_in_trigger_section

# ── 3. learn-protocol.md structure ───────────────────────────────────────────

test_protocol_file_exists() {
    assert_file_exists "$LEARN_PROTOCOL"
}
run_test "learn-protocol.md exists" test_protocol_file_exists

test_protocol_main_heading() {
    assert_file_contains "$LEARN_PROTOCOL" "^# Learn Protocol"
}
run_test "protocol has '# Learn Protocol' heading" test_protocol_main_heading

test_protocol_execution_section() {
    assert_file_contains "$LEARN_PROTOCOL" "^## Execution"
}
run_test "protocol has '## Execution' section" test_protocol_execution_section

test_protocol_triage_step() {
    assert_file_contains "$LEARN_PROTOCOL" "^### Step 1 — Triage"
}
run_test "protocol has '### Step 1 — Triage' section" test_protocol_triage_step

test_protocol_triage_is_adaptive() {
    # Triage should mention inline / no subagent — it's an inline assessment step
    local triage_section
    triage_section=$(sed -n '/^### Step 1 — Triage/,/^### /p' "$LEARN_PROTOCOL")
    assert_contains "$triage_section" "no subagent"
}
run_test "triage step is inline (no subagent)" test_protocol_triage_is_adaptive

test_protocol_pick_agents_step() {
    assert_file_contains "$LEARN_PROTOCOL" "^### Step 2 — Pick relevant agents"
}
run_test "protocol has '### Step 2 — Pick relevant agents' section" test_protocol_pick_agents_step

test_protocol_agent_templates_section() {
    assert_file_contains "$LEARN_PROTOCOL" "^### Agent Templates"
}
run_test "protocol has '### Agent Templates' section" test_protocol_agent_templates_section

test_protocol_rule_compliance_agent() {
    assert_file_contains "$LEARN_PROTOCOL" "^#### Rule Compliance Agent"
}
run_test "protocol has Rule Compliance Agent template" test_protocol_rule_compliance_agent

test_protocol_knowledge_capture_agent() {
    assert_file_contains "$LEARN_PROTOCOL" "^#### Knowledge Capture Agent"
}
run_test "protocol has Knowledge Capture Agent template" test_protocol_knowledge_capture_agent

test_protocol_process_architecture_agent() {
    assert_file_contains "$LEARN_PROTOCOL" "^#### Process/Architecture Agent"
}
run_test "protocol has Process/Architecture Agent template" test_protocol_process_architecture_agent

test_protocol_presenting_results_section() {
    assert_file_contains "$LEARN_PROTOCOL" "^## Presenting Results"
}
run_test "protocol has '## Presenting Results' section" test_protocol_presenting_results_section

# ── 4. Agent category table parseability ─────────────────────────────────────

test_agent_table_has_header() {
    local table_section
    table_section=$(sed -n '/^### Step 2 — Pick relevant agents/,/^### /p' "$LEARN_PROTOCOL")
    assert_contains "$table_section" "| Category |"
    assert_contains "$table_section" "When to include"
    assert_contains "$table_section" "Skip when"
}
run_test "agent category table has correct header columns" test_agent_table_has_header

test_agent_table_has_rule_compliance_row() {
    local table_section
    table_section=$(sed -n '/^### Step 2 — Pick relevant agents/,/^### /p' "$LEARN_PROTOCOL")
    assert_contains "$table_section" "Rule Compliance"
}
run_test "agent table has Rule Compliance row" test_agent_table_has_rule_compliance_row

test_agent_table_has_knowledge_capture_row() {
    local table_section
    table_section=$(sed -n '/^### Step 2 — Pick relevant agents/,/^### /p' "$LEARN_PROTOCOL")
    assert_contains "$table_section" "Knowledge Capture"
}
run_test "agent table has Knowledge Capture row" test_agent_table_has_knowledge_capture_row

test_agent_table_has_process_architecture_row() {
    local table_section
    table_section=$(sed -n '/^### Step 2 — Pick relevant agents/,/^### /p' "$LEARN_PROTOCOL")
    assert_contains "$table_section" "Process/Architecture"
}
run_test "agent table has Process/Architecture row" test_agent_table_has_process_architecture_row

test_agent_table_has_at_least_3_data_rows() {
    # Count pipe-delimited table rows (excluding header and separator) in the agent selection section
    local table_section row_count
    table_section=$(sed -n '/^### Step 2 — Pick relevant agents/,/^### /p' "$LEARN_PROTOCOL")
    # Data rows start with | ** (bold category names)
    row_count=$(echo "$table_section" | grep -c '| \*\*' || true)
    if [[ "$row_count" -lt 3 ]]; then
        printf "${RED}    Expected at least 3 data rows, got %d${RESET}\n" "$row_count" >&2
        return 1
    fi
}
run_test "agent table has at least 3 data rows" test_agent_table_has_at_least_3_data_rows

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
