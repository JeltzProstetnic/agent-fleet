# Placeholder Convention

All template placeholders use **double-underscore** (dunder) format: `__VARIABLE_NAME__`

## Standard Placeholders

| Placeholder | Where used | Description |
|-------------|-----------|-------------|
| `__YOUR_NAME__` | bootstrap, setup | User's full name |
| `__YOUR_EMAIL__` | bootstrap, setup, infra, secrets.env | User's email address |
| `__YOUR_DOMAIN__` | infra-protocol | User's domain name |
| `__GITHUB_USERNAME__` | bootstrap, vault | GitHub username |
| `__GITHUB_TOKEN__` | configure-claude, vault | GitHub PAT |
| `__GOOGLE_CLIENT_ID__` | configure-claude, vault | Google OAuth client ID |
| `__GOOGLE_CLIENT_SECRET__` | configure-claude, vault | Google OAuth client secret |
| `__GOOGLE_EMAIL__` | configure-claude, vault | Google account email |
| `__TWITTER_API_KEY__` | configure-claude, vault | Twitter API key |
| `__TWITTER_API_SECRET__` | configure-claude, vault | Twitter API secret key |
| `__TWITTER_ACCESS_TOKEN__` | configure-claude, vault | Twitter access token |
| `__TWITTER_ACCESS_SECRET__` | configure-claude, vault | Twitter access token secret |
| `__JIRA_URL__` | configure-claude | Jira instance URL |
| `__JIRA_USERNAME__` | configure-claude | Jira username/email |
| `__JIRA_API_TOKEN__` | configure-claude | Jira API token |
| `__POSTGRES_URL__` | configure-claude | PostgreSQL connection URL |
| `__VPS_IP__` | setup-web-terminal, infra-protocol | VPS IP address |
| `__WEB_TERMINAL_DOMAIN__` | setup-web-terminal | Domain for web terminal |
| `__WSL_MACHINE__` | infra-protocol | WSL machine identifier |
| `__HOME__` | configure-claude, settings.json | User's home directory (auto-detected) |
| `__NPX_CMD__` | configure-claude | Path to npx (auto-detected) |
| `__UVX_CMD__` | configure-claude | Path to uvx (auto-detected) |
| `__SERENA_CMD__` | configure-claude | Path to Serena command (auto-detected) |
| `__JIRA_CMD__` | configure-claude | Path to Jira MCP command (auto-detected) |
| `__PATH__` | configure-claude | Safe PATH string (auto-detected) |
| `__USERNAME__` | publication-workflow | System username for paths |
| `__PROJECT__` | publication-workflow | Project directory name |

## Rules

1. Always UPPERCASE with underscores between words
2. Always surrounded by double underscores
3. Auto-detected values (HOME, NPX_CMD, etc.) are substituted by scripts at setup time
4. User-provided values are prompted during setup or left as markers for manual replacement

## Exception: human-facing docs

README.md and getting-started.md use plain `YOUR_USERNAME` / `YOUR_REPO_URL` instead of dunders. These are read by humans on GitHub, not processed by scripts. Keep them readable.
