#!/usr/bin/env bash
# Tests for rotate-session.sh
source "$(dirname "$0")/test-helpers.sh"

ROTATE_SCRIPT="$REPO_ROOT/setup/scripts/rotate-session.sh"

suite_header "rotate-session.sh"

# ── Blank/missing detection ──────────────────────────────────────────────────

test_no_session_file() {
    local out
    out=$(bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" 2>&1)
    assert_contains "$out" "nothing to rotate"
    assert_file_not_exists "$TEST_TMPDIR/session-history.md"
}
run_test "exits cleanly when session-context.md doesn't exist" test_no_session_file

test_empty_session_file() {
    touch "$TEST_TMPDIR/session-context.md"
    local out
    out=$(bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" 2>&1)
    assert_contains "$out" "empty"
    assert_file_not_exists "$TEST_TMPDIR/session-history.md"
}
run_test "exits cleanly when session-context.md is empty" test_empty_session_file

test_blank_template_no_goal() {
    # Template with no goal should fail
    cat > "$TEST_TMPDIR/session-context.md" <<'EOF'
# Session Context

## Session Info
- **Last Updated**:
- **Machine**:
- **Working Directory**:
- **Session Goal**:

## Current State
- **Active Task**:
- **Progress** (use `- [x]` checkbox for each completed item):
- **Pending**:

## Key Decisions

## Recovery Instructions
EOF
    local rc=0
    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" 2>&1 || rc=$?
    assert_eq "0" "$rc" "should exit 0 silently for blank template (no-op, not error)"
}
run_test "exits silently on blank template (no goal)" test_blank_template_no_goal

test_goal_but_no_content() {
    # Has a goal but no completed items and no decisions
    cat > "$TEST_TMPDIR/session-context.md" <<'EOF'
# Session Context

## Session Info
- **Last Updated**: 2026-01-15T10:00Z
- **Machine**: test-box
- **Working Directory**: /tmp/test
- **Session Goal**: Quick check on something

## Current State
- **Active Task**: Nothing
- **Progress** (use `- [x]` checkbox for each completed item):
- **Pending**: Nothing

## Key Decisions

## Recovery Instructions
EOF
    local rc=0
    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" 2>&1 || rc=$?
    assert_eq "1" "$rc" "should exit 1 — goal without content"
}
run_test "rejects goal-only session (no completed items or decisions)" test_goal_but_no_content

# ── Successful rotation ─────────────────────────────────────────────────────

test_basic_rotation() {
    create_session_context "$TEST_TMPDIR" "Build feature X" "my-machine"
    local out
    out=$(bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" 2>&1)

    assert_contains "$out" "Rotation complete"
    assert_file_exists "$TEST_TMPDIR/session-history.md"
    assert_file_exists "$TEST_TMPDIR/docs/session-log.md"

    # History should contain the goal
    assert_file_contains "$TEST_TMPDIR/session-history.md" "Build feature X"
    # Log should contain the goal
    assert_file_contains "$TEST_TMPDIR/docs/session-log.md" "Build feature X"
}
run_test "basic rotation creates history and log entries" test_basic_rotation

test_session_context_reset() {
    create_session_context "$TEST_TMPDIR" "Do stuff" "box1"
    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1

    # Session context should be reset to blank template
    assert_file_not_contains "$TEST_TMPDIR/session-context.md" "Do stuff"
    # Template has "- **Session Goal**:" with nothing after the colon (or just whitespace)
    assert_file_contains "$TEST_TMPDIR/session-context.md" 'Session Goal'
    assert_file_not_contains "$TEST_TMPDIR/session-context.md" "Do stuff"
}
run_test "session-context.md is reset to blank template after rotation" test_session_context_reset

test_machine_in_entry() {
    create_session_context "$TEST_TMPDIR" "Test machine" "steam-deck-42"
    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1

    assert_file_contains "$TEST_TMPDIR/session-history.md" "steam-deck-42"
}
run_test "machine name appears in history entry" test_machine_in_entry

test_completed_items_in_entry() {
    local items="  - [x] First thing done
  - [x] Second thing done
  - [ ] Not done yet"
    create_session_context "$TEST_TMPDIR" "Multi-item test" "box" "$items"
    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1

    # Should contain completed items (without checkbox)
    assert_file_contains "$TEST_TMPDIR/session-history.md" "First thing done"
    assert_file_contains "$TEST_TMPDIR/session-history.md" "Second thing done"
    # Should NOT contain unchecked items
    assert_file_not_contains "$TEST_TMPDIR/session-history.md" "Not done yet"
}
run_test "completed items (checkboxes) are extracted correctly" test_completed_items_in_entry

test_decisions_in_entry() {
    create_session_context "$TEST_TMPDIR" "Decision test" "box"
    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1

    assert_file_contains "$TEST_TMPDIR/session-history.md" "Test decision"
}
run_test "key decisions appear in history entry" test_decisions_in_entry

# ── Session with only decisions (no completed items) ─────────────────────────

test_decisions_only_session() {
    cat > "$TEST_TMPDIR/session-context.md" <<'EOF'
# Session Context

## Session Info
- **Last Updated**: 2026-02-01T12:00Z
- **Machine**: test-box
- **Working Directory**: /tmp
- **Session Goal**: Discuss architecture

## Current State
- **Active Task**: Discussion
- **Progress** (use `- [x]` checkbox for each completed item):
- **Pending**: Nothing

## Key Decisions
- Decided to use PostgreSQL instead of SQLite
- Agreed on REST API over GraphQL

## Recovery Instructions
1. Start implementing the API
EOF
    mkdir -p "$TEST_TMPDIR/docs"
    local out
    out=$(bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" 2>&1)
    assert_contains "$out" "Rotation complete"
    assert_file_contains "$TEST_TMPDIR/session-history.md" "PostgreSQL"
    assert_file_contains "$TEST_TMPDIR/session-history.md" "REST API"
}
run_test "accepts session with decisions but no completed items" test_decisions_only_session

# ── History rolling window (max 3) ──────────────────────────────────────────

test_history_rolling_window() {
    mkdir -p "$TEST_TMPDIR/docs"

    # Create and rotate 5 sessions
    for i in 1 2 3 4 5; do
        create_session_context "$TEST_TMPDIR" "Session $i" "box"
        bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1
    done

    # History should have exactly 3 entries (sessions 5, 4, 3)
    local entry_count
    entry_count=$(grep -c '^### ' "$TEST_TMPDIR/session-history.md" || echo "0")
    assert_eq "3" "$entry_count" "history should have exactly 3 entries"

    # Should contain sessions 5, 4, 3 (newest first)
    assert_file_contains "$TEST_TMPDIR/session-history.md" "Session 5"
    assert_file_contains "$TEST_TMPDIR/session-history.md" "Session 4"
    assert_file_contains "$TEST_TMPDIR/session-history.md" "Session 3"

    # Should NOT contain sessions 1 and 2
    assert_file_not_contains "$TEST_TMPDIR/session-history.md" "Session 1"
    assert_file_not_contains "$TEST_TMPDIR/session-history.md" "Session 2"
}
run_test "history maintains rolling window of 3 entries" test_history_rolling_window

# ── Log never prunes ────────────────────────────────────────────────────────

test_log_never_prunes() {
    mkdir -p "$TEST_TMPDIR/docs"

    # Create and rotate 5 sessions
    for i in 1 2 3 4 5; do
        create_session_context "$TEST_TMPDIR" "Session $i" "box"
        bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1
    done

    # Log should have all 5 entries
    local entry_count
    entry_count=$(grep -c '^### ' "$TEST_TMPDIR/docs/session-log.md" || echo "0")
    assert_eq "5" "$entry_count" "log should have all 5 entries"

    # All sessions should be in log
    for i in 1 2 3 4 5; do
        assert_file_contains "$TEST_TMPDIR/docs/session-log.md" "Session $i"
    done
}
run_test "session log retains all entries (never prunes)" test_log_never_prunes

# ── Newest first ordering ───────────────────────────────────────────────────

test_newest_first_ordering() {
    mkdir -p "$TEST_TMPDIR/docs"

    create_session_context "$TEST_TMPDIR" "First session" "box"
    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1

    create_session_context "$TEST_TMPDIR" "Second session" "box"
    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1

    # In both history and log, "Second session" should appear BEFORE "First session"
    local first_pos second_pos
    first_pos=$(grep -n "First session" "$TEST_TMPDIR/session-history.md" | head -1 | cut -d: -f1)
    second_pos=$(grep -n "Second session" "$TEST_TMPDIR/session-history.md" | head -1 | cut -d: -f1)

    # second_pos should be smaller (earlier in file) than first_pos
    [[ "$second_pos" -lt "$first_pos" ]] || {
        echo "    FAIL: Second session (line $second_pos) should appear before First session (line $first_pos)" >&2
        return 1
    }
}
run_test "entries are ordered newest first" test_newest_first_ordering

# ── Recovery instructions preserved ─────────────────────────────────────────

test_recovery_instructions() {
    cat > "$TEST_TMPDIR/session-context.md" <<'EOF'
# Session Context

## Session Info
- **Last Updated**: 2026-02-01T12:00Z
- **Machine**: test-box
- **Working Directory**: /tmp
- **Session Goal**: Setup database

## Current State
- **Active Task**: DB migration
- **Progress** (use `- [x]` checkbox for each completed item):
  - [x] Created migration script
- **Pending**: Run migration

## Key Decisions
- Using PostgreSQL 16

## Recovery Instructions
1. Run `python manage.py migrate`
2. Verify tables created
3. Seed test data
EOF
    mkdir -p "$TEST_TMPDIR/docs"
    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1

    assert_file_contains "$TEST_TMPDIR/session-history.md" "Recovery/Next session"
    assert_file_contains "$TEST_TMPDIR/session-history.md" "manage.py migrate"
}
run_test "recovery instructions are preserved in history entry" test_recovery_instructions

# ── Pending items preserved ──────────────────────────────────────────────────

test_pending_items() {
    cat > "$TEST_TMPDIR/session-context.md" <<'EOF'
# Session Context

## Session Info
- **Last Updated**: 2026-02-01T12:00Z
- **Machine**: test-box
- **Working Directory**: /tmp
- **Session Goal**: API work

## Current State
- **Active Task**: Endpoint implementation
- **Progress** (use `- [x]` checkbox for each completed item):
  - [x] Designed API schema
- **Pending**: Write integration tests

## Key Decisions
- REST over GraphQL

## Recovery Instructions
EOF
    mkdir -p "$TEST_TMPDIR/docs"
    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1

    assert_file_contains "$TEST_TMPDIR/session-history.md" "Pending at shutdown"
    assert_file_contains "$TEST_TMPDIR/session-history.md" "Write integration tests"
}
run_test "pending items appear in history entry" test_pending_items

# ── Case-insensitive checkbox matching ───────────────────────────────────────

test_case_insensitive_checkbox() {
    local items="  - [X] Uppercase checkbox item
  - [x] Lowercase checkbox item"
    create_session_context "$TEST_TMPDIR" "Case test" "box" "$items"
    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1

    assert_file_contains "$TEST_TMPDIR/session-history.md" "Uppercase checkbox item"
    assert_file_contains "$TEST_TMPDIR/session-history.md" "Lowercase checkbox item"
}
run_test "handles both [x] and [X] checkboxes" test_case_insensitive_checkbox

# ── Creates docs directory if missing ────────────────────────────────────────

test_creates_docs_dir() {
    create_session_context "$TEST_TMPDIR" "Dir creation test" "box"
    # Remove docs dir that create_session_context made
    rm -rf "$TEST_TMPDIR/docs"

    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1

    assert_dir_exists "$TEST_TMPDIR/docs"
    assert_file_exists "$TEST_TMPDIR/docs/session-log.md"
}
run_test "creates docs/ directory if it doesn't exist" test_creates_docs_dir

# ── Reminder about decisions.md ──────────────────────────────────────────────

test_decisions_reminder() {
    create_session_context "$TEST_TMPDIR" "Reminder test" "box"
    local out
    out=$(bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" 2>&1)

    assert_contains "$out" "decisions.md"
}
run_test "prints reminder about decisions.md" test_decisions_reminder

# ── Template help text not treated as completed ──────────────────────────────

test_template_text_not_extracted() {
    # The template contains "- [x]" in help text like "(use `- [x]` checkbox...)"
    # This should NOT be treated as a completed item
    cat > "$TEST_TMPDIR/session-context.md" <<'EOF'
# Session Context

## Session Info
- **Last Updated**: 2026-02-01T12:00Z
- **Machine**: test-box
- **Working Directory**: /tmp
- **Session Goal**: Template edge case test

## Current State
- **Active Task**: Testing
- **Progress** (use `- [x]` checkbox for each completed item):
  - [x] Actually completed this task
- **Pending**: Nothing

## Key Decisions
- Test decision

## Recovery Instructions
EOF
    mkdir -p "$TEST_TMPDIR/docs"
    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1

    # Should have the actual completed item
    assert_file_contains "$TEST_TMPDIR/session-history.md" "Actually completed this task"
    # Should NOT have the template help text as a completed item
    assert_file_not_contains "$TEST_TMPDIR/session-history.md" "checkbox for each"
}
run_test "template help text not extracted as completed items" test_template_text_not_extracted

# ── Fix A: Dangling reference detection ──────────────────────────────────────

test_dangling_ref_see_below() {
    cat > "$TEST_TMPDIR/session-context.md" <<'EOF'
# Session Context

## Session Info
- **Last Updated**: 2026-03-03T20:00Z
- **Machine**: test-box
- **Working Directory**: /tmp
- **Session Goal**: Audit infrastructure

## Current State
- **Active Task**: Audit
- **Progress** (use `- [x]` checkbox for each completed item):
  - [x] Completed audit scan
- **Pending**: Execute the plan (see below)

## Key Decisions
- Decided on 5-phase approach

## Recovery Instructions
1. Execute the meta-plan (see below)

## Meta-Plan
Phase 1: Fix item A
Phase 2: Fix item B
EOF
    mkdir -p "$TEST_TMPDIR/docs"
    local out
    out=$(bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" 2>&1)

    # Should still rotate (warning, not blocking)
    assert_contains "$out" "Rotation complete"
    # Should emit a warning about dangling references
    assert_contains "$out" "WARNING"
    assert_contains "$out" "forward reference"
}
run_test "warns on dangling reference: 'see below'" test_dangling_ref_see_below

test_dangling_ref_see_section() {
    cat > "$TEST_TMPDIR/session-context.md" <<'EOF'
# Session Context

## Session Info
- **Last Updated**: 2026-03-03T20:00Z
- **Machine**: test-box
- **Working Directory**: /tmp
- **Session Goal**: Build meta-plan

## Current State
- **Active Task**: Planning
- **Progress** (use `- [x]` checkbox for each completed item):
  - [x] Created the plan
- **Pending**: Nothing

## Key Decisions
- See the ## Meta-Plan section for details

## Recovery Instructions
1. Follow the meta-plan

## Meta-Plan
Step 1: Do things
EOF
    mkdir -p "$TEST_TMPDIR/docs"
    local out
    out=$(bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" 2>&1)

    assert_contains "$out" "Rotation complete"
    assert_contains "$out" "WARNING"
}
run_test "warns on dangling reference: 'see ## Section'" test_dangling_ref_see_section

test_dangling_ref_see_the_section() {
    cat > "$TEST_TMPDIR/session-context.md" <<'EOF'
# Session Context

## Session Info
- **Last Updated**: 2026-03-03T20:00Z
- **Machine**: test-box
- **Working Directory**: /tmp
- **Session Goal**: Plan execution

## Current State
- **Active Task**: Execution
- **Progress** (use `- [x]` checkbox for each completed item):
  - [x] Wrote the plan
- **Pending**: See the execution section for next steps

## Key Decisions
- Decided to batch tasks

## Recovery Instructions
EOF
    mkdir -p "$TEST_TMPDIR/docs"
    local out
    out=$(bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" 2>&1)

    assert_contains "$out" "WARNING"
    assert_contains "$out" "forward reference"
}
run_test "warns on dangling reference: 'see the ... section'" test_dangling_ref_see_the_section

test_dangling_ref_below_parenthetical() {
    cat > "$TEST_TMPDIR/session-context.md" <<'EOF'
# Session Context

## Session Info
- **Last Updated**: 2026-03-03T20:00Z
- **Machine**: test-box
- **Working Directory**: /tmp
- **Session Goal**: Task planning

## Current State
- **Active Task**: Planning
- **Progress** (use `- [x]` checkbox for each completed item):
  - [x] Created plan (below)
- **Pending**: Nothing

## Key Decisions
- Batch approach chosen

## Recovery Instructions
EOF
    mkdir -p "$TEST_TMPDIR/docs"
    local out
    out=$(bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" 2>&1)

    assert_contains "$out" "WARNING"
}
run_test "warns on dangling reference: '(below)'" test_dangling_ref_below_parenthetical

test_no_dangling_ref_warning_when_clean() {
    create_session_context "$TEST_TMPDIR" "Clean session" "box"
    local out
    out=$(bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" 2>&1)

    assert_contains "$out" "Rotation complete"
    assert_not_contains "$out" "WARNING"
}
run_test "no dangling reference warning for clean session" test_no_dangling_ref_warning_when_clean

# ── Fix B: Next-session task extraction ──────────────────────────────────────

test_next_session_task_extracted() {
    cat > "$TEST_TMPDIR/session-context.md" <<'EOF'
# Session Context

## Session Info
- **Last Updated**: 2026-03-03T23:00Z
- **Machine**: test-box
- **Working Directory**: /tmp/myproject
- **Session Goal**: Audit infrastructure

## Current State
- **Active Task**: Audit
- **Progress** (use `- [x]` checkbox for each completed item):
  - [x] Completed scan
- **Pending**: Execute meta-plan

## Key Decisions
- 5-phase approach

## Recovery Instructions
1. Start with phase 1

## Next Session Task
task: true
file: docs/audit-2026-03-03.md
description: Execute audit fix meta-plan, Phase 1-5
EOF
    mkdir -p "$TEST_TMPDIR/docs"
    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1

    assert_file_exists "$TEST_TMPDIR/next-session-task.md"
    assert_file_contains "$TEST_TMPDIR/next-session-task.md" "task: true"
    assert_file_contains "$TEST_TMPDIR/next-session-task.md" "file: docs/audit-2026-03-03.md"
    assert_file_contains "$TEST_TMPDIR/next-session-task.md" "description: Execute audit fix meta-plan"
}
run_test "extracts ## Next Session Task to next-session-task.md" test_next_session_task_extracted

test_next_session_task_false_when_absent() {
    create_session_context "$TEST_TMPDIR" "Normal session" "box"
    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1

    assert_file_exists "$TEST_TMPDIR/next-session-task.md"
    assert_file_contains "$TEST_TMPDIR/next-session-task.md" "task: false"
    assert_file_not_contains "$TEST_TMPDIR/next-session-task.md" "file:"
    assert_file_not_contains "$TEST_TMPDIR/next-session-task.md" "description:"
}
run_test "writes task: false when no ## Next Session Task section" test_next_session_task_false_when_absent

test_next_session_task_multiline() {
    cat > "$TEST_TMPDIR/session-context.md" <<'EOF'
# Session Context

## Session Info
- **Last Updated**: 2026-03-03T23:00Z
- **Machine**: test-box
- **Working Directory**: /tmp
- **Session Goal**: Complex planning

## Current State
- **Active Task**: Planning
- **Progress** (use `- [x]` checkbox for each completed item):
  - [x] Created multi-phase plan
- **Pending**: Execute

## Key Decisions
- Multi-phase approach

## Recovery Instructions

## Next Session Task
task: true
file: docs/master-plan.md
description: Execute phases 1-3 of the master plan
priority: high
context: Previous session identified 12 issues requiring fixes
EOF
    mkdir -p "$TEST_TMPDIR/docs"
    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1

    assert_file_exists "$TEST_TMPDIR/next-session-task.md"
    assert_file_contains "$TEST_TMPDIR/next-session-task.md" "task: true"
    assert_file_contains "$TEST_TMPDIR/next-session-task.md" "priority: high"
    assert_file_contains "$TEST_TMPDIR/next-session-task.md" "context: Previous session"
}
run_test "preserves all key-value lines from ## Next Session Task" test_next_session_task_multiline

test_next_session_task_overwrites_previous() {
    mkdir -p "$TEST_TMPDIR/docs"

    # First rotation with a task
    cat > "$TEST_TMPDIR/session-context.md" <<'EOF'
# Session Context

## Session Info
- **Last Updated**: 2026-03-03T20:00Z
- **Machine**: test-box
- **Working Directory**: /tmp
- **Session Goal**: Session one

## Current State
- **Active Task**: Work
- **Progress** (use `- [x]` checkbox for each completed item):
  - [x] Did the thing
- **Pending**: Nothing

## Key Decisions
- Decided

## Recovery Instructions

## Next Session Task
task: true
file: docs/plan-a.md
description: Old task from session one
EOF
    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1
    assert_file_contains "$TEST_TMPDIR/next-session-task.md" "Old task from session one"

    # Second rotation without a task — should overwrite to task: false
    create_session_context "$TEST_TMPDIR" "Session two" "box"
    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1

    assert_file_contains "$TEST_TMPDIR/next-session-task.md" "task: false"
    assert_file_not_contains "$TEST_TMPDIR/next-session-task.md" "Old task from session one"
}
run_test "next-session-task.md is overwritten on each rotation" test_next_session_task_overwrites_previous

test_next_session_task_not_in_history() {
    cat > "$TEST_TMPDIR/session-context.md" <<'EOF'
# Session Context

## Session Info
- **Last Updated**: 2026-03-03T23:00Z
- **Machine**: test-box
- **Working Directory**: /tmp
- **Session Goal**: Task extraction test

## Current State
- **Active Task**: Test
- **Progress** (use `- [x]` checkbox for each completed item):
  - [x] Set up next session task
- **Pending**: Nothing

## Key Decisions
- Using next-session-task mechanism

## Recovery Instructions

## Next Session Task
task: true
file: docs/secret-plan.md
description: This should not leak into history
EOF
    mkdir -p "$TEST_TMPDIR/docs"
    bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" >/dev/null 2>&1

    # The Next Session Task section should NOT appear in the history/log entries
    assert_file_not_contains "$TEST_TMPDIR/session-history.md" "secret-plan.md"
    assert_file_not_contains "$TEST_TMPDIR/docs/session-log.md" "secret-plan.md"
}
run_test "## Next Session Task content does not leak into history entries" test_next_session_task_not_in_history

# ── Duplicate pending file detection ─────────────────────────────────────────

test_warns_multiple_pending_files_same_date() {
    # Setup: valid session-context.md
    cat > "$TEST_TMPDIR/session-context.md" <<'EOF'
# Session Context
## Session Info
- **Last Updated**: 2026-03-08T20:00:00Z
- **Machine**: test
- **Session Goal**: Test duplicate pending detection

## Current State
- [x] Did work

## Key Decisions
EOF
    mkdir -p "$TEST_TMPDIR/docs"
    # Create multiple pending files "today"
    echo "# Pending A" > "$TEST_TMPDIR/docs/pending-task-a.md"
    echo "# Pending B" > "$TEST_TMPDIR/docs/pending-task-b.md"
    echo "# Pending C" > "$TEST_TMPDIR/docs/pending-task-c.md"
    # Touch all to today
    touch "$TEST_TMPDIR/docs/pending-task-a.md" "$TEST_TMPDIR/docs/pending-task-b.md" "$TEST_TMPDIR/docs/pending-task-c.md"

    local out
    out=$(bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" 2>&1)
    assert_contains "$out" "pending" "should mention pending files"
}
run_test "warns when multiple pending-*.md files exist from today" test_warns_multiple_pending_files_same_date

test_no_warning_single_pending_file() {
    cat > "$TEST_TMPDIR/session-context.md" <<'EOF'
# Session Context
## Session Info
- **Last Updated**: 2026-03-08T20:00:00Z
- **Machine**: test
- **Session Goal**: Test single pending

## Current State
- [x] Did work

## Key Decisions
EOF
    mkdir -p "$TEST_TMPDIR/docs"
    echo "# Pending" > "$TEST_TMPDIR/docs/pending-single.md"

    local out
    out=$(bash "$ROTATE_SCRIPT" "$TEST_TMPDIR" 2>&1)
    # Should NOT warn about multiple pending files
    assert_not_contains "$out" "Multiple pending" "single pending file should not trigger warning"
}
run_test "no warning when only one pending file exists" test_no_warning_single_pending_file

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
