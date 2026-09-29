#!/usr/bin/env bash
# Tests for check 6d: blocked-on-consent backlog items (CFG-695)
# Items parked behind a consent step nobody requests are indistinguishable from
# dropped items — CFG-597 sat 11 days that way and recurred as CFG-693. The
# check lists every OPEN item marked as needing consent, every session, in the
# same 0-token channel as STALE_AWAIT. TDD: written before the implementation.
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/test-check-helpers.sh"

suite_header "config-check.sh: blocked-on-consent items (check 6d)"

# Shared fixture: mock config repo + project dir; the backlog is the caller's.
_bc_setup() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    # Without these, PLUGIN_INTEGRITY fires, is joined with ";" and _bc_field swallows it.
    create_mock_plugin_files "$mock_home"
    create_patched_script "$config_repo" "$mock_home" "$project_dir"
}

_bc_field() {
    printf '%s' "$1" | grep -oE 'BLOCKED_ON_CONSENT:[^|]*' | head -1
}

test_open_consent_items_listed_with_count() {
    local patched; patched=$(_bc_setup)
    cat > "$TEST_TMPDIR/project/backlog.md" <<'EOF'
# Backlog
- [ ] [P3] `CFG-637` **Rule proposal (needs Meta-Rules consent): decisions.md size threshold.** Filed by a sibling project.
- [ ] [P2] `CFG-638` **Rule proposal (needs Meta-Rules consent): ban blind replace_all.** Filed by a sibling project.
- [ ] [P1] `CFG-640` **git-sync-check still reports Up to date over a conflicted tree.** Nothing to do with consent forms.
- [ ] [P1] `CFG-697` **vault-ops.md and postal-dispatch.md contradict each other.** One sentence needs his consent because it is rule text.
EOF
    local output field
    output=$(run_hook "$patched")
    field=$(_bc_field "$output")
    assert_contains "$field" "3 open item" "count of consent-blocked items" || return 1
    assert_contains "$field" "CFG-637" || return 1
    assert_contains "$field" "CFG-638" || return 1
    assert_contains "$field" "CFG-697" "'needs his consent … rule text' is the same gate" || return 1
    assert_not_contains "$field" "CFG-640" "an item merely mentioning the word is not listed"
}
run_test "check 6d: open items marked as needing consent are listed with count + IDs" test_open_consent_items_listed_with_count

test_closed_items_and_absent_backlog_silent() {
    local patched; patched=$(_bc_setup)
    cat > "$TEST_TMPDIR/project/backlog.md" <<'EOF'
# Backlog
- [x] [P2] `CFG-603` **Rule proposal (needs Meta-Rules consent): probe before contradicting.** DONE 2026-09-20, MG approved.
- [ ] [P1] `CFG-433` **Cred mesh.** Blocked on user: verify the OAuth consent screen status in GCP Console.
EOF
    local output
    output=$(run_hook "$patched")
    assert_not_contains "$output" "BLOCKED_ON_CONSENT:" "closed items and a GCP consent screen are not the consent gate" || return 1

    rm -f "$TEST_TMPDIR/project/backlog.md"
    output=$(run_hook "$patched")
    assert_not_contains "$output" "BLOCKED_ON_CONSENT:" "no backlog → silent"
}
run_test "check 6d: closed items, unrelated 'consent', and a missing backlog stay silent" test_closed_items_and_absent_backlog_silent

# The real CFG-695 case: the marker is an HTML comment ABOVE the items, naming
# them — "CFG-596 and CFG-597 both propose RULE changes and are blocked on
# Meta-Rules consent". Only the IDs whose own line is still open are listed.
test_header_comment_marks_items() {
    local patched; patched=$(_bc_setup)
    cat > "$TEST_TMPDIR/project/backlog.md" <<'EOF'
# Backlog
<!-- CFG-596..599 promoted 2026-09-14 from the inbox. CFG-596 and CFG-597 both propose RULE changes and are blocked on Meta-Rules consent. -->
- [ ] [P1] `CFG-596` **A session can draft a grievance letter on MG's behalf without asking what his grievance is.**
- [x] [P0] `CFG-597` **CLOSED 2026-09-23 by CFG-693.**
- [ ] [P2] `CFG-598` **Something else entirely.**
EOF
    local output field
    output=$(run_hook "$patched")
    field=$(_bc_field "$output")
    assert_contains "$field" "1 open item" || return 1
    assert_contains "$field" "CFG-596" "named in the comment and still open → listed" || return 1
    assert_not_contains "$field" "CFG-597" "named in the comment but closed → not listed" || return 1
    assert_not_contains "$field" "CFG-598" "not named by the comment → not listed"
}
run_test "check 6d: IDs named in a consent header comment are listed while open" test_header_comment_marks_items

# CFG-708 follow-up 2026-09-29: once the owner has answered, the item's own line records it
# (APPROVED / No consent needed / reclassified) while keeping its historical "needs
# consent" wording. Such items are no longer parked on consent and must not be listed —
# also when a header comment names them.
test_resolved_items_not_listed() {
    local patched; patched=$(_bc_setup)
    cat > "$TEST_TMPDIR/project/backlog.md" <<'EOF'
# Backlog
<!-- CFG-596 and CFG-599 both propose RULE changes and are blocked on Meta-Rules consent. -->
- [ ] [P1] `CFG-596` **APPROVED by owner 2026-09-29 (rule) — persist after the Meta-Rules check.** A session can draft a grievance letter.
- [ ] [P1] `CFG-599` **Still waiting.** Something the owner has not seen.
- [ ] [P3] `CFG-637` **APPROVED by owner 2026-09-29 as: regular reviews.** **Rule proposal (needs Meta-Rules consent): decisions.md size.**
- [ ] [P2] `CFG-698` **No consent needed (rule approved 2026-09-23); hook work only.** Fold into the blocked-on-consent listing, needs consent wording kept.
- [ ] [P1] `CFG-489` **Target is knowledge/ — reclassified by owner 2026-09-29.** Consent needed only if it goes into CLAUDE.md.
- [ ] [P2] `CFG-638` **Rule proposal (needs Meta-Rules consent): ban blind replace_all.**
EOF
    local output field
    output=$(run_hook "$patched")
    field=$(_bc_field "$output")
    assert_contains "$field" "2 open item" "only the two unresolved items" || return 1
    assert_contains "$field" "CFG-599"
    assert_contains "$field" "CFG-638"
    assert_not_contains "$field" "CFG-596" "comment-named but APPROVED on its own line"
    assert_not_contains "$field" "CFG-637" "APPROVED"
    assert_not_contains "$field" "CFG-698" "No consent needed"
    assert_not_contains "$field" "CFG-489" "reclassified"
}
run_test "check 6d: items whose own line records the answer are not listed" test_resolved_items_not_listed

test_output_is_bounded() {
    local patched; patched=$(_bc_setup)
    {
        echo "# Backlog"
        for i in $(seq 1 15); do
            printf -- '- [ ] [P2] `CFG-9%02d` **Rule proposal (needs Meta-Rules consent): item %d.**\n' "$i" "$i"
        done
    } > "$TEST_TMPDIR/project/backlog.md"
    local output field
    output=$(run_hook "$patched")
    field=$(_bc_field "$output")
    assert_contains "$field" "15 open item" "full count is reported" || return 1
    assert_contains "$field" "CFG-910" "first ten IDs are shown" || return 1
    assert_not_contains "$field" "CFG-911" "IDs past the cap are not spelled out" || return 1
    assert_contains "$field" "+5 more" "the overflow is counted" || return 1
    [ "${#field}" -lt 400 ] || { echo "field too long: ${#field} chars" >&2; return 1; }
}
run_test "check 6d: listing is capped at ten IDs plus an overflow count" test_output_is_bounded

test_lands_in_warning_channel() {
    local patched; patched=$(_bc_setup)
    printf '# Backlog\n- [ ] [P2] `CFG-612` **Rule widening (needs Meta-Rules consent): subagent findings are hypotheses.**\n' \
        > "$TEST_TMPDIR/project/backlog.md"
    local output ctx
    output=$(run_hook "$patched")
    ctx=$(extract_additional_context "$output")
    assert_contains "$ctx" "WARNING:" "must-surface class lives in the WARNING channel, like STALE_AWAIT" || return 1
    assert_contains "$ctx" "BLOCKED_ON_CONSENT: 1 open item" || return 1
    assert_contains "$ctx" "CFG-612"
}
run_test "check 6d: the field arrives in additionalContext under WARNING" test_lands_in_warning_channel

suite_summary
