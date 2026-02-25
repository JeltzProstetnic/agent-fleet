# Domain Knowledge — Index

| Domain | Directory | Contains | Load when... |
|--------|-----------|----------|-------------|
| Software Development | `software-development/` | TDD protocol | Writing or modifying code |

## Adding a New Domain

1. Create directory under `~/claude-config/global/domains/`
2. Add protocol files as `.md`
3. Update this INDEX.md
4. Reference from project manifests
5. Run `bash ~/claude-config/sync.sh setup` to deploy

## Example Domains You Might Add

- Infrastructure: server management, Docker, deployment patterns
- Publications: document pipelines, LaTeX builds, content integrity
- Compliance: regulatory frameworks, audit protocols
- Data Engineering: pipeline conventions, data quality checks
