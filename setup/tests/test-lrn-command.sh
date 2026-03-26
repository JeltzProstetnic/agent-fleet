#!/usr/bin/env bash
# Tests for the lrn quick command — validates CLAUDE.md integration
# Skill structure tests are in test-lrn-skill.sh
source "$(dirname "$0")/test-helpers.sh"

CLAUDE_MD="$REPO_ROOT/global/CLAUDE.md"
SKILL_FILE="$REPO_ROOT/global/skills/lrn/SKILL.md"
OLD_PROTOCOL="$REPO_ROOT/global/knowledge/learn-protocol.md"

suite_header "lrn/learn quick command"

# ── 1. Quick command table entry ─────────────────────────────────────────────

test_quick_command_entry_exists() {
    assert_file_exists "$CLAUDE_MD"
    local content
    content=$(cat "$CLAUDE_MD")
    assert_contains "$content" '| `lrn`'
}
run_test "quick command table has lrn entry" test_quick_command_entry_exists

test_quick_command_mentions_self_audit() {
    local line
    line=$(grep '| `lrn` |' "$CLAUDE_MD" | head -1)
    assert_contains "$line" "Self-audit"
}
run_test "quick command entry describes self-audit" test_quick_command_mentions_self_audit

test_quick_command_points_to_skill() {
    local line
    line=$(grep '| `lrn` |' "$CLAUDE_MD" | head -1)
    assert_contains "$line" "SKILL.md" || assert_contains "$line" "skills/lrn"
}
run_test "quick command entry references skills/lrn/SKILL.md" test_quick_command_points_to_skill

test_quick_command_mentions_learn_context_sensitivity() {
    local content
    content=$(cat "$CLAUDE_MD")
    assert_contains "$content" 'learn'
    assert_contains "$content" 'context-sensitive'
}
run_test "CLAUDE.md explains learn vs lrn distinction" test_quick_command_mentions_learn_context_sensitivity

# ── 2. Conditional loading trigger ───────────────────────────────────────────

test_conditional_loading_points_to_skill() {
    local in_section
    in_section=$(sed -n '/Conditional loading/,/All paths relative/p' "$CLAUDE_MD")
    assert_contains "$in_section" "skills/lrn/SKILL.md"
    assert_contains "$in_section" "lrn"
}
run_test "conditional loading table maps lrn to skills/lrn/SKILL.md" test_conditional_loading_points_to_skill

# ── 3. Skill file exists ─────────────────────────────────────────────────────

test_skill_file_exists() {
    assert_file_exists "$SKILL_FILE"
}
run_test "skills/lrn/SKILL.md exists" test_skill_file_exists

# ── 4. Old protocol deprecated ───────────────────────────────────────────────

test_old_protocol_deprecated() {
    if [[ ! -f "$OLD_PROTOCOL" ]]; then
        return 0
    fi
    if ! grep -qE '([Dd]eprecated|[Mm]oved|[Rr]eplaced|skills/lrn)' "$OLD_PROTOCOL"; then
        printf "${RED}    learn-protocol.md exists but has no deprecation notice${RESET}\n" >&2
        return 1
    fi
}
run_test "old learn-protocol.md is deprecated or deleted" test_old_protocol_deprecated

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
