#!/usr/bin/env bash
# Shared helpers for config-check test suites
# Provides: create_mock_config_repo, create_mock_plugin_files,
#           create_patched_script, run_hook
#
# Requires: test-helpers.sh sourced first (for REPO_ROOT, TEST_TMPDIR)
# Optional: HOOK_SCRIPT can be set before sourcing; defaults to config-check.sh

# Guard against double-sourcing
[[ -n "${_TEST_CHECK_HELPERS_LOADED:-}" ]] && return 0
_TEST_CHECK_HELPERS_LOADED=1

# Default hook script path — callers can override before sourcing
: "${HOOK_SCRIPT:=$REPO_ROOT/global/hooks/config-check.sh}"

# Create a git repo on branch "main" regardless of global git config
create_git_repo_main() {
    local path="$1"
    mkdir -p "$path"
    (
        cd "$path"
        git init -b main >/dev/null 2>&1
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "init" > README.md
        git add README.md
        git commit -m "Initial commit" >/dev/null 2>&1
    )
}

# Create a tracked repo on branch "main"
create_tracked_repo_main() {
    local repo_path="$1"
    local remote_path="$2"
    local remote_name="${3:-origin}"

    mkdir -p "$remote_path"
    git init --bare -b main "$remote_path" >/dev/null 2>&1
    create_git_repo_main "$repo_path"
    (
        cd "$repo_path"
        git remote add "$remote_name" "$remote_path"
        git push -u "$remote_name" main >/dev/null 2>&1
    )
}

# Create a minimal config repo structure that _detect_config_repo() will find
create_mock_config_repo() {
    local dir="$1"
    mkdir -p "$dir/setup/scripts"
    touch "$dir/sync.sh"
    # Copy clean-permissions.sh so Check 10 can find it
    if [ -f "$REPO_ROOT/setup/scripts/clean-permissions.sh" ]; then
        cp "$REPO_ROOT/setup/scripts/clean-permissions.sh" "$dir/setup/scripts/"
    fi
    create_git_repo_main "$dir"
}

# Create mock VoltAgent plugin files so Check 11 (plugin-integrity) stays silent.
# Check 11 fires whenever known_marketplaces.json or installed_plugins.json are
# absent, regardless of whether other checks are the focus of a test.  Any test
# that asserts "no WARNING in output" must call this helper.
create_mock_plugin_files() {
    local mock_home="$1"
    local plugins_dir="$mock_home/.cc-mirror/mclaude/config/plugins"
    mkdir -p "$plugins_dir"

    # known_marketplaces.json must contain "voltagent-subagents"
    echo '{"voltagent-subagents": {"url": "https://example.com"}}' \
        > "$plugins_dir/known_marketplaces.json"

    # installed_plugins.json must list all 10 expected bundles
    cat > "$plugins_dir/installed_plugins.json" << 'EOF'
{
  "bundles": [
    "voltagent-lang@voltagent-subagents",
    "voltagent-infra@voltagent-subagents",
    "voltagent-core-dev@voltagent-subagents",
    "voltagent-qa-sec@voltagent-subagents",
    "voltagent-data-ai@voltagent-subagents",
    "voltagent-dev-exp@voltagent-subagents",
    "voltagent-domains@voltagent-subagents",
    "voltagent-biz@voltagent-subagents",
    "voltagent-meta@voltagent-subagents",
    "voltagent-research@voltagent-subagents"
  ]
}
EOF

    # each bundle needs a cache dir with at least one file
    local cache_base="$plugins_dir/cache/voltagent-subagents"
    for bundle in voltagent-lang voltagent-infra voltagent-core-dev voltagent-qa-sec \
                  voltagent-data-ai voltagent-dev-exp voltagent-domains voltagent-biz \
                  voltagent-meta voltagent-research; do
        mkdir -p "$cache_base/$bundle"
        echo '{}' > "$cache_base/$bundle/manifest.json"
    done
}

# Build a patched version of config-check.sh that:
#   - Uses a hardcoded CONFIG_REPO instead of _detect_config_repo()
#   - Runs with a controlled HOME
#   - Runs from a controlled working directory (for PROJECT_DIR = $(pwd))
#
# Instead of fragile sed on the multi-line function, we write a wrapper
# that defines _detect_config_repo first, then evals the rest of the
# original script with the function redefined.
create_patched_script() {
    local config_repo="$1"
    local mock_home="$2"
    local project_dir="$3"
    local patched="$TEST_TMPDIR/config-check-patched.sh"

    cat > "$patched" << WRAPPER_EOF
#!/usr/bin/env bash
# Patched config-check.sh for testing

# Override HOME
export HOME="$mock_home"

# Reset CC_MIRROR_DIR so it falls back to \$HOME-based default in the hook
unset CC_MIRROR_DIR

# Point CONFIG_CHECK_DIR to the real checks/ modules (BASH_SOURCE breaks under eval)
export CONFIG_CHECK_DIR="$REPO_ROOT/global/hooks/checks"

# cd into project dir so \$(pwd) returns what we want
cd "$project_dir"

# Pre-define _detect_config_repo so when the script defines it, ours
# has already been used. Actually — the script calls _detect_config_repo
# at definition time via CONFIG_REPO="\$(_detect_config_repo)". So we
# need to redefine it BEFORE the script runs, and then skip the script's
# definition.
#
# Strategy: use sed to remove the function body and replace the
# CONFIG_REPO assignment line, then eval.

_detect_config_repo() {
    echo "$config_repo"
}

# Read the original script, remove the _detect_config_repo function body
# (lines 6-17 approximately), and eval the rest
eval "\$(awk '
    /^_detect_config_repo\(\)/ { skip=1; next }
    skip && /^\}/ { skip=0; next }
    skip { next }
    { print }
' "$HOOK_SCRIPT")"
WRAPPER_EOF

    chmod +x "$patched"
    echo "$patched"
}

# Run the patched script. Captures stdout.
run_hook() {
    local patched="$1"
    shift
    bash "$patched" "$@" 2>/dev/null
}
