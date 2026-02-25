# WSL Environment Reference

Load this file when: working in WSL, hitting path or performance issues, or setting up a new WSL environment.

## Performance

**NEVER work in `/mnt/c/` paths.** File I/O across the WSL/Windows boundary is 10-15x slower than native Linux paths. Keep all project files under `~/` (the Linux filesystem).

## Git

```bash
git config --global core.autocrlf input
```

This prevents CRLF line endings from being committed when editing files from the Windows side.

## Node.js PATH

WSL inherits the Windows PATH. If Windows has Node.js installed, its `node` may appear before the WSL one. Fix:

```bash
# In ~/.bashrc or ~/.zshrc — add WSL node before Windows node
export PATH="/usr/local/bin:$PATH"
```

Verify: `which node` should return a path under `/usr/` not `/mnt/c/`.

## Sandbox Dependencies

Claude Code's sandbox requires these packages:

```bash
sudo apt install socat bubblewrap
```

Without them, sandboxed tool calls fail silently.
