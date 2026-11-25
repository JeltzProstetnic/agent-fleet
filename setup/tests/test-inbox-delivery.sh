#!/usr/bin/env bash
# Tests for CFG-1091 — the CFG-542 inbox migration reaches every reader.
#
# CFG-542 moved items to cross-project/inbox/<project>.md and updated the main reader,
# but child→parent surfacing (D4), the unknown-tag check (D5), the corpus signals (D1)
# and the delivery name (D2) kept reading the legacy inbox.md or the directory basename.
# The 2026-11-20 audit found 63 open items, none visible to a parent session,
# fleet-auditor's mail unreadable by construction (its directory is auditor/), and a
# 9 kB inbox block that the payload cap cut out of the middle (D6).
# Findings: docs/research/inbox-delivery-audit-2026-11-20.md
#
# Fixture: a sandbox repo with the REAL inbox-lib.sh copied in, a registry in the real
# column layout, and the checks sourced exactly as the hook sources them.

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
CHECK_C="$REPO_ROOT/global/hooks/checks/03c-inbox-health.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
REPO="$_tmp/repo"
HOME_DIR="$_tmp/home"
mkdir -p "$REPO/cross-project/inbox" "$REPO/setup/scripts" \
         "$HOME_DIR/cfg-agent-fleet/auditor" "$HOME_DIR/home" "$HOME_DIR/social"
cp "$REPO_ROOT/setup/scripts/inbox-lib.sh" "$REPO/setup/scripts/"

_old=$(date -d '60 days ago' +%Y-%m-%d)
_new=$(date +%Y-%m-%d)

cat > "$REPO/registry.md" <<'EOF'
# Project Registry

## Machines

| Machine ID | Platform |
|-----------|----------|
| test | linux |

## Projects

| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
| cfg-agent-fleet | P1 | — | `~/cfg-agent-fleet` | — | test | config | active | backbone |
| fleet-auditor | P3 | cfg-agent-fleet | `~/cfg-agent-fleet/auditor` | — | test | config | active | lives in auditor/ |
| home | P2 | — | `~/home` | — | test | personal | active | |
| garden | P3 | home | `~/home/garden` | — | test | business | active | |
| oldnotes | — | home | `~/oldnotes` | — | test | business | deleted 2026-11-04 | **Merged into `~/home/garden/`** |
| social | P1 | — | `~/social` | — | test | marketing | active | |

### Removed Projects

| Project | Previous Path | Status | Notes |
|---------|--------------|--------|-------|
| claude-demo | `~/demo` | Deleted from filesystem + GitHub | Was a demo |

## Next Section
EOF

cat > "$REPO/cross-project/inbox.md" <<'EOF'
# Cross-Project Inbox

<!-- Pending tasks appear below this line -->
EOF

_long=$(printf 'x%.0s' $(seq 1 1500))
cat > "$REPO/cross-project/inbox/fleet-auditor.md" <<EOF
# Inbox — fleet-auditor

- [ ] **fleet-auditor** [work] (P2; from cfg WSL $_new): AUDITOR-ITEM-ONE audit the roster
- [ ] **fleet-auditor** [fact] (P2; from cfg WSL $_new): AUDITOR-ITEM-TWO $_long
EOF
cat > "$REPO/cross-project/inbox/garden.md" <<EOF
# Inbox — garden

- [ ] **garden** [work] (P2; from home WSL $_new): Garden-CHILD-ITEM check the evidence folder
EOF
cat > "$REPO/cross-project/inbox/oldnotes.md" <<EOF
# Inbox — oldnotes

- [ ] **oldnotes** [work] (P1; from home WSL $_old): Oldnotes-DEAD-ITEM filed after the project was deleted
EOF
cat > "$REPO/cross-project/inbox/social.md" <<EOF
# Inbox — social

- [ ] **social** [work] (P2; from cfg WSL $_old): SOCIAL-OLD-OPEN an old open item
- [x] **social** [work] (P2; from cfg WSL $_old): SOCIAL-OLD-DONE a done item with an old date
<!-- 2 items dispatched on $_old -->
- [ ] **social** [fyi] (P3; from cfg WSL $_new): SOCIAL-NEW a fresh item
EOF
cat > "$REPO/cross-project/inbox/typo.md" <<EOF
# Inbox — typo

- [ ] **typoproject** [work] (P2; from cfg WSL $_new): TYPO-ITEM tagged for nobody
EOF

# run_check <cwd> [slot] — sources 03, 03b, 03c the way the hook does; with `slot` the
# INBOX_DELIVERY variable is declared, as config-check.sh declares it. Newlines inside
# the fields are flattened, as config-check.sh flattens them.
run_check() {
    local _cwd="$1" _slot="${2:-}"
    (
        cd "$_cwd" || exit 1
        CONFIG_REPO="$REPO"; WARNINGS=""; INBOX_MSG=""
        [ -n "$_slot" ] && INBOX_DELIVERY=""
        SETTINGS_FILE="/nonexistent"; DEFAULT_BRANCH="main"
        USER_HOME="$HOME_DIR"; HOME="$HOME_DIR"
        # shellcheck disable=SC1090
        . "$CHECK" >/dev/null 2>&1
        # shellcheck disable=SC1090
        . "$CHECK_B" >/dev/null 2>&1
        # shellcheck disable=SC1090
        [ -f "$CHECK_C" ] && . "$CHECK_C" >/dev/null 2>&1
        printf 'WARNINGS=%s\n' "$(printf '%s' "${WARNINGS:-}" | tr '\n' ' ')"
        printf 'INBOX_MSG=%s\n' "$(printf '%s' "${INBOX_MSG:-}" | tr '\n' ' ')"
        printf 'INBOX_DELIVERY=%s\n' "$(printf '%s' "${INBOX_DELIVERY:-}" | tr '\n' ' ')"
    )
}
field() { printf '%s' "$1" | sed -n "s/^$2=//p"; }

echo "=== D2: delivery by registry name as well as directory basename ==="
_out=$(run_check "$HOME_DIR/cfg-agent-fleet/auditor")
_msg=$(field "$_out" INBOX_MSG)
_warn=$(field "$_out" WARNINGS)

if printf '%s' "$_msg" | grep -q 'AUDITOR-ITEM-ONE'; then
    pass "a session in auditor/ receives the items filed for registry name fleet-auditor"
else
    fail "fleet-auditor's items not delivered to the auditor/ session: $_msg"
fi
if printf '%s' "$_msg" | grep -q 'INBOX TASKS for auditor.*fleet-auditor'; then
    pass "the delivery header names the registry alias"
else
    fail "header does not name the alias: $(printf '%s' "$_msg" | cut -c1-200)"
fi

echo "=== D4: child → parent surfacing reads the per-project files ==="
_out_life=$(run_check "$HOME_DIR/home")
_msg_life=$(field "$_out_life" INBOX_MSG)
if printf '%s' "$_msg_life" | grep -q 'CHILD project' && printf '%s' "$_msg_life" | grep -q 'Garden-CHILD-ITEM'; then
    pass "home sees garden's item from cross-project/inbox/garden.md"
else
    fail "child item invisible to the parent: $_msg_life"
fi
_out_cfg=$(run_check "$HOME_DIR/cfg-agent-fleet")
_msg_cfg=$(field "$_out_cfg" INBOX_MSG)
if printf '%s' "$_msg_cfg" | grep -q 'fleet-auditor (2 item(s))' && printf '%s' "$_msg_cfg" | grep -q 'AUDITOR-ITEM-ONE'; then
    pass "cfg-agent-fleet sees fleet-auditor's 2 items with a brief"
else
    fail "child count/brief missing for cfg-agent-fleet: $(printf '%s' "$_msg_cfg" | cut -c1-300)"
fi

echo "=== D5: the unknown-tag check reads the per-project files ==="
_ut=$(printf '%s' "$_warn" | grep -oE 'INBOX_UNKNOWN_TAG:[^|]*' | head -1)
if printf '%s' "$_ut" | grep -q 'typoproject'; then
    pass "a tag that matches no project is reported from a per-project file"
else
    fail "typoproject not reported: $_warn"
fi
if printf '%s' "$_ut" | grep -q 'fleet-auditor\|garden\|social'; then
    fail "a live project was reported as unknown: $_ut"
else
    pass "live projects are not reported as unknown"
fi
if printf '%s' "$_ut" | grep -q 'oldnotes.*successor.*home'; then
    pass "a tag for a deleted project is reported with its successor"
else
    fail "deleted-project tag not reported with successor: $_ut"
fi

echo "=== D2: per-project files no session can read are flagged ==="
_ur=$(printf '%s' "$_warn" | grep -oE 'INBOX_UNREACHABLE:[^|]*' | head -1)
if printf '%s' "$_ur" | grep -q 'oldnotes.md' && printf '%s' "$_ur" | grep -q 'typo.md'; then
    pass "oldnotes.md (deleted project) and typo.md (no project) are flagged unreachable"
else
    fail "unreachable files not flagged: $_warn"
fi
if printf '%s' "$_ur" | grep -q 'fleet-auditor.md\|garden.md\|social.md'; then
    fail "a readable file was flagged unreachable: $_ur"
else
    pass "files a live project or directory reads are not flagged"
fi

echo "=== D1: corpus signals name the corpus and count open items only ==="
_out_small=$(INBOX_TOKEN_CEILING=1 run_check "$HOME_DIR/social")
_os=$(field "$_out_small" WARNINGS | grep -oE 'INBOX_OVERSIZE:[^|]*' | head -1)
if [ -n "$_os" ] && ! printf '%s' "$_os" | grep -q 'inbox\.md is' && printf '%s' "$_os" | grep -q 'inbox/'; then
    pass "INBOX_OVERSIZE names the per-project corpus, not inbox.md"
else
    fail "INBOX_OVERSIZE wording: '$_os'"
fi
_st=$(printf '%s' "$_warn" | grep -oE 'INBOX_STALE:[^|]*' | head -1)
if printf '%s' "$_st" | grep -q 'INBOX_STALE: 2 open inbox item'; then
    pass "INBOX_STALE counts the 2 old OPEN items (measured: $(printf '%s' "$_st" | grep -oE 'INBOX_STALE: [0-9]+ [a-z ]*item'))"
else
    fail "INBOX_STALE should count exactly the 2 old open items, not the [x] item or the comment: '$_st'"
fi

echo "=== D6: the inbox block is capped per item and per block ==="
_item2=$(printf '%s' "$_msg" | grep -oE 'AUDITOR-ITEM-TWO x*' | head -1)
_len=${#_item2}
if [ "$_len" -gt 0 ] && [ "$_len" -le 260 ] && printf '%s' "$_msg" | grep -q 'shortened to 240'; then
    pass "a 1.5 kB item is delivered shortened (measured ${_len} chars of its body) and the block says so"
else
    fail "item not capped (body ${_len} chars) or cap not announced: $(printf '%s' "$_msg" | grep -oE '\[[0-9]+ item\(s\) shortened[^]]*\]')"
fi
_out_one=$(INBOX_BLOCK_MAX_ITEMS=1 run_check "$HOME_DIR/cfg-agent-fleet/auditor")
_msg_one=$(field "$_out_one" INBOX_MSG)
if printf '%s' "$_msg_one" | grep -q '1 more not shown' && ! printf '%s' "$_msg_one" | grep -q 'AUDITOR-ITEM-ONE'; then
    pass "with INBOX_BLOCK_MAX_ITEMS=1 only the leading fact item is shown and the rest is counted"
else
    fail "block cap not applied: $(printf '%s' "$_msg_one" | cut -c1-300)"
fi
if printf '%s' "$_msg_one" | grep -q 'cross-project/inbox/'; then
    pass "the cap note points at the per-project file for the full text"
else
    fail "cap note does not name the per-project file: $(printf '%s' "$_msg_one" | cut -c1-300)"
fi

echo "=== D6: the block goes into INBOX_DELIVERY when config-check.sh declares it ==="
_out_slot=$(run_check "$HOME_DIR/cfg-agent-fleet/auditor" slot)
_dl=$(field "$_out_slot" INBOX_DELIVERY)
_msg_slot=$(field "$_out_slot" INBOX_MSG)
if printf '%s' "$_dl" | grep -q 'INBOX TASKS for auditor' && ! printf '%s' "$_msg_slot" | grep -q 'INBOX TASKS for auditor'; then
    pass "the delivery block lands in INBOX_DELIVERY and not in INBOX_MSG"
else
    fail "slot not used (delivery='$(printf '%s' "$_dl" | cut -c1-80)', msg='$(printf '%s' "$_msg_slot" | cut -c1-80)')"
fi
if printf '%s' "$_msg" | grep -q 'INBOX TASKS for auditor'; then
    pass "without the slot (older config-check.sh) the block still reaches INBOX_MSG"
else
    fail "skew fallback lost the block: $(printf '%s' "$_msg" | cut -c1-120)"
fi

echo "=== CFG-503: the JSON contract is intact ==="
_stray=$(
    cd "$HOME_DIR/cfg-agent-fleet/auditor" || exit 1
    CONFIG_REPO="$REPO"; WARNINGS=""; INBOX_MSG=""; INBOX_DELIVERY=""
    SETTINGS_FILE="/nonexistent"; DEFAULT_BRANCH="main"; USER_HOME="$HOME_DIR"; HOME="$HOME_DIR"
    # shellcheck disable=SC1090
    . "$CHECK" 2>/dev/null
    # shellcheck disable=SC1090
    . "$CHECK_B" 2>/dev/null
    # shellcheck disable=SC1090
    [ -f "$CHECK_C" ] && . "$CHECK_C" 2>/dev/null
)
if [ -z "$_stray" ]; then
    pass "the three checks write nothing to stdout"
else
    fail "a check echoed to stdout, which would corrupt additionalContext: $_stray"
fi

echo "=== CFG-171: hook check modules stay under the 150-line split limit ==="
for _f in "$CHECK" "$CHECK_B" "$CHECK_C"; do
    if [ ! -f "$_f" ]; then
        fail "$(basename "$_f") does not exist"
        continue
    fi
    _n=$(wc -l < "$_f" | tr -d ' ')
    if [ "$_n" -le 150 ]; then
        pass "$(basename "$_f") is $_n lines (limit 150)"
    else
        fail "$(basename "$_f") is $_n lines — over the 150-line hard limit for hook checks"
    fi
done

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
