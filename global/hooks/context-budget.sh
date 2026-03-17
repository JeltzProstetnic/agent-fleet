#!/usr/bin/env bash
# UserPromptSubmit hook: inject context budget, checkpoint nudge, mobile data,
# and GPI completion notifications.
# Reads ~/.claude/.context-budget.json (written by statusline.sh every turn)
# Reads ~/.claude/.gpi-completed.json (written by gpi done / statusline log detection)
# Outputs systemMessage lines for injection

OUTPUT=""

# Context budget from statusline sidecar
SIDECAR="${CONTEXT_BUDGET_PATH:-$HOME/.claude/.context-budget.json}"
if [[ -f "$SIDECAR" ]]; then
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
        _marker_age=$(( $(date +%s) - $(stat -c %Y "$MOBILE_CHECK_MARKER" 2>/dev/null || echo 0) ))
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

[[ -n "$OUTPUT" ]] && echo "$OUTPUT"
exit 0
