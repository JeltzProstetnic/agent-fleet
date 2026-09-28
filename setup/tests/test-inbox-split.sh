#!/usr/bin/env bash
# Tests for CFG-542's migration script, setup/scripts/inbox-split.sh.
#
# This script moves real content, so the tests pin the properties that make it safe:
# fence-awareness (items embed shell scripts whose lines start with '#'), heading
# preservation, multi-project fan-out, and that --dry-run writes nothing.

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAIL_DETAILS=""

pass() { ((TESTS_PASSED++)) || true; ((TESTS_RUN++)) || true; echo "  PASS: $1"; }
fail() { ((TESTS_FAILED++)) || true; ((TESTS_RUN++)) || true; FAIL_DETAILS="${FAIL_DETAILS}\n  FAIL: $1"; echo "  FAIL: $1"; }

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
SPLIT="$REPO_ROOT/setup/scripts/inbox-split.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/cross-project"

make_fixture() {
    cat > "$_tmp/cross-project/inbox.md" <<'EOF'
# Cross-Project Inbox

Preamble prose that must survive.

- [ ] **muse** [work] (P2 — one): first muse item
- [ ] **Alpha** [fact] (P1 — two): an Alpha item
  continuation line belonging to the Alpha item
- [ ] **Alpha + beta** [fyi] (P3 — three): a multi-project item
- [ ] **muse** [fact] (P2 — four): an item embedding a script
```bash
#!/usr/bin/env bash
# this comment line starts with a hash and must NOT split the item
echo hi
```

## Pending

- [ ] **beta** [work] (P1 — five): after a heading
EOF
}

echo "=== CFG-542 inbox-split ==="

if [ ! -f "$SPLIT" ]; then
    fail "script $SPLIT does not exist"
    echo; echo "── Summary ──"; echo "  Total: 1"; echo "  Failed: 1"; exit 1
fi

# ── Test 1: --dry-run writes nothing ────────────────────────────────────────
make_fixture
_before=$(md5sum < "$_tmp/cross-project/inbox.md")
bash "$SPLIT" --repo "$_tmp" --dry-run >/dev/null 2>&1
_after=$(md5sum < "$_tmp/cross-project/inbox.md")
if [ "$_before" = "$_after" ] && [ ! -d "$_tmp/cross-project/inbox" ]; then
    pass "--dry-run writes nothing"
else
    fail "--dry-run modified state"
fi

# ── Test 2: verification passes on a well-formed fixture ────────────────────
if bash "$SPLIT" --repo "$_tmp" --dry-run 2>&1 | grep -q "nothing lost — OK"; then
    pass "verification reports the distinct-item set unchanged"
else
    fail "verification did not pass on a clean fixture"
fi

# ── Real run for the remaining assertions ───────────────────────────────────
make_fixture
bash "$SPLIT" --repo "$_tmp" >/dev/null 2>&1

# ── Test 3: items land in their own project file ────────────────────────────
if grep -q 'first muse item' "$_tmp/cross-project/inbox/muse.md" 2>/dev/null \
   && grep -q 'an Alpha item' "$_tmp/cross-project/inbox/alpha.md" 2>/dev/null; then
    pass "items are routed to their own project file"
else
    fail "items did not land in the right per-project files"
fi

# ── Test 4: multi-project tag reaches EVERY project it names ────────────────
# Before this, a combined tag matched Check 3.2's exact-name regex for nobody, so the
# item was silently undeliverable to all of them.
if grep -q 'a multi-project item' "$_tmp/cross-project/inbox/alpha.md" 2>/dev/null \
   && grep -q 'a multi-project item' "$_tmp/cross-project/inbox/beta.md" 2>/dev/null; then
    pass "multi-project tag fans out to every project it names"
else
    fail "multi-project item did not reach both projects"
fi

# ── Test 5: a fenced script does not split its item ─────────────────────────
# The '#!' and '# comment' lines inside the fence must stay attached to item four.
if grep -q 'must NOT split the item' "$_tmp/cross-project/inbox/muse.md" 2>/dev/null; then
    pass "fenced shell script stays attached to its item"
else
    fail "fenced content was detached from its item"
fi

# ── Test 6: continuation lines travel with their item ───────────────────────
if grep -q 'continuation line belonging' "$_tmp/cross-project/inbox/alpha.md" 2>/dev/null; then
    pass "continuation lines travel with their item"
else
    fail "continuation line was orphaned"
fi

# ── Test 7: preamble and headings stay in the legacy file ───────────────────
if grep -q 'Preamble prose that must survive' "$_tmp/cross-project/inbox.md" \
   && grep -q '^## Pending' "$_tmp/cross-project/inbox.md"; then
    pass "preamble and headings stay in the legacy file"
else
    fail "preamble or headings were moved or lost"
fi

# ── Test 8: no item lines remain in the legacy file ─────────────────────────
# `grep -c` prints "0" AND exits 1 on no match, so `|| echo 0` yields a two-line "0\n0"
# and every numeric test then errors. 03-inbox-services.sh carries a comment about this
# exact bug; head -1 is the fix that works whether or not there are matches.
_left=$(grep -c '^- \[ \]' "$_tmp/cross-project/inbox.md" 2>/dev/null | head -1)
[ -n "$_left" ] || _left=0
if [ "$_left" -eq 0 ]; then
    pass "all items migrated out of the legacy file"
else
    fail "$_left item(s) left behind in the legacy file"
fi

# ── Test 9: the original is backed up before any write ──────────────────────
if ls "$_tmp/cross-project/inbox.md.bak."* >/dev/null 2>&1; then
    pass "original is backed up before the split is committed"
else
    fail "no backup of the original was created"
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
