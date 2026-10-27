#!/usr/bin/env bash
# Tests for CFG-65: the legacy inbox's preamble is not inbox content.
#
# cross-project/inbox.md opens with documentation — a format example containing the
# literal `- [ ] [Task description]` and prose carrying a 2026-08-28 measurement date.
# Real items live below `<!-- Pending tasks appear below this line -->`. Two counters
# read the whole file, so an EMPTY inbox reported at every SessionStart:
#   "Cross-project inbox: 1 task(s) for other projects"   (inbox_total_count)
#   "INBOX_STALE: 1 inbox line(s) carry a date older ..." (Check 3.2c awk)
# Measured on a live machine 2026-10-23 with zero real items.

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAIL_DETAILS=""

pass() { ((TESTS_PASSED++)) || true; ((TESTS_RUN++)) || true; echo "  PASS: $1"; }
fail() { ((TESTS_FAILED++)) || true; ((TESTS_RUN++)) || true; FAIL_DETAILS="${FAIL_DETAILS}\n  FAIL: $1"; echo "  FAIL: $1"; }

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
LIB="$REPO_ROOT/setup/scripts/inbox-lib.sh"
CHECK="$REPO_ROOT/global/hooks/checks/03-inbox-services.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/repo/cross-project" "$_tmp/proj/muse"
INBOX="$_tmp/repo/cross-project/inbox.md"

_old=$(date -d '60 days ago' +%Y-%m-%d)

# Same shape as the real file: dated prose and a fenced format example above the marker.
write_preamble() {
    cat > "$INBOX" <<EOF
# Cross-Project Inbox

The payload measured 46,729 characters on $_old against a 29-item inbox.

## Format

\`\`\`
## [project-name]
- [ ] [Task description]
  Context: [Any relevant detail Claude needs to act on this]
\`\`\`

<!-- Pending tasks appear below this line -->
EOF
}

# Must be EXPORTED: the lib resolves the repo at call time (see test-inbox-lib.sh).
export INBOX_REPO="$_tmp/repo"
# shellcheck disable=SC1090
. "$LIB"

# Run the check the way the hook does, with a muse cwd.
run_check() {
    (
        cd "$_tmp/proj/muse" || exit 1
        unset INBOX_REPO
        CONFIG_REPO="$_tmp/repo"
        WARNINGS=""
        INBOX_MSG=""
        SETTINGS_FILE="/nonexistent"
        DEFAULT_BRANCH="main"
        USER_HOME="$_tmp/nohome"
        # shellcheck disable=SC1090
        . "$CHECK" >/dev/null 2>&1
        echo "WARNINGS=${WARNINGS:-}"
        echo "INBOX_MSG=${INBOX_MSG:-}"
    )
}

echo "=== CFG-65: preamble-only inbox reports nothing ==="
write_preamble

# ── Test 1: the format example is not counted as an item ────────────────────
_total=$(inbox_total_count)
if [ "$_total" = "0" ]; then
    pass "format example above the marker is not an item (total $_total)"
else
    fail "empty inbox counted $_total item(s) — the format example was read as a task"
fi

_out="$(run_check)"
_warn="$(printf '%s' "$_out" | sed -n 's/^WARNINGS=//p')"
_msg="$(printf '%s' "$_out" | sed -n 's/^INBOX_MSG=//p')"

# ── Test 2: no phantom "task(s) for other projects" at SessionStart ─────────
if printf '%s' "$_msg" | grep -q 'task(s) for other projects'; then
    fail "empty inbox reported other-project tasks: $_msg"
else
    pass "no phantom other-project count for an empty inbox"
fi

# ── Test 3: a dated sentence in the preamble is not a stale item ────────────
if printf '%s' "$_warn" | grep -q 'INBOX_STALE'; then
    fail "preamble date $_old raised INBOX_STALE: $_warn"
else
    pass "preamble date does not raise INBOX_STALE"
fi

echo "=== CFG-65: real items below the marker are still seen ==="
echo "- [ ] **Alpha** (P2 — from muse WSL $_old): a genuinely old item" >> "$INBOX"

# ── Test 4: an item below the marker is counted ─────────────────────────────
_total=$(inbox_total_count)
if [ "$_total" = "1" ]; then
    pass "item below the marker is counted (total $_total)"
else
    fail "expected 1 item below the marker, got $_total"
fi

_out="$(run_check)"
_warn="$(printf '%s' "$_out" | sed -n 's/^WARNINGS=//p')"
_msg="$(printf '%s' "$_out" | sed -n 's/^INBOX_MSG=//p')"

# ── Test 5: the other-project count reflects exactly that item ──────────────
if printf '%s' "$_msg" | grep -q '1 task(s) for other projects (total: 1)'; then
    pass "other-project count is exact: $(printf '%s' "$_msg" | grep -o '[0-9]* task(s) for other projects (total: [0-9]*)')"
else
    fail "expected '1 task(s) for other projects (total: 1)', got: $_msg"
fi

# ── Test 6: a stale item below the marker still raises INBOX_STALE ──────────
# Guards against a fix that silences the check instead of scoping it. The fixture has
# no cross-project/inbox/ directory, like an un-migrated machine: naming the unmatched
# per-project glob as an awk operand made gawk abort, and `|| echo 0` reported 0.
if printf '%s' "$_warn" | grep -q 'INBOX_STALE: 1 inbox line'; then
    pass "stale item below the marker is still flagged: $(printf '%s' "$_warn" | grep -o 'INBOX_STALE: [0-9]* inbox line(s)')"
else
    fail "stale item below the marker was not flagged exactly once: $_warn"
fi

# ── Test 7: per-project files are still part of the staleness corpus (CFG-542) ──
write_preamble
mkdir -p "$_tmp/repo/cross-project/inbox"
echo "- [ ] **Alpha** (P2 — from muse WSL $_old): an old per-project item" \
    > "$_tmp/repo/cross-project/inbox/alpha.md"
_warn="$(run_check | sed -n 's/^WARNINGS=//p')"
if printf '%s' "$_warn" | grep -q 'INBOX_STALE: 1 inbox line'; then
    pass "stale per-project item is flagged: $(printf '%s' "$_warn" | grep -o 'INBOX_STALE: [0-9]* inbox line(s)')"
else
    fail "stale per-project item was not flagged exactly once: $_warn"
fi
rm -rf "$_tmp/repo/cross-project/inbox"

echo "=== CFG-65: a legacy file without the marker is read whole ==="

# ── Test 8: no marker → behaviour unchanged ─────────────────────────────────
# Older inbox files and every other test fixture carry no marker; they must not go blind.
printf '# Inbox\n\n- [ ] **muse** (P2): one\n- [ ] **Alpha** (P2): two\n' > "$INBOX"
_total=$(inbox_total_count)
if [ "$_total" = "2" ]; then
    pass "marker-less file is read whole (total $_total)"
else
    fail "marker-less file should count 2 items, got $_total"
fi

# ── Test 9: the JSON contract is not broken (CFG-503) ───────────────────────
write_preamble
_stray=$(
    cd "$_tmp/proj/muse" || exit 1
    unset INBOX_REPO
    CONFIG_REPO="$_tmp/repo"; WARNINGS=""; INBOX_MSG=""
    SETTINGS_FILE="/nonexistent"; DEFAULT_BRANCH="main"; USER_HOME="$_tmp/nohome"
    # shellcheck disable=SC1090
    . "$CHECK" 2>/dev/null
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
