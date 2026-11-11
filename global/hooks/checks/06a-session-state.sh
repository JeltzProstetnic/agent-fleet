#!/usr/bin/env bash
# Check group 6a: Session state — hostname, persona, session context, handoff, pending files, dashboard, tmux, tip
# Checks: 6a.1, 6a.2, 6a.3, 6a.4, 6a.5 (body in ../lib-pending-files.sh), 6a.6, 6a.7, 6a.8
# Shared vars used: CONFIG_REPO, WARNINGS, INBOX_MSG, IDENTITY_MSG, PROJECT_DIR
#
# IDENTITY_MSG vs INBOX_MSG (2026-09-17 spill incident): Claude Code writes a SessionStart
# payload over ~10K chars to a file and injects only a 2 KB HEAD preview (measured
# 2026-10-08), and config-check.sh's own cap keeps 80% head, so the fields
# a session cannot start without (HOSTNAME/TIME/PERSONA/SESSION_CONTEXT/HANDOFF/
# PENDING_FILES) go into IDENTITY_MSG, which config-check.sh places FIRST in the
# payload. Everything recoverable-by-reading-the-spilled-file stays in INBOX_MSG.
# Do NOT reorder by parsing the assembled string — items legitimately contain " | "
# (the HANDOFF line does), which is why this is a separate variable, not a sort.

# Check 6a.1: Inject hostname + time for machine identity and day/night mode
HOSTNAME_VAL=$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo "unknown")
CURRENT_TIME=$(date +%H:%M)
DAY_OF_WEEK=$(date +%u)
IDENTITY_MSG="${IDENTITY_MSG:+$IDENTITY_MSG | }HOSTNAME: $HOSTNAME_VAL | TIME: $CURRENT_TIME DOW: $DAY_OF_WEEK"

# Check 6a.2: Persona injection — read active persona, inject into additionalContext
ACTIVE_PERSONA_FILE="$HOME/.claude/.active-persona"
PERSONA_NAME="Assistant"
if [ -f "$ACTIVE_PERSONA_FILE" ]; then
    _raw_persona=$(head -1 "$ACTIVE_PERSONA_FILE" 2>/dev/null | xargs)
    [ -n "$_raw_persona" ] && PERSONA_NAME="$_raw_persona"
fi
IDENTITY_MSG="${IDENTITY_MSG:+$IDENTITY_MSG | }PERSONA: $PERSONA_NAME"

# Check 6a.3: Session-context blank detection — detect blank/active session goal
if [[ -f "$PROJECT_DIR/session-context.md" ]]; then
    _sc_goal=$(sed -n 's/.*\*\*Session Goal\*\*: \(.\+\)/\1/p' "$PROJECT_DIR/session-context.md" 2>/dev/null | head -1)
    if [[ -n "$_sc_goal" ]]; then
        _sc_goal="${_sc_goal:0:150}"
        IDENTITY_MSG="${IDENTITY_MSG:+$IDENTITY_MSG | }SESSION_CONTEXT: active — $_sc_goal"
    else
        IDENTITY_MSG="${IDENTITY_MSG:+$IDENTITY_MSG | }SESSION_CONTEXT: blank"
    fi
else
    IDENTITY_MSG="${IDENTITY_MSG:+$IDENTITY_MSG | }SESSION_CONTEXT: blank"
fi

# Check 6a.4: Handoff detection — read next-session-task.md, inject HANDOFF
HANDOFF_FILE="$PROJECT_DIR/next-session-task.md"
if [[ -f "$HANDOFF_FILE" ]]; then
    _ho_task=$(grep '^task:' "$HANDOFF_FILE" 2>/dev/null | head -1 | sed 's/^task: *//')
    if [[ "$_ho_task" == "true" ]]; then
        _ho_desc=$(grep '^description:' "$HANDOFF_FILE" 2>/dev/null | head -1 | sed 's/^description: *//')
        _ho_file=$(grep '^file:' "$HANDOFF_FILE" 2>/dev/null | head -1 | sed 's/^file: *//')
        _ho_desc="${_ho_desc:0:200}"
        # CFG-948: optional `resume:` = the exact first command or step to run.
        _ho_resume=$(grep '^resume:' "$HANDOFF_FILE" 2>/dev/null | head -1 | sed 's/^resume: *//')
        _ho_resume="${_ho_resume:0:200}"
        IDENTITY_MSG="${IDENTITY_MSG:+$IDENTITY_MSG | }HANDOFF: $_ho_desc | file: $_ho_file${_ho_resume:+ | resume: $_ho_resume}"
    else
        IDENTITY_MSG="${IDENTITY_MSG:+$IDENTITY_MSG | }HANDOFF: none"
    fi
else
    IDENTITY_MSG="${IDENTITY_MSG:+$IDENTITY_MSG | }HANDOFF: none"
fi

# Check 6a.5: Pending files — PENDING_FILES / ACT_PENDING / STALE_PENDING /
# UNTRACKED_PENDING / DANGLING_PENDING plus the CFG-948 Work: block fields
# (WORK_MALFORMED, WORK_DONE_CONFLICT). The scan and the report live in
# ../lib-pending-files.sh (moved out 2026-11-11 to keep this check under the
# 100-line threshold; semantics unchanged). A missing lib is reported, never
# silent: a session that cannot see its pending files must know it.
source "$(dirname "${BASH_SOURCE[0]}")/../lib-pending-files.sh" 2>/dev/null || true
if type pending_files_scan >/dev/null 2>&1; then
    pending_files_scan
    pending_files_report
else
    IDENTITY_MSG="${IDENTITY_MSG:+$IDENTITY_MSG | }PENDING_FILES: unknown — lib-pending-files.sh failed to load; list docs/pending-*.md by hand"
fi

# Check 6a.6: AFLEET_DASHBOARD marker — afleet.sh sets this to trigger dashboard on next session
DASH_MARKER="$HOME/.claude/.afleet-show-dash"
if [ -f "$DASH_MARKER" ]; then
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }AFLEET_DASHBOARD: Render project dashboard (triggered by afleet marker)."
    rm -f "$DASH_MARKER"
fi

# Check 6a.7: Active tmux sessions — surface running background ops
_tmux_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | tr '\n' ', ' | sed 's/, $//')
if [ -n "$_tmux_sessions" ]; then
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }TMUX_ACTIVE: $_tmux_sessions"
fi

# Check 6a.8: Onboarding tip — show end/cls reminder for first 5 sessions
_session_log="${CONFIG_REPO:-}/docs/session-log.md"
if [ -f "$_session_log" ]; then
    _session_count=$(grep -c '^## Session' "$_session_log" 2>/dev/null || echo "0")
else
    _session_count=0
fi
if [ "$_session_count" -lt 5 ] 2>/dev/null; then
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }TIP: Type \`cls\` to shut down + clear (new session), or \`end\` to shut down + exit."
fi
