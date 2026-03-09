# Vault Operations

Operational procedures for the fleet's secret vault. The vault itself is at `~/agent-fleet/setup/secrets/vault.json.enc` (AES-256-CBC, PBKDF2, openssl). Only the config project owns the vault — no other project maintains its own secrets.

## vault-manage.sh

Location: `~/agent-fleet/setup/secrets/vault-manage.sh`

| Command | What it does |
|---------|-------------|
| `bash vault-manage.sh status` | Show vault keys (names only, no decryption) |
| `bash vault-manage.sh decrypt` | Decrypt to vault.json (prompts for password) |
| `bash vault-manage.sh deploy` | Decrypt + write tokens to MCP configs, git remotes, SSH keys |
| `bash vault-manage.sh encrypt` | Re-encrypt after edits |
| `VAULT_PASS=... bash vault-manage.sh deploy` | Non-interactive (for scripts) |

## Passphrase Collection — GUI Dialog

**Never ask the user to type the vault passphrase in chat.** The passphrase would be visible in terminal history and conversation logs.

Use a GUI dialog script to collect the passphrase via a masked input dialog (kdialog on KDE, zenity on GNOME, tkinter via WSLg on WSL). Example:
```bash
VAULT_PASS=$(bash /path/to/ask-passphrase.sh)
```

For encrypt operations (needs confirmation):
```bash
VAULT_PASS=$(bash /path/to/ask-passphrase.sh --confirm "Encrypt vault")
```

Then pass to vault-manage.sh:
```bash
VAULT_PASS="$VAULT_PASS" bash ~/agent-fleet/setup/secrets/vault-manage.sh deploy
```

**AskUserQuestion is NOT suitable for passwords.** It requires option selection (min 2 options) and has no password/masked input mode. The "Other" text field is visible. Always use the GUI dialog.

## When to Consult the Vault

When facing any credential or access issue (SSH refused, API auth failure, deploy blocked):
1. Check `vault-manage.sh status` — are there credentials for this service?
2. Check if credentials have been deployed to this machine (`vault-manage.sh deploy`)
3. Check prior session context for cross-machine deployment history
4. Only then start debugging the connection itself

## Credential Deployment Expectations

`vault-manage.sh deploy` provisions credentials to their target locations:
- GitHub tokens → `.mcp.json` env + `~/.git-credentials`
- SSH keys → `~/.ssh/` with proper permissions + config entries
- API tokens → `.mcp.json` env sections
- Other service credentials → project-specific config files

Every credential, API key, and SSH key used by the fleet MUST have a vault entry. If a secret exists only in a local file without a vault entry, that's a gap — add it.
