<!-- consumed-by: global/knowledge/audit-protocol.md (the "don't file this P0" cross-reference) -->

# systemd memory accounting — `Memory:` is not the service's footprint

**Load when:** a systemd service looks like it is leaking, a memory alarm fires on a
file-serving process, or an OOM post-mortem needs a footprint number.

## The trap

`systemctl status` prints a `Memory:` line. That number is the cgroup's
`memory.current`, and **`memory.current` includes page cache**. For any service that
reads or serves files, it will climb to whatever the kernel felt like caching and then
sit there — which looks exactly like an unbounded leak and is not one.

This has already cost one wrongly-filed P0.

## Measurement that established it

NUC, 2026-09-16, while the "bad" state was actively reproducing. `systemctl status`
reported **`Memory: 11.6G (peak: 12.1G)`** after 68 minutes of uptime. The cgroup and the
process said something else entirely:

| Source | Value |
|---|---|
| `memory.stat` `anon` | 102,400,000 (**102 MB**) |
| `memory.stat` `file` | 12,360,376,320 (**12.36 GB**) |
| `memory.stat` `inactive_file` | 12,296,372,224 — reclaimable |
| `swap.current` | 0 |
| `/proc/<mainpid>/status` `VmRSS` | 123,316 kB (**123 MB**), 19 threads, 18 open fds |
| processes in the cgroup | 1 |

The 12 GB was page cache from a FastAPI `StaticFiles` mount serving media off a
CIFS-mounted NAS. The kernel reclaims it on demand. Nothing was wrong.

## Diagnostic recipe

Run this before concluding anything about a service's memory.

1. **Do not trust `systemctl status`'s `Memory:` line.** It answers a different question
   than the one being asked.

2. **Read the cgroup split.**
   ```bash
   CG=/sys/fs/cgroup/system.slice/<unit>.service
   grep -E '^(anon|file|inactive_file|slab|sock|shmem) ' "$CG/memory.stat"
   ```

3. **Read the process truth.**
   ```bash
   grep -E 'VmRSS|Threads' /proc/$(systemctl show -p MainPID --value <unit>)/status
   ```

4. **Only a large `anon` is a real leak.** A high `file` with a low `anon` is healthy page
   cache and needs no action.

## Where this still bites

The same accounting applies to **container memory limits** and to **OOM post-mortems**:
`memory.current` is what the OOM killer watches, so page cache genuinely *can* create
pressure. But the fix in that case is a `MemoryHigh=` / `MemoryMax=` or a reclaim hint —
never a hunt for a leak in the application.

Expect this to recur wherever a fleet process serves or reads large files.

Source: a fleet media project on WSL, 2026-09-16 (a P0 leak alarm retracted to P1 on this measurement).
