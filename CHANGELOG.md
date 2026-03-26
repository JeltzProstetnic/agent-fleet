# Changelog

All notable changes to Agent Fleet are documented here. This follows [Keep a Changelog](https://keepachangelog.com/) conventions.

## [0.8] — 2026-03-26

**Architecture-first release.** The repo is now the single source of truth — all config flows in one direction (repo → deployed). No more bidirectional sync. Full clean-room E2E tested on Ubuntu 24.04.

### Architecture (breaking)
- **Unidirectional authority:** `sync.sh collect` removed from normal workflow, renamed to `sync.sh recover --emergency`. SessionEnd hook runs deploy only.
- **Deployed hooks are read-only:** `chmod 555` + `# MANAGED — DO NOT EDIT` header. Edit via `sync.sh edit <hook>`.
- **Template variable rendering:** `render-template.sh` handles `__DUNDER__` substitution + `#__IF_PLATFORM__` conditionals. Replaces inline sed.
- **Drift detection via git diff:** `sync.sh stamp` removed. `template-sync-manifest.md` is documentation only (no hashes).
- **Modular sync.sh:** Split from 906 lines to 93-line dispatcher + 5 modules in `sync-lib/`.

### Added
- `afleet` launcher — unified entry point with project picker
- `afleet-nav` — cross-project navigation, info, and switch
- `.githooks/pre-push` — blocks push if personal data patterns detected in template
- `render-template.sh` — pure bash template engine (~150 LOC)
- `afleet doctor` / `afleet recover` / `afleet rollback` / `afleet safe-mode` — recovery tools
- Session lock (PID-based, same-machine + cross-machine detection)
- VoltAgent subagent marketplace integration (10 bundles, per-project enablement)
- Statusline context meter with persona display and color coding
- Day/night mode behavioral modifier in persona system
- `lrn` self-audit quick command
- `sub <task>` delegate-to-subagent quick command
- DMS guide for document management conventions
- ~1,150 tests across 73 suites

### Changed
- `setup.sh` delegates to `install.sh` → `install-base.sh` (Phase 1) + `configure-claude.sh` (Phase 2) + `sync.sh setup` (Phase 3)
- `install-base.sh` installs NVM + Node.js (no system Node prerequisite)
- `configure-claude.sh` patches mclaude launcher for MCP enablement + update-checker
- macOS portability: `_readlink_f`, `_sed_i`, `_stat_mtime`, `_stat_size` via `lib-portable.sh`
- Test suite expanded from 0 to ~1,150 tests across 73 suites

### Fixed
- `((count++))` under `set -euo pipefail` returns exit 1 when count=0 — guarded with `|| true`
- `${tmpfile}` in RETURN traps unbound after function scope under `set -u`
- `require_cmd` / `require_file` / `require_dir` killed caller under `set -e` (VERBOSE && pattern)
- NVM `readonly` variable conflict with `NVM_VERSION` (renamed to `FLEET_NVM_VERSION`)
- `ensure_tool_paths` skipped NVM when system Node existed (EACCES on npm install -g)
- Launcher patching matched `^exec node` but cc-mirror native creates `exec "/path/..."` — generic match
- JSON injection in afd-lib.sh (`jq --arg` escaping)
- Duplicate check numbers in hook modules (compound numbering: 4.1, 4.2)
- Test HOME mutation (overridden to TEST_TMPDIR)
- Session lock false positive: own session detected as rival (AFLEET_SESSION_ID check)

## [0.2] — 2026-02-27

### Added
- Initial template release
- Global CLAUDE.md dispatcher with 5-layer knowledge loading
- Foundation files: user-profile, session-protocol, personas
- Domain protocols: software-development, publications, engagement, it-infrastructure
- `sync.sh` with setup, deploy, collect, status commands
- Session persistence with rotate-session.sh
- Cross-project inbox coordination
- Multi-machine sync via git
- Vault-based encrypted credential storage
- MCP server configuration templates (GitHub, Google Workspace, Twitter, Jira, PostgreSQL, LinkedIn, Serena, Playwright, Memory, Diagram)
- Skill collections installer (getsentry, obra, trailofbits)
- Security one-pager documentation
