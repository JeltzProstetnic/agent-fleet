#!/usr/bin/env bash
# lib-rule-removal.sh — the detector behind rule-removal-guard.sh (CFG-897): which rule
# sentences does a commit drop, and does its message explain each one? Sourced by the hook;
# `python3 -c "$_RULE_REMOVAL_PY" <mode> …`: --jobs <file> (records from lib-commit-scan.sh
# --with-messages, PreToolUse), --check-staged <repo> (index vs HEAD, no message; config-auto-sync),
# --replay <commit> [<repo>] (a recorded commit vs its parent, with its own message). Exit 0 = nothing
# unexplained; 1 = unexplained removals (report on stdout; --check-staged prints the offending
# paths on stdout and the report on stderr); anything else = crashed.
# Rule file: any CLAUDE.md, or *.md DIRECTLY under foundation/, reference/ or knowledge/ below
# global/ or .claude/. Unit: a sentence of a bullet or paragraph (hard-wrapped lines joined),
# or a whole table row; headings, blank lines, fenced code, HTML comments, separator and header
# rows are skipped; ~~struck~~ text is dropped first (striking a sentence removes it). A unit under
# MIN_CHARS normalised or MIN_WORDS words is a fragment, not a rule — measured 2026-11-04 over the
# 87 global rule files: 587 of 7,188 units (8.2 %), all pointers ("See `knowledge/x.md`."), bold
# labels split off their body, or codas of a guarded sentence ("No file in both.") — unless it
# carries a polarity word ("Never use `sed -i`." counts). Normalisation: lower-case, `*`/backticks
# dropped, whitespace collapsed, end punctuation stripped. A unit is PRESENT when some new unit (a)
# contains it ("X." → "X, but Y." passes) or, among the CHANGED new units, (b) is ≥ SIM similar
# (difflib, autojunk OFF — on, a 200+ char sentence scores ~0.19; a one-word swap in 100 chars
# ≥ 0.95, a replaced 20-char clause ≤ 0.85), or (c) keeps every old word and is ≤ 3× as long
# ("done or user asks" → "done, the user asks, or before …", 9dfbbb4b, ratio 0.76), or (d) its
# words are exactly k consecutive changed units joined ("begins; revert" → "begins. Revert").
# None of (a)-(d) counts when a POLAR word — NEG (not, never, unless, only, obsolete, …) or FORCE
# (must, should, may, always, usually, possible, permits, …) — is gained or lost: "Keep X" →
# "Do not keep X" scores 0.93 and "must" → "should" 0.98. A rule file renamed out of rule scope
# is a deletion of every unit. Trailer text = prefix of the unit, ≥ PREFIX chars (or the whole
# unit); merged-into = a heading or **bold label** (≥ TITLE_MIN chars) of a staged rule file of
# the commit; retired-by takes any approver token and a date not in the future.

[[ "${_LIB_RULE_REMOVAL_LOADED:-}" == "true" ]] && return 0
_LIB_RULE_REMOVAL_LOADED="true"

read -r -d '' _RULE_REMOVAL_PY <<'PY' || true
import collections, datetime, difflib, os, re, subprocess, sys
DYN, CAP = "\x01", "\x02"
MIN_CHARS, MIN_WORDS, SIM, PREFIX, SHOW, TITLE_MIN = 20, 4, 0.90, 30, 160, 8
NEG = set("not never no none nor neither unless except without instead only don't doesn't won't cannot "
          "can't mustn't isn't aren't shouldn't obsolete deprecated retired superseded formerly".split())
FORCE = set("must should may always usually sometimes prefer optional ideally possible permits".split())
POLAR = NEG | FORCE   # gaining or losing one of these inverts, weakens or restricts the rule
WORD = re.compile(r"[a-z0-9][a-z0-9'._/-]*")
STRIKE = re.compile(r"~~[^~\n]+~~")
RULE = re.compile(r"(^|/)(global|\.claude)/(foundation|reference|knowledge)/[^/]+\.md$")
TRAILER = re.compile(r'^\s*Rule-removed:\s*"(.+?)"\s+(?:moved-to\s+(\S+)|merged-into\s+"(.+?)"'
                     r'|retired-by\s+(\S+)\s+(\d{4}-\d{2}-\d{2}))\s*$', re.M | re.I)
TITLE = re.compile(r"^\s*#{1,6}\s+(.+?)\s*#*\s*$|\*\*([^*\n]{3,}?)\*\*", re.M)
BULLET = re.compile(r"\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX>?]\]\s+)?(.*)")
SEP_ROW = re.compile(r"\|[\s:|\-]+\|")
ABBR = re.compile(r"\b(e\.g|i\.e|vs|cf|incl|approx|etc)\.$", re.I)
SPLIT = re.compile(r'[.!?]["\')\]*`]*\s+(?=`|["(\[*]*[A-Z0-9])')


def is_rule(path):
    return os.path.basename(path) == "CLAUDE.md" or bool(RULE.search(path))


def norm(s, end=True):
    s = s.lower().replace("\u2019", "'").replace("\u201c", '"').replace("\u201d", '"')
    s = re.sub(r"\s+", " ", re.sub(r"[*`]", "", s)).strip()
    return s.strip(" \"'.!?:;,)([]").strip() if end else s


def sentences(text):
    out, start = [], 0
    for m in SPLIT.finditer(text):
        if ABBR.search(text[start:m.start() + 1]): continue
        out.append(text[start:m.end()].strip()); start = m.end()
    out.append(text[start:].strip())
    return [s for s in out if s]


def units(text):
    out, block, fence, lines, i = [], [], False, text.split("\n"), 0
    def flush():  # ~~struck~~ text is gone text: it must count as removed
        if block: out.extend(sentences(STRIKE.sub("", " ".join(block)))); block.clear()
    while i < len(lines):
        raw = lines[i]; s = raw.strip(); i += 1
        if s.startswith(("```", "~~~")): flush(); fence = not fence; continue
        if fence: continue
        if s.startswith("<!--"):
            flush()
            while "-->" not in s and i < len(lines): s = lines[i].strip(); i += 1
            continue
        if not s or re.match(r"#{1,6}\s", s): flush(); continue
        if s.startswith("|") and s.endswith("|"):
            flush()
            nxt = next((l.strip() for l in lines[i:] if l.strip()), "")
            if not SEP_ROW.fullmatch(s) and not SEP_ROW.fullmatch(nxt): out.append(STRIKE.sub("", s))
            continue
        m = BULLET.match(raw)
        if m: flush(); block.append(m.group(1))
        else: block.append(s)
    flush()
    def rule_like(u):  # long enough, or short but carrying a polarity word ("Never use `sed -i`.")
        n = norm(u); w = WORD.findall(n)
        return (len(n) >= MIN_CHARS and len(n.split()) >= MIN_WORDS) or (len(w) >= 2 and bool(set(w) & POLAR))
    return [u for u in out if rule_like(u)]


def similar(a, b):
    if abs(len(a) - len(b)) > 0.25 * max(len(a), len(b)): return False
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)   # autojunk scores a 200+ char sentence ~0.19
    return sm.quick_ratio() >= SIM and sm.ratio() >= SIM


def kept(n, v, loose):  # old unit n lives on as new unit v? loose: v is a changed unit, so a typo-level
    a, b = collections.Counter(WORD.findall(n)), collections.Counter(WORD.findall(v))   # or extended match
    if set(((a - b) + (b - a)).elements()) & POLAR: return False   # counts — never when a negation or
    return n in v or (loose and (similar(n, v) or (len(v) <= 3 * len(n) and not (a - b))))  # force word changes


def split_across(n, parts):  # n's words are EXACTLY k consecutive changed units joined ("A; b." → "A. B.")
    w = WORD.findall(n)
    for i in range(len(parts)):
        acc = []
        for p in parts[i:]:
            acc = acc + p
            if acc == w: return bool(w)
            if len(acc) >= len(w): break
    return False


def present(n, new_units, cand, parts=()):  # normalised unit n; all new units; the changed ones (+ their words)
    return any(kept(n, v, v in cand) for v in new_units) or split_across(n, parts)


def removed(old, new):
    oldu, newl = units(old), [norm(u) for u in units(new)]
    newu, cand = set(newl), set(newl) - {norm(u) for u in oldu}
    parts = [WORD.findall(v) for v in newl if v in cand]   # changed new units in document order
    return [u for u in oldu if norm(u) not in newu and not present(norm(u), newu, cand, parts)]


class Job:
    def __init__(self, where, g, tree, paths, x):
        self.where, self.g, self.tree, self.paths, self.x = where, g, tree, paths, x

    def git(self, *a):
        r = subprocess.run(["git", "-C", self.where, *self.g, *a], capture_output=True)
        return r.returncode, r.stdout.decode("utf-8", "replace")

    def cdir(self):
        d = self.where
        for a, b in zip(self.g, self.g[1:]):
            if a == "-C": d = os.path.join(d, b)
        return d

    def changes(self, base, rev=None):  # {new_path: (old_path, src)} for rule files
        out = {}
        def take(args, src):
            rc, raw = self.git("diff", "--name-status", "-M", "-z", *args)
            f = raw.split("\0"); i = 0
            while i < len(f) and f[i]:
                st = f[i]; i += 1
                old, new = (f[i], f[i + 1]) if st[0] in "RC" else (f[i], f[i]); i += 2 if st[0] in "RC" else 1
                if st[0] not in "MDRT" or not is_rule(old): continue
                if st[0] in "RC" and not is_rule(new): out[old] = (old, "gone")   # moved out of rule scope = deleted
                else: out[new] = (old, src)
        if rev: take([base, rev], "rev:" + rev)
        elif self.x["only"]: take([base, "--"] + self.paths, "tree")
        else:
            take(["--cached", base], "index")
            if self.tree: take([base, "--"] + self.paths, "tree")
        for kind, ps in self.x.get("muts", []):        # `git rm`/`mv` in the same call: not applied yet, so modelled
            for f in [f for f in self.git("ls-files", "-z", "--full-name", "--", *ps[:1])[1].split("\0") if f and is_rule(f)] if ps else []:
                if kind == "rm" or len(ps) < 2 or not is_rule(self.dest(f, ps[0], ps[1])): out[f] = (f, "gone")
        return out

    def dest(self, f, src, dst):  # where `git mv src dst` puts the repo-relative file f (dst may be a directory)
        c = self.cdir(); a = os.path.relpath(os.path.normpath(os.path.join(c, src)), self.root); d = os.path.normpath(os.path.join(c, dst))
        if f != a: d = os.path.join(d, os.path.relpath(f, a))
        elif os.path.isdir(d): d = os.path.join(d, os.path.basename(f))
        return os.path.relpath(d, self.root)

    def content(self, path, src):
        if src == "gone": return ""
        if src == "tree":
            try: return open(os.path.join(self.root, path), encoding="utf-8", errors="replace").read()
            except OSError: return ""
        return self.git("show", (":" if src == "index" else src[4:] + ":") + path)[1]

    def message(self):  # (text, readable?)
        x, parts, ok = self.x, [], not self.x["munk"]
        if x["amend"] and ok and not x["msgs"] and not x["files"]:   # --amend [--no-edit]: HEAD's message stays
            parts.append(self.git("log", "-1", "--format=%B", "HEAD")[1])
        for m in x["msgs"]:
            if m.startswith(DYN + CAP): parts.append(m[2:])
            elif DYN in m: ok = False
            else: parts.append(m)
        for f in x["files"]:
            if f == "-": parts.append(x["stdin"] or ""); ok &= x["stdin"] is not None; continue
            try: parts.append(open(os.path.join(self.cdir(), f), encoding="utf-8", errors="replace").read())
            except OSError: ok = False
        return "\n".join(parts), ok

    def run(self, msg=None, rev=None):  # → (findings, held paths, readable) or None to pass through
        rc, root = self.git("rev-parse", "--show-toplevel"); self.root = root.strip()
        if rc or not self.root: return None
        gd = self.git("rev-parse", "--absolute-git-dir")[1].strip()
        if any(os.path.exists(os.path.join(gd, p)) for p in ("MERGE_HEAD", "rebase-merge", "rebase-apply")): return None
        base = (rev + "^") if rev else ("HEAD^" if self.x["amend"] else "HEAD")
        if self.git("rev-parse", "-q", "--verify", base + "^{commit}")[0]: return None
        ch = self.changes(base, rev)
        if not ch: return [], [], True
        text, ok = (msg, True) if msg is not None else self.message()
        new = {p: self.content(p, src) for p, (old, src) in ch.items()}
        lost = {p: removed(self.content(old, "rev:" + base), new[p]) for p, (old, src) in ch.items()}
        trailers = [(norm(m.group(1)), m.group(0).strip(), m.group(2), m.group(3), m.group(5)) for m in TRAILER.finditer(text)]
        findings, held = [], []
        for p, us in lost.items():
            for u in us:
                n, fails, done = norm(u), [], False
                for tn, raw, mv, mg, dt in trailers:
                    if not n.startswith(tn) or len(tn) < min(PREFIX, len(n)): continue
                    err = self.verify(n, mv, mg, dt, p, new, ch)
                    if err: fails.append("trailer '%s' failed: %s" % (raw[:SHOW], err))
                    else: done = True
                if not done: findings.append((p, u, fails)); held += [p, ch[p][0]] if p not in held else []
        return findings, sorted(set(held)), ok

    def verify(self, n, mv, mg, dt, path, new, ch):
        if dt:
            try: d = datetime.date.fromisoformat(dt)
            except ValueError: return "%s is not a valid date" % dt
            return "" if d <= datetime.date.today() else "%s lies in the future" % dt
        if mg:  # a heading or **bold label** of a staged rule file in this commit, not any substring
            m, titles = norm(mg), {norm(a or b) for t in new.values() for a, b in TITLE.findall(t)}
            if len(m) < TITLE_MIN: return 'title "%s" is shorter than %d chars' % (mg, TITLE_MIN)
            return "" if any(t == m or t.startswith(m) for t in titles) else 'title "%s" is no heading or **bold label** in a staged rule file' % mg
        t = mv if os.path.isabs(mv) else re.sub(r"^(~|\$HOME)/\.claude/", "global/", mv).lstrip("./")
        if os.path.isabs(t): t = os.path.relpath(t, self.root)
        # The staged target: what this commit records for it; the tree as well when the commit
        # records tree content (a `git add <target>` in the same call has not happened yet).
        texts = [new[t]] if t in new else [self.content(t, "index")] + ([self.content(t, "tree")] if self.tree else [])
        for text in texts:
            tu = {norm(v) for v in units(text)}
            if text and present(n, tu, tu): return ""
        return "text not found in staged %s" % t


def report(findings, readable, out):
    n = len(findings)
    out.write("BLOCKED (CFG-897): %d rule sentence(s)/row(s) removed from rule files without a verified Rule-removed trailer.\n" % n)
    if not readable: out.write("  (the commit message cannot be read by the guard: a $VAR message, -F - without a visible heredoc, -c/-C/--fixup — write it as -m '…')\n")
    last = None
    for p, u, fails in findings:
        if p != last: out.write("\n  %s:\n" % p); last = p
        out.write("    - \"%s\"\n" % (u if len(u) <= SHOW else u[:SHOW] + "…"))
        for f in fails: out.write("        %s\n" % f)
    out.write("\nEvery removed sentence needs ONE verified trailer, as its own -m, in exactly one of these forms:\n"
              '  Rule-removed: "<the sentence, or its first %d+ chars>" moved-to <repo-relative path>   (text must be in the STAGED target)\n'
              '  Rule-removed: "<…>" merged-into "<title>"                                   (a heading or **bold label** of a staged rule file)\n'
              '  Rule-removed: "<…>" retired-by <who> YYYY-MM-DD                             (only when the owner retired it, in their words)\n'
              "Ready to paste once the decision exists (fill who and the date; prefer moved-to/merged-into when the rule lives on):\n" % PREFIX)
    for p, u, fails in findings[:12]:
        pre = re.sub(r"[*`]", "", u)[:PREFIX + 30]; cut = pre.rfind(" ", PREFIX)
        pre = (pre[:cut] if cut > 0 else pre).replace("'", "'\"'\"'")
        out.write("  -m 'Rule-removed: \"%s\" retired-by <who> YYYY-MM-DD'\n" % pre)
    out.write("This is how 'User actions go LAST' and CFG-609 vanished (0a26da91, 2026-09-27). Never retire a rule on your own:\n"
              "take the file out of the commit and ask.\n")


def main(argv):
    mode = argv[0] if argv else ""
    jobs, rev = [], None
    blank = {"only": False, "amend": False, "munk": False, "msgs": [], "files": [], "stdin": None, "sunk": False, "muts": []}
    if mode == "--jobs":
        f = open(argv[1], "rb").read().decode("utf-8", "surrogateescape").split("\0"); i = 0
        while i < len(f) and f[i] == "J":
            where, ng = f[i + 1], int(f[i + 2]); g = f[i + 3:i + 3 + ng]; i += 3 + ng
            tree, np_ = f[i] == "1", int(f[i + 1]); paths = f[i + 2:i + 2 + np_]; i += 2 + np_
            x = dict(blank)
            if i < len(f) and f[i] == "X":
                x["only"], x["amend"], x["munk"], nm = f[i + 1] == "1", f[i + 2] == "1", f[i + 3] == "1", int(f[i + 4]); i += 5
                x["msgs"] = f[i:i + nm]; i += nm; nf = int(f[i]); x["files"] = f[i + 1:i + 1 + nf]; i += 1 + nf
                x["stdin"], x["sunk"] = (f[i + 1] if f[i] == "1" else None), f[i] == "2"; i += 2
                nmut = int(f[i]); i += 1; x["muts"] = []
                for _ in range(nmut):
                    kind, npth = f[i], int(f[i + 1]); x["muts"].append((kind, f[i + 2:i + 2 + npth])); i += 2 + npth
            jobs.append(Job(where, g, tree, paths, x))
    elif mode == "--check-staged":
        jobs.append(Job(os.path.abspath(argv[1] if len(argv) > 1 else "."), [], False, [], dict(blank)))
    elif mode == "--replay":
        rev = argv[1]; jobs.append(Job(os.path.abspath(argv[2] if len(argv) > 2 else "."), [], False, [], dict(blank)))
    else:
        sys.exit("usage: --jobs <file> | --check-staged <repo> | --replay <commit> [<repo>]")
    findings, held, readable = [], [], True
    for j in jobs:
        msg = "" if mode == "--check-staged" else (j.git("log", "-1", "--format=%B", rev)[1] if rev else None)
        r = j.run(msg, rev)
        if r: findings += r[0]; held += r[1]; readable &= r[2]
    if not findings: return 0
    if mode == "--check-staged":
        sys.stdout.write("\n".join(sorted(set(held))) + "\n"); report(findings, readable, sys.stderr)
    else: report(findings, readable, sys.stdout)
    return 1


sys.exit(main(sys.argv[1:]))
PY
