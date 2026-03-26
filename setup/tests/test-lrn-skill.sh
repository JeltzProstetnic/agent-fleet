#!/usr/bin/env bash
# Tests for the lrn skill — validates SKILL.md structure, rule-writing discipline, and references
source "$(dirname "$0")/test-helpers.sh"

CLAUDE_MD="$REPO_ROOT/global/CLAUDE.md"
SKILL_DIR="$REPO_ROOT/global/skills/lrn"
SKILL_FILE="$SKILL_DIR/SKILL.md"
PATTERNS_FILE="$SKILL_DIR/references/known-faulty-patterns.md"
PRINCIPLES_FILE="$SKILL_DIR/references/rule-writing-principles.md"
OLD_PROTOCOL="$REPO_ROOT/global/knowledge/learn-protocol.md"

suite_header "lrn skill"

# ── 1. Skill file structure ──────────────────────────────────────────────────

test_skill_file_exists() {
    assert_file_exists "$SKILL_FILE"
}
run_test "SKILL.md exists" test_skill_file_exists

test_skill_has_frontmatter() {
    local head
    head=$(head -1 "$SKILL_FILE")
    assert_eq "---" "$head" "SKILL.md should start with YAML frontmatter"
}
run_test "SKILL.md has YAML frontmatter" test_skill_has_frontmatter

test_skill_has_name() {
    assert_file_contains "$SKILL_FILE" "^name: lrn"
}
run_test "SKILL.md declares name: lrn" test_skill_has_name

# ── 2. Audit cycle phases ────────────────────────────────────────────────────

test_skill_has_triage() {
    assert_file_contains "$SKILL_FILE" "[Tt]riage"
}
run_test "SKILL.md contains triage phase" test_skill_has_triage

test_skill_has_root_cause() {
    local content
    content=$(cat "$SKILL_FILE")
    # Must reference root cause analysis (classify/root cause/structural)
    assert_contains "$content" "root cause" || assert_contains "$content" "ROOT CAUSE" || assert_contains "$content" "[Cc]lassify"
}
run_test "SKILL.md contains root cause analysis" test_skill_has_root_cause

test_skill_has_rule_search() {
    local content
    content=$(cat "$SKILL_FILE")
    # Must check for existing rules before proposing new ones
    assert_contains "$content" "rule violated" || assert_contains "$content" "rule present" || assert_contains "$content" "existing"
}
run_test "SKILL.md checks for existing rules" test_skill_has_rule_search

test_skill_has_draft_format() {
    local content
    content=$(cat "$SKILL_FILE")
    assert_contains "$content" "FINDING:"
    assert_contains "$content" "FIX:"
}
run_test "SKILL.md has structured finding/fix format" test_skill_has_draft_format

test_skill_has_pattern_check() {
    local content
    content=$(cat "$SKILL_FILE")
    assert_contains "$content" "Known Faulty Patterns" || assert_contains "$content" "known-faulty-patterns"
}
run_test "SKILL.md references pattern check" test_skill_has_pattern_check

test_skill_has_present_step() {
    local content
    content=$(cat "$SKILL_FILE")
    assert_contains "$content" "Present" || assert_contains "$content" "present"
    assert_contains "$content" "approval" || assert_contains "$content" "approve" || assert_contains "$content" "Approval"
}
run_test "SKILL.md has present-and-approve step" test_skill_has_present_step

# ── 3. Rule-writing discipline ───────────────────────────────────────────────

test_skill_enforces_one_sentence() {
    local content
    content=$(cat "$SKILL_FILE")
    assert_contains "$content" "One sentence" || assert_contains "$content" "one sentence"
}
run_test "SKILL.md enforces one-sentence rule format" test_skill_enforces_one_sentence

test_skill_enforces_flat_imperative() {
    local content
    content=$(cat "$SKILL_FILE")
    assert_contains "$content" "imperative" || assert_contains "$content" "Flat imperative"
}
run_test "SKILL.md enforces flat imperative style" test_skill_enforces_flat_imperative

test_skill_forbids_inline_justification() {
    local content
    content=$(cat "$SKILL_FILE")
    assert_contains "$content" "justification" || assert_contains "$content" "rationale" || assert_contains "$content" "justify"
}
run_test "SKILL.md addresses inline justification" test_skill_forbids_inline_justification

test_skill_has_gate_check() {
    local content
    content=$(cat "$SKILL_FILE")
    assert_contains "$content" "GATE CHECK" || assert_contains "$content" "gate check"
    assert_contains "$content" "Rule exists"
}
run_test "SKILL.md has gate check against 'rule exists' fallacy" test_skill_has_gate_check

# ── 4. No bloat in SKILL.md itself ──────────────────────────────────────────

test_skill_no_ensure_that() {
    assert_file_not_contains "$SKILL_FILE" "ensure that"
}
run_test "SKILL.md avoids 'ensure that'" test_skill_no_ensure_that

test_skill_no_its_important() {
    assert_file_not_contains "$SKILL_FILE" "it's important"
    assert_file_not_contains "$SKILL_FILE" "it is important"
}
run_test "SKILL.md avoids 'it's important'" test_skill_no_its_important

test_skill_no_be_sure_to() {
    assert_file_not_contains "$SKILL_FILE" "be sure to"
}
run_test "SKILL.md avoids 'be sure to'" test_skill_no_be_sure_to

test_skill_under_150_lines() {
    local lines
    lines=$(wc -l < "$SKILL_FILE" | tr -d ' ')
    if [[ "$lines" -gt 150 ]]; then
        printf "${RED}    SKILL.md is %d lines (max 150)${RESET}\n" "$lines" >&2
        return 1
    fi
}
run_test "SKILL.md is under 150 lines" test_skill_under_150_lines

# ── 5. References ────────────────────────────────────────────────────────────

test_patterns_file_exists() {
    assert_file_exists "$PATTERNS_FILE"
}
run_test "known-faulty-patterns.md exists" test_patterns_file_exists

test_principles_file_exists() {
    assert_file_exists "$PRINCIPLES_FILE"
}
run_test "rule-writing-principles.md exists" test_principles_file_exists

test_skill_references_patterns() {
    assert_file_contains "$SKILL_FILE" "known-faulty-patterns"
}
run_test "SKILL.md references known-faulty-patterns.md" test_skill_references_patterns

test_skill_references_principles() {
    assert_file_contains "$SKILL_FILE" "rule-writing-principles"
}
run_test "SKILL.md references rule-writing-principles.md" test_skill_references_principles

# ── 6. CLAUDE.md integration ─────────────────────────────────────────────────

test_claudemd_quick_command_exists() {
    assert_file_contains "$CLAUDE_MD" '| `lrn`'
}
run_test "CLAUDE.md has lrn quick command entry" test_claudemd_quick_command_exists

test_claudemd_quick_command_points_to_skill() {
    local line
    line=$(grep '| `lrn` |' "$CLAUDE_MD" | head -1)
    assert_contains "$line" "SKILL.md" || assert_contains "$line" "skills/lrn"
}
run_test "CLAUDE.md quick command points to skill" test_claudemd_quick_command_points_to_skill

test_claudemd_conditional_loading_points_to_skill() {
    local in_section
    in_section=$(sed -n '/Conditional loading/,/All paths relative/p' "$CLAUDE_MD")
    assert_contains "$in_section" "skills/lrn/SKILL.md"
}
run_test "CLAUDE.md conditional loading points to skill" test_claudemd_conditional_loading_points_to_skill

test_claudemd_no_learn_protocol_reference() {
    local in_section
    in_section=$(sed -n '/Conditional loading/,/All paths relative/p' "$CLAUDE_MD")
    if echo "$in_section" | grep -q "learn-protocol\.md"; then
        printf "${RED}    Conditional loading still references learn-protocol.md${RESET}\n" >&2
        return 1
    fi
}
run_test "CLAUDE.md conditional loading does NOT reference learn-protocol.md" test_claudemd_no_learn_protocol_reference

# ── 7. Old protocol deprecated ───────────────────────────────────────────────

test_old_protocol_deprecated() {
    if [[ ! -f "$OLD_PROTOCOL" ]]; then
        # File deleted entirely — acceptable
        return 0
    fi
    # If it still exists, it should contain a deprecation notice
    if ! grep -qE '([Dd]eprecated|[Mm]oved|[Rr]eplaced|skills/lrn)' "$OLD_PROTOCOL"; then
        printf "${RED}    learn-protocol.md exists but has no deprecation notice${RESET}\n" >&2
        return 1
    fi
}
run_test "old learn-protocol.md is deprecated or deleted" test_old_protocol_deprecated

# ── 8. Tier hierarchy ────────────────────────────────────────────────────────

test_skill_has_tier_hierarchy() {
    local content
    content=$(cat "$SKILL_FILE")
    assert_contains "$content" "hook" || assert_contains "$content" "Hook"
    assert_contains "$content" "backlog" || assert_contains "$content" "Backlog"
    assert_contains "$content" "CLAUDE.md"
}
run_test "SKILL.md has tier hierarchy (hook > backlog > CLAUDE.md)" test_skill_has_tier_hierarchy

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
