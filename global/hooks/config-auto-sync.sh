#!/usr/bin/env bash
# Auto-sync config repo on session end.
# Runs as a SessionEnd hook — silent, zero context cost.
#
# What this hook does (in order):
# 1. Auto-rotate the CURRENT PROJECT's session (if it has session-context.md)
# 2. Commit session files in current project (if different from the config repo)
# 3. Auto-rotate the config repo's own session
# 4. Deploy repo → live, commit config repo changes, and push
#    Step 3 and the commit in step 4 are skipped when a DIFFERENT live session
#    holds the config repo (CFG-666 / CFG-665) — they are that session's own
#    shutdown work; touching them from here blanked and swept a live session.
#
# On failure: writes a marker to .sync-failed
# The SessionStart hook (config-check.sh) reads this marker and alerts the user.

# Source portable wrappers (provides _readlink_f for macOS compat)
source "$(dirname "${BASH_SOURCE[0]}")/lib-portable.sh" 2>/dev/null || true

# Config repo detection — canonical source in lib-detect-repo.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-detect-repo.sh" 2>/dev/null || true
CONFIG_REPO="$(_detect_config_repo)"
FAIL_MARKER="$CONFIG_REPO/.sync-failed"
LOCK_FILE="$CONFIG_REPO/.sync-lock"
ROTATE_SCRIPT="$CONFIG_REPO/setup/scripts/rotate-session.sh"
CLEAN_PERMS_SCRIPT="$CONFIG_REPO/setup/scripts/clean-permissions.sh"

# Capture the original working directory (the project the user was in)
ORIGINAL_DIR="$(pwd)"

# --- Shutdown progress indicator (CFG-340) ---
# Writes to stderr so the user sees progress while hooks run after /exit.
# Each phase gets its own line (no \r overwrite) so all steps remain visible.
_shutdown_progress() { printf '  \033[38;5;243m%s\033[0m\n' "$1" >&2; }
_shutdown_done() { printf '  \033[38;5;243mShutdown complete.\033[0m\n' >&2; }

# --- Phase -3: expire artifact-publish consent (SCI-34) ---
# cloud-publish-guard.sh unblocks publishing while <project>/.claude/.artifact-consent
# exists. That consent is per-SESSION by design: a marker surviving into tomorrow means
# a later session silently inherits permission to send the user's content to claude.ai,
# which is the failure this whole guard exists to prevent. Clearing it here is what makes
# "per-session" true rather than aspirational.
rm -f "$ORIGINAL_DIR/.claude/.artifact-consent" 2>/dev/null || true
rm -f "$CONFIG_REPO/.claude/.artifact-consent" 2>/dev/null || true

# --- Phase -2: arm every fleet repo's pre-push guard (CFG-535) ---
# This hook pushes to ~/agent-fleet, which is PUBLIC, and does so without any leak
# check of its own — the gate lives in template-push.sh, which this path never calls.
# The repo's tracked .githooks/pre-push is the only thing left, and git ignores a
# tracked hooks dir unless core.hooksPath points at it. That setting is per-clone and
# untracked, and nothing installed it. Arm it here, every session, on every machine.
_EGH="$CONFIG_REPO/setup/scripts/ensure-githooks.sh"
[ -f "$_EGH" ] && { bash "$_EGH" >&2 || true; }

_shutdown_progress "Releasing locks..."

# --- Phase -1: Session role + own-lock release (CFG-452 Phases 0+2) ---
# Determine this session's role (leader|follower), release ONLY our own lock, and
# — if a follower — stop before touching ANY shared state. A follower must not
# rotate/commit/deploy/push, must not release the leader's AFD server lock, and
# must not clear the shared GPI statusline. NEVER derive ownership from the lock
# file and NEVER force-remove — that would clobber a live leader.
#
# Role source of truth: the marker persisted at SessionStart (07b), one per
# session identity. If no marker (degraded launch), fall back to lock ownership:
#   - proven owner (we released a lock that was provably ours) → leader;
#   - a lock is present but not provably ours → follower (fail toward
#     leader-safety — a follower always has the leader's lock present);
#   - no lock at all → leader (solo session — nothing to clobber, don't lose work).
_SESSION_LOCK_LIB="$CONFIG_REPO/setup/scripts/session-lock.sh"
_LOCKFILE="$ORIGINAL_DIR/.claude/.session-lock"
_LOCK_SID="${AFLEET_SESSION_ID:-}"
# The lock may be bound to this CC session id (stamped at SessionStart). A
# matching cc id proves ownership for release — an inherited AFLEET_SESSION_ID
# does not. Read the cc id from this hook's stdin JSON; empty on any failure.
_CC_SID=""
source "$(dirname "${BASH_SOURCE[0]}")/lib-hook-stdin.sh" 2>/dev/null || true
if command -v read_cc_session_id >/dev/null 2>&1; then
    _CC_SID="$(read_cc_session_id)"
fi

_SESSION_ROLE=""
_LOCK_PRESENT=0; [ -f "$_LOCKFILE" ] && _LOCK_PRESENT=1
_PROVED_OWNER=0
if [ -f "$_SESSION_LOCK_LIB" ]; then
    source "$_SESSION_LOCK_LIB"
    # Authoritative role marker (present whenever a CC/afleet session id exists).
    if command -v read_role >/dev/null 2>&1; then
        _rr="$(read_role "$ORIGINAL_DIR" "$_CC_SID" "$_LOCK_SID" 2>/dev/null)" && _SESSION_ROLE="$_rr" || true
    fi
    # Release our own lock (ownership-proven; safe no-op otherwise).
    if [ -n "$_LOCK_SID" ] || [ -n "$_CC_SID" ]; then
        if release_own_lock "$ORIGINAL_DIR" "$_LOCK_SID" "$_CC_SID" 2>/dev/null; then
            [ "$_LOCK_PRESENT" -eq 1 ] && _PROVED_OWNER=1
        fi
    fi
    # This session is ending — drop its role marker.
    if command -v clear_role >/dev/null 2>&1; then
        clear_role "$ORIGINAL_DIR" "$_CC_SID" "$_LOCK_SID" 2>/dev/null || true
    fi
fi

# Resolve role when no authoritative marker was found (degraded launch).
if [ -z "$_SESSION_ROLE" ]; then
    if [ "$_PROVED_OWNER" -eq 1 ]; then
        _SESSION_ROLE="leader"
    elif [ "$_LOCK_PRESENT" -eq 1 ]; then
        _SESSION_ROLE="follower"
    else
        _SESSION_ROLE="leader"
    fi
fi

# FOLLOWER: own lock already released — leave all shared state untouched and stop.
if [ "$_SESSION_ROLE" = "follower" ]; then
    printf '  \033[38;5;243mFOLLOWER shutdown — shared state untouched (leader lock intact).\033[0m\n' >&2
    exit 0
fi

# ── Leader path from here (a follower has already exited) ─────────────────────

# --- Phase -0.5: Clear GPI state (CFG-363) — leader only (shared statusline) ---
# Clean slate on session end — prevents stale statusline entries. State lives in
# $HOME/.claude/.gpi-state.json (machine-global), so ONLY a leader may clear it.
_GPI_SCRIPT="$CONFIG_REPO/setup/scripts/gpi.sh"
if [ -f "$_GPI_SCRIPT" ]; then
    bash "$_GPI_SCRIPT" clear --all 2>/dev/null || true
fi

# Release server lock if session ID is available (CFG-101) — leader only.
if [ -n "$_LOCK_SID" ]; then
    _AFD_LIB="$CONFIG_REPO/afd/lib/afd-lib.sh"
    if [ -f "$_AFD_LIB" ] && [ -n "${AFD_TOKEN:-}" ]; then
        . "$_AFD_LIB"
        afd_lock_release "$(basename "$ORIGINAL_DIR")" 2>/dev/null || true
    fi
fi

# --- Phase 0: Collect mobile outbox tasks ---
MOBILE_REPO="$HOME/agent-fleet-mobile"
if [ -f "$MOBILE_REPO/inbox/outbox.md" ]; then
    MOBILE_TASKS=$(grep -c '^\- \[ \]' "$MOBILE_REPO/inbox/outbox.md" 2>/dev/null || echo "0")
    if [ "$MOBILE_TASKS" -gt 0 ] 2>/dev/null; then
        bash "$CONFIG_REPO/setup/scripts/mobile-deploy.sh" --collect \
            --config-repo "$CONFIG_REPO" \
            --target "$MOBILE_REPO" 2>/dev/null || true
    fi
fi

# --- Phase 0.5: Clean stale permissions blocks ---
# "Always allow" clicks create project-level permissions blocks that shadow global
# permissions. Clean them before auto-sync to keep things tidy for the next session.
bash "$CLEAN_PERMS_SCRIPT" 2>/dev/null || true

# --- Phase 0.6: Auto-clean completed pending files ---
# Delete pending files whose tracked backlog items are all [x] done.
MANAGE_PENDING="$CONFIG_REPO/setup/scripts/manage-pending.sh"
if [ -f "$MANAGE_PENDING" ]; then
    bash "$MANAGE_PENDING" --auto-clean --project-dir "$CONFIG_REPO" 2>/dev/null || true
fi

# --- Phase 0.65: Auto-archive completed cross-project inbox items (CFG-134) ---
# Move [x] completed items from cross-project/inbox.md → inbox-archive.md so the
# inbox stays lean. Only from the config repo's own shutdown (it owns cross-project/*
# — cross-project write boundary); no-op if no completed items. Runs before the
# config-repo commit phase so the archived state is committed this session.
if [[ "$ORIGINAL_DIR" == "$CONFIG_REPO" ]]; then
    _INBOX_ARCHIVE="$CONFIG_REPO/setup/scripts/inbox-archive.sh"
    if [[ -f "$_INBOX_ARCHIVE" && -f "$CONFIG_REPO/cross-project/inbox.md" ]]; then
        bash "$_INBOX_ARCHIVE" "$CONFIG_REPO/cross-project/inbox.md" \
            "$CONFIG_REPO/cross-project/inbox-archive.md" >/dev/null 2>&1 || true
    fi
fi

_shutdown_progress "Checking drift..."

# --- Phase 0.7: Run propagation drift check ---
# Runs sync.sh check, captures any warnings to .sync-warnings.log.
# The SessionStart hook (config-check.sh) reads this log and surfaces drift to Claude.
# Warning only — never blocks shutdown.
DRIFT_LOG="$CONFIG_REPO/.sync-warnings.log"
if [ -f "$CONFIG_REPO/sync.sh" ]; then
    DRIFT_OUTPUT=$(bash "$CONFIG_REPO/sync.sh" check 2>&1 || true)
    DRIFT_ISSUES=$(echo "$DRIFT_OUTPUT" | grep -i 'warn\|drifted\|stale\|issue(s) found' || true)
    if [ -n "$DRIFT_ISSUES" ]; then
        printf '%s\n' "$DRIFT_ISSUES" > "$DRIFT_LOG"
    else
        rm -f "$DRIFT_LOG"
    fi
fi

# --- Phase 0.75: T2 deployment-critical edit detection (CFG-326) ---
# Check if T2 files were modified this session. If so, warn that E2E tests should be run.
# Does NOT block shutdown — informational only, surfaced at next session start.
T2_MARKER="$CONFIG_REPO/.t2-edits-pending"
if [ -d "$CONFIG_REPO/.git" ]; then
    _t2_files=$(git -C "$CONFIG_REPO" diff --name-only HEAD 2>/dev/null || true)
    if [ -z "$_t2_files" ]; then
        _t2_files=$(git -C "$CONFIG_REPO" diff --name-only HEAD~1 2>/dev/null || true)
    fi
    _t2_hits=""
    while IFS= read -r _f; do
        [ -z "$_f" ] && continue
        case "$_f" in
            setup/install*.sh|setup/configure-*.sh|setup/lib.sh) _t2_hits="${_t2_hits:+$_t2_hits, }$_f" ;;
            setup/scripts/upgrade.sh) _t2_hits="${_t2_hits:+$_t2_hits, }$_f" ;;
            setup/config/*.json) _t2_hits="${_t2_hits:+$_t2_hits, }$_f" ;;
            global/hooks/*.sh|global/hooks/checks/*.sh) _t2_hits="${_t2_hits:+$_t2_hits, }$_f" ;;
        esac
    done <<< "$_t2_files"
    if [ -n "$_t2_hits" ]; then
        echo "T2_EDITS: $_t2_hits" > "$T2_MARKER"
    else
        rm -f "$T2_MARKER"
    fi
fi

# --- Phase 0.8: Automatic template propagation (CFG-242, CFG-391) ---
# If template-push.sh exists and template repo is local, auto-propagate changes.
# Category 1-2 files are auto-committed. Category 3 files are flagged only.
# CFG-242: failure-marker writing so next SessionStart surfaces silent failures.
# CFG-391: when agent-fleet has an origin remote, also push to GitHub via --push;
# fall back to --commit (local-only) when no remote / no upstream branch is set.
_TPL_SCRIPT="$CONFIG_REPO/setup/scripts/template-push.sh"
_TPL_DIR="$HOME/agent-fleet"
_TPL_FAIL_MARKER="$CONFIG_REPO/.template-push-failed"
if [ -f "$_TPL_SCRIPT" ] && [ -d "$_TPL_DIR/.git" ]; then
    _TPL_DRIFT=$(bash "$_TPL_SCRIPT" --dry-run 2>&1 | grep -c 'Would copy\|Would sanitize' || true)
    if [ "$_TPL_DRIFT" -gt 0 ]; then
        # Preflight (CFG-391): use --push only when origin remote exists.
        # Anything else (no remote, dual-remote misconfig, missing upstream
        # branch) → fall back to --commit and log the reason. The audit that
        # spawned CFG-391 was triggered by silent push gaps, so log loudly.
        _TPL_FLAG="--push"
        if ! git -C "$_TPL_DIR" remote get-url origin >/dev/null 2>&1; then
            _TPL_FLAG="--commit"
            printf 'TEMPLATE_PUSH_PREFLIGHT: agent-fleet origin remote missing — falling back to --commit\n' \
                >> "${DRIFT_LOG:-$CONFIG_REPO/.sync-warnings.log}"
        elif ! git -C "$_TPL_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
            _TPL_FLAG="--commit"
            printf 'TEMPLATE_PUSH_PREFLIGHT: agent-fleet has no upstream branch — falling back to --commit\n' \
                >> "${DRIFT_LOG:-$CONFIG_REPO/.sync-warnings.log}"
        fi
        # Auto-propagate (Cat 1-2 only, Cat 3 flagged) using the chosen flag
        _TPL_OUT=$(bash "$_TPL_SCRIPT" "$_TPL_FLAG" 2>&1)
        _TPL_RC=$?
        if [ "$_TPL_RC" -ne 0 ]; then
            printf 'time=%s\nexit_code=%d\ndrift_files=%d\noutput_tail=%s\n' \
                "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" \
                "$_TPL_RC" \
                "$_TPL_DRIFT" \
                "$(echo "$_TPL_OUT" | tail -10)" \
                > "$_TPL_FAIL_MARKER"
            printf 'TEMPLATE_PUSH_FAILED: exit=%d drift=%d (see .template-push-failed)\n' \
                "$_TPL_RC" "$_TPL_DRIFT" \
                >> "${DRIFT_LOG:-$CONFIG_REPO/.sync-warnings.log}"
        else
            # Success: clear any prior failure marker
            rm -f "$_TPL_FAIL_MARKER"
            echo "$_TPL_OUT" | tail -5
        fi
        # Cat-3 inbox auto-generation (CFG-395): parse Flag-only warnings from
        # template-push output, compare against .cat3-known, generate per-file
        # inbox tasks for genuinely new Cat-3 entries. First run seeds the file
        # without spamming inbox (avoids 21-item dump on upgrade).
        _CAT3_KNOWN="$CONFIG_REPO/.cat3-known"
        _CAT3_FILES=$(echo "$_TPL_OUT" | grep -oP 'Flag-only file changed: \K\S+' || true)
        if [ -n "$_CAT3_FILES" ]; then
            if [ ! -f "$_CAT3_KNOWN" ]; then
                echo "$_CAT3_FILES" > "$_CAT3_KNOWN"
            else
                _INBOX="$CONFIG_REPO/cross-project/inbox.md"
                _NEW_COUNT=0
                while IFS= read -r _cf; do
                    [ -z "$_cf" ] && continue
                    grep -Fxq "$_cf" "$_CAT3_KNOWN" && continue
                    echo "$_cf" >> "$_CAT3_KNOWN"
                    _NEW_COUNT=$((_NEW_COUNT + 1))
                    if [ -f "$_INBOX" ]; then
                        _REASON=$(grep -F "\`$_cf\`" "$CONFIG_REPO/template-sync-manifest.md" 2>/dev/null \
                            | head -1 | sed -E 's/.*\|[[:space:]]*([^|]+)[[:space:]]*\|[[:space:]]*$/\1/' \
                            | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        printf '\n- [ ] **agent-fleet**: Cat-3 review — `%s`. Diff: %s. Source: auto-detect %s.\n' \
                            "$_cf" "${_REASON:-(no manifest entry)}" "$(date -u +%Y-%m-%d)" >> "$_INBOX"
                    fi
                done <<< "$_CAT3_FILES"
                if [ "$_NEW_COUNT" -gt 0 ]; then
                    printf 'TEMPLATE_PROPAGATION_CAT3_NEW: %d new Cat-3 file(s) added to agent-fleet inbox\n' \
                        "$_NEW_COUNT" >> "${DRIFT_LOG:-$CONFIG_REPO/.sync-warnings.log}"
                fi
            fi
        fi
    fi
fi

# --- Phase 0.85: Pending-file demote detection (loop closure) ---
# After commits land, detect act/present pending files whose Tracked-by PRN was
# committed since the last rotation (or whose filename was cited in a commit
# body). Surface PENDING_DEMOTE_NEEDED so the shipping session demotes them in
# the same session — closes the stale-pending loop at the SessionEnd end.
# Advisory only: appends to the drift log, never changes exit behaviour.
if [ -d "$CONFIG_REPO/.git" ] && [ -f "$MANAGE_PENDING" ]; then
    _since=$(git -C "$CONFIG_REPO" log --grep 'Auto-sync: session rotation' -1 --format=%H 2>/dev/null)
    [ -z "$_since" ] && _since="HEAD~20"
    _demote=$(bash "$MANAGE_PENDING" --demote-check --since "$_since" --project-dir "$CONFIG_REPO" 2>/dev/null || true)
    if [ -n "$_demote" ]; then
        _demote_line=$(printf '%s' "$_demote" | tr '\n' ';' | sed 's/;*$//; s/;/; /g')
        printf 'PENDING_DEMOTE_NEEDED: %s\n' "$_demote_line" \
            >> "${DRIFT_LOG:-$CONFIG_REPO/.sync-warnings.log}"
    fi
fi

# Phase 0.9 moved to Phase 4 (after commit+push) so mobile gets final file state.

# Clear any previous failure marker on success path
sync_success() {
    rm -f "$FAIL_MARKER"
    _shutdown_done
    exit 0
}

sync_fail() {
    local stage="$1" detail="$2"
    printf 'stage=%s\ntime=%s\ndetail=%s\n' "$stage" "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" "$detail" > "$FAIL_MARKER"
    printf '\r\033[K  Shutdown: failed at %s (see .sync-failed)\n' "$stage" >&2
    exit 0  # Still exit 0 — don't block session end
}

_shutdown_progress "Rotating session..."

# --- Phase 1: Auto-rotate current project's session ---
# If the project has a populated session-context.md, archive it before it goes stale.
# rotate-session.sh validates content and fails safely if template is blank.
#
# No --owner-verified (CFG-666). For a genuine leader the lock was released in
# Phase -1, so rotate-session.sh's foreign-lock guard never fires and the flag
# bought nothing. It only ever mattered when the lock was STILL there — i.e.
# when this session could not prove it owns its own project (a nested CC whose
# role marker wrongly said leader; a degraded release). There the guard decides
# on ownership evidence (CFG-536) instead of a blanket bypass.
_ORIG_ROTATE_OK=1
_ORIG_HELD_BY_OTHER=0
if [[ -f "$ORIGINAL_DIR/session-context.md" && -s "$ORIGINAL_DIR/session-context.md" ]]; then
    _rot1_rc=0
    bash "$ROTATE_SCRIPT" "$ORIGINAL_DIR" 2>/dev/null || _rot1_rc=$?
    if [[ "$_rot1_rc" -eq 3 ]]; then
        # Guard refusal: another live session holds this project although our
        # role marker said leader. The context is intact — leave it, say so.
        echo "$(date -u +'%Y-%m-%d %H:%M:%S UTC') rotate-session refused for $ORIGINAL_DIR: held by another live session although this session's role marker said leader — context left intact" >> "$CONFIG_REPO/.sync-warnings.log"
        _ORIG_ROTATE_OK=0
        _ORIG_HELD_BY_OTHER=1
    elif [[ "$_rot1_rc" -ne 0 ]]; then
        echo "$(date -u +'%Y-%m-%d %H:%M:%S UTC') rotate-session failed for $ORIGINAL_DIR" >> "$CONFIG_REPO/.sync-warnings.log"
        _ORIG_ROTATE_OK=0
    fi
fi

# --- Phase 1.5: Append post-rotation commits for current project ---
# If rotation happened earlier in this session and commits followed, record them.
# Skip when ORIGINAL_DIR == CONFIG_REPO — Phase 3.5 handles it after flock.
# Pre-flock modifications strand uncommitted if another session holds the lock.
_APPEND_SCRIPT="$CONFIG_REPO/setup/scripts/append-post-rotation.sh"
if [[ -f "$_APPEND_SCRIPT" && -f "$ORIGINAL_DIR/.post-rotation-commit" && "$ORIGINAL_DIR" != "$CONFIG_REPO" ]]; then
    bash "$_APPEND_SCRIPT" "$ORIGINAL_DIR" 2>/dev/null || true
fi

# --- Phase 2: Commit session files in current project (if separate from config repo) ---
# Only commits session-related files. Does NOT push (avoids dual-remote/auth issues).
# Skip if rotation failed — don't commit potentially corrupted session data.
if [[ "$_ORIG_ROTATE_OK" -eq 1 && "$ORIGINAL_DIR" != "$CONFIG_REPO" && -d "$ORIGINAL_DIR/.git" ]]; then
    (
        cd "$ORIGINAL_DIR" || exit 0
        # Stage each file separately — git add fails atomically on multi-pathspec
        # if any file is missing, blocking the others from being staged.
        git add session-context.md 2>/dev/null || true
        git add session-history.md 2>/dev/null || true
        git add next-session-task.md 2>/dev/null || true
        git add docs/session-log.md 2>/dev/null || true
        if ! git diff --cached --quiet 2>/dev/null; then
            git commit -m "Auto-sync: session rotation $(date -u +'%Y-%m-%d %H:%M:%S UTC')" 2>/dev/null || true
        fi
    )
fi

_shutdown_progress "Deploying config..."

# --- Phase 3: Config repo sync ---
cd "$CONFIG_REPO" 2>/dev/null || sync_fail "cd" "Config repo not found at $CONFIG_REPO"

# Acquire exclusive lock to prevent parallel session-end races.
# flock -w 30 = wait up to 30s for the lock. A typical shutdown takes ~5-10s.
# Previous: flock -n (non-blocking skip) silently dropped uncommitted work.
exec 9>"$LOCK_FILE"
if ! flock -w 30 9; then
    sync_fail "lock" "Config repo lock held >30s by another session"
fi

# --- CFG-666 / CFG-665: is the config repo held by a DIFFERENT live session? ---
# If it is, everything below that touches the config repo's session files,
# working tree or index is that session's job at its own shutdown: rotation
# (Phase 3), the post-rotation marker (Phase 3.5) and staging/committing. A
# non-empty session-context.md is evidence that somebody is using it, not
# evidence that rotation is due. check_lock comes from session-lock.sh (sourced
# in Phase -1); when it is unavailable, rotate-session.sh's own guard below is
# the fallback — its exit 3 sets the same flag.
_CFG_HELD_BY_OTHER=0
_cfg_held_notice() {
    _shutdown_progress "Config repo is held by another live session — its context and work are left to it."
}
if [[ "$ORIGINAL_DIR" == "$CONFIG_REPO" ]]; then
    # The project IS the config repo: Phase 1's guard verdict is the answer.
    if [[ "$_ORIG_HELD_BY_OTHER" -eq 1 ]]; then
        _CFG_HELD_BY_OTHER=1
        _cfg_held_notice
    fi
elif command -v check_lock >/dev/null 2>&1; then
    _cl_rc=0
    check_lock "$CONFIG_REPO" >/dev/null 2>&1 || _cl_rc=$?
    # 2 = another live session on this machine, 3 = another machine (unverifiable)
    if [[ "$_cl_rc" -eq 2 || "$_cl_rc" -eq 3 ]]; then
        _CFG_HELD_BY_OTHER=1
        _cfg_held_notice
    fi
fi

# Auto-rotate config repo's own session (if different from original project).
# NEVER with --owner-verified — and it is not used in Phase 1 either (CFG-666).
# An earlier revision of this comment called the flag "legitimate in Phase 1";
# that was wrong and is retracted, see the Phase 1 note above: for a genuine
# leader the lock is already released in Phase -1, so the flag bought nothing
# there, and it only ever took effect for a session that could NOT prove
# ownership. It is doubly wrong here, where CONFIG_REPO is a different repo this
# session has proved nothing about. Passing
# it disarmed rotate-session.sh's foreign-lock guard (CFG-452) at the one call
# site where the caller is by definition foreign — another project's shutdown blanked
# a live cfg session's context mid-work (a410acdc, 2026-09-21 12:52:32).
if [[ "$_CFG_HELD_BY_OTHER" -eq 0 && "$ORIGINAL_DIR" != "$CONFIG_REPO" && -f "$CONFIG_REPO/session-context.md" && -s "$CONFIG_REPO/session-context.md" ]]; then
    _rot_rc=0
    bash "$ROTATE_SCRIPT" "$CONFIG_REPO" 2>/dev/null || _rot_rc=$?
    if [[ "$_rot_rc" -eq 3 ]]; then
        # rotate-session.sh's guard refused: a foreign live session holds the
        # config repo. Not a failure — the owner rotates its own context.
        _CFG_HELD_BY_OTHER=1
        _cfg_held_notice
    elif [[ "$_rot_rc" -ne 0 ]]; then
        echo "$(date -u +'%Y-%m-%d %H:%M:%S UTC') rotate-session failed for $CONFIG_REPO" >> "$CONFIG_REPO/.sync-warnings.log"
    fi
fi

# Deploy repo → live (v1.0: repo is sole source of truth, no more collect)
# Deploy failure is non-fatal for the commit path — rotation data must still be
# committed and pushed. Deploy will re-run at next session start anyway.
DEPLOY_OUTPUT=$(bash "$CONFIG_REPO/sync.sh" deploy 2>&1)
if [ $? -ne 0 ]; then
    printf '%s sync.sh deploy failed (non-fatal): %s\n' \
        "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" \
        "$(echo "$DEPLOY_OUTPUT" | tail -1)" \
        >> "$CONFIG_REPO/.sync-warnings.log"
fi

# --- Phase 3.5: Detect post-rotation commits and append to session-log ---
# Extracted to append-post-rotation.sh for testability. Fails silently on error.
# Skipped when another live session holds the config repo (CFG-665): the script
# CONSUMES .post-rotation-commit, and that marker belongs to the owner.
_APPEND_SCRIPT="$CONFIG_REPO/setup/scripts/append-post-rotation.sh"
if [[ "$_CFG_HELD_BY_OTHER" -eq 0 && -f "$_APPEND_SCRIPT" ]]; then
    bash "$_APPEND_SCRIPT" "$CONFIG_REPO" 2>/dev/null || true
fi

# Stage only expected directories and files — avoid staging unintended changes.
# ONE `git add` PER PATH: a multi-pathspec add fails atomically when any single
# pathspec matches nothing, and this repo has no projects/ dir, so the former
# `git add docs/ projects/ cross-project/` staged nothing on any real machine
# (measured 2026-09-23: "fatal: pathspec 'projects/' did not match any files";
# docs/session-log.md is absent from a410acdc although rotation had written it).
#
# CFG-665: when a DIFFERENT live session holds the config repo, stage NOTHING
# and commit nothing — whatever is dirty or already staged is that session's
# in-progress work. git-sweep-guard.sh cannot intervene here (it is a
# PreToolUse hook on Bash, and this `git add` is not a Bash tool call), so the
# owner check has to live in the staging itself. The breadth of the directory
# staging is unchanged for every unheld shutdown.
if [[ "$_CFG_HELD_BY_OTHER" -eq 0 ]]; then
    for _p in session-context.md session-history.md next-session-task.md \
              docs/ projects/ cross-project/ \
              global/ backlog.md registry.md template-sync-manifest.md; do
        git add -- "$_p" 2>/dev/null || true
    done
fi
# Held by another session, or nothing new staged: still check for unpushed
# commits before exiting (pushing existing commits touches no working file).
if [[ "$_CFG_HELD_BY_OTHER" -eq 1 ]] || git diff --cached --quiet 2>/dev/null; then
    # No new changes to commit — but are there unpushed commits?
    PUSH_REMOTE="origin"
    if [ -f "$CONFIG_REPO/.push-filter.conf" ]; then
        PR=$(grep '^private_remote=' "$CONFIG_REPO/.push-filter.conf" 2>/dev/null | head -1 | cut -d= -f2 | xargs)
        [ -n "$PR" ] && PUSH_REMOTE="$PR"
    fi
    DEFAULT_BRANCH=$(git symbolic-ref "refs/remotes/$PUSH_REMOTE/HEAD" 2>/dev/null | sed "s|refs/remotes/$PUSH_REMOTE/||")
    [ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"
    UNPUSHED=$(git log "$PUSH_REMOTE/$DEFAULT_BRANCH..HEAD" --oneline 2>/dev/null)
    if [ -n "$UNPUSHED" ]; then
        git push "$PUSH_REMOTE" "$DEFAULT_BRANCH" 2>/dev/null \
            || sync_fail "push" "git push failed (unpushed commits exist)"
    fi
    sync_success
fi

# Secret scan: check staged diff for obvious secret patterns before committing
STAGED_DIFF=$(git diff --cached 2>/dev/null)
SECRET_PATTERNS='sk-ant-[A-Za-z0-9-]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|AIzaSy[A-Za-z0-9_-]{33}|ghp_[A-Za-z0-9]{36,}|gho_[A-Za-z0-9]{36,}|xoxb-[A-Za-z0-9-]+|xoxp-[A-Za-z0-9-]+|password\s*[:=]|secret\s*[:=]|private_key\s*[:=]|-----BEGIN RSA|-----BEGIN PRIVATE KEY|(key|token|secret)\s*[:=]\s*[A-Za-z0-9+/]{40,}={0,2}'
SECRET_HITS=$(printf '%s' "$STAGED_DIFF" | grep -E "$SECRET_PATTERNS" 2>/dev/null | grep '^+' | grep -v '^+++' || true)
if [ -n "$SECRET_HITS" ]; then
    # Identify which staged files contain the suspicious content (newline-separated)
    SUSPICIOUS_FILES=$(git diff --cached --name-only 2>/dev/null | while read -r f; do
        if git diff --cached -- "$f" 2>/dev/null | grep -qE "$SECRET_PATTERNS"; then
            echo "$f"
        fi
    done)
    if [ -n "$SUSPICIOUS_FILES" ]; then
        # Unstage each suspicious file individually (bash 3.2 compat — no mapfile)
        while IFS= read -r _sf; do
            [ -n "$_sf" ] && git restore --staged "$_sf" 2>/dev/null || true
        done <<< "$SUSPICIOUS_FILES"
        printf 'AUTO-SYNC WARNING: Possible secrets detected in staged files: %s\n' \
            "${SUSPICIOUS_FILES//$'\n'/ }" >> "$CONFIG_REPO/.sync-warnings.log"
        printf 'time=%s\n' "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" >> "$CONFIG_REPO/.sync-warnings.log"
        # If nothing left staged, exit cleanly (no commit needed)
        git diff --cached --quiet 2>/dev/null && sync_success
    fi
fi

_shutdown_progress "Committing & pushing..."

# Commit
git commit -m "Auto-sync: $(date -u +'%Y-%m-%d %H:%M:%S UTC')" 2>/dev/null \
    || sync_fail "commit" "git commit failed"

# Push (auto-detect default branch: main or master)
# Respect dual-remote projects: push to private remote, never public
PUSH_REMOTE="origin"
if [ -f "$CONFIG_REPO/.push-filter.conf" ]; then
    PR=$(grep '^private_remote=' "$CONFIG_REPO/.push-filter.conf" 2>/dev/null | head -1 | cut -d= -f2 | xargs)
    [ -n "$PR" ] && PUSH_REMOTE="$PR"
fi
DEFAULT_BRANCH=$(git symbolic-ref "refs/remotes/$PUSH_REMOTE/HEAD" 2>/dev/null | sed "s|refs/remotes/$PUSH_REMOTE/||")
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"
# Capture stderr rather than discarding it: this push can be refused by the repo's
# pre-push leak guard, and "git push failed (network? auth?)" actively misdirects
# when the real answer is "personal data was found and publication was prevented".
_PUSH_ERR="$(git push "$PUSH_REMOTE" "$DEFAULT_BRANCH" 2>&1 >/dev/null)" \
    || sync_fail "push" "git push failed: ${_PUSH_ERR:-no stderr}"

# Phase 3 deploy (above) already ensures deployed state matches repo.
# Phase 3.5 (redundant deploy) removed in v1.0 — repo is sole authority.

# --- Phase 4: Auto-refresh mobile repo snapshots ---
# Runs AFTER commit+push so mobile gets final file state (dashboard-cache, inbox, etc.).
# Moved from Phase 0.9 — running before session rotation caused persistent staleness.
_MOBILE_DEPLOY="$CONFIG_REPO/setup/scripts/mobile-deploy.sh"
if [ -f "$_MOBILE_DEPLOY" ] && [ -d "$MOBILE_REPO" ]; then
    _shutdown_progress "Refreshing mobile repo..."
    bash "$_MOBILE_DEPLOY" --config-repo "$CONFIG_REPO" --target "$MOBILE_REPO" 2>/dev/null || true
    # Commit and push mobile changes — without this, snapshots stay dirty
    # and the next session's check reports eternal staleness.
    git -C "$MOBILE_REPO" add -A context/ 2>/dev/null || true
    if ! git -C "$MOBILE_REPO" diff --cached --quiet 2>/dev/null; then
        git -C "$MOBILE_REPO" commit -m "Auto-sync: mobile context snapshots" 2>/dev/null || true
        git -C "$MOBILE_REPO" push origin main 2>/dev/null || true
    fi
    # Clear mobile staleness warnings from drift log — Phase 0.7 ran before this
    # refresh, so mobile appeared stale. Now it's fresh. Remove stale warnings.
    if [ -f "$DRIFT_LOG" ]; then
        sed -i '/mobile repo is stale/d; /Checking mobile/d' "$DRIFT_LOG"
        # Remove log if now empty (only whitespace/blank lines remain)
        if [ ! -s "$DRIFT_LOG" ] || ! grep -q '[^[:space:]]' "$DRIFT_LOG" 2>/dev/null; then
            rm -f "$DRIFT_LOG"
        fi
    fi
fi

# --- Phase 5: deployment-local shutdown steps (optional, CFG-676) ---
# Steps that belong to ONE deployment — pushing a credential blob to a specific
# host, refreshing a machine only this fleet has — live in
# setup/scripts/config-auto-sync-local.sh (manifest: Intentionally Not
# Propagated), never in this file. This hook is Category 1: template-push copies
# it verbatim into every downstream fleet, which is exactly what a host name or a
# persona name here would prevent — and did, stranding the CFG-665/666 owner
# guard above on one machine. The shim runs as a subprocess, after commit+push,
# with CONFIG_REPO and ORIGINAL_DIR in its environment; its stdout is dropped,
# its stderr (progress lines) reaches the user, and its exit status never blocks
# shutdown. Absent shim = nothing to do.
_LOCAL_SHIM="$CONFIG_REPO/setup/scripts/config-auto-sync-local.sh"
if [ -f "$_LOCAL_SHIM" ]; then
    CONFIG_REPO="$CONFIG_REPO" ORIGINAL_DIR="$ORIGINAL_DIR" bash "$_LOCAL_SHIM" >/dev/null || true
fi

sync_success
