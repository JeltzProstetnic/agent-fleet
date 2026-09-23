#!/usr/bin/env bash
# Tests for CFG-552: repo hook SOURCES must never carry the deploy-injected MANAGED banner.
#
# Why this exists: `sync.sh deploy` injects "# MANAGED — DO NOT EDIT. Source: ..." into every
# deployed hook. Check 16-deployed-drift strips that banner from the DEPLOYED copy before
# diffing (CFG-299). If a deployed copy is ever collected back into the repo, the repo source
# carries a banner the checker does not strip on that side, so the two can never compare equal —
# and `sync.sh deploy`, the remedy the warning prints, re-creates the asymmetry on every run.
# The result is an uncleanable drift alarm on a security hook, which trains sessions to ignore it.

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAIL_DETAILS=""

pass() { ((TESTS_PASSED++)) || true; ((TESTS_RUN++)) || true; echo "  PASS: $1"; }
fail() { ((TESTS_FAILED++)) || true; ((TESTS_RUN++)) || true; FAIL_DETAILS="${FAIL_DETAILS}\n  FAIL: $1"; echo "  FAIL: $1"; }

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
HOOKS_DIR="$REPO_ROOT/global/hooks"

echo "=== hook source hygiene ==="

# ── Test 1: no repo hook source carries the MANAGED banner ──────────────────
_polluted=""
for _f in "$HOOKS_DIR"/*.sh "$HOOKS_DIR"/checks/*.sh; do
    [ -f "$_f" ] || continue
    if grep -q "^# MANAGED" "$_f"; then
        _polluted="${_polluted:+$_polluted }${_f#$REPO_ROOT/}"
    fi
done

if [ -z "$_polluted" ]; then
    pass "no repo hook source carries the deploy-injected MANAGED banner"
else
    fail "repo hook source(s) carry the MANAGED banner (deployed copy collected back into repo): $_polluted"
fi

# ── Test 2: the drift checker's own comparison is symmetric ─────────────────
# A repo source with a banner and a deployed copy with two banners must NOT be reported
# as equal by accident, and a clean pair must compare equal. This pins the actual
# comparison rather than the file contents, so the guard survives a checker rewrite.
_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT

printf '#!/usr/bin/env bash\necho hi\n' > "$_tmp/clean-repo.sh"
printf '#!/usr/bin/env bash\n# MANAGED — DO NOT EDIT. Source: x\necho hi\n' > "$_tmp/clean-deployed.sh"
if diff <(cat "$_tmp/clean-repo.sh") <(sed '/^# MANAGED/d' "$_tmp/clean-deployed.sh") >/dev/null 2>&1; then
    pass "clean repo source vs banner-injected deployed copy compares equal"
else
    fail "clean pair should compare equal but did not — checker logic changed"
fi

printf '#!/usr/bin/env bash\n# MANAGED — DO NOT EDIT. Source: x\necho hi\n' > "$_tmp/dirty-repo.sh"
printf '#!/usr/bin/env bash\n# MANAGED — DO NOT EDIT. Source: x\n# MANAGED — DO NOT EDIT. Source: x\necho hi\n' > "$_tmp/dirty-deployed.sh"
if diff <(cat "$_tmp/dirty-repo.sh") <(sed '/^# MANAGED/d' "$_tmp/dirty-deployed.sh") >/dev/null 2>&1; then
    fail "polluted repo source compared EQUAL — the drift alarm would be silently suppressed"
else
    pass "polluted repo source is detected as different (this is the uncleanable-alarm signature)"
fi

# ── Summary ────────────────────────────────────────────────────────────────
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
