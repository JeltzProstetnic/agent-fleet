#!/usr/bin/env bash
# Tests for global/hooks/compound-cd-warn.sh
#
# CFG-602: CLAUDE.md says never `cd <dir> && <cmd>`, yet one session broke it 65
# times with no consequence, because nothing fired. A warning-only hook (2026-09-28)
# changed nothing either: the warning arrives after the command has run (~6 warnings
# in one session). CFG-810 (owner, 2026-10-25): BLOCK with exit 2 and name the
# alternatives, so the call is rewritten before it runs. The filename keeps "warn"
# so no settings.json registration has to change.
source "$(dirname "$0")/test-helpers.sh"

suite_header "compound-cd-warn: block cd-chained commands with exit 2"

HOOK="$REPO_ROOT/global/hooks/compound-cd-warn.sh"

# Runs the hook on a Bash command; sets RC, OUT (stdout) and ERR (stderr).
run_bash_cmd() {
    local cmd="$1" payload errf
    payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$cmd")
    errf=$(mktemp)
    OUT=$(printf '%s' "$payload" | bash "$HOOK" 2>"$errf"); RC=$?
    ERR=$(cat "$errf"); rm -f "$errf"
}

test_chained_cd_blocks() {
    run_bash_cmd "cd /tmp && ls"
    assert_eq "2" "$RC" "cd && cmd is blocked with exit 2"
    assert_contains "$ERR" "git -C" "the block message names git -C"
    assert_contains "$ERR" "env -C" "the block message names env -C for tools that need a cwd"
}
run_test "cd <dir> && cmd: blocked, exit 2" test_chained_cd_blocks

test_semicolon_and_subshell_block() {
    run_bash_cmd "(cd /tmp; make)"
    assert_eq "2" "$RC" "a subshell cd chain is the same pattern"
    run_bash_cmd "ls; cd /tmp && pwd"
    assert_eq "2" "$RC" "a cd chain later in the command is the same pattern"
    run_bash_cmd "cd \"/tmp/a b\" && ls"
    assert_eq "2" "$RC" "a quoted cd target is the same pattern"
}
run_test "subshell, mid-command and quoted cd chains block" test_semicolon_and_subshell_block

test_non_matches_are_silent() {
    local c
    for c in "ls -la" "cd /tmp" "git -C /tmp status" "echo abcd && ls" "bash /x/abcd.sh; ls" "env -C /mnt/c powershell.exe -Command x"; do
        run_bash_cmd "$c"
        assert_eq "0||" "$RC|$OUT|$ERR" "silent pass for: $c"
    done
}
run_test "non-matching commands: silent, exit 0" test_non_matches_are_silent

test_other_tools_are_silent() {
    OUT=$(printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}' | bash "$HOOK" 2>/dev/null); RC=$?
    assert_eq "0|" "$RC|$OUT" "non-Bash tools pass silently"
}
run_test "non-Bash tools: silent" test_other_tools_are_silent

test_safe_run_passes_the_block_through() {
    local payload rc home
    home=$(mktemp -d); mkdir -p "$home/.claude/hooks"
    cp "$HOOK" "$home/.claude/hooks/compound-cd-warn.sh"
    payload='{"tool_name":"Bash","tool_input":{"command":"cd /tmp && ls"}}'
    rc=0; printf '%s' "$payload" | HOME="$home" bash "$REPO_ROOT/global/hooks/safe-run.sh" compound-cd-warn.sh >/dev/null 2>&1 || rc=$?
    rm -rf "$home"
    assert_eq "2" "$rc" "safe-run.sh passes exit 2 through"
}
run_test "registered path: safe-run passes the block through" test_safe_run_passes_the_block_through

suite_summary
