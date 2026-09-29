#!/usr/bin/env bash
# Check group 7b: Platform & docs checks
# Checks: 7b.1, 7b.2, 7b.3 (the session lock, formerly 7b.4, is checks/07c-session-lock.sh — CFG-721)
# Shared vars used: CONFIG_REPO, WARNINGS, INBOX_MSG, PROJECT_DIR
# Split from original 07-environment.sh; settings/tools checks remain in 07-environment.sh

# Check 7b.1: wsl.conf duplicate section validation
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

# Check 7b.2: Doc coherence header validation
_doc_coherence_files=(
    "global/CLAUDE.md"
    "global/reference/mcp-catalog.md"
    "global/reference/mcp-servers.md"
    "global/reference/mcp-troubleshooting.md"
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

# Check 7b.3: Email check — surface recent labeled emails at startup (optional)
# Data-driven (CFG-676): the first setup/scripts/*mail-check.sh is used, MAIL_CHECK_SCRIPT
# overrides; the tag comes from the name (`acme-mail-check.sh` → ACME_MAIL:, `mail-check.sh`
# → MAIL:), MAIL_CHECK_TAG overrides. Script takes `--since <hours>`, prints one JSON object per line.
MAIL_CHECK_SCRIPT="${MAIL_CHECK_SCRIPT:-$(ls "$CONFIG_REPO"/setup/scripts/*mail-check.sh 2>/dev/null | head -1)}"
if [ -n "$MAIL_CHECK_SCRIPT" ] && [ -f "$MAIL_CHECK_SCRIPT" ]; then
    _mcs_tag="$(basename "$MAIL_CHECK_SCRIPT" .sh)"; _mcs_tag="${_mcs_tag%mail-check}"; _mcs_tag="${_mcs_tag%-}"
    if [ -n "$_mcs_tag" ]; then _mcs_tag="$(printf '%s' "$_mcs_tag" | tr 'a-z.-' 'A-Z__')_MAIL"; else _mcs_tag="MAIL"; fi
    MAIL_CHECK_TAG="${MAIL_CHECK_TAG:-$_mcs_tag}"
    MAIL_OUTPUT=$(timeout 10 bash "$MAIL_CHECK_SCRIPT" --since 24 2>/dev/null || true)
    if [ -n "$MAIL_OUTPUT" ]; then
        MAIL_SUBJECTS=$(echo "$MAIL_OUTPUT" | python3 -c "
import json,sys
def s(l):
    try: return json.loads(l).get('subject','?')
    except Exception: return None
m=[x for x in map(s,sys.stdin) if x is not None]
if m: print(f'{sys.argv[1]}: {len(m)} message(s) in last 24h: ' + '; '.join(m))
" "$MAIL_CHECK_TAG" 2>/dev/null || true)
        if [ -n "$MAIL_SUBJECTS" ]; then
            INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }$MAIL_SUBJECTS"
        fi
    fi
fi
