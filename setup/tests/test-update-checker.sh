#!/usr/bin/env bash
# Tests for setup/scripts/update-checker.sh — cc-mirror update version checker
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/update-checker.sh"

suite_header "update-checker.sh (cc-mirror update checker)"

# ── Helpers ─────────────────────────────────────────────────────────────────

# Create a mock npm directory with a fake package.json
create_mock_npm_dir() {
    local version="$1"
    local npm_dir="$TEST_TMPDIR/cc-mirror/npm"
    mkdir -p "$npm_dir/node_modules/@anthropic-ai/claude-code"
    cat > "$npm_dir/node_modules/@anthropic-ai/claude-code/package.json" << EOF
{ "name": "@anthropic-ai/claude-code", "version": "$version" }
EOF
    echo "$npm_dir"
}

# Create mock npm command that returns a specific version
create_mock_npm() {
    local version="$1"
    local mock_dir="$TEST_TMPDIR/mockbin"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/npm" << EOF
#!/usr/bin/env bash
if [[ "\$1" == "view" ]]; then
    echo "$version"
else
    exit 1
fi
EOF
    chmod +x "$mock_dir/npm"
    echo "$mock_dir"
}

# Create mock npm command that fails (simulates network error)
create_mock_npm_fail() {
    local mock_dir="$TEST_TMPDIR/mockbin"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/npm" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$mock_dir/npm"
    echo "$mock_dir"
}

# Create mock node command that reads package.json version
create_mock_node() {
    local mock_dir="${1:-$TEST_TMPDIR/mockbin}"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/node" << 'EOF'
#!/usr/bin/env bash
# Parse -e argument and extract version from require() path
for arg in "$@"; do
    if [[ "$arg" == *"require("* ]]; then
        # Extract the path from require('path')
        local pkg_path
        pkg_path=$(echo "$arg" | sed "s/.*require('\\(.*\\)').*/\\1/")
        if [[ -f "$pkg_path" ]]; then
            # Extract version from JSON
            grep -o '"version": *"[^"]*"' "$pkg_path" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/'
        else
            echo "unknown"
        fi
    fi
done
EOF
    chmod +x "$mock_dir/node"
    echo "$mock_dir"
}

# ── Skip if disabled ────────────────────────────────────────────────────────

test_skip_when_disabled() {
    local rc=0
    CC_MIRROR_SKIP_UPDATE=1 bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "should exit 0 when CC_MIRROR_SKIP_UPDATE=1"
}
run_test "exits 0 when CC_MIRROR_SKIP_UPDATE=1" test_skip_when_disabled

# ── Daily gate — skips if already checked today ─────────────────────────────

test_skips_if_checked_recently() {
    local marker_dir="$TEST_TMPDIR/cc-mirror"
    mkdir -p "$marker_dir"
    # Set marker to current time (checked just now)
    date +%s > "$marker_dir/.last-update-check"
    local rc=0
    HOME="$TEST_TMPDIR" CC_MIRROR_FORCE_UPDATE=0 bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "should exit 0 when checked recently"
}
run_test "skips check if already checked within 24h" test_skips_if_checked_recently

test_checks_if_marker_stale() {
    local marker_dir="$TEST_TMPDIR/cc-mirror"
    mkdir -p "$marker_dir"
    # Set marker to 2 days ago
    echo $(( $(date +%s) - 172800 )) > "$marker_dir/.last-update-check"
    # Without valid npm dir, it exits early but doesn't skip (it tries to check)
    local rc=0
    HOME="$TEST_TMPDIR" CC_MIRROR_DIR="$TEST_TMPDIR/cc-mirror" bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "should exit 0 (no installed version found, early exit)"
}
run_test "attempts check when marker is older than 24h" test_checks_if_marker_stale

# ── Force update overrides daily gate ───────────────────────────────────────

test_force_overrides_daily_gate() {
    local marker_dir="$TEST_TMPDIR/cc-mirror"
    mkdir -p "$marker_dir"
    # Set marker to current time
    date +%s > "$marker_dir/.last-update-check"
    # With force=1 but no installed version, it should still try (and exit 0 early)
    local rc=0
    HOME="$TEST_TMPDIR" CC_MIRROR_DIR="$TEST_TMPDIR/cc-mirror" CC_MIRROR_FORCE_UPDATE=1 \
        bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "force update should bypass daily gate"
}
run_test "CC_MIRROR_FORCE_UPDATE=1 overrides daily gate" test_force_overrides_daily_gate

# ── Missing package.json exits cleanly ──────────────────────────────────────

test_missing_package_json_exits_clean() {
    local marker_dir="$TEST_TMPDIR/cc-mirror"
    mkdir -p "$marker_dir"
    # No package.json exists at all
    local rc=0
    HOME="$TEST_TMPDIR" CC_MIRROR_DIR="$TEST_TMPDIR/cc-mirror" CC_MIRROR_FORCE_UPDATE=1 \
        bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "should exit 0 when package.json missing"
}
run_test "missing package.json exits cleanly" test_missing_package_json_exits_clean

# ── Marker file created after check ────────────────────────────────────────

test_marker_file_created() {
    # Marker is at $HOME/.cc-mirror/.last-update-check (hardcoded from HOME)
    local npm_dir
    npm_dir=$(create_mock_npm_dir "1.0.0")
    local mock_npm
    mock_npm=$(create_mock_npm "1.0.0")
    mkdir -p "$TEST_TMPDIR/nodebin"
    cat > "$TEST_TMPDIR/nodebin/node" << 'NODEOF'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == *"require("* ]]; then
        pkg_path=$(echo "$arg" | sed "s/.*require('\\(.*\\)').*/\\1/")
        if [[ -f "$pkg_path" ]]; then
            grep -o '"version": *"[^"]*"' "$pkg_path" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/'
        else
            echo "unknown"
        fi
    fi
done
NODEOF
    chmod +x "$TEST_TMPDIR/nodebin/node"
    # CC_MIRROR_DIR controls where package.json is found; marker uses $HOME/.cc-mirror/
    HOME="$TEST_TMPDIR" CC_MIRROR_DIR="$TEST_TMPDIR/cc-mirror" CC_MIRROR_FORCE_UPDATE=1 \
        PATH="$mock_npm:$TEST_TMPDIR/nodebin:$PATH" bash "$SCRIPT" 2>/dev/null || true
    assert_file_exists "$TEST_TMPDIR/.cc-mirror/.last-update-check" "marker file should be created after check"
}
run_test "marker file created after running check" test_marker_file_created

# ── Output when versions match ──────────────────────────────────────────────

test_output_up_to_date() {
    local npm_dir
    npm_dir=$(create_mock_npm_dir "2.1.78")
    local mock_npm
    mock_npm=$(create_mock_npm "2.1.78")
    # Create a node mock that outputs the correct version
    mkdir -p "$TEST_TMPDIR/nodebin"
    cat > "$TEST_TMPDIR/nodebin/node" << 'NODEOF'
#!/usr/bin/env bash
# Extract version from package.json path in -e argument
for arg in "$@"; do
    if [[ "$arg" == *"require("* ]]; then
        pkg_path=$(echo "$arg" | sed "s/.*require('\\(.*\\)').*/\\1/")
        if [[ -f "$pkg_path" ]]; then
            grep -o '"version": *"[^"]*"' "$pkg_path" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/'
        else
            echo "unknown"
        fi
    fi
done
NODEOF
    chmod +x "$TEST_TMPDIR/nodebin/node"
    local output
    output=$(HOME="$TEST_TMPDIR" CC_MIRROR_DIR="$TEST_TMPDIR/cc-mirror" CC_MIRROR_FORCE_UPDATE=1 \
        PATH="$mock_npm:$TEST_TMPDIR/nodebin:$PATH" bash "$SCRIPT" 2>&1) || true
    assert_contains "$output" "2.1.78" "should show current version"
    assert_contains "$output" "latest" "should indicate it is latest"
}
run_test "shows 'latest' when versions match" test_output_up_to_date

# ── Output when update available ────────────────────────────────────────────

test_output_update_available() {
    local npm_dir
    npm_dir=$(create_mock_npm_dir "2.1.70")
    local mock_npm
    mock_npm=$(create_mock_npm "2.1.78")
    mkdir -p "$TEST_TMPDIR/nodebin"
    cat > "$TEST_TMPDIR/nodebin/node" << 'NODEOF'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == *"require("* ]]; then
        pkg_path=$(echo "$arg" | sed "s/.*require('\\(.*\\)').*/\\1/")
        if [[ -f "$pkg_path" ]]; then
            grep -o '"version": *"[^"]*"' "$pkg_path" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/'
        else
            echo "unknown"
        fi
    fi
done
NODEOF
    chmod +x "$TEST_TMPDIR/nodebin/node"
    local output
    output=$(HOME="$TEST_TMPDIR" CC_MIRROR_DIR="$TEST_TMPDIR/cc-mirror" CC_MIRROR_FORCE_UPDATE=1 \
        PATH="$mock_npm:$TEST_TMPDIR/nodebin:$PATH" bash "$SCRIPT" 2>&1) || true
    assert_contains "$output" "update available" "should indicate update available"
    assert_contains "$output" "2.1.70" "should show installed version"
    assert_contains "$output" "2.1.78" "should show latest version"
}
run_test "shows update available when versions differ" test_output_update_available

# ── Network failure (npm view fails) exits cleanly ──────────────────────────

test_network_failure_silent() {
    local npm_dir
    npm_dir=$(create_mock_npm_dir "2.1.78")
    local mock_npm_fail
    mock_npm_fail=$(create_mock_npm_fail)
    mkdir -p "$TEST_TMPDIR/nodebin"
    cat > "$TEST_TMPDIR/nodebin/node" << 'NODEOF'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == *"require("* ]]; then
        pkg_path=$(echo "$arg" | sed "s/.*require('\\(.*\\)').*/\\1/")
        if [[ -f "$pkg_path" ]]; then
            grep -o '"version": *"[^"]*"' "$pkg_path" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/'
        else
            echo "unknown"
        fi
    fi
done
NODEOF
    chmod +x "$TEST_TMPDIR/nodebin/node"
    local rc=0 output
    output=$(HOME="$TEST_TMPDIR" CC_MIRROR_DIR="$TEST_TMPDIR/cc-mirror" CC_MIRROR_FORCE_UPDATE=1 \
        PATH="$mock_npm_fail:$TEST_TMPDIR/nodebin:$PATH" bash "$SCRIPT" 2>&1) || rc=$?
    assert_eq "0" "$rc" "should exit 0 on network failure"
    # Should NOT show any update message
    assert_not_contains "$output" "update available" "should not show update on network failure"
}
run_test "network failure exits cleanly and silently" test_network_failure_silent

# ── Marker file contains epoch timestamp ────────────────────────────────────

test_marker_content_is_epoch() {
    local npm_dir
    npm_dir=$(create_mock_npm_dir "2.0.0")
    local mock_npm
    mock_npm=$(create_mock_npm "2.0.0")
    mkdir -p "$TEST_TMPDIR/nodebin"
    cat > "$TEST_TMPDIR/nodebin/node" << 'NODEOF'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == *"require("* ]]; then
        pkg_path=$(echo "$arg" | sed "s/.*require('\\(.*\\)').*/\\1/")
        if [[ -f "$pkg_path" ]]; then
            grep -o '"version": *"[^"]*"' "$pkg_path" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/'
        else
            echo "unknown"
        fi
    fi
done
NODEOF
    chmod +x "$TEST_TMPDIR/nodebin/node"
    HOME="$TEST_TMPDIR" CC_MIRROR_DIR="$TEST_TMPDIR/cc-mirror" CC_MIRROR_FORCE_UPDATE=1 \
        PATH="$mock_npm:$TEST_TMPDIR/nodebin:$PATH" bash "$SCRIPT" 2>/dev/null || true
    # Marker is at $HOME/.cc-mirror/.last-update-check
    local marker="$TEST_TMPDIR/.cc-mirror/.last-update-check"
    assert_file_exists "$marker" "marker file should exist"
    local content
    content=$(cat "$marker" 2>/dev/null)
    if [[ ! "$content" =~ ^[0-9]+$ ]]; then
        echo "marker content '$content' is not an epoch timestamp" >&2
        return 1
    fi
}
run_test "marker file contains epoch timestamp" test_marker_content_is_epoch

# ── Update message includes update command ──────────────────────────────────

test_update_message_has_instructions() {
    local npm_dir
    npm_dir=$(create_mock_npm_dir "1.0.0")
    local mock_npm
    mock_npm=$(create_mock_npm "2.0.0")
    mkdir -p "$TEST_TMPDIR/nodebin"
    cat > "$TEST_TMPDIR/nodebin/node" << 'NODEOF'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == *"require("* ]]; then
        pkg_path=$(echo "$arg" | sed "s/.*require('\\(.*\\)').*/\\1/")
        if [[ -f "$pkg_path" ]]; then
            grep -o '"version": *"[^"]*"' "$pkg_path" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/'
        else
            echo "unknown"
        fi
    fi
done
NODEOF
    chmod +x "$TEST_TMPDIR/nodebin/node"
    local output
    output=$(HOME="$TEST_TMPDIR" CC_MIRROR_DIR="$TEST_TMPDIR/cc-mirror" CC_MIRROR_FORCE_UPDATE=1 \
        PATH="$mock_npm:$TEST_TMPDIR/nodebin:$PATH" bash "$SCRIPT" 2>&1) || true
    echo "    measured remedy: [$(printf '%s\n' "$output" | grep -m1 'Update' | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-140)]"
    # Retargeted 2026-09-23: this test used to demand a bare `npm update`, which leaves
    # variant.json and the launcher stale — the second half of the failure that day. The
    # remedy must be the fleet wrapper (spec: test-runbook-cc-update.sh).
    assert_contains "$output" "cc-update.sh" "update message must name the fleet wrapper cc-update.sh" || return 1
    assert_not_contains "$output" "npm update" "update message must not recommend a bare npm update"
}
run_test "update message names cc-update.sh, not a bare npm update" test_update_message_has_instructions

# ── Marker directory auto-created ───────────────────────────────────────────

test_marker_dir_created_if_missing() {
    # Use a HOME where .cc-mirror doesn't exist yet
    local fresh_home="$TEST_TMPDIR/fresh"
    mkdir -p "$fresh_home"
    # No installed version, but script should still create marker dir
    local rc=0
    HOME="$fresh_home" CC_MIRROR_DIR="$fresh_home/cc-mirror" CC_MIRROR_FORCE_UPDATE=1 \
        bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "should exit cleanly even with missing marker dir"
}
run_test "runs cleanly when marker directory does not exist" test_marker_dir_created_if_missing

# ── Script is not sourced (set -euo pipefail) ──────────────────────────────

test_script_has_strict_mode() {
    local first_lines
    first_lines=$(head -10 "$SCRIPT")
    assert_contains "$first_lines" "set -euo pipefail" "script should use strict mode"
}
run_test "script uses strict mode (set -euo pipefail)" test_script_has_strict_mode

# ── Native (bare-binary) layout ─────────────────────────────────────────────
# A cc-mirror native install has NO npm/ directory: the tree is
# <variant>/{config,native/claude,scripts,tweakcc,variant.json}. Measured from
# cc-mirror 2.1.0's own writer (dist/cc-mirror.mjs): variant.json carries the
# REQUESTED spec in nativeVersion — usually the literal "latest" — and the
# resolved version only in claudeOrig ("native:X.Y.Z"). The binary itself is
# the ground truth: `claude --version` prints "X.Y.Z (Claude Code)" in ~10 ms.
# Downstream report: one native machine sat 33 releases behind because both
# checks read only the npm layout and fell through SILENTLY.

# create_native_fixture <binary-version|""> [nativeVersion] [claudeOrig]
create_native_fixture() {
    local version="$1"
    local native_version="${2:-latest}"
    local claude_orig="${3:-native:${version:-latest}}"
    local mirror="$TEST_TMPDIR/cc-mirror"
    mkdir -p "$mirror/config" "$mirror/native" "$mirror/scripts" "$mirror/tweakcc"
    if [[ -n "$version" ]]; then
        cat > "$mirror/native/claude" <<EOF
#!/bin/bash
[[ "\$1" == "--version" ]] && { echo "$version (Claude Code)"; exit 0; }
exit 1
EOF
        chmod +x "$mirror/native/claude"
    fi
    cat > "$mirror/variant.json" <<EOF
{
  "name": "mclaude",
  "provider": "mirror",
  "claudeOrig": "$claude_orig",
  "binaryPath": "$mirror/native/claude",
  "configDir": "$mirror/config",
  "tweakDir": "$mirror/tweakcc",
  "nativeDir": "$mirror/native",
  "nativeVersion": "$native_version",
  "nativeVersionSource": "default",
  "nativePlatform": "linux-x64"
}
EOF
    echo "$mirror"
}

test_native_update_available() {
    local mirror mock_npm output
    mirror=$(create_native_fixture "2.1.207")
    mock_npm=$(create_mock_npm "2.1.240")
    output=$(HOME="$TEST_TMPDIR" CC_MIRROR_DIR="$mirror" CC_MIRROR_FORCE_UPDATE=1 \
        PATH="$mock_npm:$PATH" bash "$SCRIPT" 2>&1) || true
    echo "    measured output: [$output]"
    assert_contains "$output" "update available" "native layout must report the update" || return 1
    assert_contains "$output" "2.1.207" "must show the installed version read from the binary" || return 1
    assert_contains "$output" "2.1.240" "must show the latest version"
}
run_test "BUG: native layout (no npm/): reports update available" test_native_update_available

test_native_up_to_date() {
    local mirror mock_npm output
    mirror=$(create_native_fixture "2.1.240")
    mock_npm=$(create_mock_npm "2.1.240")
    output=$(HOME="$TEST_TMPDIR" CC_MIRROR_DIR="$mirror" CC_MIRROR_FORCE_UPDATE=1 \
        PATH="$mock_npm:$PATH" bash "$SCRIPT" 2>&1) || true
    echo "    measured output: [$output]"
    assert_contains "$output" "2.1.240" || return 1
    assert_contains "$output" "latest" "native layout must confirm up-to-date, not stay silent" || return 1
    assert_not_contains "$output" "update available"
}
run_test "BUG: native layout: confirms latest when versions match" test_native_up_to_date

test_native_update_instruction_is_wrapper() {
    local mirror mock_npm output
    mirror=$(create_native_fixture "2.1.207")
    mock_npm=$(create_mock_npm "2.1.240")
    output=$(HOME="$TEST_TMPDIR" CC_MIRROR_DIR="$mirror" CC_MIRROR_FORCE_UPDATE=1 \
        PATH="$mock_npm:$PATH" bash "$SCRIPT" 2>&1) || true
    echo "    measured output: [$output]"
    # Retargeted 2026-09-23: this test used to demand the raw `cc-mirror update mclaude`
    # verb — the exact command that reset a live install from 2.1.274 to 2.1.1 with exit 0
    # when a stale cc-mirror answered on PATH. The remedy is the fleet wrapper's pinned
    # road (`cc-update.sh --via cc-mirror`), never the raw verb, and never `npm update`
    # (there is no npm/ dir on a native install).
    assert_contains "$output" "cc-update.sh" "native layout must name the fleet wrapper" || return 1
    assert_contains "$output" "--via cc-mirror" "native layout must select the wrapper's pinned cc-mirror road" || return 1
    assert_not_contains "$output" "cc-mirror update" "the raw cc-mirror verb must not be printed" || return 1
    assert_not_contains "$output" "npm update" "'npm update' is wrong on a native install (there is no npm/ dir)"
}
run_test "native layout: update instruction is cc-update.sh --via cc-mirror, never the raw verb or npm update" test_native_update_instruction_is_wrapper

test_no_install_found_is_loud() {
    # Nothing at all under the mirror dir: no npm/, no native/, no variant.json.
    local mirror="$TEST_TMPDIR/cc-mirror" mock_npm rc=0 output
    mkdir -p "$mirror/config"
    mock_npm=$(create_mock_npm "2.1.240")
    output=$(HOME="$TEST_TMPDIR" CC_MIRROR_DIR="$mirror" CC_MIRROR_FORCE_UPDATE=1 \
        PATH="$mock_npm:$PATH" bash "$SCRIPT" 2>&1) || rc=$?
    echo "    measured: rc=$rc output=[$output]"
    assert_eq "0" "$rc" "must still exit 0 (launcher must not be blocked)" || return 1
    assert_contains "$output" "UNKNOWN" "unknown installed version must be said out loud, not silently skipped" || return 1
    assert_contains "$output" "$mirror" "must name the directory it searched"
}
run_test "BUG: no version found anywhere: LOUD, not silent" test_no_install_found_is_loud

test_variant_json_latest_spec_is_not_a_version() {
    # No runnable binary; variant.json only says "latest" (the requested spec).
    local mirror mock_npm output
    mirror=$(create_native_fixture "" "latest" "native:latest")
    mock_npm=$(create_mock_npm "2.1.240")
    output=$(HOME="$TEST_TMPDIR" CC_MIRROR_DIR="$mirror" CC_MIRROR_FORCE_UPDATE=1 \
        PATH="$mock_npm:$PATH" bash "$SCRIPT" 2>&1) || true
    echo "    measured output: [$output]"
    assert_contains "$output" "UNKNOWN" "'latest' in variant.json is a spec, not a version — must be UNKNOWN" || return 1
    assert_not_contains "$output" "update available" "must not compare a spec string against the registry"
}
run_test "variant.json nativeVersion 'latest' is not mistaken for a version" test_variant_json_latest_spec_is_not_a_version

test_variant_json_resolved_version_fallback() {
    # No runnable binary, but claudeOrig carries the resolved install version.
    local mirror mock_npm output
    mirror=$(create_native_fixture "" "latest" "native:2.1.207")
    mock_npm=$(create_mock_npm "2.1.240")
    output=$(HOME="$TEST_TMPDIR" CC_MIRROR_DIR="$mirror" CC_MIRROR_FORCE_UPDATE=1 \
        PATH="$mock_npm:$PATH" bash "$SCRIPT" 2>&1) || true
    echo "    measured output: [$output]"
    assert_contains "$output" "update available" || return 1
    assert_contains "$output" "2.1.207" "must fall back to the x.y.z in variant.json claudeOrig when the binary cannot be probed"
}
run_test "variant.json x.y.z (claudeOrig) is used when the binary cannot be probed" test_variant_json_resolved_version_fallback

test_binary_wins_over_stale_variant_json() {
    local mirror mock_npm output
    mirror=$(create_native_fixture "2.1.240" "latest" "native:2.1.207")
    mock_npm=$(create_mock_npm "2.1.240")
    output=$(HOME="$TEST_TMPDIR" CC_MIRROR_DIR="$mirror" CC_MIRROR_FORCE_UPDATE=1 \
        PATH="$mock_npm:$PATH" bash "$SCRIPT" 2>&1) || true
    echo "    measured output: [$output]"
    assert_contains "$output" "2.1.240" "binary --version is ground truth" || return 1
    assert_not_contains "$output" "update available" "a stale variant.json must not produce a false update notice" || return 1
    assert_not_contains "$output" "2.1.207"
}
run_test "binary --version wins over a stale variant.json" test_binary_wins_over_stale_variant_json

test_hanging_binary_is_bounded() {
    # No x.y.z anywhere except the (hanging) binary, so UNKNOWN is the only
    # honest answer once the probe is cut off.
    local mirror mock_npm output start elapsed
    mirror=$(create_native_fixture "2.1.207" "latest" "native:latest")
    printf '#!/bin/bash\nsleep 30\n' > "$mirror/native/claude"
    mock_npm=$(create_mock_npm "2.1.240")
    start=$(date +%s)
    output=$(HOME="$TEST_TMPDIR" CC_MIRROR_DIR="$mirror" CC_MIRROR_FORCE_UPDATE=1 \
        PATH="$mock_npm:$PATH" bash "$SCRIPT" 2>&1) || true
    elapsed=$(( $(date +%s) - start ))
    echo "    measured: elapsed=${elapsed}s output=[$output]"
    if (( elapsed > 10 )); then
        echo "    a hanging binary must not hang the launcher (took ${elapsed}s)" >&2
        return 1
    fi
    assert_contains "$output" "UNKNOWN" "a probe that times out must be reported as UNKNOWN"
}
run_test "hanging binary probe is bounded by a timeout" test_hanging_binary_is_bounded

suite_summary
