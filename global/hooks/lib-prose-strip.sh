#!/usr/bin/env bash
# lib-prose-strip.sh — the PROSE in a shell command, removed before a kill guard reads it
# (CFG-731 / CFG-735). Sourced by kill-guard.sh. pkill-guard.sh carries this same pass
# inline since CFG-731 and can adopt this file in a later change. One difference from that
# inline copy, measured 2026-10-18: a here-string (`<<<`) is NOT read as a heredoc here. Read
# as one, the pass dropped every line after `wc -c <<< "y"` up to a terminator that never
# comes — including a real `kill <pid>` on the next line.
#
# Prose is data, not execution. Both guards were refusing commands whose only "kill" was
# text: a python heredoc writing a backlog line (pkill-guard, 2026-09-29) and a python
# heredoc whose string literals named kill idioms, refused as if it would signal six
# unrelated host processes (kill-guard, same day). Dropped before the scan:
#   1. heredoc bodies fed to anything that is NOT a shell. A heredoc on a line that names a
#      shell (bash/sh/zsh/dash/ssh/eval — also `cat <<EOF | bash`) is kept: that body runs.
#   2. the quoted values of message-like flags (-m, --message, --body, --title,
#      --description, --comment). The flag stays; a kill AFTER the message is still seen.
# Known limit, accepted with CFG-731: a kill a non-shell interpreter performs from inside a
# dropped body (os.system("kill …") in a python heredoc) is not seen, nor is a body fed to a
# shell this list does not name (ksh, fish, at, expect, `sudo -s`).
#
# Contract: strip_prose_from_command CMD → prints the stripped command, returns 0. Returns
# non-zero and prints nothing usable when python3 is missing or fails, so a caller written as
#   _stripped=$(strip_prose_from_command "$CMD") && CMD="$_stripped"
# keeps the RAW command. The fail-safe direction is over-block, never under-block.

[[ "${_LIB_PROSE_STRIP_LOADED:-}" == "true" ]] && return 0
_LIB_PROSE_STRIP_LOADED="true"

strip_prose_from_command() {
    command -v python3 >/dev/null 2>&1 || return 1
    printf '%s' "$1" | python3 -c '
import re, sys
s = sys.stdin.read()
lines, out, i = s.split("\n"), [], 0
while i < len(lines):
    l = lines[i]; out.append(l)
    m = re.search(r"(?<!<)<<(?!<)-?\s*([\x27\"]?)(\w+)\1", l)
    if not m:
        i += 1; continue
    term = m.group(2)
    shell = re.search(r"(^|[\s;&|(])(bash|sh|zsh|dash|ssh|eval)(\s|$)", l) is not None
    j = i + 1
    while j < len(lines) and lines[j].strip() != term:
        if shell: out.append(lines[j])
        j += 1
    if j < len(lines): out.append(lines[j])
    i = j + 1
s = "\n".join(out)
s = re.sub(r"(\s(?:-m|--message|--body|--title|--description|--comment)(?:\s+|=))(\"(?:[^\"\\\\]|\\\\.)*\"|\x27[^\x27]*\x27)", r"\1\"\"", s)
sys.stdout.write(s)
' 2>/dev/null
}
