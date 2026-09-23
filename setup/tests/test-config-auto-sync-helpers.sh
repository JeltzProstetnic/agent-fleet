#!/usr/bin/env bash
# Shared helpers for config-auto-sync.sh test files
# Source this after test-helpers.sh — provides mock infrastructure.
#
# Split from test-config-auto-sync.sh (CFG-301)

HOOK_SCRIPT="$REPO_ROOT/global/hooks/config-auto-sync.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Create a git repo on branch "main"
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

# Create a tracked repo on branch "main" with a bare remote
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

# Create a minimal config repo structure:
#   - Has sync.sh (so _detect_config_repo finds it)
#   - Has .git
#   - Has setup/scripts/ stubs for rotate-session.sh, clean-permissions.sh,
#     session-lock.sh, manage-pending.sh, mobile-deploy.sh
create_mock_config_repo() {
    local dir="$1"
    mkdir -p "$dir/setup/scripts"
    mkdir -p "$dir/cross-project"
    mkdir -p "$dir/docs"
    mkdir -p "$dir/global"

    # sync.sh stub — does nothing, returns success
    cat > "$dir/sync.sh" << 'STUB'
#!/usr/bin/env bash
# Mock sync.sh
case "${1:-}" in
    deploy)  echo "mock-deploy: ok" ;;
    collect) echo "mock-collect: ok (deprecated)" ;;
    check)   echo "mock-check: no issues" ;;
    *)       echo "mock-sync: $*" ;;
esac
exit 0
STUB
    chmod +x "$dir/sync.sh"

    # rotate-session.sh stub — succeeds
    cat > "$dir/setup/scripts/rotate-session.sh" << 'STUB'
#!/usr/bin/env bash
# Mock rotate-session.sh — succeed silently
exit 0
STUB
    chmod +x "$dir/setup/scripts/rotate-session.sh"

    # clean-permissions.sh stub — succeed silently
    cat > "$dir/setup/scripts/clean-permissions.sh" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$dir/setup/scripts/clean-permissions.sh"

    # manage-pending.sh stub — succeed silently
    cat > "$dir/setup/scripts/manage-pending.sh" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$dir/setup/scripts/manage-pending.sh"

    # session-lock.sh stub — provides release_lock, force_release, _read_lock
    cat > "$dir/setup/scripts/session-lock.sh" << 'STUB'
#!/usr/bin/env bash
# Mock session-lock.sh
_LOCK_SESSION=""
_read_lock() { return 1; }
release_lock() { return 0; }
force_release() { return 0; }
STUB

    # mobile-deploy.sh stub
    cat > "$dir/setup/scripts/mobile-deploy.sh" << 'STUB'
#!/usr/bin/env bash
echo "mock-mobile-deploy: $*"
exit 0
STUB
    chmod +x "$dir/setup/scripts/mobile-deploy.sh"
}

# Create session files that the hook's git add commands expect.
# The hook uses: git add session-context.md session-history.md
# and: git add docs/ projects/ cross-project/
# If any file in a multi-pathspec git add doesn't exist, the entire add fails.
# In production, rotate-session.sh creates these. In tests, we must create them.
create_session_files() {
    local dir="$1"
    local content="${2:-test session data}"
    echo "$content" > "$dir/session-context.md"
    echo "$content" > "$dir/session-history.md"
}

# Build a patched version of config-auto-sync.sh that uses a controlled environment.
# We override:
#   - CONFIG_REPO (via _detect_config_repo override)
#   - ORIGINAL_DIR (via cd to project_dir before sourcing)
#   - HOME (to isolate mobile repo detection)
#   - session-lock.sh sourcing (use our mock)
#   - afd-lib.sh sourcing (disabled)
create_patched_hook() {
    local config_repo="$1"
    local project_dir="$2"
    local mock_home="${3:-$TEST_TMPDIR/home}"
    local patched="$TEST_TMPDIR/config-auto-sync-patched.sh"

    # Strategy: copy the original hook script, then use sed to replace
    # the _detect_config_repo function body with one that returns our path.
    # Also prepend HOME override and cd to project_dir.
    #
    # IMPORTANT: The original hook does NOT use set -euo pipefail.

    cp "$HOOK_SCRIPT" "$patched"

    # The hook sources lib-detect-repo.sh from $(dirname BASH_SOURCE[0]) which
    # won't exist when running from /tmp. We prepend our own _detect_config_repo
    # definition, HOME override, and cd to project_dir after the shebang.
    # The source line for lib-detect-repo.sh will fail silently (2>/dev/null),
    # and our pre-defined function will be used instead.
    sed -i '1 a\
export HOME="'"$mock_home"'"\
cd "'"$project_dir"'"\
_detect_config_repo() { echo "'"$config_repo"'"; }' "$patched"

    chmod +x "$patched"
    echo "$patched"
}

# Run the patched hook script. Returns the exit code.
# Set RUN_HOOK_VERBOSE=1 to see stderr (for debugging).
run_hook() {
    local patched="$1"
    shift
    if [[ "${RUN_HOOK_VERBOSE:-}" == "1" ]]; then
        bash "$patched" "$@"
    else
        bash "$patched" "$@" 2>/dev/null
    fi
}
