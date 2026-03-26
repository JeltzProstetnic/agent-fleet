# Scrollback Fix for Claude Code

## Root Cause

Claude Code (CC) uses the main screen buffer (not the alternate screen) for its TUI. Each render cycle clears and redraws content, generating ~50-150 lines/second of terminal output. With a terminal buffer that is too small, the buffer fills in minutes and the oldest content (including user prompts and tool output) drops off the scrollback.

On Windows Terminal, the default `historySize` is 9001 lines. Even with a manually increased 50000, the buffer overflows in 10-25 minutes of active CC use.

## The Fix

### 1. Increase terminal scrollback buffer

**Windows Terminal (WSL):** Set `historySize` to 500000 in the defaults profile of Windows Terminal settings:
- File: `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json`
- Set `profiles.defaults.historySize` to `500000`

**Konsole (KDE):** Set `HistorySize=1000000` and `HistoryMode=1` in the active Konsole profile (`.profile` file in `~/.local/share/konsole/`). 50000 is insufficient — heavy sessions with subagents and multi-file diffs overflow it within minutes.

**Other terminals:** Check your terminal's scrollback/history buffer setting and increase to at least 500000. If no explicit setting exists, the terminal may manage scrollback dynamically (iTerm2, Alacritty with unlimited scrollback).

### 2. Avoid undocumented env vars

Two env vars sometimes appear in CC configuration advice:
- `CLAUDE_CODE_DISABLE_VIRTUAL_SCROLL=1`
- `TERM_PROGRAM_INHIBIT_ALTSCREEN=1`

These are NOT in CC's official documentation. Their behavior is unknown and they may have unintended side effects. Do not add them to settings.json unless you've verified their purpose.

### 3. The `\033[3J` escape sequence

The escape sequence `\033[3J` clears the entire scrollback buffer. If any scripts in your fleet use this (e.g., terminal pickers, launchers), remove it — it destroys scrollback that CC sessions depend on.

## Upstream Issues

- **#28077** — CC scrollback clearing / terminal buffer management
- **#826** — Related alternate screen buffer discussion

These track CC's rendering behavior that causes the scrollback overflow. Until upstream fixes the rendering rate or adds alternate screen support, the terminal-side buffer increase is the mitigation.

## Deployment Checklist

For each machine in your fleet:
1. **Windows Terminal (WSL):** Set `historySize` to 500000 in WT settings.json defaults profile
2. **Konsole (KDE/SteamOS):** Set `HistorySize=1000000` and `HistoryMode=1` in active profile
3. **SSH-only machines:** N/A — scrollback is managed by the client terminal
4. **macOS (iTerm2/Terminal.app):** iTerm2 has unlimited scrollback option; Terminal.app: set buffer to max

## Test Coverage

Recommended tests (see `setup/tests/test-scrollback-fix.sh`):
- Windows Terminal historySize >= 500000 (if WT settings file exists)
- Konsole active session scrollback >= 10000 (runtime, if Konsole running)
- Konsole profile on disk has adequate scrollback
- No scripts use `\033[3J` scrollback-clearing escape
