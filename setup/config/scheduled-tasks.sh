#!/usr/bin/env bash
# Fleet-wide scheduled tasks — sourced by check 19
# These tasks run on ALL machines. Machine-specific tasks go in machines/<name>/tasks.sh.
#
# NOTE: Tasks that are already handled by numbered check modules (04, 09, 13, 14, 15b, 17)
# should NOT be registered here — those checks use sched_is_due/sched_mark_done directly.
# This file is for NEW tasks that don't have a dedicated check module.

# Weekly: review upstream dependencies beyond CC (VoltAgent, MCP servers, TweakCC)
sched_task "upstream-dep-review" \
    --interval weekly \
    --scope fleet \
    --exec prompted \
    --desc "Review upstream dependencies for available updates (VoltAgent, MCP, TweakCC)"

# Weekly: backlog health review (separate from check 15b's P0/P1 count — this is a human review prompt)
sched_task "backlog-review" \
    --interval weekly \
    --scope per-project \
    --project "" \
    --exec manual \
    --desc "Review backlog for stale items, priority drift, and items that can be closed"

# Monthly: cross-project inbox cleanup
sched_task "inbox-cleanup" \
    --interval monthly \
    --scope fleet \
    --exec prompted \
    --desc "Review cross-project inbox for items older than 14 days — promote to backlog or delete"
