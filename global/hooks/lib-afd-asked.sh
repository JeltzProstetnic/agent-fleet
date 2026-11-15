#!/usr/bin/env bash
# lib-afd-asked.sh — the record of AskUserQuestion relays under AFK, and `re-ask` (CFG-1034).
#
# The user, 2026-11-15: "no questions while afk defeats the purpose of afk. afk is not dnd." A relayed
# question waits 15 min while a care shift runs (~/.afd-care, first word "active") and 45 min
# otherwise (Q-AFK-ASK). On a timeout the session goes on with its own default and states it in one
# line, "AFK_DEFAULT #<question id>: <decision>", which the Stop hook (afd-idle-wake.sh) reads from
# the session's last message or transcript. Every relayed question is recorded, one event per line,
# in $AFD_MSG_DIR/.asked.jsonl:
#   asked q project sid pid pstart question wait   afd-relay.sh, once the question is on Telegram
#   outcome q outcome told                         answered | declined | timeout | afk-off | gone | dnd
#   default q text [missing]                       the AFK_DEFAULT line (missing: not stated in 3 turns)
#   reasked q as      late q via      summarized q
# A Telegram message that is only `re-ask` (lib-afd-msg.sh) re-sends every timed-out question still
# open — no late answer since, and its Claude Code process (pid + start time) still running — as
# "[<project>] Re-ask of #<q> …", then sends ONE summary of the defaults not summarised before.
# A Telegram Reply to a re-send (or to the timed-out original) reaches that project as an ordinary
# Telegram message labelled with the question (late_answer_to): the relay that asked has long
# exited, so the late answer cannot become its tool result. It is never the answer to a newer
# question. Events of questions older than 7 days are pruned at each re-ask.
#
# Sourced by afd-relay.sh (AskUserQuestion path), afd-idle-wake.sh (the default line) and, lazily,
# lib-afd-msg.sh (re-ask, late answers). Needs python3; every call is a no-op without it.
#
# LIMITATION: the record is per machine, while a Telegram `re-ask` lands on whichever machine polls
# first. Every re-ask message therefore names its host (AFD_HOSTNAME overrides, for tests), and an
# empty summary speaks for that host only; a fleet-wide record needs the server (open work).

[[ "${_LIB_AFD_ASKED_LOADED:-}" == "true" ]] && return 0
_LIB_AFD_ASKED_LOADED="true"

_afd_asked_dir() { echo "${AFD_MSG_DIR:-$HOME/.afd-msgs}"; }
_afd_asked_py() { AFD_ASKED_FILE="$(_afd_asked_dir)/.asked.jsonl" python3 -c "$_AFD_ASKED_PY" "$@" 2>/dev/null; }

# afd_asked_wait — ASK_WAIT = seconds a relayed question waits: 900 during a care shift, else 2700.
# AFD_AFK_TIMEOUT (tests, manual) overrides, ending 30 s early above 60 s as before.
afd_asked_wait() {
    local w=""
    if [[ "${AFD_AFK_TIMEOUT:-}" =~ ^[0-9]+$ ]]; then
        ASK_WAIT=$AFD_AFK_TIMEOUT
        (( ASK_WAIT > 60 )) && ASK_WAIT=$(( ASK_WAIT - 30 ))
        return 0
    fi
    { read -r w _ < "${CARE_FILE:-$HOME/.afd-care}"; } 2>/dev/null
    if [[ "$w" == active ]]; then ASK_WAIT=900; else ASK_WAIT=2700; fi
}

# afd_asked_span <seconds> — "15 min", or "<n> s" under two minutes.
afd_asked_span() { if (( $1 >= 120 )); then echo "$(( $1 / 60 )) min"; else echo "$1 s"; fi; }

# afd_asked_begin <q> <project> <sid> <claude pid> <wait> <question text> — record a sent question.
afd_asked_begin() { _afd_asked_py ask "$@" >/dev/null || true; }

# afd_asked_end <q> <outcome> <sid> [told] — record how the wait ended. A timeout also leaves the
# Stop hook a marker (.asked-default/<sid>, "<q> <tries>") to read the session's AFK_DEFAULT line.
# Every writer of those markers holds .asked-default/.lock (at most 3 s, then unlocked, like the
# queue lock), so the Stop hook's or the sweep's rewrite cannot drop this append (re-review 6).
afd_asked_end() {
    local d
    _afd_asked_py end "$1" "$2" "${4:-}" >/dev/null || true
    if [[ "$2" == timeout && -n "${3:-}" ]]; then
        d="$(_afd_asked_dir)/.asked-default"
        mkdir -p "$d" 2>/dev/null || return 0
        if command -v flock >/dev/null 2>&1; then
            ( flock -w 3 9 || true; printf '%s 0\n' "$1" >> "$d/${3//[^A-Za-z0-9_-]/_}" ) 9>>"$d/.lock" 2>/dev/null
        else
            printf '%s 0\n' "$1" >> "$d/${3//[^A-Za-z0-9_-]/_}" 2>/dev/null
        fi
    fi
    return 0
}

# afd_asked_capture <stop hook payload> — record the AFK_DEFAULT line(s) this session owes. Pure bash
# unless the session has a marker.
afd_asked_capture() {
    local sid="" m
    [[ "$1" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && sid="${BASH_REMATCH[1]}"
    [[ -n "$sid" ]] || return 0
    m="$(_afd_asked_dir)/.asked-default/${sid//[^A-Za-z0-9_-]/_}"
    [[ -f "$m" ]] || return 0
    AFD_ASKED_PAYLOAD="$1" _afd_asked_py capture "$m" >/dev/null || true
}

# afd_asked_annotate <json line> — the line, labelled late_answer_to/late_question when it is a
# Telegram Reply to a timed-out question or to a re-send of it (and that question is closed).
afd_asked_annotate() {
    local out=""
    [[ "$1" == *'"reply_to"'* && -f "$(_afd_asked_dir)/.asked.jsonl" ]] \
        && out=$(AFD_ASKED_LINE="$1" _afd_asked_py annotate)
    printf '%s\n' "${out:-$1}"
}

# afd_reask <afd cli> — the Telegram `re-ask`: prints "<re-sent> <defaults summarised>".
afd_reask() { _afd_asked_py reask "$1" || echo "0 0"; }

_AFD_ASKED_PY='
import fcntl, json, os, re, socket, subprocess, sys, time
F = os.environ["AFD_ASKED_FILE"]
KEEP = 7 * 86400
HOST = (os.environ.get("AFD_HOSTNAME") or socket.gethostname()).split(".")[0]

def load():
    out = []
    try:
        with open(F) as fh:
            for l in fh:
                try: out.append(json.loads(l))
                except ValueError: pass
    except OSError: pass
    return out

def append(*evs):
    os.makedirs(os.path.dirname(F), exist_ok=True)
    with open(F, "a") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        for e in evs:
            e.setdefault("at", int(time.time()))
            fh.write(json.dumps(e) + "\n")

class marker_lock:
    """.asked-default/.lock around a read-modify-write of a default marker (re-review 6); after 3 s
    a wedged lock is ignored, as the queue lock does."""
    def __init__(self, d): self.p = os.path.join(d, ".lock")
    def __enter__(self):
        try: self.f = open(self.p, "a")
        except OSError: self.f = None; return self
        end = time.time() + 3
        while True:
            try: fcntl.flock(self.f, fcntl.LOCK_EX | fcntl.LOCK_NB); return self
            except OSError:
                if time.time() > end: return self
                time.sleep(0.05)
    def __exit__(self, *a):
        if self.f: self.f.close()

def fold(evs):
    qs = {}
    for e in evs:
        q, ev = str(e.get("q", "")), e.get("ev")
        if ev == "asked":
            qs[q] = dict(e, q=q, reasked=[], late=False, summarized=False); continue
        r = qs.get(q)
        if r is None: continue
        if ev == "outcome": r["outcome"] = e.get("outcome")
        elif ev == "default": r["default"] = e.get("text", ""); r["missing"] = bool(e.get("missing"))
        elif ev == "reasked": r["reasked"].append(str(e.get("as")))
        elif ev == "late": r["late"] = True
        elif ev == "summarized": r["summarized"] = True
    return qs

def pstart(pid):
    try: return open("/proc/%s/stat" % pid).read().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError): return ""

def alive(r):
    pid = str(r.get("pid") or "")
    if not pid.isdigit(): return True                # unknown process: re-send rather than lose it
    st = pstart(pid)
    return bool(st) and (not r.get("pstart") or st == str(r["pstart"]))

def hhmm(t): return time.strftime("%H:%M", time.localtime(t))

def span(s):                                          # as afd_asked_span: "15 min", "<n> s" under 2 min
    s = int(s or 0)
    return "%d min" % (s // 60) if s >= 120 else "%d s" % s

def sweep(qs):
    """Drop the default markers (.asked-default/<sid>) of sessions that are gone: their default
    is recorded as not stated, so no marker waits forever (review #8). True when it recorded any."""
    d = os.path.join(os.path.dirname(F), ".asked-default")
    try: names = [n for n in os.listdir(d) if ".tmp." not in n and n != ".lock"]
    except OSError: return False
    evs = []
    with marker_lock(d):
        for n in names:
            p = os.path.join(d, n)
            try: rows = [l.split() for l in open(p) if l.strip()]
            except OSError: continue
            keep = []
            for row in rows:
                r = qs.get(row[0])
                if r is None or "default" in r: continue   # pruned, unknown or already recorded
                if not alive(r):
                    evs.append({"ev": "default", "q": int(row[0]), "text": "", "missing": True}); continue
                keep.append(" ".join(row))
            if len(keep) == len(rows): continue
            if keep:
                tmp = p + ".tmp.%d" % os.getpid()
                open(tmp, "w").write("\n".join(keep) + "\n"); os.replace(tmp, p)
            else:
                os.remove(p)
    if evs: append(*evs)
    return bool(evs)

def cmd_ask(q, project, sid, pid, wait, question):
    sweep(fold(prune(load())))                        # the record stays bounded between re-asks too
    append({"ev": "asked", "q": int(q), "project": project, "sid": sid, "pid": pid,
            "pstart": pstart(pid) if pid.isdigit() else "", "question": question, "wait": int(wait)})

def cmd_end(q, outcome, told):
    append({"ev": "outcome", "q": int(q), "outcome": outcome, "told": told})

def texts_of(p):
    yield str(p.get("last_assistant_message") or "")
    tp = p.get("transcript_path")
    if not tp: return
    try:
        with open(tp, "rb") as fh:
            fh.seek(0, 2); fh.seek(max(0, fh.tell() - 4000000))
            lines = fh.read().decode("utf-8", "replace").splitlines()
    except OSError: return
    for l in reversed(lines):
        try: e = json.loads(l)
        except ValueError: continue
        if e.get("type") != "assistant": continue
        for c in (e.get("message") or {}).get("content") or []:
            if isinstance(c, dict) and c.get("type") == "text": yield str(c.get("text", ""))

def found_default(q, texts):
    for t in texts:
        for m in re.finditer(r"AFK_DEFAULT #" + re.escape(q) + r":[ \t]*([^\n]+)", t):
            v = m.group(1).strip().strip("`*_ ").strip()
            if v and not re.fullmatch(r"<[^>]*>", v): return v[:500]
    return None

def cmd_capture(marker):
    texts = list(texts_of(json.loads(os.environ.get("AFD_ASKED_PAYLOAD") or "{}")))   # slow part: unlocked
    with marker_lock(os.path.dirname(marker)):
        try: rows = [l.split() for l in open(marker) if l.strip()]
        except OSError: return
        keep, evs = [], []
        for row in rows:
            q, tries = row[0], int(row[1]) if len(row) > 1 and row[1].isdigit() else 0
            v = found_default(q, texts)
            if v: evs.append({"ev": "default", "q": int(q), "text": v})
            elif tries + 1 >= 3: evs.append({"ev": "default", "q": int(q), "text": "", "missing": True})
            else: keep.append("%s %d" % (q, tries + 1))
        if evs: append(*evs)
        if keep:
            tmp = marker + ".tmp.%d" % os.getpid()
            open(tmp, "w").write("\n".join(keep) + "\n"); os.replace(tmp, marker)
        else:
            os.remove(marker)

def cmd_annotate():
    line = os.environ["AFD_ASKED_LINE"]
    d = json.loads(line); rt = str(d.get("reply_to") or "")
    for q, r in fold(load()).items():
        if r.get("outcome") == "timeout" and not r["late"] and rt and (rt == q or rt in r["reasked"]):
            d["late_answer_to"] = int(q)
            d["late_question"] = str(r.get("question", "")).split("\n")[0][:120]
            append({"ev": "late", "q": int(q), "via": d.get("id")})
            print(json.dumps(d)); return
    print(line)

def prune(evs):
    now, qs = time.time(), fold(evs)
    old = {q for q, r in qs.items() if now - float(r.get("at") or now) > KEEP}
    if not old: return evs
    with open(F, "r+") as fh:                         # re-read under the lock: appends may have landed
        fcntl.flock(fh, fcntl.LOCK_EX)
        keep = []
        for l in fh:
            try: e = json.loads(l)
            except ValueError: continue
            if str(e.get("q", "")) not in old: keep.append(e)
        fh.seek(0); fh.truncate(); fh.write("".join(json.dumps(e) + "\n" for e in keep))
    return keep

def notify(cli, msg):
    try:
        r = subprocess.run([cli, "notify", "all", msg, "--channel", "telegram", "--type", "info"],
                           capture_output=True, text=True, timeout=45, stdin=subprocess.DEVNULL)
        return r.stdout + r.stderr
    except (OSError, subprocess.SubprocessError): return ""

def default_text(r):
    if r.get("default"): return r["default"]
    return "a default it did not state" if r.get("missing") else "a default not recorded yet"

def cmd_reask(cli):
    qs = fold(prune(load()))
    if sweep(qs): qs = fold(load())
    timed = sorted((r for r in qs.values() if r.get("outcome") == "timeout"), key=lambda r: r.get("at", 0))
    sent = 0
    for r in timed:
        if r["late"] or not alive(r): continue
        p = r.get("project", "?")
        msg = ("[%s] Re-ask of #%s (on %s, asked %s, no answer within %s; %s went on with: %s):\n\n%s\n\n"
               "Reply to THIS message to answer; %s gets your answer as a Telegram message."
               % (p, r["q"], HOST, hhmm(r.get("at", 0)), span(r.get("wait")), p, default_text(r),
                  r.get("question", ""), p))
        m = re.search(r"#(\d+)", notify(cli, msg))
        if m: append({"ev": "reasked", "q": int(r["q"]), "as": m.group(1)}); sent += 1
    listed = [r for r in timed if not r["summarized"]]
    if listed:
        body = "\n".join("- [%s] #%s (%s): %s" % (r.get("project", "?"), r["q"], hhmm(r.get("at", 0)), default_text(r)) for r in listed)
        msg = "[re-ask] Default decisions taken after unanswered questions on %s:\n%s\nRe-sent %d open question(s) from %s." % (HOST, body, sent, HOST)
    else:
        msg = ("[re-ask] No default decisions to report on %s since the last re-ask; re-sent %d open question(s) from %s. "
               "Other machines keep their own record." % (HOST, sent, HOST))
    if re.search(r"#\d+", notify(cli, msg)):
        done = [{"ev": "summarized", "q": int(r["q"])} for r in listed if "default" in r]
        if done: append(*done)
    print(sent, len(listed))

cmd, args = sys.argv[1], sys.argv[2:]
{"ask": cmd_ask, "end": cmd_end, "capture": cmd_capture, "annotate": cmd_annotate, "reask": cmd_reask}[cmd](*args)
'
