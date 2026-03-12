# Contributing to Agent Fleet

## Getting Started

1. Fork the repo and clone it
2. Run `bash setup.sh` to set up your environment
3. Run `bash setup/tests/run.sh` to verify all tests pass

## Development Rules

### Test-Driven Development

All changes must include tests. Write failing tests first, then implement.

- Test files go in `setup/tests/test-<name>.sh`
- Source the test helpers: `source "$(dirname "$0")/test-helpers.sh"`
- Use the provided assertion functions: `assert_eq`, `assert_contains`, `assert_file_exists`, etc.
- Run a single suite: `bash setup/tests/test-<name>.sh`
- Run all suites: `bash setup/tests/run.sh`

### Shell Scripts

- Shebang: `#!/usr/bin/env bash`
- Always `set -euo pipefail`
- Use `git -C <path>` instead of `cd <dir> && git ...`
- Use absolute paths where possible
- No compound `cd` commands -- they trigger security prompts in Claude Code

### File Organization

| Content type | Location |
|-------------|----------|
| Files deployed to `~/.claude/` root | `setup/config/` |
| Files deployed to `~/.claude/` subdirectories | `global/` (symlinked) |
| Session hooks | `global/hooks/` (copied, not symlinked) |
| Operational scripts | `setup/scripts/` |
| Tests | `setup/tests/` |
| Documentation | `docs/` |

### Commits

- Include a `Co-Authored-By` trailer if working with an AI assistant
- Keep commit messages concise and focused on the "why"

### Privacy

The template must not contain personal data. Before submitting:

- No real hostnames, IPs, or usernames
- No email addresses or private repo names
- Use placeholder patterns (e.g., `YOUR_USERNAME`, `your-hostname`)
- Run `bash sync.sh check-template` to scan for leaks

### What Not to Change

- `*.local.*` files are user-specific and gitignored
- `registry.md` and `backlog.md` are user data, not framework code
- Machine files in `global/machines/` are templates -- don't add real machine configs

## Pull Requests

- Keep PRs focused on a single change
- Include test output showing all suites pass
- If adding a new script, add a corresponding test suite
- If adding a knowledge file, add a conditional trigger in `global/CLAUDE.md`

## Questions

Open an issue on GitHub.
