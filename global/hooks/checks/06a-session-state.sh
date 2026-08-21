#!/usr/bin/env bash
# Check group 6a: Session state — hostname, persona, session context, handoff, pending files, dashboard, tmux
# Checks: 6a.1, 6a.2, 6a.3, 6a.4, 6a.5, 6a.6, 6a.7
# Shared vars used: CONFIG_REPO, WARNINGS, INBOX_MSG, PROJECT_DIR

# Check 6a.1: Inject hostname + time for machine identity and day/night mode
HOSTNAME_VAL=$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo "unknown")
CURRENT_TIME=$(date +%H:%M)
DAY_OF_WEEK=$(date +%u)
INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }HOSTNAME: $HOSTNAME_VAL | TIME: $CURRENT_TIME DOW: $DAY_OF_WEEK"

# Check 6a.2: Persona injection — read active persona, inject into additionalContext
ACTIVE_PERSONA_FILE="$HOME/.claude/.active-persona"
PERSONA_NAME="Assistant"
if [ -f "$ACTIVE_PERSONA_FILE" ]; then
    _raw_persona=$(head -1 "$ACTIVE_PERSONA_FILE" 2>/dev/null | xargs)
    [ -n "$_raw_persona" ] && PERSONA_NAME="$_raw_persona"
fi
INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }PERSONA: $PERSONA_NAME"

# Check 6a.3: Session-context blank detection — detect blank/active session goal
if [[ -f "$PROJECT_DIR/session-context.md" ]]; then
    _sc_goal=$(sed -n 's/.*\*\*Session Goal\*\*: \(.\+\)/\1/p' "$PROJECT_DIR/session-context.md" 2>/dev/null | head -1)
    if [[ -n "$_sc_goal" ]]; then
        _sc_goal="${_sc_goal:0:150}"
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }SESSION_CONTEXT: active — $_sc_goal"
    else
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }SESSION_CONTEXT: blank"
    fi
else
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }SESSION_CONTEXT: blank"
fi

# Check 6a.4: Handoff detection — read next-session-task.md, inject HANDOFF
HANDOFF_FILE="$PROJECT_DIR/next-session-task.md"
if [[ -f "$HANDOFF_FILE" ]]; then
    _ho_task=$(grep '^task:' "$HANDOFF_FILE" 2>/dev/null | head -1 | sed 's/^task: *//')
    if [[ "$_ho_task" == "true" ]]; then
        _ho_desc=$(grep '^description:' "$HANDOFF_FILE" 2>/dev/null | head -1 | sed 's/^description: *//')
        _ho_file=$(grep '^file:' "$HANDOFF_FILE" 2>/dev/null | head -1 | sed 's/^file: *//')
        _ho_desc="${_ho_desc:0:200}"
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }HANDOFF: $_ho_desc | file: $_ho_file"
    else
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }HANDOFF: none"
    fi
else
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }HANDOFF: none"
fi

# Check 6a.5: Pending files list — list all pending-*.md files in project docs/
# Stale-pending reconciliation (CFG): files whose work already shipped (all
# Tracked-by PRNs closed, or session-log/git shows shipped) are routed to a
# SEPARATE STALE_PENDING field so the agent verifies-before-presenting instead
# of re-listing shipped work as live ACT/PENDING. Genuinely-open files keep
# byte-identical ACT_PENDING/PENDING_FILES output (clean-path regression-tested).
_stale_set=""
if [ -d "$PROJECT_DIR/docs" ]; then
    _manage_pending="${CONFIG_REPO:-}/setup/scripts/manage-pending.sh"
    if [ -f "$_manage_pending" ]; then
        _stale_set=$(bash "$_manage_pending" --stale-check --project-dir "$PROJECT_DIR" 2>/dev/null || true)
    fi
fi
# Returns "stale" if the given filename appears as a STALE: line in the set.
_is_stale_pending() {
    [ -n "$_stale_set" ] || return 1
    printf '%s\n' "$_stale_set" | grep -qF "STALE: $1"
}

_pending_list=""
_act_files=""
_stale_files=""
if [ -d "$PROJECT_DIR/docs" ]; then
    for _pf in "$PROJECT_DIR"/docs/pending-*.md; do
        [ -f "$_pf" ] || continue
        _pf_base="$(basename "$_pf")"
        # Accept BOTH header forms (CFG-482). Every real pending file writes
        # `<!-- Action: x -->` so the header stays invisible in rendered markdown;
        # the bare form only ever existed in fixtures. Strip the comment markers
        # first, then take the single word after `Action:`.
        _action=$(head -5 "$_pf" | sed -e 's/<!--//' -e 's/-->//' \
            | sed -n 's/^[[:space:]]*Action:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)
        if _is_stale_pending "$_pf_base"; then
            # Route stale act/present files away from the loud channels.
            _stale_files="${_stale_files:+$_stale_files, }$_pf_base (${_action:-triage})"
            continue
        fi
        _pending_list="${_pending_list:+$_pending_list, }$_pf_base (${_action:-triage})"
        if [ "$_action" = "act" ]; then
            _act_files="${_act_files:+$_act_files, }$_pf_base"
        fi
    done
fi
if [ -n "$_act_files" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }ACT_PENDING: These pending files require IMMEDIATE execution before any user task: $_act_files — read them and execute (loading protocol step 0b)."
fi
if [ -n "$_stale_files" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }STALE_PENDING: These pending files look already-shipped (completion evidence found): $_stale_files — verify the cited commit/session-log line, then demote (act/present → reference with a real Tracked-by, or delete). Do NOT present them as live work without verifying."
fi
if [ -n "$_pending_list" ]; then
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }PENDING_FILES: $_pending_list"
else
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }PENDING_FILES: none"
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
