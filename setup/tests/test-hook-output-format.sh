#!/usr/bin/env bash
# E2E test: all hooks output additionalContext (not systemMessage)
# CC 2.1.83+ renders systemMessage visually — additionalContext stays invisible.
# This test catches regressions if anyone switches back to systemMessage.
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/test-check-helpers.sh"

suite_header "Hook output format: additionalContext (not systemMessage)"

# ── SessionStart hook (config-check.sh) ─────────────────────────────────────

test_sessionstart_uses_additionalContext() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Create a sync failure so there's definitely output
    cat > "$config_repo/.sync-failed" << 'EOF'
stage=deploy
time=2026-03-28T10:00:00Z
detail=test failure marker
EOF

    local patched
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    local output
    output=$(run_hook "$patched")

    # Must be valid JSON
    echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null
    assert_eq "0" "$?" "output must be valid JSON"

    # Must use additionalContext
    local key
    key=$(echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
hso = d.get('hookSpecificOutput') or {}
if 'additionalContext' in hso: print('additionalContext')
elif 'systemMessage' in d or 'systemMessage' in hso: print('systemMessage')
else: print('neither')
" 2>/dev/null)
    assert_eq "additionalContext" "$key" "must use additionalContext key (not systemMessage)"

    # Must NOT contain systemMessage
    assert_not_contains "$output" '"systemMessage"' "must not contain systemMessage key"
}
run_test "SessionStart: config-check.sh uses additionalContext" test_sessionstart_uses_additionalContext

# ── CFG-530: the envelope must be hookSpecificOutput, NOT top-level ──────────
# MEASURED, not inferred, and it contradicts the published docs. The hooks
# reference at code.claude.com/docs/en/hooks presents BOTH of these as valid:
#     {"additionalContext": "..."}                                    <- form A
#     {"hookSpecificOutput":{"hookEventName":"SessionStart", ...}}    <- form B
# Against the real binary (2.1.220) only form B is delivered. Probe: three
# throwaway CLAUDE_CONFIG_DIRs, one SessionStart hook each emitting a distinct
# magic token, one `-p` run apiece asking the model to echo the token back.
#     form A (top-level)      -> model answered NONE      (payload discarded)
#     form B (hookSpecificOutput) -> token echoed         (delivered)
#     form C (plain stdout)   -> token echoed             (delivered)
# Form C is NOT adopted: CFG-503 established that this hook's stdout is a JSON
# contract, and plain-text mode would make any stray byte from a check module
# part of the payload instead of a detectable corruption.
#
# WHY THIS WENT UNNOTICED FOR MONTHS. The test directly above asserted the
# top-level key and passed the whole time, so it actively defended the bug.
# CFG-503 and CFG-527 each fixed a real defect in this same emit path and each
# verified the HOOK'S OWN STDOUT rather than whether Claude Code ingested it.
# Ground truth for ingestion is the transcript: an attachment with
# hookEvent == "SessionStart" carries `stdout` (what the hook printed) and
# `content` (what was actually injected). Across 25 recent sessions in 12
# projects, `content` was 0 bytes every time while `stdout` ran 2.7 KB-128 KB.
test_sessionstart_uses_hookspecificoutput_envelope() {
    local config_repo="$TEST_TMPDIR/cr-env"
    local mock_home="$TEST_TMPDIR/home-env"
    local project_dir="$TEST_TMPDIR/proj-env"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Force the hook to have something to say, so it emits at all.
    cat > "$config_repo/.sync-failed" << 'EOF'
stage=deploy
time=2026-08-19T10:00:00Z
detail=force output so JSON is emitted
EOF

    local patched output shape
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    output=$(run_hook "$patched")

    shape=$(echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
hso = d.get('hookSpecificOutput')
if not isinstance(hso, dict):
    print('top-level-only'); sys.exit()
if hso.get('hookEventName') != 'SessionStart':
    print('missing-hookEventName'); sys.exit()
if not hso.get('additionalContext'):
    print('empty-additionalContext'); sys.exit()
print('ok')
" 2>/dev/null)
    assert_eq "ok" "$shape" \
        "payload must sit in hookSpecificOutput{hookEventName:SessionStart,additionalContext} — top-level is silently discarded by CC" || return 1

    # The identity fields must survive inside the nested envelope.
    local ctx
    ctx=$(echo "$output" | python3 -c "
import json, sys
print(json.load(sys.stdin)['hookSpecificOutput']['additionalContext'])
" 2>/dev/null)
    assert_contains "$ctx" "HOSTNAME:" "HOSTNAME must survive the envelope change"
}
run_test "CFG-530: SessionStart payload uses the hookSpecificOutput envelope" test_sessionstart_uses_hookspecificoutput_envelope

# ── CFG-503: stdout must stay JSON-only even when `git pull` SUCCEEDS ────────
# The existing test above passes against a mock repo with NO remote, so its
# `git pull` always fails silently and prints nothing. In the real fleet the
# pull SUCCEEDS and git writes "Already up to date." to STDOUT, which lands in
# the hook's stdout ahead of the JSON and makes CC discard the whole payload —
# i.e. the entire SessionStart intelligence layer goes dark, silently.
# This test gives the mock repo a real up-to-date remote so the pull succeeds.
test_sessionstart_json_survives_successful_pull() {
    local config_repo="$TEST_TMPDIR/cr-pull"
    local mock_home="$TEST_TMPDIR/home-pull"
    local project_dir="$TEST_TMPDIR/proj-pull"
    local remote="$TEST_TMPDIR/remote-pull.git"
    mkdir -p "$mock_home/.claude" "$project_dir"

    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"

    # Give it a real remote that is already up to date -> `git pull --ff-only`
    # exits 0 and prints "Already up to date." to stdout.
    git init --bare -q "$remote"
    git -C "$config_repo" remote add origin "$remote" 2>/dev/null || true
    git -C "$config_repo" add -A >/dev/null 2>&1 || true
    git -C "$config_repo" commit -qm "seed" >/dev/null 2>&1 || true
    git -C "$config_repo" push -q origin main >/dev/null 2>&1 || true

    # Guarantee the hook emits JSON at all (it only prints when it has something)
    cat > "$config_repo/.sync-failed" << 'EOF'
stage=deploy
time=2026-08-11T23:00:00Z
detail=force output so JSON is emitted
EOF

    local patched output
    patched=$(create_patched_script "$config_repo" "$mock_home" "$project_dir")
    output=$(run_hook "$patched")

    assert_not_contains "$output" "Already up to date" \
        "git pull output must NOT leak onto the hook's stdout" || return 1

    echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null
    assert_eq "0" "$?" "stdout must be valid JSON even when git pull succeeds"
}
run_test "CFG-503: SessionStart stdout stays JSON when git pull succeeds" test_sessionstart_json_survives_successful_pull

# ── PostToolUse hooks ────────────────────────────────────────────────────────

test_tool_install_detect_uses_additionalContext() {
    local hook="$REPO_ROOT/global/hooks/tool-install-detect.sh"
    local input='{"tool_name":"Bash","tool_input":{"command":"pip install requests"},"stdout":"Successfully installed"}'
    local output
    output=$(echo "$input" | bash "$hook" 2>/dev/null)

    assert_contains "$output" "additionalContext" "must use additionalContext"
    assert_not_contains "$output" "systemMessage" "must not use systemMessage"
}
run_test "PostToolUse: tool-install-detect uses additionalContext" test_tool_install_detect_uses_additionalContext

test_auto_lint_uses_additionalContext() {
    local hook="$REPO_ROOT/global/hooks/auto-lint.sh"
    local badfile="$TEST_TMPDIR/bad.py"
    cat > "$badfile" << 'PYEOF'
def foo():
    print("missing closing paren"
PYEOF
    # auto-lint reads file_path from tool_input — must be a real path
    local input="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$badfile\"},\"stdout\":\"\"}"
    local output
    output=$(echo "$input" | bash "$hook" 2>/dev/null)

    assert_contains "$output" "additionalContext" "must use additionalContext" || return 1
    assert_not_contains "$output" "systemMessage" "must not use systemMessage" || return 1
}
run_test "PostToolUse: auto-lint uses additionalContext" test_auto_lint_uses_additionalContext

test_commit_verify_uses_additionalContext() {
    local hook="$REPO_ROOT/global/hooks/commit-verify.sh"
    local input='{"tool_name":"Bash","tool_input":{"command":"git commit -m fix"},"stdout":"[main abc1234] fix"}'
    local output
    output=$(echo "$input" | bash "$hook" 2>/dev/null)

    assert_contains "$output" "additionalContext" "must use additionalContext"
    assert_not_contains "$output" "systemMessage" "must not use systemMessage"
}
run_test "PostToolUse: commit-verify uses additionalContext" test_commit_verify_uses_additionalContext

# ── PreToolUse hooks ─────────────────────────────────────────────────────────

test_critical_edit_notify_uses_additionalContext() {
    local hook="$REPO_ROOT/global/hooks/critical-edit-notify.sh"
    local input='{"tool_name":"Edit","tool_input":{"file_path":"/home/user/.claude/foundation/session-protocol.md"}}'
    local output
    output=$(echo "$input" | bash "$hook" 2>/dev/null)

    assert_contains "$output" "additionalContext" "must use additionalContext"
    assert_not_contains "$output" "systemMessage" "must not use systemMessage"
}
run_test "PreToolUse: critical-edit-notify uses additionalContext" test_critical_edit_notify_uses_additionalContext

# ── Grep audit: no systemMessage in any hook JSON output ─────────────────────

test_no_systemMessage_in_hook_json() {
    # Check all hook .sh files for json.dumps containing systemMessage
    local violations
    violations=$(grep -rn "json.dumps.*systemMessage\|JSON.stringify.*systemMessage" \
        "$REPO_ROOT/global/hooks/" 2>/dev/null | grep -v "^#" || true)

    if [ -n "$violations" ]; then
        echo "  Violations found:"
        echo "$violations"
    fi
    assert_eq "" "$violations" "no hook should output systemMessage in JSON"
}
run_test "Grep audit: no systemMessage in hook JSON output" test_no_systemMessage_in_hook_json

suite_summary
