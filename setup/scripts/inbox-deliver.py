#!/usr/bin/env python3
"""Deliver one project's cross-project inbox items into its own backlog.md.

Moves item text VERBATIM — only an ID and a title line are prepended, so the
original source session and date stay readable in the preamble. Inserts above
the first '## Done' heading; appends if there is none.

Preserves the target's line endings. A session on 2026-08-24 rewrote a whole
backlog by stripping CRLF, turning a six-line append into a 216-line diff.

Does NOT delete from the inbox and does NOT commit — run inbox-cut.py delete
afterwards, and stage only backlog.md, because target repos routinely carry
pre-staged changes that a bare `git commit` would sweep into your commit.

Usage:
  inbox-deliver.py <owner> <PREFIX> <start-id> [--backlog PATH] [--apply]

Without --apply it prints the plan and writes nothing.
Env: INBOX overrides the inbox path (default: <repo>/cross-project/inbox.md).
"""
import sys
import os
import re
import subprocess
import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
CUT = os.path.join(HERE, 'inbox-cut.py')
# Derived from this script's own location (<repo>/setup/scripts/), never a
# hardcoded home path — that is what keeps this file propagatable verbatim.
DEFAULT_INBOX = os.path.abspath(
    os.path.join(HERE, os.pardir, os.pardir, 'cross-project', 'inbox.md'))


def split_items(raw):
    items, cur = [], []
    for line in raw.split('\n'):
        if line.startswith('- ['):
            if cur:
                items.append('\n'.join(cur).rstrip())
            cur = [line]
        elif cur:
            cur.append(line)
    if cur:
        items.append('\n'.join(cur).rstrip())
    return [i for i in items if i.strip()]


def strip_owner(line):
    return re.sub(r'^- \[[ x>]\] \*\*[^*]+\*\*:?\s*', '', line)


def title_of(item):
    body = strip_owner(item.split('\n')[0])
    body = re.sub(r'^\([^)]*\):?\s*', '', body)
    m = re.search(r'\*\*(.+?)\*\*', body)
    t = re.sub(r'\s+', ' ', (m.group(1) if m else body)).strip().rstrip('.:')
    return (t[:150] + '…') if len(t) > 150 else (t or 'Inbox item')


def prio_of(item):
    m = re.search(r'\**P([0-3])\b', item.split('\n')[0])
    return f'[P{m.group(1)}]' if m else '[P3]'


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if len(args) < 3:
        sys.exit(__doc__)
    owner, prefix, start = args[0], args[1], int(args[2])
    apply_ = '--apply' in sys.argv
    inbox = os.environ.get('INBOX', DEFAULT_INBOX)

    backlog = None
    if '--backlog' in sys.argv:
        backlog = sys.argv[sys.argv.index('--backlog') + 1]
    else:
        backlog = os.path.expanduser(f'~/{owner}/backlog.md')

    raw = subprocess.run([sys.executable, CUT, inbox, 'extract', owner],
                         capture_output=True, text=True, check=True).stdout
    items = split_items(raw)
    if not items:
        print(f'{owner}: no items — nothing to deliver')
        return 0

    blocks = []
    for n, it in enumerate(items):
        head = strip_owner(it.split('\n')[0])
        tail = '\n'.join(it.split('\n')[1:])
        line = f'- [ ] {prio_of(it)} `{prefix}-{start + n}` **{title_of(it)}.** {head}'
        blocks.append(line + ('\n' + tail if tail.strip() else ''))

    print(f'{owner}: {len(items)} item(s) -> {prefix}-{start}..{prefix}-{start + len(items) - 1}')
    for n, it in enumerate(items):
        print(f'  {prefix}-{start + n} {prio_of(it)} {title_of(it)[:95]}')
    if not apply_:
        print('  (dry run — pass --apply to write)')
        return 0

    today = datetime.date.today().isoformat()
    sender = os.path.basename(os.path.abspath(os.path.join(HERE, os.pardir, os.pardir)))
    section = (
        f'### Inbox intake {today} — delivered by {sender}\n\n'
        f'{len(items)} item(s) moved verbatim from `cross-project/inbox.md` while this '
        'project had no active session. Each preamble names the original source and date.\n\n'
        + '\n\n'.join(blocks) + '\n'
    )

    data = open(backlog, 'rb').read() if os.path.exists(backlog) else b''
    crlf = b'\r\n' in data
    text = data.replace(b'\r\n', b'\n').decode('utf-8')

    idx = text.find('\n## Done')
    text = (text[:idx + 1] + section + '\n' + text[idx + 1:]) if idx != -1 \
        else (text.rstrip('\n') + '\n\n' + section)

    out = text.encode('utf-8')
    if crlf:
        out = out.replace(b'\n', b'\r\n')
    open(backlog, 'wb').write(out)
    print(f'  -> {backlog}' + (' (CRLF preserved)' if crlf else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
