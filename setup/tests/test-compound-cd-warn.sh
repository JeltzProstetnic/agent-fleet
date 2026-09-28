#!/usr/bin/env bash
# Tests for global/hooks/compound-cd-warn.sh
#
# CFG-602: CLAUDE.md says never `cd <dir> && <cmd>`, yet one session broke it 65
# times with no consequence, because nothing fired. The owner chose (2026-09-28)
# to keep the rule and add a WARNING-ONLY hook: the call proceeds, and the model
# is told at the point of action. Warning means exit 0 + additionalContext —
# never exit 2.
source "$(dirname "$0")/test-helpers.sh"

suite_header "compound-cd-warn: warn, never block, on cd-chained commands"

HOOK="$REPO_ROOT/global/hooks/compound-cd-warn.sh"

# Runs the hook on a Bash command; sets RC and OUT.
run_bash_cmd() {
    local cmd="$1" payload
    payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$cmd")
    OUT=$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null); RC=$?
}

warned() { [[ "$OUT" == *additionalContext* ]] && echo yes || echo no; }

test_chained_cd_warns() {
    run_bash_cmd "cd /tmp && ls"
    assert_eq "0" "$RC" "a warning never blocks"
    assert_eq "yes" "$(warned)" "cd && cmd is warned about"
    assert_contains "$OUT" "git -C" "the warning names the alternative"
}
run_test "cd <dir> && cmd: warns, exit 0" test_chained_cd_warns

test_semicolon_and_subshell_warn() {
    run_bash_cmd "(cd /tmp; make)"
    assert_eq "yes" "$(warned)" "a subshell cd chain is the same pattern"
    run_bash_cmd "ls; cd /tmp && pwd"
    assert_eq "yes" "$(warned)" "a cd chain later in the command is the same pattern"
}
run_test "subshell and mid-command cd chains warn" test_semicolon_and_subshell_warn

test_output_is_valid_json() {
    run_bash_cmd "cd \"/tmp/a b\" && ls"
    local ok="no"; printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["hookSpecificOutput"]["hookEventName"]=="PreToolUse"' 2>/dev/null && ok="yes"
    assert_eq "yes" "$ok" "the warning is valid PreToolUse hookSpecificOutput JSON"
}
run_test "warning output is valid JSON" test_output_is_valid_json

test_non_matches_are_silent() {
    local c
    for c in "ls -la" "cd /tmp" "git -C /tmp status" "echo abcd && ls" "bash /x/abcd.sh; ls"; do
        run_bash_cmd "$c"
        assert_eq "0|" "$RC|$OUT" "silent pass for: $c"
    done
}
run_test "non-matching commands: silent, exit 0" test_non_matches_are_silent

test_other_tools_are_silent() {
    OUT=$(printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}' | bash "$HOOK" 2>/dev/null); RC=$?
    assert_eq "0|" "$RC|$OUT" "non-Bash tools pass silently"
}
run_test "non-Bash tools: silent" test_other_tools_are_silent

suite_summary
