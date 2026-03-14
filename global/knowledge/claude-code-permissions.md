# Claude Code Permissions — Known Issues & Best Practices

## The settings.local.json Override Problem

**Root cause:** When Claude Code prompts "Allow this tool?" and the user clicks "Allow", it appends the specific command pattern to the project's `.claude/settings.local.json` under `permissions.allow`. This creates a **project-level** permissions block that **completely replaces** the global `settings.json` permissions — it does NOT merge with or extend the global list.

**Symptom:** After a few sessions in a project, the `settings.local.json` accumulates random one-off approvals (e.g., `Bash(cat:*)`, `Bash(echo === grep -q:*)`) but is missing critical entries from the global config (e.g., `Bash(git:*)`, `Bash(du:*)`). This causes the shutdown checklist and common operations to prompt for permission every time.

**Fix:** Remove the entire `permissions` block from `settings.local.json`. The global `settings.json` (at `~/.cc-mirror/mclaude/config/settings.json`) has comprehensive auto-approvals that cover all standard operations.

**Prevention:**
1. When prompted to allow a tool in any project, prefer "Allow for this session" over "Always allow" to avoid polluting `settings.local.json`
2. If a command should be permanently allowed, add it to the global `settings.json` instead
3. The `config-check.sh` hook should detect and warn about permission blocks in project settings

**Which file controls what:**
| File | Scope | Override behavior |
|------|-------|-------------------|
| `~/.cc-mirror/mclaude/config/settings.json` | Global (all projects) | Base permissions |
| `<project>/.claude/settings.local.json` | One project | **REPLACES** global permissions if `permissions` key exists |
| `<project>/.claude/settings.json` | One project (committed) | Same override behavior |

**Key insight:** `settings.local.json` should ONLY contain project-specific MCP server configuration (`enabledMcpjsonServers`, `enableAllProjectMcpServers`). It should NEVER have a `permissions` block unless you intentionally want to restrict that project's permissions below the global baseline.

## First-Word Matching Rule

**Root cause:** Claude Code's `Bash(command:*)` permission patterns match against the **first word** of the command string only. A command like `KONSOLE_SVC="value" && qdbus ...` starts with `KONSOLE_SVC`, not `qdbus` — so `Bash(qdbus:*)` does NOT match.

**Common mistakes:**
| Command pattern | First word | Matches `Bash(qdbus:*)`? |
|----------------|-----------|--------------------------|
| `qdbus org.kde.konsole-123 ...` | qdbus | Yes |
| `KONSOLE_SVC="..." && qdbus ...` | KONSOLE_SVC | **No** |
| `sleep 2 && qdbus ...` | sleep | **No** |

**Fix:** Always start Bash tool commands with the actual command, never with variable assignments or delays. Use separate tool calls instead of chaining with `&&`.

**Adding missing commands:** If a command is frequently used but not in the global permissions, add `Bash(command:*)` to `settings.json` — don't rely on project-level approvals (they cause the settings.local.json override problem described above).

## Long git commit Messages with Multiple -m Flags

**Symptom:** `git -C <path> commit -m "..." -m "..." -m "..."` prompts for permission even though `Bash(git:*)` is in global permissions.

**Root cause:** Under investigation. Hypothesis: either the total command length exceeds some internal threshold, or the multiple quoted strings with special characters (parentheses, dashes, colons) confuse the permission matcher. Observed with 8 `-m` flags totaling ~600 chars.

**Workaround:** Unknown — the `-m` flag approach was itself a workaround for the HEREDOC `$()` and temp file `/tmp/` permission issues. The occasional permission prompt on long commit messages may be unavoidable. If it becomes frequent, investigate whether a shorter commit message (fewer `-m` flags) avoids the prompt.

**Status:** Needs deeper investigation. Track whether this reproduces across platforms.

## Compound Command Permission Problem

**Root cause:** Bash permissions use prefix matching. `Bash(cd:*)` and `Bash(git:*)` individually don't cover compound commands like `cd ~/project && git status`. The compound command is evaluated as a whole string, and `cd ~/project && git status` starts with `cd` but Claude Code's security layer flags it as a compound command with `&&` — triggering the "bare repository attacks" safety warning regardless of individual permissions.

**Fix — avoid compound commands in automation:** When Claude needs to run git commands in another directory, use `git -C <path>` instead of `cd <path> && git`:
- Instead of: `cd ~/social && git status` → Use: `git -C ~/social status`
- Instead of: `cd ~/project && git add . && git commit` → Use: `git -C ~/project add . && git -C ~/project commit`

**Behavioral rule for Claude:** NEVER use `cd <dir> && <command>` patterns. Use `-C` flags, absolute paths, or `--work-tree`/`--git-dir` for git. For non-git commands, use absolute paths directly.

## Auto-Clean: Permissions Block Removal

Stale permissions blocks are cleaned at **three points**:
1. **SessionStart** (config-check.sh Check 10) — clean for the new session
2. **Shutdown checklist step 0** — agent runs `clean-permissions.sh` before git operations
3. **SessionEnd hook** (config-auto-sync.sh Phase 0) — final sweep before auto-commit

All three call the shared script `setup/scripts/clean-permissions.sh`, which:
1. Scans all `~/*/.claude/settings.local.json` files (maxdepth 3)
2. If a `"permissions"` key is found, removes it silently (keeping all other config)
3. Reports how many files were cleaned (silent if none)

**Why three points?** Startup cleanup only protects the new session. If a user clicks "Always allow" mid-session, the permissions block shadows global permissions immediately. The shutdown cleanup (both agent-driven step 0 and hook Phase 0) ensures the shutdown sequence itself doesn't get hit with prompts. Belt, suspenders, and a safety pin.

## Disabling Tips — TWO Separate Settings

Claude Code has two independent tip/suggestion systems. Both must be disabled in `settings.json`:

| Setting | Location | Controls |
|---------|----------|----------|
| `"spinnerTipsEnabled": false` | Top-level key | Tips shown in the spinner while Claude thinks |
| `"CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION": "0"` | `env` block | Greyed-out prompt suggestions in the input field |

**Common mistake:** Setting only one of these and thinking tips are fully disabled. They are different features with different config mechanisms. The env var is a string `"0"`, the other is a boolean `false`.

**Settings path:** Check your launcher's config directory for `settings.json`. Fixes applied to the wrong path are silently ignored.
