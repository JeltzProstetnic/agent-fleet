#!/usr/bin/env python3
"""tty-inject.py — type a line into ONE Claude Code session's own pty (CFG-878, WSL path).

On WSL a session has no tmux pane and no Konsole tab: `af` runs claude under `script -q -f`
in a Windows Terminal tab, so claude reads its own /dev/pts/<n>. The kernel refuses TIOCSTI
(legacy_tiocsti=0) unless the caller holds CAP_SYS_ADMIN, so remote-session-lib.sh runs this
as root through `wsl.exe -u root -e python3 …`. No shell is involved: argv only.

    tty-inject.py [--expect-pid PID] [--clear N] [--no-cr] /dev/pts/N [TEXT]

TEXT (optional) is typed, then Enter (\\r) unless --no-cr. No TEXT = Enter only.
--clear N first types N times Ctrl+K (delete to line end), then N times Ctrl+U (delete to line start,
repeated across lines): it empties Claude Code's input line wherever the cursor sits, which TEXT cannot
do because TEXT refuses control characters. `--clear N --no-cr` with no TEXT is a clear alone (CFG-1006).

Claude Code 2.1.280 acts on a control byte (a clearing key, the Enter) ONLY when it arrives in a read of
fewer than 64 bytes; a read of 64+ bytes is ONE text token whose control bytes do nothing (its input
tokenizer, bin/claude.exe offset 191421218: `a<32&&(u.length<64||a===BS)`). Bytes typed back to back
reach it as whatever reads it happens to make — 128 clearing bytes were read as [21,107]: no Ctrl+U at
all; on 2026-11-13 a 330-byte order and its CR were one read, the CR became text and the order sat
unsent. So an injection goes in as separate WRITES with a pause before each: the clear CLEAR_BATCH keys
at a time, KEY_GAP apart; the TEXT (text only) TEXT_GAP after a clear; the Enter alone, TEXT_GAP after
anything before it.
--expect-pid PID re-verifies, as root and immediately before EVERY write, that PID is
still alive, that its fd 0 is exactly this pty and that its executable is the Claude Code
binary (`claude` / `claude.exe`, the same rule as cc-account-holders.py). That closes the
window in which the pid could have been reused by something else reading the same device.

Refusals: 2 usage / not a /dev/pts/N path / control characters in TEXT, 3 --expect-pid check failed
(both: nothing injected), 4 the kernel refused TIOCSTI (not root, or no such device), 5 the
--expect-pid check failed part-way (the writes before it were typed, none after).
TTY_INJECT_PROC overrides /proc (tests only).
"""
import fcntl
import os
import re
import sys
import termios
import time

PTS_RE = re.compile(r"^/dev/pts/[0-9]+$")
CLAUDE_EXES = ("claude", "claude.exe")
PROC = os.environ.get("TTY_INJECT_PROC", "/proc")


def refuse(code, msg):
    print(f"tty-inject: refused: {msg}", file=sys.stderr)
    sys.exit(code)


CTRL_K, CTRL_U = b"\x0b", b"\x15"
MAX_CLEAR = 64
CLEAR_BATCH = 8    # clearing keys per write — far below the 64 bytes at which they stop acting
KEY_GAP = 0.1      # seconds before each further write of the clear
TEXT_GAP = 0.5     # seconds before the TEXT after a clear, and before the Enter after anything


def parse(argv):
    expect_pid, cr, clear, rest = None, True, 0, []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--expect-pid":
            i += 1
            if i >= len(argv) or not argv[i].isdigit():
                refuse(2, "--expect-pid needs a numeric pid")
            expect_pid = int(argv[i])
        elif a == "--clear":
            i += 1
            if i >= len(argv) or not argv[i].isdigit() or not 1 <= int(argv[i]) <= MAX_CLEAR:
                refuse(2, f"--clear needs a count of Ctrl+U presses (1-{MAX_CLEAR})")
            clear = int(argv[i])
        elif a == "--no-cr":
            cr = False
        elif a.startswith("--"):
            refuse(2, f"unknown option {a}")
        else:
            rest.append(a)
        i += 1
    if not 1 <= len(rest) <= 2:
        refuse(2, "usage: tty-inject.py [--expect-pid PID] [--clear N] [--no-cr] /dev/pts/N [TEXT]")
    tty = rest[0]
    text = rest[1] if len(rest) == 2 else ""
    if not PTS_RE.match(tty):
        refuse(2, f"{tty} is not a /dev/pts/<n> device")
    if any(ord(c) < 0x20 or ord(c) == 0x7F for c in text):
        refuse(2, "TEXT must not contain control characters")
    if not text and not cr and not clear:
        refuse(2, "nothing to type (no TEXT, no --clear and --no-cr)")
    return tty, text, expect_pid, cr, clear


def exe_basename(pid):
    try:
        exe = os.readlink(f"{PROC}/{pid}/exe")
    except OSError:
        return None
    if exe.endswith(" (deleted)"):
        exe = exe[: -len(" (deleted)")]
    return os.path.basename(exe)


def pid_problem(pid, tty):
    """None while pid is still the claude that reads this pty, else why not — checked at each write."""
    if not os.path.isdir(f"{PROC}/{pid}"):
        return f"pid {pid} is not alive"
    try:
        fd0 = os.readlink(f"{PROC}/{pid}/fd/0")
    except OSError as e:
        return f"cannot read /proc/{pid}/fd/0 ({e.strerror})"
    if fd0 != tty:
        return f"pid {pid} reads {fd0}, not {tty} — target moved or pid reused"
    base = exe_basename(pid)
    if base not in CLAUDE_EXES:
        return f"pid {pid} is not a Claude Code binary (exe: {base or 'unreadable'})"
    return None


def writes(text, cr, clear):
    """The injection as (pause-before, bytes) writes: no write that holds a control byte comes near
    the 64 bytes at which Claude Code reads it as text, and the Enter is always a write of its own."""
    out = []
    keys = CTRL_K * clear + CTRL_U * clear
    for i in range(0, len(keys), CLEAR_BATCH):
        out.append((KEY_GAP if out else 0, keys[i:i + CLEAR_BATCH]))
    if text:
        out.append((TEXT_GAP if out else 0, text.encode("utf-8")))
    if cr:
        out.append((TEXT_GAP if out else 0, b"\r"))
    return out


def main():
    tty, text, expect_pid, cr, clear = parse(sys.argv[1:])
    try:
        fd = os.open(tty, os.O_WRONLY | os.O_NOCTTY)
    except OSError as e:
        refuse(4, f"cannot open {tty} ({e.strerror})")
    typed = 0
    try:
        for pause, data in writes(text, cr, clear):
            if pause:
                time.sleep(pause)
            why = pid_problem(expect_pid, tty) if expect_pid is not None else None
            if why:
                refuse(5, f"{why} — stopped after {typed} byte(s)") if typed else refuse(3, why)
            for b in data:
                fcntl.ioctl(fd, termios.TIOCSTI, bytes([b]))
            typed += len(data)
    except OSError as e:
        refuse(4, f"TIOCSTI on {tty} failed ({e.strerror}) — needs root (CAP_SYS_ADMIN), "
                  "see /proc/sys/dev/tty/legacy_tiocsti")
    finally:
        os.close(fd)
    print(f"tty-inject: typed {typed} byte(s) into {tty}"
          + (f" (pid {expect_pid} verified before each write)" if expect_pid is not None else ""))


if __name__ == "__main__":
    main()
