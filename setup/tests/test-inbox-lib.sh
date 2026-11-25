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

# ══════════════════════════════════════════════════════════════════════════════
# CFG-1091: registry resolution — who can read a per-project file, and who is dead
# ══════════════════════════════════════════════════════════════════════════════
# fleet-auditor lives in `auditor/`, so the hook's basename lookup never read
# inbox/fleet-auditor.md; oldnotes was deleted 2026-11-04 and still accepted as a target.
echo "=== CFG-1091: registry resolution ==="
mkdir -p "$_tmp/cross-project/inbox"
cat > "$_tmp/registry.md" <<'EOF'
## Projects

| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
| cfg-agent-fleet | P1 | — | `~/cfg-agent-fleet` | — | test | config | active | backbone |
| fleet-auditor | P3 | cfg-agent-fleet | `~/cfg-agent-fleet/auditor` | — | test | config | active | sub-project |
| home | P2 | — | `~/home` | — | test | personal | active | |
| garden | P3 | home | `~/home/garden` | — | test | business | active | |
| oldnotes | — | home | `~/oldnotes` | — | test | business | deleted 2026-11-04 | **Merged into `~/home/garden/`** |
| acme | P1 | — | `~/acme` | — | test | business | active | |

### Removed Projects

| Project | Previous Path | Status | Notes |
|---------|--------------|--------|-------|
| claude-demo | `~/demo` | Deleted from filesystem + GitHub | Was a demo |
| oldmail | `~/oldmail` | Absorbed into acme | PST search |

## Machines
EOF

# ── Test 9: rows of both tables parse by header name ────────────────────────
_rows=$(inbox_registry_rows 2>/dev/null)
_main=$(printf '%s\n' "$_rows" | grep -c '|main|')
_removed=$(printf '%s\n' "$_rows" | grep -c '|removed|')
if [ "$_main" -eq 6 ] && [ "$_removed" -eq 2 ] \
   && printf '%s\n' "$_rows" | grep -q '^fleet-auditor|cfg-agent-fleet|~/cfg-agent-fleet/auditor|active|main|'; then
    pass "registry rows parse: 6 project rows, 2 removed rows, columns by header"
else
    fail "registry rows wrong (main=$_main removed=$_removed): $_rows"
fi

# ── Test 10: live names exclude deleted and removed projects ────────────────
_live=$(inbox_registry_live_names 2>/dev/null)
if printf '%s\n' "$_live" | grep -qx 'fleet-auditor' && ! printf '%s\n' "$_live" | grep -qx 'oldnotes' \
   && ! printf '%s\n' "$_live" | grep -qx 'claude-demo' && ! printf '%s\n' "$_live" | grep -qx 'oldmail'; then
    pass "live names keep fleet-auditor and drop oldnotes, claude-demo, oldmail"
else
    fail "live names wrong: $(printf '%s' "$_live" | tr '\n' ' ')"
fi

# ── Test 11: a dead target is recognised and its successor named ────────────
_d=$(inbox_registry_dead oldnotes 2>/dev/null)
if [ "$_d" = "deleted 2026-11-04|home" ]; then
    pass "oldnotes is dead, phase 'deleted 2026-11-04', successor home (Parent column)"
else
    fail "inbox_registry_dead oldnotes → '$_d'"
fi
_d=$(inbox_registry_dead oldmail 2>/dev/null)
if [ "${_d#*|}" = "acme" ]; then
    pass "oldmail (removed table) names its successor from 'Absorbed into acme'"
else
    fail "inbox_registry_dead oldmail → '$_d'"
fi
_d=$(inbox_registry_dead claude-demo 2>/dev/null); _rc=$?
if [ "$_rc" -eq 0 ] && [ -z "${_d#*|}" ]; then
    pass "claude-demo is dead with no successor recorded"
else
    fail "inbox_registry_dead claude-demo → rc=$_rc '$_d'"
fi
if inbox_registry_dead home >/dev/null 2>&1; then
    fail "a live project was reported dead"
else
    pass "a live project is not dead"
fi

# ── Test 12: the registry name of a directory, and the names a session answers to ──
_n=$(inbox_registry_name_for_dir "/somewhere/else/auditor" 2>/dev/null)
if [ "$_n" = "fleet-auditor" ]; then
    pass "directory auditor/ resolves to registry name fleet-auditor"
else
    fail "name for auditor/ → '$_n'"
fi
_names=$(inbox_names_for_dir "/x/auditor" 2>/dev/null | tr '\n' ' ')
if [ "$_names" = "auditor fleet-auditor " ]; then
    pass "a session in auditor/ answers to 'auditor' and 'fleet-auditor'"
else
    fail "names for auditor/ → '$_names'"
fi
_names=$(inbox_names_for_dir "/x/home" 2>/dev/null | tr '\n' ' ')
if [ "$_names" = "home " ]; then
    pass "a directory whose name is its registry name answers to one name"
else
    fail "names for home/ → '$_names'"
fi

# ── Test 13: children by any alias ──────────────────────────────────────────
_kids=$(inbox_children_of home 2>/dev/null | sort | tr '\n' ' ')
if [ "$_kids" = "garden oldnotes " ]; then
    pass "children of home: garden and oldnotes (a deleted child is still listed for its parent)"
else
    fail "children of home → '$_kids'"
fi
_kids=$(inbox_children_of auditor fleet-auditor 2>/dev/null)
if [ -z "$_kids" ]; then
    pass "a project without children yields nothing"
else
    fail "unexpected children: $_kids"
fi

# ── Test 14: items for several names, each line once ────────────────────────
printf -- '- [ ] **fleet-auditor** (P2 — legacy): a legacy fleet-auditor item\n' >> "$_tmp/cross-project/inbox.md"
cat > "$_tmp/cross-project/inbox/fleet-auditor.md" <<'EOF'
- [ ] **fleet-auditor** [work] (P2): file item one
- [ ] **fleet-auditor** [fact] (P2): file item two
EOF
_n=$(inbox_items_for_any auditor fleet-auditor fleet-auditor 2>/dev/null | grep -c '^- \[ \]')
if [ "$_n" -eq 3 ]; then
    pass "items for aliases are a union without duplicates (3)"
else
    fail "expected 3 unique items, got $_n"
fi

# ── Test 15: per-project files no session can read ──────────────────────────
printf -- '- [ ] **oldnotes** [work] (P1): mail for a deleted project\n' > "$_tmp/cross-project/inbox/oldnotes.md"
printf -- '- [ ] **?** [work] (P2): mail for nobody\n' > "$_tmp/cross-project/inbox/unrouted.md"
printf -- '- [ ] **new-project** [work] (P2): placeholder\n' > "$_tmp/cross-project/inbox/new-project.md"
printf -- '- [ ] **auditor** [work] (P2): by directory name\n' > "$_tmp/cross-project/inbox/auditor.md"
printf -- '# Inbox — empty\n' > "$_tmp/cross-project/inbox/nobody.md"
_ur=$(inbox_unreadable_files 2>/dev/null)
if printf '%s\n' "$_ur" | grep -qx 'oldnotes 1' && printf '%s\n' "$_ur" | grep -qx 'unrouted 1' \
   && [ "$(printf '%s\n' "$_ur" | grep -c .)" -eq 2 ]; then
    pass "oldnotes.md and unrouted.md are unreachable; auditor.md, fleet-auditor.md, new-project.md and an empty file are not"
else
    fail "unreachable files → '$(printf '%s' "$_ur" | tr '\n' ';')'"
fi

# ── Test 16: the child report is capped ─────────────────────────────────────
: > "$_tmp/cross-project/inbox/garden.md"
for i in 1 2 3 4 5 6 7; do
    printf -- '- [ ] **garden** [work] (P2): child item %s\n' "$i" >> "$_tmp/cross-project/inbox/garden.md"
done
_rep=$(inbox_child_report home 2>/dev/null)
if printf '%s' "$_rep" | grep -q 'garden (7 item(s))' && printf '%s' "$_rep" | grep -q '+2 more' \
   && ! printf '%s' "$_rep" | grep -q 'child item 6'; then
    pass "child report names the count, shows 5 items and counts the rest"
else
    fail "child report → '$_rep'"
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
