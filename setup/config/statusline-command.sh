#!/bin/bash
# Context usage statusline for Claude Code
# Shows: project [Model] ▓▓▓▓░░░░░░ 108k/200k (54%) $12.34 {persona}
# Color: green <50%, cyan 50-59%, orange 60-69%, yellow 70-79%, red 80%+
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
    win_size = cw.get('context_window_size') or 1000000
    cu = cw.get('current_usage') or {}
    input_tokens = (cu.get('input_tokens') or 0) + (cu.get('cache_creation_input_tokens') or 0) + (cu.get('cache_read_input_tokens') or 0)
    # Prefer used_percentage (CC's own calc). Only fall back to token-based if
    # used_percentage is truly 0 AND tokens exist — never mix methods mid-session.
    if pct > 0:
        used_k = int(win_size * pct / 100000)
    elif input_tokens > 0:
        used_k = input_tokens // 1000
        pct = (input_tokens / win_size) * 100
    else:
        used_k = 0
    pct_int = int(pct)
    total_k = win_size // 1000
    bar_w = 10
    filled = pct_int * bar_w // 100
    empty = bar_w - filled
    if pct_int >= 80:
        c = '\033[31m'        # red
    elif pct_int >= 70:
        c = '\033[93m'        # bright yellow
    elif pct_int >= 60:
        c = '\033[38;5;208m'  # orange (256-color)
    elif pct_int >= 50:
        c = '\033[36m'        # cyan (first warning)
    else:
        c = '\033[32m'        # green
    r = '\033[0m'
    dim = '\033[2m'
    bar = '\u2593' * filled + '\u2591' * empty

    # Project name from workspace
    project_dir = d.get('workspace', {}).get('project_dir', '')
    project = os.path.basename(project_dir) if project_dir else '?'
    project_str = f'{dim}{project}{r}'

    # Cost — opt-in only (subscription users don't need it). Set STATUSLINE_SHOW_COST=1 for API billing.
    cost_str = ''
    if os.environ.get('STATUSLINE_SHOW_COST') == '1':
        cost = d.get('cost', {}).get('total_cost_usd', 0)
        cost_str = f' \${cost:.2f}' if cost and cost > 0 else ''

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
    gpi_completed_path = os.path.expanduser('~/.claude/.gpi-completed.json')
    if os.path.exists(gpi_path):
        try:
            import time as _t, re as _re, fcntl as _fcntl
            with open(gpi_path) as f:
                gpi = json.loads(f.read())
            ops = gpi.get('ops', {})
            gpi_updated = gpi.get('updated', 0)
            now = _t.time()
            age = now - gpi_updated
            # Staleness: also check log file mtimes — active logs prevent staleness
            log_fresh = False
            for opv in ops.values():
                lp = opv.get('log_path')
                if lp and os.path.exists(lp):
                    try:
                        log_age = now - os.path.getmtime(lp)
                        if log_age < 600:
                            log_fresh = True
                    except Exception:
                        pass
            if ops and (age < 600 or log_fresh):
                dp = '\033[2m' if (age > 300 and not log_fresh) else ''
                state_dirty = False
                # Enrich ops that have log_path — parse live progress from log file
                for opk, opv in list(ops.items()):
                    lp = opv.get('log_path')
                    if lp and os.path.exists(lp) and not opv.get('completed_at'):
                        try:
                            with open(lp, 'rb') as lf:
                                lf.seek(0, 2)
                                sz = lf.tell()
                                lf.seek(max(0, sz - 2000))
                                chunk = lf.read().decode('utf-8', errors='ignore')
                            lines = chunk.replace('\r', '\n').strip().split('\n')
                            last = lines[-1].strip() if lines else ''
                            if 'RSYNC COMPLETE' in last or 'RSYNC DONE' in last:
                                opv['pct'] = 100
                                opv['detail'] = 'DONE'
                                # Mark as completed in state for auto-cleanup
                                opv['completed_at'] = int(now)
                                state_dirty = True
                                # Write notification sidecar
                                notif = [{'id': opk, 'label': opv.get('label', opk), 'completed_at': int(now)}]
                                try:
                                    if os.path.exists(gpi_completed_path):
                                        with open(gpi_completed_path) as nf:
                                            existing = json.loads(nf.read())
                                        notif = existing + notif
                                    with open(gpi_completed_path, 'w') as nf:
                                        nf.write(json.dumps(notif))
                                except Exception:
                                    pass
                            else:
                                # Parse ir-chk=M/T from any recent line for overall progress
                                irchk_m = None
                                for ln in reversed(lines):
                                    m = _re.search(r'ir-chk=(\d+)/(\d+)', ln)
                                    if m:
                                        remaining, total = int(m.group(1)), int(m.group(2))
                                        if total > 0:
                                            opv['pct'] = int((total - remaining) * 100 / total)
                                        irchk_m = m
                                        break
                                # Extract speed — last token matching */s pattern, integer precision
                                spd = ''
                                for ln in reversed(lines):
                                    parts_l = ln.split()
                                    speeds = [x for x in parts_l if '/s' in x]
                                    if speeds:
                                        raw_spd = speeds[-1]
                                        sm = _re.match(r'([\d.]+)(.*)', raw_spd)
                                        if sm:
                                            spd = str(int(float(sm.group(1)))) + sm.group(2)
                                        else:
                                            spd = raw_spd
                                        break
                                # Detail: only speed (no raw bytes, no duplicate pct)
                                opv['detail'] = spd if spd else None
                        except Exception:
                            pass
                # Write back state if log enrichment detected completion
                if state_dirty:
                    try:
                        gpi['ops'] = ops
                        gpi['updated'] = int(now)
                        lock_path = gpi_path + '.lock'
                        with open(lock_path, 'w') as lkf:
                            _fcntl.flock(lkf, _fcntl.LOCK_EX)
                            with open(gpi_path, 'w') as sf:
                                sf.write(json.dumps(gpi))
                            _fcntl.flock(lkf, _fcntl.LOCK_UN)
                    except Exception:
                        pass
                # Filter: hide completed ops older than 60s, auto-clean from state
                visible_ops = {}
                expired_ids = []
                for opk, opv in ops.items():
                    ca = opv.get('completed_at')
                    if ca and (now - ca) > 60:
                        expired_ids.append(opk)
                    else:
                        visible_ops[opk] = opv
                # Clean expired from state file
                if expired_ids:
                    try:
                        for eid in expired_ids:
                            del gpi['ops'][eid]
                        gpi['updated'] = int(now)
                        lock_path = gpi_path + '.lock'
                        with open(lock_path, 'w') as lkf:
                            _fcntl.flock(lkf, _fcntl.LOCK_EX)
                            with open(gpi_path, 'w') as sf:
                                sf.write(json.dumps(gpi))
                            _fcntl.flock(lkf, _fcntl.LOCK_UN)
                    except Exception:
                        pass
                active = list(visible_ops.values())
                count = len(active)
                if count == 1:
                    op = active[0]
                    si, st = op.get('seq_index'), op.get('seq_total')
                    is_done = op.get('completed_at') is not None
                    if is_done:
                        p = 'DONE'
                    elif op.get('pct') is not None:
                        p = str(op.get('pct')) + '%'
                    else:
                        p = '...'
                    lbl = op.get('label', '?')
                    dtl = ' ' + op['detail'] if op.get('detail') else ''
                    done_c = '\033[32m' if is_done else '\033[36m'
                    if si and st:
                        gpi_str = ' ' + dp + done_c + '[' + str(si) + '/' + str(st) + ' ' + lbl + ' ' + p + ']' + r
                    else:
                        gpi_str = ' ' + dp + done_c + '[' + lbl + ' ' + p + dtl + ']' + r
                elif count > 1:
                    # Show only the single largest/slowest op with +N suffix
                    # Rank by pct (highest first), tie-break by started (oldest first = longest running)
                    def _sort_key(o):
                        p = o.get('pct') if o.get('pct') is not None else 0
                        s = o.get('started') or 0
                        return (-p, s)
                    ranked = sorted(active, key=_sort_key)
                    op = ranked[0]
                    others = count - 1
                    is_done = op.get('completed_at') is not None
                    if is_done:
                        p = 'DONE'
                    elif op.get('pct') is not None:
                        p = str(op.get('pct')) + '%'
                    else:
                        p = '...'
                    lbl = op.get('label', '?')
                    dtl = ' ' + op['detail'] if op.get('detail') else ''
                    done_c = '\033[32m' if is_done else '\033[36m'
                    suffix = ' +' + str(others) if others > 0 else ''
                    gpi_str = ' ' + dp + done_c + '[' + lbl + ' ' + p + dtl + suffix + ']' + r
        except Exception:
            pass

    # Send heartbeat to AFD server if session lock is active
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
