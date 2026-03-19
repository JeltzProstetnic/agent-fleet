# Check group 6: State injection — hostname, persona, session, handoff, pending, knowledge, tmux
# Checks: 19(hostname), 20, 21, 22, 23, 18b, 26, 24, 25
# Shared vars used: CONFIG_REPO, WARNINGS, INBOX_MSG, PROJECT_DIR

# Check 19: Inject hostname + time for machine identity and day/night mode
HOSTNAME_VAL=$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo "unknown")
CURRENT_TIME=$(date +%H:%M)
DAY_OF_WEEK=$(date +%u)
INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }HOSTNAME: $HOSTNAME_VAL | TIME: $CURRENT_TIME DOW: $DAY_OF_WEEK"

# Check 20: Persona injection — read active persona, inject into systemMessage
ACTIVE_PERSONA_FILE="$HOME/.claude/.active-persona"
PERSONA_NAME="Assistant"
if [ -f "$ACTIVE_PERSONA_FILE" ]; then
    _raw_persona=$(head -1 "$ACTIVE_PERSONA_FILE" 2>/dev/null | xargs)
    [ -n "$_raw_persona" ] && PERSONA_NAME="$_raw_persona"
fi
INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }PERSONA: $PERSONA_NAME"

# Check 21: Session-context blank detection — detect blank/active session goal
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

# Check 22: Handoff detection — read next-session-task.md, inject HANDOFF
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

# Check 23: Pending files list — list all pending-*.md files in project docs/
_pending_list=""
_act_files=""
if [ -d "$PROJECT_DIR/docs" ]; then
    for _pf in "$PROJECT_DIR"/docs/pending-*.md; do
        [ -f "$_pf" ] || continue
        _pf_base="$(basename "$_pf")"
        _pending_list="${_pending_list:+$_pending_list, }$_pf_base"
        _action=$(head -5 "$_pf" | sed -n 's/^Action: *\(.*\)/\1/p' | head -1)
        if [ "$_action" = "act" ]; then
            _act_files="${_act_files:+$_act_files, }$_pf_base"
        fi
    done
fi
if [ -n "$_act_files" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }ACT_PENDING: These pending files require IMMEDIATE execution before any user task: $_act_files — read them and execute (loading protocol step 0b)."
fi
if [ -n "$_pending_list" ]; then
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }PENDING_FILES: $_pending_list"
else
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }PENDING_FILES: none"
fi

# Check 18b: AFLEET_DASHBOARD marker — afleet.sh sets this to trigger dashboard on next session
DASH_MARKER="$HOME/.claude/.afleet-show-dash"
if [ -f "$DASH_MARKER" ]; then
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }AFLEET_DASHBOARD: Render project dashboard (triggered by afleet marker)."
    rm -f "$DASH_MARKER"
fi

# Check 26: Active tmux sessions — surface running background ops
_tmux_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | tr '\n' ', ' | sed 's/, $//')
if [ -n "$_tmux_sessions" ]; then
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }TMUX_ACTIVE: $_tmux_sessions"
fi

# Check 24: Knowledge file list — list .claude/knowledge/*.md + .claude/*.md
_knowledge_list=""
if [ -d "$PROJECT_DIR/.claude" ]; then
    for _kf in "$PROJECT_DIR"/.claude/knowledge/*.md; do
        [ -f "$_kf" ] || continue
        _knowledge_list="${_knowledge_list:+$_knowledge_list, }$(basename "$_kf")"
    done
    for _kf in "$PROJECT_DIR"/.claude/*.md; do
        [ -f "$_kf" ] || continue
        _kf_base="$(basename "$_kf")"
        [[ "$_kf_base" == settings* ]] && continue
        _knowledge_list="${_knowledge_list:+$_knowledge_list, }$_kf_base"
    done
fi
if [ -n "$_knowledge_list" ]; then
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }PROJECT_KNOWLEDGE: $_knowledge_list"
else
    INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }PROJECT_KNOWLEDGE: none"
fi

# Check 35: Sibling session detection — config repo ↔ template repo cross-project write gate
_sibling_dir=""
if [[ "$PROJECT_DIR" == */cfg-agent-fleet ]]; then
    _sibling_dir="$HOME/agent-fleet"
elif [[ "$PROJECT_DIR" == */agent-fleet ]] && [[ "$PROJECT_DIR" != */cfg-agent-fleet ]]; then
    _sibling_dir="$HOME/cfg-agent-fleet"
fi
if [ -n "$_sibling_dir" ] && [ -d "$_sibling_dir" ]; then
    _sibling_lock="$_sibling_dir/.session-lock"
    if [ -f "$_sibling_lock" ]; then
        _sib_machine=$(grep '^machine:' "$_sibling_lock" 2>/dev/null | head -1 | sed 's/^machine: *//')
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }SIBLING_SESSION: active (${_sib_machine:-unknown})"
    else
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }SIBLING_SESSION: none"
    fi
fi

# Check 25: Detect blank session-context.md — warn agent to populate deterministic fields
if [[ -f "$PROJECT_DIR/session-context.md" ]]; then
    _sc_updated=$(sed -n 's/.*\*\*Last Updated\*\*: \(.\+\)/\1/p' "$PROJECT_DIR/session-context.md" 2>/dev/null | head -1)
    _sc_machine=$(sed -n 's/.*\*\*Machine\*\*: \(.\+\)/\1/p' "$PROJECT_DIR/session-context.md" 2>/dev/null | head -1)
    if [[ -z "$_sc_updated" && -z "$_sc_machine" ]]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }session-context.md has blank template fields — populate Last Updated, Machine, Working Directory, and Session Goal (loading protocol step 9)."
    fi
fi
