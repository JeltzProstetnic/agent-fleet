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
