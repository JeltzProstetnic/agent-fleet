#!/usr/bin/env python3
"""Extract, delete, or audit whole items in cross-project/inbox.md.

An inbox item starts at a column-0 "- [ ] **owner**" line and runs until the
next column-0 "- [" line or a "## " heading. Two things make the naive
line-based approach wrong, and both bit a real session on 2026-08-24:

  * items carry INDENTED continuation paragraphs — deleting only the headline
    leaves them orphaned under whatever heading follows, and the evidence in
    them is silently lost;
  * at least one item embeds an UNINDENTED bash fence whose lines begin with
    "- [", so fences must suspend the boundary rule.

Owners may carry a suffix — "**proj (WSL)**" — so matching is on the leading
token of the bold field, not the whole field.

Usage:
  inbox-cut.py <file> extract <owner>   print matching items verbatim
  inbox-cut.py <file> delete  <owner>   remove them in place
  inbox-cut.py <file> owners            count open items per owner
  inbox-cut.py <file> orphans           report continuation blocks with no parent
"""
import sys
import re

ITEM = re.compile(r'- \[[ x>]\] \*\*(?P<owner>[^*]+)\*\*')


def _fence_map(lines):
    """True for every line inside a ``` fence."""
    out, state = [], False
    for line in lines:
        if line.lstrip().startswith('```'):
            # BOTH markers count as fenced: an opening ``` must never become the
            # "parent" line of the indented text that follows the closing one.
            out.append(True)
            state = not state
            continue
        out.append(state)
    return out


def spans(lines):
    """Yield (start, end_exclusive) for every top-level item."""
    fenced = _fence_map(lines)
    starts = [i for i, l in enumerate(lines)
              if l.startswith('- [') and not fenced[i]]
    result = []
    for s in starts:
        end = len(lines)
        for j in range(s + 1, len(lines)):
            if fenced[j]:
                continue
            if lines[j].startswith('- [') or lines[j].startswith('## '):
                end = j
                break
        while end > s + 1 and not lines[end - 1].strip():
            end -= 1
        result.append((s, end))
    return result


def owner_of(line):
    m = ITEM.match(line)
    if not m:
        return None
    # "proj (WSL)" -> "proj"; a "parent/child" owner stays whole
    return m.group('owner').strip().split(' (')[0].strip().lower()


def read(path):
    raw = open(path, 'rb').read()
    crlf = b'\r\n' in raw
    return raw.replace(b'\r\n', b'\n').decode('utf-8').split('\n'), crlf


def write(path, lines, crlf):
    text = '\n'.join(lines)
    data = text.encode('utf-8')
    if crlf:
        data = data.replace(b'\n', b'\r\n')
    open(path, 'wb').write(data)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    path, mode = sys.argv[1], sys.argv[2]
    lines, crlf = read(path)

    if mode == 'orphans':
        fenced = _fence_map(lines)
        last, bad = None, []
        for i, l in enumerate(lines):
            if fenced[i] or not l.strip():
                continue
            if l.startswith(('  ', '\t')):
                if last is None or not last.startswith('- ['):
                    bad.append((i + 1, l[:70]))
            else:
                last = l
        print(f'orphans: {len(bad)}')
        for n, t in bad:
            print(' ', n, t)
        return 0

    if mode == 'owners':
        counts = {}
        for s, _ in spans(lines):
            if lines[s].startswith('- [ ]'):
                o = owner_of(lines[s]) or '?'
                counts[o] = counts.get(o, 0) + 1
        for o, c in sorted(counts.items(), key=lambda kv: -kv[1]):
            print(f'{c:5d}  {o}')
        return 0

    if len(sys.argv) < 4:
        sys.exit(__doc__)
    want = sys.argv[3].strip().lower()
    hits = [(s, e) for s, e in spans(lines) if owner_of(lines[s]) == want]

    if mode == 'extract':
        for s, e in hits:
            print('\n'.join(lines[s:e]))
            print()
        return 0

    if mode == 'delete':
        keep = [True] * len(lines)
        for s, e in hits:
            for k in range(s, e):
                keep[k] = False
        write(path, [l for l, k in zip(lines, keep) if k], crlf)
        print(f'deleted {len(hits)} item(s), {keep.count(False)} line(s)')
        return 0

    sys.exit(f'unknown mode: {mode}')


if __name__ == '__main__':
    sys.exit(main())
