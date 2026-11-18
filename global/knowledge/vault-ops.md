# Vault Operations

Operational procedures for the fleet's secret vault. The vault itself is at `~/agent-fleet/setup/secrets/vault.json.enc`, an openssl-encrypted file whose cipher and key-derivation parameters live in `vault-manage.sh`, not in prose. Only the config project owns the vault — no other project maintains its own secrets.

## vault-manage.sh

**Vault completeness — HARD RULE:** Every credential, API key, token, and password used by the fleet MUST have a vault entry with a `deploy_to` target. Browser-login passwords the fleet uses for automated logins live in the vault too, filled through the `/dev/shm` bridge below; you run `ask-passphrase.sh` and `vault-manage.sh` yourself, and the user only types into the masked dialog. When a service has no API, its browser login is the automation credential and lives in the vault. No machine should be special — any machine that can decrypt the vault can deploy any service.

Location: `~/agent-fleet/setup/secrets/vault-manage.sh` (its key-tree program `vault_edit.py` sits beside it)

| Command | What it does |
|---------|-------------|
| `bash vault-manage.sh status` | Which vault files exist; lists key names ONLY when a plaintext `vault.json` is present — on the normal encrypted-only vault it shows none, use `keys` |
| `VAULT_PASS=… bash vault-manage.sh keys [<prefix>]` | Key names with their sub-key names, never a value, straight from the ciphertext (decrypted into tmpfs `/dev/shm`, shredded). A prefix filters (`keys github_`), a dotted prefix lists children (`keys ssh_keys.`) |
| `printf '%s' "$VALUE" \| VAULT_PASS=… bash vault-manage.sh set <dotted.key>` | Store ONE value, read from stdin (never argv): one decrypt into tmpfs and one rewrite of the ciphertext — it writes no plaintext of its own, but a `vault.json` already beside the script is taken as its input (see the lock paragraph). Creates missing parents (`set broker_web.password`) |
| `VAULT_PASS=… bash vault-manage.sh unset [--yes] <dotted.key> [<dotted.key>…]` | Delete keys (whole entries or one field) in ONE rewrite of the ciphertext, decrypted in tmpfs only (a stale `vault.json` beside the script is refused, never taken as input); refuses with nothing written if any key is absent; prunes parents the removal empties (inverse of `set`) and names each one; prints only key names, any `deploy_to` target (deployed copies are NOT touched — clean them up separately) and the remaining key count, and only after the rewrite landed. A quoted last segment `'prefix*'` (a literal prefix of at least 3 characters, so never a bare `*`) matches every sibling it fits: without `--yes` it only previews the names and writes nothing; `unset --yes 'old_service_*'` removes them and echoes the names. Exact keys need no `--yes`. `_meta` is never removed |
| `VAULT_PASS=… bash vault-manage.sh shm <dotted.key>` / `bash vault-manage.sh shm-clean [path]` | One value into a mode-600 `/dev/shm/vault-key.*.txt` for a browser login (prints path + length only) / shred it — see "Vault-held browser login"; an object-valued key is refused and its sub-key names are listed — pass the leaf (`<key>.password`) |
| `bash vault-manage.sh decrypt` | Decrypt to vault.json (prompts for password) — for a hand edit of MANY keys; `encrypt` consumes the file |
| `bash vault-manage.sh encrypt` | Encrypt `vault.json` -> `vault.json.enc` and delete the plaintext |
| `bash vault-manage.sh deploy` | Decrypt + write tokens to the MCP config; extend `deploy_mcp_tokens` for other targets |
| `VAULT_PASS=… bash vault-manage.sh reencrypt` / `kdf` | Rewrite the ciphertext under the current KDF work factor in one step (no plaintext) / report the PBKDF2 count that opens the vault |
| `VAULT_PASS=... bash vault-manage.sh deploy` | Non-interactive (for scripts) |

Every vault edit (`set`, `unset`, `encrypt`, `reencrypt`, `decrypt`, `deploy`) takes the lock `setup/secrets/.vault.lock` (flock, gitignored) only once its interactive input is in — the password prompt, and `deploy`'s keep-or-delete question — and holds it to its final write, so concurrent sessions queue instead of undoing each other and none waits on another's prompt; `set`/`unset`/`reencrypt` also refuse to overwrite a ciphertext that changed after they read it (a git pull mid-edit). `set`, `unset`, `reencrypt` and `keys` decrypt only into tmpfs scratch (`/dev/shm`; `TMPDIR` only where no tmpfs is writable), never to a `vault.json` beside the script, and shred it on any exit — HUP, INT and TERM included; only SIGKILL can leave a copy, and that one is in RAM. `decrypt` and `deploy` write `vault.json` by design (a `deploy` that fails after decrypting shreds the copy it made; one the user decrypted is left alone). **`set` edits a `vault.json` that is already there** — like `encrypt`, it takes a plaintext beside the script as its input instead of decrypting, so a stale leftover is what gets encrypted and keys added since are lost; `unset` and `reencrypt` refuse such a file. Remove or encrypt a leftover `vault.json` before any `set`.

These guarantees are Linux ones: tmpfs (`/dev/shm`), `shred` and `flock`. Where `/dev/shm` is missing or read-only the scratch goes to `TMPDIR` — on disk — and is still removed on exit; without `shred` the file is unlinked, not overwritten; without `flock` the script warns and edits are not serialised, and only the changed-underneath check protects against a lost update (the loser is refused and reruns).

**KDF work factor:** `encrypt` writes the PBKDF2 count `ITER` set in `vault-manage.sh`; `ITER_LEGACY` lists older counts `decrypt` still opens, and any encrypt upgrades such a vault in place. To raise the work factor, set `ITER` and append the old count to `ITER_LEGACY`, then `reencrypt`. **Never decrypt ad hoc with a hand-typed `openssl -iter`** — a wrong count fails like a wrong passphrase, and about 1 in 256 times it yields garbage instead; `vault-manage.sh` validates the result as JSON.

## Passphrase Collection — GUI Dialog

**Never ask the user to type the vault passphrase in chat.** The passphrase would be visible in terminal history and conversation logs.

Use the GUI dialog script, which auto-detects the environment and pops a masked dialog (kdialog on KDE, zenity on GNOME, tkinter on X11, PowerShell WPF on WSL):
```bash
VAULT_PASS=$(bash ~/agent-fleet/setup/scripts/ask-passphrase.sh)
```

For a FRESH passphrase (a new vault, or a deliberate change) collect a second, independent entry:
```bash
VAULT_PASS_CONFIRM=$(bash ~/agent-fleet/setup/scripts/ask-passphrase.sh "Confirm vault passphrase")
```

Then pass to vault-manage.sh:
```bash
VAULT_PASS="$VAULT_PASS" bash ~/agent-fleet/setup/secrets/vault-manage.sh deploy
```

**AskUserQuestion is NOT suitable for passwords.** It requires option selection (min 2 options) and has no password/masked input mode. The "Other" text field is visible. Always use the GUI dialog.

**Record a secret's location or fingerprint, never its value.**

## Decrypt→Edit→Encrypt Cycle — HARD RULES

1. **One passphrase prompt per cycle.** Collect the passphrase ONCE at the start. Hold it in a shell variable through the entire cycle. Wipe (`unset`) only AFTER the write succeeds. Never prompt a second time — re-prompting introduces typo risk and user frustration.

2. **Encryption MUST use double-entry confirmation** if (and ONLY if) the passphrase is being set fresh (not retained from decryption). A single-entry typo on encryption = permanent credential loss. **The tool enforces this (CFG-641):** with no `vault.json.enc` yet, or with `VAULT_ALLOW_NEW_PASSPHRASE=1` for a deliberate change, `encrypt` refuses unless `VAULT_PASS_CONFIRM` is set and equal to `VAULT_PASS` — collect it with a second, independent `ask-passphrase.sh` dialog, never by copying the variable. No `.prev` copy of a replaced ciphertext is kept (it would keep data openable with a leaked passphrase outside any history scrub).

3. **Retained passphrase from decrypt skips confirmation.** When the same passphrase that successfully decrypted is reused for encryption, no confirmation needed — it's already verified by the successful decryption. The tool enforces this half too: re-encrypting an existing vault under `VAULT_PASS` alone is accepted only after `VAULT_PASS` has been proven to open the current `vault.json.enc`; a passphrase that cannot is refused before anything is overwritten.

4. **Stage and verify the payload first, then acquire the credential and execute it in a single call.**
   ```
   stage + verify payload  →  PASS=$(collect passphrase)  →  set / unset / shm with PASS  →  unset PASS
   ```
   The variable lives for the duration of the cycle. Not longer.

5. **Always write the vault entry first, before using the credential for anything else.** A step that fails after the credential has been used and wiped makes the user enter it twice.

6. **Claude Code shell isolation — CRITICAL.** Each `Bash()` call runs a separate shell — variables don't persist across calls, and a decrypted `vault.json` is cleaned up between calls. ALWAYS run the whole cycle in ONE `Bash()` call, chained with `&&`, under one `VAULT_PASS`. The verbs that change the vault write no plaintext and give the credential guard nothing to refuse:
   ```
   VAULT_PASS=$(bash ~/agent-fleet/setup/scripts/ask-passphrase.sh) && \
   printf '%s' "$VALUE" | VAULT_PASS="$VAULT_PASS" bash ~/agent-fleet/setup/secrets/vault-manage.sh set <dotted.key> && \
   VAULT_PASS="$VAULT_PASS" bash ~/agent-fleet/setup/secrets/vault-manage.sh unset <old.dotted.key>
   ```
   `set` reads the value from stdin (never argv) and rewrites the ciphertext itself; one `set` per key, chained with `&&`. Need the key names first? `VAULT_PASS="$VAULT_PASS" bash …/vault-manage.sh keys <prefix>` in the same chain — names only, never a value. **A `decrypt → python3/jq rewrite of vault.json → encrypt` chain IS REFUSED by the credential guard** (`vault-read-guard.sh`, CFG-960: the rewrite reads the plaintext) — do not write one; `set`/`unset` replaced it. `decrypt` + `encrypt` remain for a hand edit of many keys at a terminal, outside Claude Code.

   Never split the cycle across multiple `Bash()` calls. If `ask-passphrase.sh` fails, investigate and fix it — don't improvise manual dialogs. The `age` CLI does NOT work in Claude Code (needs TTY) — use openssl via vault-manage.sh.

## Vault-held browser login — one dialog, one key, never in the transcript

The user memorises the vault passphrase and nothing else. When a login's password is in the vault, you fill it; the user only types the passphrase into the masked dialog. Check the key exists first (`VAULT_PASS=… vault-manage.sh keys <prefix>`, names only — `status` lists none on an encrypted-only vault) — never promise a vault fill you have not checked.

1. **One key to tmpfs** (one Bash call; prints `path=… length=N`, never the value):
   ```
   VAULT_PASS=$(bash ~/agent-fleet/setup/scripts/ask-passphrase.sh) && VAULT_PASS="$VAULT_PASS" bash ~/agent-fleet/setup/secrets/vault-manage.sh shm <dotted.key>
   ```
   Repeat for the login name if it is a vault key too — or collect both in the same call under the same `VAULT_PASS`.
2. **Fill it through the browser** (Playwright `browser_run_code_unsafe`): open `file://<path>` in a second page, read its `textContent('body')` into a variable inside the browser, `.fill()` the password field with it, close that page and return only the length — the value never crosses into the tool result or the transcript. Submit by clicking the button, not Enter (passkey dialogs). The whole step is one function:
   ```js
   async (page) => { const p2 = await page.context().newPage(); await p2.goto('file://<path>');
     const v = (await p2.textContent('body')) || ''; await p2.close();
     await page.fill('input[type=password]', v); return v.length; }
   ```
3. **Shred at once**, success or failure: `bash ~/agent-fleet/setup/secrets/vault-manage.sh shm-clean <path>` (no path = every `vault-key.*.txt` bridge file in `/dev/shm`).

Never `cat` the bridge file, never `browser_type` the value, never snapshot the filled login page. A password that only the user knows and the vault lacks: store it first with `set` (rule 5), then use it. Extracting a value from a decrypted `vault.json` with python/jq is refused by the credential guard — `shm` is the route.

## When to Consult the Vault

When facing any credential or access issue (SSH refused, API auth failure, deploy blocked):
1. Check `VAULT_PASS=… vault-manage.sh keys <service-prefix>` — are there credentials for this service? (`status` names keys only when a plaintext `vault.json` exists.)
2. Check if credentials have been deployed to this machine (`vault-manage.sh deploy`)
3. Check prior session context for cross-machine deployment history
4. Only then start debugging the connection itself

## Credential Deployment Expectations

`vault-manage.sh deploy` provisions credentials to their target locations:
- GitHub tokens → `.mcp.json` env (+ `~/.git-credentials` where a deploy function writes it)
- API tokens → `.mcp.json` env sections
- SSH keys → `~/.ssh/` with proper permissions + config entries, and other service credentials → project-specific config files: each needs a deploy function beside `deploy_mcp_tokens` in `vault-manage.sh` (the template ships the MCP one); the vault entry's `deploy_to` field records the target

Every credential, API key, and SSH key used by the fleet MUST have a vault entry. If a secret exists only in a local file without a vault entry, that's a gap — add it with `set`.

**The live `settings.json` and `.mcp.json` are deploy targets, so they are credential stores.** Read settings only through `bash ~/agent-fleet/setup/scripts/settings-view.sh` (env values masked); `vault-read-guard.sh` and `credential-read-guard.sh` refuse raw reads of them. Name the vault key, never print a credential's value.
