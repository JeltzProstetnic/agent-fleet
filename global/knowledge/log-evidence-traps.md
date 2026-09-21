<!-- consumed-by: global/knowledge/vault-ops.md (live-log redaction), global/knowledge/live-issue-capture.md (evidence quality) -->

# Log & Evidence Traps

Load when a log, a diff or a grep is about to be used as **evidence** — to conclude a job finished, a
line is absent, a scrub is clean, or a bug is fixed. Every entry below produced a wrong conclusion in
a real fleet session. They share one shape: **the check reports success because it never looked at
what it claimed to look at.** Same family as `CFG-611`.

---

## 1. A completion sentinel can match the line that ANNOUNCES it

`tmux-launch.sh` used to write `Command: <the full command>` into the same log the job appends its
sentinel to. Since the command *contains* the literal text `RSYNC DONE`, `grep -c 'RSYNC DONE' <log>`
returned **1 from the first second** — the completion check reported success while the copy was still
running. A session hit exactly this on a large disk-to-NAS mirror: grep said done, the file count
said **516 of 1162**, and rsync was still live.

**Fixed at the mechanism** (`CFG-659`, 2026-09-21): the command now goes to a `<log>.meta` sidecar and
the log only points at it, so the sentinel cannot pre-appear.

Still worth doing at the call site:
- **Anchor the match**: `grep -cx 'RSYNC DONE'` — a whole-line match cannot be satisfied by a line that
  merely quotes the sentinel.
- **Or ask the process, not the log**: `pgrep -a rsync`, `tmux has-session -t=<name>`.
- ⚠ `rsync --info=stats2` prints only at the end, so **an empty log means running, not failed.**

Same defect class: the `CFG-597` `pgrep -f <pattern>` self-match (the loop matches its own command
line) and the `CFG-616` `tmux -t` prefix match (`-t job` resolves to a live `job2`). Always `-t=`.

## 2. `grep -c` prints `0` and THEN exits 1

`n=$(grep -c PATTERN file || echo 0)` yields **`"0\n0"`** on no-match, because grep already printed its
zero before the `||` fired. Any comparison against `"0"` then fails, and the test looks like the code
is broken when the test is. Use `|| true`, or `grep -c … ; true`.

## 3. `grep <pattern> <log> | tail -N` hides the line you are looking for

On a log carrying a high-frequency recurring line — an APScheduler job logging every 15 s — the tail
window is entirely noise and the one real line is silently cut off. **This produced a wrong root-cause
diagnosis on 2026-09-20**: a fleet-wide deadlock was filed against a service that did not have one, and
the proof it did not was a single line the tail had dropped.

Use `grep -c` first to learn how many matches exist, or grep for the specific message. Never read an
empty tail as an absent line.

**Same class:** a `journalctl` query returning 0 because retention has rotated the window away. Check
the **oldest available entry** before reading a 0 as evidence of absence.

## 4. `color.diff = always` makes every diff-parsing check match nothing

Set in both `cfg-agent-fleet` and `agent-fleet`. The ANSI escape precedes the `+`/`-` marker, so any
script grepping `^+` or `^-` matches **nothing** and reports "no changes". Cost a wrong reading on
2026-08-21; a security audit hit the same wall independently the same day.

Always pass `--no-color` (prefer `git --no-pager diff --no-color`). ⚠ **`-c color.ui=never` does NOT
override it** — `color.diff=always` wins (measured 2026-09-18). If you cannot pass the flag, strip:
`re.sub(r'\x1b\[[0-9;]*m', '', s)`.

## 5. `sed -i` on a log another process holds open SILENTLY KILLS THE WRITER

Every fleet machine runs conversation logging as
`script -q -f -e -c mclaude <project>/docs/terminal-logs/session-<stamp>.log`, so **the current
session's log is an open write fd on a specific inode.**

`sed -i` — and any editor that writes-then-renames — creates a **new** file at that path and unlinks
the old one. The running `script` keeps writing to the now-unlinked inode: the redaction appears to
succeed, the file stops growing, and **the rest of the session's transcript is lost** when the fd
closes. Confirmed live 2026-09-21: a `script` process held that session's own log open while a
redaction of it was being planned.

**The safe edit — available because we control the replacement:** open the file `r+b`, find every
offset of the secret, and write a **same-length** replacement over those bytes in place. Inode, fd,
offsets and file size are all preserved, `script` keeps appending, and no byte outside the secret
moves. **Same-length is not a nicety** — a shorter or longer replacement forces a rewrite and puts you
back on the unlink path.

Applies to any in-place edit of a file another process holds open: logs, journals, tmux capture files.

## 6. An exact-string scrub of a terminal log returns a confident false clean

The TUI splits a rendered value with SGR/cursor escapes, so a literal `grep` for the secret misses
copies that are visibly present. A working scrub needs an **escape-tolerant match** plus a
stripped-index → raw-index mapping. Verification that greps for the raw string will say "clean".

⚠ And the terminal emitted an **OSC 52 clipboard-write** carrying `base64(credential)` — so printing
a secret also put it on the Windows clipboard, where `Win+V` history may still hold it.

⇒ **The cheap fix is upstream: never print a credential in output. Name where it is stored instead.**
A reference scrubber and an escape-blind verification exist in the fleet; grep for the
stripped-index mapping if you need the tested version.

---

## The one-line test

Before trusting a check: **what would this command print if it had looked at nothing?** If that output
is indistinguishable from success, the check is not evidence. Make it report what it examined, so
"inspected nothing" is visibly distinct from "found nothing".
