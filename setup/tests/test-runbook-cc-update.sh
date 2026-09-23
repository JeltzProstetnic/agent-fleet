#!/usr/bin/env bash
# Binds the DOCUMENTED Claude Code update procedure to fleet-owned, tested code.
#
# TDD: written 2026-09-23, RED until the runbook lines are edited. Rule under test:
#
#   Every place the fleet tells an operator (human or agent) how to update Claude Code
#   must name setup/scripts/cc-update.sh — the wrapper that has a unit suite
#   (test-cc-update.sh), an E2E suite (test-e2e-cc-update.sh), a backup phase, a version
#   verify phase and an in-session refusal — and must NOT name the raw third-party verb
#   `cc-mirror update …`, which has none of those and whose behaviour depends on which
#   cc-mirror happens to be on PATH.
#
# Why this test is cheap and honest: it cannot prove the prose is right, only that the
# prose points at code a test can reach. That is the whole gap it closes — on 2026-09-23
# global/CLAUDE.md line 156 told every session to run `cc-mirror update mclaude
# --claude-version latest --no-tweak`, no test read that line, the wrapper that WAS
# tested was not what the line named, and a stale cc-mirror 1.6.2 on the Windows PATH
# executed a flag it did not know and reset the install to 2.1.1 with exit 0.
#
# Slots checked (targeted, not a blanket grep, so history/incident prose can still
# mention the verb): global/CLAUDE.md `**CC update:**`; upstream-dependencies.md
# `**CC update procedure:**`; fleet-capabilities.md `To switch:` and `Update path:`;
# update-checker.sh's printed remedy (behavioural, both layouts). Plus one blanket rule
# for global/CLAUDE.md alone, because it is in every session's context: the backticked
# command form `cc-mirror update` must not appear there at all.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"
source "$SCRIPT_DIR/lib-cc-install-fixture.sh"

CLAUDE_MD="$REPO_ROOT/global/CLAUDE.md"
UPSTREAM_MD="$REPO_ROOT/global/reference/upstream-dependencies.md"
CAPS_MD="$REPO_ROOT/global/knowledge/fleet-capabilities.md"
CC_UPDATE="$REPO_ROOT/setup/scripts/cc-update.sh"
UPDATE_CHECKER="$REPO_ROOT/setup/scripts/update-checker.sh"

suite_header "runbook binding: documented CC update command → cc-update.sh"

slot() {  # slot <file> <marker>  → the first line containing <marker>; the record goes to stderr
    local line
    line=$(grep -m1 -F "$2" "$1" 2>/dev/null || true)
    echo "    measured [$2]: $(printf '%s' "$line" | cut -c1-160)" >&2
    printf '%s' "$line"
}

# ── The binding target must be real and tested (GREEN today — the wrapper exists) ──
test_wrapper_exists_and_has_tests() {
    assert_file_exists "$CC_UPDATE" "cc-update.sh must exist" || return 1
    [[ -x "$CC_UPDATE" ]] || { echo "    cc-update.sh is not executable" >&2; return 1; }
    assert_file_exists "$SCRIPT_DIR/test-cc-update.sh" "cc-update.sh must have a unit suite" || return 1
    assert_file_exists "$SCRIPT_DIR/test-e2e-cc-update.sh" "cc-update.sh must have an E2E suite" || return 1
    assert_file_contains "$CC_UPDATE" 'CLAUDE_CONFIG_DIR' "wrapper must keep its in-session refusal"
}
run_test "binding target: cc-update.sh exists, executable, unit + E2E suites present" test_wrapper_exists_and_has_tests

# ── global/CLAUDE.md ─────────────────────────────────────────────────────────
test_claude_md_cc_update_slot_names_wrapper() {
    local line; line=$(slot "$CLAUDE_MD" '**CC update:**')
    [[ -n "$line" ]] || { echo "    no '**CC update:**' slot found in global/CLAUDE.md" >&2; return 1; }
    assert_contains "$line" "cc-update.sh" "the CC update slot must name the wrapper" || return 1
    assert_not_contains "$line" "cc-mirror update" "the CC update slot must not name the raw verb"
}
run_test "global/CLAUDE.md '**CC update:**' names cc-update.sh, not cc-mirror update" test_claude_md_cc_update_slot_names_wrapper

test_claude_md_has_no_backticked_cc_mirror_update() {
    local hits
    hits=$(grep -n -F '`cc-mirror update' "$CLAUDE_MD" 2>/dev/null || true)
    echo "    measured hits: [$(printf '%s' "$hits" | cut -c1-120)]"
    [[ -z "$hits" ]] || { echo "    global/CLAUDE.md carries the raw verb as a command" >&2; return 1; }
}
run_test "global/CLAUDE.md never carries \`cc-mirror update\` as a command" test_claude_md_has_no_backticked_cc_mirror_update

# ── upstream-dependencies.md ─────────────────────────────────────────────────
test_upstream_deps_procedure_names_wrapper() {
    local line; line=$(slot "$UPSTREAM_MD" '**CC update procedure:**')
    [[ -n "$line" ]] || { echo "    no '**CC update procedure:**' slot in upstream-dependencies.md" >&2; return 1; }
    assert_contains "$line" "cc-update.sh" "procedure must name the wrapper" || return 1
    assert_not_contains "$line" "cc-mirror update" "procedure must not name the raw verb"
}
run_test "upstream-dependencies.md 'CC update procedure' names cc-update.sh" test_upstream_deps_procedure_names_wrapper

test_upstream_deps_update_method_row_names_wrapper() {
    local line; line=$(slot "$UPSTREAM_MD" '| **Update method** |')
    [[ -n "$line" ]] || { echo "    no '**Update method**' row in upstream-dependencies.md" >&2; return 1; }
    assert_contains "$line" "cc-update.sh" "the Update method row must name the wrapper (not a bare npm install)"
}
run_test "upstream-dependencies.md 'Update method' row names cc-update.sh" test_upstream_deps_update_method_row_names_wrapper

# ── fleet-capabilities.md ────────────────────────────────────────────────────
test_fleet_capabilities_switch_slot_names_wrapper() {
    local line; line=$(slot "$CAPS_MD" 'To switch:')
    [[ -n "$line" ]] || { echo "    no 'To switch:' slot in fleet-capabilities.md" >&2; return 1; }
    assert_contains "$line" "cc-update.sh" "'To switch' must name the wrapper" || return 1
    assert_not_contains "$line" "cc-mirror update" "'To switch' must not name the raw verb"
}
run_test "fleet-capabilities.md 'To switch:' names cc-update.sh" test_fleet_capabilities_switch_slot_names_wrapper

test_fleet_capabilities_update_path_slot_names_wrapper() {
    local line; line=$(slot "$CAPS_MD" '**Update path:**')
    [[ -n "$line" ]] || { echo "    no '**Update path:**' slot in fleet-capabilities.md" >&2; return 1; }
    assert_contains "$line" "cc-update.sh" "'Update path' must name the wrapper" || return 1
    assert_not_contains "$line" "cc-mirror update" "'Update path' must not name the raw verb"
}
run_test "fleet-capabilities.md '**Update path:**' names cc-update.sh" test_fleet_capabilities_update_path_slot_names_wrapper

# ── update-checker.sh: the remedy it PRINTS must be the wrapper (both layouts) ──
# Behavioural: run the real checker against a sandbox with an update available.
checker_remedy() {  # checker_remedy <layout>
    local layout="$1"
    local mirror="$HOME/.cc-mirror/mclaude" launcher="$HOME/.local/bin/mclaude"
    local mockbin="$TEST_TMPDIR/mockbin"
    make_cc_mirror_fixture "$mirror" "$launcher" 2.1.207 '^2.1.207' false "$layout"
    mock_npm "$mockbin" "$TEST_TMPDIR/npm-called" 2.1.280
    rm -f "$HOME/.cc-mirror/.last-update-check"
    OUT=$(PATH="$mockbin:$PATH" CC_MIRROR_DIR="$mirror" bash "$UPDATE_CHECKER" 2>&1 || true)
    echo "    measured remedy ($layout): [$(printf '%s\n' "$OUT" | grep -i -m1 'update' | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-140)]"
}

test_update_checker_native_remedy_is_wrapper() {
    checker_remedy native
    assert_contains "$OUT" "update available" "sanity: an update must be detected" || return 1
    assert_contains "$OUT" "cc-update.sh" "native-layout remedy must name the wrapper" || return 1
    assert_not_contains "$OUT" "cc-mirror update" "native-layout remedy must not print the raw verb"
}
run_test "update-checker.sh (native layout) recommends cc-update.sh, not cc-mirror update" test_update_checker_native_remedy_is_wrapper

test_update_checker_npm_remedy_is_wrapper() {
    checker_remedy npm
    assert_contains "$OUT" "update available" "sanity: an update must be detected" || return 1
    assert_contains "$OUT" "cc-update.sh" "npm-layout remedy must name the wrapper (a bare 'npm update' leaves variant.json and the launcher stale)"
}
run_test "update-checker.sh (npm layout) recommends cc-update.sh, not a bare npm update" test_update_checker_npm_remedy_is_wrapper

suite_summary
