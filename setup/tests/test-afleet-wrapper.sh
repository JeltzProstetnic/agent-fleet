#!/usr/bin/env bash
# TDD tests for setup/scripts/afleet-wrapper.sh (CFG-256)
# Run: bash setup/tests/test-afleet-wrapper.sh
source "$(dirname "$0")/test-helpers.sh"

WRAPPER_SCRIPT="$REPO_ROOT/setup/scripts/afleet-wrapper.sh"

suite_header "afleet-wrapper.sh (CFG-256: outer safety shell)"

# ── Helpers ──────────────────────────────────────────────────────────────────

setup_wrapper_env() {
    local base="$TEST_TMPDIR"
    local cfg="$base/cfg-agent-fleet"
    local tpl="$base/agent-fleet"

    mkdir -p "$cfg/setup/scripts" "$tpl/setup/scripts"

    # Create valid afleet.sh
    cat > "$cfg/setup/scripts/afleet.sh" << 'EOF'
#!/usr/bin/env bash
echo "AFLEET_LAUNCHED from=$1"
EOF

    # Create valid afleet-lib.sh with required functions
    cat > "$cfg/setup/scripts/afleet-lib.sh" << 'EOF'
#!/usr/bin/env bash
parse_registry() { echo "test|/tmp/test"; }
find_launcher() { echo "/usr/bin/echo"; }
EOF

    echo "$base"
}

# ── Test 1: Wrapper execs real afleet.sh when valid ──────────────────────────

test_wrapper_execs_valid() {
    local base
    base=$(setup_wrapper_env)
    local cfg="$base/cfg-agent-fleet"

    local output
    output=$(AFLEET_WRAPPER_HOME="$base" bash "$WRAPPER_SCRIPT" --test-arg 2>&1)

    assert_contains "$output" "AFLEET_LAUNCHED" "should exec the real afleet.sh"
}
run_test "wrapper execs real afleet.sh when valid" test_wrapper_execs_valid

# ── Test 2: Wrapper falls back on syntax error ───────────────────────────────

test_wrapper_fallback_syntax_error() {
    local base
    base=$(setup_wrapper_env)
    local cfg="$base/cfg-agent-fleet"

    # Break afleet.sh syntax
    echo "if then fi {{{" >> "$cfg/setup/scripts/afleet.sh"

    local output
    output=$(AFLEET_WRAPPER_HOME="$base" AFLEET_WRAPPER_FALLBACK="echo FALLBACK_OK" bash "$WRAPPER_SCRIPT" 2>&1)

    assert_contains "$output" "FALLBACK" "should fall back on syntax error"
    assert_contains "$output" "DEGRADED" "should warn about degraded mode"
}
run_test "wrapper falls back on afleet.sh syntax error" test_wrapper_fallback_syntax_error

# ── Test 3: Wrapper falls back on missing afleet-lib.sh ──────────────────────

test_wrapper_fallback_missing_lib() {
    local base
    base=$(setup_wrapper_env)
    local cfg="$base/cfg-agent-fleet"

    # Remove lib
    rm "$cfg/setup/scripts/afleet-lib.sh"

    local output
    output=$(AFLEET_WRAPPER_HOME="$base" AFLEET_WRAPPER_FALLBACK="echo FALLBACK_OK" bash "$WRAPPER_SCRIPT" 2>&1)

    assert_contains "$output" "FALLBACK" "should fall back when lib missing"
}
run_test "wrapper falls back on missing afleet-lib.sh" test_wrapper_fallback_missing_lib

# ── Test 4: Wrapper falls back on missing afleet.sh ──────────────────────────

test_wrapper_fallback_missing_main() {
    local base
    base=$(setup_wrapper_env)

    # Remove both repo dirs entirely
    rm -rf "$base/cfg-agent-fleet" "$base/agent-fleet"

    local output
    output=$(AFLEET_WRAPPER_HOME="$base" AFLEET_WRAPPER_FALLBACK="echo FALLBACK_OK" bash "$WRAPPER_SCRIPT" 2>&1)

    assert_contains "$output" "FALLBACK" "should fall back when no repo found"
}
run_test "wrapper falls back on missing afleet.sh" test_wrapper_fallback_missing_main

# ── Test 5: Wrapper tries agent-fleet if cfg-agent-fleet missing ─────────────

test_wrapper_tries_template_repo() {
    local base
    base=$(setup_wrapper_env)

    # Remove cfg, keep template
    rm -rf "$base/cfg-agent-fleet"
    mkdir -p "$base/agent-fleet/setup/scripts"
    cat > "$base/agent-fleet/setup/scripts/afleet.sh" << 'EOF'
#!/usr/bin/env bash
echo "TEMPLATE_LAUNCHED"
EOF
    cat > "$base/agent-fleet/setup/scripts/afleet-lib.sh" << 'EOF'
#!/usr/bin/env bash
parse_registry() { :; }
EOF

    local output
    output=$(AFLEET_WRAPPER_HOME="$base" bash "$WRAPPER_SCRIPT" 2>&1)

    assert_contains "$output" "TEMPLATE_LAUNCHED" "should use agent-fleet fallback"
}
run_test "wrapper tries agent-fleet if cfg-agent-fleet missing" test_wrapper_tries_template_repo

# ── Test 6: Wrapper passes all args through ──────────────────────────────────

test_wrapper_passes_args() {
    local base
    base=$(setup_wrapper_env)

    # afleet.sh that echoes all args
    cat > "$base/cfg-agent-fleet/setup/scripts/afleet.sh" << 'EOF'
#!/usr/bin/env bash
echo "ARGS=$*"
EOF

    local output
    output=$(AFLEET_WRAPPER_HOME="$base" bash "$WRAPPER_SCRIPT" social --pick 2>&1)

    assert_contains "$output" "ARGS=social --pick" "should pass all args through"
}
run_test "wrapper passes all args through" test_wrapper_passes_args

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
