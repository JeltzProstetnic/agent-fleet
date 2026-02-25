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

<!-- No tasks currently -->
