#!/usr/bin/env bash
# Tests for render-template.sh — template variable rendering (CFG-292)
source "$(dirname "$0")/test-helpers.sh"

RENDER_SCRIPT="$REPO_ROOT/setup/scripts/render-template.sh"

suite_header "render-template.sh"

# ── Basic substitution ───────────────────────────────────────────────────────

test_substitutes_home() {
    local input="$TEST_TMPDIR/input.txt"
    echo 'path: __HOME__/.claude' > "$input"

    local out
    out=$(HOME="/mock/home" bash "$RENDER_SCRIPT" "$input")
    assert_contains "$out" "/mock/home/.claude" "should substitute __HOME__"
    assert_not_contains "$out" "__HOME__" "should not leave __HOME__ placeholder"
}
run_test "substitutes __HOME__" test_substitutes_home

test_substitutes_multiple_vars() {
    local input="$TEST_TMPDIR/input.txt"
    echo '__HOME__/cfg on __PLATFORM__ host __HOSTNAME__' > "$input"

    local out
    out=$(HOME="/mock" PLATFORM="wsl" HOSTNAME="test-host" bash "$RENDER_SCRIPT" "$input")
    assert_contains "$out" "/mock/cfg" "should substitute HOME"
    assert_contains "$out" "wsl" "should substitute PLATFORM"
    assert_contains "$out" "test-host" "should substitute HOSTNAME"
}
run_test "substitutes multiple variables" test_substitutes_multiple_vars

test_substitutes_config_repo() {
    local input="$TEST_TMPDIR/input.txt"
    echo 'repo: __CONFIG_REPO__' > "$input"

    local out
    out=$(CONFIG_REPO="/path/to/cfg" bash "$RENDER_SCRIPT" "$input")
    assert_contains "$out" "/path/to/cfg" "should substitute CONFIG_REPO"
}
run_test "substitutes __CONFIG_REPO__" test_substitutes_config_repo

test_preserves_non_template_lines() {
    local input="$TEST_TMPDIR/input.txt"
    cat > "$input" << 'EOF'
regular line
another line with no vars
__HOME__/real
EOF
    local out
    out=$(HOME="/h" bash "$RENDER_SCRIPT" "$input")
    assert_contains "$out" "regular line" "should preserve non-template lines"
    assert_contains "$out" "another line" "should preserve other lines"
}
run_test "preserves non-template lines" test_preserves_non_template_lines

test_multiple_substitutions_per_line() {
    local input="$TEST_TMPDIR/input.txt"
    echo '__HOME__/a:__HOME__/b' > "$input"

    local out
    out=$(HOME="/x" bash "$RENDER_SCRIPT" "$input")
    assert_contains "$out" "/x/a:/x/b" "should substitute all occurrences on one line"
}
run_test "multiple substitutions per line" test_multiple_substitutions_per_line

# ── Platform conditionals ────────────────────────────────────────────────────

test_includes_matching_platform() {
    local input="$TEST_TMPDIR/input.txt"
    cat > "$input" << 'EOF'
always
#__IF_PLATFORM_WSL__
wsl-only line
#__ENDIF__
also always
EOF
    local out
    out=$(PLATFORM="wsl" bash "$RENDER_SCRIPT" "$input")
    assert_contains "$out" "always" "should include unconditional"
    assert_contains "$out" "wsl-only line" "should include matching platform block"
    assert_contains "$out" "also always" "should include after block"
    assert_not_contains "$out" "#__IF_" "should strip conditional markers"
    assert_not_contains "$out" "#__ENDIF__" "should strip endif markers"
}
run_test "includes matching platform conditional" test_includes_matching_platform

test_excludes_non_matching_platform() {
    local input="$TEST_TMPDIR/input.txt"
    cat > "$input" << 'EOF'
always
#__IF_PLATFORM_MACOS__
macos-only line
#__ENDIF__
also always
EOF
    local out
    out=$(PLATFORM="wsl" bash "$RENDER_SCRIPT" "$input")
    assert_contains "$out" "always" "should include unconditional"
    assert_not_contains "$out" "macos-only line" "should exclude non-matching platform"
    assert_contains "$out" "also always" "should include after block"
}
run_test "excludes non-matching platform conditional" test_excludes_non_matching_platform

test_multiple_conditionals() {
    local input="$TEST_TMPDIR/input.txt"
    cat > "$input" << 'EOF'
base
#__IF_PLATFORM_WSL__
wsl stuff
#__ENDIF__
middle
#__IF_PLATFORM_LINUX__
linux stuff
#__ENDIF__
end
EOF
    local out
    out=$(PLATFORM="wsl" bash "$RENDER_SCRIPT" "$input")
    assert_contains "$out" "wsl stuff" "should include wsl block"
    assert_not_contains "$out" "linux stuff" "should exclude linux block"
}
run_test "handles multiple conditional blocks" test_multiple_conditionals

# ── Machine vars file ────────────────────────────────────────────────────────

test_machine_vars_override() {
    local input="$TEST_TMPDIR/input.txt"
    echo 'dir: __CC_CONFIG_DIR__' > "$input"

    local vars_dir="$TEST_TMPDIR/machines"
    mkdir -p "$vars_dir"
    echo 'CC_CONFIG_DIR=/custom/path' > "$vars_dir/test-host.vars"

    local out
    out=$(HOSTNAME="test-host" bash "$RENDER_SCRIPT" --vars-dir "$vars_dir" "$input")
    assert_contains "$out" "/custom/path" "should use machine vars override"
}
run_test "machine vars file overrides defaults" test_machine_vars_override

# ── Edge cases ───────────────────────────────────────────────────────────────

test_empty_file() {
    local input="$TEST_TMPDIR/empty.txt"
    touch "$input"
    local out
    out=$(bash "$RENDER_SCRIPT" "$input")
    assert_eq "" "$out" "empty input should produce empty output"
}
run_test "handles empty file" test_empty_file

test_missing_var_left_as_is() {
    local input="$TEST_TMPDIR/input.txt"
    echo '__NONEXISTENT_VAR__' > "$input"
    local out
    out=$(bash "$RENDER_SCRIPT" "$input")
    assert_contains "$out" "__NONEXISTENT_VAR__" "unknown vars should pass through"
}
run_test "unknown vars pass through unchanged" test_missing_var_left_as_is

test_no_file_argument_fails() {
    local rc=0
    bash "$RENDER_SCRIPT" 2>/dev/null || rc=$?
    assert_neq "0" "$rc" "should fail without file argument"
}
run_test "fails without file argument" test_no_file_argument_fails

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
