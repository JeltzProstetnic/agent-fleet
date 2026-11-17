#!/usr/bin/env bash
# Token vault management
# Uses openssl AES-256-CBC with PBKDF2 for symmetric encryption
#
# Usage:
#   bash setup/secrets/vault-manage.sh encrypt   # vault.json -> vault.json.enc (prompts for password)
#   bash setup/secrets/vault-manage.sh decrypt   # vault.json.enc -> vault.json (prompts for password)
#   bash setup/secrets/vault-manage.sh deploy    # decrypt + write tokens to their target locations
#   bash setup/secrets/vault-manage.sh status    # which vault files exist (key names only from a plaintext vault.json)
#   bash setup/secrets/vault-manage.sh reencrypt # decrypt + encrypt in one step (KDF upgrade, no plaintext left)
#   bash setup/secrets/vault-manage.sh kdf       # report the PBKDF2 iteration count that opens the vault
#   printf '%s' "$V" | bash setup/secrets/vault-manage.sh set <dotted.key>   # store one value read from stdin
#   bash setup/secrets/vault-manage.sh unset [--yes] <dotted.key|prefix*> […] # delete keys in one rewrite (names + count only)
#   bash setup/secrets/vault-manage.sh keys [<prefix>|<dotted.prefix>]        # key NAMES, decrypted in tmpfs, no plaintext on disk
#   bash setup/secrets/vault-manage.sh shm <dotted.key>   # one value → mode-600 /dev/shm/vault-key.*.txt (path + length only)
#   bash setup/secrets/vault-manage.sh shm-clean [path]   # shred the bridge file(s)
#
# Password can be passed via VAULT_PASS env var for non-interactive use:
#   VAULT_PASS="mypassword" bash setup/secrets/vault-manage.sh deploy
#
# encrypt under VAULT_PASS (CFG-641): re-encrypting an existing vault requires VAULT_PASS to
# open it first. A FRESH passphrase — no vault.json.enc yet, or a deliberate change with
# VAULT_ALLOW_NEW_PASSPHRASE=1 — additionally requires VAULT_PASS_CONFIRM, collected by a
# second independent entry. No .prev copy of a replaced ciphertext is kept.
#
# SECURITY: All password input uses read -s (masked, no echo) or env vars.
# Never paste vault passwords or tokens into a Claude Code chat session —
# session transcripts may be logged. Use this script's interactive prompts,
# the VAULT_PASS env var, or a GUI dialog (setup/scripts/ask-passphrase.sh).

set -euo pipefail
cd "$(dirname "$0")"
# Internal state, never inherited: an exported _VAULT_LOCKED would skip the lock and an exported
# _VAULT_BASE_SHA would make encrypt refuse an unchanged vault.
unset _VAULT_LOCKED _VAULT_BASE_SHA _VAULT_STAGED _VAULT_WROTE _VAULT_NEW_OURS _VAULT_PASS_TYPED _VAULT_OLD_ITER _VAULT_DEPLOY_DEC _keep

# Reminder for Claude Code agents: vault-ops.md has the cycle rules (passphrase hold-through, confirm-on-fresh)
echo "Reminder: Load knowledge/vault-ops.md for vault cycle rules before proceeding." >&2

VAULT_PLAIN="vault.json"
VAULT_ENCRYPTED="vault.json.enc"
VAULT_LOCK=".vault.lock"   # flock target for every read-modify-write (gitignored)
CIPHER="aes-256-cbc"
# PBKDF2 work factor. ITER is what encrypt writes. ITER_LEGACY lists counts older vaults of
# this deployment were written with: decrypt tries ITER, then each of these, and re-encrypting
# under ITER upgrades the vault in place. To raise the work factor, set ITER to the new count
# and append the old one here (space-separated).
ITER=100000
ITER_LEGACY=""

_file_size() {
  stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo "?"
}

# ── Scratch plaintext, the edit lock, the changed-underneath check ──
# Every decrypted copy is a scratch file in tmpfs (VAULT_SHM_DIR, default /dev/shm: RAM, never
# the disk) when that is writable, else in TMPDIR, and every one is shredded on ANY exit.
# set, unset, reencrypt and keys work on such a copy only — never a vault.json beside this
# script (a signal mid-set would leave the whole vault there as plaintext); decrypt and
# deploy write vault.json because that file is their product.
# HUP/INT/TERM are trapped on purpose: an untrapped TERM runs the EXIT trap at once while
# openssl is still running, and openssl then writes its plaintext after the shred; trapped,
# bash lets the running command finish first. Only SIGKILL can leave a scratch file behind.
_VAULT_SCRATCH=()
_scratch_dir() {
  local d="${VAULT_SHM_DIR:-/dev/shm}"
  if [ -d "$d" ] && [ -w "$d" ]; then printf '%s' "$d"; else printf '%s' "${TMPDIR:-/tmp}"; fi
}
_scratch() {  # <var> <tag> — a new mode-600 scratch file, tracked for the exit shred; path → <var>
  local _sf; _sf=$(mktemp "$(_scratch_dir)/vault-$2.XXXXXX") || exit 1
  chmod 600 "$_sf"; _VAULT_SCRATCH+=("$_sf"); printf -v "$1" '%s' "$_sf"
}
_shred() { shred -u "$1" 2>/dev/null || rm -f "$1"; }
_sha() { { sha256sum || shasum -a 256; } < "$1" 2>/dev/null | cut -c1-64 || true; }
_cleanup() {
  local rc=$? f; set +e
  for f in ${_VAULT_SCRATCH[@]+"${_VAULT_SCRATCH[@]}"}; do [ -e "$f" ] && _shred "$f"; done
  [ -z "${_VAULT_NEW_OURS:-}" ] || rm -f "$VAULT_ENCRYPTED.new"
  if [ -n "${_VAULT_STAGED:-}" ] && [ "$rc" -ne 0 ] && [ -z "${_VAULT_WROTE:-}" ] \
     && [ "$(_sha "$VAULT_ENCRYPTED")" = "${_VAULT_BASE_SHA:-}" ]; then
    echo "ERROR: $_VAULT_STAGED did not complete — nothing was written; $VAULT_ENCRYPTED is unchanged." >&2
  fi
  # A deploy that decrypted the vault for itself and then failed (a broken MCP config, a
  # python error) must not leave that plaintext behind; one the user decrypted is theirs.
  if [ -n "${_VAULT_DEPLOY_DEC:-}" ] && [ "$rc" -ne 0 ] && [ -f "$VAULT_PLAIN" ]; then
    _shred "$VAULT_PLAIN"
    echo "ERROR: deploy did not complete — the $VAULT_PLAIN it decrypted was shredded; $VAULT_ENCRYPTED is unchanged." >&2
  fi
}
trap _cleanup EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM

# Read VAULT_PASS at the terminal when the caller did not set it; `confirm` asks twice (a
# fresh encrypt). Every verb calls this BEFORE _vault_lock, so no run waits on another's prompt.
_prompt_pass() {  # [confirm]
  [ -z "${VAULT_PASS:-}" ] || return 0
  # SECURITY: read -s masks input (no echo). Never use unmasked read for secrets.
  echo -n "Password: "; read -rs VAULT_PASS; echo
  [ "${1:-}" = confirm ] || return 0
  local _again; echo -n "Confirm: "; read -rs _again; echo
  if [ "$VAULT_PASS" != "$_again" ]; then echo "ERROR: Passwords don't match."; exit 1; fi
  _VAULT_PASS_TYPED=1   # typed twice: do_encrypt takes the double entry as the confirmation
}

# A vault.json beside the vault is never the input of unset or reencrypt: it may predate the
# ciphertext (stale-plaintext hazard). Checked before the prompt and again under the lock.
_refuse_stale_plain() {  # <verb>
  [ -f "$VAULT_PLAIN" ] || return 0
  echo "ERROR: a plaintext $VAULT_PLAIN lies beside the vault — encrypt or remove it first;" >&2
  echo "$1 edits $VAULT_ENCRYPTED only (stale-plaintext hazard). Nothing was written." >&2
  exit 1
}

# Decrypt the ciphertext into a tmpfs scratch file and point VAULT_PLAIN at it; records what
# the ciphertext was, for _vault_cas. The decrypt the edit verbs and keys share.
_open_scratch() {
  [ -f "$VAULT_ENCRYPTED" ] || { echo "ERROR: no vault found ($VAULT_ENCRYPTED)." >&2; exit 1; }
  local _dec; _scratch _dec dec
  _VAULT_BASE_SHA=$(_sha "$VAULT_ENCRYPTED")
  if ! _decrypt_any_iter "$_dec" >/dev/null; then
    echo "ERROR: cannot decrypt $VAULT_ENCRYPTED — wrong passphrase? Nothing was written." >&2; exit 1
  fi
  VAULT_PLAIN="$_dec"
}

# One writer at a time, held from the stale-plaintext check to the final mv: without it a
# concurrent set and unset each rewrite the vault from the copy they read, and the later mv
# silently undoes the other (a removed key comes back, or a stored one vanishes). Taken only
# after the run's interactive input is in (_prompt_pass, deploy's question). Idempotent.
_vault_lock() {
  [ -z "${_VAULT_LOCKED:-}" ] || return 0
  _VAULT_LOCKED=1
  if ! command -v flock >/dev/null 2>&1; then
    echo "  [WARN] flock not found: vault edits are not serialised here (the changed-underneath check still runs)." >&2
    return 0
  fi
  if ! { exec 9>>"$VAULT_LOCK"; } 2>/dev/null; then
    echo "ERROR: cannot open the edit lock $VAULT_LOCK — nothing was done." >&2; exit 1
  fi
  flock -w "${VAULT_LOCK_WAIT:-120}" 9 || {
    echo "ERROR: another vault-manage.sh still holds $VAULT_LOCK after ${VAULT_LOCK_WAIT:-120}s — nothing was done." >&2; exit 1; }
}

# Refuse to replace a ciphertext that changed since this run decrypted it (_VAULT_BASE_SHA):
# a git pull, a restore, or a writer that does not take the lock. The copy this run decrypted
# is tmpfs scratch, so the exit shred removes it — nothing stale is left to encrypt later.
_vault_cas() {
  [ -n "${_VAULT_BASE_SHA:-}" ] || return 0
  [ "$(_sha "$VAULT_ENCRYPTED")" != "$_VAULT_BASE_SHA" ] || return 0
  echo "ERROR: $VAULT_ENCRYPTED changed while this edit ran (a git pull or restore, or a writer" >&2
  echo "without the lock) — refusing to overwrite it. Nothing was written; run the command again." >&2
  exit 1
}

_is_json() {  # <file>
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1
  elif command -v jq >/dev/null 2>&1; then
    jq -e . "$1" >/dev/null 2>&1
  else
    return 0   # no validator on this box: accept
  fi
}

# Decrypt $VAULT_ENCRYPTED into <out> under $VAULT_PASS, trying ITER and then each
# ITER_LEGACY count. A wrong count — like a wrong passphrase — normally fails the
# padding check, but about one time in 256 it yields garbage that passes it, so a
# plaintext counts only when it parses as JSON. Prints the count that opened it.
# <out> must be a scratch file: it is truncated between attempts, never removed.
_decrypt_any_iter() {  # <out>
  local out="$1" it
  for it in $ITER $ITER_LEGACY; do
    if openssl enc -$CIPHER -d -pbkdf2 -iter "$it" -in "$VAULT_ENCRYPTED" -out "$out" \
         -pass fd:3 3<<<"$VAULT_PASS" 2>/dev/null && _is_json "$out"; then
      printf '%s' "$it"; return 0
    fi
    : > "$out"
  done
  return 1
}

# Write salted fingerprints of every vault value, for secret-commit-guard.sh and the git
# pre-push scan (lib-secret-detect.sh reads this directory). This is the only moment the
# plaintext values exist, so it runs between a verified encrypt and the plaintext deletion.
#
# Fingerprints, never values: the guard hashes tokens in a staged diff and compares, so it
# catches a human-memorable passphrase written as prose, which no shape-based pattern can
# match. The salt is mandatory and stays out of git: an unsalted hash of a low-entropy
# secret is brute-forceable, which would make the fingerprint file the next version of the
# bug it prevents.
FP_FILE=".secret-fingerprints"
SALT_FILE=".fingerprint-salt"

_write_fingerprints() {
  [ -f "$VAULT_PLAIN" ] || return 0
  command -v python3 >/dev/null 2>&1 || { echo "  [SKIP] fingerprints: python3 absent" >&2; return 0; }
  if [ ! -s "$SALT_FILE" ]; then
    ( umask 077; python3 -c 'import secrets;print(secrets.token_hex(32))' > "$SALT_FILE" )   # created 600, never world-readable for an instant
    chmod 600 "$SALT_FILE"
  fi
  VAULT_PLAIN="$VAULT_PLAIN" SALT_FILE="$SALT_FILE" FP_FILE="$FP_FILE" python3 -c '
import hashlib, json, os, sys
plain, salt_file, out = os.environ["VAULT_PLAIN"], os.environ["SALT_FILE"], os.environ["FP_FILE"]
salt = open(salt_file).read().strip()
vals = set()
# Fingerprint values under CREDENTIAL-ish keys only. Taking every string in the vault would
# fingerprint user names and org names too, so the guard would block ordinary prose that
# merely mentions them — the false-positive class that gets a guard switched off.
SECRET_KEYS = ("password", "passphrase", "token", "secret", "key", "credential",
               "pat", "apikey", "api_key", "auth", "pass", "pin", "seed")
NEVER = ("username", "user", "host", "hostname", "org", "owner", "account", "login",
         "email", "note", "comment", "protocol", "share", "path", "url", "endpoint",
         "deploy_to", "mount_path", "windows_drive", "type", "name", "id", "keyfile",
         "key_path", "pubkey", "public_key", "key_name", "keyring")
def _is_secret_key(k):
    kl = k.lower()
    if any(n == kl or kl.endswith("_" + n) for n in NEVER):
        return False
    return any(sk in kl for sk in SECRET_KEYS)
def walk(o, key=None):
    if isinstance(o, dict):
        for k, v in o.items(): walk(v, k)
    elif isinstance(o, list):
        for v in o: walk(v, key)
    elif isinstance(o, str):
        s = o.strip()
        # Short values are brute-forceable even salted; a URL or a path is not a
        # credential; a placeholder is not one either.
        if (key and _is_secret_key(key) and len(s) >= 8
                and not s.startswith(("http://", "https://", "/", "~/", "./"))
                and "PASTE" not in s.upper() and "PLACEHOLDER" not in s.upper()):
            vals.add(s)
try:
    walk(json.load(open(plain)))
except Exception:
    sys.exit(0)
# MERGE, never overwrite. Some secrets cannot live in the vault — the vault PASSPHRASE
# above all, since it is the key to it — so they are fingerprinted directly. Rewriting
# this file from the vault alone would silently drop them.
existing = set()
if os.path.exists(out):
    existing = {l.strip() for l in open(out) if l.strip()}
fresh = {hashlib.sha256((salt + v).encode()).hexdigest() for v in vals}
merged = existing | fresh
with open(out, "w") as f:
    for h in sorted(merged):
        f.write(h + "\n")
print("  [OK] %d vault values fingerprinted, %d total (values never stored)"
      % (len(vals), len(merged)))
'
  chmod 600 "$FP_FILE" 2>/dev/null || true
}

# CFG-641: who vouches for VAULT_PASS before anything is overwritten? A second prompt cannot
# help a non-interactive caller. What can depends on whether anything on disk can vouch:
#   - EXISTING vault, same passphrase — prove VAULT_PASS opens it, which catches the typo
#     (and records the count it opened at, in _VAULT_OLD_ITER, for the upgrade note);
#   - FRESH passphrase (no vault yet, or a deliberate change): nothing can vouch for it, and
#     the round-trip re-uses the same typo, so it must arrive twice, from two independent
#     entries — VAULT_PASS and VAULT_PASS_CONFIRM.
_vouch_passphrase() {
  _VAULT_OLD_ITER=""
  [ -z "${_VAULT_PASS_TYPED:-}" ] || return 0   # typed twice at the terminal: that IS the confirmation
  if [ -f "$VAULT_ENCRYPTED" ] && [ -z "${VAULT_ALLOW_NEW_PASSPHRASE:-}" ]; then
    local _probe; _scratch _probe probe
    if ! _VAULT_OLD_ITER=$(_decrypt_any_iter "$_probe"); then
      _shred "$_probe"
      echo "ERROR: VAULT_PASS does not open the existing $VAULT_ENCRYPTED." >&2
      echo "Refusing to re-encrypt — a passphrase that cannot open the current vault is" >&2
      echo "almost always a typo, and encrypting with it makes the vault unrecoverable (CFG-641)." >&2
      echo "If you are deliberately CHANGING the passphrase, set VAULT_ALLOW_NEW_PASSPHRASE=1" >&2
      echo "and confirm the new one via VAULT_PASS_CONFIRM." >&2
      exit 1
    fi
    _shred "$_probe"
    return 0
  fi
  if [ -z "${VAULT_PASS_CONFIRM:-}" ]; then
    echo "ERROR: a FRESH passphrase must be confirmed — VAULT_PASS_CONFIRM is not set." >&2
    echo "Nothing on disk can vouch for a new passphrase, and one mistyped entry makes the" >&2
    echo "vault unrecoverable (CFG-641). Collect it a SECOND time, independently:" >&2
    echo "  VAULT_PASS_CONFIRM=\$(bash ~/agent-fleet/setup/scripts/ask-passphrase.sh \"Confirm vault passphrase\")" >&2
    echo "never by copying VAULT_PASS — then run encrypt again. Nothing was written." >&2
    exit 1
  fi
  if [ "$VAULT_PASS" != "$VAULT_PASS_CONFIRM" ]; then
    echo "ERROR: VAULT_PASS and VAULT_PASS_CONFIRM do not match. Nothing was written (CFG-641)." >&2
    exit 1
  fi
}

do_encrypt() {
  _prompt_pass confirm   # a no-op here when the dispatch already prompted, before the lock
  _vouch_passphrase
  _VAULT_NEW_OURS=1   # the exit trap removes a .new this run leaves behind
  openssl enc -$CIPHER -salt -pbkdf2 -iter $ITER \
    -in "$VAULT_PLAIN" -out "$VAULT_ENCRYPTED.new" \
    -pass fd:3 3<<<"$VAULT_PASS"
  # Round-trip before the new ciphertext replaces the old one: decrypt what was just written
  # and byte-compare against the plaintext. This catches a truncated or corrupt write. Only
  # on success does the new file become the vault.
  local _rt; _scratch _rt rt
  if ! openssl enc -$CIPHER -d -pbkdf2 -iter $ITER \
         -in "$VAULT_ENCRYPTED.new" -out "$_rt" \
         -pass fd:3 3<<<"$VAULT_PASS" 2>/dev/null || ! cmp -s "$VAULT_PLAIN" "$_rt"; then
    _shred "$_rt"
    rm -f "$VAULT_ENCRYPTED.new"
    echo "ERROR: the new ciphertext did not round-trip back to the plaintext." >&2
    echo "The existing vault and the plaintext are both untouched. Nothing was lost." >&2
    exit 1
  fi
  _shred "$_rt"
  _vault_cas
  # No .prev copy: a committed vault's git history keeps every prior ciphertext, and a .prev
  # would outlive a post-leak history scrub.
  mv -f "$VAULT_ENCRYPTED.new" "$VAULT_ENCRYPTED"
  _VAULT_WROTE=1; _VAULT_NEW_OURS=""
  if [ -n "${_VAULT_OLD_ITER:-}" ] && [ "$_VAULT_OLD_ITER" != "$ITER" ]; then
    echo "Upgraded PBKDF2 iterations: $_VAULT_OLD_ITER -> $ITER."
  fi
}

do_decrypt() {
  _prompt_pass
  local _tmp _it; _scratch _tmp dec
  if ! _it=$(_decrypt_any_iter "$_tmp"); then
    _shred "$_tmp"
    echo "ERROR: cannot decrypt $VAULT_ENCRYPTED — wrong passphrase, or a ciphertext written" >&2
    echo "with an iteration count this script does not know (tried: $ITER $ITER_LEGACY)." >&2
    exit 1
  fi
  mv -f "$_tmp" "$VAULT_PLAIN"
  chmod 600 "$VAULT_PLAIN"
  if [ "$_it" != "$ITER" ]; then
    echo "NOTE: vault opened with legacy PBKDF2 iterations ($_it); the next encrypt upgrades it to $ITER." >&2
  fi
}

# Which iteration count opens the vault? The verification step after a re-encrypt.
# Reads VAULT_PASS; the only plaintext is a shredded scratch file.
do_kdf() {
  _prompt_pass
  local _probe _it; _scratch _probe probe
  if _it=$(_decrypt_any_iter "$_probe"); then
    _shred "$_probe"
    if [ "$_it" = "$ITER" ]; then
      echo "PBKDF2 iterations: $_it (current)"
    else
      echo "PBKDF2 iterations: $_it (legacy; run reencrypt to upgrade to $ITER)"
    fi
  else
    _shred "$_probe"
    echo "ERROR: VAULT_PASS opens $VAULT_ENCRYPTED at none of: $ITER $ITER_LEGACY" >&2
    exit 1
  fi
}

# ── Deploy: write vault values to the MCP config (extend here for other targets) ──

deploy_mcp_tokens() {
  # Deploy to MCP config (try cc-mirror path first, then standard)
  local MCP_CONFIG="$HOME/.cc-mirror/mclaude/config/.mcp.json"
  [[ ! -f "$MCP_CONFIG" ]] && MCP_CONFIG="$HOME/.mcp.json"
  if [ ! -f "$MCP_CONFIG" ]; then
    echo "WARNING: $MCP_CONFIG not found. Skipping MCP deployment."
    echo "Run 'bash ~/agent-fleet/sync.sh setup' first to set up the config structure."
    return 0
  fi
  python3 << 'PYEOF'
import json, os, shutil

vault = json.load(open('vault.json'))

# Find MCP config (cc-mirror path first, then standard)
mcp_path = os.path.expanduser('~/.cc-mirror/mclaude/config/.mcp.json')
if not os.path.isfile(mcp_path):
    mcp_path = os.path.expanduser('~/.mcp.json')

# Backup
shutil.copy2(mcp_path, mcp_path + '.bak')
mcp = json.load(open(mcp_path))
servers = mcp.setdefault('mcpServers', {})

# A vault filled key by key (`set`) holds whatever was set so far, and a server block the
# user wrote by hand may have no `env` yet: never hard-index either (CFG-978 review). The
# keys that exist are written, the rest are left out and named.
def env_of(name):
    return servers[name].setdefault('env', {})

def deploy(server, entry, lead, pairs, label):
    """pairs: (env var, vault field) in order; `lead` is the field that decides presence."""
    e = vault.get(entry)
    if server not in servers or not isinstance(e, dict) or not e.get(lead):
        return
    if str(e[lead]).startswith('PASTE'):
        print("  [SKIP] %s — placeholder" % label); return
    env, done, missing = env_of(server), [], []
    for var, field in pairs:
        if e.get(field): env[var] = e[field]; done.append(var)
        else: missing.append(field)
    print("  [OK] %s (%d value%s%s)" % (label, len(done), "" if len(done) == 1 else "s",
                                       "; not in the vault: " + ", ".join(missing) if missing else ""))

deploy('github', 'github_personal', 'token', [('GITHUB_PERSONAL_ACCESS_TOKEN', 'token')], "GitHub personal token")
deploy('twitter', 'twitter', 'api_key', [('API_KEY', 'api_key'), ('API_SECRET_KEY', 'api_secret'),
                                         ('ACCESS_TOKEN', 'access_token'), ('ACCESS_TOKEN_SECRET', 'access_secret')], "Twitter tokens")
deploy('google-workspace', 'google_workspace', 'client_id', [('GOOGLE_OAUTH_CLIENT_ID', 'client_id'),
                                                            ('GOOGLE_OAUTH_CLIENT_SECRET', 'client_secret'), ('USER_GOOGLE_EMAIL', 'email')], "Google Workspace credentials")
deploy('jira', 'jira', 'api_token', [('JIRA_URL', 'url'), ('JIRA_USERNAME', 'email'), ('JIRA_API_TOKEN', 'api_token')], "Jira credentials")
deploy('linkedin', 'linkedin', 'access_token', [('LINKEDIN_CLIENT_ID', 'client_id'), ('LINKEDIN_CLIENT_SECRET', 'client_secret'),
                                                ('LINKEDIN_ACCESS_TOKEN', 'access_token')], "LinkedIn credentials")

with open(mcp_path, 'w') as f:
    json.dump(mcp, f, indent=2)
    f.write('\n')

# Sync to ~/.mcp.json if we modified a different file (cc-mirror path) — unless the two are
# the same file through a symlink or hardlink, where shutil.copy2 raises SameFileError and
# would abort the whole deploy with the plaintext still on disk.
def _same_file(a, b):
    try:
        return os.path.samefile(a, b)
    except OSError:
        return False

global_mcp = os.path.expanduser('~/.mcp.json')
if os.path.abspath(mcp_path) != os.path.abspath(global_mcp):
    if _same_file(mcp_path, global_mcp):
        print("  [OK] ~/.mcp.json is a symlink/hardlink to the config written — no copy needed")
    else:
        shutil.copy2(mcp_path, global_mcp)
        print("  [OK] Synced to ~/.mcp.json")

print("\nDone. Restart Claude Code to pick up new tokens.")
PYEOF
}

# The key-tree program behind `unset` and `keys` is vault_edit.py beside this script: it reads
# the plaintext named by VAULT_TREE_PLAIN and prints key NAMES, deploy_to targets and counts —
# never a value. Its header documents both modes.
VAULT_EDIT_PY="vault_edit.py"
_need_tree() {  # before any prompt or decrypt: a copy of this script without its program refuses
  [ -f "$VAULT_EDIT_PY" ] && return 0
  echo "ERROR: $(pwd)/$VAULT_EDIT_PY is missing — unset and keys need it beside vault-manage.sh. Nothing was written." >&2
  exit 1
}
_unset_keys() { VAULT_TREE_PLAIN="$1" python3 "$VAULT_EDIT_PY" unset "${@:2}"; }   # <plain> [--yes] <key>…
_list_keys() { VAULT_TREE_PLAIN="$1" python3 "$VAULT_EDIT_PY" keys "${@:2}"; }     # <plain> [<pattern>]

# ── Main command dispatch ──

case "${1:-help}" in
  encrypt)
    [ -f "$VAULT_PLAIN" ] || { echo "ERROR: $VAULT_PLAIN not found. Nothing to encrypt."; exit 1; }
    _prompt_pass confirm; _vault_lock   # the prompt first: no lock is held while a human types
    [ -f "$VAULT_PLAIN" ] || { echo "ERROR: $VAULT_PLAIN not found. Nothing to encrypt."; exit 1; }
    do_encrypt
    # Verify .enc was actually written and non-empty before destroying plaintext
    if [ ! -s "$VAULT_ENCRYPTED" ]; then
      echo "ERROR: $VAULT_ENCRYPTED is missing or empty after encrypt. Keeping plaintext."
      exit 1
    fi
    echo "Encrypted: $VAULT_ENCRYPTED ($(_file_size "$VAULT_ENCRYPTED") bytes)"
    # Refresh the commit guard's fingerprints while the values still exist
    _write_fingerprints
    # Auto-delete plaintext after verified encrypt (stale-plaintext hazard)
    rm -f "$VAULT_PLAIN"
    echo "Deleted plaintext $VAULT_PLAIN."
    ;;

  set)
    # set <dotted.key>  — VALUE IS READ FROM STDIN, never from argv.
    # Hand-editing vault.json is blocked for an agent by the credential guard, and a value on
    # a command line is visible to ps and lands in shell history. One decrypt-edit-encrypt
    # cycle, one passphrase prompt, value on stdin.
    _key="${2:-}"
    if [ -z "$_key" ]; then
      echo "ERROR: usage: printf '%s' \"\$VALUE\" | vault-manage.sh set <dotted.key>" >&2
      exit 1
    fi
    if [ "$#" -gt 2 ]; then
      echo "ERROR: the value must arrive on STDIN, not as an argument — an argument is" >&2
      echo "visible to ps and lands in shell history. Pipe it in instead." >&2
      exit 1
    fi
    _val="$(cat)"
    if [ -z "$_val" ]; then
      echo "ERROR: empty value refused — storing an empty secret hides the real one." >&2
      exit 1
    fi
    if [ -f "$VAULT_PLAIN" ]; then _prompt_pass confirm; else _prompt_pass; fi   # before the lock
    _vault_lock
    # The vault is decrypted into tmpfs scratch, never to a vault.json beside this script. A
    # vault.json the caller decrypted is the input instead, as encrypt would take it.
    [ -f "$VAULT_PLAIN" ] || _open_scratch
    VAULT_PLAIN_PATH="$VAULT_PLAIN" VAULT_SET_KEY="$_key" VAULT_SET_VAL="$_val" python3 -c '
import json, os
plain = os.environ["VAULT_PLAIN_PATH"]
key   = os.environ["VAULT_SET_KEY"]
val   = os.environ["VAULT_SET_VAL"]
data  = json.load(open(plain))
node  = data
parts = key.split(".")
for p in parts[:-1]:
    if not isinstance(node.get(p), dict):
        node[p] = {}
    node = node[p]
node[parts[-1]] = val
with open(plain, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print("  [OK] set %s (value not shown)" % key)
' || exit 1
    unset _val
    _VAULT_STAGED="set"; do_encrypt; _VAULT_STAGED=""
    if [ ! -s "$VAULT_ENCRYPTED" ]; then
      echo "ERROR: $VAULT_ENCRYPTED missing or empty after encrypt."
      exit 1
    fi
    _write_fingerprints
    _shred "$VAULT_PLAIN"
    echo "Stored. No plaintext left; fingerprints refreshed."
    ;;

  unset)
    # unset [--yes] <dotted.key|prefix*> […] — the delete verb. Key NAMES on argv, no value
    # anywhere. A pattern without --yes only previews its matches; _meta is refused
    # (vault_edit.py). Under the edit lock: one decrypt into a tmpfs scratch file (shredded on
    # any exit), every key removed in memory, one encrypt that refuses if the ciphertext changed
    # meanwhile — the vault is rewritten once or not at all, and no vault.json ever appears
    # beside this script. The report is printed only after the rewrite landed; a run that
    # stops before it says nothing was written. Deployed copies are never touched.
    shift
    if [ "$#" -eq 0 ]; then
      echo "ERROR: usage: VAULT_PASS=… vault-manage.sh unset [--yes] <dotted.key|prefix*> [<dotted.key|prefix*>…]" >&2; exit 1
    fi
    _need_tree; _refuse_stale_plain unset
    _prompt_pass; _vault_lock; _refuse_stale_plain unset   # the prompt first, then the lock
    unset VAULT_ALLOW_NEW_PASSPHRASE   # re-encrypt under the passphrase that opened it, never a new one
    _open_scratch
    _report=$(_unset_keys "$VAULT_PLAIN" "$@") || exit 1
    _VAULT_STAGED="unset"; do_encrypt; _VAULT_STAGED=""
    printf '%s\n' "$_report"
    _write_fingerprints
    echo "Removed. Ciphertext rewritten once; no plaintext left; fingerprints refreshed (removed values stay listed)."
    ;;

  keys)
    # keys [<prefix>|<dotted.prefix>|<pattern>] — vault key NAMES with sub-key names, never a
    # value, from the ciphertext alone: one decrypt into tmpfs scratch, shredded. `status` can
    # list names only when a plaintext vault.json exists; this is the route for the normal,
    # encrypted-only vault — and the preview for an `unset 'prefix*'`.
    shift
    [ "$#" -le 1 ] || { echo "ERROR: usage: VAULT_PASS=… vault-manage.sh keys [<prefix>]" >&2; exit 1; }
    [ -f "$VAULT_ENCRYPTED" ] || { echo "ERROR: no vault found ($VAULT_ENCRYPTED)." >&2; exit 1; }
    _need_tree; _prompt_pass
    _open_scratch
    _list_keys "$VAULT_PLAIN" "$@"
    ;;

  shm)
    # shm <dotted.key> — ONE value into a mode-600 .txt under /dev/shm for the browser-login
    # bridge (knowledge/vault-ops.md "Vault-held browser login"). The decrypt runs into tmpfs
    # and is shredded; stdout carries the path and the length, never the value.
    _key="${2:-}"
    if [ -z "$_key" ] || [ "$#" -ne 2 ]; then
      echo "ERROR: usage: VAULT_PASS=… vault-manage.sh shm <dotted.key>" >&2; exit 1
    fi
    _shm="${VAULT_SHM_DIR:-/dev/shm}"
    [ -d "$_shm" ] && [ -w "$_shm" ] || { echo "ERROR: $_shm is missing or not writable." >&2; exit 1; }
    _prompt_pass
    umask 077
    # mktemp --suffix is GNU-only: make the name, then give it the .txt a file:// page needs.
    _dec=$(mktemp "$_shm/vault-dec.XXXXXX"); _out=$(mktemp "$_shm/vault-key.XXXXXX")
    trap '_shred "$_dec"; [ -n "${_keep:-}" ] || _shred "$_out"' EXIT
    mv "$_out" "$_out.txt"; _out="$_out.txt"
    if ! _decrypt_any_iter "$_dec" >/dev/null; then
      echo "ERROR: cannot decrypt $VAULT_ENCRYPTED — wrong passphrase?" >&2; exit 1
    fi
    _len=$(VAULT_DEC="$_dec" VAULT_GET_KEY="$_key" VAULT_OUT="$_out" python3 -c '
import json, os, sys
key = os.environ["VAULT_GET_KEY"]; node = json.load(open(os.environ["VAULT_DEC"]))
for p in key.split("."):
    if not isinstance(node, dict) or p not in node:
        sys.exit("ERROR: no vault key %s" % key)
    node = node[p]
if isinstance(node, dict):
    sys.exit("ERROR: %s holds an object, not one value; sub-keys: %s" % (key, ", ".join(sorted(node))))
if isinstance(node, bool) or not isinstance(node, (str, int, float)) or node == "":
    sys.exit("ERROR: %s is not a non-empty string or number" % key)
val = str(node)
with open(os.environ["VAULT_OUT"], "w") as f:
    f.write(val)
print(len(val))
') || exit 1
    _keep=1
    echo "path=$_out length=$_len"
    echo "Fill it through the browser file:// bridge, then: vault-manage.sh shm-clean $_out" >&2
    ;;

  shm-clean)
    # shm-clean [<path>…] — shred the named bridge files, or every vault-key.*.txt in the shm dir.
    _shm="${VAULT_SHM_DIR:-/dev/shm}"; _shm_real=$(cd "$_shm" && pwd -P); _n=0
    shift
    if [ "$#" -eq 0 ]; then shopt -s nullglob; set -- "$_shm"/vault-key.*.txt; fi
    for _f in "$@"; do
      case "$(basename "$_f")" in vault-key.*.txt) ;; *)
        echo "ERROR: $_f is not a vault-key bridge file — refused." >&2; exit 1 ;; esac
      if [ "$(cd "$(dirname "$_f")" 2>/dev/null && pwd -P)" != "$_shm_real" ]; then
        echo "ERROR: $_f is outside $_shm — refused." >&2; exit 1
      fi
      [ -f "$_f" ] || continue
      _shred "$_f"; _n=$((_n + 1))
    done
    echo "Shredded $_n vault-key bridge file(s) in $_shm."
    ;;

  fingerprints)
    if [ ! -f "$VAULT_PLAIN" ]; then
      echo "ERROR: $VAULT_PLAIN not found. Decrypt first, then re-run."
      exit 1
    fi
    _write_fingerprints
    ;;

  reencrypt)
    # decrypt + encrypt under the same passphrase in one step: upgrades the KDF work factor.
    # One VAULT_PASS; the plaintext only ever exists as tmpfs scratch.
    if [ ! -f "$VAULT_ENCRYPTED" ]; then
      echo "ERROR: $VAULT_ENCRYPTED not found. Nothing to re-encrypt."
      exit 1
    fi
    _refuse_stale_plain reencrypt
    _prompt_pass; _vault_lock; _refuse_stale_plain reencrypt   # the prompt first, then the lock
    _open_scratch
    _VAULT_STAGED="reencrypt"; do_encrypt; _VAULT_STAGED=""
    if [ ! -s "$VAULT_ENCRYPTED" ]; then
      echo "ERROR: $VAULT_ENCRYPTED missing or empty after encrypt."
      exit 1
    fi
    _write_fingerprints
    echo "Re-encrypted: $VAULT_ENCRYPTED ($(_file_size "$VAULT_ENCRYPTED") bytes). No plaintext left."
    ;;

  kdf)
    if [ ! -f "$VAULT_ENCRYPTED" ]; then
      echo "ERROR: $VAULT_ENCRYPTED not found."
      exit 1
    fi
    do_kdf
    ;;

  decrypt)
    if [ ! -f "$VAULT_ENCRYPTED" ]; then
      echo "ERROR: $VAULT_ENCRYPTED not found. Nothing to decrypt."
      exit 1
    fi
    _prompt_pass
    _vault_lock   # never hand out a copy read in the middle of another run's rewrite
    do_decrypt
    echo "Decrypted: $VAULT_PLAIN"
    ;;

  deploy)
    # Every interactive input first — the password, and at a terminal whether to keep the
    # decrypted vault.json — then the lock, so no other run waits on this one's prompts.
    if [ ! -f "$VAULT_PLAIN" ]; then
      [ -f "$VAULT_ENCRYPTED" ] || { echo "ERROR: Neither $VAULT_PLAIN nor $VAULT_ENCRYPTED found."; exit 1; }
      _prompt_pass
    fi
    _keep_plain=""
    if [ -t 0 ]; then
      printf "After deploying, delete the decrypted vault.json? [Y/n] "
      read -r answer
      case "${answer:-Y}" in n|N) _keep_plain=1 ;; esac
    fi
    _vault_lock   # the plaintext it decrypts must not be edited or removed under it
    if [ ! -f "$VAULT_PLAIN" ]; then
      echo "Decrypting vault..."
      do_decrypt
      _VAULT_DEPLOY_DEC=1   # ours: the exit trap shreds it should the deploy fail
    fi

    echo "Deploying tokens to their target locations..."
    deploy_mcp_tokens

    echo ""
    echo "Tokens deployed."
    if [ -t 0 ]; then
      if [ -z "$_keep_plain" ]; then
        rm -f "$VAULT_PLAIN"
        echo "Deleted vault.json."
      else
        echo "Kept vault.json — remember to delete it manually."
      fi
    else
      echo "Non-interactive mode — removing vault.json automatically."
      rm -f "$VAULT_PLAIN"
    fi
    ;;

  status)
    if [ -f "$VAULT_PLAIN" ]; then
      echo "Vault (plaintext): EXISTS"
      python3 -c "import json; v=json.load(open('$VAULT_PLAIN')); [print(f'  {k}: {list(s.keys())}') for k,s in v.items() if k != '_meta']"
    else
      echo "Vault (plaintext): not present"
      echo "  key names: VAULT_PASS=… vault-manage.sh keys [<prefix>]  (decrypts in tmpfs, names only)"
    fi
    if [ -f "$VAULT_ENCRYPTED" ]; then
      echo "Vault (encrypted): EXISTS ($(_file_size "$VAULT_ENCRYPTED") bytes)"
    else
      echo "Vault (encrypted): not present"
    fi
    ;;

  *)
    echo "Usage: bash setup/secrets/vault-manage.sh {encrypt|decrypt|deploy|status|keys|set|unset|shm|shm-clean|fingerprints|reencrypt|kdf}"
    echo ""
    echo "  encrypt    — Encrypt vault.json -> vault.json.enc (password prompt)"
    echo "  decrypt    — Decrypt vault.json.enc -> vault.json (password prompt)"
    echo "  deploy     — Decrypt (if needed) + write tokens to MCP configs"
    echo "  status     — Which vault files exist (key names only from a plaintext vault.json)"
    echo "  keys [<prefix>] — Key names from the ciphertext, decrypted in tmpfs; never a value"
    echo "  set <key>  — Store a value read from stdin under a dotted key"
    echo "  unset <key> [<key>…] — Delete dotted keys in one rewrite; refuses if any is absent or _meta"
    echo "             'prefix*' (3+ literal chars) previews its matches; add --yes to remove them"
    echo "  shm <key>  — One value into a mode-600 /dev/shm/vault-key.*.txt for a browser login (path + length only)"
    echo "  shm-clean [path] — Shred the bridge file(s)"
    echo "  fingerprints — Refresh the commit guard's salted fingerprints from a plaintext vault.json"
    echo "  reencrypt  — Decrypt + encrypt in one step (upgrades the KDF work factor)"
    echo "  kdf        — Report the PBKDF2 iteration count that opens the vault"
    echo ""
    echo "  Set VAULT_PASS env var for non-interactive use."
    ;;
esac
