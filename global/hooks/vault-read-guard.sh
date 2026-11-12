#!/usr/bin/env bash
# PreToolUse hook: block direct reads of the plaintext vault (secrets/vault.json,
# or any <prefix>-vault.json). Direct plaintext reads bypass vault-manage.sh and
# may hit stale data (LRN S210 — agent read stale plaintext that had drifted from
# the encrypted source-of-truth for months).
#
# Allowed: any command that goes through vault-manage.sh.
# Blocked: cat/head/tail/less/more/grep/awk/sed/jq/xxd/od/python/python3 of vault.json,
#          or cp/mv that would copy plaintext elsewhere.
# Exit 2 = block with message. Exit 0 = allow.

INPUT=$(cat)

# Only care about Bash tool
case "$INPUT" in
    *'"tool_name":"Bash"'*|*'"tool_name": "Bash"'*) ;;
    *) exit 0 ;;
esac

# Extract command
CMD=""
if command -v jq &>/dev/null; then
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
    CMD=$(echo "$INPUT" | grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"command"[^"]*"\([^"]*\)"/\1/')
fi
[ -z "$CMD" ] && exit 0

# WHICH paths are credential stores lives in lib-credential-paths.sh (CFG-960), shared with
# credential-read-guard.sh (Read/Grep/NotebookRead) so the two guards cannot drift apart:
#   vault     a plaintext vault as a path (preceded by /, space, or start; followed by space,
#             end, or non-alnum): `secrets/vault.json`, `secrets/other-vault.json` — NOT
#             `test-vault-manage.sh` (no .json) or `vault.json.tmp` (alnum follows).
#   settings  CFG-892: the LIVE settings.json is a credential store too — its env block
#             carries tokens (AFD_TOKEN and others), and a subagent asked to "read the
#             settings" printed them into its transcript (2026-10-30). Live =
#             $CLAUDE_CONFIG_DIR/settings.json, a cc-mirror variant's config/settings.json,
#             or ~/.claude/settings.json (live on hosts that symlink the two). NOT the repo
#             template (setup/config/settings.json: no secrets by invariant) and NOT a
#             project's <project>/.claude/settings.json. A suffix (.bak) is a copy: blocked.
# Without the lib (a broken deploy — sync.sh ships hook and lib in one loop) every
# vault.json / settings.json mention counts: a false block, never a read.
if source "$(dirname "${BASH_SOURCE[0]}")/lib-credential-paths.sh" 2>/dev/null && [ -n "${CRED_SETTINGS_RE:-}" ]; then
    VAULT_RE="$CRED_VAULT_RE"; SETTINGS_RE="$CRED_SETTINGS_RE"
    LIVE_RE="$CRED_LIVE_MARKER_RE"; HOME_RE="$CRED_HOME_MARKER_RE"
else
    VAULT_RE='vault\.json'; SETTINGS_RE='settings\.json'; LIVE_RE='.'; HOME_RE='.'
fi
VAULT_HIT=0; SETTINGS_HIT=0
echo "$CMD" | grep -qE "$VAULT_RE" && VAULT_HIT=1
echo "$CMD" | grep -qE "$SETTINGS_RE" && SETTINGS_HIT=1
# CFG-959: a path BUILT at run time — os.environ['CLAUDE_CONFIG_DIR']+'/settings.json',
# Path.home()/'.cc-mirror'/…/'settings.json', D=$CLAUDE_CONFIG_DIR; … $D/settings.json — never
# spells the live path, so the match above misses it. A settings.json that is not a known
# non-live spelling (the repo template, a <dir>/.claude/settings.json) counts as live when the
# command also names a live location: CLAUDE_CONFIG_DIR, .cc-mirror, or a home-relative .claude.
if [ "$SETTINGS_HIT" = 0 ]; then
    REST=${CMD//"setup/config/settings.json"/}; REST=${REST//"/.claude/settings.json"/}
    if [[ "$REST" == *settings.json* ]] && { [[ "$CMD" =~ $LIVE_RE ]] ||
         { [[ "$CMD" =~ $HOME_RE ]] && [[ "$CMD" == *.claude* ]]; }; }; then
        SETTINGS_HIT=1
    fi
fi

[ "$VAULT_HIT" = 1 ] || [ "$SETTINGS_HIT" = 1 ] || exit 0

# Allow the legitimate intermediary (the vault's — it says nothing about the settings)
if [ "$SETTINGS_HIT" = 0 ]; then
    case "$CMD" in
        *"vault-manage.sh"*) exit 0 ;;
    esac
fi

# ── What the verb match may see (CFG-621) ────────────────────────────────────
# The blocked-verb list contains the English words `more` and `less`; a commit whose MESSAGE
# read "describe secrets/vault.json more usefully" was blocked although it read nothing. So
# the verb checks below run on SCAN: the command with git commit-message bodies removed
# (lib-commit-message-strip.sh carries the rules and their rationale). The path check above
# stays on the full string. Without the lib or python3 nothing is stripped and the match
# runs over the raw command: that degrades toward a false block, never toward a read.
SCAN="$CMD"
if source "$(dirname "${BASH_SOURCE[0]}")/lib-commit-message-strip.sh" 2>/dev/null \
   && type strip_commit_messages &>/dev/null; then
    _stripped=$(strip_commit_messages "$CMD") && [ -n "$_stripped" ] && SCAN="$_stripped"
fi

# No metadata exemption (CFG-959). Metadata ops (rm, ls, stat, test, readlink, chmod …) carry
# no read primitive and fall through to the final exit 0 on their own. An exemption keyed on
# their PRESENCE let `S=<live>; ls -la $S; readlink -f $S; python3 - <<EOF … open(S) … EOF`
# through: it fired on the `ls` and looked only for a PIPE into a reader, and a heredoc read
# is no pipe. A read primitive anywhere in SCAN blocks, whatever sits beside it.

# Where is vault-manage.sh? Resolved at RUN TIME so that no copy of this hook — it
# ships verbatim in the public template — spells out one deployment's vault location
# (CFG-869). Order: CC_VAULT_MANAGE; the config repo this hook was deployed from
# (~/.claude/foundation is a symlink into <repo>/global/, and from a checkout the
# hook's own parent is <repo>/global/hooks); the conventional checkout names. Each
# root is tried in both layouts, secrets/ (private config repo) and setup/secrets/
# (template clone). Nothing found: a placeholder, never a hard-coded path.
_vault_manage_path() {
    local root c
    [ -n "${CC_VAULT_MANAGE:-}" ] && [ -f "$CC_VAULT_MANAGE" ] && { printf '%s' "$CC_VAULT_MANAGE"; return; }
    root=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/../foundation" 2>/dev/null) || root=""
    root="${root%/global/foundation}"
    for root in "$root" "$HOME/cfg-agent-fleet" "$HOME/agent-fleet"; do
        [ -n "$root" ] || continue
        for c in "$root/secrets/vault-manage.sh" "$root/setup/secrets/vault-manage.sh"; do
            [ -f "$c" ] && { printf '%s' "$c"; return; }
        done
    done
    printf '%s' '<config-repo>/secrets/vault-manage.sh'
}

# The masked settings reader, resolved like vault-manage.sh above (no deployment path baked in).
_settings_view_path() {
    local root
    root=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/../foundation" 2>/dev/null) || root=""
    root="${root%/global/foundation}"
    for root in "$root" "$HOME/cfg-agent-fleet" "$HOME/agent-fleet"; do
        [ -n "$root" ] && [ -f "$root/setup/scripts/settings-view.sh" ] && {
            printf '%s' "$root/setup/scripts/settings-view.sh"; return; }
    done
    printf '%s' '<config-repo>/setup/scripts/settings-view.sh'
}

# Block: command contains a read primitive or a copy-elsewhere primitive. CFG-960: ln (a
# hardlink twin shares the credential's inode under a name no shape knows), install, rsync
# and dd (if=) mint an alias or a copy — the file guard catches the twin by inode, this
# closes the side that creates it.
READ_VERB_RE='\b(cat|head|tail|less|more|grep|awk|sed|jq|xxd|od|python[23]?|node|cp|mv|tee|tar|zip|ln|install|rsync|dd)\b'
if [ "$SETTINGS_HIT" = 1 ] && echo "$SCAN" | grep -qE "$READ_VERB_RE"; then
    SV=$(_settings_view_path)
    cat >&2 <<BLOCKED_SETTINGS
BLOCKED (CFG-892): the live settings.json is a credential store — its env block holds
tokens (AFD_TOKEN and others), and reading it raw prints them into the transcript.
Use the masked reader (env values masked unless the fleet template declares the key):

  bash $SV                # the whole file, env values masked
  bash $SV | jq .hooks    # any part of it

ls/stat/test on the file stay allowed. Never print a credential's value.
BLOCKED_SETTINGS
    exit 2
fi
if [ "$VAULT_HIT" = 1 ] && echo "$SCAN" | grep -qE "$READ_VERB_RE"; then
    VM=$(_vault_manage_path)
    cat >&2 <<BLOCKED_MSG
BLOCKED: Direct read/copy of secrets/vault.json bypasses vault-manage.sh and risks
stale-plaintext drift (LRN S210). Use the canonical tool instead:

  bash $VM decrypt   # decrypt to vault.json
  bash $VM deploy    # deploy tokens to targets
  bash $VM status    # show keys (no decryption)

There is ONE vault and one passphrase (see knowledge/vault-ops.md).

If you genuinely need to override this hook (e.g., emergency recovery), drop
the matching PreToolUse entry from settings.json temporarily and restart CC.
BLOCKED_MSG
    exit 2
fi

# Any other op against vault.json that isn't whitelisted — allow but with warning to stderr
exit 0
