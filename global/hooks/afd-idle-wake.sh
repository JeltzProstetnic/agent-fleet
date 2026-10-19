#!/usr/bin/env bash
# afd-idle-wake.sh — Stop hook, registered with "asyncRewake": true (CFG-777).
#
# A session reads its Telegram queue only on its own next prompt, so a message for an
# IDLE session used to wait until some other session woke it (2026-10-19: the user's @<project>
# messages sat 10+ min). This hook runs in the background after every turn: it polls
# afd, files every consumed message into its project's queue (lib-afd-msg.sh), and
# exits 2 the moment one is queued for THIS project — Claude Code then wakes the model
# with this hook's stderr. No other session has to be reading.
#
# One waiter per session: a newer one (next turn) supersedes the older via a pid file.
# Exits 0 (no wake) when Claude Code is gone, when superseded, or after AFD_IDLE_MAX
# seconds; settings.json gives the hook a timeout 60 s longer than that.
# Env: AFD_IDLE_POLL (s, default 10), AFD_IDLE_MAX (s, default 43200),
#      AFD_IDLE_PARENT_PID (tests: the process standing in for Claude Code).

INPUT=""
[[ -t 0 ]] || INPUT=$(timeout 2 cat 2>/dev/null)

AFD_CLI="${HOME}/.local/bin/afd"
[[ -x "$AFD_CLI" ]] || exit 0
source "$(dirname "${BASH_SOURCE[0]}")/lib-afd-msg.sh" 2>/dev/null || exit 0

SID="nosession"; CWD="$PWD"
[[ "$INPUT" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && SID="${BASH_REMATCH[1]}"
[[ "$INPUT" =~ \"cwd\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && CWD="${BASH_REMATCH[1]}"
ME=$(afd_project_of "$CWD" 2>/dev/null || basename "$CWD")

# The Claude Code process this waiter belongs to: nearest ancestor named claude*.
claude_pid() {
    local p=$PPID c
    while [[ -n "$p" && "$p" -gt 1 ]]; do
        c=$(cat "/proc/$p/comm" 2>/dev/null) || return 1
        [[ "$c" == claude* ]] && { echo "$p"; return 0; }
        p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
    done
    return 1
}
PARENT="${AFD_IDLE_PARENT_PID:-$(claude_pid)}"
[[ -n "$PARENT" ]] || exit 0

DIR=$(_afd_msg_dir)
mkdir -p "$DIR/.idle" 2>/dev/null || exit 0
PIDFILE="$DIR/.idle/${SID//[^A-Za-z0-9_-]/_}.pid"
echo $$ > "$PIDFILE"

POLL="${AFD_IDLE_POLL:-10}"
DEADLINE=$(( $(date +%s) + ${AFD_IDLE_MAX:-43200} ))

while (( $(date +%s) < DEADLINE )); do
    kill -0 "$PARENT" 2>/dev/null || exit 0
    [[ "$(cat "$PIDFILE" 2>/dev/null)" == "$$" ]] || exit 0
    afd_route_messages "$ME" >/dev/null 2>&1
    MESSAGES=$(afd_take_messages "$ME")
    if [[ -n "$MESSAGES" ]]; then
        rm -f "$PIDFILE"
        {
            echo "=== Telegram message(s) for this project (woke this idle session, CFG-777) ==="
            while IFS= read -r line; do
                [[ -n "$line" ]] || continue
                printf '%s' "$line" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
ch = '(persona: %s)' % d['persona'] if d.get('persona') else ''
print('[%s] %s %s' % (str(d.get('timestamp', ''))[:16], ch, d.get('message', '')))" 2>/dev/null
            done <<< "$MESSAGES"
            echo "Reply via: afd notify all \"[$ME] your reply\" --channel telegram"
            echo "==="
        } >&2
        exit 2
    fi
    sleep "$POLL"
done
rm -f "$PIDFILE"
exit 0
