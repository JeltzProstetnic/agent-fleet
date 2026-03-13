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

## Decrypt→Edit→Encrypt Cycle — HARD RULES

1. **One passphrase prompt per cycle.** Collect the passphrase ONCE at the start. Hold it in a shell variable through the entire decrypt→edit→encrypt flow. Wipe (`unset`) only AFTER encryption succeeds. Never prompt a second time — re-prompting introduces typo risk and user frustration.

2. **Encryption MUST use double-entry confirmation** if (and ONLY if) the passphrase is being set fresh (not retained from decryption). Use `ask-passphrase.sh --confirm`. A single-entry typo on encryption = permanent credential loss.

3. **Retained passphrase from decrypt skips confirmation.** When the same passphrase that successfully decrypted is reused for encryption, no confirmation needed — it's already verified by the successful decryption.

4. **Passphrase lifecycle in a session:**
   ```
   PASS=$(collect passphrase)  →  decrypt with PASS  →  edit JSON  →  encrypt with PASS  →  unset PASS + delete temp files
   ```
   The variable lives for the duration of the cycle. Not longer.

5. **Platform-specific notes:** `ask-passphrase.sh` auto-detects the environment and uses the appropriate masked input method (kdialog on KDE, zenity on GNOME, tkinter on X11, PowerShell WPF on WSL). The `age` CLI does NOT work in Claude Code (needs TTY) — use openssl via vault-manage.sh.

6. **Claude Code shell isolation — CRITICAL.** Each `Bash()` call runs a separate shell — variables don't persist across calls. ALWAYS execute the full decrypt→edit→encrypt cycle in ONE `Bash()` call, chained with `&&`. The passphrase is collected once (for decrypt) and reused silently for encrypt — zero additional user interaction. Prepare complex edits (Python/jq one-liners) beforehand, then embed them in the single chain:
   ```
   VAULT_PASS=$(bash .../ask-passphrase.sh) && \
   VAULT_PASS="$VAULT_PASS" bash .../vault-manage.sh decrypt && \
   python3 -c '...' vault.json > vault.json.tmp && mv vault.json.tmp vault.json && \
   VAULT_PASS="$VAULT_PASS" bash .../vault-manage.sh encrypt && \
   rm -f vault.json
   ```
   Never split the cycle across multiple `Bash()` calls. If `ask-passphrase.sh` fails, investigate and fix it — don't improvise manual dialogs.

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
