#!/usr/bin/env bash
# Tests for setup/scripts/inbox-cut.py and inbox-deliver.py
#
# Every case here encodes a defect that actually happened on 2026-08-24 while
# draining cross-project/inbox.md by hand. Run against the pre-fix scratchpad
# versions, cases 4 and 5 FAIL — that is the point of them.
#
# Override the scripts under test with INBOX_CUT / INBOX_DELIVER to prove RED.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CUT="${INBOX_CUT:-$REPO/setup/scripts/inbox-cut.py}"
DELIVER="${INBOX_DELIVER:-$REPO/setup/scripts/inbox-deliver.py}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

make_inbox() {
  cat > "$TMP/inbox.md" <<'EOF'
# Cross-Project Inbox

- [ ] **alpha** (P1 — from x 2026-01-01): **Simple one-liner.** Body text.

- [ ] **beta** (P2 — from y): **Multi-line item.** First paragraph.

  **Continuation one:** indented detail that must travel with its parent.

  **Continuation two:** more indented detail.

- [ ] **gamma**: **Item with an unindented code fence.**

```bash
- [ ] this line looks like an item but is inside a fence
exit 0
```

  **After the fence:** still part of gamma.

- [ ] **delta (WSL)**: **Owner name carries a suffix.** Must still be routable.

- [ ] **alpha** (P3): **Second alpha item.**
EOF
}

echo "== inbox-cut =="

# 1. multi-line items travel whole
make_inbox
n=$(python3 "$CUT" "$TMP/inbox.md" extract beta | grep -c 'Continuation')
check "multi-line item keeps both continuations" "$n" "2"

# 2. a fence containing a fake item line does not split gamma
make_inbox
n=$(python3 "$CUT" "$TMP/inbox.md" extract gamma | grep -c 'After the fence')
check "code fence does not truncate the item" "$n" "1"

# 3. deletion leaves no orphaned continuation blocks
make_inbox
python3 "$CUT" "$TMP/inbox.md" delete beta >/dev/null
n=$(python3 "$CUT" "$TMP/inbox.md" orphans | head -1 | grep -oP 'orphans: \K\d+')
check "deleting a multi-line item orphans nothing" "$n" "0"

# 4. REGRESSION: an owner with a suffix must be addressable
make_inbox
n=$(python3 "$CUT" "$TMP/inbox.md" extract delta | grep -c 'Owner name carries a suffix')
check "suffixed owner '**delta (WSL)**' is routable" "$n" "1"

# 5. multiple items for one owner are all taken
make_inbox
python3 "$CUT" "$TMP/inbox.md" delete alpha >/dev/null
n=$(grep -c '^- \[ \] \*\*alpha\*\*' "$TMP/inbox.md" || true)
check "all items for an owner are deleted" "$n" "0"

# 6. items belonging to other owners survive
n=$(grep -c '^- \[ \] \*\*beta\*\*' "$TMP/inbox.md" || true)
check "other owners untouched by a delete" "$n" "1"

echo "== inbox-deliver =="

# 7. REGRESSION: CRLF line endings must survive delivery
make_inbox
mkdir -p "$TMP/proj"
printf '# Backlog\r\n\r\n- [ ] [P1] `PRJ-1` **Existing.**\r\n\r\n## Done\r\n' > "$TMP/proj/backlog.md"
before=$(grep -c $'\r' "$TMP/proj/backlog.md")
INBOX="$TMP/inbox.md" python3 "$DELIVER" alpha PRJ 2 --backlog "$TMP/proj/backlog.md" --apply >/dev/null 2>&1
after=$(grep -c $'\r' "$TMP/proj/backlog.md")
landed=$(grep -c 'PRJ-2' "$TMP/proj/backlog.md" || true)
# Guard against a vacuous pass: if the delivery never wrote, CRLF "survives"
# trivially and proves nothing. Require the write to have happened first.
if [ "$landed" -eq 0 ]; then bad "CRLF check is vacuous — delivery wrote nothing"
elif [ "$after" -gt "$before" ]; then ok "CRLF preserved through delivery ($before -> $after)"
else bad "CRLF stripped by delivery ($before -> $after)"; fi

# 8. the delivered content actually lands
n=$(grep -c 'PRJ-2' "$TMP/proj/backlog.md" || true)
check "delivered item carries its new ID" "$n" "1"

# 9. insertion goes before '## Done', not after
d=$(grep -n '## Done' "$TMP/proj/backlog.md" | cut -d: -f1)
i=$(grep -n 'PRJ-2' "$TMP/proj/backlog.md" | head -1 | cut -d: -f1)
if [ "$i" -lt "$d" ]; then ok "intake inserted above '## Done'"
else bad "intake landed below '## Done' (item $i, Done $d)"; fi

# 10. dry run writes nothing
make_inbox
cp "$TMP/proj/backlog.md" "$TMP/proj/backlog.before"
INBOX="$TMP/inbox.md" python3 "$DELIVER" beta PRJ 9 --backlog "$TMP/proj/backlog.md" >/dev/null 2>&1
if diff -q "$TMP/proj/backlog.md" "$TMP/proj/backlog.before" >/dev/null; then ok "dry run leaves the backlog untouched"
else bad "dry run modified the backlog"; fi

echo
echo "inbox-tools: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
