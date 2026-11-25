#!/usr/bin/env bash
# Tests for global/hooks/checks/30-project-conformance.sh — CFG-1094, Q-1094-COMMIT.
#
# Every project's own SessionStart applies the mechanical conformance fixes to its own tree
# (template .githooks/pre-commit, .gitignore lines, a retired-name pointer in CLAUDE.md), files
# ONE backlog item for the rest, and adds ONE line to the startup context naming what it fixed
# and telling the session to commit it. The hook never commits. Silent when there is nothing
# to do, and in directories that are not registered fleet projects.
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/lib-pc-fixture.sh"

CHECK="$REPO_ROOT/global/hooks/checks/30-project-conformance.sh"

suite_header "check 30: project-conformance (CFG-1094: fix own tree, file the rest, one line)"

_run() {   # PROJECT_DIR must be set
    WARNINGS=""; INBOX_MSG=""
    CONFIG_REPO="$REPO_ROOT"
    # shellcheck disable=SC1090
    source "$CHECK"
    printf 'W=%s\nI=%s\n' "$WARNINGS" "$INBOX_MSG"
}

t_fixes_and_says_so_once() {
    pcf_cfg; pcf_project own --legacy-inbox --no-gitignore --tracked-tmp 1
    PROJECT_DIR="$P"
    local out; out=$(_run)
    assert_contains "$out" "W=PROJECT_CONFORMANCE: fixed .githooks/pre-commit copied from the template; .gitignore +4 line(s)" || return 1
    assert_contains "$out" "CLAUDE.md: 1 line(s) rewritten from cross-project/inbox.md" || return 1
    assert_contains "$out" "commit these in this session" || return 1
    assert_contains "$out" "Filed backlog item FIX-13 for:" || return 1
    assert_contains "$out" "1 tracked file(s) under tmp/" || return 1
    assert_file_contains "$P/backlog.md" '^- \[ \] \[P2\] `FIX-13` \*\*Project conformance\*\*' "check 30 files at P2 (Q-1094-ITEMPRIO)" || return 1
    assert_eq "1" "$(printf '%s' "$out" | grep -o 'PROJECT_CONFORMANCE' | wc -l | tr -d ' ')" "exactly one line" || return 1
    cmp -s "$P/.githooks/pre-commit" "$PC_TEMPLATE_HOOK" || { echo "    hook not copied" >&2; return 1; }
    assert_file_contains "$P/CLAUDE.md" 'cross-project/inbox/<project>.md' || return 1
    assert_eq "0" "$(git -C "$P" log --oneline | grep -c conformance || true)" "the hook never commits" || return 1
    [ -n "$(git -C "$P" status --porcelain)" ] || { echo "    the fixes must be left for the session to commit" >&2; return 1; }
    out=$(_run)
    assert_eq "W=" "$(printf '%s\n' "$out" | head -1)" "a conforming, tracked project is silent on the next start"
}
run_test "fixes the own tree, files one item, says so once, never commits" t_fixes_and_says_so_once

t_conforming_is_silent() {
    pcf_cfg; pcf_project ok --githooks --knowledge vertical-slicing.md --knowledge needs-to-requirements.md \
        --knowledge test-isolation-guards.md --knowledge anti-chain-state.md --knowledge log-evidence-traps.md --knowledge llm-provider-integration.md
    PROJECT_DIR="$P"
    assert_eq "W=
I=" "$(_run)" "nothing to fix, nothing to file, nothing to say" || return 1
    assert_eq "" "$(git -C "$P" status --porcelain)"
}
run_test "a conforming project gets no line and no write" t_conforming_is_silent

t_home_and_unregistered_untouched() {
    pcf_cfg
    PROJECT_DIR="$HOME"; mkdir -p "$HOME/.claude"; printf '# Global\n' > "$HOME/.claude/CLAUDE.md"
    assert_eq "W=
I=" "$(_run)" "the home directory is not a project" || return 1
    assert_file_not_exists "$HOME/.githooks/pre-commit" || return 1
    mkdir -p "$HOME/stranger"; git -C "$HOME/stranger" init -q -b main; pcf_manifest "$HOME/stranger/CLAUDE.md" --legacy-inbox
    PROJECT_DIR="$HOME/stranger"
    assert_eq "W=
I=" "$(_run)" "an unregistered repo is not a fleet project" || return 1
    assert_file_not_exists "$HOME/stranger/.githooks/pre-commit" || return 1
    assert_file_contains "$HOME/stranger/CLAUDE.md" 'cross-project/inbox.md` | Cross-project tasks' "its manifest is not rewritten"
}
run_test "never writes into \$HOME or an unregistered directory" t_home_and_unregistered_untouched

t_opt_out_untouched() {
    pcf_cfg; pcf_project optout --legacy-inbox --no-gitignore --no-marker --tracked-tmp 2
    printf 'upstream clone\n' > "$P/.fleet-conformance-skip"
    git -C "$P" add .fleet-conformance-skip >/dev/null; git -C "$P" commit -qm marker >/dev/null
    PROJECT_DIR="$P"
    assert_eq "W=
I=" "$(_run)" "an opted-out project gets no line (Q-1094-SEARXNG)" || return 1
    assert_eq "" "$(git -C "$P" status --porcelain)" "and nothing is changed or filed there" || return 1
    assert_file_not_exists "$P/.githooks/pre-commit"
}
run_test "a project with .fleet-conformance-skip is left alone by the hook" t_opt_out_untouched

t_mobile_repo_untouched() {
    pcf_cfg; pcf_project mob --legacy-inbox; : > "$P/.mobile-repo"
    PROJECT_DIR="$P"
    local out; out=$(_run)
    assert_file_not_exists "$P/.githooks/pre-commit" "the mobile snapshot is read-only" || return 1
    assert_file_contains "$P/CLAUDE.md" 'cross-project/inbox.md` | Cross-project tasks'
}
run_test "the mobile snapshot repo is left alone" t_mobile_repo_untouched

t_crashed_or_empty_script_reported() {
    pcf_cfg; pcf_project cr
    PROJECT_DIR="$P"
    local fake="$TEST_TMPDIR/fake-cfg"; mkdir -p "$fake/setup/scripts"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$fake/setup/scripts/project-conformance.sh"
    WARNINGS=""; INBOX_MSG=""; CONFIG_REPO="$fake"
    # shellcheck disable=SC1090
    source "$CHECK"
    assert_contains "$WARNINGS" "PROJECT_CONFORMANCE: script failed (rc 1)" "a crash is reported, never swallowed (MINOR b)" || return 1
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/setup/scripts/project-conformance.sh"
    WARNINGS=""; INBOX_MSG=""
    # shellcheck disable=SC1090
    source "$CHECK"
    assert_contains "$WARNINGS" "PROJECT_CONFORMANCE: script produced no output" "silence from the script is a defect, the sentinel is what 'nothing to say' looks like"
}
run_test "a crashed or silent script run is reported" t_crashed_or_empty_script_reported

t_behind_upstream_defers() {
    pcf_cfg; pcf_project lag --legacy-inbox --no-gitignore
    pcf_bare_remote "$P" >/dev/null; pcf_backfill_upstream "$P" || return 1
    PROJECT_DIR="$P"
    local out; out=$(_run)
    assert_eq "W=" "$(printf '%s\n' "$out" | head -1)" "a deferral is information, not a warning" || return 1
    assert_contains "$out" "I=PROJECT_CONFORMANCE: deferred — HEAD is 1 commit(s) behind @{u}" || return 1
    assert_eq "" "$(git -C "$P" status --porcelain)" "nothing written before the pull (MAJOR 1)" || return 1
    git -C "$P" pull -q --ff-only >/dev/null 2>&1 || { echo "    the startup pull failed" >&2; return 1; }
}
run_test "behind the fetched upstream the hook defers so the startup pull succeeds" t_behind_upstream_defers

t_script_missing_is_reported() {
    pcf_cfg; pcf_project nos
    PROJECT_DIR="$P"
    WARNINGS=""; INBOX_MSG=""; CONFIG_REPO="$TEST_TMPDIR/empty-cfg"; mkdir -p "$CONFIG_REPO"
    # shellcheck disable=SC1090
    source "$CHECK"
    assert_contains "$WARNINGS" "PROJECT_CONFORMANCE: script missing" "a missing script is a degradation, never silence"
}
run_test "a missing script is reported, not swallowed" t_script_missing_is_reported

suite_summary
