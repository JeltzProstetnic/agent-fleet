#!/usr/bin/env bash
# lib-afd-pool.sh — the untagged pool, atomic claims and locked queue operations behind
# lib-afd-msg.sh (CFG-779, CFG-781).
#
# 2026-10-24: two sessions waited on relayed questions, so an untagged Telegram answer
# fell to whichever session consumed it, and that session took it as its own answer.
# Untagged lines are therefore pooled while any relay waits ($AFD_MSG_DIR/.untagged.jsonl,
# dot-prefixed so afd_wake_hint's per-project *.jsonl glob never reports it as a project),
# and a relay CLAIMS a line before acting on it: `mkdir .claims/<id>` is atomic, the owner
# file names "<pid> <project>", and a claim whose pid is gone is reaped by the next claimer.
#
# Every write to a queue file goes through one flock (.lock): the relay peeks in place and
# deletes by id, so a kill between any two steps leaves every line inside some file — the
# take-and-requeue of CFG-781 is gone. Without flock(1) the operations run unlocked.
# CFG-838 (2026-10-25): a Telegram Reply belongs to the project that SENT the replied-to message;
# the helpers that decide that, and the pool drain that honours it, live at the end of this file.
# Sourced by lib-afd-msg.sh; uses its _afd_msg_dir, _afd_known_projects and _afd_marker_live.

[[ "${_LIB_AFD_POOL_LOADED:-}" == "true" ]] && return 0
_LIB_AFD_POOL_LOADED="true"

_afd_pool_file() { echo "$(_afd_msg_dir)/.untagged.jsonl"; }

# _afd_locked <cmd...> — run <cmd> under the queue lock (fd 9 on $AFD_MSG_DIR/.lock). A lock
# still held after 3 s is treated as wedged: the command runs anyway, unlocked (an O_APPEND
# write is what the queues had before the lock existed) — a server-consumed line is already
# acknowledged and must NEVER be skipped (review 2026-10-25). A subshell, so pass results
# through stdout, not variables.
_afd_locked() {
    local lock; lock="$(_afd_msg_dir)/.lock"
    mkdir -p "$(dirname "$lock")" 2>/dev/null
    if command -v flock >/dev/null 2>&1; then
        ( flock -w 3 9 || exec 9>&-; "$@" ) 9>>"$lock"
    else
        "$@"
    fi
}

_afd_append_line() { printf '%s\n' "$2" >> "$1"; }

# _afd_take_file <file> — print and remove every line of <file> (mv: a concurrent append
# lands in a new file). Call under _afd_locked.
_afd_take_file() {
    local q="$1" tmp
    [[ -s "$q" ]] || return 0
    tmp="$q.taking.$$"
    mv -f "$q" "$tmp" 2>/dev/null || return 0
    cat "$tmp"
    rm -f "$tmp"
}

# afd_pool_add <json line> — pool an untagged line, stamped with the time it was pooled
# (the tier-2 grace in lib-afd-ask.sh runs from it).
afd_pool_add() {
    local line
    line=$(printf '%s' "$1" | python3 -c '
import json, sys, time
d = json.load(sys.stdin); d["pooled"] = int(time.time()); print(json.dumps(d))' 2>/dev/null) || return 0
    [[ -n "$line" ]] && _afd_locked _afd_append_line "$(_afd_pool_file)" "$line"
    return 0
}

# afd_queue_first_after <file> <id> — the first line newer than <id> that has text once a
# leading @tag is stripped (a bare "@project" can never be an answer), or nothing.
afd_queue_first_after() {
    [[ -f "$1" ]] || return 0
    python3 -c '
import json, re, sys
for l in open(sys.argv[1]):
    try: d = json.loads(l)
    except Exception: continue
    if int(d.get("id", 0) or 0) <= int(sys.argv[2]): continue
    if not re.sub(r"^@[A-Za-z0-9_.-]+[\s:,]*", "", str(d.get("message", ""))).strip(): continue
    print(l.rstrip("\n")); break' "$1" "$2" 2>/dev/null
}

# _afd_pool_take_rejected <live waiters, newline-separated> — print and remove every pooled
# line that each live waiter has rejected: nobody waiting will claim it, so it belongs to the
# consumer now instead of after the last relay exits. Call under _afd_locked.
_afd_pool_take_rejected() {
    local f; f="$(_afd_pool_file)"
    [[ -f "$f" && -n "$1" ]] || return 0
    python3 -c '
import json, os, sys, time
f, live = sys.argv[1], {x for x in sys.argv[2].split("\n") if x}
keep, take = [], []
fh = open(f, "rb")
for l in fh.read().decode().splitlines():
    try: d = json.loads(l)
    except Exception: keep.append(l); continue
    (take if live <= set(d.get("rejected") or []) else keep).append(l)
if take:
    time.sleep(float(os.environ.get("_AFD_REWRITE_DELAY") or 0))   # tests only
    tmp = f + ".tmp"
    with open(tmp, "w") as out: out.write("".join(x + "\n" for x in keep))
    os.replace(tmp, f)
    tail = fh.read()   # appended to the old inode after we parsed it
    if tail:
        with open(f, "ab") as out: out.write(tail if tail.endswith(b"\n") else tail + b"\n")
    print("\n".join(take))' "$f" "$1" 2>/dev/null
}

# afd_queue_get <file> <id> — the line with exactly that id, or nothing.
afd_queue_get() {
    [[ -f "$1" ]] || return 0
    python3 -c '
import json, sys
for l in open(sys.argv[1]):
    try: d = json.loads(l)
    except Exception: continue
    if int(d.get("id", 0) or 0) == int(sys.argv[2]):
        print(l.rstrip("\n")); break' "$1" "$2" 2>/dev/null
}

# _afd_queue_rewrite <file> <id> <delete|reject|redirect> [project|target file] — rewrite
# <file> without the line <id> (delete), with that line marked rejected by [project], or
# with it moved to [target file] flagged "redirected". Atomic: temp file + rename. Under lock.
# The parsed descriptor stays open: a line appended to the old inode while this stalled (an
# append whose 3 s lock wait gave up) is re-appended after the rename, so it is never lost.
_afd_queue_rewrite() {
    [[ -f "$1" ]] || return 0
    python3 -c '
import json, os, sys, time
f, want, op, arg = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else ""
keep, moved = [], []
fh = open(f, "rb")
for l in fh.read().decode().splitlines():
    try: d = json.loads(l); i = int(d.get("id", 0) or 0)
    except Exception: keep.append(l); continue
    if i != want: keep.append(l); continue
    if op == "reject":
        r = d.get("rejected") or []
        if arg not in r: r.append(arg)
        d["rejected"] = r; keep.append(json.dumps(d))
    elif op == "redirect":
        d.pop("pooled", None); d.pop("rejected", None); d["redirected"] = True
        moved.append(json.dumps(d))
time.sleep(float(os.environ.get("_AFD_REWRITE_DELAY") or 0))   # tests only: stall before replacing
tmp = f + ".tmp"
with open(tmp, "w") as out: out.write("".join(x + "\n" for x in keep))
os.replace(tmp, f)
tail = fh.read()   # appended to the old inode after we parsed it (an append whose lock wait gave up)
if tail:
    with open(f, "ab") as out: out.write(tail if tail.endswith(b"\n") else tail + b"\n")
if moved:
    with open(arg, "a") as out: out.write("".join(x + "\n" for x in moved))' "$@" 2>/dev/null
}

afd_queue_delete() { _afd_locked _afd_queue_rewrite "$1" "$2" delete; }
afd_pool_reject()  { _afd_locked _afd_queue_rewrite "$(_afd_pool_file)" "$1" reject "$2"; }
afd_pool_redirect() { _afd_locked _afd_queue_rewrite "$(_afd_pool_file)" "$1" redirect "$(_afd_msg_dir)/$2.jsonl"; }

# afd_claim <id> <project> [pid] — 0 when [pid] (default: this shell) owns .claims/<id>
# afterwards. A claim whose owner pid is gone (SIGKILL skips EXIT traps) is reaped first.
afd_claim() {
    local pid="${3:-$$}"
    _afd_locked _afd_claim_unlocked "$1" "$2" "$pid"
}
_afd_claim_unlocked() {
    local d="$(_afd_msg_dir)/.claims/$1" owner
    mkdir -p "$(dirname "$d")" 2>/dev/null
    if ! mkdir "$d" 2>/dev/null; then
        owner=$(cut -d' ' -f1 "$d/owner" 2>/dev/null)
        [[ "$owner" == "$3" ]] && return 0
        [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null && return 1
        rm -rf "$d"; mkdir "$d" 2>/dev/null || return 1
    fi
    echo "$3 $2" > "$d/owner"
}

# afd_release_claim <id> [pid] — drop the claim if [pid] (default: this shell) owns it.
afd_release_claim() {
    local d="$(_afd_msg_dir)/.claims/$1" pid="${2:-$$}"
    [[ "$(cut -d' ' -f1 "$d/owner" 2>/dev/null)" == "$pid" ]] && rm -rf "$d"
    return 0
}

# afd_release_claims_of <pid> — drop every claim <pid> owns (a relay's EXIT trap).
afd_release_claims_of() {
    local d
    for d in "$(_afd_msg_dir)"/.claims/*/; do
        [[ -d "$d" ]] && [[ "$(cut -d' ' -f1 "$d/owner" 2>/dev/null)" == "$1" ]] && rm -rf "$d"
    done
    return 0
}

# ── CFG-838: a Telegram Reply belongs to the project that SENT the replied-to message ──────────
# 2026-10-25: the user replied to one project's info message #529; the server stored reply_to=529,
# but no relay of that project waited, so the line counted as untagged and the first consumer took it.

# _afd_reply_meta <json line> — "<project> <reply_to> [#n …]" when the line is a Telegram Reply to a
# KNOWN project's message, else nothing. The server's reply_to_project is the replied-to notification's
# leading "[project]" tag, machine-written as the sender's full name — so it is matched exactly
# (case-insensitive), never as a prefix the way a human's @tag is (a prefix must not pick another
# project; review MINOR 3). Fast path: no such field, no python.
_afd_reply_meta() {
    local meta
    [[ "$1" == *reply_to_project* ]] || return 0
    meta=$(printf '%s' "$1" | python3 -c '
import json, re, sys
d = json.load(sys.stdin)
p = str(d.get("reply_to_project") or "").lower()
if re.fullmatch(r"[A-Za-z0-9_.-]+", p):
    print(p, d.get("reply_to") or 0, *re.findall(r"#\d+", str(d.get("message", ""))))' 2>/dev/null)
    [[ -n "$meta" ]] && grep -qxF -- "${meta%% *}" <<< "$(_afd_known_projects)" && echo "$meta"
    return 0
}

# _afd_reply_origin <json line> — the project to file a Reply into (the one that sent what it
# answers), or nothing: not such a Reply, or one that may be the verdict or answer its origin's LIVE
# relay waits for and so belongs in the pool — a Reply to that relay's question Q (tier 0,
# lib-afd-ask.sh), to its ask-back C, or naming #C / #M (the verdict scan, lib-afd-scan.sh). Any
# other Reply to that project goes to its queue even mid-ask-back: pooled, it would reach whichever
# consumer drains the pool once the relay exits (review MAJOR 1).
_afd_reply_origin() {
    local meta origin rt refs m q claimed mm c
    meta=$(_afd_reply_meta "$1"); [[ -n "$meta" ]] || return 0
    read -r origin rt refs <<< "$meta"
    m="$(_afd_msg_dir)/.waiting/$origin"
    if [[ -f "$m" ]] && _afd_marker_live "$m"; then
        read -r _ q claimed mm c < "$m" || true   # "<pid> Q" or "<pid> Q claimed M C"
        [[ "$rt" == "$q" ]] && return 0
        if [[ "$claimed" == claimed && -n "$c" ]]; then
            [[ "$rt" == "$c" || " $refs " == *" #$c "* || " $refs " == *" #$mm "* ]] && return 0
        fi
    fi
    echo "$origin"
}

# _afd_refile_replies <me> — filter for a pool drain (afd_take_messages): a line that is a Reply to
# ANOTHER project's message is re-filed into that project's queue, pool bookkeeping (pooled, rejected)
# dropped, instead of reaching the consumer; every other line passes through. A relay that exits
# (answered, timed out, killed) leaves such lines behind — a tier-0 Reply it never claimed, a Reply to
# its ask-back the verdict scan left alone — and the next consumer must not take them (review MAJOR 1).
# A line is never dropped: if the bookkeeping cannot be stripped it is re-filed as it is.
_afd_refile_replies() {
    local me="$1" line meta origin stripped
    while IFS= read -r line; do
        meta=$(_afd_reply_meta "$line"); origin="${meta%% *}"
        if [[ -n "$origin" && "$origin" != "$me" ]]; then
            stripped=$(printf '%s' "$line" | python3 -c '
import json, sys
d = json.load(sys.stdin); d.pop("pooled", None); d.pop("rejected", None); print(json.dumps(d))' 2>/dev/null)
            _afd_locked _afd_append_line "$(_afd_msg_dir)/$origin.jsonl" "${stripped:-$line}"
        else
            printf '%s\n' "$line"
        fi
    done
}
