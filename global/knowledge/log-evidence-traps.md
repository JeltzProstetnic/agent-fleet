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

## A value's presence AFTER an incident is not evidence the incident caused it

**Measured 2026-09-23 (WSL), and I got this wrong in a report to MG before catching it.**

After `cc-mirror update` wrecked the install, `variant.json` read `teamModeEnabled: true` and two
unfamiliar skills were on disk. I reported *"it silently enabled team mode — nobody asked for this."*

**Wrong.** Four backups sat in the same directory:

```
variant.json-backup-2.1.111  teamModeEnabled= True   (2026-02-09)
variant.json-backup-2.1.168  teamModeEnabled= True   (2026-06-08)
variant.json-backup-2.1.170  teamModeEnabled= True   (2026-06-10)
variant.json-backup-2.1.220  teamModeEnabled= True   (2026-08-02)
```

Team mode had been **ours since February**, and `CLAUDE_CODE_TEAM_MODE=1` was in the fleet's own
settings template. The tool re-asserted a flag we set and forgot. The consequence of the error was
not cosmetic: acting on it, I set the flag to `false` — **a policy change made while believing it was
a restore.**

⇒ **Before attributing a changed value to an incident, read the same value in the nearest
pre-incident backup and quote both.** The post-incident state alone cannot distinguish *"the incident
set this"* from *"the incident re-asserted what was already there"*, and those call for opposite
repairs. Backups, `git log -S`, and the file's own siblings are usually one command away — the error
is not missing data, it is not looking.

## A background job you launched can change your own session's tools mid-turn

Same incident, separate lesson. The update ran detached via `tmux-launch.sh`. Its side effects —
a new skill listing, a `MANDATORY` skill description, a changed tool roster — **arrived in the
session before the job's log did**, and were briefly assessed as a possible external injection.

⇒ **Attribute a mid-session change in tools, skills or settings to your own in-flight work before
treating it as external.** Check what you launched and what it touches; the log is the slower signal.

## `kill -0` / `os.kill(pid, 0)` SUCCEEDS on a zombie — it is the wrong liveness probe for a child you spawned

**Measured on WSL 2026-09-22.** An un-reaped terminated child is a **zombie**, and signal 0
succeeds on a zombie, so the probe reports the process **alive after you killed it**. This produced a
false `FAIL` in a verification script and would have been read as *"the fix does not work"* — the
classic shape of this file: a check that cannot distinguish the state you care about from the state
you are trying to rule out.

⇒ **Reap with `proc.wait()` instead.** And if what you actually care about is a **GUI window or a
grandchild**, check that separately — *"the wrapper exited"* and *"the window closed"* are different
questions, and the answer to one is not evidence for the other.

**Companion fact from the same measurement, because it is what put the zombie there.**
`subprocess.Popen` **without** `start_new_session=True` leaves the child in the **parent's** process
group — measured `parent pid 4146408 pgid 4146408 / child pid 4146409 pgid 4146408`, versus
`start_new_session=True` giving `pid 4146410 pgid 4146410`. ⛔ **Consequence:** any cleanup helper
written as `os.killpg(os.getpgid(child_pid), SIG)` against such a child **signals your own process
group and kills the caller.** This shipped to production in a fleet project and was one pause-edge
away from taking down the Deck overlay; fixed as `PRN-1577` with two defences — **own session on
spawn**, plus **refusing to `killpg` when `getpgid(pid) == getpgid(0)`** and falling back to the pid
alone.
