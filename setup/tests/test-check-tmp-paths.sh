#!/usr/bin/env bash
# Tests for agent-fleet GH#13 (residual): SessionStart check modules must not
# hardcode /tmp. Claude Code's Bash sandbox mounts /tmp READ-ONLY and points
# TMPDIR at a writable scratchpad; safe-run.sh was fixed to honour it, but the
# daily-gate fallbacks in checks/ still wrote "/tmp/.<name>-<date>" — every
# gate then failed to persist and the check re-ran (and re-reported) each
# session, on a healthy machine. Markers go to ${SCHED_MARKER_DIR:-${TMPDIR:-/tmp}}.
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/test-check-helpers.sh"

suite_header "checks/: no hardcoded /tmp (GH#13 residual)"

CHECKS_DIR="$REPO_ROOT/global/hooks/checks"

# ── 1. Lint: no live check module names /tmp/ as a literal path ──────────────
# "${TMPDIR:-/tmp}" is the accepted form (no "/tmp/" substring). Disabled
# twins (*.sh.disabled) are not loaded and are not linted.
test_no_literal_tmp_in_checks() {
    local offenders
    offenders=$(grep -n '/tmp/' "$CHECKS_DIR"/*.sh 2>/dev/null || true)
    if [ -n "$offenders" ]; then
        echo "hardcoded /tmp/ in check modules:" >&2
        echo "$offenders" >&2
        return 1
    fi
}
run_test "lint: no checks/*.sh module hardcodes /tmp/" test_no_literal_tmp_in_checks

# ── 1b. Lint: no suite clears or plants a check's daily gate under /tmp ──────
# Moving the gates off /tmp left suites that still `rm -f /tmp/.<name>-check-*`
# before each case: with TMPDIR set (macOS always; the CC sandbox) the first
# case's gate was never cleared and every later case saw no output. A suite
# must pin SCHED_MARKER_DIR inside its sandbox and clear the marker there.
test_no_literal_tmp_gate_in_suites() {
    local offenders
    offenders=$(grep -nE '/tmp/\.[a-z0-9-]+-check-' "$REPO_ROOT"/setup/tests/test-*.sh 2>/dev/null || true)
    if [ -n "$offenders" ]; then
        echo "suites that clear/plant a daily-gate marker under a literal /tmp:" >&2
        echo "$offenders" >&2
        return 1
    fi
}
run_test "lint: no setup/tests suite clears a daily-gate marker under a literal /tmp" test_no_literal_tmp_gate_in_suites

# ── 2. Functional: the knowledge-index daily gate lives under TMPDIR ─────────
# 23-knowledge-index.sh has no sched-lib path at all — its gate was a bare
# /tmp literal. Run the hook twice with TMPDIR pointing at a private dir: the
# first run must create the marker THERE, the second must be gated by it.
_ki_env() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    # A knowledge dir with one file MISSING from INDEX.md → the check reports.
    mkdir -p "$config_repo/global/knowledge"
    printf '# Index\n\n| `alpha.md` | one |\n' > "$config_repo/global/knowledge/INDEX.md"
    printf '# alpha\n' > "$config_repo/global/knowledge/alpha.md"
    printf '# beta\n' > "$config_repo/global/knowledge/beta.md"
    create_patched_script "$config_repo" "$mock_home" "$project_dir"
}

test_knowledge_index_gate_under_tmpdir() {
    local patched scratch out
    patched=$(_ki_env)
    scratch="$TEST_TMPDIR/scratch"
    mkdir -p "$scratch"

    out=$(TMPDIR="$scratch" run_hook "$patched")
    assert_contains "$out" "KNOWLEDGE_INDEX" "first run reports (beta.md is not indexed)" || return 1
    local marker
    marker=$(ls "$scratch"/.knowledge-index-check-* 2>/dev/null | head -1)
    [ -n "$marker" ] || { echo "no gate marker under TMPDIR=$scratch" >&2; return 1; }

    out=$(TMPDIR="$scratch" run_hook "$patched")
    assert_not_contains "$out" "KNOWLEDGE_INDEX" "second run is gated by the marker it wrote"
}
run_test "23-knowledge-index: daily gate marker is written to and read from TMPDIR" test_knowledge_index_gate_under_tmpdir

# ── 3. Functional: sched-lib-less fallback gates honour TMPDIR too ───────────
# With no sched-lib.sh in the config repo, 04-auto-fix's dependency check
# uses its inline marker. npm is mocked to fail fast so nothing hits the
# network; the marker is what is under test.
test_autofix_fallback_gate_under_tmpdir() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    rm -f "$config_repo/setup/scripts/sched-lib.sh"
    local mockbin="$TEST_TMPDIR/mockbin"
    mkdir -p "$mockbin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$mockbin/npm"
    chmod +x "$mockbin/npm"
    local patched scratch
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    scratch="$TEST_TMPDIR/scratch"
    mkdir -p "$scratch"

    PATH="$mockbin:$PATH" TMPDIR="$scratch" run_hook "$patched" >/dev/null
    local marker
    marker=$(ls "$scratch"/.cc-dep-check-* 2>/dev/null | head -1)
    [ -n "$marker" ] || { echo "no .cc-dep-check marker under TMPDIR=$scratch" >&2; return 1; }
}
run_test "04-auto-fix: inline fallback gate marker is written under TMPDIR" test_autofix_fallback_gate_under_tmpdir

suite_summary
