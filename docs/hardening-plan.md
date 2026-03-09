# Deployment Hardening Plan — 3-Day Sprint

Created: 2026-03-01
Updated: 2026-03-09
Status: Partially implemented

## Problem Statement

25+ shell scripts, ~6000 lines, 80+ external commands, 50+ hardcoded paths, 5 platform families. Originally had zero automated tests — now has **365 tests across 22 suites** covering session rotation, config sync, dashboard, permissions, filtered push, mobile deploy, and more. Portable command wrappers (`get_hostname()`, `portable_sed_i()`, `portable_timeout()`) implemented in `lib.sh`. Remaining items below focus on CI/CD and Docker-based cross-platform validation.

### Bugs Found by Running (Not Reading)
- `hostname` binary missing on SteamOS (BUG-1, fixed)
- Statusline `input_tokens` is 1, not total context (BUG-2, fixed)
- `grep -q` returns exit 1 under `pipefail` (fixed previously)
- `ln -sf` doesn't replace directories, only files (fixed previously)
- `sed -i''` incompatible with macOS BSD sed (BUG-5, fixed)
- `timeout` command missing on macOS (BUG-6, fixed)
- `uvx` not installed on SteamOS — MCP servers fail (BUG-2b, documented)
- `pip install` blocked on SteamOS externally-managed Python (BUG-3, documented)
- Statusline crashes on malformed/null JSON (BUG-4, fixed)

## Day 1: Automated Validation Infrastructure

### 1a. Platform Smoke Tests via Docker

Create `tests/` directory with:
```
tests/
  Dockerfile.ubuntu-24.04
  Dockerfile.debian-12
  Dockerfile.fedora-42
  Dockerfile.arch
  smoke-test.sh          # Runs inside each container
  validate-commands.sh   # Checks every command used in scripts exists
  validate-paths.sh      # Checks every hardcoded path is creatable
  run-all.sh             # Builds containers, runs tests, reports
```

Each Dockerfile:
- Installs base packages for that distro
- Copies setup/ directory
- Runs smoke-test.sh which exercises:
  - `lib.sh` sourcing + all utility functions
  - `detect_distro()` returns correct family
  - `get_hostname()` works
  - `is_steamos()` / `is_wsl()` return correct values
  - `check_pkg_installed()` works for that distro's package manager
  - `install-base.sh --dry-run` completes without errors
  - `configure-claude.sh --dry-run` completes without errors

macOS cannot be Dockerized — use GitHub Actions macOS runner.

### 1b. Pre-flight Check (`setup/preflight.sh`)

Runs BEFORE any install script. Checks:
- Every required command exists in PATH (platform-specific list)
- Required paths are writable (`$HOME`, `$HOME/.local/bin`, etc.)
- Network connectivity (can reach github.com, registry.npmjs.org)
- Disk space (>1GB free in $HOME)
- Platform detection (human-readable report)
- Clear, actionable error messages for every failure
- Exit 0 = all clear, exit 1 = problems found with fix instructions

This is the "corporate demo safety net."

### 1c. Portable Command Wrappers in lib.sh

Add functions for every command that varies across platforms:
- `get_hostname()` — already done
- `portable_sed_i()` — handles GNU vs BSD sed
- `portable_timeout()` — handles missing timeout on macOS
- `portable_sha256()` — already handled

## Day 2: Fix All Known Bugs + Integration Testing

### Remaining Bugs to Fix
- [ ] Install `uv`/`uvx` on SteamOS (or detect and warn about missing MCP servers)
- [ ] Document `pip install` blocked on SteamOS (pipx is the path)
- [ ] `configure-claude.sh` RETURN trap overwrite (BUG-9, temp file leak)
- [ ] Deduplicate hostname fallback (3 scripts have inline copies of get_hostname)
- [ ] `file_contains()` in lib.sh is a latent trap if called outside `if` context

### Integration Test Script (`tests/integration-test.sh`)
- Full install.sh + setup.sh on a clean Docker container
- Verify mclaude launches
- Verify MCP config is valid JSON
- Verify symlinks point to correct targets
- Verify .bashrc modifications are idempotent (run twice, same result)

## Day 3: CI + Corporate Readiness

### GitHub Actions CI (`.github/workflows/platform-tests.yml`)
- Run smoke tests on: ubuntu-latest, ubuntu-24.04, macos-latest, macos-14
- Fedora via Docker action
- Triggered on push to main and PRs
- Badge in README

### Corporate Readiness Checklist
- [ ] README quick-start: per-platform, copy-pasteable, no ambiguity
- [ ] Error messages audit: every `exit 1` gets human-readable context
- [ ] Idempotency sweep: every script safe to run twice
- [ ] One-command install for demos
- [ ] `preflight.sh` runs automatically before install (opt-out, not opt-in)

## Platform Coverage Matrix

| Platform | Docker Test | CI Runner | Notes |
|----------|------------|-----------|-------|
| Ubuntu 24.04 | Yes | GitHub Actions | Primary target |
| Debian 12 | Yes | — | |
| Fedora 42 | Yes (Docker) | — | |
| Arch Linux | Yes | — | |
| SteamOS | — (no Docker) | — | Immutable FS, manual testing only |
| macOS (ARM) | — | GitHub Actions | |
| macOS (Intel) | — | GitHub Actions | |
| WSL | — | — | Runs inside Ubuntu, shares apt path |
| Windows (native) | — | — | Not supported (WSL required) |

## Known Gaps That Won't Be Covered
- SteamOS can't be Dockerized (immutable FS, pacman keyring)
- macOS testing limited to CI runners (no local Mac)
- iPad is not macOS — different ecosystem entirely
- Windows native is out of scope (WSL is the supported path)
