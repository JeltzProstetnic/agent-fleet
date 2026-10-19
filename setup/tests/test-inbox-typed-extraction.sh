#!/usr/bin/env bash
# Tests for the SessionStart extractor half of CFG-541 (type-aware delivery)
# and CFG-543 (dated-item expiry lane), both in global/hooks/checks/03-inbox-services.sh.
#
# CFG-541: a receiving session must be able to see WHICH of its items are free to
# execute. `fact` items are minutes of work needing nobody's permission; they were
# never hard, only unrecognisable among the expensive ones. So they lead.
#
# CFG-543: urgency is a property of the calendar and no priority number carries it.
# A deadline item decayed from 17 days out to 3 while sitting in a queue sorted by nothing.
# The discriminator is tense: a FILING date is always past ("from muse WSL 2026-08-26"),
# a deadline is future. Surfacing only future dates keeps filing noise out of the lane.

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAIL_DETAILS=""

pass() { ((TESTS_PASSED++)) || true; ((TESTS_RUN++)) || true; echo "  PASS: $1"; }
fail() { ((TESTS_FAILED++)) || true; ((TESTS_RUN++)) || true; FAIL_DETAILS="${FAIL_DETAILS}\n  FAIL: $1"; echo "  FAIL: $1"; }

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
CHECK="$REPO_ROOT/global/hooks/checks/03-inbox-services.sh"
CHECK_B="$REPO_ROOT/global/hooks/checks/03b-inbox-typing.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT

mkdir -p "$_tmp/repo/cross-project" "$_tmp/proj/muse"
cat > "$_tmp/repo/registry.md" <<'EOF'
## Projects

| Project | Type | Parent |
|---------|------|--------|
| muse | code | - |
| Alpha | research | - |

## Machines
EOF

# Anchored at noon: near midnight, '+9 days' is 216 h and a DST change in between
# lands it on the previous calendar day (CFG-780, measured 00:47 CEST 2026-10-20).
_noon=$(date -d "$(date +%Y-%m-%d) 12:00" +%s)   # epoch math: "12:00 +9" would parse as a TZ
_future=$(date -d "@$(( _noon + 9 * 86400 ))" +%Y-%m-%d)
_far=$(date -d "@$(( _noon + 40 * 86400 ))" +%Y-%m-%d)
_past=$(date -d '-5 days' +%Y-%m-%d)

cat > "$_tmp/repo/cross-project/inbox.md" <<EOF
# Inbox

- [ ] **muse** [work] (P1 — a build task; from Alpha WSL $_past): do the expensive thing
- [ ] **muse** [fact] (P2 — a doc write; from Alpha WSL $_past): record a measured fact
- [ ] **muse** (P2 — untagged legacy item; from Alpha WSL $_past): the old format
- [ ] **muse** [fyi] (P3 — heads up; from Alpha WSL $_past): submission closes $_far
- [ ] **muse** [rule] (P2 — proposed rule; from Alpha WSL $_past): deadline is $_future
- [ ] **Alpha** [fact] (P2 — not muse's; from muse WSL $_past): different project
EOF

# Run the check the way the hook does, with a muse cwd.
run_check() {
    (
        cd "$_tmp/proj/muse" || exit 1
        CONFIG_REPO="$_tmp/repo"
        WARNINGS=""
        INBOX_MSG=""
        SETTINGS_FILE="/nonexistent"
        DEFAULT_BRANCH="main"
        USER_HOME="$_tmp/nohome"
        # shellcheck disable=SC1090
        . "$CHECK" >/dev/null 2>&1
        # shellcheck disable=SC1090
        . "$CHECK_B" >/dev/null 2>&1
        echo "WARNINGS=${WARNINGS:-}"
        echo "INBOX_MSG=${INBOX_MSG:-}"
        echo "DEADLINES=${INBOX_DEADLINES:-}"
    )
}

_out="$(run_check)"
_msg="$(printf '%s' "$_out" | sed -n 's/^INBOX_MSG=//p')"
_dead="$(printf '%s' "$_out" | sed -n 's/^DEADLINES=//p')"

echo "=== CFG-541: type-aware delivery ==="

# ── Test 1: a per-type breakdown is surfaced ────────────────────────────────
if printf '%s' "$_msg" | grep -qE 'INBOX_TYPES.*fact'; then
    pass "per-type breakdown is surfaced to the receiving session"
else
    fail "no INBOX_TYPES breakdown in INBOX_MSG: $_msg"
fi

# ── Test 2: untagged legacy items are counted, not silently dropped ─────────
if printf '%s' "$_msg" | grep -qE 'untagged'; then
    pass "untagged legacy items are counted rather than silently dropped"
else
    fail "untagged items not reported: $_msg"
fi

# ── Test 3: fact items lead the delivered list ──────────────────────────────
_first_tagged=$(printf '%s' "$_msg" | grep -o '\[fact\]\|\[work\]\|\[rule\]\|\[fyi\]' | head -1)
if [ "$_first_tagged" = "[fact]" ]; then
    pass "fact items lead the delivered list"
else
    fail "expected [fact] first, got '$_first_tagged'"
fi

# ── Test 4: another project's items are not delivered here ──────────────────
if printf '%s' "$_msg" | grep -q "different project"; then
    fail "Alpha's item leaked into muse's delivery"
else
    pass "other projects' items are not delivered"
fi

echo "=== CFG-543: dated-item expiry lane ==="

# ── Test 5: a future-dated item is surfaced in the deadline lane ────────────
if printf '%s' "$_dead" | grep -q "$_future"; then
    pass "future-dated item appears in the deadline lane"
else
    fail "future date $_future missing from deadline lane: $_dead"
fi

# ── Test 6: days-remaining is computed ──────────────────────────────────────
if printf '%s' "$_dead" | grep -qE '\b9d\b|9 day'; then
    pass "days-remaining is computed for the dated item"
else
    fail "no days-remaining for the +9d item: $_dead"
fi

# ── Test 7: soonest-first, independent of P-number ──────────────────────────
# The +9d item is P2 (rule) and the +40d item is P3 (fyi). Sorted by date the
# P2 leads; sorted by priority it would also lead, so the discriminating check is
# that the FAR item still appears AFTER it despite being a different priority.
_pos_near=$(printf '%s' "$_dead" | grep -bo "$_future" | head -1 | cut -d: -f1)
_pos_far=$(printf '%s' "$_dead" | grep -bo "$_far" | head -1 | cut -d: -f1)
if [ -n "$_pos_near" ] && [ -n "$_pos_far" ] && [ "$_pos_near" -lt "$_pos_far" ]; then
    pass "deadline lane is ordered soonest-first"
else
    fail "ordering wrong (near@$_pos_near far@$_pos_far): $_dead"
fi

# ── Test 8: past filing dates must NOT enter the deadline lane ──────────────
# Every item carries "from <proj> <machine> <past-date>"; if those leaked in, the
# lane would be pure noise and get ignored — the exact fate of the drift alarm.
# Assert on the SELECTED deadline dates — the `(YYYY-MM-DD)` field — not on the whole
# string. The lane quotes each item's body, which legitimately contains its own filing
# date; asserting over the body would fail on correct output. What must never happen is
# a PAST date being chosen AS a deadline.
# Guarded against vacuity: an empty lane selects no dates and would prove nothing.
_selected=$(printf '%s' "$_dead" | grep -oE '\(20[0-9]{2}-[0-9]{2}-[0-9]{2}\)' | tr -d '()')
if [ -z "$_selected" ]; then
    fail "deadline lane selected no dates — the past-date assertion would be vacuous"
elif printf '%s\n' "$_selected" | grep -q "$_past"; then
    fail "past filing date $_past was SELECTED as a deadline: $_selected"
else
    pass "only future dates are selected as deadlines (selected: $(printf '%s' "$_selected" | tr '\n' ' '))"
fi

# ── Test 9: the JSON contract is not broken (CFG-503) ───────────────────────
# stdout from a check is a JSON contract; anything echoed corrupts additionalContext
# and silently discards the ENTIRE payload. This is the fleet's most expensive bug class.
_stray=$(
    cd "$_tmp/proj/muse" || exit 1
    CONFIG_REPO="$_tmp/repo"; WARNINGS=""; INBOX_MSG=""
    SETTINGS_FILE="/nonexistent"; DEFAULT_BRANCH="main"; USER_HOME="$_tmp/nohome"
    # shellcheck disable=SC1090
    . "$CHECK" 2>/dev/null
    # shellcheck disable=SC1090
    . "$CHECK_B" 2>/dev/null
)
if [ -z "$_stray" ]; then
    pass "check writes nothing to stdout (JSON contract intact)"
else
    fail "check echoed to stdout, would corrupt additionalContext: $_stray"
fi

echo
echo "── Summary ──"
echo "  Total:   $TESTS_RUN"
echo "  Passed:  $TESTS_PASSED"
if [ "$TESTS_FAILED" -gt 0 ]; then
    echo "  Failed:  $TESTS_FAILED"
    echo -e "$FAIL_DETAILS"
    exit 1
fi
exit 0
