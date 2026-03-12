# Template Sync Manifest

Tracks expected state of files shared between template (`~/agent-fleet/`) and personal config repos.
Used by `sync.sh check` to detect template drift and by `sync.sh stamp` to refresh hashes.

When a hash changes: review the diff, propagate changes, then run `sync.sh stamp` to update.

## Tracked Files — Must Be Identical

These files have NO personal content and should be byte-identical between repos.

| File | Hash (CRC32, python binascii) | Date |
|------|------|------|
| `setup/lib.sh` | `11109742` | 2026-03-12 |
| `setup/install-base.sh` | `b7a1060a` | 2026-03-12 |
| `setup/install.sh` | `f175d82e` | 2026-03-12 |
| `setup/configure-claude.sh` | `c22ea264` | 2026-03-12 |
| `setup/scripts/rotate-session.sh` | `76ed1761` | 2026-03-12 |
| `setup/scripts/git-sync-check.sh` | `506e481e` | 2026-03-12 |
| `setup/scripts/clean-marketplace-plugins.sh` | `66c73114` | 2026-03-12 |
| `setup/scripts/clean-permissions.sh` | `ae0200b6` | 2026-03-12 |
| `global/reference/cross-project-rules.md` | `0e9db0c2` | 2026-03-12 |
| `global/reference/output-rules.md` | `7e86e3fb` | 2026-03-12 |
| `global/foundation/session-protocol.md` | `85db0981` | 2026-03-12 |

## Tracked Files — Intentional Diffs

These files are expected to differ between template and personal repos.
Hash tracks the template version. When it changes, propagate structural improvements to personal repo.

| File | Hash (CRC32, python binascii) | Diff reason |
|------|------|-------------|
| `global/CLAUDE.md` | `a9db140f` | Template: generic examples, no machine table. Personal: real hostnames, MCP routing, personal triggers. |
| `global/foundation/user-profile.md` | `8dca2c23` | Template: placeholder. Personal: real identity. |
| `global/foundation/personas.md` | `a80149fb` | Template: Assistant + Supporter (generic). Personal: custom personas. |
| `global/foundation/INDEX.md` | `0955303f` | Template: generic persona names. Personal: custom names. |
| `global/reference/mcp-catalog.md` | `91c01946` | Template: generic setup guide. Personal: real accounts + servers. |
| `global/hooks/config-auto-sync.sh` | `1d22fdd9` | Template: _detect_config_repo() auto-detect. Personal: may hardcode path. |
| `global/hooks/config-check.sh` | `8b87b4ef` | Template: _detect_config_repo() auto-detect. Personal: may use $CONFIG_REPO. |
| `sync.sh` | `eaae07ea` | Template: example hostnames, no leak check. Personal: real hostnames + leak patterns. |
| `setup/config/settings.json` | `7bfa5ab4` | Template: base MCP set. Personal: extra servers, tips disabled. |
| `setup/config/statusline-command.sh` | `f9f582c8` | Template: generic personas. Personal: custom persona colors. |
| `setup/config/mcp.json.template` | `16383ed6` | Template: memory + context7. Personal: may differ. |
| `setup/scripts/git-credential-mcp` | `44604cfe` | Template: configurable SECONDARY vars. Personal: hardcoded accounts. |
| `global/knowledge/INDEX.md` | `63408d0c` | Template: generic entries only. Personal: extra tool-specific entries. |
| `setup/config/settings.local.json` | `be015f0b` | Template: base deny set. Personal: extra entries. |
| `setup/scripts/install-skill-collections.sh` | `b6f5fddf` | Repo name in comments differs. |
| `setup/scripts/filtered-push.sh` | `d270475e` | Repo name in usage comment differs. |
| `setup/scripts/lsd-refresh.sh` | `fe1d4d7d` | Repo name + hardcoded paths differ. |
| `global/reference/lsd-spec.md` | `1f09082b` | Template: anonymized examples. Personal: real project names. |
| `global/knowledge/claude-code-permissions.md` | `a6b2269a` | Template: generalized cross-platform. Personal: platform-specific detail. |
| `global/knowledge/mcp-deployment.md` | `88730030` | Template: generalized. Personal: platform-specific examples. |
| `global/knowledge/plan-mode-issues.md` | `2d401629` | Template: generic. Personal: specific dates, MCP lists. |

## Last Updated

2026-03-12 — Initial creation with CRC32 hashes for all tracked files. 11 identical + 21 intentional-diff files.
