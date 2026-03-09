# Platform Notes

Load this when: working on a platform you're unfamiliar with, terminal tab operations, or cross-platform issues.

Machine files (`~/.claude/machines/<machine>.md`) contain platform-specific details. This file covers platform-wide conventions.

## WSL

- **NEVER work in `/mnt/c/` paths** — 10-15x slower
- `git config --global core.autocrlf input`
- Full reference: `~/.claude/reference/wsl-environment.md`

## VPS

- User runs tmux — for "open new tab" requests, use `tmux new-window -c <path>`
- No GUI, no file opening, no `xdg-open`
- **Mobile-first delivery:** Assume the user is on mobile and cannot copy-paste from the terminal. Any text the user needs to copy-paste (tweet drafts, reply options, snippets) MUST be delivered via pastebin link, not inline. Use termbin: `printf 'text' | nc termbin.com 9999` — returns a plain-text URL the user can open in their phone browser. Fallback order: termbin.com → dpaste.org → ix.io.
- **Tmux tab switching:** When the user wants to switch tabs, list all open tmux windows as a numbered list so they can reply with just a number. Name windows after the project/folder name (not "claude" or generic names).
- **New tab creation:** When the user asks for a new tab, present a numbered list of projects on the local system (from `~/`) so they can pick by number. Then create the window named after the chosen project.

## Native Linux (Fedora KDE, SteamOS, etc.)

- Use `xdg-open` for opening files (respects system default app)
- No `/mnt/c/` or `powershell.exe` available
- **Terminal tabs (Konsole/KDE):** Use D-Bus to open tabs and send commands:
  ```bash
  KONSOLE_SVC=$(qdbus org.kde.konsole-* 2>/dev/null | head -1)
  SID=$(qdbus "$KONSOLE_SVC" /Windows/1 org.kde.konsole.Window.newSession "tab-name" "bash")
  qdbus "$KONSOLE_SVC" /Sessions/$SID org.kde.konsole.Session.sendText "cd ~/project && mclaude\n"
  ```
- **Never use tmux on KDE machines** — the user has a graphical terminal with native tabs

## macOS

- Use `open <filepath>` for opening files (respects system default app)
- No `/mnt/c/` or `powershell.exe` available
