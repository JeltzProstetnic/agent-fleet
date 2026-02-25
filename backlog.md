# Backlog — claude-config-template

## Active

_(nothing in progress)_

## Queued

- [ ] **Project prioritization system**: Design a priority scheme so ai2do can list top TODOs across projects, ranked by (1) project priority and (2) per-project task priority. Needs: priority field in `registry.md` per project, priority field per task in each project's backlog, ai2do integration spec to read and merge these. This is a claude-config responsibility to define the schema.

## Done

- [x] **Secrets scaffold**: Added `secrets/` with `vault-manage.sh`, `vault.json.example`, and `.gitignore` that tracks scaffold but ignores actual secrets. Adapted from claude-config's vault system with placeholder-detection in deploy.
