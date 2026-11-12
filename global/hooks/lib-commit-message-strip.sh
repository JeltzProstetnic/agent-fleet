#!/usr/bin/env bash
# lib-commit-message-strip.sh — a Bash command with its git COMMIT MESSAGES removed, so a
# read guard's verb match sees only what executes (CFG-621; split out of vault-read-guard.sh
# in CFG-960). Sourced by vault-read-guard.sh.
#
# Why: the blocked-verb list contains the English words `more` and `less`, and the match
# used to run over the whole command string with no positional relation to the path — so a
# commit whose MESSAGE read "describe secrets/vault.json more usefully" was blocked although
# it read nothing. A guard that false-blocks trains the bypass (CFG-513). The verbs are not
# the defect (`more secrets/…` must stay blocked); the matching scope is. So the verb checks
# run on the command with commit-message bodies removed; the path check stays on the full
# string.
#
# Only a GIT COMMIT's message counts as prose, and only in two shapes: the value of
# `-m`/`--message` on a `git … commit` clause (a `$(cat <<EOF … EOF)` there included), and a
# heredoc read by `git commit` itself (`-F - <<EOF`). The first CFG-621 fix treated every
# `$(cat <<EOF)` as prose because its own command is `cat`, but what consumes the
# substitution decides: `bash -c "$(cat <<…)"`, `eval`, `perl -e`, `x=$(…)` and `… | sh`
# run the body. The -m match is also tied to a git commit clause, so `unshare -m cat …` and
# a " -m \"" inside some other string hide nothing. Kept even inside a message, because
# they execute:
#   - a $(...) or `...` in an -m body — `-m "$(cat secrets/vault.json)"` puts the plaintext
#     into the commit message;
#   - body lines of an unquoted-tag heredoc that hold $(...) or `...`.
#
# Contract: strip_commit_messages CMD → prints the stripped command, returns 0. Returns
# non-zero and prints nothing usable when python3 is missing or fails, so a caller written as
#   _s=$(strip_commit_messages "$CMD") && SCAN="$_s"
# keeps the RAW command: nothing stripped degrades toward a false block, never a read.

[[ "${_LIB_COMMIT_MESSAGE_STRIP_LOADED:-}" == "true" ]] && return 0
_LIB_COMMIT_MESSAGE_STRIP_LOADED="true"

# The program, read once at source time (a quoted tag: nothing expands, every backslash stays).
IFS= read -r -d '' _CMS_PROGRAM <<'PY' || true
import re, sys
s = sys.stdin.read()

HEREDOC = re.compile(r"<<(-?)\s*([\x27\"]?)(\w+)\2")
# A `git … commit` clause: env prefixes, then git global options, then commit.
COMMIT = re.compile(r"[\s({]*(?:[A-Za-z_]\w*=\S*\s+)*git(?:\s+(?:-[Cc]\s+\S+|--?[\w-]+(?:=\S+)?))*\s+commit\b")
MSGOPT = re.compile(r"(?:^|\s)(?:-[A-Za-z]*m|--message=?)\s*$")

def frames(t):
    # Nesting at the end of t, one [kind, clause_start, open_pos] per level with
    # kind cmd|dq|sub; heredoc bodies are skipped. None: t ends inside single quotes.
    st = [["cmd", 0, 0]]; pend = []; i = 0; n = len(t)
    while i < n:
        c = t[i]; top = st[-1]
        if c == "\\":
            i += 2; continue
        if c == "`":
            e = t.find("`", i + 1); i = n if e < 0 else e + 1; continue
        if top[0] == "dq":
            if c == "\"": st.pop()
            elif t.startswith("$(", i): st.append(["sub", i + 2, i]); i += 1
            i += 1; continue
        if c == "\x27":
            e = t.find("\x27", i + 1)
            if e < 0: return None
            i = e + 1; continue
        if t.startswith("<<<", i):
            i += 3; continue
        m = HEREDOC.match(t, i)
        if m:
            pend.append((m.group(3), m.group(1) == "-")); i = m.end(); continue
        if c == "\"": st.append(["dq", i + 1, i])
        elif t.startswith("$(", i): st.append(["sub", i + 2, i]); i += 1
        elif c == ")" and top[0] == "sub": st.pop()
        elif c == "#" and (i == 0 or t[i - 1] in " \t\n;&|("):
            e = t.find("\n", i); i = n if e < 0 else e; continue
        elif c in ";&|()\n":
            top[1] = i + 1
            if c == "\n" and pend:
                i += 1
                for tag, strip in pend:
                    while i < n:
                        e = t.find("\n", i); e = n if e < 0 else e
                        line = t[i:e]; i = e + 1
                        if (line.lstrip("\t") if strip else line) == tag: break
                pend = []; top[1] = min(i, n); continue
        i += 1
    return st

def prose(before):
    # Is the heredoc that starts at the end of `before` a commit message?
    #   "commit": git commit itself reads it (git commit -F - <<EOF);
    #   "cat":    $(cat <<EOF) is the -m/--message value of a git commit.
    # Anything else consumes the output some other way (bash -c, eval, perl -e,
    # x=…, | sh), so its body stays visible to the verb match.
    st = frames(before)
    if not st or st[-1][0] == "dq": return None
    top = st[-1]; own = before[top[1]:]
    if COMMIT.match(own) and not re.search(r"[$`|;&<>]", own): return "commit"
    if top[0] != "sub" or not re.fullmatch(r"\s*cat(?:\s+-)?\s*", own): return None
    outer, end = (st[-3], st[-2][2]) if st[-2][0] == "dq" else (st[-2], top[2])
    if outer[0] == "dq": return None
    lead = before[outer[1]:end]
    return "cat" if COMMIT.match(lead) and MSGOPT.search(lead) else None

def strip_heredocs(s):
    lines = s.split("\n"); out = []; i = 0
    while i < len(lines):
        line = lines[i]
        m = HEREDOC.search(line)
        if m:
            pre = line[:m.start()]
            kind = prose("\n".join(out + [pre]))
            # Prose only if nothing but `)`, `"` or end-of-line follows the tag:
            # a redirect or pipe after it sends the body somewhere.
            if kind and re.match(r"\s*(?:\)|\"|$)", line[m.end():]):
                dash, quoted, tag = m.group(1), bool(m.group(2)), m.group(3)
                j = i + 1
                while j < len(lines) and (lines[j].lstrip("\t") if dash else lines[j]) != tag:
                    j += 1
                if j < len(lines):
                    if kind == "cat":
                        pre = re.sub(r"cat(?:\s+-)?\s*$", "", pre)   # cat only echoes the prose
                    out.append(pre + line[m.start():])
                    for b in lines[i + 1:j]:
                        if not quoted and ("$(" in b or "`" in b):   # unquoted tag expands
                            out.append(b)
                    out.append(lines[j])
                    i = j + 1
                    continue
        out.append(line)
        i += 1
    return "\n".join(out)

OPT = re.compile(r"(?:(?<=\s)|^)(?:--message(?:=|\s+)|-(?!-)[a-ln-zA-Z]*m(?:\s+|(?=\S)))")

def strip_messages(s):
    res = []; i = 0; n = len(s)
    while True:
        m = OPT.search(s, i)
        if not m:
            res.append(s[i:]); break
        res.append(s[i:m.end()])
        st = frames(s[:m.start()])     # an option of git commit, not text in a string
        if not st or st[-1][0] == "dq" or not COMMIT.match(s[st[-1][1]:m.start()]):
            i = m.end(); continue
        j = m.end()
        if j >= n:
            break
        c = s[j]
        if c == "\"":
            k = j + 1; depth = 0; keep = []; buf = None
            while k < n:
                ch = s[k]
                if depth > 0:
                    buf += ch
                    if ch == "\\":
                        buf += s[k + 1:k + 2]; k += 2; continue
                    if s.startswith("$(", k):
                        buf += "("; depth += 1; k += 2; continue
                    if ch == ")":
                        depth -= 1
                        if depth == 0:
                            keep.append(buf); buf = None
                    k += 1; continue
                if ch == "\\":
                    k += 2; continue
                if s.startswith("$(", k):
                    buf = "$("; depth = 1; k += 2; continue
                if ch == "`":
                    e = s.find("`", k + 1)
                    e = n - 1 if e < 0 else e
                    keep.append(s[k:e + 1]); k = e + 1; continue
                if ch == "\"":
                    break
                k += 1
            if buf is not None:
                keep.append(buf)
            res.append("\"" + " ".join(keep) + "\"")
            i = k + 1
        elif c == "\x27":
            e = s.find("\x27", j + 1)
            e = n - 1 if e < 0 else e
            res.append("\x27\x27"); i = e + 1
        else:
            e = j
            while e < n and not s[e].isspace():
                e += 1
            word = s[j:e]
            res.append(word if ("$(" in word or "`" in word) else "\"\"")
            i = e
    return "".join(res)

sys.stdout.write(strip_messages(strip_heredocs(s)))
PY

strip_commit_messages() {
    command -v python3 >/dev/null 2>&1 || return 1
    printf '%s' "$1" | python3 -c "$_CMS_PROGRAM" 2>/dev/null
}
