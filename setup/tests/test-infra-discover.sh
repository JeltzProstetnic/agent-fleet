#!/usr/bin/env bash
# Tests for setup/scripts/infra-discover.sh
# Verifies output format, section structure, helper functions, and platform detection.
# Network-dependent sections are tested for format only (not actual network state).

source "$(dirname "$0")/test-helpers.sh"

suite_header "Infrastructure Discovery"

SCRIPT="$REPO_ROOT/setup/scripts/infra-discover.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Run the script and capture output (some sections may timeout on network)
run_infra_discover() {
    timeout 30 bash "$SCRIPT" 2>/dev/null || true
}

# ── Tests: Report Header ───────────────────────────────────────────────────

test_report_header_present() {
    local output
    output=$(run_infra_discover)
    assert_contains "$output" "# Infrastructure Map"
}
run_test "report starts with Infrastructure Map header" test_report_header_present

test_report_has_generated_date() {
    local output
    output=$(run_infra_discover)
    assert_contains "$output" "Generated:"
}
run_test "report includes Generated timestamp" test_report_has_generated_date

test_report_has_machine_name() {
    local output
    output=$(run_infra_discover)
    assert_contains "$output" "Machine:"
}
run_test "report includes Machine name" test_report_has_machine_name

test_report_has_platform() {
    local output
    output=$(run_infra_discover)
    assert_contains "$output" "Platform:"
}
run_test "report includes Platform" test_report_has_platform

# ── Tests: Section Headers ─────────────────────────────────────────────────

test_has_network_interfaces_section() {
    local output
    output=$(run_infra_discover)
    assert_contains "$output" "## Network Interfaces"
}
run_test "report has Network Interfaces section" test_has_network_interfaces_section

test_has_gateway_dns_section() {
    local output
    output=$(run_infra_discover)
    assert_contains "$output" "## Gateway & DNS"
}
run_test "report has Gateway & DNS section" test_has_gateway_dns_section

test_has_public_ip_section() {
    local output
    output=$(run_infra_discover)
    assert_contains "$output" "## Public IP & NAT Detection"
}
run_test "report has Public IP & NAT Detection section" test_has_public_ip_section

test_has_ssh_config_section() {
    local output
    output=$(run_infra_discover)
    assert_contains "$output" "## SSH Config Hosts"
}
run_test "report has SSH Config Hosts section" test_has_ssh_config_section

test_has_docker_section() {
    local output
    output=$(run_infra_discover)
    assert_contains "$output" "## Docker Containers"
}
run_test "report has Docker Containers section" test_has_docker_section

test_has_cloud_clis_section() {
    local output
    output=$(run_infra_discover)
    assert_contains "$output" "## Cloud CLIs"
}
run_test "report has Cloud CLIs section" test_has_cloud_clis_section

test_has_tunnels_section() {
    local output
    output=$(run_infra_discover)
    assert_contains "$output" "## Tunnels & VPNs"
}
run_test "report has Tunnels & VPNs section" test_has_tunnels_section

test_has_listening_ports_section() {
    local output
    output=$(run_infra_discover)
    assert_contains "$output" "## Listening Ports"
}
run_test "report has Listening Ports section" test_has_listening_ports_section

# ── Tests: Footer ──────────────────────────────────────────────────────────

test_report_has_footer() {
    local output
    output=$(run_infra_discover)
    assert_contains "$output" "Report complete"
}
run_test "report ends with footer" test_report_has_footer

# ── Tests: Platform Detection ──────────────────────────────────────────────

test_platform_is_valid() {
    local output
    output=$(run_infra_discover)
    # Platform should be one of: wsl, macos, linux
    local platform
    platform=$(echo "$output" | grep '^Platform:' | awk '{print $2}')
    [[ "$platform" == "wsl" || "$platform" == "macos" || "$platform" == "linux" ]]
}
run_test "platform detection returns valid value" test_platform_is_valid

# ── Tests: Output Contains Code Blocks or Not-Detected ─────────────────────

test_network_interfaces_has_content() {
    local output
    output=$(run_infra_discover)
    # Should have either a code block or not_detected placeholder
    local section
    section=$(echo "$output" | sed -n '/## Network Interfaces/,/^## /p' | head -10)
    # Must have some content: either ``` or _(not detected)_
    [[ "$section" == *'```'* ]] || [[ "$section" == *"not detected"* ]]
}
run_test "network interfaces section has content or not-detected" test_network_interfaces_has_content

test_listening_ports_has_content() {
    local output
    output=$(run_infra_discover)
    local section
    section=$(echo "$output" | sed -n '/## Listening Ports/,/^---/p')
    [[ "$section" == *'```'* ]] || [[ "$section" == *"not detected"* ]]
}
run_test "listening ports section has content or not-detected" test_listening_ports_has_content

suite_summary
