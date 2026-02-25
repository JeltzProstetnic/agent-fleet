# Domain Knowledge — Index

| Domain | Directory | Contains | Load when... |
|--------|-----------|----------|-------------|
| Software Development | `software-development/` | TDD protocol | Writing or modifying code |
| Publications | `publications/` | Publication workflow, test-driven authoring | Authoring, editing, building publications |
| Engagement | `engagement/` | Twitter/X engagement protocol | Social media engagement |
| IT Infrastructure | `it-infrastructure/` | Infra protocol (servers, Docker, DNS, smart home) | Infrastructure work (servers, VPS, deployment) |

## Adding a New Domain

1. Create directory under `~/claude-config/global/domains/`
2. Add protocol files as `.md`
3. Update this INDEX.md
4. Reference from project manifests
5. Run `bash ~/claude-config/sync.sh setup` to deploy
