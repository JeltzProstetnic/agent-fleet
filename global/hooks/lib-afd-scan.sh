#!/usr/bin/env bash
# lib-afd-scan.sh — the pool scan behind lib-afd-ask.sh (CFG-779): one python pass over the
# untagged pool. `_afd_ask_scan candidate` prints "<tier> <id> <open ask-backs of others>" for
# the line the relay may claim now; `_afd_ask_scan verdict` prints
# "<yes|no|redirect|nudge> <target|-> <id>" for the verdict on the relay's ask-back (ASK_C /
# ASK_M) — `nudge` names a bare verdict that is nobody's because another ask-back is open.
# Reads the relay globals ME, NOTIF_ID (Q), ASK_M, ASK_C, ASK_QN and env AFD_ASK_GRACE, ONLY0.
# Split out of lib-afd-ask.sh on 2026-10-25 to keep that hook under the 300-line limit.
#
# Verdict rules (decided 2026-10-25): a line that EXPLICITLY answers this ask-back — a Telegram
# reply to it, or one naming #C / #M — is read by its FIRST token: a yes-word, a no-word or an
# @project (exact or unique prefix, as routing resolves it); any other first token leaves the
# line in place as nobody's verdict. Any other pooled line is a verdict only as a sole y/n
# token or a sole @tag (the ask-back grammar is "@project": a bare project name is not a
# redirect), and only while no OTHER ask-back is open ("require a target"). No apostrophes
# inside the program below: it lives in a single-quoted bash string.

[[ "${_LIB_AFD_SCAN_LOADED:-}" == "true" ]] && return 0
_LIB_AFD_SCAN_LOADED="true"

_AFD_ASK_SCAN_PY='
import json, os, re, sys, time
E, mode = os.environ, sys.argv[1]
pool, msgdir, me, mypid = E["POOL"], E["MSGDIR"], E["ME"], E["MYPID"]
Q, C, M = int(E["Q"] or 0), int(E["C"] or 0), int(E["M"] or 0)
grace, qn, only0 = float(E["GRACE"] or 0), int(E["QN"] or 1), E.get("ONLY0") == "1"
known = [k for k in E["KNOWN"].split("\n") if k]
YES, NO = {"y", "yes", "ja", "j", "yep", "yup"}, {"n", "no", "nein", "nope"}   # a bare line
YES_X = YES | {"ok", "okay", "sure", "yeah", "yea", "correct", "right", "mine", "jo", "passt"}
NO_X = NO | {"nah", "nicht", "not"}                                          # an explicit reply
TAG = re.compile(r"^@[A-Za-z0-9_.-]+[\s:,]*")

def alive(pid):
    try: os.kill(int(pid), 0); return True
    except Exception: return False

def num(v): return int(v) if str(v).isdigit() else None

def lines():
    out = []
    try:
        for l in open(pool):
            try: d = json.loads(l)
            except Exception: continue
            if isinstance(d, dict): out.append(d)
    except OSError: pass
    return sorted(out, key=lambda d: int(d.get("id", 0) or 0))

def tokens(text):
    """Lowercased tokens with #numbers removed and trailing punctuation stripped."""
    return [t.rstrip(".,!?:;") for t in re.sub(r"#\d+", " ", text.lower()).split()]

def tag_target(tag):
    """The project an @tag means: exact, else a unique prefix (as routing resolves it)."""
    t = tag.lstrip("@")
    if t in known: return t
    hits = [k for k in known if k.startswith(t)] if t else []
    return hits[0] if len(hits) == 1 else None

def classify(t, yes, no):
    """yes / no / redirect for one token, else None."""
    if t in yes: return ("yes", None)
    if t in no: return ("no", None)
    if t.startswith("@"):
        p = tag_target(t)
        if p: return ("redirect", p)
    return None

def verdict(text):
    """A bare line: a sole core y/n token or a sole @tag, else None."""
    toks = tokens(text)
    return classify(toks[0], YES, NO) if len(toks) == 1 else None

def explicit_verdict(text):
    """A reply to this ask-back, read by its first token (wider yes/no sets); None leaves it."""
    toks = tokens(text)
    return classify(toks[0], YES_X, NO_X) if toks else None

def claimed_by_other(i):
    try: owner = open(f"{msgdir}/.claims/{i}/owner").read().split()
    except OSError: return False
    return bool(owner) and owner[0] != mypid and alive(owner[0])

def others():
    """(Q, M, C) of each other project with a live relay (one marker per project; ours is
    .waiting/<me>; a dot-name is a marker being written); M and C are 0 until its ask-back is out."""
    out = []
    try: names = os.listdir(f"{msgdir}/.waiting")
    except OSError: return out
    for n in names:
        if n == me or n.startswith("."): continue
        try: f = open(f"{msgdir}/.waiting/{n}").read().split()
        except OSError: continue
        if len(f) >= 2 and alive(f[0]):
            asked = len(f) >= 5 and f[2] == "claimed"
            out.append((num(f[1]) or 0, num(f[3]) or 0 if asked else 0, num(f[4]) or 0 if asked else 0))
    return out

def refs(d, text):
    m = re.search(r"#(\d+)", text)
    return num(d.get("reply_to")), (int(m.group(1)) if m else None)

def reserved(d, i, text, pend):
    """True when another relay reads this line as the verdict on its ask-back."""
    rt, ref = refs(d, text)
    for q, m, c in pend:
        if rt == c or ref in (c, m): return True
        if i > c and rt is None and ref is None and verdict(text): return True
    return False

def candidate():
    now, oth, best = time.time(), others(), None
    pend = [o for o in oth if o[2]]
    foreign = {x for o in oth for x in (o[0], o[2]) if x}   # their questions and ask-backs
    for d in lines():
        i, text, rt = int(d.get("id", 0) or 0), str(d.get("message", "")), num(d.get("reply_to"))
        body = TAG.sub("", text).strip()
        if i <= Q or not body or me in (d.get("rejected") or []) or claimed_by_other(i): continue
        if rt == Q: return (0, i, len(pend))
        if only0 or rt in foreign or reserved(d, i, text, pend): continue
        if qn <= 1 or len(body.split()) == qn: tier = 1
        elif now - float(d.get("pooled") or 0) >= grace: tier = 2
        else: continue
        if best is None or tier < best[0]: best = (tier, i, len(pend))
    return best

def verdict_line():
    pend, nudge = [o for o in others() if o[2]], None
    for d in lines():
        i, text = int(d.get("id", 0) or 0), str(d.get("message", ""))
        if i == M: continue
        rt, ref = refs(d, text)
        if rt == C or ref in (C, M):
            v = explicit_verdict(text)
            if v: return (v, i)
            continue
        if i > C and rt is None and ref is None and verdict(text):
            if not pend: return (verdict(text), i)
            nudge = nudge or (("nudge", None), i)   # a bare verdict nobody may take
    return nudge

r = candidate() if mode == "candidate" else verdict_line()
if r and mode == "candidate": print(r[0], r[1], r[2])
elif r: print(r[0][0], r[0][1] or "-", r[1])
'

# _afd_ask_scan <candidate|verdict> — run the scan with the relay's state in the environment.
_afd_ask_scan() {
    POOL="$(_afd_pool_file)" MSGDIR="$(_afd_msg_dir)" ME="$ME" MYPID="$$" Q="$NOTIF_ID" \
    C="${ASK_C:-0}" M="${ASK_M:-0}" GRACE="${AFD_ASK_GRACE:-20}" QN="${ASK_QN:-1}" \
    KNOWN="$(_afd_known_projects)" python3 -c "$_AFD_ASK_SCAN_PY" "$1" 2>/dev/null
}
