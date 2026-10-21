#!/usr/bin/env bash
# Tests for deploy_agents() — deploys custom agent definitions from global/agents/
# to $CLAUDE_CONFIG_DIR/agents/ (where Claude Code reads user-level agents). CFG-438.
source "$(dirname "$0")/test-helpers.sh"

SYNC_LIB_DIR="$REPO_ROOT/sync-lib"

suite_header "deploy_agents"

# Source just the deploy_agents function with logging stubbed to echo
_load_deploy_agents() {
    source <(sed -n '/^deploy_agents()/,/^}/p' "$SYNC_LIB_DIR/deploy.sh" \
        | sed 's/log_info/echo/g; s/log_warn/echo/g')
}

test_deploy_agents_copies_md() {
    mkdir -p "$TEST_TMPDIR/global/agents" "$TEST_TMPDIR/config"
    cat > "$TEST_TMPDIR/global/agents/fable.md" <<'EOF'
---
name: fable
model: claude-fable-5
---
You are a subagent running on Claude Fable 5.
EOF

    (
        SCRIPT_DIR="$TEST_TMPDIR"
        CLAUDE_CONFIG_DIR="$TEST_TMPDIR/config"
        _load_deploy_agents
        deploy_agents
    )

    assert_file_exists "$TEST_TMPDIR/config/agents/fable.md"
    # Content must be preserved verbatim
    assert_contains "$(cat "$TEST_TMPDIR/config/agents/fable.md")" "model: claude-fable-5"
}
run_test "deploy_agents copies agent .md files to CLAUDE_CONFIG_DIR/agents" test_deploy_agents_copies_md

test_deploy_agents_noop_when_no_source() {
    mkdir -p "$TEST_TMPDIR/config2"
    (
        SCRIPT_DIR="$TEST_TMPDIR/empty-repo"   # has no global/agents
        CLAUDE_CONFIG_DIR="$TEST_TMPDIR/config2"
        _load_deploy_agents
        deploy_agents
    )
    # No source dir → must not create the target agents dir, must not error
    [[ ! -d "$TEST_TMPDIR/config2/agents" ]]
}
run_test "deploy_agents is a no-op when no agents source dir exists" test_deploy_agents_noop_when_no_source

test_deploy_agents_falls_back_to_claude_home() {
    # When CLAUDE_CONFIG_DIR is unset, fall back to ~/.claude/agents
    mkdir -p "$TEST_TMPDIR/global/agents" "$TEST_TMPDIR/fakehome/.claude"
    printf -- '---\nname: fable\nmodel: claude-fable-5\n---\nbody\n' > "$TEST_TMPDIR/global/agents/fable.md"
    (
        SCRIPT_DIR="$TEST_TMPDIR"
        HOME="$TEST_TMPDIR/fakehome"
        unset CLAUDE_CONFIG_DIR
        _load_deploy_agents
        deploy_agents
    )
    assert_file_exists "$TEST_TMPDIR/fakehome/.claude/agents/fable.md"
}
run_test "deploy_agents falls back to ~/.claude/agents when CLAUDE_CONFIG_DIR unset" test_deploy_agents_falls_back_to_claude_home
