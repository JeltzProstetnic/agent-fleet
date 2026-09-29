#!/usr/bin/env bash
# CFG-676 — the two hooks whose security fixes stranded on one machine must be
# Category 1 (propagated verbatim by template-push) and must STAY free of the
# literals that made them Category 3.
#
# Why this is a product test and not a style check: template-push.sh decides a
# file's fate from THREE inputs that have to agree — the manifest section its
# row sits in (Must Be Identical = copied), the `flag_only=` list in
# template-push.conf (never copied, and skipped by the leak scan), and the
# `personal_patterns` gate in the same conf (a hit holds the file back). Any
# one of the three left behind means the file silently never ships. The gate's
# patterns are also case-sensitive (`\bBartl\b` never matched `bartl-mail-check`,
# `\bElsa\b` never matched `elsa-home`), so the persona/host assertions here
# are case-insensitive on purpose — stricter than the gate, which is the point.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/setup/tests/test-helpers.sh"

suite_header "CFG-676: 07b-platform-env.sh and config-auto-sync.sh are generic and Cat-1"

CONF="$REPO_ROOT/setup/config/template-push.conf"
MANIFEST="$REPO_ROOT/template-sync-manifest.md"
HOOK_07B="global/hooks/checks/07b-platform-env.sh"
# CFG-721: the session-lock section (was 7b.4) lives in its own Cat-1 check.
HOOK_07C="global/hooks/checks/07c-session-lock.sh"
HOOK_CAS="global/hooks/config-auto-sync.sh"

# CFG-709: this file ships downstream (Must Be Identical), but template-push.conf
# is the source repo's own propagation config and never does. Without it the
# gate pattern is empty and an empty ERE matches every line ('787 hits'), so the
# suite would fail on a clone for a reason that has nothing to do with the hooks.
if [[ ! -f "$CONF" ]]; then
    skip_test "CFG-676 Cat-1 guards" "no setup/config/template-push.conf — this install is downstream of template-push, the guards only apply at the source"
    suite_summary
    exit 0
fi

# The gate regex exactly as template-push.sh's load_conf reads it: parameter
# expansion trim, never xargs (CFG-606 — xargs ate every `\b`).
_gate_patterns() {
    local line
    line="$(grep -E '^[[:space:]]*personal_patterns[[:space:]]*=' "$CONF" | head -1)"
    line="${line#*=}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    printf '%s' "$line"
}

# Same awk as template-push.sh's get_identical_files.
_identical_files() {
    awk '
        /^## Tracked Files.*Must Be Identical/ { in_sec=1; next }
        /^## / && in_sec { in_sec=0 }
        in_sec && /^\| `[^`]+` \|/ { print }
    ' "$MANIFEST" | sed 's/^| `//;s/` |.*//'
}

# Count of case-insensitive ERE hits in a repo file; the hits themselves go to
# stdout first so a failure names the offending lines.
_ci_hit_count() {   # <repo-relative file> <ERE>
    local hits
    hits="$(grep -n -i -E "$2" "$REPO_ROOT/$1" || true)"
    [[ -z "$hits" ]] || printf '%s\n' "$hits"
    printf '%s' "$hits" | grep -c . || true
}

test_07b_has_no_persona_literal() {
    local n
    local f
    for f in "$HOOK_07B" "$HOOK_07C"; do
        n="$(_ci_hit_count "$f" 'bartl' | tail -1)"
        assert_eq "0" "$n" "$f carries no persona literal (measured case-insensitive 'bartl' hits: $n)"
    done
}
run_test "07b: no persona literal — neither the mail-check filename nor the output tag" test_07b_has_no_persona_literal

test_cas_has_no_host_or_persona_literal() {
    # The gate's own vocabulary, applied case-INsensitively (the gate is case-
    # sensitive, which is how a persona's home directory and an employer's name
    # in comments slipped through), plus the deployment's ssh host alias, which
    # no gate pattern covers. The literals are deliberately not spelled in this
    # file: a test that names them is itself held by the gate — measured.
    local n
    n="$(_ci_hit_count "$HOOK_CAS" "$(_gate_patterns)|\\bvps\\b" | tail -1)"
    assert_eq "0" "$n" "config-auto-sync.sh carries no persona/employer/host literal (measured case-insensitive hits: $n)"
}
run_test "config-auto-sync.sh: no persona, employer or host literal" test_cas_has_no_host_or_persona_literal

test_hooks_have_no_repo_name_literal() {
    # Both hooks resolve the config repo at runtime (CONFIG_REPO / lib-detect-repo);
    # a verbatim copy lands in a repo with a different name, so the name must not
    # appear even in a comment.
    local n7 n7c nc
    n7="$(grep -c 'cfg-agent-fleet' "$REPO_ROOT/$HOOK_07B" || true)"
    assert_file_exists "$REPO_ROOT/$HOOK_07C" || return 1
    n7c="$(grep -c 'cfg-agent-fleet' "$REPO_ROOT/$HOOK_07C" || true)"
    assert_eq "0" "$n7c" "07c has no repo-name literal (measured: $n7c)"
    nc="$(grep -c 'cfg-agent-fleet' "$REPO_ROOT/$HOOK_CAS" || true)"
    assert_eq "0" "$n7" "07b has no repo-name literal (measured: $n7)" || return 1
    assert_eq "0" "$nc" "config-auto-sync.sh has no repo-name literal (measured: $nc)"
}
run_test "both hooks: no hardcoded repo name" test_hooks_have_no_repo_name_literal

test_hooks_pass_the_leak_gate() {
    local pat hits n f
    pat="$(_gate_patterns)"
    [[ -n "$pat" ]] || { echo "FAIL: personal_patterns not found in $CONF"; return 1; }
    for f in "$HOOK_07B" "$HOOK_07C" "$HOOK_CAS"; do
        # scan_leaks also whitelists the template's own GitHub URL; that
        # exclusion is not replicated here (naming it would hold this file),
        # so this check is strictly at least as strict as the gate.
        hits="$(grep -n -E "$pat" "$REPO_ROOT/$f" 2>/dev/null \
            | grep -v 'PERSONAL_DATA_PATTERNS\|personal_patterns' || true)"
        n="$(printf '%s' "$hits" | grep -c . || true)"
        [[ -z "$hits" ]] || printf '%s\n' "$hits"
        assert_eq "0" "$n" "$f passes template-push's personal-data gate (measured hit lines: $n)" || return 1
    done
}
run_test "both hooks: zero hits against template-push.conf personal_patterns" test_hooks_pass_the_leak_gate

test_conf_does_not_flag_them() {
    local n
    n="$(grep -c -E "^[[:space:]]*flag_only[[:space:]]*=[[:space:]]*($HOOK_07B|$HOOK_07C|$HOOK_CAS)[[:space:]]*$" "$CONF" || true)"
    assert_eq "0" "$n" "template-push.conf has no flag_only= line for either hook (measured: $n)"
}
run_test "template-push.conf: neither hook is flag_only" test_conf_does_not_flag_them

test_manifest_lists_them_as_identical() {
    local list
    list="$(_identical_files)"
    printf '%s\n' "$list" | grep -Fxq "$HOOK_07B" \
        || { echo "FAIL: $HOOK_07B is not under 'Must Be Identical'"; return 1; }
    printf '%s\n' "$list" | grep -Fxq "$HOOK_07C" \
        || { echo "FAIL: $HOOK_07C is not under 'Must Be Identical'"; return 1; }
    printf '%s\n' "$list" | grep -Fxq "$HOOK_CAS" \
        || { echo "FAIL: $HOOK_CAS is not under 'Must Be Identical'"; return 1; }
    echo "  both hooks found under 'Must Be Identical' ($(printf '%s\n' "$list" | grep -c .) rows in section)"
}
run_test "manifest: both hooks sit under 'Must Be Identical'" test_manifest_lists_them_as_identical

test_hooks_are_not_in_both_sections() {
    # A row in Intentional Diffs AND Must Be Identical would make the file's
    # category depend on parser order. Exactly one section, and it is the first.
    local n f
    for f in "$HOOK_07B" "$HOOK_07C" "$HOOK_CAS"; do
        n="$(awk '
            /^## Tracked Files.*Intentional Diffs/ { in_sec=1; next }
            /^## / && in_sec { in_sec=0 }
            in_sec && /^\| `[^`]+` \|/ { print }
        ' "$MANIFEST" | sed 's/^| `//;s/` |.*//' | grep -Fxc "$f" || true)"
        assert_eq "0" "$n" "$f has no leftover row under 'Intentional Diffs' (measured: $n)" || return 1
    done
}
run_test "manifest: no leftover Intentional-Diffs row for either hook" test_hooks_are_not_in_both_sections

test_lock_section_moved_to_07c() {
    # CFG-721: 07b was 171 lines against the 150-line hook-check limit.
    local lines
    lines="$(wc -l < "$REPO_ROOT/$HOOK_07B")"
    [[ "$lines" -le 150 ]] || { echo "FAIL: 07b has $lines lines (limit 150)"; return 1; }
    assert_not_contains "$(cat "$REPO_ROOT/$HOOK_07B")" "check_lock" "07b no longer runs the lock check"
    assert_contains "$(cat "$REPO_ROOT/$HOOK_07C" 2>/dev/null)" 'check_lock "$PWD"' "07c runs the lock check"
    echo "  07b measured at $lines lines"
}
run_test "CFG-721: the session-lock section lives in 07c, 07b is within the limit" test_lock_section_moved_to_07c

suite_summary
