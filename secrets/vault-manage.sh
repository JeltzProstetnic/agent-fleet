#!/usr/bin/env bash
# Token vault management
# Uses openssl AES-256-CBC with PBKDF2 for symmetric encryption
#
# Usage:
#   bash secrets/vault-manage.sh encrypt   # vault.json -> vault.json.enc (prompts for password)
#   bash secrets/vault-manage.sh decrypt   # vault.json.enc -> vault.json (prompts for password)
#   bash secrets/vault-manage.sh deploy    # decrypt + write tokens to their target locations
#   bash secrets/vault-manage.sh status    # show what's in the vault (keys only, no values)
#
# Password can be passed via VAULT_PASS env var for non-interactive use:
#   VAULT_PASS="mypassword" bash secrets/vault-manage.sh deploy

set -euo pipefail
cd "$(dirname "$0")"

VAULT_PLAIN="vault.json"
VAULT_ENCRYPTED="vault.json.enc"
CIPHER="aes-256-cbc"
ITER=100000

get_pass() {
  if [ -n "${VAULT_PASS:-}" ]; then
    return
  fi
  echo -n "Password: "
  read -rs VAULT_PASS
  echo
}

get_pass_confirm() {
  get_pass
  if [ -z "${VAULT_PASS_CONFIRMED:-}" ]; then
    echo -n "Confirm: "
    read -rs VAULT_PASS2
    echo
    if [ "$VAULT_PASS" != "$VAULT_PASS2" ]; then
      echo "ERROR: Passwords don't match."
      exit 1
    fi
    VAULT_PASS_CONFIRMED=1
  fi
}

do_encrypt() {
  get_pass_confirm
  openssl enc -$CIPHER -salt -pbkdf2 -iter $ITER -in "$VAULT_PLAIN" -out "$VAULT_ENCRYPTED" -pass pass:"$VAULT_PASS"
}

do_decrypt() {
  get_pass
  openssl enc -$CIPHER -d -pbkdf2 -iter $ITER -in "$VAULT_ENCRYPTED" -out "$VAULT_PLAIN" -pass pass:"$VAULT_PASS"
  chmod 600 "$VAULT_PLAIN"
}

case "${1:-help}" in
  encrypt)
    if [ ! -f "$VAULT_PLAIN" ]; then
      echo "ERROR: $VAULT_PLAIN not found. Nothing to encrypt."
      exit 1
    fi
    do_encrypt
    echo "Encrypted: $VAULT_ENCRYPTED ($(stat -c%s 2>/dev/null || stat -f%z "$VAULT_ENCRYPTED") bytes)"
    echo "You can now safely delete $VAULT_PLAIN (it's gitignored, but still)."
    ;;

  decrypt)
    if [ ! -f "$VAULT_ENCRYPTED" ]; then
      echo "ERROR: $VAULT_ENCRYPTED not found. Nothing to decrypt."
      exit 1
    fi
    do_decrypt
    echo "Decrypted: $VAULT_PLAIN"
    ;;

  deploy)
    # Decrypt if needed
    if [ ! -f "$VAULT_PLAIN" ]; then
      if [ ! -f "$VAULT_ENCRYPTED" ]; then
        echo "ERROR: Neither $VAULT_PLAIN nor $VAULT_ENCRYPTED found."
        exit 1
      fi
      echo "Decrypting vault..."
      do_decrypt
    fi

    echo "Deploying tokens to their target locations..."

    # Deploy to MCP config (try cc-mirror path first, then standard)
    MCP_CONFIG="$HOME/.cc-mirror/mclaude/config/.mcp.json"
    [[ ! -f "$MCP_CONFIG" ]] && MCP_CONFIG="$HOME/.mcp.json"
    if [ -f "$MCP_CONFIG" ]; then
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

# GitHub personal
if 'github' in mcp['mcpServers'] and vault.get('github_personal', {}).get('token'):
    token = vault['github_personal']['token']
    if not token.startswith('PASTE'):
        mcp['mcpServers']['github']['env']['GITHUB_PERSONAL_ACCESS_TOKEN'] = token
        print("  [OK] GitHub personal token")
    else:
        print("  [SKIP] GitHub — placeholder token")

# Twitter
if 'twitter' in mcp['mcpServers'] and vault.get('twitter', {}).get('api_key'):
    tw = vault['twitter']
    if not tw['api_key'].startswith('PASTE'):
        mcp['mcpServers']['twitter']['env']['API_KEY'] = tw['api_key']
        mcp['mcpServers']['twitter']['env']['API_SECRET_KEY'] = tw['api_secret']
        mcp['mcpServers']['twitter']['env']['ACCESS_TOKEN'] = tw['access_token']
        mcp['mcpServers']['twitter']['env']['ACCESS_TOKEN_SECRET'] = tw['access_secret']
        print("  [OK] Twitter tokens (4 values)")
    else:
        print("  [SKIP] Twitter — placeholder tokens")

# Google Workspace
if 'google-workspace' in mcp['mcpServers'] and vault.get('google_workspace', {}).get('client_id'):
    gw = vault['google_workspace']
    if not gw['client_id'].startswith('PASTE'):
        mcp['mcpServers']['google-workspace']['env']['GOOGLE_OAUTH_CLIENT_ID'] = gw['client_id']
        mcp['mcpServers']['google-workspace']['env']['GOOGLE_OAUTH_CLIENT_SECRET'] = gw['client_secret']
        mcp['mcpServers']['google-workspace']['env']['USER_GOOGLE_EMAIL'] = gw['email']
        print("  [OK] Google Workspace credentials")
    else:
        print("  [SKIP] Google Workspace — placeholder credentials")

# Jira/Atlassian
if 'jira' in mcp.get('mcpServers', {}) and vault.get('jira', {}).get('api_token'):
    jira = vault['jira']
    if not jira['api_token'].startswith('PASTE'):
        env = mcp['mcpServers']['jira']['env']
        if 'url' in jira: env['JIRA_URL'] = jira['url']
        if 'email' in jira: env['JIRA_EMAIL'] = jira['email']
        env['JIRA_API_TOKEN'] = jira['api_token']
        print("  [OK] Jira credentials")
    else:
        print("  [SKIP] Jira — placeholder credentials")

# LinkedIn
if 'linkedin' in mcp.get('mcpServers', {}) and vault.get('linkedin', {}).get('access_token'):
    li = vault['linkedin']
    if not li['access_token'].startswith('PASTE'):
        env = mcp['mcpServers']['linkedin']['env']
        if 'client_id' in li: env['LINKEDIN_CLIENT_ID'] = li['client_id']
        if 'client_secret' in li: env['LINKEDIN_CLIENT_SECRET'] = li['client_secret']
        env['LINKEDIN_ACCESS_TOKEN'] = li['access_token']
        print("  [OK] LinkedIn credentials")
    else:
        print("  [SKIP] LinkedIn — placeholder credentials")

with open(mcp_path, 'w') as f:
    json.dump(mcp, f, indent=2)
    f.write('\n')

# Sync to ~/.mcp.json if we modified a different file (cc-mirror path)
global_mcp = os.path.expanduser('~/.mcp.json')
if os.path.abspath(mcp_path) != os.path.abspath(global_mcp):
    shutil.copy2(mcp_path, global_mcp)
    print("  [OK] Synced to ~/.mcp.json")

print("\nDone. Restart mclaude to pick up new tokens.")
PYEOF
    else
      echo "WARNING: $MCP_CONFIG not found. Skipping MCP deployment."
      echo "Run 'bash ~/cfg-agent-fleet/sync.sh setup' first to set up the config structure."
    fi

    # Clean up plaintext
    echo ""
    echo "Tokens deployed. Consider removing vault.json:"
    echo "  rm secrets/vault.json"
    ;;

  status)
    if [ -f "$VAULT_PLAIN" ]; then
      echo "Vault (plaintext): EXISTS"
      python3 -c "import json; v=json.load(open('$VAULT_PLAIN')); [print(f'  {k}: {list(s.keys())}') for k,s in v.items() if k != '_meta']"
    else
      echo "Vault (plaintext): not present"
    fi
    if [ -f "$VAULT_ENCRYPTED" ]; then
      echo "Vault (encrypted): EXISTS ($(stat -c%s 2>/dev/null || stat -f%z "$VAULT_ENCRYPTED") bytes)"
    else
      echo "Vault (encrypted): not present"
    fi
    ;;

  *)
    echo "Usage: bash secrets/vault-manage.sh {encrypt|decrypt|deploy|status}"
    echo ""
    echo "  encrypt  — Encrypt vault.json -> vault.json.enc (password prompt)"
    echo "  decrypt  — Decrypt vault.json.enc -> vault.json (password prompt)"
    echo "  deploy   — Decrypt (if needed) + write tokens to MCP configs"
    echo "  status   — Show vault contents (keys only)"
    echo ""
    echo "  Set VAULT_PASS env var for non-interactive use."
    ;;
esac
