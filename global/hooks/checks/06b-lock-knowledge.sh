#!/usr/bin/env bash
# Check group 6b: Lock detection, project knowledge, sibling session, blank template
# Checks: 6b.1, 6b.2, 6b.3, 6b.4
# Shared vars used: CONFIG_REPO, WARNINGS, INBOX_MSG, PROJECT_DIR

# Check 6b.1: Knowledge file list — list .claude/knowledge/*.md + .claude/*.md
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

# Check 6b.2: Project session lock detection — stale/remote lock warnings (CFG-269)
_project_lock="$PROJECT_DIR/.claude/.session-lock"
if [ -f "$_project_lock" ]; then
    _lock_json=$(cat "$_project_lock" 2>/dev/null)
    _lock_parsed=$(python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(d.get('machine',''))
    print(d.get('pid',''))
    print(d.get('user',''))
    print(d.get('sessionId',''))
    print(d.get('timestamp',''))
except: pass
" <<< "$_lock_json" 2>/dev/null)
    if [ -n "$_lock_parsed" ]; then
        { read -r _lock_machine; read -r _lock_pid; read -r _lock_user; read -r _lock_session; read -r _lock_ts; } <<< "$_lock_parsed"

        # Compute age
        _lock_age="unknown"
        if [ -n "$_lock_ts" ]; then
            _lock_epoch=$(date -u -d "$_lock_ts" +%s 2>/dev/null) || true
            _now_epoch=$(date -u +%s)
            if [ -n "$_lock_epoch" ]; then
                _diff=$(( _now_epoch - _lock_epoch ))
                _days=$(( _diff / 86400 ))
                _hours=$(( (_diff % 86400) / 3600 ))
                _mins=$(( (_diff % 3600) / 60 ))
                if [ "$_days" -gt 0 ]; then _lock_age="${_days}d ${_hours}h"
                elif [ "$_hours" -gt 0 ]; then _lock_age="${_hours}h ${_mins}m"
                else _lock_age="${_mins}m"
                fi
            fi
        fi

        _current_host=$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo "unknown")
        if [ "$_lock_machine" = "$_current_host" ]; then
            if [ -n "${AFLEET_SESSION_ID:-}" ] && [ "$_lock_session" = "$AFLEET_SESSION_ID" ]; then
                : # Our own session's lock — normal, skip
            elif kill -0 "$_lock_pid" 2>/dev/null; then
                INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }SESSION_LOCKED: Another session active on this machine (PID $_lock_pid, age: $_lock_age)"
            else
                rm -f "$_project_lock"
                WARNINGS="${WARNINGS:+$WARNINGS | }STALE_LOCK_CLEARED: Cleared stale lock from this machine (session $_lock_session, PID $_lock_pid dead, age: $_lock_age)"
            fi
        else
            INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }SESSION_LOCKED_REMOTE: Lock held by $_lock_machine ($_lock_user, age: $_lock_age)"
        fi
    fi
fi

# Check 6b.3: Sibling session detection — config repo ↔ template repo cross-project write gate (CFG-329: marker-based)
_sibling_dir=""
if [[ -f "$PROJECT_DIR/.config-repo" ]]; then
    # Config repo — look for template sibling
    for _sd in "$HOME/agent-fleet" "$HOME/cfg-agent-fleet"; do
        [[ "$_sd" != "$PROJECT_DIR" && -f "$_sd/.template-repo" ]] && _sibling_dir="$_sd" && break
    done
elif [[ -f "$PROJECT_DIR/.template-repo" ]]; then
    # Template repo — look for config sibling
    for _sd in "$HOME/cfg-agent-fleet" "$HOME/agent-fleet"; do
        [[ "$_sd" != "$PROJECT_DIR" && -f "$_sd/.config-repo" ]] && _sibling_dir="$_sd" && break
    done
fi
if [ -n "$_sibling_dir" ] && [ -d "$_sibling_dir" ]; then
    _sibling_lock="$_sibling_dir/.claude/.session-lock"
    if [ -f "$_sibling_lock" ]; then
        _sib_machine=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('machine',''))" < "$_sibling_lock" 2>/dev/null)
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }SIBLING_SESSION: active (${_sib_machine:-unknown})"
    else
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }SIBLING_SESSION: none"
    fi
fi

# Check 6b.4: Detect blank session-context.md — warn agent to populate deterministic fields
if [[ -f "$PROJECT_DIR/session-context.md" ]]; then
    _sc_updated=$(sed -n 's/.*\*\*Last Updated\*\*: \(.\+\)/\1/p' "$PROJECT_DIR/session-context.md" 2>/dev/null | head -1)
    _sc_machine=$(sed -n 's/.*\*\*Machine\*\*: \(.\+\)/\1/p' "$PROJECT_DIR/session-context.md" 2>/dev/null | head -1)
    if [[ -z "$_sc_updated" && -z "$_sc_machine" ]]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }session-context.md has blank template fields — populate Last Updated, Machine, Working Directory, and Session Goal (loading protocol step 9)."
    fi
fi
