#!/usr/bin/env bash
# Check group 27: box-wide name-pattern kills inside the project's tracked scripts (CFG-730).
# Checks: 27.1
# Shared vars used: PROJECT_DIR, WARNINGS
#
# kill-guard/pkill-guard only inspect commands an agent types. A project script that kills
# by bare process name reaches every matching process on the machine: one project's stack
# script killed every pytest/ffmpeg on the box at each start and took out a sibling project's
# full test runs (2026-09-29). This lints the project's own tracked scripts.
#
# FLAGGED: pkill/killall at a command position (bash) or as the program of a subprocess
#          argv / os.system call (python) whose pattern is a bare name.
# SILENT:  comments, prose (echo/printf/docstrings), patterns naming a path or a script
#          (repro/x.py, runner.py), variable patterns, -P/-g/-s scoping, kills by PID,
#          test files, and any line marked '# kill-scope: ok'. 0 tokens.

_uk_dir="${PROJECT_DIR:-$PWD}"
if command -v python3 >/dev/null 2>&1 && git -C "$_uk_dir" rev-parse --git-dir >/dev/null 2>&1; then
    _uk_out=$(git -C "$_uk_dir" ls-files -z -- '*.sh' '*.bash' '*.py' 2>/dev/null | UK_DIR="$_uk_dir" python3 -c '
import os, re, sys
root = os.environ["UK_DIR"]
files = [f for f in sys.stdin.read().split("\0") if f]
TEST = re.compile(r"(^|/)tests?/|(^|/)test[_-][^/]*$")
SH = re.compile(r"(?:^|;|&&|\|\||\||\(|`|\$\(|\bthen\b|\bdo\b|\belse\b)\s*(pkill|killall)\b([^;&|)`]*)")
PYLIST = re.compile(r"\[\s*[\x27\"](pkill|killall)[\x27\"]\s*((?:,\s*[\x27\"][^\x27\"]*[\x27\"]\s*)*)\]")
PYSYS = re.compile(r"os\.system\(\s*[\x27\"](pkill|killall)\s+([^\x27\"]*)")
SCOPING_OPTS = {"-P", "--parent", "-g", "--pgroup", "-s", "--session"}
PROJ = os.path.basename(os.path.normpath(root)).lower()
def sp(text):
    import shlex
    try:
        return shlex.split(text)
    except ValueError:
        return text.split()
FUNC = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\)")
ASSIGN = re.compile(r"\b(\w+)=\$\(\s*pgrep\b([^)]*)\)")
INLINE_SUB = re.compile(r"\bkill\b[^;&|]*\$\(\s*pgrep\b([^)]*)\)")
INLINE_XARGS = re.compile(r"\bpgrep\b([^|;&]*)\|\s*xargs\s+(?:-\S+\s+)*kill\b")
def sh_pgrep_kills(lines):
    """The 2026-09-29 incident idiom: pids=$(pgrep -f PAT); kill $pids — and helpers wrapping it,
    judged at their call sites. Returns line numbers of unscoped kills."""
    found, pvars, helpers, func = [], {}, set(), None
    for n, line in enumerate(lines, 1):
        s = line.strip()
        if not s or s.startswith("#") or "kill-scope: ok" in line:
            continue
        m = FUNC.match(line)
        if m:
            func = m.group(1)
        for m in ASSIGN.finditer(line):
            pvars[m.group(1)] = (sp(m.group(2)), func)
        for var, (args, f) in pvars.items():
            if re.search(r"\bkill\b[^;&|]*\$\{?%s\}?\b" % re.escape(var), line):
                if any(t.strip("\x27\"").startswith("$") for t in args if not t.startswith("-")) and f:
                    helpers.add(f)
                elif unscoped("pgrep", args):
                    found.append(n)
        for rx in (INLINE_SUB, INLINE_XARGS):
            m = rx.search(line)
            if m and unscoped("pgrep", sp(m.group(1))):
                found.append(n)
    for n, line in enumerate(lines, 1):
        s = line.strip()
        if not s or s.startswith("#") or "kill-scope: ok" in line or FUNC.match(line):
            continue
        for h in helpers:
            m = re.match(r"^\s*(?:if\s+|!\s*)?%s\s+(.*)$" % re.escape(h), line)
            if not m:
                continue
            try:
                import shlex
                first = shlex.split(m.group(1))[:1]
            except ValueError:
                first = m.group(1).split()[:1]
            if first and unscoped(h, first):
                found.append(n)
    return found
def unscoped(prog, args):
    toks = [t.strip("\x27\" ") for t in args]
    toks = [t for t in toks if t and ">" not in t and t not in ("||", "&&", "true", "2")]
    if any(t in SCOPING_OPTS for t in toks):
        return False
    names = [t for t in toks if not t.startswith("-")]
    if not names:
        return False
    pat = names[0]
    if "/" in pat or "$" in pat:
        return False
    if PROJ and PROJ in pat.lower():
        return False
    if re.search(r"\.(py|sh|bash|js|mjs|ts|rb|pl)\b", pat):
        return False
    return True
hits = []
for f in files:
    if TEST.search(f):
        continue
    p = os.path.join(root, f)
    try:
        if os.path.getsize(p) > 512 * 1024:
            continue
        lines = open(p, encoding="utf-8", errors="replace").read().split("\n")
    except OSError:
        continue
    is_py = f.endswith(".py")
    for n, line in enumerate(lines, 1):
        s = line.strip()
        if not s or s.startswith("#") or "kill-scope: ok" in line:
            continue
        if is_py:
            m = PYLIST.search(line)
            if m:
                args = re.findall(r"[\x27\"]([^\x27\"]*)[\x27\"]", m.group(2))
                if unscoped(m.group(1), args):
                    hits.append("%s:%d" % (f, n))
                continue
            m = PYSYS.search(line)
            if m and unscoped(m.group(1), sp(m.group(2))):
                hits.append("%s:%d" % (f, n))
        else:
            for m in SH.finditer(line):
                if unscoped(m.group(1), sp(m.group(2))):
                    hits.append("%s:%d" % (f, n))
                    break
    if not is_py:
        hits.extend("%s:%d" % (f, n) for n in sh_pgrep_kills(lines))
if hits:
    more = " (+%d more)" % (len(hits) - 5) if len(hits) > 5 else ""
    print("%d name-pattern kill(s) in tracked scripts reach every matching process on the machine, not just this project\x27s — %s%s. Scope each to the project (match a path under the repo or a script name, or kill recorded PIDs), or mark a deliberate one with \x27# kill-scope: ok\x27 (CFG-730)." % (len(hits), ", ".join(hits[:5]), more))
' 2>/dev/null)
    if [ -n "$_uk_out" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }UNSCOPED_KILL: $_uk_out"
    fi
fi
