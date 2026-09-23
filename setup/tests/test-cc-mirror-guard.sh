#!/usr/bin/env bash
# Tests for global/hooks/cc-mirror-guard.sh — PreToolUse hook that refuses the
# cc-mirror verbs which RE-PROVISION a variant, and points at cc-update.sh instead.
#
# Why this hook exists (2026-09-23): `cc-mirror update mclaude --claude-version latest
# --no-tweak` — the command global/CLAUDE.md documented — resolved bare `cc-mirror` to a
# Windows-installed cc-mirror 1.6.2 whose bundle has ZERO occurrences of `claude-version`.
# The flag was silently ignored, the variant was re-provisioned from its Feb-9 `claudeOrig`
# pin, Claude Code went 2.1.274 -> 2.1.1, the launcher was rewritten to an entry point that
# no longer exists, and it exited 0. Fixing the runbook is advisory; this hook is the fence.
#
# NOTE: one assert per test function — this harness lets only the FINAL assert decide.
source "$(dirname "$0")/test-helpers.sh"

HOOK="$REPO_ROOT/global/hooks/cc-mirror-guard.sh"

suite_header "cc-mirror-guard.sh (PreToolUse re-provision guard)"

# Feed a Bash tool payload to the hook, echo its exit code.
_rc() {
    local input rc=0
    input=$(jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}')
    HOOK_STDERR=$(printf '%s' "$input" | bash "$HOOK" 2>&1) || rc=$?
    printf '%s' "$rc"
}

# ── MUST BLOCK: verbs that re-provision ────────────────────────────────────────
t_blocks_the_exact_command() {
    assert_eq "2" "$(_rc 'cc-mirror update mclaude --claude-version latest --no-tweak')" \
        "the exact command that broke the install must be refused"
}
run_test "blocks the exact command that broke the install" t_blocks_the_exact_command

t_blocks_bare_update() {
    assert_eq "2" "$(_rc 'cc-mirror update mclaude')" "bare update must be refused"
}
run_test "blocks bare cc-mirror update" t_blocks_bare_update

t_blocks_npx() {
    assert_eq "2" "$(_rc 'npx cc-mirror update mclaude --claude-version latest')" \
        "npx form must be refused"
}
run_test "blocks it via npx" t_blocks_npx

t_blocks_npx_pinned() {
    assert_eq "2" "$(_rc 'npx -y cc-mirror@2.1.0 update mclaude')" "npx -y pinned form must be refused"
}
run_test "blocks npx -y pinned form" t_blocks_npx_pinned

t_blocks_create() {
    assert_eq "2" "$(_rc 'cc-mirror create mclaude --provider mirror')" "create re-provisions"
}
run_test "blocks create" t_blocks_create

t_blocks_quick() {
    assert_eq "2" "$(_rc 'cc-mirror quick --provider mirror')" "quick re-provisions"
}
run_test "blocks quick" t_blocks_quick

t_blocks_remove() {
    assert_eq "2" "$(_rc 'cc-mirror remove mclaude')" "remove destroys a variant"
}
run_test "blocks remove" t_blocks_remove

t_blocks_through_tmux_launch() {
    assert_eq "2" "$(_rc 'bash setup/scripts/tmux-launch.sh cc-update "x" --log /tmp/l "cc-mirror update mclaude --claude-version latest --no-tweak"')" \
        "must still refuse when wrapped in tmux-launch.sh, which is how it actually ran"
}
run_test "blocks when wrapped in tmux-launch.sh, as it actually ran" t_blocks_through_tmux_launch

t_message_names_the_route() {
    _rc 'cc-mirror update mclaude' >/dev/null
    assert_contains "$HOOK_STDERR" "cc-update.sh" "the refusal must name the sanctioned route"
}
run_test "refusal names cc-update.sh" t_message_names_the_route

# ── MUST NOT BLOCK: read-only verbs ────────────────────────────────────────────
t_allows_list()   { assert_eq "0" "$(_rc 'cc-mirror list')"        "list is read-only"; }
run_test "allows list" t_allows_list

t_allows_doctor() { assert_eq "0" "$(_rc 'cc-mirror doctor')"      "doctor is read-only"; }
run_test "allows doctor" t_allows_doctor

t_allows_help()   { assert_eq "0" "$(_rc 'cc-mirror update --help')" "--help mutates nothing"; }
run_test "allows --help" t_allows_help

t_allows_tasks()  { assert_eq "0" "$(_rc 'cc-mirror tasks list')"  "tasks is read-only"; }
run_test "allows tasks" t_allows_tasks

# ── MUST NOT BLOCK: the mirror DIRECTORY ───────────────────────────────────────
# Dominant false-positive risk: the install lives at ~/.cc-mirror/, so matching the PATH
# instead of the COMMAND would block routine work fleet-wide on every Bash call.
t_allows_reading_mirror_file() {
    assert_eq "0" "$(_rc 'cat ~/.cc-mirror/mclaude/variant.json')" \
        "reading a file under the mirror dir must not be confused with the cc-mirror command"
}
run_test "allows reading a file under ~/.cc-mirror" t_allows_reading_mirror_file

t_allows_the_repair_path() {
    assert_eq "0" "$(_rc "cd $HOME/.cc-mirror/mclaude/npm && npm install @anthropic-ai/claude-code@2.1.280")" \
        "the npm repair path must stay open — it is how a broken install gets fixed"
}
run_test "allows the npm repair path" t_allows_the_repair_path

t_allows_wrapper() {
    assert_eq "0" "$(_rc 'bash ~/cfg-agent-fleet/setup/scripts/cc-update.sh --version 2.1.280')" \
        "the sanctioned wrapper must never be blocked"
}
run_test "allows the sanctioned wrapper" t_allows_wrapper

t_allows_wrapper_via() {
    assert_eq "0" "$(_rc 'bash setup/scripts/cc-update.sh --via cc-mirror --version 2.1.280')" \
        "the wrapper may invoke cc-mirror internally and must still be allowed"
}
run_test "allows the wrapper's --via form" t_allows_wrapper_via

t_allows_grep_mentioning_verb() {
    assert_eq "0" "$(_rc "grep -rn 'cc-mirror update' global/CLAUDE.md")" \
        "searching for the string is not running it"
}
run_test "allows a grep whose text mentions the verb" t_allows_grep_mentioning_verb

t_allows_ls_mirror() {
    assert_eq "0" "$(_rc 'ls -la ~/.cc-mirror/mclaude/')" "ls of the mirror dir is harmless"
}
run_test "allows ls of the mirror dir" t_allows_ls_mirror

# ── non-Bash tools are none of this hook's business ────────────────────────────
t_ignores_non_bash() {
    local rc=0
    printf '%s' "$(jq -n '{tool_name:"Write",tool_input:{file_path:"/tmp/x",content:"cc-mirror update mclaude"}}')" \
        | bash "$HOOK" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "non-Bash tools pass through"
}
run_test "ignores non-Bash tools" t_ignores_non_bash

suite_summary
