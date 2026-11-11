#!/usr/bin/env bash
# Shared fixtures for the "config repo held by another live session" suites
# (CFG-666 / CFG-665 / CFG-965): test-config-auto-sync-owner-guard.sh and
# test-config-auto-sync-held-phases.sh. Source after test-helpers.sh and
# test-config-auto-sync-helpers.sh. Defines nothing that runs on its own.
#
# Product under test: the REAL hook, the REAL rotate-session.sh (with its real
# lib.sh and session-lock.sh beside it) and the REAL session-lock.sh in the
# mock config repo. The "other live session" is the test process: its pid is
# alive for the whole test and its ids never match the ids the hook runs with.

LOCK_LIB="$REPO_ROOT/setup/scripts/session-lock.sh"
ROTATE_REAL="$REPO_ROOT/setup/scripts/rotate-session.sh"
APPEND_REAL="$REPO_ROOT/setup/scripts/append-post-rotation.sh"

_CFG_GOAL="Mid-work cfg session that must survive a foreign shutdown"

# A populated cfg session-context.md — exactly the state that holds while a
# cfg session is mid-work (goal + a completed item, so rotate has real work).
_populate_cfg_context() {
    cat > "$1/session-context.md" << EOF
# Session Context

## Session Info
- **Last Updated**: 2026-09-21T12:25:00Z
- **Machine**: WSL
- **Working Directory**: $1
- **Session Goal**: $_CFG_GOAL

## Current State
- **Progress**:
- [x] Drained the inbox

## Key Decisions
- keep going
EOF
}

# Mock config repo carrying the real lock library (or the harness mock when
# asked), the real rotate-session.sh and append-post-rotation.sh, a tracked
# work area and a populated cfg context. Everything is committed and pushed, so
# any later commit or index change is the hook's doing. Deliberately NO
# projects/ dir — the live repo has none either.
_prep_cfg_repo() {   # <config_repo> [real-lib|mock-lib]
    local cfg="$1" lib="${2:-real-lib}"
    create_mock_config_repo "$cfg"
    create_tracked_repo_main "$cfg" "$TEST_TMPDIR/remote.git"
    if [[ "$lib" == "real-lib" ]]; then
        cp "$LOCK_LIB" "$cfg/setup/scripts/session-lock.sh"
    fi
    cp "$APPEND_REAL" "$cfg/setup/scripts/append-post-rotation.sh"
    # Delegate to the REAL rotate-session.sh so it sources the real lib.sh and
    # session-lock.sh next to it — the guard under test is the real guard.
    cat > "$cfg/setup/scripts/rotate-session.sh" << STUB
#!/usr/bin/env bash
exec bash "$ROTATE_REAL" "\$@"
STUB
    chmod +x "$cfg/setup/scripts/rotate-session.sh"
    mkdir -p "$cfg/global/hooks" "$cfg/docs" "$cfg/cross-project" "$cfg/.claude"
    echo "hook v1" > "$cfg/global/hooks/x.sh"
    echo "backlog v1" > "$cfg/backlog.md"
    echo "registry v1" > "$cfg/registry.md"
    echo "manifest v1" > "$cfg/template-sync-manifest.md"
    echo "pending v1" > "$cfg/docs/pending-work.md"
    echo "inbox v1" > "$cfg/cross-project/inbox.md"
    _populate_cfg_context "$cfg"
    (cd "$cfg" && git add -A && git commit -q -m "cfg baseline" && git push -q origin main)
}

# A live foreign lock on the config repo, held by a process that is NOT an
# ancestor of the hook (a sibling `sleep`), bound to ids the hook does not run
# with. $$ would be wrong under a fake CC tree: it is the fake leader's parent,
# so check_lock's ancestry walk would read the hook as the lock's OWNER (rc 1).
# The holder lives until _run returns (or the suite exits).
_FOREIGN_HOLDER_PID=""
_hold_cfg_lock_foreign() {
    sleep 120 & _FOREIGN_HOLDER_PID=$!
    ( source "$LOCK_LIB"; _write_lock "$1/.claude/.session-lock" "af-cfg-owner" "cc-cfg-owner" "$_FOREIGN_HOLDER_PID" )
}
_release_foreign_holder() {
    [[ -z "$_FOREIGN_HOLDER_PID" ]] || kill "$_FOREIGN_HOLDER_PID" 2>/dev/null || true
    _FOREIGN_HOLDER_PID=""
}
trap '_release_foreign_holder' EXIT

# Fake CC process tree for the nested-CC cases. session-lock.sh identifies CC
# processes by cmdline (_CC_PROC_RE, env-overridable); pointing it at these
# names makes any real CC running this suite invisible, so the verdict depends
# only on the tree built here. `leader` = one fake CC; `nested` = one under it.
_FAKE_CC_RE='(^|/)fakecc-(leader|nested)([[:space:]]|$)'
_mk_fake_cc_tree() {
    # `bash "$@"` must NOT be the last command of the -c string: bash 5.2
    # exec-optimises a single trailing command (measured 2026-09-23), which
    # would replace the leader with the child and flatten the tree.
    cat > "$TEST_TMPDIR/fakecc-leader.sh" << 'EOF'
#!/usr/bin/env bash
exec -a fakecc-leader bash -c 'bash "$@"; rc=$?; exit $rc' _ "$@"
EOF
    cat > "$TEST_TMPDIR/fakecc-nested.sh" << 'EOF'
#!/usr/bin/env bash
exec -a fakecc-nested bash "$@"
EOF
}
_under_tree() {   # leader|nested <script> [args]
    local tree="$1"; shift
    case "$tree" in
        leader) _CC_PROC_RE="$_FAKE_CC_RE" bash "$TEST_TMPDIR/fakecc-leader.sh" "$@" ;;
        nested) _CC_PROC_RE="$_FAKE_CC_RE" bash "$TEST_TMPDIR/fakecc-leader.sh" "$TEST_TMPDIR/fakecc-nested.sh" "$@" ;;
    esac
}

# Run the hook as a shutdown of <project_dir>.
#   tree      none (default) | leader | nested   — process tree to run under
#   af / cc   the ids the shutting-down session runs with
#   stdin_id  the session_id CC pipes to the hook on stdin (default: cc)
# CFG965_NO_HELD_LIB=1 removes lib-cfg-held.sh from beside the patched hook
# (the deployment-defect case: the hook shipped without its owner-check library).
_run() {   # <config_repo> <project_dir> [tree] [af] [cc] [stdin_id]
    local cfg="$1" proj="$2" tree="${3:-none}" af="${4:-af-other-project}" cc="${5:-cc-other-project}"
    local stdin_id="${6-$cc}"
    local patched
    patched=$(create_patched_hook "$cfg" "$proj" "$TEST_TMPDIR/home")
    # The hook reads its CC session id from stdin JSON via lib-hook-stdin.sh,
    # sourced from its own directory — give the patched copy that library.
    cp "$REPO_ROOT/global/hooks/lib-hook-stdin.sh" "$TEST_TMPDIR/"
    [[ "${CFG965_NO_HELD_LIB:-0}" == "1" ]] && rm -f "$TEST_TMPDIR/lib-cfg-held.sh"
    local rc=0
    (
        export AFLEET_SESSION_ID="$af" CC_SESSION_ID="$cc"
        if [[ "$tree" == none ]]; then
            printf '{"session_id":"%s"}' "$stdin_id" | bash "$patched"
        else
            _mk_fake_cc_tree
            printf '{"session_id":"%s"}' "$stdin_id" | _under_tree "$tree" "$patched"
        fi
    ) 2>/dev/null || rc=$?
    _release_foreign_holder   # the foreign holder, if any, outlives only the hook
    return "$rc"
}

_commits() { git -C "$1" rev-list --count HEAD; }
_goal_lines() { grep -c "$_CFG_GOAL" "$1/session-context.md" 2>/dev/null || true; }

# A template-push.sh mock recording argv, plus a mock ~/agent-fleet so Phase
# 0.8's preconditions hold. The dry-run reports one copyable file.
_TPL_ARGV=""
_arm_template_push() {   # <config_repo>
    local cfg="$1"
    _TPL_ARGV="$TEST_TMPDIR/tpl-argv.log"
    rm -f "$_TPL_ARGV"
    mkdir -p "$TEST_TMPDIR/home/agent-fleet/.git"
    cat > "$cfg/setup/scripts/template-push.sh" << STUB
#!/usr/bin/env bash
echo "\$@" >> "$_TPL_ARGV"
case "\$1" in --dry-run) echo "Would copy global/hooks/x.sh" ;; esac
exit 0
STUB
    chmod +x "$cfg/setup/scripts/template-push.sh"
}

# A template-push.sh mock whose --dry-run is the moment a cfg session APPEARS:
# it writes a foreign lock held by <holder_pid> (and, with `also-edit`, that
# session's first in-progress edit). The early probe ran before it, so Phase
# 0.8 legitimately runs; what is under test is what Phase 3 does afterwards.
_write_lock_from_template_push() {   # <config_repo> <holder_pid> [also-edit]
    local cfg="$1" holder="$2" edit="${3:-}"
    _TPL_ARGV="$TEST_TMPDIR/tpl-argv.log"
    rm -f "$_TPL_ARGV"
    mkdir -p "$TEST_TMPDIR/home/agent-fleet/.git"
    cat > "$cfg/setup/scripts/template-push.sh" << STUB
#!/usr/bin/env bash
echo "\$@" >> "$_TPL_ARGV"
if [[ "\$1" == --dry-run ]]; then
    ( source "$LOCK_LIB"; _write_lock "$cfg/.claude/.session-lock" "af-cfg-owner" "cc-cfg-owner" "$holder" )
    [[ -n "$edit" ]] && echo "new holder's in-progress edit" >> "$cfg/global/hooks/x.sh"
    echo "Would copy global/hooks/x.sh"
fi
exit 0
STUB
    chmod +x "$cfg/setup/scripts/template-push.sh"
}

# A sync.sh mock that records every verb it is called with (deploy, check, …)
# to <log>, one per line, and answers "no drift" to `check`.
_arm_recording_sync() {   # <config_repo> <log>
    cat > "$1/sync.sh" << STUB
#!/usr/bin/env bash
echo "\${1:-}" >> "$2"
case "\${1:-}" in check) echo "mock-check: no issues" ;; *) echo "mock-sync: \$*" ;; esac
exit 0
STUB
    chmod +x "$1/sync.sh"
}
