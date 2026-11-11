#!/usr/bin/env bash
# Tests for global/hooks/lib-pending-work.sh (CFG-948): the parsed work-item
# state block in docs/pending-*.md:
#   <!-- Work: stage=<word>; status=<open|blocked|awaiting-proof|done>; next=<one line>; approved=<YYYY-MM-DD who|none> -->
source "$(dirname "$0")/test-helpers.sh"

LIB="$REPO_ROOT/global/hooks/lib-pending-work.sh"

suite_header "lib-pending-work.sh (CFG-948 work block)"

_pf() { printf '%s\n' "$@" > "$TEST_TMPDIR/pending-x.md"; printf '%s' "$TEST_TMPDIR/pending-x.md"; }

test_valid_comment_block_summary() {
    local f; f=$(_pf '<!-- Action: act -->' '<!-- Tracked-by: CFG-948 -->' \
        '<!-- Work: stage=build; status=open; next=run E2E in podman; approved=2026-11-11 MG -->' '' 'body')
    source "$LIB"
    local s rc=0; s=$(pending_work_summary "$f") || rc=$?
    echo "    measured: summary=[$s] rc=$rc"
    assert_eq "build/open: run E2E in podman" "$s" "compact form is stage/status: next"
    pending_work_parse "$f" || true
    assert_eq "open" "${_pw_status:-}" "status field parsed"
    assert_eq "2026-11-11 MG" "${_pw_approved:-}" "approved field parsed"
    assert_eq "" "${_pw_error:-}" "valid block has no error"
}
run_test "valid comment-form block → stage/status: next" test_valid_comment_block_summary

test_absent_block_is_empty() {
    local f; f=$(_pf '<!-- Action: act -->' 'no work block here')
    source "$LIB"
    local s rc=0; s=$(pending_work_summary "$f") || rc=$?
    assert_eq "" "$s" "no block → empty summary"
    assert_eq "1" "$rc" "no block → rc 1"
}
run_test "absent block → empty summary, rc 1" test_absent_block_is_empty

test_bad_status_is_malformed() {
    local f; f=$(_pf '<!-- Action: act -->' '<!-- Work: stage=build; status=wip; next=x; approved=none -->')
    source "$LIB"
    local s rc=0; s=$(pending_work_summary "$f") || rc=$?
    echo "    measured: summary=[$s] rc=$rc"
    assert_contains "$s" "MALFORMED:" "bad status is flagged"
    assert_contains "$s" "status=wip" "the offending value is named"
    assert_eq "2" "$rc" "malformed → rc 2"
}
run_test "status outside the enum → MALFORMED naming the value" test_bad_status_is_malformed

test_bare_form_parses() {
    local f; f=$(_pf 'Action: act' 'Work: stage=review; status=awaiting-proof; next=wait for MG; approved=none')
    source "$LIB"
    local s; s=$(pending_work_summary "$f") || true
    assert_eq "review/awaiting-proof: wait for MG" "$s" "bare (non-comment) form parses like the Action: header"
}
run_test "bare form without comment markers parses" test_bare_form_parses

test_missing_stage_is_malformed() {
    local f; f=$(_pf '<!-- Work: status=open; next=x -->')
    source "$LIB"
    local s; s=$(pending_work_summary "$f") || true
    assert_contains "$s" "MALFORMED:" "missing stage is flagged"
    assert_contains "$s" "stage" "the missing field is named"
}
run_test "missing stage → MALFORMED naming stage" test_missing_stage_is_malformed

test_unknown_key_is_malformed() {
    local f; f=$(_pf '<!-- Work: stage=build; state=open; next=x -->')
    source "$LIB"
    local s; s=$(pending_work_summary "$f") || true
    assert_contains "$s" "MALFORMED:" "unknown key is flagged (catches typos like state=)"
    assert_contains "$s" "state" "the unknown key is named"
}
run_test "unknown key → MALFORMED naming the key" test_unknown_key_is_malformed

test_bad_approved_is_malformed() {
    local f; f=$(_pf '<!-- Work: stage=build; status=open; next=x; approved=yesterday -->')
    source "$LIB"
    local s; s=$(pending_work_summary "$f") || true
    assert_contains "$s" "MALFORMED:" "approved must be none or YYYY-MM-DD who"
    assert_contains "$s" "approved=yesterday" "the offending value is named"
}
run_test "approved not 'none' nor 'YYYY-MM-DD who' → MALFORMED" test_bad_approved_is_malformed

test_long_next_is_truncated() {
    local long; long=$(printf 'x%.0s' $(seq 1 120))
    local f; f=$(_pf "<!-- Work: stage=build; status=open; next=$long; approved=none -->")
    source "$LIB"
    local s; s=$(pending_work_summary "$f") || true
    local bounded="no"; [ "${#s}" -le 90 ] && bounded="yes"
    echo "    measured: length=${#s} bounded=$bounded"
    assert_eq "yes" "$bounded" "summary length bounded (next truncated to 70 chars)"
    assert_contains "$s" "build/open: " "stage/status still lead the summary"
}
run_test "a long next= is truncated so the identity payload stays bounded" test_long_next_is_truncated

test_any_order_and_no_next() {
    local f; f=$(_pf '<!-- Work: approved=2026-11-11 MG; status=done; stage=ship -->')
    source "$LIB"
    local s; s=$(pending_work_summary "$f") || true
    assert_eq "ship/done" "$s" "fields in any order; no next → stage/status only"
}
run_test "fields in any order, next omitted → stage/status" test_any_order_and_no_next

suite_summary
