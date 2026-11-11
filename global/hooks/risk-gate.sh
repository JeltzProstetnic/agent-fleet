#!/usr/bin/env bash
# PreToolUse hook: blocks Tier 1 infrastructure edits without risk clearance.
# T1 files: mclaude, afleet, settings.json, .mcp.json, sync.sh
# Clearance: /tmp/.risk-gate-clearance-<md5 of the path> (valid 10 minutes) holding
#   sha256=<fingerprint>  — CFG-949: sha256 of the exact payload the risk subagent
#   assessed (Write: content; Edit: old_string + new_string + replace_all), so the
#   gate blocks when what is about to be written is not what was cleared. TTL stays
#   as the second limit. An empty (touch) clearance is the pre-CFG-949 format: it
#   passes until it expires, with a one-line warning.
#
# CLI verbs (no stdin), sharing the hook's own fingerprint function:
#   risk-gate.sh fingerprint write <content-file>
#   risk-gate.sh fingerprint edit <old-file> <new-file> [--replace-all]
#   risk-gate.sh clearance <target-path> write <content-file>
#   risk-gate.sh clearance <target-path> edit <old-file> <new-file> [--replace-all]
#
# Exit 0 = allow, Exit 2 + stderr = block with instructions.

TTL=600

# Canonical payload: "<tool>" NUL field NUL field… — tool-bound, so a Write clearance
# never covers an Edit, and replace_all is part of the edit.
#   fingerprint_files write <content-file> | edit <old-file> <new-file> <true|false>
fingerprint_files() {
    case "$1" in
        write) { printf 'write\0'; cat "$2"; } | sha256sum | cut -c1-64 ;;
        edit)  { printf 'edit\0'; cat "$2"; printf '\0'; cat "$3"; printf '\0%s' "$4"; } | sha256sum | cut -c1-64 ;;
    esac
}
# The same bytes from the hook's JSON (jq -j emits raw bytes; "\u0000" is the NUL).
fingerprint_input() {
    printf '%s' "$INPUT" | jq -j '
        if .tool_name == "Write" then "write\u0000" + (.tool_input.content // "")
        else "edit\u0000" + (.tool_input.old_string // "") + "\u0000" + (.tool_input.new_string // "")
             + "\u0000" + (if .tool_input.replace_all == true then "true" else "false" end) end' \
        | sha256sum | cut -c1-64
}
clearance_path() { printf '/tmp/.risk-gate-clearance-%s' "$(echo "$1" | md5sum | cut -c1-16)"; }

cli_fingerprint() {   # write <content-file> | edit <old-file> <new-file> [--replace-all]
    local mode="${1:-}"; shift || true
    case "$mode" in
        write)
            [ -f "${1:-}" ] || { echo "usage: risk-gate.sh fingerprint write <content-file>" >&2; return 1; }
            fingerprint_files write "$1" ;;
        edit)
            local all=false; [ "${3:-}" = "--replace-all" ] && all=true
            { [ -f "${1:-}" ] && [ -f "${2:-}" ]; } || { echo "usage: risk-gate.sh fingerprint edit <old-file> <new-file> [--replace-all]" >&2; return 1; }
            fingerprint_files edit "$1" "$2" "$all" ;;
        *)  echo "usage: risk-gate.sh fingerprint write <content-file> | edit <old-file> <new-file> [--replace-all]" >&2; return 1 ;;
    esac
}

case "${1:-}" in
    fingerprint) shift; cli_fingerprint "$@"; exit $? ;;
    clearance)
        shift; TARGET="${1:-}"; shift || true
        [ -n "$TARGET" ] || { echo "usage: risk-gate.sh clearance <target-path> write <content-file> | edit <old-file> <new-file> [--replace-all]" >&2; exit 1; }
        FP=$(cli_fingerprint "$@") || exit 1
        CL=$(clearance_path "${TARGET/#\~/$HOME}")
        printf 'sha256=%s\n' "$FP" > "$CL"
        echo "CLEARANCE WRITTEN: $CL sha256=$FP — valid $((TTL / 60)) min, bound to exactly this payload"
        exit 0 ;;
esac

# Drain stdin immediately (PreToolUse contract)
INPUT=$(cat)

# Fast exit: only process Write/Edit tools
TOOL=""
case "$INPUT" in
    *'"tool_name":"Write"'*|*'"tool_name": "Write"'*) TOOL=Write ;;
    *'"tool_name":"Edit"'*|*'"tool_name": "Edit"'*)   TOOL=Edit ;;
    *) exit 0 ;;
esac

# Extract file_path
FILE_PATH=""
if command -v jq &>/dev/null; then
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
else
    FILE_PATH=$(echo "$INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
fi
[ -z "$FILE_PATH" ] && exit 0

# Resolve ~ to $HOME
FILE_PATH="${FILE_PATH/#\~/$HOME}"

# Classify: Tier 1 only — everything else passes through
IS_T1=false
case "$FILE_PATH" in
    */.local/bin/mclaude)                   IS_T1=true ;;
    */.local/bin/afleet)                    IS_T1=true ;;
    */.cc-mirror/*/config/settings.json)    IS_T1=true ;;
    */.mcp.json)                            IS_T1=true ;;
    */cfg-agent-fleet/sync.sh)              IS_T1=true ;;
    */agent-fleet/sync.sh)                  IS_T1=true ;;
esac

$IS_T1 || exit 0

CLEARANCE=$(clearance_path "$FILE_PATH")

block() {   # <reason>… — always names the protocol, the clearance path and the verb to write it
    {
        echo "RISK_GATE TIER 1 — Edit to $(basename "$FILE_PATH") blocked."
        printf '%s\n' "$@"
        cat <<EOF
This is a critical infrastructure file. Before editing:
1. Load knowledge/risk-analysis-protocol.md
2. Launch a risk analysis subagent for this change — give it the exact payload (old/new strings or full content) in scratch files
3. After an acceptable assessment, write the clearance bound to that payload:
   bash ~/.claude/hooks/risk-gate.sh clearance $FILE_PATH edit <old-file> <new-file> [--replace-all]
   bash ~/.claude/hooks/risk-gate.sh clearance $FILE_PATH write <content-file>
Clearance file: $CLEARANCE
EOF
    } >&2
    exit 2
}

[ -f "$CLEARANCE" ] || block "No clearance on file."
FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$CLEARANCE" 2>/dev/null || echo 0) ))
[ "$FILE_AGE" -lt "$TTL" ] || block "Clearance expired: written ${FILE_AGE}s ago, TTL ${TTL}s — the assessment is stale, run it again."

# Old format (empty file, `touch`): no fingerprint to compare — allow, say so once.
if ! grep -q '^sha256=' "$CLEARANCE" 2>/dev/null; then
    WARN="RISK_GATE: clearance for $(basename "$FILE_PATH") has no fingerprint (touch format) — allowed until it expires; bind the next one to its payload with: bash ~/.claude/hooks/risk-gate.sh clearance $FILE_PATH edit <old-file> <new-file> | write <content-file>"
    echo "$WARN" >&2
    command -v jq &>/dev/null && jq -cn --arg m "$WARN" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $m}}'
    exit 0
fi

RECORDED=$(sed -n 's/^sha256=\(.*\)$/\1/p' "$CLEARANCE" | head -1 | tr -d '[:space:]')
case "$RECORDED" in
    '' | *[!0-9a-f]*) block "Clearance fingerprint line is malformed ('sha256=${RECORDED:0:24}'): expected 64 hex chars — rewrite it with the clearance verb." ;;
esac
[ "${#RECORDED}" -eq 64 ] || block "Clearance fingerprint line is malformed (${#RECORDED} chars, expected 64) — rewrite it with the clearance verb."
command -v jq &>/dev/null || block "jq is required to verify a fingerprinted clearance and is not installed on this machine."

ACTUAL=$(fingerprint_input)
[ "$ACTUAL" = "$RECORDED" ] && exit 0
block "Payload changed after clearance: cleared sha256=${RECORDED:0:12}…, this $TOOL carries sha256=${ACTUAL:0:12}… — what the risk subagent assessed is not what is about to be written. Run the assessment on the new payload and write a fresh clearance."
