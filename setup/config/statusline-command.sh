#!/bin/bash
# Context usage statusline for Claude Code
# Shows: {project} [{Model}] ▓▓▓▓░░░░░░ 108k/200k (54%) {persona} {afk} {gpi}
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
    dim = '\033[2m'
    bar = '\u2593' * filled + '\u2591' * empty

    # Project name from workspace
    project_dir = d.get('workspace', {}).get('project_dir', '')
    project = os.path.basename(project_dir) if project_dir else '?'
    project_str = f'{dim}{project}{r}'

    # Cost
    cost = d.get('cost', {}).get('total_cost_usd', 0)
    cost_str = ''

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

    # GPI (Grind Progress Indicator) — reads state file from gpi.sh
    gpi_str = ''
    gpi_path = os.path.expanduser('~/.claude/.gpi-state.json')
    if os.path.exists(gpi_path):
        try:
            import time as _t
            with open(gpi_path) as f:
                gpi = json.loads(f.read())
            ops = gpi.get('ops', {})
            gpi_updated = gpi.get('updated', 0)
            age = _t.time() - gpi_updated
            if ops and age < 600:
                dp = '\033[2m' if age > 300 else ''
                # Enrich ops that have log_path — parse live progress from log file
                for opv in ops.values():
                    lp = opv.get('log_path')
                    if lp and os.path.exists(lp):
                        try:
                            with open(lp, 'rb') as lf:
                                lf.seek(0, 2)
                                sz = lf.tell()
                                lf.seek(max(0, sz - 500))
                                chunk = lf.read().decode('utf-8', errors='ignore')
                            last = chunk.replace('\r', '\n').strip().split('\n')[-1].strip()
                            if 'RSYNC COMPLETE' in last or 'RSYNC DONE' in last:
                                opv['pct'] = 100
                                opv['detail'] = 'DONE'
                            elif last:
                                parts = last.split()
                                szv = parts[0] if parts else ''
                                pct_v = next((x for x in parts if x.endswith('%')), '')
                                spd = next((x for x in parts if '/s' in x), '')
                                if pct_v:
                                    try: opv['pct'] = int(pct_v.rstrip('%'))
                                    except: pass
                                bits = [x for x in [szv, pct_v, spd] if x]
                                if bits:
                                    opv['detail'] = ' '.join(bits)
                        except Exception:
                            pass
                active = list(ops.values())
                count = len(active)
                if count == 1:
                    op = active[0]
                    si, st = op.get('seq_index'), op.get('seq_total')
                    p = str(op.get('pct')) + '%' if op.get('pct') is not None else '...'
                    lbl = op.get('label', '?')
                    dtl = ' ' + op['detail'] if op.get('detail') else ''
                    if si and st:
                        gpi_str = ' ' + dp + '\033[36m[' + str(si) + '/' + str(st) + ' ' + lbl + ' ' + p + ']' + r
                    else:
                        gpi_str = ' ' + dp + '\033[36m[' + lbl + ' ' + p + dtl + ']' + r
                else:
                    featured = max(active, key=lambda o: o.get('eta_secs', 0) or (_t.time() - o.get('started', _t.time())))
                    p = str(featured.get('pct')) + '%' if featured.get('pct') is not None else '...'
                    lbl = featured.get('label', '?')
                    gpi_str = ' ' + dp + '\033[36m[' + str(count) + '\u2016 ' + lbl + ' ' + p + ']' + r
        except Exception:
            pass

    # Send heartbeat to AFD server if session lock is active (CFG-101)
    session_id = os.environ.get('AFLEET_SESSION_ID', '')
    afd_token = os.environ.get('AFD_TOKEN', '')
    if session_id and afd_token and project != '?':
        try:
            import subprocess
            afd_url = os.environ.get('AFD_URL', '')
            if afd_url:
                subprocess.Popen(
                    ['curl', '-sf', '-X', 'PATCH',
                     f'{afd_url}/api/locks/{project}',
                     '-H', 'Content-Type: application/json',
                     '-H', f'Authorization: Bearer {afd_token}',
                     '-d', '{\"heartbeat\":true}'],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
                )
        except Exception:
            pass

    # Write context budget sidecar for agent self-awareness
    sidecar_path = os.environ.get('CONTEXT_BUDGET_PATH', os.path.expanduser('~/.claude/.context-budget.json'))
    try:
        import json as j2
        j2.dump({'pct': pct_int, 'remaining': 100 - pct_int, 'size': win_size, 'used_k': used_k}, open(sidecar_path, 'w'))
    except Exception:
        pass

    sys.stdout.write(f'{project_str} [{model}] {c}{bar} {used_k}k/{total_k}k ({pct_int}%){r}{cost_str}{persona_str}{afk_str}{gpi_str}\n')
except Exception:
    sys.stdout.write('[?] ...\n')
" <<< "$input"
