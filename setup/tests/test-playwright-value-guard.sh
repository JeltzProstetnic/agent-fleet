#!/usr/bin/env bash
# Tests for global/hooks/playwright-value-guard.sh — CFG-791.
# Incident 2026-10-21: a Playwright diagnostic read .value over every <input> on a
# page and returned a freshly generated password into the transcript. The guard refuses
# code that reads .value over a COLLECTION of inputs unless it excludes type=password.
source "$(dirname "$0")/test-helpers.sh"

HOOK="$REPO_ROOT/global/hooks/playwright-value-guard.sh"
SETTINGS="$REPO_ROOT/setup/config/settings.json"

suite_header "playwright-value-guard.sh (input .value leak guard)"

# call <tool> <field> <js> — sets RC, ERR
call() {
    local json
    json=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1],"tool_input":{sys.argv[2]:sys.argv[3]}}))' "$1" "$2" "$3")
    RC=0
    ERR=$(printf '%s' "$json" | bash "$HOOK" 2>&1 >/dev/null) || RC=$?
}
EVAL=mcp__playwright__browser_evaluate
RUN=mcp__playwright__browser_run_code_unsafe

test_blocks_incident_shape() {
    # The S348 shape: every input's value, mapped.
    call "$RUN" code "async (page) => page.evaluate(() => [...document.querySelectorAll('input')].map(i => i.name + '=' + i.value))"
    assert_eq "2" "$RC" "querySelectorAll('input') + .value is refused"
    assert_contains "$ERR" "password" "says why (password exposure)"
}
run_test "blocks .value over querySelectorAll('input') (S348 shape)" test_blocks_incident_shape

test_blocks_evaluate_function_field() {
    call "$EVAL" function "() => Array.from(document.querySelectorAll('form input')).map(e => e.value)"
    assert_eq "2" "$RC" "browser_evaluate's function field is checked too"
}
run_test "blocks on browser_evaluate (function field)" test_blocks_evaluate_function_field

test_blocks_other_collections() {
    call "$EVAL" function "() => { const r=[]; for (const e of document.getElementsByTagName('input')) r.push(e.value); return r }"
    assert_eq "2" "$RC" "getElementsByTagName('input') counts as a collection" || return 1
    call "$EVAL" function "() => [...document.forms[0].elements].map(e => e.value)"
    assert_eq "2" "$RC" "form.elements counts as a collection"
}
run_test "blocks getElementsByTagName and form.elements" test_blocks_other_collections

test_allows_not_password_selector() {
    call "$EVAL" function "() => [...document.querySelectorAll('input:not([type=password])')].map(i => i.value)"
    assert_eq "0" "$RC" ":not([type=password]) excludes passwords" || return 1
    call "$EVAL" function "() => [...document.querySelectorAll('input:not([type=\"password\"])')].map(i => i.value)"
    assert_eq "0" "$RC" "quoted form too"
}
run_test "allows a :not([type=password]) selector" test_allows_not_password_selector

test_allows_type_filter() {
    call "$EVAL" function "() => [...document.querySelectorAll('input')].filter(i => i.type !== 'password').map(i => i.value)"
    assert_eq "0" "$RC" "a type !== 'password' filter excludes passwords"
}
run_test "allows a type !== 'password' filter" test_allows_type_filter

test_allows_single_input_and_no_value() {
    call "$EVAL" function "() => document.querySelector('#email').value"
    assert_eq "0" "$RC" "one named input is not a collection" || return 1
    call "$EVAL" function "() => document.querySelectorAll('input').length"
    assert_eq "0" "$RC" "counting inputs reads no value"
}
run_test "allows a single input's value and value-free collection reads" test_allows_single_input_and_no_value

test_other_tools_ignored() {
    call mcp__playwright__browser_click element "input value"
    assert_eq "0" "$RC" "other Playwright tools pass"
}
run_test "other tools pass" test_other_tools_ignored

test_settings_registration() {
    local m
    m=$(python3 -c "
import json
s = json.load(open('$SETTINGS'))
for g in s['hooks']['PreToolUse']:
    for h in g['hooks']:
        if 'playwright-value-guard.sh' in h['command'] and 'safe-run.sh' in h['command']:
            print(g['matcher'])")
    [[ -n "$m" && "$EVAL" =~ ^($m)$ && "$RUN" =~ ^($m)$ ]] && ok=0 || ok=1
    assert_eq "0" "$ok" "registered via safe-run.sh with a matcher covering both tools (matcher: '$m')"
}
run_test "settings: registered via safe-run for evaluate + run_code_unsafe" test_settings_registration

suite_summary
