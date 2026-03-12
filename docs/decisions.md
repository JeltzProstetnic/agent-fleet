# Decisions & Requirements -- Agent Fleet

## Architecture & Design

### Shebang convention: `#!/usr/bin/env bash`
**Date:** 2026-02-27
**Decision:** All shell scripts use `#!/usr/bin/env bash` for portability (macOS, NixOS, BSDs where bash is not at `/bin/bash`).

### JSON output in hooks uses python3
**Date:** 2026-02-27
**Decision:** Hooks that emit JSON (e.g., config-check.sh) use `python3 -c "import json; ..."` instead of manual string concatenation, preventing escaping bugs with special characters.

### Symlink architecture for global directories
**Date:** 2026-03-09
**Decision:** `global/foundation/`, `global/reference/`, `global/knowledge/`, `global/domains/`, `global/machines/` are deployed as symlinks to `~/.claude/` subdirectories. Hooks in `global/hooks/` are copied (not symlinked) because the SessionEnd hook runs `sync.sh collect` which would create circular overwrites. This means hook edits must be committed immediately -- uncommitted changes are overwritten by collect.

### setup/config/ vs global/ separation
**Date:** 2026-03-10
**Decision:** Files deployed to `~/.claude/` root (settings.json, statusline.sh) belong in `setup/config/`. `global/` is for `~/.claude/` subdirectories only (foundation/, reference/, knowledge/, domains/, hooks/). No file should exist in both -- dual copies diverge silently.

### Template personas are generic
**Date:** 2026-03-10
**Decision:** Template ships with generic persona names (Assistant/Supporter) rather than personal ones. Users customize during first-run onboarding. Personal persona names in the private cfg-agent-fleet repo are not propagated.

### Knowledge loading is conditional, not eager
**Date:** 2026-03-10
**Decision:** Domain knowledge, reference files, and operational knowledge load only when triggered (by topic, error, or user request). This keeps startup token cost low (~18-28% of 200k context). The global CLAUDE.md acts as a dispatcher with a trigger table.

### 5-tier fix hierarchy (least-cost-first)
**Date:** 2026-03-12
**Decision:** When fixing issues found during `lrn` audits, prefer the cheapest tier: (1) hook/script (0 tokens), (2) extend existing knowledge file (0 tokens unless triggered), (3) new knowledge file, (4) backlog item, (5) project CLAUDE.md rule, (6) global CLAUDE.md rule (most expensive -- tokens every session). Bias check mandatory: always default DOWN the hierarchy.

### Timestamp guards for sync.sh collect
**Date:** 2026-03-12
**Decision:** `sync.sh collect` compares file modification times against repo commit timestamps before overwriting. If the repo version is newer (committed on another machine), the deployed file is skipped. Prevents stale local files from destroying cross-machine work. Applies to both directory copies and project-specific rules.

## User Requirements

### TDD is mandatory
**Date:** 2026-02-27
**Decision:** All new code must follow test-driven development. Write failing tests first, then implement. No exceptions for bash scripts, config logic, or any testable behavior. Currently 365+ tests across 22 suites.

### Co-Authored-By trailer required on all commits
**Date:** 2026-02-27
**Decision:** Every git commit made by or with Claude must include a `Co-Authored-By` trailer. The model name is not hardcoded -- uses whatever model is active. Subagents must be explicitly told to include it since they don't inherit CLAUDE.md rules.

### No speculative interactive calls
**Date:** 2026-03-09
**Decision:** Never call user-facing prompts (passphrase dialogs, confirmations, GUI input) "just to test." Use them directly for the real operation. Each test call doubles user effort.

## Conventions

### Pending file lifecycle (Action headers)
**Date:** 2026-03-09
**Decision:** Pending files (`docs/pending-*.md`) use an `Action:` header line: `present`, `act`, `triage`, `await-user-decision`, or `defer`. This tells the next session exactly how to handle the file without reading the full content. Files without headers default to `triage`.

### Severity-differentiated stale file tags
**Date:** 2026-03-12
**Decision:** config-check.sh Check 17 uses `STALE_ACT` (>3 days, action files), `STALE_DEFER` (>14 days, untracked deferred files), `STALE_AWAIT` (>7 days, awaiting decision), and generic stale (>2 days, untracked) instead of a single threshold. Different pending file types have different acceptable lifetimes.

### Privacy scrubbing for template propagation
**Date:** 2026-03-09
**Decision:** All files propagated from the private cfg-agent-fleet to the public agent-fleet template must be scrubbed of personal data: hostnames, IPs, usernames, email addresses, private repo names. fleet-issue.sh provides automated privacy pattern checking. Test files must also be scrubbed (use placeholder patterns instead of real personal data).

## Rejected / Superseded

### Subagent file creation guardrail (global rule)
**Date:** 2026-03-12
**Decision:** Rejected as a global CLAUDE.md rule. Instead, the `sub` command template includes "Write artifacts to tmp/, not docs/ -- return findings as text." This is cheaper (only costs tokens when `sub` is used) and the parent agent promotes artifacts as needed.

### fleet-capabilities.md 3-tier grouping for template
**Date:** 2026-03-12
**Decision:** Not propagated. The private cfg has a 3-tier grouping with a "Life OS packages" section. Template keeps a simpler flat structure -- Life OS is a personal deployment feature, not a generic template concept.
