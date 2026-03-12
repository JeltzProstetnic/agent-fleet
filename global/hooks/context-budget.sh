#!/usr/bin/env bash
# UserPromptSubmit hook: inject context budget + GPI completion notifications
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
