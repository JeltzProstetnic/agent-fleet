<!-- updates: setup/scripts/afleet-ide.sh (the commands this guide names), setup/tests/test-afleet-ide.sh -->
<!-- consumed-by: global/CLAUDE.md (conditional-loading trigger row), global/knowledge/INDEX.md (row), docs/research/ide-integration-2026-11.md (step 1 of its build order) -->
# IDE Terminal Mode

Load when a developer wants to keep VS Code or a JetBrains IDE open as the place to inspect what a
fleet session changes, when `af --ide`, `/ide` or `af ide …` comes up, or when a session started
from an IDE terminal behaves unexpectedly (lock role, no diff view). Full Visual Studio has no
official Claude Code integration; it is not covered here (see the research doc named above).

## Three ways to connect, all with the full fleet session

| You do | What happens |
|---|---|
| Run `af` in the IDE's **integrated terminal** (VS Code, Cursor and the other VS Code forks, JetBrains) | Claude Code sees the IDE terminal (`TERM_PROGRAM=vscode`, `TERMINAL_EMULATOR=JetBrains-JediTerm`) and connects to that IDE by itself. Hooks, settings, statusline, the launcher's lock and sync steps all run as in any terminal. |
| Run `af` in any terminal, then type `/ide` inside the session | Same connection, chosen from a list of running IDEs. Works from a Windows terminal into a WSL fleet too. |
| Run `af --ide` | The launcher first says what Claude Code will find (which IDE has this folder open), then hands `--ide` to the CLI, which connects when **exactly one** running IDE has the folder open. |

The IDE must have the folder open that `af` lands in (the project directory or a parent of it) and
the Claude Code extension installed; the IDE writes a lock file the CLI discovers. `af` itself
is unchanged: nothing connects unless you ask with one of the three forms above, or opt in:

```
af ide status            # IDE terminal detected? lock dirs searched, IDEs found, opt-in state
af ide autoconnect on    # writes autoConnectIde=true into the fleet's global config (.claude.json)
af ide autoconnect off   # back to the default
```

`autoconnect on` makes every launch connect when an IDE has the folder open; it is the only thing
this mode writes, and only on that command.

## What the IDE shows

- In the default **Manual** permission mode every proposed edit opens as a diff in the IDE for
  accept or reject. That is the review view. `acceptEdits` and auto mode apply edits without the
  dialog; then the IDE's git view (Source Control / Commit tool window) is the place to inspect.
- The current selection and the IDE's diagnostics are shared with the session while connected.
- The session stays a terminal session: `!` shell shortcuts, tab completion and the statusline work
  as usual. The extension's own chat panel is a different, reduced surface and is not this mode.

## Recipes

**VS Code on Linux or macOS.** Install the Claude Code extension, open the project folder, open the
integrated terminal, run `af`. If it does not connect, `/ide`.

**Windows user, fleet in WSL (VS Code Remote-WSL).** Install the "WSL" extension, open the folder
with "Reopen Folder in WSL", install the Claude Code extension in the WSL side (VS Code offers
this). The integrated terminal runs in WSL, so `af` runs there, and the extension's lock file lands
in WSL `~/.claude/ide`, which the fleet's CLI searches even with its own `CLAUDE_CONFIG_DIR`. No
Windows networking is involved. (Remote-WSL runs no shell startup scripts for the extension host;
that only matters for the chat panel, not for `af` in the terminal.)

**JetBrains IDE (IntelliJ, PyCharm, Rider, …).** Install the Claude Code plugin. In its settings,
set the **Claude command** to `af` — the plugin's terminal button then starts a full fleet session.
With the IDE on Windows and the fleet in WSL use `wsl -d <distro> -- bash -lic "af"`; WSL 2 in NAT
mode then needs a Windows firewall rule for the WSL subnet, or `networkingMode=mirrored` in
`.wslconfig`. Do not enable the plugin's "accept connections from all interfaces": it sends the
token in cleartext.

**Windows-side IDE, WSL fleet, any terminal.** Start `af` in WSL, type `/ide`. The CLI finds the
Windows IDE's lock under `/mnt/c/Users/<profile>/.claude/ide` and reaches its port over loopback
with mirrored networking (or a firewall rule). `afleet.bat` from a Windows terminal drops
`TERM_PROGRAM`, so auto-connect does not fire there; `/ide` does.

## How discovery works (what `af ide status` prints)

The CLI searches, in this order: `<CLAUDE_CONFIG_DIR>/ide`; `~/.claude/ide` whenever the variable
is set (an IDE started without it writes there); on WSL also every Windows profile's `.claude/ide`.
Each `<port>.lock` names the IDE, its workspace folders and a token; a lock whose port no longer
answers is **stale** (the IDE closed) and can be deleted. `af ide status` shows the dirs, each
lock's state and whether its workspace contains the current folder. The launcher never prints a
token.

## Traps

- **The IDE's chat panel and `af` in the same folder are two sessions.** The panel's bundled
  CLI is a live Claude Code process in the project, so the `af` session comes up as a
  **follower** (`SESSION_LOCKED`, worktree mode) — correct, and the panel's lock stays the panel's.
  Close the panel's session, or run the terminal session in another folder, before `af`.
- **`--ide` needs exactly one valid IDE.** Two IDEs with the folder open: `af --ide` says so and
  the CLI will not pick; use `/ide`.
- **The panel is not the fleet.** The extension's chat panel runs its own bundled CLI, which
  auto-updates and reads `~/.claude` unless told otherwise, and has no statusline, no `af`
  steps and no key injection. Keep review in the IDE, run the session in the terminal.
- **JetBrains in `acceptEdits` mode** can modify IDE configuration files the IDE executes, which
  bypasses Bash permission prompts (the plugin's own warning). Stay in Manual mode there.
- **IDE processes above the launcher do not disturb the session lock.** `af` nested in an IDE
  terminal is still classified leader: the IDE's host processes are not Claude Code processes and
  the lock's ownership proof (launcher shell as the CLI's ancestor) holds through them. Tested in
  `setup/tests/test-afleet-ide.sh` with a real process tree.

## Not in this mode (later build steps)

Per-turn snapshots with an `af review` diff opener (the Visual Studio answer), routing opened
files into the IDE, a VS Code chat-panel profile running the fleet-pinned CLI, and a Visual Studio
extension. Until then, Visual Studio users inspect through git (`devenv /Diff`, the Git Changes
window) after each turn.
