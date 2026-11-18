# Decisions Archive -- Agent Fleet

Entries moved out of `docs/decisions.md` at a monthly review, verbatim, each with a one-line note saying why it left. Newest review first.

## Executed (review 2026-11-18)

### AFT-32 fix approach: pattern-based sed sanitization
**Archived 2026-11-18:** executed. AFT-32 is done in `backlog.md`; `setup/scripts/filtered-push.sh` has `sanitize_text()`, tested by `setup/tests/test-commit-sanitize.sh`.
**Date:** 2026-03-12
**Decision:** Filtered-push commit message leak (line 214-216) should be fixed with pattern-based sed sanitization reusing `PERSONAL_DATA_PATTERNS` from sync.sh. Chosen over config-driven patterns (overengineered), template rewriting (too aggressive), and interactive approval (poor UX). Needs tests in `test-filtered-push.sh`.

### AFT-33 fix approach: add flag to parse_common_args
**Archived 2026-11-18:** executed. AFT-33 is done in `backlog.md`; `setup/lib.sh` parses `--reconfigure-mcp` and `setup/configure-claude.sh` reads `RECONFIGURE_MCP`.
**Date:** 2026-03-12
**Decision:** `--reconfigure-mcp` flag should be handled in `parse_common_args()` in lib.sh (not configure-claude.sh directly) so it works both standalone and via install.sh. Exports `RECONFIGURE_MCP=true`, checked before early-return in `configure_mcp_servers()`.

### CI implementation order: preflight → integration → GitHub Actions
**Archived 2026-11-18:** executed. AFT-39/40/41 are done in `backlog.md`; `setup/preflight.sh` and `setup/tests/integration-test.sh` exist. The GitHub Actions workflow was later removed (commit `4fe079e`, "Disable CI workflow — tests need fixing before re-enabling").
**Date:** 2026-03-12
**Decision:** AFT-39/40/41 should be implemented in dependency order: preflight check (41) first (standalone, no Docker needed), then integration test (40, uses preflight), then GitHub Actions CI (39, orchestrates both). Matches hardening-plan.md Day 1→2→3 sequence.

## Superseded (review 2026-11-18)

### fleet-capabilities.md 3-tier grouping for template
**Archived 2026-11-18:** superseded. The grouping was propagated after all (template-push commit `f77bd8d`, 2026-04-25): `global/knowledge/fleet-capabilities.md` now has Core, Core Extended and Life OS Packages sections.
**Date:** 2026-03-12
**Decision:** Not propagated. The private cfg has a 3-tier grouping with a "Life OS packages" section. Template keeps a simpler flat structure -- Life OS is a personal deployment feature, not a generic template concept.

## Revised, original text (review 2026-11-18)

These decisions are still in force, but the mechanism or rationale they describe had changed. The revised entry is in `docs/decisions.md`; the original is kept here.

### Symlink architecture for global directories
**Archived 2026-11-18:** rationale superseded. `sync.sh collect` is a deprecated alias for `recover --emergency`, and the SessionEnd sync runs `deploy`, which rewrites the deployed hooks from the repo. The symlinked set now also includes `skills/`.
**Date:** 2026-03-09
**Decision:** `global/foundation/`, `global/reference/`, `global/knowledge/`, `global/domains/`, `global/machines/` are deployed as symlinks to `~/.claude/` subdirectories. Hooks in `global/hooks/` are copied (not symlinked) because the SessionEnd hook runs `sync.sh collect` which would create circular overwrites. This means hook edits must be committed immediately -- uncommitted changes are overwritten by collect.

### Timestamp guards for sync.sh collect
**Archived 2026-11-18:** command renamed. The guard now lives in `sync-lib/recover.sh` (`sync.sh recover --emergency`), and `collect` only forwards to it with a deprecation warning.
**Date:** 2026-03-12
**Decision:** `sync.sh collect` compares file modification times against repo commit timestamps before overwriting. If the repo version is newer (committed on another machine), the deployed file is skipped. Prevents stale local files from destroying cross-machine work. Applies to both directory copies and project-specific rules.

### Pending file lifecycle (Action headers)
**Archived 2026-11-18:** header form and action set changed. The header is now the HTML-comment form `<!-- Action: … -->` (the bare form is still parsed), and a sixth action, `reference`, exists (`global/foundation/session-protocol.md`).
**Date:** 2026-03-09
**Decision:** Pending files (`docs/pending-*.md`) use an `Action:` header line: `present`, `act`, `triage`, `await-user-decision`, or `defer`. This tells the next session exactly how to handle the file without reading the full content. Files without headers default to `triage`.

### Severity-differentiated stale file tags
**Archived 2026-11-18:** location changed. The tags are raised by check 5.3 in `global/hooks/checks/05-stale-detection.sh`, not by a "Check 17" (check 17 is now fleet updates).
**Date:** 2026-03-12
**Decision:** config-check.sh Check 17 uses `STALE_ACT` (>3 days, action files), `STALE_DEFER` (>14 days, untracked deferred files), `STALE_AWAIT` (>7 days, awaiting decision), and generic stale (>2 days, untracked) instead of a single threshold. Different pending file types have different acceptable lifetimes.

### Upgrade rollback via git tags
**Archived 2026-11-18:** rationale corrected. `setup/scripts/upgrade.sh` creates the tag locally and never runs `git push --tags`, so the claim that the tags survive across machines does not describe the script.
**Date:** 2026-03-12
**Decision:** `upgrade.sh` uses lightweight git tags (`pre-upgrade-TIMESTAMP`) for rollback points rather than file-system backups. Tags survive across machines (pushed with `git push --tags`), are cheap, and `--rollback` is just `git reset --hard <tag>`. No tag created when already up-to-date (avoids tag clutter).
