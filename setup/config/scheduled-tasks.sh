#!/usr/bin/env bash
# Fleet-wide scheduled tasks — sourced by check 19
# These tasks run on ALL machines. Machine-specific tasks go in machines/<name>/tasks.sh.

# Daily: check for upstream agent-fleet updates
sched_task "fleet-update-check" \
    --interval daily \
    --scope fleet \
    --exec auto \
    --desc "Check for upstream agent-fleet updates" \
    --cmd 'bash "$_sched_config_repo/global/hooks/checks/17-fleet-updates.sh" 2>&1 | tail -5'

# Weekly: check upstream dependencies (CC version, VoltAgent, MCP servers)
sched_task "upstream-dep-check" \
    --interval weekly \
    --scope fleet \
    --exec prompted \
    --desc "Review upstream dependencies for available updates"

# Weekly: backlog health check
sched_task "backlog-health" \
    --interval weekly \
    --scope per-project \
    --project "" \
    --exec prompted \
    --desc "Review backlog for stale items, priority drift, and overdue tasks"

# Monthly: scaling threshold check
sched_task "scaling-check" \
    --interval monthly \
    --scope fleet \
    --exec auto \
    --desc "Check script/file scaling thresholds" \
    --cmd 'bash "$_sched_config_repo/global/hooks/checks/13-scaling-thresholds.sh" 2>&1 | grep -c WARN || echo 0'
