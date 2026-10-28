#!/usr/bin/env bash
# Tests for config-auto-sync.sh Phase -0.5 — SessionEnd GPI clearing (CFG-863)
#
# The GPI state file (~/.claude/.gpi-state.json) is MACHINE-global while "leader" is
# per PROJECT, so a leader's shutdown runs on a file that other projects' live jobs are
# registered in. 2026-10-28: a sibling project's SessionEnd ran `gpi clear --all` and wiped another project's
# four running tmux-launch ops; the statusline showed nothing running.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/setup/tests/test-helpers.sh"
source "$REPO_ROOT/setup/tests/test-config-auto-sync-helpers.sh"

suite_header "config-auto-sync.sh (Phase -0.5: SessionEnd GPI clearing, CFG-863)"

# Every tmux call made by gpi.sh under test goes to a PRIVATE socket dir, never to the
# user's live server. The dir must exist for the whole file: with a missing TMUX_TMPDIR
# tmux silently falls back to /tmp — the live server (measured 2026-10-28). Not under
# TEST_TMPDIR, which teardown removes after every test.
unset TMUX
TMUX_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/cfgtest-tmux.XXXXXX")"; export TMUX_TMPDIR
_tmux_sandbox_cleanup() { tmux kill-server 2>/dev/null || true; rm -rf "$TMUX_TMPDIR"; }
trap _tmux_sandbox_cleanup EXIT

# Stage a shutdown: mock config repo carrying the REAL gpi.sh, GPI state under the
# hook's (mock) HOME. Echoes the state file path.
stage_hook_with_gpi() {
    local config_repo="$1" project_dir="$2" mock_home="$3"
    mkdir -p "$project_dir/.claude" "$mock_home/.claude"
    create_mock_config_repo "$config_repo"
    cp "$REPO_ROOT/setup/scripts/gpi.sh" "$config_repo/setup/scripts/gpi.sh"
    echo "$mock_home/.claude/.gpi-state.json"
}

# gpi against the staged state file (sidecar beside it)
staged_gpi() {
    local config_repo="$1" state="$2"; shift 2
    GPI_STATE="$state" GPI_COMPLETED="${state%/*}/.gpi-completed.json" \
        bash "$config_repo/setup/scripts/gpi.sh" "$@"
}

op_field() { jq -r "$2" "$1"; }

test_leader_sessionend_keeps_running_ops() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" state live="cfgtest-live-$$"
    state=$(stage_hook_with_gpi "$config_repo" "$project_dir" "$mock_home")
    tmux new-session -d -s "$live" sleep 120
    # Another project's running job (the 2026-10-28 case): no tmux recorded, mid-progress.
    staged_gpi "$config_repo" "$state" start other-running "other job" >/dev/null
    staged_gpi "$config_repo" "$state" update other-running --pct 40 >/dev/null
    staged_gpi "$config_repo" "$state" start live-tmux "live tmux job" --tmux "$live" >/dev/null
    staged_gpi "$config_repo" "$state" start dead-tmux "killed tmux job" --tmux "cfgtest-gone-$$" >/dev/null
    staged_gpi "$config_repo" "$state" start finished "done job" >/dev/null
    staged_gpi "$config_repo" "$state" done finished >/dev/null
    # Past the 10 s grace that protects an op between `gpi start` and `tmux new-session`.
    local aged
    aged=$(jq '.ops["dead-tmux"].started -= 60 | .ops["live-tmux"].started -= 60' "$state")
    echo "$aged" > "$state"

    export AFLEET_SESSION_ID=""
    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    unset AFLEET_SESSION_ID
    tmux kill-server 2>/dev/null || true

    assert_file_exists "$state" "state file must survive SessionEnd" || return 1
    assert_eq "other job" "$(op_field "$state" '.ops["other-running"].label // "null"')" \
        "another project's RUNNING op survives a leader SessionEnd"
    assert_eq "40" "$(op_field "$state" '.ops["other-running"].pct // "null"')" "its progress is intact"
    assert_eq "live tmux job" "$(op_field "$state" '.ops["live-tmux"].label // "null"')" \
        "an op whose tmux session is alive survives"
    assert_eq "null" "$(op_field "$state" '.ops["dead-tmux"] // "null"')" "an op whose tmux session is gone is reaped"
    assert_eq "null" "$(op_field "$state" '.ops["finished"] // "null"')" "a completed op is reaped"
}
run_test "Phase -0.5: leader SessionEnd keeps running ops, reaps completed + dead-tmux" test_leader_sessionend_keeps_running_ops

# A follower exits before Phase -0.5 — not even completed ops may be touched (shared state).
test_follower_sessionend_leaves_gpi_untouched() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project"
    local mock_home="$TEST_TMPDIR/home" state
    state=$(stage_hook_with_gpi "$config_repo" "$project_dir" "$mock_home")
    cp "$REPO_ROOT/setup/scripts/session-lock.sh" "$config_repo/setup/scripts/session-lock.sh"
    # A live foreign leader holds the lock (our PID is alive) → this shutdown is a follower's.
    cat > "$project_dir/.claude/.session-lock" << EOF
{"machine":"$(hostname)","pid":$$,"sessionId":"leader-live-sid","timestamp":"2026-01-01T00:00:00Z","user":"$(whoami)"}
EOF
    staged_gpi "$config_repo" "$state" start finished "done job" >/dev/null
    staged_gpi "$config_repo" "$state" done finished >/dev/null

    export AFLEET_SESSION_ID=""
    local patched
    patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    unset AFLEET_SESSION_ID

    assert_neq "null" "$(op_field "$state" '.ops["finished"] // "null"')" \
        "a follower shutdown leaves the shared GPI state untouched"
}
run_test "Phase -0.5: follower SessionEnd leaves GPI state untouched" test_follower_sessionend_leaves_gpi_untouched

suite_summary
