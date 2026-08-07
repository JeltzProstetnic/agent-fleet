#!/usr/bin/env bash
# UserPromptSubmit hook: inject context budget, checkpoint nudge, mobile data,
# and GPI completion notifications.
# Reads ~/.claude/.context-budget.json (written by statusline.sh every turn)
# Reads ~/.claude/.gpi-completed.json (written by gpi done / statusline log detection)
# Outputs plain text lines for injection (UserPromptSubmit uses stdout, not JSON)

source "$(dirname "${BASH_SOURCE[0]}")/lib-portable.sh" 2>/dev/null || true

OUTPUT=""

# Read ALL of stdin ONCE, up front — the sidecar lookup needs session_id and
# the trigger detection below needs message. `read` fails on input without a
# trailing newline, so use IFS + -d '' to grab everything or fall back silently.
_hook_input=""
IFS= read -r -t 2 -d '' _hook_input 2>/dev/null || true
_session_id=$(printf '%s' "$_hook_input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null) || true

# Context budget from this session's statusline sidecar.
# Keyed by session id (CFG-458) — a shared sidecar is last-writer-wins across
# concurrent sessions, which silently injected another session's numbers.
# If this session has no sidecar yet, stay silent rather than guess.
SIDECAR="${CONTEXT_BUDGET_PATH:-}"
if [[ -z "$SIDECAR" && -n "$_session_id" ]]; then
    SIDECAR="${CONTEXT_BUDGET_DIR:-$HOME/.claude}/.context-budget-${_session_id}.json"
fi
if [[ -n "$SIDECAR" && -f "$SIDECAR" ]]; then
    read -r PCT USED_K SIZE_K 2>/dev/null <<< "$(python3 -c "
import json, sys
try:
    d = json.load(open('$SIDECAR'))
    print(d['pct'], d['used_k'], d['size'] // 1000)
except Exception:
    sys.exit(1)
" 2>/dev/null)" || true
    if [[ -n "$PCT" ]]; then
        OUTPUT="CONTEXT_BUDGET: ${PCT}% used (${USED_K}k/${SIZE_K}k)"
    fi
fi

# Checkpoint nudge when context >70% (fires once until compaction resets)
CHECKPOINT_THRESHOLD=70
CHECKPOINT_MARKER="${CHECKPOINT_MARKER:-$HOME/.claude/.checkpoint-nudged}"
if [[ -n "$PCT" ]]; then
    if [[ "$PCT" -ge "$CHECKPOINT_THRESHOLD" ]]; then
        if [[ ! -f "$CHECKPOINT_MARKER" ]]; then
            OUTPUT="${OUTPUT:+$OUTPUT | }CHECKPOINT_NEEDED: context at ${PCT}%, update session-context.md"
            touch "$CHECKPOINT_MARKER"
        fi
    else
        # Context dropped (post-compaction or /clear) — reset marker
        rm -f "$CHECKPOINT_MARKER"
    fi
fi

# Mid-session mobile branch check (timer-gated, default 10 min)
MOBILE_REPO="${MOBILE_REPO:-$HOME/agent-fleet-mobile}"
MOBILE_CHECK_MARKER="${MOBILE_CHECK_MARKER:-$HOME/.claude/.mobile-last-check}"
MOBILE_CHECK_INTERVAL="${MOBILE_CHECK_INTERVAL:-600}"  # seconds
if [[ -d "$MOBILE_REPO/.git" ]]; then
    _do_mobile_check=false
    if [[ ! -f "$MOBILE_CHECK_MARKER" ]]; then
        _do_mobile_check=true
    elif [[ "$MOBILE_CHECK_INTERVAL" -eq 0 ]]; then
        _do_mobile_check=true
    else
        _marker_age=$(( $(date +%s) - $(_stat_mtime "$MOBILE_CHECK_MARKER" 2>/dev/null || echo 0) ))
        [[ "$_marker_age" -ge "$MOBILE_CHECK_INTERVAL" ]] && _do_mobile_check=true
    fi
    if [[ "$_do_mobile_check" == "true" ]]; then
        touch "$MOBILE_CHECK_MARKER"
        # Check for unmerged claude/* branches (local only — no network fetch mid-session)
        _claude_branches=$(git -C "$MOBILE_REPO" branch --list 'claude/*' 2>/dev/null | wc -l)
        if [[ "$_claude_branches" -gt 0 ]]; then
            OUTPUT="${OUTPUT:+$OUTPUT | }MOBILE_DATA: ${_claude_branches} unmerged claude/* branch(es) in agent-fleet-mobile. Run mobile-collect or start new session to ingest."
        fi
    fi
fi

# GPI completion notifications — one-shot, consumed after reading
GPI_COMPLETED="${GPI_COMPLETED_PATH:-$HOME/.claude/.gpi-completed.json}"
if [[ -f "$GPI_COMPLETED" ]]; then
    GPI_NOTIF=$(python3 -c "
import json, sys, os
try:
    d = json.load(open('$GPI_COMPLETED'))
    if d:
        labels = [e.get('label', e.get('id', '?')) for e in d]
        print('GPI_COMPLETED: ' + ', '.join(labels) + ' finished')
        os.remove('$GPI_COMPLETED')
except Exception:
    pass
" 2>/dev/null) || true
    if [[ -n "$GPI_NOTIF" ]]; then
        OUTPUT="${OUTPUT:+$OUTPUT | }$GPI_NOTIF"
    fi
fi

# LRN skill trigger detection — safety net for skill invocation
# Live-issue capture trigger detection (CFG-389) — injects LIVE_ISSUE_DETECTED
#   when user reports a real-time failure; agent loads knowledge/live-issue-capture.md.
# stdin was consumed at the top of this script — reuse the captured payload.
if [[ -n "$_hook_input" ]]; then
    _user_msg=$(printf '%s' "$_hook_input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null) || true
    if [[ "$_user_msg" =~ (^|[[:space:]])(lrn|LRN)($|[[:space:]]) ]]; then
        OUTPUT="${OUTPUT:+$OUTPUT | }LRN_TRIGGERED: Invoke the lrn skill via Skill tool. Load SKILL.md + references/known-faulty-patterns.md before responding."
    fi
    # Live-issue trigger phrases — present-tense failure reports
    # `bug`, `no media`, `broke it`, `broken again` need [^a-z] word boundaries to avoid false matches in "debug", "no medians", etc.
    # AGAIN (all-caps) checked separately on original-case message — the lowercase "again" is too common to trigger on.
    _lc_msg=$(printf '%s' "$_user_msg" | tr '[:upper:]' '[:lower:]')
    _lc_msg_padded=" ${_lc_msg} "
    _live_re='([^a-z]bug[^a-z]|[^a-z]no media[^a-z]|[^a-z]broke it[^a-z]|[^a-z]broken again[^a-z]|invisible media|keeps showing no media|is stuck|got stuck|is hanging|is hung|wont respond|won'"'"'t respond|isnt responding|isn'"'"'t responding|cant dismiss|can'"'"'t dismiss|cant close|can'"'"'t close|failed to load|fails to load|wont load|won'"'"'t load|just crashed|popup error|error popup)'
    if [[ "$_lc_msg_padded" =~ $_live_re ]] || [[ "$_user_msg" =~ (^|[^A-Z])AGAIN([^A-Z]|$) ]]; then
        OUTPUT="${OUTPUT:+$OUTPUT | }LIVE_ISSUE_DETECTED: user reports a real-time failure. Capture live state synchronously (ps/logs/curl/pid files — whatever applies) in this same turn, then delegate deep investigation to a subagent with captured state in the prompt. Load knowledge/live-issue-capture.md for the protocol. Do NOT defer with 'capture if it recurs'."
    fi
fi

[[ -n "$OUTPUT" ]] && echo "$OUTPUT"
exit 0
