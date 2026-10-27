#!/usr/bin/env bash
# Tests for setup/scripts/anti-lockout-check.sh
# Verifies the anti-lockout gate catches all lockout vectors.

source "$(dirname "$0")/test-helpers.sh"

suite_header "Anti-Lockout Check"

SCRIPT="$REPO_ROOT/setup/scripts/anti-lockout-check.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Build a minimal valid fixture with hooks dir, settings.json, safe-run.sh
build_fixture() {
    local root="$TEST_TMPDIR/fixture"
    local hooks_dir="$root/hooks"
    local config_dir="$root/config"
    mkdir -p "$hooks_dir" "$config_dir" "$root/foundation"

    # Minimal valid hook
    cat > "$hooks_dir/safe-run.sh" << 'HOOK'
#!/usr/bin/env bash
exec bash "$@"
HOOK

    cat > "$hooks_dir/test-hook.sh" << 'HOOK'
#!/usr/bin/env bash
echo "ok"
HOOK

    # Valid settings.json with hooks routing through safe-run.sh.
    # REAL CC schema is matcher-nested: event → [{matcher, hooks:[{type,command}]}].
    cat > "$config_dir/settings.json" << JSON
{
  "hooks": {
    "SessionStart": [
      {"matcher": "", "hooks": [
        {"type": "command", "command": "bash $hooks_dir/safe-run.sh test-hook.sh"}
      ]}
    ]
  }
}
JSON

    # Valid .mcp.json
    echo '{"mcpServers": {}}' > "$config_dir/.mcp.json"

    # Foundation symlink target
    touch "$root/foundation/session-protocol.md"

    echo "$root"
}

# ── Tests ────────────────────────────────────────────────────────────────────

test_pass_on_valid_fixture() {
    local root
    root=$(build_fixture)
    local output
    output=$(bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root" 2>&1)
    assert_exit_code 0 bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "passes on valid fixture" test_pass_on_valid_fixture

test_detects_hook_syntax_error() {
    local root
    root=$(build_fixture)
    # Inject syntax error
    echo 'if then fi else' > "$root/hooks/broken.sh"
    local output
    output=$(bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root" 2>&1) || true
    assert_contains "$output" "syntax"
    assert_exit_code 1 bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "detects hook syntax error" test_detects_hook_syntax_error

test_detects_invalid_settings_json() {
    local root
    root=$(build_fixture)
    echo '{broken json' > "$root/config/settings.json"
    assert_exit_code 1 bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "detects invalid settings.json" test_detects_invalid_settings_json

test_detects_invalid_mcp_json() {
    local root
    root=$(build_fixture)
    echo 'not json' > "$root/config/.mcp.json"
    assert_exit_code 1 bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "detects invalid .mcp.json" test_detects_invalid_mcp_json

test_detects_hook_bypassing_safe_run() {
    local root
    root=$(build_fixture)
    # Hook command that doesn't use safe-run.sh (in the REAL matcher-nested schema)
    cat > "$root/config/settings.json" << JSON
{
  "hooks": {
    "SessionStart": [
      {"matcher": "", "hooks": [
        {"type": "command", "command": "bash $root/hooks/test-hook.sh"}
      ]}
    ]
  }
}
JSON
    local output
    output=$(bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root" 2>&1) || true
    assert_contains "$output" "safe-run"
    assert_exit_code 1 bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "detects hook bypassing safe-run.sh" test_detects_hook_bypassing_safe_run

# REGRESSION (Fable R3 / C3, 2026-07-05): the routing check must DESCEND the real
# matcher-nested CC schema (event → [{matcher, hooks:[{command}]}]). The prior parser
# read h.get('command') one level too shallow → found 0 commands → vacuous PASS, and the
# old fixtures encoded the same wrong flat schema so this hole was never caught.
test_routing_descends_matcher_nested_groups() {
    local root; root=$(build_fixture)
    cat > "$root/config/settings.json" << JSON
{
  "hooks": {
    "SessionStart": [
      {"matcher": "", "hooks": [
        {"type": "command", "command": "bash $root/hooks/safe-run.sh good.sh"}
      ]}
    ],
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [
        {"type": "command", "command": "bash $root/hooks/evil.sh"}
      ]}
    ]
  }
}
JSON
    local output
    output=$(bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root" 2>&1) || true
    assert_contains "$output" "safe-run" || return 1
    assert_exit_code 1 bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "C3: routing check descends matcher-nested hook groups" test_routing_descends_matcher_nested_groups

# The bypass detector must not be limited to 'bash '-prefixed commands (Fable R3 MED):
# a hook registered as 'sh ...' or a bare path also bypasses safe-run.sh.
test_routing_flags_non_bash_bypass() {
    local root; root=$(build_fixture)
    cat > "$root/config/settings.json" << JSON
{
  "hooks": {
    "SessionStart": [
      {"matcher": "", "hooks": [
        {"type": "command", "command": "sh $root/hooks/test-hook.sh"}
      ]}
    ]
  }
}
JSON
    local output
    output=$(bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root" 2>&1) || true
    assert_contains "$output" "safe-run" || return 1
    assert_exit_code 1 bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "C3/MED: non-bash hook bypassing safe-run.sh is flagged" test_routing_flags_non_bash_bypass

test_detects_missing_safe_run() {
    local root
    root=$(build_fixture)
    rm "$root/hooks/safe-run.sh"
    local output
    output=$(bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root" 2>&1) || true
    assert_contains "$output" "safe-run.sh"
    assert_exit_code 1 bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "detects missing safe-run.sh" test_detects_missing_safe_run

test_detects_missing_foundation() {
    local root
    root=$(build_fixture)
    rm -rf "$root/foundation"
    local output
    output=$(bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root" 2>&1) || true
    assert_contains "$output" "foundation"
    assert_exit_code 1 bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "detects missing foundation directory" test_detects_missing_foundation

test_detects_empty_hooks_section() {
    local root
    root=$(build_fixture)
    echo '{"permissions": {}}' > "$root/config/settings.json"
    local output
    output=$(bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root" 2>&1) || true
    assert_contains "$output" "hooks"
    assert_exit_code 1 bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "detects settings.json with no hooks section" test_detects_empty_hooks_section

test_checks_subdirectory_hooks() {
    local root
    root=$(build_fixture)
    mkdir -p "$root/hooks/checks"
    echo 'if then' > "$root/hooks/checks/broken-check.sh"
    assert_exit_code 1 bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "checks hooks in subdirectories" test_checks_subdirectory_hooks

test_default_paths_when_no_args() {
    # Without args, script should use default paths (~/.claude/hooks, etc.)
    # Needs real HOME — live system paths don't exist in test sandbox
    local output
    output=$(HOME="$REAL_HOME" bash "$SCRIPT" 2>&1)
    assert_contains "$output" "PASS"
}
run_test "uses default paths and passes on live system" test_default_paths_when_no_args

# ── CFG-433 A4 slice 5: H2 NUC crontab hygiene + RUNWAY_OK contract ──────────

# H2 uses CC_MESH_ANTILOCKOUT_CRONTAB_FILE to shim the crontab; without it the
# script must silently skip (many machines run without cron altogether).

test_H2_fails_when_crontab_still_runs_cc_refresh_cron() {
    local root; root=$(build_fixture)
    local ct="$TEST_TMPDIR/crontab"
    printf '%s\n' '*/20 * * * * bash /home/user/agent-fleet/setup/scripts/cc-refresh-cron.sh' > "$ct"
    local output
    output=$(CC_MESH_ANTILOCKOUT_CRONTAB_FILE="$ct" bash "$SCRIPT" \
        --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root" 2>&1) || true
    assert_contains "$output" "cc-refresh-cron.sh" || return 1
    CC_MESH_ANTILOCKOUT_CRONTAB_FILE="$ct" assert_exit_code 1 bash "$SCRIPT" \
        --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "A4-H2: fails when NUC crontab still runs cc-refresh-cron.sh" test_H2_fails_when_crontab_still_runs_cc_refresh_cron

test_H2_fails_when_crontab_still_runs_old_propagate_push() {
    local root; root=$(build_fixture)
    local ct="$TEST_TMPDIR/crontab"
    printf '%s\n' '0 * * * * bash /some/path/cc-credentials-propagate.sh push' > "$ct"
    local output
    output=$(CC_MESH_ANTILOCKOUT_CRONTAB_FILE="$ct" bash "$SCRIPT" \
        --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root" 2>&1) || true
    assert_contains "$output" "cc-credentials-propagate.sh" || return 1
    CC_MESH_ANTILOCKOUT_CRONTAB_FILE="$ct" assert_exit_code 1 bash "$SCRIPT" \
        --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "A4-H2: fails when NUC crontab still runs cc-credentials-propagate.sh push" test_H2_fails_when_crontab_still_runs_old_propagate_push

test_H2_ignores_commented_out_lines() {
    # A commented-out old cron line must NOT brick the mesh forever — mirrors
    # cc-refresh-cron's own precondition-guard convention (grep -v '^\s*#').
    local root; root=$(build_fixture)
    local ct="$TEST_TMPDIR/crontab"
    printf '%s\n' '# */20 * * * * bash /path/cc-refresh-cron.sh   # retired 2026-06-23' > "$ct"
    printf '%s\n' '*/20 * * * * CC_MESH_TTL=5400 bash /path/cc-mesh-cron.sh nuc' >> "$ct"
    CC_MESH_ANTILOCKOUT_CRONTAB_FILE="$ct" assert_exit_code 0 bash "$SCRIPT" \
        --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "A4-H2: commented-out old cron lines are inert (skip)" test_H2_ignores_commented_out_lines

test_H2_passes_on_clean_mesh_crontab() {
    local root; root=$(build_fixture)
    local ct="$TEST_TMPDIR/crontab"
    printf '%s\n' '*/20 * * * * CC_MESH_TTL=5400 bash /path/cc-mesh-cron.sh nuc' > "$ct"
    CC_MESH_ANTILOCKOUT_CRONTAB_FILE="$ct" assert_exit_code 0 bash "$SCRIPT" \
        --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "A4-H2: clean mesh-only crontab passes" test_H2_passes_on_clean_mesh_crontab

test_H2_silent_skip_when_shim_file_absent() {
    # Deck 2, and any machine where the shim file doesn't exist: silent skip.
    # (Test-side model of "no crontab available" — the script's own `command -v
    # crontab` fallback handles the live-machine case.)
    local root; root=$(build_fixture)
    CC_MESH_ANTILOCKOUT_CRONTAB_FILE="$TEST_TMPDIR/no-such-file" \
        assert_exit_code 0 bash "$SCRIPT" \
            --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "A4-H2: shim file absent → silent skip (pass)" test_H2_silent_skip_when_shim_file_absent

test_H2_silent_skip_when_shim_file_empty() {
    local root; root=$(build_fixture)
    local ct="$TEST_TMPDIR/empty-crontab"; : > "$ct"
    CC_MESH_ANTILOCKOUT_CRONTAB_FILE="$ct" \
        assert_exit_code 0 bash "$SCRIPT" \
            --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "A4-H2: empty crontab → silent skip (pass)" test_H2_silent_skip_when_shim_file_empty

# RUNWAY_OK contract — bash cc-mesh-leader.sh config at the configured TTL must
# emit RUNWAY_OK=1. The check is skipped if the leader script isn't present
# (test seam CC_MESH_ANTILOCKOUT_LEADER_BIN + TTL via CC_MESH_ANTILOCKOUT_TTL).

test_runway_ok_passes_at_configured_ttl() {
    local root; root=$(build_fixture)
    local leader="$REPO_ROOT/setup/scripts/cc-mesh-leader.sh"
    CC_MESH_ANTILOCKOUT_LEADER_BIN="$leader" CC_MESH_ANTILOCKOUT_TTL=5400 \
        assert_exit_code 0 bash "$SCRIPT" \
            --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "A4 RUNWAY_OK: TTL=5400 with real leader emits RUNWAY_OK=1 (pass)" test_runway_ok_passes_at_configured_ttl

test_runway_ok_fails_when_config_emits_runway_zero() {
    local root; root=$(build_fixture)
    local leader="$TEST_TMPDIR/fake-leader.sh"
    cat > "$leader" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "config" ]; then
    printf 'TTL=%s\nTOKEN_RUNWAY=100\nWORST_STALL=7340\nRUNWAY_OK=0\n' "${CC_MESH_TTL:-5400}"
fi
EOF
    chmod +x "$leader"
    local output
    output=$(CC_MESH_ANTILOCKOUT_LEADER_BIN="$leader" CC_MESH_ANTILOCKOUT_TTL=5400 \
        bash "$SCRIPT" --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root" 2>&1) || true
    assert_contains "$output" "RUNWAY_OK" || return 1
    CC_MESH_ANTILOCKOUT_LEADER_BIN="$leader" CC_MESH_ANTILOCKOUT_TTL=5400 \
        assert_exit_code 1 bash "$SCRIPT" \
            --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "A4 RUNWAY_OK: RUNWAY_OK=0 from leader config → fail-closed" test_runway_ok_fails_when_config_emits_runway_zero

test_runway_ok_silent_skip_when_leader_missing() {
    local root; root=$(build_fixture)
    # Point at a non-existent leader — the check should skip, not fail.
    CC_MESH_ANTILOCKOUT_LEADER_BIN="$TEST_TMPDIR/does-not-exist" CC_MESH_ANTILOCKOUT_TTL=5400 \
        assert_exit_code 0 bash "$SCRIPT" \
            --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "A4 RUNWAY_OK: missing leader script → silent skip (pass)" test_runway_ok_silent_skip_when_leader_missing

# ── A5: Tier 2 edits must not reach a commit without a recorded E2E run ──────
# A Tier 2 edit (setup/scripts, global/hooks, setup/config) requires podman E2E
# "before committing", but nothing enforced it — a session could disclose "E2E not
# run" and commit anyway, which is exactly what happened on 2026-09-10.
# Note there is deliberately NO skip clause for "podman is unavailable": that would
# be Known Faulty Pattern 7, turning the gate off precisely where it is load-bearing.

# Build a throwaway git repo with a Tier 2 file, returns its path.
build_tier2_repo() {
    local repo="$TEST_TMPDIR/tier2repo"
    mkdir -p "$repo/setup/scripts"
    git -C "$repo" init -q 2>/dev/null
    git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
    echo "original" > "$repo/setup/scripts/thing.sh"
    git -C "$repo" add -A >/dev/null 2>&1
    git -C "$repo" commit -qm init >/dev/null 2>&1
    printf '%s' "$repo"
}

test_e2e_gate_fails_without_marker() {
    local root; root=$(build_fixture)
    local repo; repo=$(build_tier2_repo)
    echo "modified" > "$repo/setup/scripts/thing.sh"
    ANTILOCKOUT_REPO_DIR="$repo" ANTILOCKOUT_E2E_MARKER="$TEST_TMPDIR/no-such-marker" \
        assert_exit_code 1 bash "$SCRIPT" \
            --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "A5 E2E gate: Tier 2 file modified with no recorded E2E → fail" test_e2e_gate_fails_without_marker

test_e2e_gate_fails_when_marker_is_stale() {
    local root; root=$(build_fixture)
    local repo; repo=$(build_tier2_repo)
    local marker="$TEST_TMPDIR/stale-marker"
    touch -d '2020-01-01' "$marker"
    echo "modified after the E2E ran" > "$repo/setup/scripts/thing.sh"
    ANTILOCKOUT_REPO_DIR="$repo" ANTILOCKOUT_E2E_MARKER="$marker" \
        assert_exit_code 1 bash "$SCRIPT" \
            --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "A5 E2E gate: Tier 2 file newer than the last E2E → fail" test_e2e_gate_fails_when_marker_is_stale

test_e2e_gate_passes_when_marker_is_fresh() {
    local root; root=$(build_fixture)
    local repo; repo=$(build_tier2_repo)
    echo "modified" > "$repo/setup/scripts/thing.sh"
    local marker="$TEST_TMPDIR/fresh-marker"
    touch "$marker"   # created after the edit
    ANTILOCKOUT_REPO_DIR="$repo" ANTILOCKOUT_E2E_MARKER="$marker" \
        assert_exit_code 0 bash "$SCRIPT" \
            --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "A5 E2E gate: E2E recorded after the edit → pass" test_e2e_gate_passes_when_marker_is_fresh

test_e2e_gate_ignores_non_tier2_changes() {
    local root; root=$(build_fixture)
    local repo; repo=$(build_tier2_repo)
    mkdir -p "$repo/docs"
    echo "just a doc" > "$repo/docs/notes.md"
    ANTILOCKOUT_REPO_DIR="$repo" ANTILOCKOUT_E2E_MARKER="$TEST_TMPDIR/no-such-marker" \
        assert_exit_code 0 bash "$SCRIPT" \
            --hooks-dir "$root/hooks" --config-dir "$root/config" --claude-dir "$root"
}
run_test "A5 E2E gate: a non-Tier-2 change does not demand an E2E" test_e2e_gate_ignores_non_tier2_changes

suite_summary
