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

# The Claude Code process this waiter belongs to (lib-afd-msg.sh).
PARENT="${AFD_IDLE_PARENT_PID:-$(afd_claude_pid)}"
[[ -n "$PARENT" ]] || exit 0

DIR=$(_afd_msg_dir)
mkdir -p "$DIR/.idle" 2>/dev/null || exit 0
PIDFILE="$DIR/.idle/${SID//[^A-Za-z0-9_-]/_}.pid"
echo $$ > "$PIDFILE"

POLL="${AFD_IDLE_POLL:-10}"
DEADLINE=$(( $(date +%s) + ${AFD_IDLE_MAX:-43200} ))

# CFG-797: a cross-project inbox item filed after this turn ended also wakes the session,
# but only while its context use is under AFD_IDLE_INBOX_PCT % of its window (owner
# decision 2026-10-21: 45 %). Project = basename of cwd, as inbox-watch.sh derives it. Items
# already open at turn end are the baseline — the session saw them via INBOX_PENDING.
INBOX_PROJECT=$(basename "$CWD")
INBOX_LIB="${INBOX_REPO:-${CONFIG_REPO:-$HOME/cfg-agent-fleet}}/setup/scripts/inbox-lib.sh"
INBOX_ON=false
# shellcheck disable=SC1090
[[ -f "$INBOX_LIB" ]] && . "$INBOX_LIB" 2>/dev/null && command -v inbox_items_for >/dev/null && INBOX_ON=true
INBOX_BASE=""
$INBOX_ON && INBOX_BASE=$(inbox_items_for "$INBOX_PROJECT" 2>/dev/null)

# Context use in % of the window from this session's statusline sidecar; empty if unknown.
context_pct() {
    local f="${CONTEXT_BUDGET_DIR:-$HOME/.claude}/.context-budget-${SID}.json"
    [[ -f "$f" ]] || return 0
    python3 -c "import json,sys; print(int(json.load(open(sys.argv[1]))['pct']))" "$f" 2>/dev/null
}

# Prints the open items for this project that were not open at turn end.
new_inbox_items() {
    $INBOX_ON || return 0
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        grep -qxF -- "$line" <<< "$INBOX_BASE" || printf '%s\n' "$line"
    done <<< "$(inbox_items_for "$INBOX_PROJECT" 2>/dev/null)"
}

# A newer turn's waiter may have written its pid since our last check; never delete
# its pidfile, or that session is left with no waiter (Fable F2).
release_pidfile() { [[ "$(cat "$PIDFILE" 2>/dev/null)" == "$$" ]] && rm -f "$PIDFILE"; }

# CFG-806: Claude Code is still alive while its SessionEnd hooks run (/exit, /clear — up to
# CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS), so an exit 2 in that window opens a new turn in a
# session the user has already left. config-auto-sync.sh marks the session as ending with
# this file and sends us SIGTERM before it does anything else; from then on nothing wakes
# the model, and a Telegram message already taken goes back to the project queue for the
# next session's prompt hook. A marker older than this waiter is an earlier life of the
# same session id (a resumed session) and is cleared, not obeyed.
ENDING="$DIR/.idle/${SID//[^A-Za-z0-9_-]/_}.ending"
rm -f "$ENDING" 2>/dev/null
MESSAGES=""
session_ending() { [[ -f "$ENDING" ]]; }
stop_quietly() {
    [[ -n "$MESSAGES" ]] && printf '%s\n' "$MESSAGES" >> "$DIR/$ME.jsonl" 2>/dev/null
    release_pidfile
    exit 0
}
trap stop_quietly TERM
# sleep in the background so SIGTERM is acted on at once, not after the poll interval.
nap() { sleep "$POLL" & wait $! 2>/dev/null; }

while (( $(date +%s) < DEADLINE )); do
    kill -0 "$PARENT" 2>/dev/null || exit 0
    session_ending && stop_quietly
    [[ "$(cat "$PIDFILE" 2>/dev/null)" == "$$" ]] || exit 0
    NEW_ITEMS=$(new_inbox_items)
    if [[ -n "$NEW_ITEMS" ]]; then
        PCT=$(context_pct)
        if [[ -n "$PCT" ]] && (( PCT < ${AFD_IDLE_INBOX_PCT:-45} )); then
            session_ending && stop_quietly
            release_pidfile
            # Count + path only, like inbox-watch.sh: item bodies come from other sessions
            # and must not reach the model unread as part of a wake frame (Fable F1).
            echo "INBOX_PENDING: $(grep -c . <<< "$NEW_ITEMS") new inbox item(s) for $INBOX_PROJECT (woke this idle session at ${PCT}% context, CFG-797) — read $(inbox_project_file "$INBOX_PROJECT") and dispatch per startup step 1 now" >&2
            exit 2
        fi
        # Over threshold or unknown: no wake; the item waits for the next prompt (inbox-watch.sh).
        INBOX_BASE=$(printf '%s\n%s' "$INBOX_BASE" "$NEW_ITEMS")
    fi
    afd_route_messages "$ME" >/dev/null 2>&1
    # A waiting AskUserQuestion relay owns this project's queue (2026-10-20, #406/#408).
    if afd_question_waiting "$ME"; then nap; continue; fi
    session_ending && stop_quietly
    MESSAGES=$(afd_take_messages "$ME")
    if [[ -n "$MESSAGES" ]]; then
        session_ending && stop_quietly   # marked between the check and the take: requeue, no wake
        release_pidfile
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
    nap
done
release_pidfile
exit 0
