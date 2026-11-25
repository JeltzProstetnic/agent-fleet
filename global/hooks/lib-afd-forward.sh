#!/usr/bin/env bash
# lib-afd-forward.sh — a Telegram message meant for another live session reaches it (CFG-1039).
#
# The user, 2026-11-15: "when a telegram message is very obviously for a different session, one that
# is live even, why cant it then be relayed?" At 11:27 `@cfg 1153 fail.mode 2 … 1154 1` answered
# another project's AFK questions (#1153 timed out, its relay waiting on #1154): routing honoured
# the @cfg, cfg had no way to pass the message on, and the user had to resend it. Two mechanics:
#   (a) routing — afd_question_route, called by lib-afd-msg.sh for each consumed line while a relay
#       waits. The line goes to a waiting relay's project W when its text, after an optional @tag,
#       STARTS with the number of a question W asked (open, or timed out) and names W's OPEN question
#       (live marker .waiting/<W> + an .asked.jsonl record with no outcome, lib-afd-asked.sh) — also
#       when its @tag or Telegram Reply points at a project that is not waiting ("the number wins").
#       "Very obviously" (the user's words): a number only mentioned ("@cfg yes, same as 1154",
#       "PR #1154") is no answer (review B2/S3), nor is a message that is only a question number
#       (Q-1039-F6). The number ends at whitespace or the end, or at one of ":,.)" before them; ASCII
#       digits, compared by value (N-a, N-b). Not rerouted: the text names the open questions of two
#       other relays, a Reply to a waiting relay's ask-back (N-c), a bare "@project #n" verdict
#       (lib-afd-msg.sh). When the pointed project X waits itself (Q-1039-4, the user: "non unique -
#       either content makes it clear or refuse"): the text after the number decides — it is CLEAR
#       only when it FITS exactly one of the two questions (fits(): a digit in its option range, a
#       label, a label's first word, or the start of a label, casefolded; review 3 B-1); then the line
#       goes there. Else it answers neither: filed in X's queue marked "ambiguous" (no relay takes it)
#       and the user gets one Telegram line, tagged [X], naming both questions and how to resend. A
#       routed line is bound to its question ("for_question"); afd_queue_first_after takes it as the
#       answer to that one only.
#   (b) `afd forward <project> --id <n>` — afd_forward_cli, which the afd CLI runs after fetching
#       Telegram message #n from the server (AFD_FWD_NOTIF; AFD_FWD_FETCH=404 when it is not there).
#       The text is NEVER taken from the command line (free text forged the user's answer, review
#       B1). Filed, with the server's text and persona, into <project>'s queue under the queue lock,
#       marked redirected, forwarded_from = the calling project — only a row with source telegram,
#       type message and the shape telegram.js gives an inbound message (machine and channel "all",
#       never sent to Telegram: no tg_message_id, no delivered_at). RESIDUAL RISK (review 3 S-4): any
#       token holder can still mint that exact shape — `afd notify all "…" --type message --source
#       telegram` (POST /api/notify passes type and source through) on machine and channel "all"
#       keeps tg_message_id and delivered_at NULL whenever its Telegram send fails (a text over 4096
#       characters; parse errors are retried as plain text) or Telegram is off — and PATCH
#       /api/notifications/<id> can reset tg_message_id and delivered_at of a delivered row to NULL.
#       `afd messages` then delivers such a row like the user's own, with or without this command.
#       Only the server can close it: CFG-1042 (POST refuses source telegram / type message, PATCH
#       refuses client-set tg_message_id / delivered_at). The text's leading question number decides
#       first (Q-1039-F-FWD): another project's question is refused, one that is only the number is
#       refused, <project>'s timed-out (not late-answered) question makes it a late answer to that
#       one, a question of <project> closed any other way binds it there so no relay takes it (review
#       3 S-1); it is bound to the open question q only when it starts with q or with no question
#       number at all (and is newer than q). It first prints <project>'s open question; `--show` only
#       prints. Otherwise it
#       arrives as an ordinary Telegram message, and the output says so. A message already in that
#       queue is not filed twice. Exit 0 filed (or shown, or already there), 2 usage error or refused
#       message, 1 when it could not be filed.
# Also here: afd_answer_meta (how a relay takes a line: provenance + the leading question number
# stripped, review S4) and _afd_fwd_delivery (the label and text of a line delivered outside a
# relay, with continuation lines of a forwarded or rerouted message indented, review B1/S5).
#
# Sources lib-afd-msg.sh (beside it) for the queue dir, project names, markers and the lock; that
# lib loads this one lazily (circular sourcing is cut by both load guards). Needs python3.

# _python3 (lib-portable.sh, CFG-1087): on native Windows a bare python3 can be the Microsoft Store
# stub; everywhere else it is python3, unchanged. Fallback for a hooks dir without the lib.
source "$(dirname "${BASH_SOURCE[0]}")/lib-portable.sh" 2>/dev/null || true
type _python3 >/dev/null 2>&1 || _python3() { python3 "$@"; }

[[ "${_LIB_AFD_FORWARD_LOADED:-}" == "true" ]] && return 0
source "$(dirname "${BASH_SOURCE[0]}")/lib-afd-msg.sh" || return 1
_LIB_AFD_FORWARD_LOADED="true"

# _afd_fwd_py <route|show|line|answer|deliver> — the program below, with the env the caller set.
_afd_fwd_py() { AFD_FWD_ASKED="$(_afd_msg_dir)/.asked.jsonl" _python3 -c "$_AFD_FWD_PY" "$1" 2>/dev/null; }

# _afd_waiting_q <project> — the question id <project>'s LIVE relay waits on, or nothing.
_afd_waiting_q() {
    local m q=""
    m="$(_afd_msg_dir)/.waiting/$1"
    [[ -f "$m" ]] && _afd_marker_live "$m" && read -r _ q _ < "$m" 2>/dev/null
    [[ "$q" =~ ^[0-9]+$ ]] && echo "$q"
    return 0
}

# afd_question_route <json line> <live waiters, newline-separated> — "<project> <the line, bound or
# marked ambiguous>" when (a) above routes the line, else nothing; for an ambiguous one a second line
# "NOTICE <text>" for the user.
afd_question_route() {
    local w m q c pairs=""
    while IFS= read -r w; do
        [[ -n "$w" ]] || continue
        m="$(_afd_msg_dir)/.waiting/$w"; q=""; c=""
        [[ -f "$m" ]] && _afd_marker_live "$m" && read -r _ q _ _ c < "$m" 2>/dev/null   # "<pid> Q [claimed M C]"
        [[ "$q" =~ ^[0-9]+$ ]] && pairs="$pairs $w:$q:${c//[^0-9]/}"
    done <<< "$2"
    [[ -n "$pairs" ]] || return 0
    AFD_FWD_LINE="$1" AFD_FWD_PAIRS="$pairs" KNOWN="$(_afd_known_projects)" _afd_fwd_py route
}

# afd_answer_meta <json line> <question id> — how a waiting relay takes this line as the answer to
# <question id>: "<how>\x1f<id>\x1f<forwarded from>\x1f<note>", then the answer text. how = tagged |
# redirected | forwarded | rerouted; the note says where a forwarded or rerouted answer came from.
afd_answer_meta() { AFD_FWD_LINE="$1" AFD_FWD_Q="$2" _afd_fwd_py answer; }

# _afd_fwd_delivery <json line> <me> — "<time>\x1f<persona>\x1f<label>", then the text, for a line
# delivered outside a relay (afk-deactivate.sh, afd-idle-wake.sh). A line bound to a question that
# has timed out since is labelled a late answer, and its late event recorded (lib-afd-asked.sh), so
# re-ask does not send that question again (review S5).
_afd_fwd_delivery() {
    local line="$1"
    [[ "$line" == *'"for_question"'* ]] && _afd_asked_lib && line=$(afd_asked_annotate "$line")
    AFD_FWD_LINE="$line" AFD_FWD_ME="$2" _afd_fwd_py deliver
}

_afd_forward_usage() {
    echo "afd forward: $1" >&2
    echo "Usage: afd forward <project> --id <Telegram message id>   |   afd forward <project> --show" >&2
}

# _afd_forward_parse <args> — sets _FWD_PROJECT, _FWD_ID, _FWD_SHOW; 2 on a usage error. The id is
# checked as a bounded positive integer before anything does arithmetic with it (review N3).
_afd_forward_parse() {
    _FWD_PROJECT="" _FWD_ID="" _FWD_SHOW=false
    while (( $# )); do
        case "$1" in
            --show) _FWD_SHOW=true ;;
            --id) _FWD_ID="${2:-}"; (( $# > 1 )) && shift ;;
            -*) _afd_forward_usage "unknown option $1"; return 2 ;;
            *) if [[ -z "$_FWD_PROJECT" ]]; then _FWD_PROJECT="$1"; else
                   _afd_forward_usage "\"$1\" is not accepted: the text is never taken from the command line, only the Telegram message --id names, fetched from the server"
                   return 2
               fi ;;
        esac
        shift
    done
    [[ -n "$_FWD_PROJECT" ]] || { _afd_forward_usage "no project given"; return 2; }
    $_FWD_SHOW && return 0
    [[ "$_FWD_ID" =~ ^[1-9][0-9]{0,14}$ ]] \
        || { _afd_forward_usage "--id needs the Telegram message id: a positive number of at most 15 digits"; return 2; }
}

# _afd_forward_append <queue> <line> <id> — append under the lock; 3 when that id is queued there already.
_afd_forward_append() {
    [[ -f "$1" ]] && grep -qE "\"id\": ?$3[,}]" "$1" && return 3
    printf '%s\n' "$2" >> "$1"
}

# afd_forward_cli <args> — `afd forward`, (b) in the header.
afd_forward_cli() {
    local target from q out kind fq line dir rc=0
    _afd_forward_parse "$@" || return 2
    target=$(_afd_resolve_target "$(printf '%s' "$_FWD_PROJECT" | tr '[:upper:]' '[:lower:]')")
    if [[ -z "$target" ]]; then
        _afd_forward_usage "no project '$_FWD_PROJECT' under ${AFD_PROJECT_ROOTS:-$HOME} (exact name or a unique prefix); nothing filed"
        return 2
    fi
    q=$(_afd_waiting_q "$target")
    if ! $_FWD_SHOW; then
        from=$(afd_project_of "$PWD")
        out=$(AFD_FWD_ID="$_FWD_ID" AFD_FWD_FROM="$from" AFD_FWD_TARGET="$target" AFD_FWD_Q="$q" _afd_fwd_py line)
        { read -r kind fq; IFS= read -r line; } <<< "$out"
        case "$kind" in
            open|late|none|older|closed) ;;
            refused) _afd_forward_usage "${out#refused * }; nothing filed"; return 2 ;;
            *) echo "afd forward: could not build the queue line (python3?); nothing filed" >&2; return 1 ;;
        esac
    fi
    AFD_FWD_TARGET="$target" AFD_FWD_Q="$q" _afd_fwd_py show
    $_FWD_SHOW && return 0
    dir=$(_afd_msg_dir); mkdir -p "$dir" 2>/dev/null
    _afd_locked _afd_forward_append "$dir/$target.jsonl" "$line" "$_FWD_ID" || rc=$?
    _afd_forward_said "$kind" "$rc" "$target" "$from" "$q" "$fq"
}

# _afd_forward_said <kind> <append rc> <target> <from> <q> <bound q> — the outcome line; its exit code.
_afd_forward_said() {
    local how="Filed into $3's queue as forwarded from $4 (Telegram #$_FWD_ID)"
    case "$2" in
        0) ;;
        3) echo "Telegram #$_FWD_ID is already in $3's queue; nothing filed again."; return 0 ;;
        *) echo "afd forward: could not write $3's queue; nothing filed" >&2; return 1 ;;
    esac
    case "$1" in
        open)  echo "$how: the $3 relay waiting on #$5 takes it as its answer." ;;
        late)  echo "$how, as a late answer to $3's timed-out question #$6: it arrives as an ordinary Telegram message labelled so." ;;
        older) echo "$how, but NOT as the answer to #$5: Telegram #$_FWD_ID is older than that question. It arrives at $3 as an ordinary Telegram message." ;;
        closed) echo "$how, but not as an answer: it starts with #$6, a question $3 no longer waits on. It arrives at $3 as an ordinary Telegram message." ;;
        *)     echo "$how. No $3 relay is waiting, so it is not taken as an answer: it arrives as an ordinary Telegram message at $3's next prompt (or idle wake), or at its next start when no $3 session is live." ;;
    esac
    return 0
}

# A quoted heredoc, not a single-quoted string: one apostrophe in the program must not end it (N5).
IFS= read -r -d '' _AFD_FWD_PY << 'PY' || true
import json, os, re, sys, time
E, mode = os.environ, sys.argv[1]
# A number standing alone ("1154", "#1154", "1154:"), never one inside a word, an id like CFG-1154,
# a version or a decimal; ASCII digits only (N-b).
NUM = re.compile(r"(?:(?<![\w.-])#|(?<![\w.#-]))(\d+)(?!\w|\.\d)", re.ASCII)
# The one ending rule for a LEADING number, shared by the router, forward and the answer strip (N-a):
# whitespace or the end, or one of ":,.)" right before them. "1154%", "1154-1160", "1154/1160" do not lead.
LEAD = re.compile(r"#?(\d+)(?=[:,.)]?(?:\s|$))", re.ASCII)
TAG = re.compile(r"^@[A-Za-z0-9_.-]+[\s:,]*", re.ASCII)

def split_lead(text):
    """(the question number the text starts with, as its integer value in a str, the text after it),
    after an optional @tag; (None, the text) when it starts with no number. A separating " - " after
    the number goes with it (N-3: "1154 - 2" leaves "2")."""
    body = TAG.sub("", str(text)).lstrip()
    m = LEAD.match(body)
    if not m: return None, body
    return str(int(m.group(1))), re.sub(r"^[:,.)]?\s*(?:[-–—]\s+)?", "", body[m.end():])

def norm(s): return " ".join(str(s).casefold().split())

OPT = re.compile(r"^  (\d+)\) (.*)$")

def single(r):
    """The option labels of a single-question relay, from its option block only (N-5): afd-relay.sh
    writes the question text, then "  N) label" per option, numbered 1..n, at the end. A numbered
    line inside the question text is no option; a text with option-like lines in more than one place
    (several questions, or a numbered list in the question) has no single option block: None."""
    lines = str(r.get("question", "")).splitlines()
    runs, cur = [], []
    for l in lines:
        if OPT.match(l): cur.append(l)
        elif cur: runs.append(cur); cur = []
    if not cur or runs: return None                # the option block must end the text, and be the only one
    nums = [int(OPT.match(l).group(1)) for l in cur]
    start = len(nums) - 1
    while start > 0 and nums[start] != 1: start -= 1   # the block is the last run numbered 1..n
    if nums[start:] != list(range(1, len(nums) - start + 1)): return None
    return [norm(OPT.match(l).group(2)) for l in cur[start:]]

def fits(text, labels):
    """Review 3 B-1: the text answers that question when, casefolded and whitespace-normalised, it is a
    digit within its option range, equals a label, equals a label first word with its punctuation
    stripped, or a label starts with it. A question without a single option block fits anything."""
    if labels is None: return True
    t = norm(text)
    if not t: return False
    if re.fullmatch(r"[0-9]+", t) and 1 <= int(t) <= len(labels): return True
    for l in labels:
        first = re.sub(r"\W+", "", l.split()[0]) if l else ""
        if t == l or (first and t == first) or l.startswith(t): return True
    return False

def first_line(r): return (str(r.get("question", "")).splitlines() or [""])[0][:60]

def records():
    """{question id: {project, question, at, outcome, late}} from .asked.jsonl (lib-afd-asked.sh)."""
    out = {}
    try:
        for l in open(E["AFD_FWD_ASKED"]):
            try: e = json.loads(l)
            except ValueError: continue
            q, ev = str(e.get("q", "")), e.get("ev")
            if ev == "asked":
                out[q] = {"project": str(e.get("project", "")), "question": str(e.get("question", "")), "at": e.get("at") or 0}
            elif q in out and ev == "outcome": out[q]["outcome"] = e.get("outcome")
            elif q in out and ev == "late": out[q]["late"] = True
    except OSError: pass
    return out

def pointer(d, text):
    """The project the line points at: its @tag (exact, else a unique prefix), else a Reply's sender."""
    known = [k for k in E.get("KNOWN", "").split("\n") if k]
    m = re.match(r"@([A-Za-z0-9_.-]+)", text)
    if m:
        t = m.group(1).lower(); hits = [k for k in known if k.startswith(t)]
        return t if t in known else (hits[0] if len(hits) == 1 else "")
    p = str(d.get("reply_to_project") or "").lower()
    return p if p in known else ""

def route():
    d = json.loads(E["AFD_FWD_LINE"]); text = str(d.get("message", ""))
    L, content = split_lead(text)
    if L is None: return                           # it must START with a question number
    rec, live, askbacks = records(), {}, set()
    for p in E["AFD_FWD_PAIRS"].split():
        w, q, c = (p.split(":") + ["", ""])[:3]
        live[w] = q
        if c: askbacks.add(c)
    if str(d.get("reply_to") or "") in askbacks: return   # a verdict on an ask-back (N-c)
    open_q = {w: q for w, q in live.items() if rec.get(q, {}).get("project") == w and "outcome" not in rec[q]}
    named = {str(int(n)) for n in NUM.findall(text)}
    ptr = pointer(d, text)
    hits = [(w, q) for w, q in open_q.items() if q in named and w != ptr]
    if len(hits) != 1: return                      # none, or two relays: routing as today
    w, q = hits[0]
    r = rec.get(L, {})                             # it starts with a question of that project
    if r.get("project") != w or r.get("outcome") not in (None, "timeout"): return
    if not content.strip(): return                 # only a number is no answer (Q-1039-F6), nor a notice (N-2)
    d["lead_question"] = int(L)
    if ptr: d["rerouted_from"] = ptr
    pq = open_q.get(ptr)
    if not pq:                                     # the pointed project does not wait: the number wins
        d["for_question"] = int(q); print(w, json.dumps(d)); return
    # Q-1039-4: the pointed project waits too. Clear only when the text after the number fits exactly
    # one of the two questions (fits(), review 3 B-1).
    fx, fy = fits(content, single(rec[pq])), fits(content, single(rec[q]))
    if fx != fy:
        d["for_question"] = int(q if fy else pq)
        if fx: d["routed_by"] = "content"
        print(w if fy else ptr, json.dumps(d)); return
    d["ambiguous"] = [int(pq), int(q)]; d["ambiguous_with"] = w
    print(ptr, json.dumps(d))
    theirs = ("%s's open question" % w) if L == q else ("a question of %s, which waits on #%s" % (w, q))
    print(("NOTICE [%s] Telegram #%s answered neither question: it is tagged for %s, which waits on #%s (%s), but "
           "starts with #%s, %s (%s). Resend it as @%s <answer> for #%s, or @%s <answer> for #%s.")
          % (ptr, d.get("id"), ptr, pq, first_line(rec[pq]), L, theirs, first_line(rec[q]), ptr, pq, w, q))

def show():
    p, q = E["AFD_FWD_TARGET"], E.get("AFD_FWD_Q", "")
    if not q:
        print("%s has no open question: no %s relay is waiting on a Telegram question." % (p, p)); return
    r = records().get(q)
    if not r or r["project"] != p:
        print("Open question of %s: #%s (its relay is waiting on it; the question text is not recorded here)." % (p, q)); return
    print("Open question of %s, its relay waiting for the Telegram answer: #%s (asked %s)" % (p, q, time.strftime("%H:%M", time.localtime(float(r["at"] or 0)))))
    for l in r["question"].splitlines()[:20]: print("    " + l)

def refused(why): print("refused - " + why)

def server_copy(i):
    """The fetched row when it is the user's Telegram message #i, else None (a refusal printed)."""
    if E.get("AFD_FWD_FETCH") == "404": return refused("there is no message #%s on the server" % i)
    try: n = json.loads(E.get("AFD_FWD_NOTIF") or "null")
    except ValueError: n = None
    if not isinstance(n, dict): return refused("no server copy of #%s was handed over (run it as afd forward, which fetches it)" % i)
    if str(n.get("id")) != i: return refused("the server copy is #%s, not #%s" % (n.get("id"), i))
    if n.get("source") != "telegram" or n.get("type") != "message":
        return refused("#%s is not a Telegram message from the user (source %s, type %s): only those are forwarded" % (i, n.get("source"), n.get("type")))
    # S-A stopgap: the shape telegram.js gives an inbound message; a row minted through POST /api/notify
    # is refused unless it copies that shape exactly (CFG-1042 closes the rest on the server).
    if n.get("machine") != "all" or n.get("channel") != "all" or n.get("tg_message_id") is not None or n.get("delivered_at") is not None:
        return refused("#%s does not have the shape of a message the user sent on Telegram (machine %s, channel %s, sent to Telegram: %s): only those are forwarded; the server-side fix for minted rows is CFG-1042"
                       % (i, n.get("machine"), n.get("channel"), "yes" if n.get("tg_message_id") is not None or n.get("delivered_at") is not None else "no"))
    if not isinstance(n.get("message"), str) or not n["message"].strip(): return refused("#%s has no text" % i)
    return n

def line():
    """Line 1 "<open|late|older|closed|none> <question>" (or "refused - <why>"), line 2 the queue line."""
    i, target, q = E["AFD_FWD_ID"], E["AFD_FWD_TARGET"], E.get("AFD_FWD_Q", "")
    n = server_copy(i)
    if n is None: return
    text = n["message"]
    d = {"id": int(i), "message": text, "timestamp": str(n.get("created_at") or ""), "persona": n.get("persona"),
         "redirected": True, "forwarded_from": E["AFD_FWD_FROM"], "forwarded_at": int(time.time())}
    L, rest = split_lead(text)
    r = records().get(L, {}) if L else {}
    kind, fq = "none", ""
    if r and r["project"] != target:               # Q-1039-F-FWD: another project's question
        return refused("it starts with #%s, %s's question: forward it to %s, not to %s" % (L, r["project"], r["project"], target))
    if r and not rest.strip(): return refused("it is only the question number #%s: no answer to forward" % L)
    if r and L != q:                               # a question of the target it no longer waits on
        if r.get("outcome") == "timeout" and not r.get("late"): kind, fq = "late", L
        else: kind, fq = "closed", L
    elif q and int(i) > int(q): kind, fq = "open", q
    elif q: kind = "older"
    # A closed question binds the line too (review 3 S-1): bound to a question nobody waits on, it is
    # never the answer to the open one, and reaches the session as an ordinary message.
    if kind in ("open", "late", "closed"): d["for_question"] = int(fq)
    print(kind, fq or "-"); print(json.dumps(d))

def answer():
    d = json.loads(E["AFD_FWD_LINE"]); q = E.get("AFD_FWD_Q", ""); i = d.get("id", 0)
    bound = str(d.get("for_question", "")) == q != ""
    by_content = bound and d.get("routed_by") == "content"
    L, rest = split_lead(str(d.get("message", "")))
    # The leading number is stripped when it is this question's own (S-D, S4: "1154 2" answers #1154
    # with "2"), or the other session's number a content-routed line starts with; never a fallback to
    # the unstripped text (Q-1039-F6: a lone number is no answer).
    if L is not None and (L == q or (by_content and str(d.get("lead_question")) == L)): text = rest.strip()
    else: text = TAG.sub("", str(d.get("message", ""))).strip()
    p = d.get("rerouted_from") or ""
    if d.get("forwarded_from"):
        how, frm, note = "forwarded", d["forwarded_from"], "forwarded by the %s session from Telegram #%s" % (d["forwarded_from"], i)
    elif by_content:
        how, frm, note = "rerouted", "", "kept here by its content: Telegram #%s starts with #%s, another session's question, but its answer fits only this question" % (i, L)
    elif bound:
        how, frm, note = "rerouted", "", "routed here%s: Telegram #%s starts with #%s, %s" % (
            " from @" + p if p else "", i, L, "this question number" if L == q else "a question this session asked earlier")
    else:
        how, frm, note = ("redirected" if d.get("redirected") else "tagged"), "", ""
    print("\x1f".join([how, str(i), frm, note])); print(text)

def deliver():
    d = json.loads(E["AFD_FWD_LINE"]); me = E.get("AFD_FWD_ME", ""); labels = []
    bound, lead = d.get("for_question") not in (None, ""), d.get("lead_question") or d.get("for_question")
    if d.get("forwarded_from"): labels.append("(forwarded here by the %s session from Telegram #%s)" % (d["forwarded_from"], d.get("id")))
    elif d.get("redirected"): labels.append("(redirected here by the user)")
    elif d.get("ambiguous"):
        labels.append("(not taken as an answer: tagged for you while you waited on #%s, but it starts with #%s, a question of %s; the user was asked to resend it)" % (d["ambiguous"][0], lead, d.get("ambiguous_with", "another session")))
    elif bound and d.get("routed_by") == "content":
        labels.append("(its answer fits only your AFK question #%s, although it starts with #%s, another session's question)" % (d["for_question"], lead))
    elif bound: labels.append("(routed here: it starts with your AFK question #%s)" % lead)
    if d.get("late_answer_to"):
        labels.append("(late answer to your AFK question #%s \"%s\", which timed out: revisit the default you took)" % (d["late_answer_to"], d.get("late_question", "")))
    if not labels and d.get("reply_to") and d.get("reply_to_project") == me: labels.append("(reply to #%s)" % d["reply_to"])
    text = str(d.get("message", ""))
    if d.get("forwarded_from") or bound or d.get("ambiguous"):   # no continuation line may pass for a message
        text = text.replace("\r", "").replace("\n", "\n    ")
    clean = lambda s: re.sub(r"[\x1f\r\n]", " ", str(s or ""))
    print("\x1f".join([clean(str(d.get("timestamp", ""))[:16]), clean(d.get("persona")), clean(" ".join(labels))])); print(text)

{"route": route, "show": show, "line": line, "answer": answer, "deliver": deliver}[mode]()
PY
