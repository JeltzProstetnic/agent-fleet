#!/usr/bin/env bash
# CFG-201 — auto-memory is OFF fleet-wide, delivered by the settings template.
# Owner decision (CFG-201): nothing may rely on auto-memory — knowledge lives in fleet files.
# These tests check the DEPLOYED artifact: the live settings.json that
# sync.sh deploy produces by running json-merge.py over the REAL repo template.
source "$(dirname "$0")/test-helpers.sh"

suite_header "Auto-memory off (CFG-201)"

TEMPLATE="$REPO_ROOT/setup/config/settings.json"
MERGE="$REPO_ROOT/setup/scripts/json-merge.py"

# merged_value <live-json> → prints env.CLAUDE_CODE_DISABLE_AUTO_MEMORY of the merged result
merged_value() {
    local live="$TEST_TMPDIR/live.json"
    printf '%s\n' "$1" > "$live"
    HOME="$TEST_TMPDIR" python3 "$MERGE" "$TEMPLATE" "$live" "$TEST_TMPDIR/no-override.json" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("env",{}).get("CLAUDE_CODE_DISABLE_AUTO_MEMORY","<absent>"))'
}

test_deploy_adds_key_to_live_without_it() {
    local v; v=$(merged_value '{"env":{"AFD_TOKEN":"x"}}')
    echo "    measured: merged CLAUDE_CODE_DISABLE_AUTO_MEMORY=[$v]"
    assert_eq "1" "$v" "a live settings.json without the key must get =1 from the template"
}
run_test "deploy: live settings without the key gets CLAUDE_CODE_DISABLE_AUTO_MEMORY=1" test_deploy_adds_key_to_live_without_it

test_deploy_overrides_live_zero() {
    local v; v=$(merged_value '{"env":{"CLAUDE_CODE_DISABLE_AUTO_MEMORY":"0"}}')
    echo "    measured: merged CLAUDE_CODE_DISABLE_AUTO_MEMORY=[$v]"
    assert_eq "1" "$v" "a live =0 must be overridden by the template's =1"
}
run_test "deploy: a live =0 is overridden to 1" test_deploy_overrides_live_zero

test_deploy_keeps_live_secrets() {
    local live="$TEST_TMPDIR/live.json" kept
    printf '%s\n' '{"env":{"AFD_TOKEN":"keep-me"}}' > "$live"
    kept=$(HOME="$TEST_TMPDIR" python3 "$MERGE" "$TEMPLATE" "$live" "$TEST_TMPDIR/no-override.json" \
        | python3 -c 'import json,sys; print("AFD_TOKEN" in json.load(sys.stdin)["env"])')
    echo "    measured: live-only secret key survived=[$kept]"
    assert_eq "True" "$kept" "adding the key must not drop live-only env keys"
}
run_test "deploy: live-only env keys survive the merge" test_deploy_keeps_live_secrets

suite_summary
