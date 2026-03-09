# Changelog

All notable changes to Agent Fleet are documented here. This follows [Keep a Changelog](https://keepachangelog.com/) conventions.

## [Unreleased] (v0.3)

### Added
- `upgrade.sh` — one-command upgrade from upstream with automatic migrations
- `migrations/` directory — version-gated migration scripts for breaking changes
- `sync.sh check` — aggregated drift/staleness check across all propagation chains
- `sync.sh check-template` — pre-publish validation (scans for personal data leaks)
- `sync.sh stamp` — refresh manifest hashes after template sync
- `.push-filter.conf` — dual-remote filtered push configuration
- `afleet` launcher — unified entry point with project picker (`setup/scripts/afleet.sh`)
- `afleet-nav` — cross-project navigation, info, and switch (`setup/scripts/afleet-nav.sh`)
- Mobile access via `sync.sh mobile-deploy` / `sync.sh mobile-collect`
- Context7 MCP server in default config
- 13 new test suites (afleet, afleet-nav, clean-pending, clean-permissions, config-check, filtered-push, git-credential-mcp, install-base, install-fixes, lrn-command, mobile, plugin-inventory, template-drift)
- `setup/vps/` — VPS bootstrap and web terminal setup
- `setup/icons/` — desktop launcher icons
- `setup/scripts/clean-permissions.sh` — removes shadowing permission blocks
- `setup/scripts/clean-pending-files.sh` — cleanup after pending file resolution
- `setup/scripts/plugin-inventory.sh` — audit installed plugins
- Knowledge files: hook-behavior, dev-browser-ops, age-encryption, fleet-capabilities, audit-protocol, vault-ops, upstream-dependencies, learn-protocol
- Statusline context meter with persona display and color coding
- Day/night mode behavioral modifier in persona system
- `lrn` self-audit quick command
- `sub <task>` delegate-to-subagent quick command
- Pending file carry-over with Action headers (present/act/triage/await-user-decision/defer)
- Placeholder convention for setup scripts (`__VARIABLE_NAME__` format)
- DMS guide for document management conventions

### Changed
- `setup.sh` is now a thin wrapper delegating to `setup/install.sh`
- `install.sh` orchestrates two phases: `install-base.sh` (system deps) + `configure-claude.sh` (MCP, hooks)
- Session protocol Rule 10 rewritten with Action-header-based pending file processing
- `config-check.sh` expanded from 13 to 24 checks (auto-heal, plugin audit, session detection)
- `sync.sh` enhanced with template-aware drift detection and personal data leak scanning
- `git-sync-check.sh` now auto-stashes uncommitted changes during pull
- Test suite expanded from 0 to 365 tests across 22 suites

### Fixed
- `hostname` binary missing on SteamOS (portable `get_hostname()` in lib.sh)
- Statusline crash on malformed/null JSON input
- `sed -i''` incompatibility with macOS BSD sed (portable wrapper)
- `timeout` command missing on macOS (portable wrapper)
- `grep -q` exit code under `pipefail` (wrapped in `if` contexts)
- `ln -sf` not replacing directories (explicit `rm -rf` before link)

### Migration (v0.3)
The `v0.3` migration runs automatically during `upgrade.sh`:
1. Extracts hostname case entries from `sync.sh` to `sync.local.sh` (gitignored)
2. Splits `personas.md` into framework defaults + `personas.local.md` (gitignored)
3. Adds gitignore entries for new local files

User customizations survive in `.local` files that are never touched by upgrades.

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
