#!/usr/bin/env bash
# test-afleet-integrity.sh — Smoke tests for launcher chain integrity
# Catches: syntax errors, missing functions, set -e, broken sourcing
# Run: bash setup/tests/test-afleet-integrity.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0; FAIL=0; TESTS=0
pass() { ((PASS++)); ((TESTS++)); echo "  PASS: $1"; }
fail() { ((FAIL++)); ((TESTS++)); echo "  FAIL: $1"; }

AFLEET="$REPO_ROOT/setup/scripts/afleet.sh"
AFLEET_LIB="$REPO_ROOT/setup/scripts/afleet-lib.sh"

echo "=== afleet launcher integrity tests ==="

# ── T1: Syntax check all launcher scripts ────────────────────────
echo ""
echo "T1: Syntax check"
for f in "$AFLEET" "$AFLEET_LIB"; do
    if [[ -f "$f" ]]; then
        if bash -n "$f" 2>/dev/null; then
            pass "syntax OK: $(basename "$f")"
        else
            fail "syntax ERROR: $(basename "$f")"
        fi
    else
        fail "file missing: $(basename "$f")"
    fi
done

# ── T2: afleet.sh must NOT contain 'set -e' ─────────────────────
echo ""
echo "T2: No set -e in launcher"
if grep -qE '^set\s+-[a-z]*e[a-z]*\b' "$AFLEET" 2>/dev/null; then
    fail "afleet.sh uses set -e — launcher must NEVER use errexit"
else
    pass "no set -e found"
fi

# ── T3: _fallback_launch function exists ─────────────────────────
echo ""
echo "T3: Fallback launch mechanism"
if grep -q '_fallback_launch' "$AFLEET" 2>/dev/null; then
    pass "_fallback_launch defined in afleet.sh"
else
    fail "_fallback_launch not found — launcher has no degraded mode"
fi

# ── T4: source afleet-lib.sh is guarded ──────────────────────────
echo ""
echo "T4: Library sourcing is guarded"
if grep -qE 'bash -n.*afleet-lib\.sh' "$AFLEET" 2>/dev/null; then
    pass "afleet-lib.sh sourcing includes syntax check"
else
    fail "afleet-lib.sh sourcing has no syntax guard"
fi

# ── T5: Required functions resolve after sourcing lib ────────────
echo ""
echo "T5: Function resolution"

# Definitions in both files
all_defs=$(grep -ohE '^[[:space:]]*(function[[:space:]]+)?[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)' \
    "$AFLEET" "$AFLEET_LIB" 2>/dev/null \
    | sed 's/^[[:space:]]*//;s/function //;s/[[:space:]]*()$//' | sort -u)

required=(
    parse_registry
    parse_dashboard_cache
    start_spinner
    stop_spinner
    steamos_preflight
    pre_pull_all_repos
)

for func in "${required[@]}"; do
    if echo "$all_defs" | grep -qxF "$func"; then
        pass "resolved: $func"
    else
        fail "MISSING: $func — called but not defined"
    fi
done

# ── T6: No unguarded source commands ─────────────────────────────
echo ""
echo "T6: All source commands are guarded"
# Find source lines that don't have || or if/then guards
unguarded=$(grep -n '^\s*source\s' "$AFLEET" 2>/dev/null | grep -v '||' | grep -v '_fallback_launch' || true)
if [[ -z "$unguarded" ]]; then
    pass "all source commands have error guards"
else
    fail "unguarded source found: $unguarded"
fi

# ── T7: exec to nonexistent files is guarded ────────────────────
echo ""
echo "T7: exec commands are guarded"
# Check each exec bash line has a -f guard within 3 lines above it
t7_fail=0
while IFS=: read -r lineno line; do
    [[ -z "$lineno" ]] && continue
    start=$((lineno - 3)); [[ $start -lt 1 ]] && start=1
    context=$(sed -n "${start},${lineno}p" "$AFLEET")
    if echo "$context" | grep -qE '\-f\b|if \['; then
        pass "exec at line $lineno is guarded"
    else
        fail "unguarded exec at line $lineno: $line"
        t7_fail=1
    fi
done < <(grep -n 'exec bash' "$AFLEET" 2>/dev/null || true)
[[ $t7_fail -eq 0 ]] || true

# ── T8: mclaude launch line exists ───────────────────────────────
echo ""
echo "T8: Launch line reachable"
if grep -qE '"\$MCLAUDE"' "$AFLEET" 2>/dev/null; then
    pass "mclaude launch line found"
else
    fail "mclaude launch line missing"
fi

# ── Summary ──────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
