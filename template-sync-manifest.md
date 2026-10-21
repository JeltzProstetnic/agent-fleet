# Template Sync Manifest

Tracks expected state of files shared between template (`~/agent-fleet/`) and personal config repos.
Used by `sync.sh check`, which diffs each file directly against its counterpart — this file is documentation, it stores no hashes (`sync.sh stamp` is gone).

## Tracked Files — Must Be Identical

These files have NO personal content and should be byte-identical between repos.

| File | Note |
|------|------|
| `setup/lib.sh` | Generic. |
| `setup/install-base.sh` | Generic. |
| `setup/install.sh` | Generic. |
| `setup/configure-claude.sh` | Generic. |
| `setup/scripts/rotate-session.sh` | Generic. |
| `setup/scripts/git-sync-check.sh` | Generic. |
| `setup/scripts/clean-marketplace-plugins.sh` | Generic. |
| `setup/scripts/clean-permissions.sh` | Generic. |
| `global/reference/cross-project-rules.md` | Generic. |
| `global/reference/output-rules.md` | Generic. |
| `global/foundation/session-protocol.md` | Generic. |
| `sync.sh` | Modular sync, identical to the reference fleet since 2026-10-21 (CFG-700). |
| `sync-lib/common.sh` | Modular sync, identical to the reference fleet since 2026-10-21 (CFG-700). |
| `sync-lib/check.sh` | Modular sync, identical to the reference fleet since 2026-10-21 (CFG-700). |
| `sync-lib/pre-deploy.sh` | Modular sync, identical to the reference fleet since 2026-10-21 (CFG-700). |
| `sync-lib/deploy.sh` | Modular sync, identical to the reference fleet since 2026-10-21 (CFG-700). |
| `sync-lib/setup.sh` | Modular sync, identical to the reference fleet since 2026-10-21 (CFG-700). |
| `sync-lib/recover.sh` | Modular sync, identical to the reference fleet since 2026-10-21 (CFG-700). |
| `sync-lib/status.sh` | Modular sync, identical to the reference fleet since 2026-10-21 (CFG-700). |

## Tracked Files — Intentional Diffs

These files are expected to differ between template and personal repos.
When one changes, propagate structural improvements by hand.

| File | Diff reason |
|------|-------------|
| `global/CLAUDE.md` | Template: generic examples, no machine table. Personal: real hostnames, MCP routing, personal triggers. |
| `global/foundation/user-profile.md` | Template: placeholder. Personal: real identity. |
| `global/foundation/personas.md` | Template: Assistant + Supporter (generic). Personal: custom personas. |
| `global/foundation/INDEX.md` | Template: generic persona names. Personal: custom names. |
| `global/reference/mcp-catalog.md` | Template: generic setup guide. Personal: real accounts + servers. |
| `global/hooks/config-auto-sync.sh` | Template: _detect_config_repo() auto-detect. Personal: may hardcode path. |
| `global/hooks/config-check.sh` | Template: _detect_config_repo() auto-detect. Personal: may use $CONFIG_REPO. |
| `setup/config/settings.json` | Template: base MCP set. Personal: extra servers, tips disabled. |
| `setup/config/statusline-command.sh` | Template: generic personas. Personal: custom persona colors. |
| `setup/config/mcp.json.template` | Template: memory + context7. Personal: may differ. |
| `setup/scripts/git-credential-mcp` | Template: configurable SECONDARY vars. Personal: hardcoded accounts. |
| `global/knowledge/INDEX.md` | Template: generic entries only. Personal: extra tool-specific entries. |
| `setup/config/settings.local.json` | Template: base deny set. Personal: extra entries. |
| `setup/scripts/install-skill-collections.sh` | Repo name in comments differs. |
| `setup/scripts/filtered-push.sh` | Repo name in usage comment differs. |
| `setup/scripts/lsd-refresh.sh` | Repo name + hardcoded paths differ. |
| `global/reference/lsd-spec.md` | Template: anonymized examples. Personal: real project names. |
| `global/knowledge/claude-code-permissions.md` | Template: generalized cross-platform. Personal: platform-specific detail. |
| `global/knowledge/mcp-deployment.md` | Template: generalized. Personal: platform-specific examples. |
| `global/knowledge/plan-mode-issues.md` | Template: generic. Personal: specific dates, MCP lists. |

## Last Updated

2026-10-21 — Hash columns dropped (drift is a direct diff); modular `sync.sh` + `sync-lib/` moved to Must Be Identical (CFG-700).
2026-03-12 — Initial creation.
