# Check group 7: Environment — plugins, splash, bartl mail, afleet, TweakCC, wsl, coherence, lock
# Checks: 19(plugins), 32, 33, 27, 28, 29, 30, 31
# Shared vars used: CONFIG_REPO, WARNINGS, INBOX_MSG, SETTINGS_FILE, PROJECT_DIR

# Check 19: Auto-disable global enabledPlugins (token budget protection)
if [ -f "$SETTINGS_FILE" ]; then
    if grep -q '"enabledPlugins"' "$SETTINGS_FILE" 2>/dev/null; then
        _ep_tmp="$(mktemp)"
        printf '%s\n' 'import json,sys,os' 'f=sys.argv[1]' 'd=json.load(open(f))' 'ep=d.get("enabledPlugins",{})' 'n=len(ep)' 'if n>0:' '  d["enabledPlugins"]={}' '  t=f+".tmp"; open(t,"w").write(json.dumps(d,indent=2)+"\n"); os.rename(t,f)' 'print(n)' > "$_ep_tmp"
        _ep_count=$(python3 "$_ep_tmp" "$SETTINGS_FILE" 2>/dev/null || echo "0")
        rm -f "$_ep_tmp"
        if [ "$_ep_count" -gt 0 ]; then
            WARNINGS="${WARNINGS:+$WARNINGS | }Global enabledPlugins had $_ep_count plugin(s) — auto-disabled. Plugins consume ~10k tokens/bundle. Enable per-project only via .claude/settings.local.json."
        fi
    fi
fi

# Check 32: Auto-fix CC_MIRROR_SPLASH drift
if [ -f "$SETTINGS_FILE" ]; then
    if grep -q '"CC_MIRROR_SPLASH"' "$SETTINGS_FILE" 2>/dev/null; then
        _splash_val=$(python3 -c "import json; d=json.load(open('$SETTINGS_FILE')); print(d.get('env',{}).get('CC_MIRROR_SPLASH','0'))" 2>/dev/null || echo "0")
        if [ "$_splash_val" != "0" ]; then
            python3 -c "
import json, sys, os
f = sys.argv[1]
with open(f) as fh: d = json.load(fh)
if 'env' in d and 'CC_MIRROR_SPLASH' in d['env']:
    d['env']['CC_MIRROR_SPLASH'] = '0'
    t = f + '.tmp'
    with open(t, 'w') as fh: json.dump(d, fh, indent=2); fh.write('\n')
    os.rename(t, f)
" "$SETTINGS_FILE" 2>/dev/null || true
        fi
    fi
fi

# Check 33: Persona mail check — surface recent persona-labeled emails at startup
# Configure PERSONA_MAIL_SCRIPT in your machine file or environment to enable.
PERSONA_MAIL_SCRIPT="${PERSONA_MAIL_SCRIPT:-$CONFIG_REPO/setup/scripts/persona-mail-check.sh}"
if [ -f "$PERSONA_MAIL_SCRIPT" ]; then
    PERSONA_MAIL_OUTPUT=$(timeout 10 bash "$PERSONA_MAIL_SCRIPT" --since 24 2>/dev/null || true)
    if [ -n "$PERSONA_MAIL_OUTPUT" ]; then
        PERSONA_MAIL_SUBJECTS=$(echo "$PERSONA_MAIL_OUTPUT" | python3 -c "
import json,sys
msgs=[]
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        d=json.loads(line)
        msgs.append(d.get('subject','?'))
    except: pass
if msgs: print(f'PERSONA_MAIL: {len(msgs)} message(s) in last 24h: ' + '; '.join(msgs))
" 2>/dev/null || true)
        if [ -n "$PERSONA_MAIL_SUBJECTS" ]; then
            INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }$PERSONA_MAIL_SUBJECTS"
        fi
    fi
fi

# Check 27: afleet mandatory — warn if launched directly via mclaude
if [[ -z "${AFLEET_LAUNCHED:-}" ]]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }Session NOT launched via afleet. Use 'afleet' instead of 'mclaude' — afleet handles pre-pull, project detection, and session safety. Direct mclaude launch skips fleet infrastructure."
fi

# Check 28: TweakCC stale patch detection
CC_MIRROR_DIR="${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}"
TWEAKCC_CONFIG="$CC_MIRROR_DIR/tweakcc/config.json"
CC_PACKAGE="$CC_MIRROR_DIR/npm/node_modules/@anthropic-ai/claude-code/package.json"
if [ -f "$TWEAKCC_CONFIG" ] && [ -f "$CC_PACKAGE" ]; then
    _tweak_ver=$(python3 -c "import json; print(json.load(open('$TWEAKCC_CONFIG')).get('ccVersion',''))" 2>/dev/null || true)
    _tweak_applied=$(python3 -c "import json; print(json.load(open('$TWEAKCC_CONFIG')).get('changesApplied',True))" 2>/dev/null || true)
    _cc_ver=$(python3 -c "import json; print(json.load(open('$CC_PACKAGE')).get('version',''))" 2>/dev/null || true)
    if [ -n "$_tweak_ver" ] && [ -n "$_cc_ver" ] && [ "$_tweak_ver" != "$_cc_ver" ] && [ "$_tweak_applied" = "False" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }TweakCC patches stale (applied to $_tweak_ver, installed CC is $_cc_ver) — run \`cc-mirror tweak mclaude\` from interactive terminal."
    fi
fi

# Check 29: wsl.conf duplicate section validation
_is_wsl=0
if [ "${_FORCE_WSL:-}" = "1" ]; then
    _is_wsl=1
elif [ "${_FORCE_WSL:-}" = "0" ]; then
    _is_wsl=0
elif [ -d "/mnt/c" ] || grep -qi "microsoft" /proc/version 2>/dev/null; then
    _is_wsl=1
fi
if [ "$_is_wsl" -eq 1 ]; then
    _wsl_conf="${_WSL_CONF_PATH:-/etc/wsl.conf}"
    if [ -f "$_wsl_conf" ]; then
        _wsl_dups=$(awk '/^\[.+\]$/ { count[$0]++; name[$0]=$0 } END { for (s in count) if (count[s]>1) { gsub(/[\[\]]/, "", name[s]); printf "%s ", name[s] } }' "$_wsl_conf")
        _wsl_dups=$(echo "$_wsl_dups" | sed 's/ $//')
        if [ -n "$_wsl_dups" ]; then
            _wsl_backup="${_wsl_conf}.bak.$(date +%Y%m%d%H%M%S)"
            cp "$_wsl_conf" "$_wsl_backup"
            _wsl_merged=$(python3 -c "
import sys, collections
sections = collections.OrderedDict()
current = ''
with open(sys.argv[1]) as f:
    for line in f:
        line = line.rstrip('\n')
        stripped = line.strip()
        if stripped.startswith('[') and stripped.endswith(']'):
            current = stripped
            if current not in sections:
                sections[current] = collections.OrderedDict()
        elif '=' in line and current:
            key = line.split('=', 1)[0].strip()
            sections[current][key] = line
        elif current and stripped:
            sections[current]['__line_' + str(len(sections[current]))] = line
for sec, keys in sections.items():
    print(sec)
    for k, v in keys.items():
        print(v)
" "$_wsl_conf" 2>/dev/null) || true
            if [ -n "$_wsl_merged" ]; then
                echo "$_wsl_merged" > "$_wsl_conf"
                WARNINGS="${WARNINGS:+$WARNINGS | }wsl.conf has duplicate [section] headers: $_wsl_dups. Settings in duplicate sections may be silently ignored. Auto-fixed: merged duplicate sections (backup: $_wsl_backup)."
            else
                WARNINGS="${WARNINGS:+$WARNINGS | }wsl.conf has duplicate [section] headers: $_wsl_dups. Settings in duplicate sections may be silently ignored. Auto-fix failed — merge manually."
            fi
        fi
    fi
fi

# Check 30: Doc coherence header validation
_doc_coherence_files=(
    "global/CLAUDE.md"
    "global/reference/mcp-catalog.md"
    "cross-project/infrastructure-strategy.md"
    "registry.md"
)
for _mf in "$CONFIG_REPO"/global/machines/*.md; do
    [ -f "$_mf" ] && _doc_coherence_files+=("global/machines/$(basename "$_mf")")
done
_doc_missing=()
for _dcf in "${_doc_coherence_files[@]}"; do
    _dcf_path="$CONFIG_REPO/$_dcf"
    [ -f "$_dcf_path" ] || continue
    if ! head -5 "$_dcf_path" | grep -q '<!-- updates:'; then
        _doc_missing+=("$_dcf")
    fi
done
if [ ${#_doc_missing[@]} -gt 0 ]; then
    _doc_count=${#_doc_missing[@]}
    _doc_list=$(printf '%s, ' "${_doc_missing[@]}" | sed 's/, $//')
    WARNINGS="${WARNINGS:+$WARNINGS | }doc coherence: $_doc_count file(s) missing <!-- updates: --> header: $_doc_list"
fi

# Check 31: Session lock — detect if another session holds this project
_SESSION_LOCK_LIB="$CONFIG_REPO/setup/scripts/session-lock.sh"
if [ -f "$_SESSION_LOCK_LIB" ]; then
    source "$_SESSION_LOCK_LIB"
    check_lock "$PWD" 2>/dev/null
    _lock_rc=$?

    if [[ $_lock_rc -eq 2 ]] && [[ -n "${AFLEET_SESSION_ID:-}" ]]; then
        _read_lock "$PWD/.claude/.session-lock" 2>/dev/null
        if [[ "$_LOCK_SESSION" == "$AFLEET_SESSION_ID" ]]; then
            _lock_rc=1
        fi
    fi

    case $_lock_rc in
        2)
            _read_lock "$PWD/.claude/.session-lock" 2>/dev/null
            WARNINGS="${WARNINGS:+$WARNINGS | }SESSION_LOCKED: Project locked by PID $_LOCK_PID (session $_LOCK_SESSION) on this machine. FOLLOWER — load knowledge/follower-mode.md and follow it."
            ;;
        3)
            _read_lock "$PWD/.claude/.session-lock" 2>/dev/null
            WARNINGS="${WARNINGS:+$WARNINGS | }SESSION_LOCKED_REMOTE: Project locked by $_LOCK_MACHINE (session $_LOCK_SESSION). FOLLOWER — load knowledge/follower-mode.md and follow it."
            ;;
        0)
            acquire_lock "$PWD" "${AFLEET_SESSION_ID:-}" 2>/dev/null
            ;;
        1)
            ;;
    esac
fi
