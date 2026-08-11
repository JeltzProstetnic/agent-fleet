# Check group 7b: Platform, docs & lock checks
# Checks: 29(wsl.conf), 30(doc coherence), 33(mail check), 31(session lock)
# Shared vars used: CONFIG_REPO, WARNINGS, INBOX_MSG, PROJECT_DIR
# Split from original 07-environment.sh; settings/tools checks remain in 07-environment.sh

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

# Check 33: Email check — surface recent labeled emails at startup (optional)
# If you have a mail check script, configure it here
MAIL_CHECK_SCRIPT="${MAIL_CHECK_SCRIPT:-$CONFIG_REPO/setup/scripts/mail-check.sh}"
if [ -f "$MAIL_CHECK_SCRIPT" ]; then
    MAIL_OUTPUT=$(timeout 10 bash "$MAIL_CHECK_SCRIPT" --since 24 2>/dev/null || true)
    if [ -n "$MAIL_OUTPUT" ]; then
        MAIL_SUBJECTS=$(echo "$MAIL_OUTPUT" | python3 -c "
import json,sys
msgs=[]
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        d=json.loads(line)
        msgs.append(d.get('subject','?'))
    except: pass
if msgs: print(f'MAIL: {len(msgs)} message(s) in last 24h: ' + '; '.join(msgs))
" 2>/dev/null || true)
        if [ -n "$MAIL_SUBJECTS" ]; then
            INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }$MAIL_SUBJECTS"
        fi
    fi
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
