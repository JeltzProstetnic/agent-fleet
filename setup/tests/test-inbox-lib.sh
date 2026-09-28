#!/usr/bin/env bash
# Tests for CFG-542: per-project inbox files with an additive migration path.
#
# The split fixes two measured failures that nothing else does:
#   (a) PAYLOAD — the whole ~94k-token file was injected at SessionStart for EVERY
#       project and then truncated, so the tail was unread by construction.
#   (b) CLOBBER — `git add cross-project/inbox.md` commits whatever other sessions
#       left uncommitted in it; a sibling project's commit carried 53 deletions it never made.
#
# The migration is ADDITIVE on purpose: readers consult the per-project file AND the
# legacy file, so every existing writer (config-auto-sync Cat-3, afleet-nav, telegram,
# mobile-deploy) keeps working untouched. A cutover across 7 scripts and 14 test files
# would have been a lockout risk for no extra benefit.

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAIL_DETAILS=""

pass() { ((TESTS_PASSED++)) || true; ((TESTS_RUN++)) || true; echo "  PASS: $1"; }
fail() { ((TESTS_FAILED++)) || true; ((TESTS_RUN++)) || true; FAIL_DETAILS="${FAIL_DETAILS}\n  FAIL: $1"; echo "  FAIL: $1"; }

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
LIB="$REPO_ROOT/setup/scripts/inbox-lib.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
mkdir -p "$_tmp/cross-project/inbox"

echo "=== CFG-542 inbox library ==="

if [ ! -f "$LIB" ]; then
    fail "library $LIB does not exist"
    echo; echo "── Summary ──"; echo "  Total: 1"; echo "  Failed: 1"; exit 1
fi

# Must be EXPORTED, not a command-scoped assignment: the lib resolves the repo at
# function-call time, so `INBOX_REPO=x . lib` leaves the functions reading the real
# repo — which is how the first run of this suite silently tested production data.
export INBOX_REPO="$_tmp"
# shellcheck disable=SC1090
. "$LIB"

cat > "$_tmp/cross-project/inbox.md" <<'EOF'
# Inbox (legacy)

- [ ] **muse** (P2 — legacy untagged): an item filed by an un-migrated writer
- [ ] **Alpha** (P1 — legacy): someone else's legacy item
EOF

cat > "$_tmp/cross-project/inbox/muse.md" <<'EOF'
- [ ] **muse** [fact] (P2 — per-project): a migrated item
EOF

# ── Test 1: project file path is derived, lowercased ────────────────────────
_p=$(inbox_project_file "Alpha")
if [ "$_p" = "$_tmp/cross-project/inbox/alpha.md" ]; then
    pass "project file path is derived and case-folded"
else
    fail "unexpected path: $_p"
fi

# ── Test 2: a slashed parent/child tag cannot escape the inbox directory ────
# `acme/pdp` is a legal tag (CFG-483). Naively interpolated it would write to
# cross-project/inbox/acme/pdp.md, or worse escape via `..`.
_p=$(inbox_project_file "acme/pdp")
case "$_p" in
    "$_tmp/cross-project/inbox/"*)
        if printf '%s' "$_p" | grep -q '\.\.'; then
            fail "path traversal not neutralised: $_p"
        elif [ "$(dirname "$_p")" = "$_tmp/cross-project/inbox" ]; then
            pass "slashed tag is flattened into a single file inside the inbox dir"
        else
            fail "slashed tag created a subdirectory: $_p"
        fi ;;
    *) fail "slashed tag escaped the inbox dir: $_p" ;;
esac

_p=$(inbox_project_file "../../etc/passwd")
if [ "$(dirname "$_p")" = "$_tmp/cross-project/inbox" ]; then
    pass "traversal attempt is confined to the inbox dir"
else
    fail "traversal escaped: $_p"
fi

# ── Test 3: items for a project come from BOTH sources ──────────────────────
_items=$(inbox_items_for muse)
_n=$(printf '%s\n' "$_items" | grep -c '^- \[ \]')
if [ "$_n" -eq 2 ]; then
    pass "items are read from the per-project file AND the legacy file"
else
    fail "expected 2 muse items across both sources, got $_n: $_items"
fi

# ── Test 4: another project's legacy item is not returned ───────────────────
if printf '%s' "$_items" | grep -q "someone else's legacy item"; then
    fail "Alpha's legacy item leaked into muse's items"
else
    pass "legacy items are still filtered by project tag"
fi

# ── Test 5: total count spans both sources without double-counting ──────────
_total=$(inbox_total_count)
if [ "$_total" -eq 3 ]; then
    pass "total count spans both sources (3)"
else
    fail "expected total 3, got $_total"
fi

# ── Test 6: a project with no file and no legacy items yields nothing ───────
_empty=$(inbox_items_for nosuchproject)
if [ -z "$_empty" ]; then
    pass "unknown project yields no items and no error"
else
    fail "unknown project returned: $_empty"
fi

# ── Test 7 (the payload win): reading one project does not read the whole corpus ──
# Pad the legacy file so a whole-file read would be obvious, then assert that the
# bytes returned for a project are far smaller than the corpus. This is the actual
# CFG-515 symptom — the entire file injected for every project, then truncated.
for i in $(seq 1 200); do
    echo "- [ ] **otherproj** (P3 — filler $i): $(head -c 200 /dev/zero | tr '\0' 'x')" \
        >> "$_tmp/cross-project/inbox.md"
done
_corpus=$(wc -c < "$_tmp/cross-project/inbox.md")
_mine=$(inbox_items_for muse | wc -c)
if [ "$_mine" -lt $(( _corpus / 10 )) ]; then
    pass "per-project read is <10% of the corpus ($_mine vs $_corpus bytes)"
else
    fail "per-project read did not bound the payload ($_mine vs $_corpus bytes)"
fi

# ── Test 8: missing inbox dir degrades to legacy rather than failing ────────
# Hooks source this. If a machine has not migrated yet, it must still deliver.
rm -rf "$_tmp/cross-project/inbox"
_items=$(inbox_items_for muse 2>/dev/null)
if printf '%s' "$_items" | grep -q "un-migrated writer"; then
    pass "missing inbox dir degrades to legacy delivery, no breakage"
else
    fail "delivery broke when the inbox dir was absent: $_items"
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
