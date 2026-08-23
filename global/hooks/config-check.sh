#!/usr/bin/env bash
# SessionStart hook: check for config sync failures, symlink health, and inbox tasks.
# Outputs JSON with additionalContext so Claude sees the warning in context (invisible to user).
#
# Check modules live in checks/ subdirectory and are sourced in filename order
# (01-sync-state.sh through 20-user-needs.sh) — adding a file there registers it.
# Each module reads/modifies the shared variables below.

# Source portable wrappers (provides _readlink_f for macOS compat)
source "$(dirname "${BASH_SOURCE[0]}")/lib-portable.sh" 2>/dev/null || true

# Config repo detection — canonical source in lib-detect-repo.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-detect-repo.sh" 2>/dev/null || true

# CC session id from hook stdin (CFG-452) — binds lock ownership to this session
source "$(dirname "${BASH_SOURCE[0]}")/lib-hook-stdin.sh" 2>/dev/null || true

# ── Shared state (used by all check modules) ──
CONFIG_REPO="$(_detect_config_repo)"
FAIL_MARKER="$CONFIG_REPO/.sync-failed"
WARNINGS=""
INBOX_MSG=""

DEFAULT_BRANCH=$(git -C "$CONFIG_REPO" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"

CC_MIRROR_DIR="${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}"
SETTINGS_FILE="$CC_MIRROR_DIR/config/settings.json"
PROJECT_DIR="$(pwd)"
PROJECT_ROOT="$(git -C "$CONFIG_REPO" rev-parse --show-toplevel 2>/dev/null || echo "$CONFIG_REPO")"

# ── CC session id (CFG-452) ──
# Read the session_id from this hook's stdin JSON and export it so the lock
# check (checks/07b-platform-env.sh) can bind the lock to a unique CC session,
# closing the F1 env-inheritance spoof. Empty on any failure → legacy behaviour.
# TTY-guarded + 2s-bounded read (see lib-hook-stdin.sh) — cannot hang startup.
CC_SESSION_ID=""
if command -v read_cc_session_id >/dev/null 2>&1; then
    CC_SESSION_ID="$(read_cc_session_id)"
fi
export CC_SESSION_ID

# ── Resolve checks directory ──
_HOOK_DIR="$(cd "$(dirname "$(_readlink_f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
_CHECKS_DIR="${CONFIG_CHECK_DIR:-${_HOOK_DIR}/checks}"

# ── First-run mode: suppress non-critical checks when .setup-pending exists ──
# First-run mode suppresses 21 of 23 checks, and NOTHING used to remove the
# marker — deleting it existed only as prose in first-run-refinement.md, so a
# machine stayed suppressed from install onwards and "everything was skipped"
# looked exactly like "nothing to report" (agent-fleet GH#6 defect 2; the same
# silent-empty signature as CFG-503 / CFG-527 / CFG-530).
#
# The marker now has a definite lifetime of exactly ONE session: the first
# startup arms a `.seen` sibling and runs suppressed, so first-run refinement
# gets its full session; the next startup finds the sibling and clears both.
# The asymmetry justifies erring toward clearing — one session too early costs
# a re-run of refinement, never clearing costs every check, forever.
FIRST_RUN_MODE=0
_SETUP_MARKER=""
if [ -f "$PROJECT_ROOT/.setup-pending" ]; then
    _SETUP_MARKER="$PROJECT_ROOT/.setup-pending"
elif [ -f "$CONFIG_REPO/.setup-pending" ]; then
    _SETUP_MARKER="$CONFIG_REPO/.setup-pending"
fi

if [ -n "$_SETUP_MARKER" ]; then
    if [ -f "$_SETUP_MARKER.seen" ]; then
        rm -f "$_SETUP_MARKER" "$_SETUP_MARKER.seen" 2>/dev/null || true
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }[INFO] First-run mode complete — .setup-pending cleared, all checks re-armed."
    else
        FIRST_RUN_MODE=1
        : > "$_SETUP_MARKER.seen" 2>/dev/null || true
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }[INFO] First-run mode — skipping non-essential checks (.setup-pending detected). This is the ONLY suppressed session; the marker clears at the next startup."
    fi
else
    # Marker removed by hand — do not leave the sibling behind to confuse the next run.
    rm -f "$PROJECT_ROOT/.setup-pending.seen" "$CONFIG_REPO/.setup-pending.seen" 2>/dev/null || true
fi

# ── Source and execute check modules (alphabetical order) ──
if [ -d "$_CHECKS_DIR" ]; then
    for _check_file in "$_CHECKS_DIR"/*.sh; do
        [ -f "$_check_file" ] || continue
        # In first-run mode, only load critical checks
        if [ "$FIRST_RUN_MODE" -eq 1 ]; then
            _check_basename="$(basename "$_check_file")"
            case "$_check_basename" in
                01-sync-state.sh|04-auto-fix.sh|06a-session-state.sh) ;;
                *) continue ;;
            esac
        fi
        source "$_check_file" 2>/dev/null || true
    done
fi

# ── Output JSON ──
SYSTEM_MSG=""
if [ -n "$WARNINGS" ]; then
    if [ "$FIRST_RUN_MODE" -eq 1 ]; then
        SYSTEM_MSG="$(printf '%s' "$WARNINGS" | tr '\n' ' ')"
    else
        SYSTEM_MSG="WARNING: $(printf '%s' "$WARNINGS" | tr '\n' ' ') Tell the user about this issue immediately before doing any other work."
    fi
fi
if [ -n "$INBOX_MSG" ]; then
    SYSTEM_MSG="${SYSTEM_MSG:+$SYSTEM_MSG | }$(printf '%s' "$INBOX_MSG" | tr '\n' ' ')"
fi

# ── Cap the payload (CFG-527) ──
# Two independent reasons, and both matter:
#  1. A single argv entry is capped at MAX_ARG_STRLEN = 32 pages = 131,072 bytes (NOT ARG_MAX,
#     which is ~2 MB and is not what bites). Passing the payload as argv past that returns E2BIG,
#     the encoder never runs, stdout is empty — and this script still exits 0. Silent, unlogged.
#     The encoder below now reads stdin, so that limit no longer applies; the cap is defence in depth.
#  2. Even when it fits, a 176 KB additionalContext is ~45k tokens injected into every session of
#     the affected project. Uncapped, fixing (1) alone trades a silent failure for a context bomb.
# Truncation keeps BOTH ends: warnings accumulate at the front, and the identity block
# (HOSTNAME / PERSONA / SESSION_CONTEXT / HANDOFF / PENDING_FILES, from 06a onward) at the back.
# A head-only truncation would drop exactly the fields a session cannot start without.
_MAX_CTX="${CONFIG_CHECK_MAX_CONTEXT:-60000}"
if [ -n "$SYSTEM_MSG" ] && [ "${#SYSTEM_MSG}" -gt "$_MAX_CTX" ]; then
    _total=${#SYSTEM_MSG}
    _head=$(( _MAX_CTX * 6 / 10 ))
    _tail=$(( _MAX_CTX * 4 / 10 ))
    _dropped=$(( _total - _head - _tail ))
    SYSTEM_MSG="${SYSTEM_MSG:0:$_head} … [TRUNCATED: $_dropped of $_total chars dropped — the payload is oversized, usually because cross-project/inbox.md holds too many items for this project; see CFG-515 and CFG-527] … ${SYSTEM_MSG: -$_tail}"
fi

if [ -n "$SYSTEM_MSG" ]; then
    # Payload goes in on STDIN, never as argv. The python3 branch is guarded by its own exit
    # status so a runtime failure falls through to node — `command -v` alone only proves the
    # binary exists, which is how the argv failure stayed invisible.
    # CFG-530: the payload MUST be nested under hookSpecificOutput with an explicit
    # hookEventName. A TOP-LEVEL {"additionalContext": …} is accepted, logged as
    # hook_success, and then SILENTLY DISCARDED — measured against the real binary,
    # not inferred, and contrary to the published docs which present both forms as
    # valid. See setup/tests/test-hook-output-format.sh for the three-variant probe.
    if ! { command -v python3 >/dev/null 2>&1 &&
           printf '%s' "$SYSTEM_MSG" | python3 -c \
             "import json,sys; print(json.dumps({'hookSpecificOutput': {'hookEventName': 'SessionStart', 'additionalContext': sys.stdin.read()}}))"; }; then
        if command -v node >/dev/null 2>&1; then
            printf '%s' "$SYSTEM_MSG" | node -e \
              "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>console.log(JSON.stringify({hookSpecificOutput:{hookEventName:'SessionStart',additionalContext:s}})))"
        fi
    fi
fi

exit 0
