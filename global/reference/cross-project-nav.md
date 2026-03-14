# Cross-Project Navigation Protocol

**Load when:** Cross-project reference detected during a session (user mentions another project, references files outside current project, lsd dashboard switch action).

## Detection

When Claude detects a cross-project reference:
- User mentions a project name from registry.md
- User references files in `~/other-project/`
- User says "switch to X", "open X", "check X"
- lsd dashboard `switch <N>` action

## Navigation Menu

Present this menu when a cross-project reference is detected:

```
Cross-project reference detected: [project-name]

  [s] Switch  — open there in new tab, close here
  [t] Tab     — open there in new tab, keep this session
  [n] Notify  — drop a task in the inbox for that project
  [i] Ignore  — disregard the reference
```

## Execution

Use `afleet-nav.sh` for all actions:

```bash
bash ~/agent-fleet/setup/scripts/afleet-nav.sh switch <project>
bash ~/agent-fleet/setup/scripts/afleet-nav.sh tab <project>
bash ~/agent-fleet/setup/scripts/afleet-nav.sh notify <project> "message here"
bash ~/agent-fleet/setup/scripts/afleet-nav.sh info <project>
```

## Rules

- **Never auto-switch.** Always present the menu and wait for user choice.
- **Prefer notify over switch** for small tasks — cross-project inbox is the designed mechanism.
- **Cross-project boundary still applies.** Navigation is about opening the right session, not bypassing write restrictions.
- **lsd dashboard integration:** The `switch <N>` action in lsd uses `afleet-nav.sh tab` instead of ad-hoc platform logic.
