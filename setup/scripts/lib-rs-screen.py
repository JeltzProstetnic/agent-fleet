#!/usr/bin/env python3
"""lib-rs-screen.py — a Claude Code screen from its terminal output, and the dialog on it (CFG-1023 slice 1).

  lib-rs-screen.py render   < log    the screen the log draws, one line per row, right-trimmed
  lib-rs-screen.py options  < log    the dialog's options; exit 1 when no dialog with a cursor is on screen

Input is a script(1) log (what remote-session reads on WSL, often only its tail) or already-rendered text (tmux
capture-pane, Konsole getAllDisplayedText), which passes through unchanged. Claude Code 2.1.280 draws with relative
cursor moves (CSI A/B/C/D/G), line erases (CSI K) and colours (CSI m), and redraws only the lines that change — so
the screen is replayed on a virtual terminal, never read as a byte stream. The width comes from the log's
`COLUMNS="…"` header when present (default 200). Real captures and findings:
setup/tests/fixtures/cfg1023/, docs/research/cfg1023-dialog-captures-2026-11-27.md.

options output — line 1: `kind=<single|checklist> n=<options> cursor=<1-based option | action>`, then per option
`<n>\\t<1 cursor on it | 0>\\t<1 ticked | 0 unticked | - no box>\\t<text>`. `action` = the checklist's confirm line
(`Enable selected`). Library, not an afx verb (afx skips lib-*). No dependencies beyond the standard library.
"""
import re
import sys
import unicodedata

GUIDES = ("Enter to confirm", "Esc to cancel", "Space to select", "Esc to reject all")
CSI = re.compile(r"\x1b\[([0-?]*)([ -/]*)([@-~])")
OSC = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def _width(ch):
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def _num(params, default=1):
    p = params.split(";")[0].lstrip("?<>=")
    return int(p) if p.isdigit() and int(p) > 0 else default


def render(text, cols=200):
    """Replay terminal output on a virtual screen; returns the rows top to bottom, right-trimmed."""
    screen, r, c, saved = {}, 0, 0, (0, 0)
    i, n = 0, len(text)

    def put(ch):
        nonlocal r, c
        w = _width(ch)
        if c + w > cols:
            r, c = r + 1, 0
        row = screen.setdefault(r, {})
        row[c] = ch
        if w == 2:
            row.pop(c + 1, None)
        c += w

    while i < n:
        ch = text[i]
        if ch == "\x1b":
            m = OSC.match(text, i)
            if m:
                i = m.end(); continue
            m = CSI.match(text, i)
            if m:
                params, final = m.group(1), m.group(3)
                if final == "A": r -= _num(params)
                elif final == "B": r += _num(params)
                elif final == "C": c += _num(params)
                elif final == "D": c = max(0, c - _num(params))
                elif final == "G": c = _num(params) - 1
                elif final in "Hf":
                    parts = (params.split(";") + ["1", "1"])[:2]
                    r = (int(parts[0]) if parts[0].isdigit() else 1) - 1
                    c = (int(parts[1]) if parts[1].isdigit() else 1) - 1
                elif final == "K":
                    row, mode = screen.setdefault(r, {}), _num(params, 0) if params else 0
                    for k in [k for k in row if (mode == 0 and k >= c) or (mode == 1 and k <= c) or mode == 2]:
                        del row[k]
                elif final == "J" and params in ("2", "3"):
                    screen.clear()
                i = m.end(); continue
            nxt = text[i + 1:i + 2]
            if nxt == "7": saved = (r, c)
            elif nxt == "8": r, c = saved
            i += 3 if nxt in "()*+" and nxt else 2
            continue
        if ch == "\r": c = 0
        elif ch == "\n": r, c = r + 1, 0   # a tty's onlcr logs every LF as CR LF; a bare LF is rendered text
        elif ch == "\b": c = max(0, c - 1)
        elif ch == "\t": c = (c // 8 + 1) * 8
        elif ch >= " " and ch != "\x7f": put(ch)
        i += 1
    if not screen:
        return []
    out = []
    for row_no in range(min(screen), max(screen) + 1):
        row = screen.get(row_no, {})
        line = "".join(row.get(k, " ") for k in range(max(row) + 1)) if row else ""
        out.append(line.rstrip())
    return out


def read_input():
    raw = sys.stdin.buffer.read().decode("utf-8", "replace")
    cols = 200
    m = re.search(r'COLUMNS="(\d+)"', raw[:2000])
    if m:
        cols = int(m.group(1))
    lines = raw.split("\n")
    if lines and lines[0].startswith("Script started on"):
        raw = "\n".join(lines[1:])
    return raw, cols


BOX = re.compile(r"^(\s*)(?:❯\s+)?\[(✔| )\]\s(.+)$")


def options(rows):
    """(kind, entries, cursor) of the dialog whose guide is the last one on screen, else None."""
    gi = max((k for k, line in enumerate(rows) if any(g in line for g in GUIDES)), default=None)
    if gi is None:
        return None
    block = [line for line in rows[:gi] if line.strip()]
    if any(BOX.match(line) for line in block[-12:]):
        return _checklist(block)
    return _single(block)


def _single(block):
    cur = max((k for k, line in enumerate(block) if line.lstrip().startswith("❯")), default=None)
    if cur is None:
        return None
    lead = block[cur].index("❯")
    col = lead + len(re.match(r"❯\s+", block[cur][lead:]).group(0))
    start, k = cur, cur
    while k - 1 >= 0 and _text_col(block[k - 1]) == col and not block[k - 1].lstrip().startswith("❯"):
        k -= 1
        start = k
    end = cur
    while end + 1 < len(block) and _text_col(block[end + 1]) == col:
        end += 1
    entries = [(n + 1, 1 if j == cur else 0, "-", block[j].lstrip().lstrip("❯").strip())
               for n, j in enumerate(range(start, end + 1))]
    return "single", entries, cur - start + 1


def _text_col(line):
    s = line.lstrip()
    if s.startswith("❯"):
        s = s[1:].lstrip()
    return len(line) - len(s) if s else -1


def _checklist(block):
    items, cursor = [], None
    for line in block:
        m = BOX.match(line)
        if m:
            items.append((len(items) + 1, 1 if "❯" in line else 0, "1" if m.group(2) == "✔" else "0", m.group(3).strip()))
            if "❯" in line:
                cursor = len(items)
        elif items and "❯" in line:
            cursor = "action"
    if not items or cursor is None:
        return None
    return "checklist", items, cursor


def main(argv):
    if len(argv) != 2 or argv[1] not in ("render", "options"):
        sys.stderr.write(__doc__.split("\n\n")[0] + "\n")
        return 2
    raw, cols = read_input()
    rows = render(raw, cols)
    if argv[1] == "render":
        sys.stdout.write("\n".join(rows) + ("\n" if rows else ""))
        return 0
    found = options(rows)
    if not found:
        return 1
    kind, entries, cursor = found
    print(f"kind={kind} n={len(entries)} cursor={cursor}")
    for e in entries:
        print("\t".join(str(x) for x in e))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
