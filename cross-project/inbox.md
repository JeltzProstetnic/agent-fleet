# Cross-Project Inbox

One-off tasks passed between projects and machines. Tasks are picked up by the target project and deleted after integrating.

## Format

```
## [project-name]
- [ ] [Task description]
  Context: [Any relevant detail Claude needs to act on this]
  From: [source project or machine, optional]
```

## Usage Rules

- One entry per target project (not broadcasts)
- Claude picks up tasks for the current project, integrates them, then deletes the entry
- Never write directly into another project's files — drop a task here instead
- Keep entries short; link to files for detail

---

## agent-fleet
- [ ] **Commit and push vault.json.enc**: The gitignore fix to allowlist `vault.json.enc` has been committed from the Deck. Pull it, then `git add secrets/vault.json.enc && git commit -m "Add encrypted vault for cross-machine token deployment" && git push`. After that, the Deck can `git pull && bash secrets/vault-manage.sh deploy`.
  From: SteamDeckBedroom
- [ ] **Fix `~/.claude/machines/` symlink structure on Deck**: `sync.sh setup` created `~/.claude/machines/` as a regular directory containing a single recursive symlink (`machines -> /home/deck/agent-fleet/global/machines`). The machine files (e.g. `SteamDeckBedroom.md`) are not accessible at `~/.claude/machines/SteamDeckBedroom.md`. Expected: either the directory itself is a symlink to `global/machines/`, or individual files are symlinked. The `@import` in `CLAUDE.local.md` fails silently because the path doesn't resolve.
  From: SteamDeckBedroom
- [ ] **Fix recursive symlinks in `global/` subdirectories**: `sync.sh setup` created circular symlinks inside `global/domains/`, `global/foundation/`, `global/knowledge/`, `global/machines/`, and `global/reference/` — each contains a symlink named after itself pointing back to the repo path (e.g. `global/domains/domains -> /home/deck/agent-fleet/global/domains`). These show up as untracked files in `git status` and indicate a bug in the setup script's symlink logic. Likely cause: the script symlinks the target directory *into* itself instead of symlinking it *from* `~/.claude/`.
  From: SteamDeckBedroom
