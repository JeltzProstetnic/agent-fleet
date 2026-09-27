#!/usr/bin/env bash
# lib-commit-scan.sh — which commits does this Bash command make, in which repo, and does
# each one also record working-tree content? Answered without running it (CFG-668).
# Sourced by secret-commit-guard.sh.
# Contract: `_commit_scan_jobs "$command"` APPENDS flattened records to the caller's JOBS
# array — `J <dir> <n> <git-global-args…> <tree 0|1> <n> <paths…>` — and returns 0, or
# returns 1 when python3 is unusable (the caller then falls back to its own walk).
# tree=1: the commit also records the working tree, for <paths> or, when there are none,
# for every tracked path. The index is not described: the caller always reads it.
# The parse is linear. A bash character loop before it was quadratic (~24 s at 100 KB).
# Parsed: quotes, $(…) and backticks, heredoc bodies (stdin text, never words),
# redirections and their targets (never pathspecs), comments, backslash-newline, `cd` /
# `pushd` with subshell scope, env prefixes, git's global options, commit's short
# clusters and abbreviated long options, --pathspec-from-file. Text only the running shell
# knows ($VAR, $(…), {a,b}) is marked unknown; an unknown pathspec means "any tracked path".

[[ "${_LIB_COMMIT_SCAN_LOADED:-}" == "true" ]] && return 0
_LIB_COMMIT_SCAN_LOADED="true"

read -r -d '' _COMMIT_SCAN_PY <<'PY' || true
import os, re, sys
HOME, DYN = os.environ.get("HOME", ""), "\x01"   # DYN marks text known only at run time
NAME, FD = re.compile(r"[A-Za-z_]\w*"), re.compile(r"\d+(?=[<>])")
ASSIGN = re.compile(r"[A-Za-z_]\w*(\[[^]]*\])?\+?=")
BRACE = re.compile(r"\{[^{}]*(,|\.\.)[^{}]*\}")
PREFIX = {"!", "{", "if", "then", "else", "elif", "do", "while", "until"}
WRAPPERS = {"time", "command", "exec", "env", "nohup", "nice"}
END = set(" \t\n;&|<>()")
LONG = ("all include only interactive patch message file author date reedit-message "
        "reuse-message fixup squash reset-author trailer signoff template edit cleanup status "
        "gpg-sign quiet verbose untracked-files dry-run short branch ahead-behind porcelain long "
        "null amend no-post-rewrite no-verify verify allow-empty allow-empty-message "
        "pathspec-from-file pathspec-file-nul").split()
VALUE = set("message file author date reedit-message reuse-message fixup squash trailer "
            "template cleanup pathspec-from-file".split())


def long_opt(name):  # git takes a unique prefix of a long option: --mess is --message
    hits = [o for o in LONG if o.startswith(name)] if name else []
    return name if name in LONG else (hits[0] if len(hits) == 1 else None)


class Lexer:
    def __init__(self, text):
        self.s, self.n, self.i, self.pending, self.jobs = text, len(text), 0, [], []

    def at(self, k=0):
        return self.s[self.i + k] if self.i + k < self.n else ""

    def blank(self):
        while self.at() in (" ", "\t"): self.i += 1

    def bodies(self):  # after a newline: consume every queued heredoc body
        for tag, strip in self.pending:
            while self.i < self.n:
                j = self.s.find("\n", self.i); j = self.n if j < 0 else j
                line, self.i = self.s[self.i:j], j + 1
                if (line.lstrip("\t") if strip else line) == tag: break
        self.pending = []

    def skip_until(self, close, opener=None, depth=1):
        while self.i < self.n and depth:
            c = self.s[self.i]
            self.i += 2 if c == "\\" else 1
            depth += (c == opener) - (c == close)

    def dollar(self, state, buf):
        nx, self.i = self.at(1), self.i + 2
        if nx == "(":
            if self.at() == "(": self.i += 1; self.skip_until(")", "(", 2)   # $(( arithmetic ))
            else: self.parse(dict(state), True)        # $( command ): its own subshell
            buf.append(DYN)
        elif nx == "{":
            start = self.i; self.skip_until("}", "{")
            buf.append(HOME if self.s[start:self.i - 1] == "HOME" and HOME else DYN)
        else:
            self.i -= 1
            m = NAME.match(self.s, self.i)
            if m: self.i = m.end(); buf.append(HOME if m.group() == "HOME" and HOME else DYN)
            elif nx and nx in "@*#?$!-0123456789": self.i += 1; buf.append(DYN)
            else: buf.append("$")

    def word(self, state):
        buf, start, brace, dq = [], self.i, False, False
        while self.i < self.n:
            c = self.s[self.i]
            if dq:
                if c == '"': dq, self.i = False, self.i + 1
                elif c == "\\":
                    nx, self.i = self.at(1), self.i + 2
                    if nx != "\n": buf.append(nx if nx in '"\\$`' else c + nx)
                elif c == "$": self.dollar(state, buf)
                elif c == "`": self.i += 1; self.skip_until("`"); buf.append(DYN)
                else: buf.append(c); self.i += 1
            elif c in END:
                break
            elif c == "\\":
                nx, self.i = self.at(1), self.i + 2
                if nx != "\n": buf.append(nx)          # backslash-newline joins lines
            elif c == "'":
                j = self.s.find("'", self.i + 1); j = self.n if j < 0 else j
                buf.append(self.s[self.i + 1:j]); self.i = j + 1
            elif c == '"':
                dq, self.i = True, self.i + 1
            elif c == "$" and self.at(1) == "'":      # $'ANSI-C'
                j = self.i + 2
                while j < self.n and self.s[j] != "'": j += 2 if self.s[j] == "\\" else 1
                buf.append(self.s[self.i + 2:j]); self.i = j + 1
            elif c == "$" and self.at(1) == '"':      # $"locale" is a plain "…"
                self.i += 1
            elif c == "$":
                self.dollar(state, buf)
            elif c == "`":
                self.i += 1; self.skip_until("`"); buf.append(DYN)
            elif c == "~" and self.i == start and HOME and (self.at(1) in ("", "/") or self.at(1) in END):
                buf.append(HOME); self.i += 1
            else:
                brace = brace or c == "{"; buf.append(c); self.i += 1
        w = "".join(buf)
        return w + DYN if brace and BRACE.search(w) else w

    def redirect(self, state):  # operator and target are dropped; `<<TAG` queues a body
        s, i = self.s, self.i
        if s.startswith("<<<", i):
            self.i += 3
        elif s.startswith("<<", i):
            strip = s[i + 2:i + 3] == "-"
            self.i += 2 + strip; self.blank()
            tag = self.word(state)
            if tag: self.pending.append((tag, strip))
            return
        else:
            two = (s[i] == "<" and self.at(1) in ("&", ">")) or (s[i] == ">" and self.at(1) in (">", "&", "|"))
            self.i += 1 + two
        self.blank()
        if self.i < self.n and self.s[self.i] not in "\n;&|()<>":
            self.word(state)

    def parse(self, state, nested):
        words = []
        while self.i < self.n:
            c = self.s[self.i]
            if c in " \t":
                self.i += 1
            elif c == "\\" and self.at(1) == "\n":
                self.i += 2
            elif c == "#":                             # comment to end of line
                j = self.s.find("\n", self.i); self.i = self.n if j < 0 else j
            elif c.isdigit() and FD.match(self.s, self.i):   # 2>&1, 2>/dev/null
                self.i = FD.match(self.s, self.i).end(); self.redirect(state)
            elif c in "<>" and self.at(1) == "(":     # <(…) >(…) process substitution
                self.i += 2; self.parse(dict(state), True); words.append(DYN)
            elif c in "<>" or (c == "&" and self.at(1) == ">"):
                self.i += c == "&"; self.redirect(state)   # &> and &>> redirect like > and >>
            elif c not in END:
                words.append(self.word(state))
            else:                                      # newline ; & | && || ( )
                self.clause(words, state); words = []; self.i += 1
                if c == "\n" and self.pending: self.bodies()
                elif c == ")" and nested: return
                elif c == "(": self.parse(dict(state), True)   # subshell: a cd inside stays inside
                elif c in ";&|":
                    while self.at() in (";", "&", "|"): self.i += 1
        self.clause(words, state)

    def clause(self, words, state):
        k, wrap = 0, False
        while k < len(words) and (ASSIGN.match(words[k]) or words[k] in PREFIX or words[k] in WRAPPERS
                                  or (wrap and words[k][:1] == "-" and DYN not in words[k])):
            wrap = wrap or words[k] in WRAPPERS; k += 1
        w = words[k:]
        if not w or DYN in w[0]: return
        if w[0] in ("cd", "pushd", "popd"): self.chdir(w[0], w[1:], state)
        elif os.path.basename(w[0]) == "git": self.git(w[1:], state)

    def chdir(self, verb, args, state):
        while args and args[0][:1] == "-" and args[0] != "-":
            done, args = args[0] == "--", args[1:]
            if done: break
        t = args[0] if args else (HOME if verb == "cd" else "")
        if verb == "popd" or not t or DYN in t or t[:1] in "-+":
            state["cwd"] = None
        elif state["cwd"] is not None or os.path.isabs(t):
            p = os.path.normpath(os.path.join(state["cwd"] or "/", t))
            state["cwd"] = p if os.path.isdir(p) else None

    def git(self, args, state):
        g, k = [], 0
        while k < len(args) and args[k][:1] == "-":
            t = args[k]
            if DYN in t or (t in ("-C", "--git-dir", "--work-tree") and (k + 1 >= len(args) or DYN in args[k + 1])):
                return                                 # target unknowable; base could not scan it either
            if t in ("-C", "--git-dir", "--work-tree"): g += args[k:k + 2]; k += 2
            elif t in ("-c", "--namespace", "--config-env"): k += 2
            else:
                if t.startswith(("--git-dir=", "--work-tree=")): g.append(t)
                k += 1
        if k < len(args) and args[k] == "commit": self.commit(args[k + 1:], state, g)

    def commit(self, args, state, g):
        all_ = unknown = nul = dd = False
        paths, psff, k = [], None, 0
        while k < len(args):
            t = args[k]; k += 1
            if dd or t[:1] != "-" or t == "-":
                if DYN in t: unknown = True            # a pathspec (or flag) known only at run time
                else: paths.append(t)
            elif t == "--":
                dd = True
            elif t[:2] == "--":
                name, eq, val = t[2:].partition("=")
                opt = long_opt(name)
                all_ |= opt == "all"; nul |= opt == "pathspec-file-nul"
                if opt in VALUE and not eq: val = args[k] if k < len(args) else ""; k += 1
                if opt == "pathspec-from-file": psff = val
            else:                                      # short cluster: -am, -qam, -mMSG …
                for p, ch in enumerate(t[1:], 1):
                    if ch == "a": all_ = True
                    elif ch == DYN: unknown = True; break
                    elif ch in "mFCct": k += p == len(t) - 1; break   # value attached, else the next word
                    elif ch in "Su": break             # optional value, attached only
        where = state["cwd"]
        if psff is not None:
            listed = self.pathspec_file(psff, where, g, nul)
            unknown |= listed is None; paths += listed or []
        if where is None:                              # a cd we could not follow: read what base read
            self.jobs.append((os.getcwd(), g, False, []))
        else:
            self.jobs.append((where, g, all_ or unknown or bool(paths), [] if all_ or unknown else paths))

    def pathspec_file(self, name, where, g, nul):
        if DYN in name or name == "-" or where is None: return None
        for a, b in zip(g, g[1:]):
            if a == "-C": where = os.path.join(where, b)
        try:
            with open(os.path.join(where, name), encoding="utf-8", errors="replace") as fh:
                raw = fh.read()
        except OSError:
            return None
        return [x for x in (raw.split("\0") if nul else raw.splitlines()) if x]


lx = Lexer(sys.stdin.buffer.read().decode("utf-8", "surrogateescape"))
lx.parse({"cwd": os.getcwd()}, False)
out = []
for where, g, tree, paths in lx.jobs:
    out += ["J", where, str(len(g))] + g + [str(int(tree)), str(len(paths))] + paths
sys.stdout.buffer.write(("\0".join(out + ["E"]) + "\0").encode("utf-8", "surrogateescape"))
PY

_commit_scan_jobs() {  # _commit_scan_jobs COMMAND — appends to JOBS; 1 = python3 unusable
    local f fields=()
    command -v python3 &>/dev/null || return 1
    while IFS= read -r -d '' f; do fields+=("$f"); done \
        < <(printf '%s' "$1" | python3 -c "$_COMMIT_SCAN_PY" 2>/dev/null)
    [ ${#fields[@]} -gt 0 ] && [ "${fields[${#fields[@]}-1]}" = "E" ] || return 1
    JOBS+=("${fields[@]:0:${#fields[@]}-1}")
    return 0
}
