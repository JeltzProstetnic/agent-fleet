#!/usr/bin/env bash
# Tests for setup/scripts/settings-view.sh (CFG-892): print the live settings.json with every
# env value masked unless the fleet template declares that key (template keys are non-secret
# by the json-merge invariant). The only sanctioned way to read the live settings.
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/settings-view.sh"

suite_header "settings-view.sh (masked live settings reader, CFG-892)"

_fixture() {
    LIVE="$TEST_TMPDIR/live/settings.json"; TMPL="$TEST_TMPDIR/tmpl/settings.json"
    mkdir -p "$(dirname "$LIVE")" "$(dirname "$TMPL")"
    SECRET="fixture-$(date +%s)-$$-not-a-real-credential"
    printf '{"env":{"FLEET_KEY":"visible-value","AFD_TOKEN":"%s"},"hooks":{"Stop":[{"x":1}]},"model":"opus"}\n' "$SECRET" > "$LIVE"
    printf '{"env":{"FLEET_KEY":"template-value"},"hooks":{}}\n' > "$TMPL"
}

test_masks_non_template_env() {
    _fixture
    local out rc=0
    out=$(bash "$SCRIPT" --file "$LIVE" --template "$TMPL" 2>&1) || rc=$?
    local tok; tok=$(printf '%s' "$out" | jq -r '.env.AFD_TOKEN' 2>/dev/null)
    echo "    measured: rc=$rc AFD_TOKEN=[$tok] secret-in-output=[$(printf '%s' "$out" | grep -cF "$SECRET")]"
    assert_eq "0" "$rc" "must succeed" || return 1
    assert_not_contains "$out" "$SECRET" "a non-template env value must never appear" || return 1
    assert_contains "$tok" "masked" "the key stays visible, its value is masked"
}
run_test "masks env values the template does not declare" test_masks_non_template_env

test_shows_template_env_and_rest() {
    _fixture
    local out; out=$(bash "$SCRIPT" --file "$LIVE" --template "$TMPL")
    assert_eq "visible-value" "$(printf '%s' "$out" | jq -r '.env.FLEET_KEY')" "a template key shows the LIVE value" || return 1
    assert_eq "opus" "$(printf '%s' "$out" | jq -r '.model')" "non-env settings are unchanged" || return 1
    assert_eq "1" "$(printf '%s' "$out" | jq -r '.hooks.Stop[0].x')" "hooks are unchanged"
}
run_test "shows template-declared env values and everything outside env" test_shows_template_env_and_rest

test_unreadable_template_masks_all() {
    _fixture
    local out rc=0
    out=$(bash "$SCRIPT" --file "$LIVE" --template "$TEST_TMPDIR/nope.json" 2>&1) || rc=$?
    echo "    measured: rc=$rc FLEET_KEY=[$(printf '%s' "$out" | sed -n '/^{/,$p' | jq -r '.env.FLEET_KEY' 2>/dev/null)]"
    assert_not_contains "$out" "visible-value" "without a readable template every env value is masked (fail closed)" || return 1
    assert_not_contains "$out" "$SECRET" "and the secret stays hidden"
}
run_test "an unreadable template masks every env value (fail closed)" test_unreadable_template_masks_all

test_missing_live_file_fails() {
    local out rc=0
    out=$(bash "$SCRIPT" --file "$TEST_TMPDIR/absent.json" --template "$TEST_TMPDIR/absent2.json" 2>&1) || rc=$?
    assert_neq "0" "$rc" "a missing settings file is an error" || return 1
    assert_contains "$out" "not found" "and says so"
}
run_test "a missing live settings file is an error" test_missing_live_file_fails

test_default_live_path_is_config_dir() {
    _fixture
    local out; out=$(CLAUDE_CONFIG_DIR="$TEST_TMPDIR/live" bash "$SCRIPT" --template "$TMPL")
    assert_eq "visible-value" "$(printf '%s' "$out" | jq -r '.env.FLEET_KEY')" "default file is \$CLAUDE_CONFIG_DIR/settings.json" || return 1
    assert_not_contains "$out" "$SECRET" "and it is masked"
}
run_test "defaults to \$CLAUDE_CONFIG_DIR/settings.json" test_default_live_path_is_config_dir

test_real_template_is_default() {
    _fixture
    # FLEET_KEY is not in the real repo template, so with the default template it is masked.
    local out; out=$(bash "$SCRIPT" --file "$LIVE")
    assert_not_contains "$out" "visible-value" "the default template is the repo's setup/config/settings.json" || return 1
    assert_not_contains "$out" "$SECRET" "secret masked"
}
run_test "defaults to the repo's settings template" test_real_template_is_default

suite_summary
