#!/usr/bin/env python3
"""tty-probe.py — read-only root probe of another session's /proc (CFG-878, WSL path).

On WSL (yama ptrace_scope=1) an unprivileged process cannot read /proc/<pid>/{exe,fd/0,cwd}
of a session it did not spawn — and a remote end/exit targets exactly such a session. The
safety policy stays in bash; this helper only reads, as root (wsl.exe -u root), the fields
bash cannot. It NEVER writes or signals anything.

    tty-probe.py inspect <pid>     -> alive=0|1, and if alive: tty= exe= cwd= comm=
    tty-probe.py sharers <tty>     -> one "<pid> <comm>" line per process whose fd 0 is <tty>

TTY_PROBE_PROC overrides /proc (tests only). Output is plain key=value / "pid comm" lines so
bash can parse it without a JSON dependency.
"""
import os
import re
import sys

PROC = os.environ.get("TTY_PROBE_PROC", "/proc")
PTS_RE = re.compile(r"^/dev/pts/[0-9]+$")


def rl(path):
    try:
        return os.readlink(path)
    except OSError:
        return ""


def comm(pid):
    try:
        with open(f"{PROC}/{pid}/comm") as f:
            return f.read().strip()
    except OSError:
        return ""


def inspect(pid):
    if not os.path.isdir(f"{PROC}/{pid}"):
        print("alive=0")
        return
    print("alive=1")
    tty = rl(f"{PROC}/{pid}/fd/0")
    exe = rl(f"{PROC}/{pid}/exe")
    if exe.endswith(" (deleted)"):
        exe = exe[: -len(" (deleted)")]
    print(f"tty={tty}")
    print(f"exe={os.path.basename(exe) if exe else ''}")
    print(f"cwd={rl(f'{PROC}/{pid}/cwd')}")
    print(f"comm={comm(pid)}")


def sharers(tty):
    if not PTS_RE.match(tty):
        print(f"tty-probe: refused: {tty} is not a /dev/pts/<n> device", file=sys.stderr)
        sys.exit(2)
    for name in os.listdir(PROC):
        if not name.isdigit():
            continue
        if rl(f"{PROC}/{name}/fd/0") == tty:
            print(f"{name} {comm(name)}")


def main():
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "inspect" and a[1].isdigit():
        inspect(a[1])
    elif len(a) == 2 and a[0] == "sharers":
        sharers(a[1])
    else:
        print("usage: tty-probe.py inspect <pid> | sharers <tty>", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
