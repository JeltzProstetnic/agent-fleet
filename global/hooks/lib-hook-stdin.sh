#!/usr/bin/env bash
# lib-hook-stdin.sh — helpers for a hook's Claude Code stdin JSON:
#   read_cc_session_id    — the CC session_id (CFG-452 Phase 1), below.
#   prompt_is_synthetic   — is a UserPromptSubmit `.prompt` harness-delivered? (CFG-911)
#   prompt_user_text      — the user's own words in a prompt (CFG-911)
#   record_session_crons  — Stop hook: keep this session's cron prompts (CFG-911)
#   hook_prompt_user_text — prompt_user_text for a raw UserPromptSubmit payload (CFG-911)
#   hook_prompt_is_synthetic — prompt_is_synthetic for a raw payload, crons included (CFG-911)
#
# Claude Code pipes {"session_id":"...", ...} to SessionStart / SessionEnd hooks
# on stdin. Binding session-lock ownership to this id (instead of the inheritable
# AFLEET_SESSION_ID env var) closes the F1 spoof: a nested CC process (headless
# `mclaude -p` via the Bash tool, a tmux-launched background CC in the same
# project) inherits AFLEET_SESSION_ID but gets a DIFFERENT session_id, so its
# SessionEnd can no longer release the leader's live lock.
#
# SAFE BY CONSTRUCTION — any failure path yields "" and the caller falls back to
# legacy AFLEET_SESSION_ID ownership (i.e. pre-CFG-452 behaviour):
#   - TTY / no pipe            -> "" (nothing to read)
#   - empty or malformed JSON  -> ""
#   - python3 absent           -> grep/sed fallback, else ""
# NEVER BLOCKS: interactive stdin is skipped (`-t 0`) and the read is bounded by
# a 2s `timeout` so a SessionStart hang can never lock the user out.

# read_cc_session_id — reads and CONSUMES stdin once; echoes the session_id (or "").
# Call once, early, in a hook (typically: CC_SESSION_ID="$(read_cc_session_id)").
read_cc_session_id() {
    # Interactive shell / no piped input — nothing to read, don't block.
    [ -t 0 ] && return 0

    # Bounded read. Do NOT gate on the exit status: if `timeout` kills `cat`,
    # the JSON `cat` already echoed is still captured in $_raw.
    local _raw
    _raw="$(timeout 2 cat 2>/dev/null)"
    [ -n "$_raw" ] || return 0

    local _id=""
    if command -v python3 >/dev/null 2>&1; then
        _id="$(printf '%s' "$_raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    v = d.get("session_id", "") if isinstance(d, dict) else ""
    sys.stdout.write(v if isinstance(v, str) else "")
except Exception:
    pass' 2>/dev/null)"
    fi

    # Fallback: extract the field textually if python3 is absent or found nothing.
    if [ -z "$_id" ]; then
        _id="$(printf '%s' "$_raw" \
            | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | head -1 \
            | sed 's/.*"session_id"[[:space:]]*:[[:space:]]*"//; s/"$//')"
    fi

    printf '%s' "$_id"
}

# prompt_is_synthetic <prompt> [source] — exit 0 when the UserPromptSubmit prompt was
# delivered by the harness rather than typed by the user (CFG-770, CFG-911). Such turns fire
# UserPromptSubmit too, and their text quotes whatever a subagent or task reported.
# Shapes measured 2026-11-13 in real transcripts: a queued subagent hand-back is
# `<agent-message from="…">\n[Subagent hand-back] …`, stored framed as
# "Another Claude session sent a message:\n<agent-message …"; a background task is
# `<task-notification>…`; a peer session is `<cross-session-message …>`, likewise framed.
# Anchored at the start, so user text that quotes a marker later still counts as the
# user's. [source] is the payload's `source` field: Claude Code's hook schema documents
# user | sdk | system | loop_wakeup | schedule_wakeup | poll_event ("payloads may omit it
# while the field rolls out"; 2.1.280 compiles it out). The last four are machine-injected;
# any other value, or none, leaves the call to the text. Pure bash: it runs on every Enter.
_PROMPT_SYNTHETIC_RE='^[[:space:]]*(<(task-notification|cross-session-message|agent-message)([[:space:]>]|$)|\[(Subagent hand-back|Cross-session idle notice)\]|(Another Claude session|A peer session) sent a message( while you were working)?:)'
prompt_is_synthetic() {
    case "${2-}" in system|loop_wakeup|schedule_wakeup|poll_event) return 0 ;; esac
    [[ "${1-}" =~ $_PROMPT_SYNTHETIC_RE ]]
}

# prompt_user_text <prompt> [source] — print the words the user wrote in a UserPromptSubmit
# prompt (CFG-911): typed text whole, nothing for a harness-delivered turn, with one exception.
# The CFG-777 idle wake (afd-idle-wake.sh, a Stop hook exiting 2) hands an idle session
# the user's Telegram messages on stderr, and Claude Code delivers that stderr as
# `<task-notification>\n<summary>Stop hook feedback</summary>…` — synthetic, yet the
# lines between its `=== Telegram message(s) for this project` header and its
# `Reply via: afd notify` footer are the user's own words, so those are printed.
# Only that frame at the very start counts: a hand-back or task output quoting such a
# block prints nothing. Pure bash, like prompt_is_synthetic.
_PROMPT_STOP_FEEDBACK_RE='^[[:space:]]*<task-notification>[[:space:]]*<summary>Stop hook feedback</summary>'
_PROMPT_TG_WAKE_HEAD='=== Telegram message(s) for this project (woke this idle session, CFG-777) ==='
prompt_user_text() {
    local p="${1-}" body nl=$'\n'
    if ! prompt_is_synthetic "$p" "${2-}"; then printf '%s' "$p"; return 0; fi
    [[ "$p" =~ $_PROMPT_STOP_FEEDBACK_RE ]] || return 0
    [[ "$p" == *"$_PROMPT_TG_WAKE_HEAD"* ]] || return 0
    body="${p#*"$_PROMPT_TG_WAKE_HEAD"}"
    body="${body%"$nl"Reply via: afd notify *}"
    printf '%s' "${body#"$nl"}"
}

# Scheduled fires (CronCreate, ScheduleWakeup, /loop) run UserPromptSubmit with the task's
# prompt VERBATIM: no frame (7 fires in 6 projects, 2026-10-27..11-13, each opening its own
# way) and, in 2.1.280, no `source`. Only the transcript row says scheduled. The Stop payload
# lists the session's crons, `session_crons: [{id, schedule, recurring, prompt}]`, each prompt
# clipped at 1000 UTF-16 units + "… [+N chars]"; the Stop hook (afd-idle-wake.sh) records
# them here, and the hook_prompt_* functions treat a prompt that is one of them as scheduled.
# Claude Code holds a fire until the session is idle, so it normally follows a recorded Stop.
# Not always: that Stop hook runs async (asyncRewake), so a fire already due when its turn
# ends can reach UserPromptSubmit before the record is written; a turn that ends without a
# Stop (StopFailure, an interrupt) records nothing; and a durable cron firing at startup
# precedes every Stop. Such a fire reads as typed text, as before CFG-911 (fails open).
_session_crons_dir() { printf '%s' "${SESSION_CRONS_DIR:-$HOME/.claude/.session-crons}"; }

# record_session_crons <stop-hook-input-json> — write this session's cron prompts to
# <dir>/<session_id>.json, or remove that file when none are left. A payload without
# `session_crons` (older Claude Code) changes nothing. Records idle 8+ days are pruned.
record_session_crons() {
    [[ -n "${1-}" ]] || return 0
    printf '%s' "$1" | python3 -c '
import json, os, re, sys, time
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
sid = d.get("session_id") if isinstance(d, dict) else None
crons = d.get("session_crons") if isinstance(d, dict) else None
if not isinstance(sid, str) or not sid or not isinstance(crons, list):
    sys.exit(0)
base = sys.argv[1]
path = os.path.join(base, re.sub(r"[^A-Za-z0-9_-]", "_", sid) + ".json")
prompts = [c["prompt"] for c in crons if isinstance(c, dict) and isinstance(c.get("prompt"), str)]
if os.path.isdir(base):
    for f in os.listdir(base):
        try:
            if time.time() - os.path.getmtime(os.path.join(base, f)) > 8 * 86400:
                os.remove(os.path.join(base, f))
        except OSError:
            pass
if not prompts:
    if os.path.exists(path):
        os.remove(path)
    sys.exit(0)
os.umask(0o077)   # prompts can be private: owner-only, like the transcripts they come from
os.makedirs(base, exist_ok=True)
with open(path + ".tmp", "w") as fh:
    json.dump(prompts, fh)
os.replace(path + ".tmp", path)' "$(_session_crons_dir)" 2>/dev/null || true
}

# _hook_prompt_parse <user-prompt-submit-json> — set _HOOK_PROMPT to the payload's `.prompt`
# and _HOOK_PROMPT_SOURCE to its `.source`; with no `source`, a prompt equal to one of this
# session's recorded crons (a clipped one: same prefix, same UTF-16 length) gets
# schedule_wakeup. Returns 1, both empty, when the payload cannot be read.
_hook_prompt_parse() {
    local out nl=$'\n'
    _HOOK_PROMPT=""; _HOOK_PROMPT_SOURCE=""
    out=$(printf '%s' "${1-}" | python3 -c '
import json, os, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
d = d if isinstance(d, dict) else {}
p = d.get("prompt") or d.get("message") or ""
p = p if isinstance(p, str) else ""
s = d.get("source") if isinstance(d.get("source"), str) else ""
sid = d.get("session_id") if isinstance(d.get("session_id"), str) else ""
units = lambda t: len(t.encode("utf-16-le", "surrogatepass")) // 2
crons = []
if sid and not s:
    try:
        crons = json.load(open(os.path.join(sys.argv[1], re.sub(r"[^A-Za-z0-9_-]", "_", sid) + ".json")))
    except Exception:
        crons = []
for c in crons if isinstance(crons, list) else []:
    m = re.fullmatch(r"(.*)… \[\+(\d+) chars\]", c, re.S) if isinstance(c, str) else None
    if c == p or (m and p.startswith(m.group(1)) and units(p) - units(m.group(1)) == int(m.group(2))):
        s = "schedule_wakeup"
        break
sys.stdout.write(re.sub(r"\s", " ", s) + "\n" + p + ".")' "$(_session_crons_dir)" 2>/dev/null) || return 1
    # The trailing "." keeps an empty or newline-ended prompt intact through $( ).
    [[ "$out" == *"$nl"*. ]] || return 1
    out="${out%.}"
    _HOOK_PROMPT_SOURCE="${out%%"$nl"*}"
    _HOOK_PROMPT="${out#*"$nl"}"
}

# hook_prompt_user_text <user-prompt-submit-json> — prompt_user_text for the raw payload:
# nothing for a scheduled fire (by `source`, or a recorded cron), as for any synthetic turn.
hook_prompt_user_text() {
    _hook_prompt_parse "${1-}" || return 0
    prompt_user_text "$_HOOK_PROMPT" "$_HOOK_PROMPT_SOURCE"
}

# hook_prompt_is_synthetic <user-prompt-submit-json> — prompt_is_synthetic for the raw
# payload, so a scheduled fire counts as harness-delivered too. 1 for an unreadable payload.
hook_prompt_is_synthetic() {
    _hook_prompt_parse "${1-}" || return 1
    prompt_is_synthetic "$_HOOK_PROMPT" "$_HOOK_PROMPT_SOURCE"
}
