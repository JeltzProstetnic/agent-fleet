# Statusline Operations — Knowledge Base

Loaded when: editing statusline-command.sh, GPI, or deploying statusline changes.

## Architecture

- **Source**: `~/agent-fleet/setup/config/statusline-command.sh`
- **Deployed to**: `~/.claude/statusline-command.sh` (via `sync.sh deploy` or manual `cp`)
- **State file (GPI)**: `~/.claude/.gpi-state.json`
- **CLI**: `gpi` (`~/.local/bin/gpi` → `setup/scripts/gpi.sh`)
- **Renderer**: Python block inside statusline-command.sh, invoked by Claude Code every turn

## Deployment Gotchas

1. **Source vs deployed divergence.** After editing `setup/config/statusline-command.sh`, you must also deploy it (`cp` or `sync.sh deploy`). Editing the source without redeploying means changes are invisible until next sync. Always check `settings.json` to confirm which file the live config references.

2. **Python inside bash quoting.** The statusline uses `python3 -c "..."` inside bash. Python f-strings with double quotes (`f"{x}"`) terminate the bash string. Use string concatenation (`str(x) + '%'`) or single-quoted f-strings inside double-quoted bash.

3. **Redeploying CLI tools too.** `gpi.sh` deploys to `~/.local/bin/gpi`. After modifying gpi.sh (adding flags, changing state format), redeploy or the old version keeps running.

## GPI (Grind Progress Indicator)

### State Design
- `gpi.sh` writes to `~/.claude/.gpi-state.json` with `flock` for concurrency
- Each op has: label, pct, detail, group, started, eta_secs, seq_index, seq_total, log_path, completed_at
- `updated` timestamp at root level — set only by `gpi.sh` CLI calls
- `completed_at` field: set by `gpi done` or by renderer when log detects completion (operation completion markers)

### Completion Lifecycle
1. `gpi done <id>` sets `completed_at` timestamp (does NOT delete the op)
2. Op remains visible for 60 seconds with green "DONE" indicator
3. Auto-cleaned after 60s (by both `gpi.sh` commands and renderer)
4. Notification sidecar (`~/.claude/.gpi-completed.json`) written on completion
5. UserPromptSubmit hook reads sidecar and injects `GPI_COMPLETED: <label> finished` into context
6. Hook deletes sidecar after reading (one-shot notification)

Log-detected completion (completion markers in log file) also sets `completed_at` in state and writes the sidecar — no `gpi done` call needed.

### Notification Sidecar
- Path: `~/.claude/.gpi-completed.json` (env: `GPI_COMPLETED`)
- Format: JSON array of `{id, label, completed_at}`
- Written by: `gpi done` and renderer log detection
- Consumed by: `context-budget.sh` hook (deleted after read)

## Testing Requirements

- **Synthetic tests** (current: 24 tests in `test-gpi.sh`) cover CLI behavior and rendering with injected state.
- **Real data fixtures** needed: capture sample operation log output, test the parser against them. Synthetic data hid 3 bugs in the initial release (raw bytes, pct duplication, wrong progress metric).
- **Live verification step**: after deploying, test with `echo '<real-context-json>' | bash ~/.claude/statusline-command.sh` with real operation logs active. Don't rely on synthetic tests alone for rendering changes.
