# Machine-Specific Knowledge — Index

Per-machine operational state: installed tooling, applied patches, auth state, known issues.

## How It Works

1. At session start, after hostname detection, load `~/.claude/machines/<machine>.md` if it exists
2. File path mapping is defined in global CLAUDE.md (Machine Identity section)
3. During sessions, if machine state changes (tooling installed, patches applied, auth rotated), note it for shutdown update
4. At shutdown, update the machine file if state changed (step 5 in Session Shutdown Checklist)
5. Files sync to all machines via git — any machine can read any other's state

## Files

| File | Machine | Status |
|------|---------|--------|
| `_template.md` | (template for new machines) | — |

## Adding a New Machine

1. Copy `_template.md` to `<machine-name>.md` (use a simple, stable identifier like `vps`, `home-fedora`, `office-mac`)
2. Fill in the Identity section (hostname pattern, platform, user)
3. Add an entry to the hostname detection table in `global/CLAUDE.md` Machine Identity section
4. Update the mapping in step 1 of Loading Protocol
5. Populate tooling/patches/auth as you work on that machine
6. Keep the template version generic — strip personal account names and specific paths
