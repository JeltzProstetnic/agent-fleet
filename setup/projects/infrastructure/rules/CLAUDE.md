# Infrastructure — Network & Environment

Home lab, server, and workstation infrastructure management. Replace this line with your own estate — e.g. a home server (containers, home automation), a VPS (reverse proxy, TLS), any hosted domains, and your workstation configs.

## Knowledge Loading

| Domain | Files | Load when... |
|--------|-------|-------------|
| IT Infrastructure | `~/.claude/domains/it-infrastructure/infra-protocol.md` | Working on infrastructure tasks |
| Software Development | `~/.claude/domains/software-development/tdd-protocol.md` | Writing or modifying code (scripts, Hugo, tests) |

## Reference (load on demand, not at start)

- MCP catalog: `~/.claude/reference/mcp-catalog.md`
- Vault ops: `~/.claude/knowledge/vault-ops.md` (credential/secret operations)
- Web presence docs: `docs/web-presence.md`, `docs/email-setup.md`
- Infrastructure catalog: `docs/nuc.md`, `docs/vps.md`, `docs/network.md`

## Active Roster

- Agents: none (built-in general-purpose, Explore, Plan sufficient for infra work)
- Skills: none

## Key Files

| File | Purpose |
|------|---------|
| `session-context.md` | Current session state — **read first** |
| `backlog.md` | Prioritized task backlog |
| `docs/runbook.md` | Disaster recovery, rebuild procedures |
| `docs/secrets-registry.md` | Central credential inventory |

## Project-Specific Knowledge

- `docs/ha-inventory.md` — Home Assistant device/entity inventory
- `docs/web-presence.md` — domains, deploy method, hosting provider
- `docs/network.md` — ISP/NAT constraints, tunnels, remote access

## Cross-Project References

- Infrastructure strategy: `~/cfg-agent-fleet/cross-project/infrastructure-strategy.md`
- FMT visibility funnel: `~/cfg-agent-fleet/cross-project/fmt-visibility-strategy.md`
- Cross-project inbox: `~/cfg-agent-fleet/cross-project/inbox.md`

## Rules

- Document all infrastructure changes before and after
- Never store credentials in plain text — use encrypted vaults
- Test changes in staging/parallel before cutting over
- Website changes go through staging first (`sites/<your-domain>-staging/`)
