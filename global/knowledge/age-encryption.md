# age Encryption — Operational Notes

## The Problem

The `age` CLI refuses non-interactive use. It requires a TTY for passphrase input — no env var support, no stdin piping. This means it hard-fails in Claude Code sessions (no `/dev/tty` available).

## Solution: pyrage

`pyrage` is a Python package fully compatible with `age` CLI output:

```bash
pip install pyrage
```

Use for non-interactive encrypt/decrypt in scripts and Claude Code sessions. Output is interchangeable with `age` CLI.

## Passphrase Handling in Claude Code Sessions

**Never ask the user to type a passphrase in plain text chat.**

Fallback chain for passphrase collection:

1. **`VAULT_PASSPHRASE` env var** — if set, use it directly (non-interactive)
2. **GUI dialog** — a passphrase collection script that pops a masked input dialog (tkinter, zenity, or kdialog depending on platform)
   - For **encryption** (or any destructive write), use `--confirm` flag: prompts twice, verifies match, retries up to 3 times on mismatch
   - For **decryption** (read-only), single prompt is fine
3. **TTY fallback** — `read -s` (only works in real terminal, not Claude Code)

Implement a passphrase dialog script that tries in order: tkinter, zenity, kdialog. On WSL it uses WSLg for the GUI window.

## For Vault Operations

Use a GUI passphrase dialog to collect the passphrase instead of asking in chat. The vault management script (`secrets/vault-manage.sh`) uses openssl, not age, precisely because of this TTY limitation.

## Summary

| Tool | Interactive? | Claude Code compatible? | Use when |
|------|:-----------:|:----------------------:|----------|
| `age` CLI | TTY required | No | Manual terminal use only |
| `pyrage` (Python) | No TTY needed | Yes | Scripts, automation, Claude Code |
| `openssl` (current vault) | Optional | Yes | Current vault-manage.sh approach |
