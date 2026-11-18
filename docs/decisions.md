# Decisions & Requirements -- Agent Fleet

Last reviewed: 2026-11-18

Reviewed monthly (config-check group 26). At each review, superseded or executed entries move verbatim to `docs/decisions-archive.md`, and every entry left here is cut down to the decision and its rationale.

## Architecture & Design

### Shebang convention: `#!/usr/bin/env bash`
**Date:** 2026-02-27
**Decision:** Shell scripts start with `#!/usr/bin/env bash`. **Why:** portability to systems where bash is not at `/bin/bash` (macOS, NixOS, the BSDs).

### JSON output in hooks uses python3
**Date:** 2026-02-27
**Decision:** Hooks that emit JSON (e.g. `config-check.sh`) build it with `python3 -c "import json; ..."`, never by string concatenation. **Why:** concatenation breaks on special characters.

### Symlink architecture for global directories
**Date:** 2026-03-09 (revised 2026-11-18; original in the archive)
**Decision:** `sync.sh setup` symlinks `global/{foundation,reference,domains,knowledge,machines,skills}/` into `~/.claude/`. Hooks are not symlinked: `sync.sh deploy` copies them from `global/hooks/` with a `# MANAGED — DO NOT EDIT` header and read-only mode. **Why:** the repo is the sole authority (v1.0). Every deploy rewrites the deployed hooks, so an edit made there is lost; edit in `global/hooks/` and commit.

### setup/config/ vs global/ separation
**Date:** 2026-03-10
**Decision:** Files deployed to the `~/.claude/` root (settings.json, statusline) live in `setup/config/`; `global/` holds only `~/.claude/` subdirectories. No file lives in both. **Why:** dual copies diverge silently.

### Template personas are generic
**Date:** 2026-03-10
**Decision:** The template ships generic personas (Assistant, Supporter) and never propagates personal persona names from a private config repo. **Why:** users name their own during first-run onboarding.

### Knowledge loading is conditional, not eager
**Date:** 2026-03-10
**Decision:** Domain, reference and operational knowledge loads only when triggered (topic, error or user request); the global CLAUDE.md is a dispatcher with a trigger table. **Why:** keeps the startup token cost low.

### Least-cost-first fix hierarchy
**Date:** 2026-03-12
**Decision:** A fix from an `lrn` audit takes the cheapest tier that works: hook/script (0 tokens) > extend an existing knowledge file > new knowledge file > backlog item > project CLAUDE.md rule > global CLAUDE.md rule. Always default down the hierarchy. Canonical list: `global/skills/lrn/SKILL.md`. **Why:** a global rule costs tokens in every session; a hook costs none.

### Timestamp guard when recovering deployed files
**Date:** 2026-03-12 (revised 2026-11-18; original in the archive)
**Decision:** `sync.sh recover --emergency` (which replaced `collect`; `collect` now only forwards to it) compares each deployed file's mtime with the repo's last commit time for that file and skips the file when the repo version is newer. **Why:** a stale local copy must not overwrite work committed on another machine.

## User Requirements

### TDD is mandatory
**Date:** 2026-02-27
**Decision:** All new code follows test-driven development: failing test first, then the implementation. No exception for bash scripts, config logic or any other testable behaviour.

### Co-Authored-By trailer required on all commits
**Date:** 2026-02-27
**Decision:** Every commit made by or with Claude carries a `Co-Authored-By` trailer naming the active model (never hardcoded). A subagent that commits must be told so in its prompt. **Why:** subagents do not inherit CLAUDE.md rules.

### No speculative interactive calls
**Date:** 2026-03-09
**Decision:** Never call a user-facing prompt (passphrase dialog, confirmation, GUI input) "just to test"; call it for the real operation. **Why:** each test call doubles the user's effort.

## Conventions

### Pending file lifecycle (Action headers)
**Date:** 2026-03-09 (revised 2026-11-18; original in the archive)
**Decision:** Each `docs/pending-*.md` starts with `<!-- Action: present|act|triage|await-user-decision|defer|reference -->`; a file without one is treated as `triage`. Canonical: `global/foundation/session-protocol.md`. **Why:** the next session knows how to handle the file without reading all of it.

### Severity-differentiated stale pending-file tags
**Date:** 2026-03-12 (revised 2026-11-18; original in the archive)
**Decision:** Check 5.3 (`global/hooks/checks/05-stale-detection.sh`) flags pending files by type: `STALE_ACT` (act, 3+ days), `STALE_AWAIT` (await-user-decision, 7+ days), `STALE_DEFER` (defer, 14+ days and untracked), and a generic stale warning (2+ days with no backlog item). **Why:** different pending-file types have different acceptable lifetimes.

### Privacy scrubbing for template propagation
**Date:** 2026-03-09
**Decision:** Every file propagated from a private config repo into this public template, test files included, is scrubbed of personal data: hostnames, IPs, usernames, email addresses, private repo names. Tests use placeholder patterns. `setup/scripts/fleet-issue.sh` checks text against the privacy patterns. **Why:** the template is public.

## Installer & Upgrade

### Shell RC detection strategy
**Date:** 2026-03-12
**Decision:** `detect_shell_rc()` in `setup/lib.sh` returns `.zshrc` on macOS (zsh is the default since Catalina) and on Linux when `$SHELL` ends in `/zsh`, otherwise `.bashrc`. It never prompts.

### Upgrade rollback via git tags
**Date:** 2026-03-12 (revised 2026-11-18; original in the archive)
**Decision:** `setup/scripts/upgrade.sh` marks each upgrade with a local lightweight tag `pre-upgrade-TIMESTAMP` instead of a file-system backup; `--rollback` is `git reset --hard <tag>`. No tag is made when already up to date. **Why:** tags are cheap, and skipping the up-to-date case avoids tag clutter.

## Session Behaviour

### Memory rule: supplementary, not prohibited
**Date:** 2026-03-20
**Decision:** Auto-memory (`MEMORY.md`) is "NOT the answer" / "usually wrong", not "never". The fleet's structured files are primary for every defined knowledge type; auto-memory stays available for what they do not cover (temporary orientation, observations, cross-session hints). **Why:** an absolute ban blocked a useful safety net for uncovered cases.

### sub command: subagents do not commit
**Date:** 2026-03-20
**Decision:** The `sub` prompt says "Do NOT commit, push, or create PRs", not "Include Co-Authored-By". **Why:** the main session controls what gets committed.

### Quick commands trigger anywhere in the message
**Date:** 2026-03-20
**Decision:** Quick-command keywords (`cls`, `end`, `lsd`, …) trigger anywhere in the user's message, not only when sent alone. **Why:** allows natural use such as "push and cls".

### Persona startup: trust hook injection
**Date:** 2026-03-20
**Decision:** At startup, use the `PERSONA:` value the SessionStart hook injects; do not Read `.active-persona`. **Why:** saves two tool calls per session.

## Rejected

### Subagent file creation guardrail as a global rule
**Date:** 2026-03-12
**Decision:** Rejected as a global CLAUDE.md rule. The `sub` command prompt carries it instead: "Write artifacts to tmp/, not docs/ — return findings as text." **Why:** it then costs tokens only when `sub` is used, and the parent agent promotes artifacts as needed.
