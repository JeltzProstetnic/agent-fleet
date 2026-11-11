#!/usr/bin/env bash
# Auto-sync config repo on session end.
# Runs as a SessionEnd hook — silent, zero context cost.
#
# What this hook does (in order):
# 1. Auto-rotate the CURRENT PROJECT's session (if it has session-context.md)
# 2. Commit session files in current project (if different from the config repo)
# 3. Auto-rotate the config repo's own session
# 4. Deploy repo → live, commit config repo changes, and push
#    Everything that writes to, deletes from, deploys or publishes the config
#    repo's working tree is skipped when a DIFFERENT live session holds that
#    repo (CFG-666 / CFG-665 / CFG-965): the mobile collect (Phase 0), the
#    pending auto-clean (0.6), the inbox archive (0.65), the T2 marker (0.75),
#    the template propagation (0.8), rotation, deploy, staging and commit (3).
#    They are that session's own shutdown work; touching them from here blanked
#    and swept a live session, pushed its half-built files to the public
#    template, and deployed its half-edited hooks over the live ~/.claude. The
#    verdict and its fail-closed rules live in lib-cfg-held.sh.
#
# On failure: writes a marker to .sync-failed
# The SessionStart hook (config-check.sh) reads this marker and alerts the user.

# Source portable wrappers (provides _readlink_f for macOS compat)
source "$(dirname "${BASH_SOURCE[0]}")/lib-portable.sh" 2>/dev/null || true
# In-place sed for the drift-log strips: lib-portable's _sed_i handles BSD sed;
# without the library, fall back to GNU syntax rather than fail the strip.
command -v _sed_i >/dev/null 2>&1 || _sed_i() { sed -i "$@"; }

# Config repo detection — canonical source in lib-detect-repo.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-detect-repo.sh" 2>/dev/null || true
CONFIG_REPO="$(_detect_config_repo)"
FAIL_MARKER="$CONFIG_REPO/.sync-failed"
LOCK_FILE="$CONFIG_REPO/.sync-lock"
# Lock waits (seconds) and the ONE deadline they share. The whole SessionEnd
# hook is capped by settings.json's CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS
# (60 s), and that cap kills the hook SILENTLY — no .sync-failed, no Phase 4/5,
# a kill mid-commit can leave .git/index.lock. So no wait here may run past
# the cap: each is min(its budget, _HOOK_CAP − elapsed since the hook started),
# never below 0 (a 0 is a non-blocking try). Phase 0.8's budget is 20 s and it
# DEFERS on timeout (free: the next shutdown pushes); Phase 3's is 45 s and it
# loses its commit on timeout (expensive), so it gets the larger share — but
# whatever is left of the cap bounds both, so sync_fail "lock" is always
# reached, visibly, before the cap (reviewer R2: the two budgets alone added up
# to 65 s). _HOOK_CAP is 55 s: 5 s of headroom under the 60 s cap for the
# phases after Phase 3's wait to fail cleanly. CFG_AUTO_SYNC_LOCK_WAIT
# overrides both budgets and CFG_AUTO_SYNC_HOOK_CAP the cap (tests).
_T0=$SECONDS
_HOOK_CAP="${CFG_AUTO_SYNC_HOOK_CAP:-55}"
_TPL_LOCK_WAIT="${CFG_AUTO_SYNC_LOCK_WAIT:-20}"
_LOCK_WAIT="${CFG_AUTO_SYNC_LOCK_WAIT:-45}"
# Phase 3's wait also keeps a RESERVE: the work after it (deploy, commit, push,
# mobile, shim) needs ~10-15 s of cap itself, and a wait that ends exactly at
# the deadline would hand it nothing (reviewer: lock busy 50 s ⇒ Phase 3 began
# at +50 s with 10 s left). Phase 0.8 keeps no reserve — its timeout is a free
# deferral and what follows it is cheap.
_P3_RESERVE=15
_lock_budget() {   # <budget> [reserve] → seconds this wait may still take: min(budget, cap − elapsed − reserve), floored at 0
    local left=$(( _HOOK_CAP - (SECONDS - _T0) - ${2:-0} ))
    (( left < 0 )) && left=0
    (( $1 < left )) && echo "$1" || echo "$left"
}
ROTATE_SCRIPT="$CONFIG_REPO/setup/scripts/rotate-session.sh"
CLEAN_PERMS_SCRIPT="$CONFIG_REPO/setup/scripts/clean-permissions.sh"

# Capture the original working directory (the project the user was in)
ORIGINAL_DIR="$(pwd)"

# --- Shutdown progress indicator (CFG-340) ---
# Writes to stderr so the user sees progress while hooks run after /exit.
# Each phase gets its own line (no \r overwrite) so all steps remain visible.
_shutdown_progress() { printf '  \033[38;5;243m%s\033[0m\n' "$1" >&2; }
_shutdown_done() { printf '  \033[38;5;243mShutdown complete.\033[0m\n' >&2; }

# This hook's stdin JSON carries the Claude Code session id. It binds lock ownership in
# Phase -1 (CFG-452: an inherited AFLEET_SESSION_ID does not prove ownership, this id
# does) and names this session's idle waiter in Phase -4. Empty on any failure.
_CC_SID=""
source "$(dirname "${BASH_SOURCE[0]}")/lib-hook-stdin.sh" 2>/dev/null || true
if command -v read_cc_session_id >/dev/null 2>&1; then
    _CC_SID="$(read_cc_session_id)"
fi

# The owner check for the config repo (CFG-665/666/965) lives in lib-cfg-held.sh,
# sourced from this hook's own directory like the libraries above. Unlike them it
# is load-bearing, so a missing or unloadable copy FAILS CLOSED: these stubs
# treat the config repo as held and say why, instead of letting every
# cfg-touching phase run unguarded. The library redefines all of them. One
# exception, mirrored from the library's own shortcut (CFG-965 R4): the project
# IS the config repo and no lock is left — a genuine leader released its own in
# Phase -1 — is "not held" without asking, library or no library; otherwise the
# owner's own shutdown would never rotate its context or deploy while the
# library is missing.
_CFG_HELD_BY_OTHER=0
_CFG_HELD_RECORDED=0
_CFG_HELD_UNKNOWN_RECORD=""
_CFG_DRIFT_LOG_RESET_PENDING=0
_cfg_held_probe() {
    [[ "$ORIGINAL_DIR" == "$CONFIG_REPO" && ! -f "$CONFIG_REPO/.claude/.session-lock" ]] && return 0
    _CFG_HELD_BY_OTHER=1
    [[ "$_CFG_HELD_RECORDED" -eq 1 ]] && return 0
    _CFG_HELD_RECORDED=1
    _shutdown_progress "Owner-check library missing (lib-cfg-held.sh) — config repo treated as held."
    _CFG_HELD_UNKNOWN_RECORD="$(date -u +'%Y-%m-%d %H:%M:%S UTC') lib-cfg-held.sh missing or unloadable beside $(dirname "${BASH_SOURCE[0]}")/config-auto-sync.sh — config repo treated as held (fail closed): rotation, deploy, propagation and commit skipped; redeploy the hooks (sync.sh deploy)"
}
_cfg_held_flush_record() {   # append the stashed record to the drift log (after Phase 0.7 has rewritten it)
    _CFG_DRIFT_LOG_RESET_PENDING=0
    [ -n "$_CFG_HELD_UNKNOWN_RECORD" ] || return 0
    echo "$_CFG_HELD_UNKNOWN_RECORD" >> "$CONFIG_REPO/.sync-warnings.log" 2>/dev/null || true
    _CFG_HELD_UNKNOWN_RECORD=""
}
_cfg_held_notice() { :; }
_cfg_defer_audit() { :; }
source "$(dirname "${BASH_SOURCE[0]}")/lib-cfg-held.sh" 2>/dev/null || true

# --- Phase -4: silence this session's idle waiter (CFG-806) — before anything else ---
# afd-idle-wake.sh (Stop hook, asyncRewake, CFG-777/797) polls for up to 12 h and exits 2
# to wake the model on a Telegram message or a new inbox item. Claude Code is still alive
# while this hook runs (/exit, /clear — up to CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS), so a
# wake now would open a new turn in a session the user has already left. Mark the session
# as ending (the waiter checks the marker before every wake and leaves every message for
# the next session) and signal the waiter — but only a pid that really is an
# afd-idle-wake.sh: a pidfile left by a killed waiter may name a reused pid.
_silence_idle_waiter() {
    local dir="${AFD_MSG_DIR:-$HOME/.afd-msgs}/.idle" key pid
    [ -n "$_CC_SID" ] && [ -d "$dir" ] || return 0
    key="${_CC_SID//[^A-Za-z0-9_-]/_}"
    : > "$dir/$key.ending" 2>/dev/null || true
    pid="$(cat "$dir/$key.pid" 2>/dev/null)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && ps -o args= -p "$pid" 2>/dev/null | grep -q 'afd-idle-wake'; then
        kill -TERM "$pid" 2>/dev/null || true
    fi
    # A marker outlives its waiter only when the waiter was already gone; keep the dir clean.
    find "$dir" -maxdepth 1 -name '*.ending' -mmin +120 -delete 2>/dev/null || true
}
_silence_idle_waiter

# --- Phase -3: expire artifact-publish consent (SCI-34) ---
# cloud-publish-guard.sh unblocks publishing while <project>/.claude/.artifact-consent
# exists. That consent is per-SESSION by design: a marker surviving into tomorrow means
# a later session silently inherits permission to send the user's content to claude.ai,
# which is the failure this whole guard exists to prevent. Clearing it here is what makes
# "per-session" true rather than aspirational.
rm -f "$ORIGINAL_DIR/.claude/.artifact-consent" 2>/dev/null || true
rm -f "${CLAUDE_PROJECT_DIR:-$ORIGINAL_DIR}/.claude/.artifact-consent" 2>/dev/null || true
rm -f "$CONFIG_REPO/.claude/.artifact-consent" 2>/dev/null || true
# Same per-session rule for cloud-routine-guard.sh (CFG-842).
rm -f "$ORIGINAL_DIR/.claude/.cloud-routine-consent" 2>/dev/null || true
rm -f "${CLAUDE_PROJECT_DIR:-$ORIGINAL_DIR}/.claude/.cloud-routine-consent" 2>/dev/null || true
rm -f "$CONFIG_REPO/.claude/.cloud-routine-consent" 2>/dev/null || true

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
# does not. _CC_SID was read from this hook's stdin JSON above (Phase -4); stdin
# is consumed, so it is read exactly once.

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

# --- Phase -0.5: Reap finished GPI ops (CFG-363) — leader only (shared statusline) ---
# Prevents stale statusline entries. State lives in $HOME/.claude/.gpi-state.json, which is
# MACHINE-global while "leader" is per PROJECT: other projects' live jobs are registered in
# the same file. So only a leader may touch it, and even a leader removes only what is
# provably over — completed ops and ops whose recorded tmux session is gone (`--dead`).
# CFG-863: `clear --all` here wiped another project's four running tmux ops when a sibling
# project's session ended (2026-10-28); the statusline then showed nothing running.
_GPI_SCRIPT="$CONFIG_REPO/setup/scripts/gpi.sh"
if [ -f "$_GPI_SCRIPT" ]; then
    bash "$_GPI_SCRIPT" clear --dead 2>/dev/null || true
fi

# Release server lock if session ID is available (CFG-101) — leader only.
if [ -n "$_LOCK_SID" ]; then
    _AFD_LIB="$CONFIG_REPO/afd/lib/afd-lib.sh"
    if [ -f "$_AFD_LIB" ] && [ -n "${AFD_TOKEN:-}" ]; then
        . "$_AFD_LIB"
        afd_lock_release "$(basename "$ORIGINAL_DIR")" 2>/dev/null || true
    fi
fi

# --- CFG-666 / CFG-665 / CFG-965: is the config repo held by a DIFFERENT live session? ---
# Decided ONCE, here — before any phase touches the config repo's working tree
# (Phase 0 mobile collect, 0.6 pending auto-clean, 0.65 inbox archive, 0.75 T2
# marker, 0.8 template propagation, 3 rotate/deploy/stage/commit) — and asked
# once more under each lock (Phase 0.8, Phase 3) for a session that arrives in
# between. The probe only ever turns "not held" into "held", and a held repo is
# not probed again. check_lock comes from session-lock.sh (sourced in Phase -1)
# or, when that working-tree copy has none, from HEAD's copy (SF-1); anything
# but a clean 0/1 is held. Verdict, records, fail-closed rules: lib-cfg-held.sh.
# (CFG-665, measured twice 2026-11-11: the verdict used to be taken in Phase 3,
# after Phase 0.8 had already pushed a live cfg session's uncommitted files to
# agent-fleet — c8e613c, 67df308.) Phase 0.7 below rewrites the drift log from
# scratch, so an "unknown" record taken here is stashed and appended after it.
_CFG_DRIFT_LOG_RESET_PENDING=1
_cfg_held_probe

# --- Phase 0: Collect mobile outbox tasks ---
# Skipped while another live session holds the config repo (CFG-965): --collect
# appends to cross-project/inbox.md and docs/mobile-session-log.md in the cfg
# WORKING TREE and resets the phone outbox. Nothing is lost by waiting — the
# outbox keeps its tasks until the next unheld shutdown, and the holder is told
# mid-session (MOBILE_DATA:) and collects them itself.
MOBILE_REPO="$HOME/agent-fleet-mobile"
if [ -f "$MOBILE_REPO/inbox/outbox.md" ]; then
    MOBILE_TASKS=$(grep -c '^\- \[ \]' "$MOBILE_REPO/inbox/outbox.md" 2>/dev/null || echo "0")
    if [ "$MOBILE_TASKS" -gt 0 ] 2>/dev/null && [ "$_CFG_HELD_BY_OTHER" -eq 1 ]; then
        _cfg_defer_audit MOBILE_COLLECT_DEFERRED "config repo held by another live session — $MOBILE_TASKS phone outbox task(s) left for its holder or the next unheld shutdown"
    elif [ "$MOBILE_TASKS" -gt 0 ] 2>/dev/null; then
        bash "$CONFIG_REPO/setup/scripts/mobile-deploy.sh" --collect \
            --config-repo "$CONFIG_REPO" \
            --target "$MOBILE_REPO" 2>/dev/null || true
    fi
fi

# --- Phase 0.5: Clean stale permissions blocks ---
# "Always allow" clicks create project-level permissions blocks that shadow global
# permissions. Clean them before auto-sync to keep things tidy for the next session.
# Not gated on the held verdict (CFG-965, documented): the sweep is $HOME-wide
# over every project's .claude/settings.local.json — gitignored, never part of
# the config repo's working tree — backs up what it removes, spares a block
# marked .permissions-authored, and runs with exactly the same scope from every
# SessionStart (checks/04-auto-fix.sh, Check 4.1). Whether the config repo is
# held changes nothing about what it touches or who else already touches it.
bash "$CLEAN_PERMS_SCRIPT" 2>/dev/null || true

# --- Phase 0.55: Age out the fleet's scratch (CFG-851) — detached, the first run is large ---
TMP_SWEEP_SCRIPT="$CONFIG_REPO/setup/scripts/tmp-sweep.sh"
[ -f "$TMP_SWEEP_SCRIPT" ] && setsid bash "$TMP_SWEEP_SCRIPT" </dev/null >/dev/null 2>&1 &

# --- Phase 0.6: Auto-clean completed pending files ---
# Delete pending files whose tracked backlog items are all [x] done.
# Skipped while another live session holds the config repo (CFG-965): this
# DELETES docs/pending-*.md from the cfg working tree — files the holder may be
# demoting, editing or about to commit. The holder's own shutdown cleans them.
MANAGE_PENDING="$CONFIG_REPO/setup/scripts/manage-pending.sh"
if [ "$_CFG_HELD_BY_OTHER" -eq 1 ]; then
    _cfg_defer_audit PENDING_AUTO_CLEAN_DEFERRED "config repo held by another live session — docs/pending-*.md left to its holder"
elif [ -f "$MANAGE_PENDING" ]; then
    bash "$MANAGE_PENDING" --auto-clean --project-dir "$CONFIG_REPO" 2>/dev/null || true
fi

# --- Phase 0.65: Auto-archive completed cross-project inbox items (CFG-134) ---
# Move [x] completed items from cross-project/inbox.md → inbox-archive.md so the
# inbox stays lean. Only from the config repo's own shutdown (it owns cross-project/*
# — cross-project write boundary); no-op if no completed items. Runs before the
# config-repo commit phase so the archived state is committed this session.
# CFG-965: and not from a nested CC mis-marked leader in the config repo while
# the real leader's lock is still there (_CFG_HELD_BY_OTHER) — the one cfg
# shutdown that is not the holder's, and inbox.md is the holder's tree.
if [[ "$ORIGINAL_DIR" == "$CONFIG_REPO" && "$_CFG_HELD_BY_OTHER" -eq 0 ]]; then
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
    # CFG-965: while another live session holds the config repo, every
    # "<file>: drifted (repo ≠ deployed)" line — and every "<file>: not
    # deployed" line, the holder's NEW, undeployed file — is that session's
    # uncommitted tree versus the live copy: work in progress, not drift. The
    # next SessionStart would surface them as "fix with sync.sh deploy", the
    # deploy Phase 3 rightly refuses. Those lines are dropped before the log is
    # written, and so is the "N issue(s) found" summary whose N counted them;
    # every other warning stays; a log that would be left empty is not written
    # at all; the drop is one audit line, never drift.
    if [ "$_CFG_HELD_BY_OTHER" -eq 1 ] && printf '%s\n' "$DRIFT_ISSUES" | grep -q -e 'repo ≠ deployed' -e ': not deployed'; then
        _drift_dropped=$(printf '%s\n' "$DRIFT_ISSUES" | grep -c -e 'repo ≠ deployed' -e ': not deployed' || true)
        DRIFT_ISSUES=$(printf '%s\n' "$DRIFT_ISSUES" | grep -v -e 'repo ≠ deployed' -e ': not deployed' -e 'issue(s) found' || true)
        printf '%s\n' "$DRIFT_ISSUES" | grep -q '[^[:space:]]' || DRIFT_ISSUES=""
        _cfg_defer_audit DRIFT_CHECK_DEFERRED "config repo held by another live session — $_drift_dropped repo≠deployed/not-deployed line(s) are its holder's uncommitted work, not drift; dropped from the drift log with the issue summary"
    fi
    if [ -n "$DRIFT_ISSUES" ]; then
        printf '%s\n' "$DRIFT_ISSUES" > "$DRIFT_LOG"
    else
        rm -f "$DRIFT_LOG"
    fi
fi
# The early probe's "unknown" record (CFG-965), if any, is appended only now:
# the check above rewrites the drift log from scratch and would have erased it.
_cfg_held_flush_record

# --- Phase 0.75: T2 deployment-critical edit detection (CFG-326) ---
# Check if T2 files were modified this session. If so, warn that E2E tests should be run.
# Does NOT block shutdown — informational only, surfaced at next session start.
# Skipped while another live session holds the config repo (CFG-965): the diff
# against HEAD is that session's unfinished work, and the marker would report
# it to the next SessionStart as T2 edits to verify. Left exactly as it is —
# not rewritten, not removed; the holder's own shutdown computes it.
T2_MARKER="$CONFIG_REPO/.t2-edits-pending"
if [ "$_CFG_HELD_BY_OTHER" -eq 1 ]; then
    _cfg_defer_audit T2_CHECK_DEFERRED "config repo held by another live session — .t2-edits-pending left as it was"
elif [ -d "$CONFIG_REPO/.git" ]; then
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
# CFG-965: under the config repo lock. Phase 0.8 ran outside any lock, so two
# shutdowns ending together propagated in parallel — two template-push runs
# into one ~/agent-fleet index, racing the push. It now takes the same
# .sync-lock as Phase 3 (fd 8, released at the end of this phase), so a
# template push also waits for another shutdown's Phase 3 commit and sees a
# settled tree. A busy or unwritable lock DEFERS the push — the drift stays and
# the next shutdown pushes it — rather than failing the shutdown or touching
# the failure streak. The re-probe under the lock closes the gap between the
# early verdict and the copy.
_TPL_LOCKED=0
if [ -f "$_TPL_SCRIPT" ] && [ -d "$_TPL_DIR/.git" ] && [ "$_CFG_HELD_BY_OTHER" -eq 0 ]; then
    _tpl_lock_why="lock file $LOCK_FILE not writable"
    if ( : >> "$LOCK_FILE" ) 2>/dev/null; then
        exec 8>"$LOCK_FILE"
        _tpl_wait=$(_lock_budget "$_TPL_LOCK_WAIT")
        if flock -w "$_tpl_wait" 8; then
            _TPL_LOCKED=1
            _cfg_held_probe
        else
            exec 8>&-
            _tpl_lock_why="config repo lock busy for ${_tpl_wait}s (another shutdown in progress; budget ${_TPL_LOCK_WAIT}s, hook cap ${_HOOK_CAP}s)"
        fi
    fi
    if [ "$_TPL_LOCKED" -eq 0 ]; then
        _shutdown_progress "Template propagation deferred — $_tpl_lock_why."
        _cfg_defer_audit TEMPLATE_PUSH_DEFERRED "$_tpl_lock_why — propagation left to the next shutdown"
    fi
fi
if [ -f "$_TPL_SCRIPT" ] && [ -d "$_TPL_DIR/.git" ] && [ "$_CFG_HELD_BY_OTHER" -eq 1 ]; then
    # CFG-665: template-push copies the config repo's WORKING TREE — another
    # live session's uncommitted, half-built files included — into the PUBLIC
    # template and pushes it. The owner propagates at its own shutdown. Not
    # even the dry-run runs: its exit code is a verdict that writes
    # .template-push-failed, and that streak is the owner's too.
    # Recorded in an audit log, NOT in the drift log: checks/04-auto-fix.sh
    # surfaces every line of .sync-warnings.log at the next SessionStart of ANY
    # project as "propagation drift … fix with sync.sh deploy" — wrong advice,
    # and with a cfg session live most of the day it would fire on most shutdowns.
    _shutdown_progress "Template propagation deferred — config repo held by another live session."
    _cfg_defer_audit TEMPLATE_PUSH_DEFERRED "config repo held by another live session — its owner propagates at its own shutdown"
elif [ "$_TPL_LOCKED" -eq 1 ]; then
    # CFG-431: gate on REAL drift. The dry-run reports "Would copy/sanitize" only
    # for files that differ from the template (byte-identical targets print
    # "Identical:"), so the count is the number of files a push would change —
    # it used to be every manifest file, and Phase 0.8 pushed on every shutdown.
    # Two more reasons to run with zero drift: agent-fleet still holds a commit
    # the last push never delivered, or the last run left a failure marker that
    # only a clean run may clear. The dry-run output is kept: with no push it is
    # also where the Cat-3 detection below reads its Flag-only lines.
    # CFG-613 / CFG-431: the dry-run's EXIT CODE is kept too. The hard aborts
    # (1: manifest coverage gap, empty personal_patterns, dirty template at
    # preflight) and a run that holds every candidate (3) print no "Would copy"
    # line. With the exit code thrown away those failures wrote no marker and
    # advanced no streak - the commonest hard failure was the one that never
    # escalated. When no real pass follows, the dry-run IS the verdict; it is
    # recorded through the same marker path below.
    _TPL_DRY=$(bash "$_TPL_SCRIPT" --dry-run 2>&1); _TPL_DRY_RC=$?
    _TPL_DRIFT=$(printf '%s\n' "$_TPL_DRY" | grep -c 'Would copy\|Would sanitize' || true)
    _TPL_UNPUSHED=$(git -C "$_TPL_DIR" log '@{u}..HEAD' --oneline 2>/dev/null | grep -c . || true)
    _TPL_OUT="$_TPL_DRY"; _TPL_RC=$_TPL_DRY_RC; _TPL_RAN=0
    if [ "$_TPL_DRIFT" -gt 0 ] || [ "$_TPL_UNPUSHED" -gt 0 ] || [ -f "$_TPL_FAIL_MARKER" ]; then
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
        _TPL_RAN=1
    fi
    if [ "$_TPL_RC" -ne 0 ]; then
        # The real pass's exit code when one ran, the dry-run's otherwise.
        # CFG-613: keep the STREAK across failures — when it began and how long it
        # is — so SessionStart (checks/08) can name the age. Overwriting it made six
        # dead days read like one bad night. A pre-CFG-613 marker (time= only) is
        # carried forward as the streak's first failure. Fields stop at output_tail=.
        _tpl_now=$(date -u +'%Y-%m-%d %H:%M:%S UTC')
        _tpl_field() { awk -v k="$1" '/^output_tail=/{exit} index($0, k "=")==1 {print substr($0, length(k)+2); exit}' "$_TPL_FAIL_MARKER" 2>/dev/null; }
        _tpl_first="" _tpl_epoch="" _tpl_n=0
        if [ -f "$_TPL_FAIL_MARKER" ]; then
            _tpl_first=$(_tpl_field first_failed)
            _tpl_epoch=$(_tpl_field first_failed_epoch)
            _tpl_n=$(_tpl_field consecutive)
            [ -n "$_tpl_first" ] || _tpl_first=$(_tpl_field time)
            case "$_tpl_n" in ''|*[!0-9]*) _tpl_n=1 ;; esac
            case "$_tpl_epoch" in
                ''|*[!0-9]*) _tpl_epoch=$(date -u -d "$_tpl_first" +%s 2>/dev/null \
                               || date -j -u -f '%Y-%m-%d %H:%M:%S UTC' "$_tpl_first" +%s 2>/dev/null \
                               || date +%s) ;;
            esac
        fi
        printf 'time=%s\nfirst_failed=%s\nfirst_failed_epoch=%s\nconsecutive=%d\nexit_code=%d\ndrift_files=%d\noutput_tail=%s\n' \
            "$_tpl_now" \
            "${_tpl_first:-$_tpl_now}" \
            "${_tpl_epoch:-$(date +%s)}" \
            "$((_tpl_n + 1))" \
            "$_TPL_RC" \
            "$_TPL_DRIFT" \
            "$(echo "$_TPL_OUT" | tail -10)" \
            > "$_TPL_FAIL_MARKER"
        unset -f _tpl_field
        printf 'TEMPLATE_PUSH_FAILED: exit=%d drift=%d consecutive=%d since %s (see .template-push-failed)\n' \
            "$_TPL_RC" "$_TPL_DRIFT" "$((_tpl_n + 1))" "${_tpl_first:-$_tpl_now}" \
            >> "${DRIFT_LOG:-$CONFIG_REPO/.sync-warnings.log}"
    elif [ "$_TPL_RAN" -eq 1 ]; then
        # Success: clear any prior failure marker
        rm -f "$_TPL_FAIL_MARKER"
        echo "$_TPL_OUT" | tail -5
        # CFG-431: the template drift Phase 0.7 logged is fixed now — strip
        # it the way Phase 4 strips mobile staleness, and leave every other
        # warning in place. A log left holding only the "N issue(s) found"
        # summary is removed too, or the next session still opens with
        # "propagation drift detected at last shutdown" for drift that no
        # longer exists.
        if [ -f "$DRIFT_LOG" ]; then
            _sed_i '/differs from template/d; /not found in template/d; /file(s) drifted/d' "$DRIFT_LOG"
            if ! grep -v 'issue(s) found' "$DRIFT_LOG" 2>/dev/null | grep -q '[^[:space:]]'; then
                rm -f "$DRIFT_LOG"
            fi
        fi
    else
        # A clean dry-run with nothing to copy, nothing unpushed and no marker:
        # the template is current. That is exactly when the real pass used to
        # write .template-push-verified-<HEAD> ("No changes to commit"), which
        # manifest-push-check.sh requires before a cfg commit of a tracked
        # file. The dry-run is now the only verification that ran, so it
        # leaves the same marker (CFG-394).
        _tpl_head=$(git -C "$CONFIG_REPO" rev-parse HEAD 2>/dev/null) \
            && touch "$CONFIG_REPO/.template-push-verified-$_tpl_head" 2>/dev/null || true
    fi
    # Cat-3 inbox auto-generation (CFG-395): parse Flag-only warnings from
    # template-push output — the push's when one ran, the dry-run's otherwise
    # (CFG-431) — compare against .cat3-known, generate per-file inbox tasks
    # for genuinely new Cat-3 entries. First run seeds the file without
    # spamming inbox (avoids 21-item dump on upgrade).
    _CAT3_KNOWN="$CONFIG_REPO/.cat3-known"
    _CAT3_FILES=$(echo "$_TPL_OUT" | grep -oP 'Flag-only file changed: \K\S+' || true)
    if [ -n "$_CAT3_FILES" ]; then
        if [ ! -f "$_CAT3_KNOWN" ]; then
            echo "$_CAT3_FILES" > "$_CAT3_KNOWN"
        else
            # Per-project, typed item (CFG-542/541) — never the legacy inbox.md.
            _INBOX="$CONFIG_REPO/cross-project/inbox/agent-fleet.md"
            _NEW_COUNT=0
            while IFS= read -r _cf; do
                [ -z "$_cf" ] && continue
                grep -Fxq "$_cf" "$_CAT3_KNOWN" && continue
                echo "$_cf" >> "$_CAT3_KNOWN"
                _NEW_COUNT=$((_NEW_COUNT + 1))
                if [ -d "$CONFIG_REPO/cross-project" ]; then
                    mkdir -p "$CONFIG_REPO/cross-project/inbox"
                    _REASON=$(grep -F "\`$_cf\`" "$CONFIG_REPO/template-sync-manifest.md" 2>/dev/null \
                        | head -1 | sed -E 's/.*\|[[:space:]]*([^|]+)[[:space:]]*\|[[:space:]]*$/\1/' \
                        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    printf -- '- [ ] **agent-fleet** [work] (P3): Cat-3 review — `%s`. Diff: %s. Source: auto-detect %s.\n' \
                        "$_cf" "${_REASON:-(no manifest entry)}" "$(date -u +%Y-%m-%d)" >> "$_INBOX"
                fi
            done <<< "$_CAT3_FILES"
            # .cat3-known was append-only, so a file that re-converged or was reclassified
            # stayed "known" forever and a later drift raised no item. Keep only current flags.
            printf '%s\n' "$_CAT3_FILES" | grep -Fxf - "$_CAT3_KNOWN" > "$_CAT3_KNOWN.tmp" 2>/dev/null || true
            mv -f "$_CAT3_KNOWN.tmp" "$_CAT3_KNOWN"
            if [ "$_NEW_COUNT" -gt 0 ]; then
                printf 'TEMPLATE_PROPAGATION_CAT3_NEW: %d new Cat-3 file(s) added to agent-fleet inbox\n' \
                    "$_NEW_COUNT" >> "${DRIFT_LOG:-$CONFIG_REPO/.sync-warnings.log}"
            fi
        fi
    fi
fi
# CFG-965: release the Phase 0.8 lock (fd 8); Phase 3 takes its own (fd 9).
if [ "$_TPL_LOCKED" -eq 1 ]; then flock -u 8 2>/dev/null; exec 8>&-; fi

# --- Phase 0.85: Pending-file demote detection (loop closure) ---
# After commits land, detect act/present pending files whose Tracked-by PRN was
# committed since the last rotation (or whose filename was cited in a commit
# body). Surface PENDING_DEMOTE_NEEDED so the shipping session demotes them in
# the same session — closes the stale-pending loop at the SessionEnd end.
# Advisory only: appends to the drift log, never changes exit behaviour.
# Runs for a held config repo too (CFG-965, documented): it reads git history
# and prints advice; its only write is the drift-log line, the channel meant
# for the next session — the holder's, most likely.
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

# The single normal exit, after Phase 5. Clears a previous failure marker —
# unless THIS run recorded one (sync_fail_continue), which must survive to the
# next SessionStart.
_SYNC_FAILED=0
sync_success() {
    [ "$_SYNC_FAILED" -eq 1 ] || rm -f "$FAIL_MARKER"
    _shutdown_done
    exit 0
}

_sync_fail_record() {
    local stage="$1" detail="$2"
    printf 'stage=%s\ntime=%s\ndetail=%s\n' "$stage" "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" "$detail" > "$FAIL_MARKER"
    printf '\r\033[K  Shutdown: failed at %s (see .sync-failed)\n' "$stage" >&2
}

# A failure after which nothing below can run (no config repo, lock not held).
sync_fail() {
    _sync_fail_record "$1" "$2"
    exit 0  # Still exit 0 — don't block session end
}

# A failure of the cfg commit or push (CFG-634). Recorded, then the hook carries
# on: the mobile refresh (Phase 4) and the deployment-local steps (Phase 5) do
# not depend on the cfg push, and exiting here skipped them on every shutdown
# whose push was refused — a non-fast-forward after another machine pushed cfg
# repeats on every later shutdown until somebody pulls.
sync_fail_continue() {
    _sync_fail_record "$1" "$2"
    _SYNC_FAILED=1
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
if [[ "$ORIGINAL_DIR" == "$CONFIG_REPO" && "$_CFG_HELD_BY_OTHER" -eq 1 ]]; then
    # CFG-965: the project IS the config repo and the early probe already found
    # it held (or its holder unknown): the hook's own verdict is authoritative —
    # rotate-session.sh is not asked; its guard is a second line of defence, not
    # the decision. Recorded once: the unknown case was recorded by the probe.
    if [[ "$_CFG_HELD_RECORDED" -eq 0 ]]; then
        echo "$(date -u +'%Y-%m-%d %H:%M:%S UTC') rotation refused for $ORIGINAL_DIR: held by another live session (the hook's own owner check) although this session's role marker said leader — context left intact, rotate-session.sh not run" >> "$CONFIG_REPO/.sync-warnings.log"
    fi
    _ORIG_ROTATE_OK=0
    _ORIG_HELD_BY_OTHER=1
elif [[ -f "$ORIGINAL_DIR/session-context.md" && -s "$ORIGINAL_DIR/session-context.md" ]]; then
    _rot1_rc=0
    _rot1_err=$(bash "$ROTATE_SCRIPT" "$ORIGINAL_DIR" 2>&1 >/dev/null) || _rot1_rc=$?
    if [[ "$_rot1_rc" -eq 3 ]]; then
        # Guard refusal: another live session holds this project although our
        # role marker said leader — or the guard could not tell (check_lock 4
        # or unusable; its stderr says "unknown"). The context is intact —
        # leave it, say so ONCE: when the project IS the config repo and the
        # early probe already recorded the unknown state, this refusal is the
        # same event (CFG-965 NIT 6).
        case "$_rot1_err" in
            *unknown*) _rot1_why="whether another live session holds it is unknown (lock check could not tell)" ;;
            *)         _rot1_why="held by another live session" ;;
        esac
        if [[ "$ORIGINAL_DIR" != "$CONFIG_REPO" || "$_CFG_HELD_RECORDED" -eq 0 ]]; then
            echo "$(date -u +'%Y-%m-%d %H:%M:%S UTC') rotate-session refused for $ORIGINAL_DIR: $_rot1_why although this session's role marker said leader — context left intact" >> "$CONFIG_REPO/.sync-warnings.log"
        fi
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

# --- CFG-897: never sweep an unexplained rule removal into an Auto-sync commit ---
# 3d8cb52c (2026-03-12) was exactly that: an Auto-sync commit dropped the subagent file-creation
# guardrail from global CLAUDE.md, because this hook stages `global/` wholesale and nobody reads
# what it records. rule-removal-guard.sh --check-staged judges the index as the PreToolUse guard
# judges a commit — with no message, so every removed sentence is unexplained. Offending files
# are UNSTAGED (the working tree is never touched), the rest is committed, and the hold is
# written to the drift log, which the next SessionStart surfaces (config-check.sh Check 4.5).
_RRG_SCRIPT=""
for _c in "$(dirname "${BASH_SOURCE[0]}")/rule-removal-guard.sh" "$CONFIG_REPO/global/hooks/rule-removal-guard.sh"; do
    [ -f "$_c" ] && { _RRG_SCRIPT="$_c"; break; }
done
_rule_removal_hold() {  # <repo> — unstages held rule files in <repo>; never fails the caller
    local repo="$1" held f rc=0
    [ -n "$_RRG_SCRIPT" ] || return 0
    held=$(bash "$_RRG_SCRIPT" --check-staged "$repo" 2>/dev/null) || rc=$?
    [ "$rc" -eq 1 ] && [ -n "$held" ] || return 0
    while IFS= read -r f; do
        [ -n "$f" ] && { git -C "$repo" restore --staged -- ":/$f" 2>/dev/null || true; }   # :/ = root-relative
    done <<< "$held"
    printf 'RULE_REMOVAL_HELD: %s: %s — a staged change drops rule sentence(s) with no Rule-removed trailer; left unstaged, working tree untouched. Commit it with the trailer(s) the guard asks for (bash %s --check-staged %s) or restore the sentence(s).\n' \
        "$repo" "${held//$'\n'/ }" "$_RRG_SCRIPT" "$repo" >> "$DRIFT_LOG"
    return 0
}

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
        _rule_removal_hold "$ORIGINAL_DIR"   # CFG-897: session files are never rule files today; the check keeps it so
        if ! git diff --cached --quiet 2>/dev/null; then
            git commit -m "Auto-sync: session rotation $(date -u +'%Y-%m-%d %H:%M:%S UTC')" 2>/dev/null || true
        fi
    )
fi

_shutdown_progress "Deploying config..."

# --- Phase 3: Config repo sync ---
cd "$CONFIG_REPO" 2>/dev/null || sync_fail "cd" "Config repo not found at $CONFIG_REPO"

# Acquire exclusive lock to prevent parallel session-end races.
# Waits up to _LOCK_WAIT (45 s) — or whatever is left of the hook's deadline
# (_lock_budget, see the definitions at the top), so this wait can never be
# the one that runs the hook into the silent 60 s cap. A typical shutdown holds
# the lock for ~5-10 s; a template push under it (Phase 0.8) longer.
# Previous: flock -n (non-blocking skip) silently dropped uncommitted work.
exec 9>"$LOCK_FILE"
_p3_wait=$(_lock_budget "$_LOCK_WAIT" "$_P3_RESERVE")
if ! flock -w "$_p3_wait" 9; then
    sync_fail "lock" "Config repo lock held >${_p3_wait}s by another session (budget ${_LOCK_WAIT}s, hook cap ${_HOOK_CAP}s, work reserve ${_P3_RESERVE}s, $((SECONDS - _T0))s elapsed)"
fi

# --- CFG-666 / CFG-665 / CFG-965: is the config repo held by a DIFFERENT live session? ---
# Decided before Phase 0 and re-asked under the Phase 0.8 lock (_cfg_held_probe,
# lib-cfg-held.sh): one verdict for every cfg-touching phase. Asked once more
# here, under the flock, for a session that arrived during Phases 0.8–2: the
# probe only ever turns "not held" into "held", and a repo already held is not
# probed again, so its unknown record is written at most once. When the project
# IS the config repo, Phase 1's guard verdict is added too — it exists now: the
# probe ran the same guard early, so the two differ only when the holder changed
# between them, and a hold from either side counts.
[[ "$_CFG_HELD_BY_OTHER" -eq 0 ]] && _cfg_held_probe
if [[ "$ORIGINAL_DIR" == "$CONFIG_REPO" && "$_ORIG_HELD_BY_OTHER" -eq 1 && "$_CFG_HELD_BY_OTHER" -eq 0 ]]; then
    _CFG_HELD_BY_OTHER=1
    _cfg_held_notice
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
#
# CFG-965 / Q-965-DEPLOY (MG, 2026-11-11): SKIPPED ENTIRELY while another live
# session holds the config repo. `sync.sh deploy` copies the WORKING TREE — that
# session's half-edited hooks, settings and knowledge — over the live ~/.claude,
# from any project's shutdown. No HEAD-only or temporary-checkout deploy either:
# the holder deploys at its own shutdown, and every SessionStart deploys anyway.
# An expected skip: audit line, not drift.
if [[ "$_CFG_HELD_BY_OTHER" -eq 1 ]]; then
    _shutdown_progress "Deploy skipped — config repo held by another live session."
    _cfg_defer_audit DEPLOY_DEFERRED "config repo held by another live session — sync.sh deploy skipped; the holder deploys at its own shutdown and every SessionStart deploys"
else
    DEPLOY_OUTPUT=$(bash "$CONFIG_REPO/sync.sh" deploy 2>&1)
    if [ $? -ne 0 ]; then
        printf '%s sync.sh deploy failed (non-fatal): %s\n' \
            "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" \
            "$(echo "$DEPLOY_OUTPUT" | tail -1)" \
            >> "$CONFIG_REPO/.sync-warnings.log"
    fi
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
# Push target (auto-detect default branch: main or master). Respect dual-remote
# projects: push to the private remote, never public.
PUSH_REMOTE="origin"
if [ -f "$CONFIG_REPO/.push-filter.conf" ]; then
    PR=$(grep '^private_remote=' "$CONFIG_REPO/.push-filter.conf" 2>/dev/null | head -1 | cut -d= -f2 | xargs)
    [ -n "$PR" ] && PUSH_REMOTE="$PR"
fi
DEFAULT_BRANCH=$(git symbolic-ref "refs/remotes/$PUSH_REMOTE/HEAD" 2>/dev/null | sed "s|refs/remotes/$PUSH_REMOTE/||")
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"

# CFG-634: no path through here may EXIT before Phase 4 and Phase 5. This block
# used to end in `sync_success`, which is `exit 0`, whenever the repo was held
# or nothing new was staged — and a session that follows session-shutdown.md
# commits and pushes explicitly, so it hands this hook a clean tree every time.
# A well-behaved session guaranteed the early exit: the mobile refresh and the
# deployment-local steps (config-auto-sync-local.sh, the credential push) ran
# only when Phase 3 had something to commit. Measured: every mobile snapshot
# commit ever made landed 1-3 s after a cfg Auto-sync commit and never
# otherwise, and the distributed token expired on the last such day. The
# nothing-to-commit case now SKIPS the commit
# (still pushing whatever is unpushed — that touches no working file) and falls
# through; the secret-scan path below does the same. A refused commit or push
# is recorded (sync_fail_continue) and falls through as well; only a failure
# after which nothing can run (no config repo, lock not acquired) leaves early.
_PHASE3_COMMIT=1
if [[ "$_CFG_HELD_BY_OTHER" -eq 1 ]] || git diff --cached --quiet 2>/dev/null; then
    _PHASE3_COMMIT=0
    UNPUSHED=$(git log "$PUSH_REMOTE/$DEFAULT_BRANCH..HEAD" --oneline 2>/dev/null)
    if [ -n "$UNPUSHED" ]; then
        _PUSH_ERR="$(git push "$PUSH_REMOTE" "$DEFAULT_BRANCH" 2>&1 >/dev/null)" \
            || sync_fail_continue "push" "git push failed (unpushed commits exist): ${_PUSH_ERR:-no stderr}"
    fi
fi

# Secret scan: check staged diff for obvious secret patterns before committing
if [[ "$_PHASE3_COMMIT" -eq 1 ]]; then
    STAGED_DIFF=$(git diff --cached 2>/dev/null)
    SECRET_PATTERNS='sk-ant-[A-Za-z0-9-]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|AIzaSy[A-Za-z0-9_-]{33}|ghp_[A-Za-z0-9]{36,}|gho_[A-Za-z0-9]{36,}|xoxb-[A-Za-z0-9-]+|xoxp-[A-Za-z0-9-]+|password\s*[:=]|secret\s*[:=]|private_key\s*[:=]|-----BEGIN RSA|-----BEGIN PRIVATE KEY|(key|token|secret)\s*[:=]\s*[A-Za-z0-9+/]{40,}={0,2}'  # pragma: allowlist secret
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
            # Nothing left staged: no commit — but the tail still runs (CFG-634)
            git diff --cached --quiet 2>/dev/null && _PHASE3_COMMIT=0
        fi
    fi
fi

# CFG-897: same shape as the secret scan — hold rule files whose staged change drops a
# sentence nobody retired (see _rule_removal_hold above), commit whatever else is staged.
if [[ "$_PHASE3_COMMIT" -eq 1 ]]; then
    _rule_removal_hold "$CONFIG_REPO"
    git diff --cached --quiet 2>/dev/null && _PHASE3_COMMIT=0
fi

if [[ "$_PHASE3_COMMIT" -eq 1 ]]; then
    _shutdown_progress "Committing & pushing..."

    # Commit. The body names EVERY path this shutdown swept in, with the count
    # (CFG-665): the directory staging above is deliberately broad, and a sweep
    # of somebody's half-finished work produces a green tree that looks like
    # nothing happened. `git log` is where they will look; make it say so.
    _SWEPT=$(git diff --cached --name-only 2>/dev/null)
    _SWEPT_N=$(printf '%s\n' "$_SWEPT" | grep -c . || true)
    if git commit -m "Auto-sync: $(date -u +'%Y-%m-%d %H:%M:%S UTC')" \
        -m "Swept by the SessionEnd hook from $(basename "$ORIGINAL_DIR"): $_SWEPT_N file(s)
$(printf '%s\n' "$_SWEPT" | sed 's/^/  - /')" 2>/dev/null; then
        # Capture stderr rather than discarding it: this push can be refused by the repo's
        # pre-push leak guard, and "git push failed (network? auth?)" actively misdirects
        # when the real answer is "personal data was found and publication was prevented".
        _PUSH_ERR="$(git push "$PUSH_REMOTE" "$DEFAULT_BRANCH" 2>&1 >/dev/null)" \
            || sync_fail_continue "push" "git push failed: ${_PUSH_ERR:-no stderr}"
    else
        sync_fail_continue "commit" "git commit failed"
    fi
fi

# Phase 3 deploy (above) already ensures deployed state matches repo.
# Phase 3.5 (redundant deploy) removed in v1.0 — repo is sole authority.

# --- Phase 4: Auto-refresh mobile repo snapshots ---
# Runs AFTER commit+push so mobile gets final file state (dashboard-cache, inbox, etc.).
# Moved from Phase 0.9 — running before session rotation caused persistent staleness.
# Reached on EVERY leader shutdown since CFG-634, whether or not Phase 3 committed;
# a follower has already exited in Phase -1, so only a leader ever refreshes mobile.
# Not gated on the held verdict (CFG-965, documented): mobile-deploy.sh READS
# the config repo and every registry project's session-context and backlog and
# WRITES only into ~/agent-fleet-mobile — nothing in the cfg working tree. A
# live cfg session is just one of the live projects whose context the phone
# snapshot excerpts on every shutdown, and what leaves the machine is decided
# by the leak gate and the egress policy below, not by who holds which repo;
# the holder's own shutdown refreshes the snapshot again.
_MOBILE_DEPLOY="$CONFIG_REPO/setup/scripts/mobile-deploy.sh"
_LEAK_LIB="$CONFIG_REPO/setup/scripts/lib-leak-gate.sh"
if [ -f "$_MOBILE_DEPLOY" ] && [ -d "$MOBILE_REPO" ]; then
    _shutdown_progress "Refreshing mobile repo..."
    # CFG-626: keep the output. This line ended in `2>/dev/null || true` and the
    # push below in the same, while the push failed on every run for five weeks
    # and nothing said so. A failed refresh is now a drift-log line the next
    # session surfaces; a held file (mobile-deploy exit 3) lands there too.
    _MOB_OUT=$(bash "$_MOBILE_DEPLOY" --config-repo "$CONFIG_REPO" --target "$MOBILE_REPO" 2>&1) || {
        _mob_rc=$?
        printf 'MOBILE_DEPLOY_FAILED: mobile-deploy.sh exit=%d: %s\n' "$_mob_rc" \
            "$(printf '%s\n' "$_MOB_OUT" | sed "s/$(printf '\033')\[[0-9;]*m//g" \
                | grep -E '\[LEAK\]|\[ERROR\]|ERROR' | tail -3 | tr '\n' ';')" >> "$DRIFT_LOG"
    }
    # The belt over mobile-deploy's braces: the SAME shared gate (lib-leak-gate.sh)
    # over exactly what is about to be committed. No library means nothing can
    # be scanned, and nothing unscanned leaves this machine — fail closed.
    _MOB_OK=0
    if [ -f "$_LEAK_LIB" ] && source "$_LEAK_LIB" 2>/dev/null; then
        _mob_gate_rc=0
        _MOB_HITS=$(check_leaks "$LEAK_GATE_SECRET_PATTERNS" "$MOBILE_REPO/context" 2>&1) || _mob_gate_rc=$?
        if [ "$_mob_gate_rc" -eq 0 ]; then
            _MOB_OK=1
        elif [ "$_mob_gate_rc" -eq 1 ]; then
            printf 'MOBILE_LEAK_HELD: credential-shaped content in the mobile snapshot — NOT committed or pushed: %s\n' \
                "$(printf '%s\n' "$_MOB_HITS" | leak_gate_hit_files | sed "s|^$MOBILE_REPO/||" | tr '\n' ' ')" >> "$DRIFT_LOG"
        else
            # The gate's own refusal lines only: when a refusal coincides with
            # real hits, the hit lines carry the credential text.
            printf 'MOBILE_LEAK_HELD: the leak gate refused to scan (rc %d) — NOT committed or pushed: %s\n' \
                "$_mob_gate_rc" "$(printf '%s\n' "$_MOB_HITS" | grep '^check_leaks:' | tr '\n' ' ')" >> "$DRIFT_LOG"
        fi
    else
        printf 'MOBILE_LEAK_GATE_UNAVAILABLE: %s missing — mobile snapshot NOT committed or pushed (fail closed)\n' \
            "$_LEAK_LIB" >> "$DRIFT_LOG"
    fi
    # Egress policy (CFG-634 x CFG-626). The snapshot is an excerpt of EVERY
    # registry project's session-context and backlog plus the registry,
    # dashboard and inbox, bound for an external host — and the gate above
    # only knows credential values, not which projects' work may leave the
    # machine. Before CFG-634 a clean-tree shutdown never got here; now every
    # leader shutdown does. So the push needs a declared policy: the deployment
    # sets push=allow in setup/config/mobile-deploy.conf once it has decided
    # its snapshot may leave (or filters it first). push=hold is that decision
    # the other way and is not a warning; no policy at all holds the push AND
    # says so. Either way the local refresh above has run and nothing is
    # committed, so nothing waits in the mobile repo to be pushed later.
    if [ "$_MOB_OK" -eq 1 ]; then
        _MOB_POLICY=$(leak_gate_conf_value "$CONFIG_REPO/setup/config/mobile-deploy.conf" push)
        case "$_MOB_POLICY" in
            allow) ;;
            hold)
                _MOB_OK=0
                _shutdown_progress "Mobile snapshot refreshed locally; push held (setup/config/mobile-deploy.conf: push=hold)."
                ;;
            *)
                _MOB_OK=0
                printf 'MOBILE_PUSH_HELD: no egress policy — the mobile snapshot (every registry project'"'"'s context) was refreshed locally but NOT committed or pushed; set push=allow (or push=hold) in setup/config/mobile-deploy.conf\n' \
                    >> "$DRIFT_LOG"
                ;;
        esac
    fi
    # Commit and push mobile changes — without this, snapshots stay dirty
    # and the next session's check reports eternal staleness.
    if [ "$_MOB_OK" -eq 1 ]; then
        git -C "$MOBILE_REPO" add -A context/ 2>/dev/null || true
        if ! git -C "$MOBILE_REPO" diff --cached --quiet 2>/dev/null; then
            git -C "$MOBILE_REPO" commit -m "Auto-sync: mobile context snapshots" 2>/dev/null || true
            # Capture stderr: a refused push must name its reason, not vanish.
            _MPUSH_ERR="$(git -C "$MOBILE_REPO" push origin main 2>&1 >/dev/null)" \
                || printf 'MOBILE_PUSH_FAILED: git push origin main in %s: %s\n' \
                    "$MOBILE_REPO" "${_MPUSH_ERR:-no stderr}" >> "$DRIFT_LOG"
        fi
    fi
    # Clear mobile staleness warnings from drift log — Phase 0.7 ran before this
    # refresh, so mobile appeared stale. Now it's fresh. Remove stale warnings.
    if [ -f "$DRIFT_LOG" ]; then
        _sed_i "/mobile repo is stale/d; /Checking mobile/d; /file(s) stale\. Run 'sync\.sh mobile-deploy'/d" "$DRIFT_LOG"
        # Remove the log when nothing but the "N issue(s) found" summary (or
        # blank lines) is left — the issues it counted were stripped above or
        # in Phase 0.8 as fixed (CFG-431), and a summary alone would still make
        # the next session report drift that no longer exists.
        if ! grep -v 'issue(s) found' "$DRIFT_LOG" 2>/dev/null | grep -q '[^[:space:]]'; then
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
# guard above on one machine. The shim runs as a subprocess, after the Phase 3
# commit+push was attempted (a refused push no longer skips it, CFG-634),
# with CONFIG_REPO and ORIGINAL_DIR in its environment; its stdout is dropped,
# its stderr (progress lines) reaches the user, and its exit status never blocks
# shutdown. Absent shim = nothing to do. It runs on every LEADER shutdown, with
# or without a Phase 3 commit (CFG-634); follower shutdowns exit in Phase -1, so
# only the leader's shutdown can ever refresh what the shim refreshes.
# CFG-965: it is also told the owner verdict (CFG_HELD_BY_OTHER=0|1), so a
# deployment's shim can hold its own cfg-tree writes while the repo is held.
# Not gated here: this fleet's shim touches no cfg working file (it refreshes
# a credential blob on a remote host), and a downstream one decides for itself.
_LOCAL_SHIM="$CONFIG_REPO/setup/scripts/config-auto-sync-local.sh"
if [ -f "$_LOCAL_SHIM" ]; then
    CONFIG_REPO="$CONFIG_REPO" ORIGINAL_DIR="$ORIGINAL_DIR" CFG_HELD_BY_OTHER="$_CFG_HELD_BY_OTHER" \
        bash "$_LOCAL_SHIM" >/dev/null || true
fi

sync_success
