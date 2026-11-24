#!/usr/bin/env bash
# remote-session-follow-lib.sh — what the shutdown-follow mechanism (CFG-1043 / CFG-1044) shares with
# the remote-session libs: the TYPING STAMP and the judgement of a shutdown turn. Sourced by
# remote-session-lib.sh (at its end, like the submit lib); not run.
#
# The stamp: global/hooks/shutdown-follow.sh arms a watcher whenever a real prompt holds `cls` or `end`
# as a word. A line that remote-session typed itself (the caretaker's `cls` in cls-restart, a sent brief
# holding "end") must not arm one — the caretaker's script types /clear itself, and two /clears plus two
# `startup`s would follow. So the typing primitives (rs_type_text, rs_type_line) leave, BEFORE the keys,
# "<line>\n<epoch>\n<token>" at $RS_FOLLOW_DIR/stamp.<pid>; the hook, seeing a prompt equal to a fresh
# stamp's line, consumes it, cancels a pending watcher and arms nothing — unless <token> is the pending
# watcher's own (SHUTDOWN_FOLLOW_TOKEN in its environment: its /clear and `startup` change nothing). The
# stamp is written before the write because the hook can fire before the write returns (rs_type_line
# carries the Enter); a write that FAILS removes it again (rs_type_text / rs_type_line), as does a give-up
# that clears the line from the input box (rs_unstamp) — else the stale stamp would eat the user's next
# real `cls` for an hour, silently.
# Overridable: SHUTDOWN_FOLLOW_DIR (the hook reads the same), SHUTDOWN_FOLLOW_TOKEN (the watcher).

# rs_follow_dir — the state dir the hook reads (resolved per call: tests set it after sourcing)
rs_follow_dir() { printf '%s' "${SHUTDOWN_FOLLOW_DIR:-$HOME/.local/state/shutdown-follow}"; }

# rs_stamp_typed <pid> <text> — leave the stamp for <pid>; never fails the typing (0 whatever happens)
rs_stamp_typed() {
    local d now tmp; d=$(rs_follow_dir); tmp="$d/stamp.$1.tmp.$$"
    mkdir -p "$d" 2>/dev/null || return 0
    printf -v now '%(%s)T' -1
    { printf '%s\n%s\n%s\n' "$2" "$now" "${SHUTDOWN_FOLLOW_TOKEN:-}" > "$tmp" && mv -f "$tmp" "$d/stamp.$1"; } 2>/dev/null \
        || rm -f "$tmp" 2>/dev/null
    return 0
}

# rs_unstamp <pid> — the line never reached the session (a refused write) or left the input box unsent (a
# give-up cleared it): the stamp goes with it
rs_unstamp() { rm -f "$(rs_follow_dir)/stamp.$1" 2>/dev/null; return 0; }

# ── the shutdown turn ─────────────────────────────────────────────────────────
# A turn COMPLETED the shutdown when it ended (system/turn_duration) and its last assistant text has a line
# starting "Shutdown complete" (CFG-1001): tool output, a quoted phrase, or the phrase followed by more work
# never count. A QUOTED completion is not the session's own either — a line inside a ``` / ~~~ fence or on a
# `>` blockquote line is dropped before the test (a live answer that quotes the row must never /exit a
# session; 0 of 274 real completions were written that way). The `Next: /exit|/clear` hint is read from the
# same visible text. Two judges share this script, RS_SHUTDOWN_MODE selects:
#   last   exit 0 when the LAST completed turn after the offset is a completion (rs_shutdown_reported —
#          remote-session's end-exit / cls-restart: a later prompt and its answer VOID the shutdown there)
#   first  print the hint ("exit" | "clear" | "none") of the FIRST completed turn after the offset and exit 0;
#          exit 1 when none (rs_shutdown_turn — the watcher: it is cancelled by the user's prompts itself,
#          and a synthetic turn that starts and ends between two polls must not hide the shutdown)
RS_SHUTDOWN_PY='import json,os,re,sys
mode = os.environ.get("RS_SHUTDOWN_MODE", "last")
def visible(text):
    out, fence = [], False
    for l in text.splitlines():
        s = l.strip()
        if s.startswith("```") or s.startswith("~~~"): fence = not fence; continue
        if fence or s.startswith(">"): continue
        out.append(l)
    return "\n".join(out)
def completion(text):
    return text is not None and re.search(r"(?m)^[\s*_#-]*Shutdown complete", visible(text)) is not None
hint_re = re.compile(r"Next:\s*`?/(exit|clear)\b")
last, done, first = None, False, None
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if d.get("type") == "system" and d.get("subtype") == "turn_duration":
        ok = completion(last)
        done = ok
        if ok and first is None:
            m = hint_re.findall(visible(last)); first = m[-1] if m else "none"
        last = None
    elif d.get("type") == "assistant":
        c = (d.get("message") or {}).get("content")
        if isinstance(c, str): c = [{"type": "text", "text": c}]
        for b in c or []:
            if b.get("type") == "text": last = b.get("text") or ""
            elif b.get("type") == "tool_use": last = None
    elif d.get("type") == "user":
        c = (d.get("message") or {}).get("content")
        if not (isinstance(c, list) and any(b.get("type") == "tool_result" for b in c)): last = None
if mode == "last": sys.exit(0 if done else 1)
if first is None: sys.exit(1)
print(first)'

# rs_shutdown_turn <transcript> <offset> — the watcher's judge: 0 and the hint ("exit" | "clear" | "none") of
# the first turn after byte <offset> that completed the shutdown; 1 when there is none (or no transcript).
rs_shutdown_turn() {
    [[ -f "$1" ]] || return 1
    tail -c +"$(( $2 + 1 ))" "$1" 2>/dev/null | RS_SHUTDOWN_MODE=first python3 -c "$RS_SHUTDOWN_PY"
}

# rs_shutdown_next <transcript> <offset> — "exit" | "clear" | "": that turn's hint alone (nothing when none)
rs_shutdown_next() {
    local h; h=$(rs_shutdown_turn "$1" "$2") || return 0
    [[ "$h" == none ]] || echo "$h"
}
