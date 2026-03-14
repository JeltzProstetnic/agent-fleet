#!/usr/bin/env bash
# Tests for NVM/non-interactive PATH resolution in lib.sh and configure-claude.sh
source "$(dirname "$0")/test-helpers.sh"

suite_header "NVM PATH Resolution (non-interactive SSH)"

# ── lib.sh: ensure_tool_paths function ──────────────────────────────────────

test_ensure_tool_paths_exists() {
    # ensure_tool_paths should be defined in lib.sh
    source "$REPO_ROOT/setup/lib.sh"
    declare -f ensure_tool_paths >/dev/null 2>&1
}
run_test "ensure_tool_paths function exists in lib.sh" test_ensure_tool_paths_exists

test_ensure_tool_paths_noop_when_tools_found() {
    # When node/npm are already in PATH, ensure_tool_paths should not error
    if ! command -v node &>/dev/null; then
        skip_test "ensure_tool_paths is a no-op when tools are in PATH" "node not installed"
        return 0
    fi
    (
        source "$REPO_ROOT/setup/lib.sh"
        ensure_tool_paths
        # PATH should still contain node
        command -v node >/dev/null
    )
}
run_test "ensure_tool_paths is a no-op when tools are in PATH" test_ensure_tool_paths_noop_when_tools_found

test_ensure_tool_paths_finds_nvm_node() {
    # Simulate NVM installation: create fake NVM dir with node binary
    local fake_nvm="$TEST_TMPDIR/nvm"
    local fake_node_dir="$fake_nvm/versions/node/v22.0.0/bin"
    mkdir -p "$fake_node_dir"
    echo '#!/bin/sh' > "$fake_node_dir/node"
    echo 'echo "v22.0.0"' >> "$fake_node_dir/node"
    chmod +x "$fake_node_dir/node"
    cp "$fake_node_dir/node" "$fake_node_dir/npm"
    chmod +x "$fake_node_dir/npm"
    # Create a fake cc-mirror too
    echo '#!/bin/sh' > "$fake_node_dir/cc-mirror"
    chmod +x "$fake_node_dir/cc-mirror"

    (
        # Strip real node from PATH to simulate non-interactive SSH
        export PATH="/usr/local/bin:/usr/bin:/bin"
        export NVM_DIR="$fake_nvm"
        export HOME="$TEST_TMPDIR"

        source "$REPO_ROOT/setup/lib.sh"
        ensure_tool_paths

        # After ensure_tool_paths, the fake NVM node dir should be in PATH
        command -v node >/dev/null
    )
}
run_test "ensure_tool_paths finds NVM node when not in PATH" test_ensure_tool_paths_finds_nvm_node

test_ensure_tool_paths_finds_default_nvm_alias() {
    # NVM uses a "default" alias that's a symlink — test that path too
    local fake_nvm="$TEST_TMPDIR/nvm"
    local fake_alias_dir="$fake_nvm/versions/node/v22.0.0/bin"
    local fake_default="$fake_nvm/alias/default"
    mkdir -p "$fake_alias_dir" "$fake_nvm/alias"
    echo '#!/bin/sh' > "$fake_alias_dir/node"
    echo 'echo "v22.0.0"' >> "$fake_alias_dir/node"
    chmod +x "$fake_alias_dir/node"
    cp "$fake_alias_dir/node" "$fake_alias_dir/npm"
    chmod +x "$fake_alias_dir/npm"
    # NVM default alias file contains just the version string
    echo "v22.0.0" > "$fake_default"

    (
        export PATH="/usr/local/bin:/usr/bin:/bin"
        export NVM_DIR="$fake_nvm"
        export HOME="$TEST_TMPDIR"

        source "$REPO_ROOT/setup/lib.sh"
        ensure_tool_paths

        command -v node >/dev/null
    )
}
run_test "ensure_tool_paths resolves NVM default alias" test_ensure_tool_paths_finds_default_nvm_alias

test_ensure_tool_paths_finds_nvm_without_NVM_DIR() {
    # NVM_DIR not set, but ~/.nvm exists
    local fake_nvm="$TEST_TMPDIR/.nvm"
    local fake_node_dir="$fake_nvm/versions/node/v20.0.0/bin"
    mkdir -p "$fake_node_dir"
    echo '#!/bin/sh' > "$fake_node_dir/node"
    chmod +x "$fake_node_dir/node"
    cp "$fake_node_dir/node" "$fake_node_dir/npm"
    chmod +x "$fake_node_dir/npm"

    (
        export PATH="/usr/local/bin:/usr/bin:/bin"
        unset NVM_DIR
        export HOME="$TEST_TMPDIR"

        source "$REPO_ROOT/setup/lib.sh"
        ensure_tool_paths

        command -v node >/dev/null
    )
}
run_test "ensure_tool_paths finds NVM at ~/.nvm when NVM_DIR is unset" test_ensure_tool_paths_finds_nvm_without_NVM_DIR

test_ensure_tool_paths_picks_latest_version() {
    # Multiple NVM versions installed — should pick the latest (by sort)
    local fake_nvm="$TEST_TMPDIR/.nvm"
    for ver in v18.0.0 v20.5.0 v22.1.0; do
        local d="$fake_nvm/versions/node/$ver/bin"
        mkdir -p "$d"
        echo "#!/bin/sh" > "$d/node"
        echo "echo '$ver'" >> "$d/node"
        chmod +x "$d/node"
        cp "$d/node" "$d/npm"
        chmod +x "$d/npm"
    done

    # Create a safe bin dir that has coreutils but NOT node
    local safe_bin="$TEST_TMPDIR/safe-bin"
    mkdir -p "$safe_bin"
    for tool in sort tail ls cat tr sed grep basename dirname date mkdir cp wc head chmod mv rm awk printf; do
        local real_path
        real_path="$(command -v "$tool" 2>/dev/null || true)"
        if [[ -n "$real_path" ]] && [[ -x "$real_path" ]]; then
            ln -sf "$real_path" "$safe_bin/$tool"
        fi
    done

    (
        export PATH="$safe_bin"
        unset NVM_DIR
        export HOME="$TEST_TMPDIR"

        # Verify node is truly not in PATH
        if command -v node &>/dev/null; then
            exit 0  # can't isolate — skip
        fi

        source "$REPO_ROOT/setup/lib.sh"
        ensure_tool_paths

        # Should find node (any version)
        command -v node >/dev/null
        # The latest version dir should be in PATH
        local node_path
        node_path="$(command -v node)"
        assert_contains "$node_path" "v22.1.0"
    )
}
run_test "ensure_tool_paths picks latest NVM version" test_ensure_tool_paths_picks_latest_version

# ── --path-prefix flag ──────────────────────────────────────────────────────

test_path_prefix_flag_parsed() {
    # parse_common_args should accept --path-prefix and set PATH_PREFIX
    (
        source "$REPO_ROOT/setup/lib.sh"
        parse_common_args --path-prefix "/custom/bin"
        assert_eq "/custom/bin" "${PATH_PREFIX:-}"
    )
}
run_test "--path-prefix flag is parsed by parse_common_args" test_path_prefix_flag_parsed

test_path_prefix_prepended_to_PATH() {
    # After parse_common_args --path-prefix, ensure_tool_paths should prepend it
    local fake_bin="$TEST_TMPDIR/custom-bin"
    mkdir -p "$fake_bin"
    echo '#!/bin/sh' > "$fake_bin/node"
    chmod +x "$fake_bin/node"
    cp "$fake_bin/node" "$fake_bin/npm"
    chmod +x "$fake_bin/npm"

    (
        export PATH="/usr/local/bin:/usr/bin:/bin"
        export HOME="$TEST_TMPDIR"

        source "$REPO_ROOT/setup/lib.sh"
        PATH_PREFIX="$fake_bin"
        ensure_tool_paths

        command -v node >/dev/null
        local node_path
        node_path="$(command -v node)"
        assert_contains "$node_path" "$fake_bin"
    )
}
run_test "--path-prefix is prepended to PATH by ensure_tool_paths" test_path_prefix_prepended_to_PATH

test_path_prefix_takes_precedence_over_nvm() {
    # --path-prefix should win over NVM auto-detection
    local fake_nvm="$TEST_TMPDIR/.nvm"
    local nvm_bin="$fake_nvm/versions/node/v20.0.0/bin"
    mkdir -p "$nvm_bin"
    echo '#!/bin/sh' > "$nvm_bin/node"
    echo 'echo "nvm-node"' >> "$nvm_bin/node"
    chmod +x "$nvm_bin/node"

    local custom_bin="$TEST_TMPDIR/custom-bin"
    mkdir -p "$custom_bin"
    echo '#!/bin/sh' > "$custom_bin/node"
    echo 'echo "custom-node"' >> "$custom_bin/node"
    chmod +x "$custom_bin/node"

    (
        export PATH="/usr/local/bin:/usr/bin:/bin"
        export HOME="$TEST_TMPDIR"
        unset NVM_DIR

        source "$REPO_ROOT/setup/lib.sh"
        PATH_PREFIX="$custom_bin"
        ensure_tool_paths

        local node_path
        node_path="$(command -v node)"
        assert_contains "$node_path" "custom-bin"
    )
}
run_test "--path-prefix takes precedence over NVM auto-detection" test_path_prefix_takes_precedence_over_nvm

# ── Edge cases ──────────────────────────────────────────────────────────────

test_no_nvm_no_node_logs_warning() {
    # When node can't be found anywhere, ensure_tool_paths should not crash
    # (require_cmd will catch it later — ensure_tool_paths is best-effort)
    (
        export PATH="/usr/local/bin:/usr/bin:/bin"
        export HOME="$TEST_TMPDIR"
        unset NVM_DIR

        source "$REPO_ROOT/setup/lib.sh"
        # Should not crash — just silently do nothing
        ensure_tool_paths
    )
}
run_test "ensure_tool_paths is best-effort (no crash when nothing found)" test_no_nvm_no_node_logs_warning

test_ensure_tool_paths_idempotent() {
    # Calling ensure_tool_paths twice should not double-add paths
    local fake_nvm="$TEST_TMPDIR/.nvm"
    local fake_node_dir="$fake_nvm/versions/node/v22.0.0/bin"
    mkdir -p "$fake_node_dir"
    echo '#!/bin/sh' > "$fake_node_dir/node"
    chmod +x "$fake_node_dir/node"

    (
        export PATH="/usr/local/bin:/usr/bin:/bin"
        export HOME="$TEST_TMPDIR"
        unset NVM_DIR

        source "$REPO_ROOT/setup/lib.sh"
        ensure_tool_paths
        local path_after_first="$PATH"
        ensure_tool_paths
        local path_after_second="$PATH"
        assert_eq "$path_after_first" "$path_after_second"
    )
}
run_test "ensure_tool_paths is idempotent (no duplicate PATH entries)" test_ensure_tool_paths_idempotent

# ── configure-claude.sh integration ─────────────────────────────────────────

test_configure_claude_accepts_path_prefix() {
    # configure-claude.sh should accept --path-prefix without error
    local output
    output=$(bash "$REPO_ROOT/setup/configure-claude.sh" --help 2>&1 || true)
    assert_contains "$output" "--path-prefix"
}
run_test "configure-claude.sh --help mentions --path-prefix" test_configure_claude_accepts_path_prefix

suite_summary
