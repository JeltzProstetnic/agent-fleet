#!/bin/bash
# Context usage statusline for Claude Code
# Shows: [Model] ▓▓▓▓░░░░░░ 108k/200k (54%) | Assistant
# Color: green <70%, yellow 70-89%, red 90%+
# Persona indicator reads from ~/.claude/.active-persona (written by Claude)
input=$(cat)
python3 -c "
import json, sys, os

# Persona colors (ANSI) — must match personas.md Color field
PERSONA_COLORS = {
    'Assistant': '\033[93m',   # bright-yellow
    'Supporter': '\033[95m',   # bright-magenta (pink)
}

try:
    d = json.loads(sys.stdin.read())
    model = d.get('model', {}).get('display_name', '?')
    cw = d.get('context_window') or {}
    pct = cw.get('used_percentage') or 0
    win_size = cw.get('context_window_size') or 200000
    cu = cw.get('current_usage') or {}
    input_tokens = (cu.get('input_tokens') or 0) + (cu.get('cache_creation_input_tokens') or 0) + (cu.get('cache_read_input_tokens') or 0)
    used_k = int(win_size * pct / 100000)
    # If used_percentage is 0 but tokens exist, derive percentage from tokens
    if used_k == 0 and input_tokens > 0:
        used_k = input_tokens // 1000
        pct = (input_tokens / win_size) * 100  # recalculate percentage
    pct_int = int(pct)
    total_k = win_size // 1000
    bar_w = 10
    filled = pct_int * bar_w // 100
    empty = bar_w - filled
    if pct_int >= 90:
        c = '\033[31m'
    elif pct_int >= 70:
        c = '\033[33m'
    else:
        c = '\033[32m'
    r = '\033[0m'
    bar = '\u2593' * filled + '\u2591' * empty

    # Read active persona
    persona_str = ''
    persona_file = os.path.expanduser('~/.claude/.active-persona')
    try:
        with open(persona_file) as f:
            name = f.read().strip()
        if name:
            pc = PERSONA_COLORS.get(name, '\033[36m')  # default cyan
            persona_str = f' {pc}{name}{r}'
    except FileNotFoundError:
        pass

    # AFK mode indicator
    afk_str = ''
    afk_marker = os.path.expanduser('~/.afd-afk')
    if os.path.exists(afk_marker):
        afk_str = f' \033[91m[AFK]\033[0m'

    sys.stdout.write(f'[{model}] {c}{bar} {used_k}k/{total_k}k ({pct_int}%){r}{persona_str}{afk_str}\n')
except Exception:
    sys.stdout.write('[?] ...\n')
" <<< "$input"
