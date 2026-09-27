#!/usr/bin/env bash
# Tests for setup/scripts/handover-check.sh — CFG-204.
#
# LRN audit 2026-03-16: the agent said "I'll add" an item to the handoff and didn't; the
# user caught it. rotate-session.sh carries `## Next Session Task` into next-session-task.md
# mechanically, but `## Recovery Instructions` only goes to session-history.md, which the
# next session reads on demand only. So an item promised in Recovery Instructions and never
# written into the handover silently falls out of view. The check: every Recovery item
# must be carried by the handover — the Next Session Task section plus the file its
# `file:` line points at. An item that names task IDs is carried when every ID appears;
# an item without IDs must appear as written (markdown and case ignored).
source "$(dirname "$0")/test-helpers.sh"

CHECK="$REPO_ROOT/setup/scripts/handover-check.sh"
ROTATE="$REPO_ROOT/setup/scripts/rotate-session.sh"

suite_header "handover-check.sh (CFG-204)"

# _ctx <recovery-body> <next-task-body>
_ctx() {
    mkdir -p "$TEST_TMPDIR/docs"
    cat > "$TEST_TMPDIR/session-context.md" <<EOF
# Session Context

## Session Info
- **Last Updated**: 2026-09-25T10:00Z
- **Machine**: test-box
- **Working Directory**: /tmp/test
- **Session Goal**: Ship the thing

## Current State
- **Active Task**: x
- **Progress** (use \`- [x]\` checkbox for each completed item):
  - [x] Did the first part
- **Pending**: —

## Key Decisions

## Recovery Instructions
$1

## Next Session Task
$2
EOF
}

_pending() { printf '%s\n' "$1" > "$TEST_TMPDIR/docs/pending-x.md"; }

# Sets RC and OUT in the caller's shell (a $(…) wrapper would lose OUT).
_run() { RC=0; OUT=$(bash "$CHECK" "$TEST_TMPDIR" 2>&1) || RC=$?; }

t_all_carried_verbatim() {
    _ctx "- Re-run the migration on the NUC
- Ask MG about the **retention** window" "task: true
file: docs/pending-x.md
backlog: none
description: resume"
    _pending "# Pending
- Re-run the migration on the NUC
- Ask MG about the retention window"
    _run; assert_eq "0" "$RC" "every item is in the pending file"
}
run_test "passes when every Recovery item is in the handover file" t_all_carried_verbatim

t_missing_item_flagged() {
    _ctx "- Re-run the migration on the NUC
- Tell MG the backup is 3 days stale" "task: true
file: docs/pending-x.md
backlog: none
description: resume"
    _pending "- Re-run the migration on the NUC"
    _run
    assert_eq "1" "$RC" "an uncarried item must fail the check" || return 1
    assert_contains "$OUT" "Tell MG the backup is 3 days stale" "the missing item must be named"
}
run_test "fails and names an item the handover does not carry" t_missing_item_flagged

t_id_carries_paraphrase() {
    _ctx "- Finish CFG-204 (the handover diff) and close CFG-205" "task: true
file: docs/pending-x.md
backlog: CFG-204
description: finish the handover check, then CFG-205"
    _pending "Nothing else."
    _run; assert_eq "0" "$RC" "an item's task IDs carry it even when reworded"
}
run_test "an item whose task IDs all appear is carried" t_id_carries_paraphrase

t_missing_id_flagged() {
    _ctx "- Finish CFG-204 and close CFG-205" "task: true
file: docs/pending-x.md
backlog: CFG-204
description: finish the handover check"
    _pending "Nothing else."
    _run; assert_eq "1" "$RC" "CFG-205 appears nowhere in the handover"
}
run_test "an item with an ID missing from the handover fails" t_missing_id_flagged

t_next_task_section_counts() {
    _ctx "- Deploy the hook to the Deck" "task: true
file: docs/pending-x.md
backlog: none
description: Deploy the hook to the Deck"
    _pending "Nothing."
    _run; assert_eq "0" "$RC" "the Next Session Task section itself is part of the handover"
}
run_test "the Next Session Task section itself counts as handover" t_next_task_section_counts

t_empty_recovery_passes() {
    _ctx "" "task: false"
    _run; assert_eq "0" "$RC" "nothing promised, nothing to carry"
}
run_test "empty Recovery Instructions pass" t_empty_recovery_passes

t_placeholders_ignored() {
    _ctx "<!-- fill in at shutdown -->
- —
- none" "task: false"
    _run; assert_eq "0" "$RC" "comments and placeholders are not items"
}
run_test "comments and placeholder bullets are ignored" t_placeholders_ignored

t_missing_file_target() {
    _ctx "- Re-run the migration on the NUC" "task: true
file: docs/pending-gone.md
backlog: none
description: resume"
    _run; assert_eq "1" "$RC" "a file: that does not exist carries nothing"
}
run_test "a missing file: target carries nothing" t_missing_file_target

t_rotate_warns_but_rotates() {
    _ctx "- Tell MG the backup is 3 days stale" "task: true
file: docs/pending-x.md
backlog: none
description: resume"
    _pending "Nothing."
    local out rc=0
    out=$(bash "$ROTATE" "$TEST_TMPDIR" 2>&1) || rc=$?
    assert_eq "0" "$rc" "rotation must not be blocked (it also runs in SessionEnd)" || return 1
    assert_contains "$out" "Tell MG the backup is 3 days stale" "rotation must warn, naming the uncarried item" || return 1
    assert_file_contains "$TEST_TMPDIR/session-history.md" "Ship the thing" "and still rotate"
}
run_test "rotate-session.sh warns about uncarried items and still rotates" t_rotate_warns_but_rotates

t_rotate_silent_when_carried() {
    _ctx "- Re-run the migration on the NUC" "task: true
file: docs/pending-x.md
backlog: none
description: resume"
    _pending "- Re-run the migration on the NUC"
    local out
    out=$(bash "$ROTATE" "$TEST_TMPDIR" 2>&1) || true
    assert_not_contains "$out" "CFG-204" "no handover warning when everything is carried"
}
run_test "rotate-session.sh is quiet when the handover carries everything" t_rotate_silent_when_carried

suite_summary
