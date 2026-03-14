#!/usr/bin/env bash
# Tests for --reconfigure-mcp flag in lib.sh and configure-claude.sh
source "$(dirname "$0")/test-helpers.sh"

LIB_SH="$REPO_ROOT/setup/lib.sh"
CONFIGURE_SH="$REPO_ROOT/setup/configure-claude.sh"

suite_header "--reconfigure-mcp flag (AFT-33)"

# ── 1. parse_common_args recognizes --reconfigure-mcp ────────────────────────

test_parse_recognizes_flag() {
    (
        # Source lib.sh in a subshell to avoid polluting globals
        source "$LIB_SH"
        RECONFIGURE_MCP="${RECONFIGURE_MCP:-false}"
        parse_common_args --reconfigure-mcp
        assert_eq "true" "$RECONFIGURE_MCP" "RECONFIGURE_MCP should be true after parsing"
    )
}
run_test "parse_common_args recognizes --reconfigure-mcp" test_parse_recognizes_flag

# ── 2. parse_common_args does NOT set it without the flag ────────────────────

test_parse_default_false() {
    (
        source "$LIB_SH"
        parse_common_args --dry-run
        assert_eq "false" "${RECONFIGURE_MCP:-false}" "RECONFIGURE_MCP should be false by default"
    )
}
run_test "RECONFIGURE_MCP defaults to false" test_parse_default_false

# ── 3. --reconfigure-mcp does not trigger unknown argument warning ───────────

test_no_unknown_warning() {
    local output
    output=$(
        source "$LIB_SH"
        parse_common_args --reconfigure-mcp 2>&1
    )
    assert_not_contains "$output" "Unknown argument" \
        "--reconfigure-mcp should not produce unknown argument warning"
}
run_test "--reconfigure-mcp does not trigger unknown argument warning" test_no_unknown_warning

# ── 4. --reconfigure-mcp works alongside other flags ─────────────────────────

test_combined_flags() {
    (
        source "$LIB_SH"
        parse_common_args --dry-run --reconfigure-mcp --verbose
        assert_eq "true" "$RECONFIGURE_MCP" "RECONFIGURE_MCP should be true"
        assert_eq "true" "$DRY_RUN" "DRY_RUN should be true"
        assert_eq "true" "$VERBOSE" "VERBOSE should be true"
    )
}
run_test "--reconfigure-mcp works alongside other flags" test_combined_flags

# ── 5. configure-claude.sh accepts --reconfigure-mcp without error ───────────

test_configure_accepts_flag() {
    # The script will fail on prerequisites (no cc-mirror installed in test env)
    # but it should NOT fail during argument parsing
    local output rc=0
    output=$(bash "$CONFIGURE_SH" --reconfigure-mcp --dry-run 2>&1) || rc=$?
    # It will fail on prerequisite checks, but NOT on argument parsing
    assert_not_contains "$output" "Unknown argument" \
        "configure-claude.sh should accept --reconfigure-mcp"
}
run_test "configure-claude.sh accepts --reconfigure-mcp without unknown warning" test_configure_accepts_flag

# ── 6. configure_mcp_servers has RECONFIGURE_MCP bypass logic ────────────────

test_mcp_bypass_exists_in_source() {
    # Verify the configure_mcp_servers function checks RECONFIGURE_MCP
    assert_file_contains "$CONFIGURE_SH" "RECONFIGURE_MCP" \
        "configure-claude.sh should reference RECONFIGURE_MCP"
}
run_test "configure_mcp_servers references RECONFIGURE_MCP" test_mcp_bypass_exists_in_source

# ── 7. RECONFIGURE_MCP is exported so child processes can see it ─────────────

test_reconfigure_exported() {
    local val
    val=$(
        source "$LIB_SH"
        parse_common_args --reconfigure-mcp
        bash -c 'echo "${RECONFIGURE_MCP:-unset}"'
    )
    assert_eq "true" "$val" "RECONFIGURE_MCP should be exported to child processes"
}
run_test "RECONFIGURE_MCP is exported to child processes" test_reconfigure_exported

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
