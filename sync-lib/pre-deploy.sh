#!/usr/bin/env bash
# sync-lib/pre-deploy.sh — Mechanical pre-deploy checks for sync.sh
# Sourced by sync.sh. Provides pre_deploy_checks().
#
# Checks: merge markers, bash syntax, JSON validity, hook safe-run audit.
# Returns 0 on pass, 1 on any failure.

# shellcheck source=common.sh
# Expects from caller: GLOBAL_DIR, SETUP_DIR (or SCRIPT_DIR), log_error

pre_deploy_checks() {
    local _global="${GLOBAL_DIR:-$SCRIPT_DIR/global}"
    local _setup="${SETUP_DIR:-$SCRIPT_DIR/setup}"
    local _fail=0

    # 1. Merge marker scan in global/ and setup/config/
    local _merge_files=""
    for _dir in "$_global" "$_setup/config"; do
        [ -d "$_dir" ] || continue
        _merge_files+=$(grep -rlE '^(<{7}|={7}|>{7})' "$_dir" 2>/dev/null || true)
    done
    if [ -n "$_merge_files" ]; then
        log_error "Pre-deploy: merge marker(s) found:"
        echo "$_merge_files" | while read -r f; do
            [ -n "$f" ] && log_error "  $f"
        done
        _fail=1
    fi

    # 2. Bash syntax validation for .sh files
    for _dir in "$_global/hooks" "$_setup/scripts"; do
        [ -d "$_dir" ] || continue
        for _sh in "$_dir"/*.sh; do
            [ -f "$_sh" ] || continue
            if ! bash -n "$_sh" 2>/dev/null; then
                log_error "Pre-deploy: bash syntax error in $_sh"
                _fail=1
            fi
        done
    done

    # 3. JSON validity for config files
    for _json in "$_setup/config"/*.json; do
        [ -f "$_json" ] || continue
        if command -v jq &>/dev/null; then
            if ! jq empty "$_json" 2>/dev/null; then
                log_error "Pre-deploy: invalid JSON in $_json"
                _fail=1
            fi
        elif command -v python3 &>/dev/null; then
            if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$_json" 2>/dev/null; then
                log_error "Pre-deploy: invalid JSON in $_json"
                _fail=1
            fi
        fi
    done

    # 4. Hook safe-run audit: verify all hook commands use safe-run.sh
    local _settings="$_setup/config/settings.json"
    if [ -f "$_settings" ]; then
        local _hook_cmds=""
        if command -v jq &>/dev/null; then
            _hook_cmds=$(jq -r '
                .hooks // {} | to_entries[] | .value[] |
                .hooks[]? | select(.type == "command") | .command
            ' "$_settings" 2>/dev/null) || true
        elif command -v python3 &>/dev/null; then
            # Same traversal as the jq path. A blind grep for "command" also matches
            # statusLine.command (legitimately not a hook) and would false-positive
            # this check into blocking every deploy on machines without jq.
            _hook_cmds=$(python3 -c '
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for matchers in (data.get("hooks") or {}).values():
    for matcher in matchers or []:
        for hook in (matcher.get("hooks") or []):
            if hook.get("type") == "command" and hook.get("command"):
                print(hook["command"])
' "$_settings" 2>/dev/null) || true
        else
            _hook_cmds=$(grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' "$_settings" \
                | sed 's/.*"\(bash [^"]*\)".*/\1/' | grep '^bash ' || true)
        fi
        if [ -n "$_hook_cmds" ]; then
            while IFS= read -r _cmd; do
                [ -z "$_cmd" ] && continue
                if [[ "$_cmd" == bash* ]] && [[ "$_cmd" != *"safe-run.sh"* ]]; then
                    log_error "Pre-deploy: hook bypasses safe-run.sh: $_cmd"
                    _fail=1
                fi
            done <<< "$_hook_cmds"
        fi
    fi

    return "$_fail"
}
