#!/usr/bin/env bash
# shutdown-follow.sh — UserPromptSubmit hook: after a `cls` / `end` shutdown the follow-up command is
# typed into this session by itself (CFG-1043 cls → /clear [+ startup during care], CFG-1044 end → /exit).
#
# Arms whenever a REAL prompt holds `cls` or `end` as a word, anywhere, any case (Q-CLS-WHOLE): letters,
# digits, `_` and `-` are word characters, so `end-to-end`, `backend`, `cls_x` never arm and `the end.`
# does. A false arm is harmless — the watcher (setup/scripts/shutdown-follow.sh, launched detached) types
# nothing unless the transcript shows a turn that ENDED on "Shutdown complete" after this prompt. Any
# later real prompt cancels the pending watcher (Q-CLS-CANCEL); one with a keyword re-arms (new token,
# the old watcher stops). Harness-delivered turns — hand-backs, task notifications, scheduled fires
# (hook_prompt_is_synthetic, lib-hook-stdin.sh) — neither arm nor cancel.
# A line remote-session.sh typed itself (the caretaker's `cls`, a brief holding "end") carries a stamp
# left by its typing primitive (remote-session-follow-lib.sh: "<line>\n<epoch>\n<token>" at
# $DIR/stamp.<pid>): such a prompt cancels the pending watcher and never arms; one whose stamp carries the
# pending watcher's own token (its /clear, its `startup`) changes nothing. The stamp is consumed once;
# older than SHUTDOWN_FOLLOW_STAMP_TTL (3600 s: a line typed into a BUSY session is queued, and this hook
# fires only when the queued prompt runs) it is ignored.
#
# FAST: it runs on every Enter. The fast path — no keyword anywhere in the payload, no pending watcher
# for this pid — is pure bash. Prints NOTHING to stdout (stdout is model context); every event goes to
# $SHUTDOWN_FOLLOW_LOG. State: $SHUTDOWN_FOLLOW_DIR/<claude pid> = the pending watcher (6 lines: token,
# keyword(s), transcript, byte offset at arming, session id, epoch) — the watcher re-reads the token
# every poll and, with the record's status and session id, right before its clearing keys, its text and
# its Enter (sf_may_type), so cancellation never needs a kill (tmux kill-session does not stop a job here).
# The user's own /clear or /exit fires no prompt hook (a built-in command, knowledge/hook-behavior.md): the
# session id in the record is what tells the watcher the session was already cleared.
# Where no /proc can be read (macOS, a sandbox) no session pid is found and the hook exits 0 at once,
# silently: there is nothing to arm. The watcher itself stands down, log-only, on a machine with no way to
# type into the session (no tmux pane, no Konsole tab, not WSL).
# Env (tests): SHUTDOWN_FOLLOW_PID, SHUTDOWN_FOLLOW_PROC, SHUTDOWN_FOLLOW_SCRIPT, SHUTDOWN_FOLLOW_DIR,
# SHUTDOWN_FOLLOW_LOG.

INPUT=""
[[ -t 0 ]] || INPUT=$(timeout 2 cat 2>/dev/null)
[[ -n "$INPUT" ]] || exit 0

DIR="${SHUTDOWN_FOLLOW_DIR:-$HOME/.local/state/shutdown-follow}"
PROC="${SHUTDOWN_FOLLOW_PROC:-/proc}"
LOG="${SHUTDOWN_FOLLOW_LOG:-$HOME/.claude/logs/shutdown-follow.log}"
WATCHER="${SHUTDOWN_FOLLOW_SCRIPT:-${CONFIG_REPO:-$HOME/agent-fleet}/setup/scripts/shutdown-follow.sh}"
TTL="${SHUTDOWN_FOLLOW_STAMP_TTL:-3600}"
CLS_RE='(^|[^[:alnum:]_-])[Cc][Ll][Ss]([^[:alnum:]_-]|$)'
END_RE='(^|[^[:alnum:]_-])[Ee][Nn][Dd]([^[:alnum:]_-]|$)'
# The pre-filter runs on the RAW payload, where a newline or tab is the two characters \n / \t: those
# count as a boundary before the word too (the decoded check above stays strict).
RAW_CLS_RE='(^|[^[:alnum:]_-]|\\[ntr])[Cc][Ll][Ss]([^[:alnum:]_-]|$)'
RAW_END_RE='(^|[^[:alnum:]_-]|\\[ntr])[Ee][Nn][Dd]([^[:alnum:]_-]|$)'

sf_log() { mkdir -p "${LOG%/*}" 2>/dev/null; local t; printf -v t '%(%FT%T)T' -1; echo "$t hook pid=${PID:-?} $*" >> "$LOG" 2>/dev/null; }

# sf_claude_pid — the nearest ancestor running a Claude Code binary (argv0 claude / claude.exe, as
# rs_caller_pid judges it; comm claude* when no cmdline is readable). Pure bash. 1 when the walk finds
# none — or cannot read $PROC at all (no /proc: macOS, a sandbox), which ends it at the first parent.
sf_claude_pid() {
    local p=$PPID i a0 c s
    [[ -n "${SHUTDOWN_FOLLOW_PID:-}" ]] && { echo "$SHUTDOWN_FOLLOW_PID"; return 0; }
    for i in $(seq 1 32); do
        [[ "$p" =~ ^[0-9]+$ && "$p" -gt 1 ]] || return 1
        a0=""; { IFS= read -r -d '' a0 < "$PROC/$p/cmdline"; } 2>/dev/null
        if [[ -n "$a0" ]]; then
            a0="${a0##*/}"; [[ "$a0" == claude || "$a0" == claude.exe ]] && { echo "$p"; return 0; }
        else
            c=""; { read -r c < "$PROC/$p/comm"; } 2>/dev/null; [[ "$c" == claude* ]] && { echo "$p"; return 0; }
        fi
        { read -r s < "$PROC/$p/stat"; } 2>/dev/null || return 1
        s="${s##*) }"; s="${s#* }"; p="${s%% *}"
    done
    return 1
}

PID=$(sf_claude_pid) || exit 0
STATE="$DIR/$PID"

# Fast path: no pending watcher and no keyword anywhere in the raw payload → nothing to do.
[[ -e "$STATE" || "$INPUT" =~ $RAW_CLS_RE || "$INPUT" =~ $RAW_END_RE ]] || exit 0

source "$(dirname "${BASH_SOURCE[0]}")/lib-hook-stdin.sh" 2>/dev/null || exit 0
hook_prompt_is_synthetic "$INPUT" && exit 0   # a harness-delivered turn neither arms nor cancels

# The payload's fields, one python call: session id, transcript path, then the prompt (may span lines).
FIELDS=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: d = {}
d = d if isinstance(d, dict) else {}
f = lambda k: d.get(k) if isinstance(d.get(k), str) else ""
sys.stdout.write(f("session_id").replace("\n", " ") + "\n" + f("transcript_path").replace("\n", " ") + "\n" + f("prompt") + ".")' 2>/dev/null) || exit 0
FIELDS="${FIELDS%.}"
SID="${FIELDS%%$'\n'*}"; REST="${FIELDS#*$'\n'}"
TRANSCRIPT="${REST%%$'\n'*}"; PROMPT="${REST#*$'\n'}"
[[ "$REST" == *$'\n'* ]] || PROMPT=""

# sf_trim <text> — without leading and trailing whitespace (for the stamp comparison)
sf_trim() { local t="$1"; t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"; printf '%s' "$t"; }

sf_cancel() { [[ -e "$STATE" ]] || return 0; rm -f "$STATE" 2>/dev/null; sf_log "cancelled pending watcher ($1)"; }

# A fresh stamp for exactly this line: remote-session typed it. Consumed once. The trim runs only when the
# lengths are close (a stamped line is one short line; trimming a multi-megabyte prompt costs a second).
STAMP="$DIR/stamp.$PID"
if [[ -f "$STAMP" ]]; then
    { IFS= read -r s_line; IFS= read -r s_epoch; IFS= read -r s_token; } < "$STAMP" 2>/dev/null
    printf -v now '%(%s)T' -1
    if (( ${#PROMPT} <= ${#s_line} + 64 )) && [[ "$(sf_trim "$s_line")" == "$(sf_trim "$PROMPT")" && "$s_epoch" =~ ^[0-9]+$ ]] \
       && (( now - s_epoch <= TTL )); then
        rm -f "$STAMP" 2>/dev/null
        if [[ -n "$s_token" && -e "$STATE" && "$(head -n1 "$STATE" 2>/dev/null)" == "$s_token" ]]; then
            sf_log "own line of the pending watcher ($s_token): unchanged"
        else
            sf_cancel "the line was typed by remote-session"
        fi
        exit 0
    fi
fi

WORDS=""
[[ "$PROMPT" =~ $CLS_RE ]] && WORDS="cls"
[[ "$PROMPT" =~ $END_RE ]] && WORDS="${WORDS:+$WORDS }end"

sf_cancel "a new prompt"
[[ -n "$WORDS" ]] || exit 0

# Arm: record the pending watcher, then launch it detached (setsid, fds off the hook's pipe — safe-run's
# capture would otherwise wait for it; the fleet's hook detach path, config-auto-sync.sh Phase 0.55).
if [[ ! -f "$WATCHER" ]]; then sf_log "NOT armed ($WORDS): watcher script missing ($WATCHER)"; exit 0; fi
mkdir -p "$DIR" "${LOG%/*}" 2>/dev/null || exit 0
printf -v now '%(%s)T' -1
TOKEN="$now-$$-$RANDOM"
OFFSET=0; [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] && OFFSET=$(stat -c %s "$TRANSCRIPT" 2>/dev/null || echo 0)
if printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$TOKEN" "$WORDS" "$TRANSCRIPT" "$OFFSET" "$SID" "$now" > "$STATE.tmp.$$" 2>/dev/null \
   && mv -f "$STATE.tmp.$$" "$STATE" 2>/dev/null; then
    setsid bash "$WATCHER" --pid "$PID" --token "$TOKEN" --state-dir "$DIR" </dev/null >>"$LOG" 2>&1 &
    sf_log "armed ($WORDS) token=$TOKEN offset=$OFFSET session=$SID"
else
    rm -f "$STATE.tmp.$$" 2>/dev/null; sf_log "NOT armed ($WORDS): cannot write $STATE"
fi
exit 0
