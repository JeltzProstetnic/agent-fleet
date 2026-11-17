#!/usr/bin/env bash
# PreToolUse hook (Bash): block a command that READS a credential store (CFG-960) — the
# plaintext vault (secrets/vault.json or any <prefix>-vault.json: a direct read bypasses
# vault-manage.sh and may hit stale data, LRN S210), the live settings.json (its env block
# carries tokens, CFG-892), the live .mcp.json copies, Claude Code's .credentials.json,
# .git-credentials and /etc/nas-credentials.
#
# WHICH paths those are lives in lib-credential-paths.sh, shared with credential-read-guard.sh
# (the Read/Grep/NotebookRead tools). WHAT a command line does to one — reader verbs, `< f`
# redirects, `source`, interpreters, recursive searches over a directory, quote/glob/brace
# spellings — lives in lib-cred-command-scan.sh. The refusal texts (the masked reader for a
# settings.json, "name the vault key, never the value" for the rest) come from cred_refusal.
#
# Allowed: metadata (ls, stat, test, readlink, rm), a credential's consumers (mount -o
# credentials=, smbclient -A), vault-manage.sh and settings-view.sh on their own, and a git
# commit MESSAGE that only mentions a path (CFG-621: the message is stripped before the
# reader match; the path match runs on the full text). A read primitive anywhere in the
# command blocks, whatever metadata sits beside it (CFG-959: `S=<live>; ls $S; python3 - <<EOF
# open(S) EOF` printed the env block through a metadata exemption).
#
# Without the libs (a broken deploy — sync.sh ships hook and libs in one loop) the legacy
# path at the end runs on crude regexes and the pre-CFG-960 verb list: every vault.json or
# settings.json mention beside a reader verb counts — a false block, never a read.
# Exit 2 + stderr = block. Exit 0 = allow.

INPUT=$(cat)
case "$INPUT" in
    *'"tool_name":"Bash"'*|*'"tool_name": "Bash"'*) ;;
    *) exit 0 ;;
esac
CMD=""; CWD=""
if command -v jq &>/dev/null; then
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
else
    CMD=$(echo "$INPUT" | grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"command"[^"]*"\([^"]*\)"/\1/')
fi
[ -z "$CMD" ] && exit 0
[ -n "$CWD" ] || CWD="$PWD"

_HERE=$(dirname "${BASH_SOURCE[0]}")
source "$_HERE/lib-credential-paths.sh" 2>/dev/null || true
source "$_HERE/lib-cred-command-scan.sh" 2>/dev/null || true

# Where is vault-manage.sh / settings-view.sh? Resolved at RUN TIME so that no copy of this
# hook — it ships verbatim in the public template — spells out one deployment's paths
# (CFG-869). Order: CC_VAULT_MANAGE; the config repo this hook was deployed from
# (~/.claude/foundation is a symlink into <repo>/global/; from a checkout the hook's own parent
# is <repo>/global/hooks); the conventional checkout names, in both layouts, secrets/ (private
# config repo) and setup/secrets/ (template clone). Nothing found: a placeholder.
_vault_manage_path() {
    local root c
    [ -n "${CC_VAULT_MANAGE:-}" ] && [ -f "$CC_VAULT_MANAGE" ] && { printf '%s' "$CC_VAULT_MANAGE"; return; }
    root=$(readlink -f "$_HERE/../foundation" 2>/dev/null) || root=""
    root="${root%/global/foundation}"
    for root in "$root" "$HOME/cfg-agent-fleet" "$HOME/agent-fleet"; do
        [ -n "$root" ] || continue
        for c in "$root/secrets/vault-manage.sh" "$root/setup/secrets/vault-manage.sh"; do
            [ -f "$c" ] && { printf '%s' "$c"; return; }
        done
    done
    printf '%s' '<config-repo>/secrets/vault-manage.sh'
}
_settings_view_path() {
    local root
    root=$(readlink -f "$_HERE/../foundation" 2>/dev/null) || root=""
    root="${root%/global/foundation}"
    for root in "$root" "$HOME/cfg-agent-fleet" "$HOME/agent-fleet"; do
        [ -n "$root" ] && [ -f "$root/setup/scripts/settings-view.sh" ] && {
            printf '%s' "$root/setup/scripts/settings-view.sh"; return; }
    done
    printf '%s' '<config-repo>/setup/scripts/settings-view.sh'
}

# ── What the reader match may see (CFG-621) ──────────────────────────────────
# A commit whose MESSAGE read "describe secrets/vault.json more usefully" was blocked although
# it read nothing (`more` is a pager). The reader checks run on SCAN: the command with git
# commit-message bodies removed (lib-commit-message-strip.sh carries the rules). Without the
# lib or python3 nothing is stripped: a false block, never a read.
_scan_of() {
    local s
    if source "$_HERE/lib-commit-message-strip.sh" 2>/dev/null && type strip_commit_messages &>/dev/null \
       && s=$(strip_commit_messages "$1") && [ -n "$s" ]; then printf '%s' "$s"; else printf '%s' "$1"; fi
}

# ── The shared-lib path ──────────────────────────────────────────────────────
if type cred_cmd_reader &>/dev/null && type cred_refusal &>/dev/null && [ -n "${CRED_SETTINGS_RE:-}" ]; then
    UNQ=$(cred_cmd_unquote "$CMD")
    KIND=$(cred_cmd_kinds "$UNQ" "$CMD") || KIND=""
    # Nothing credential-shaped, no recursive searcher or enumeration, and no reader beside a
    # path-like operand: allow at once, without the python strip.
    if [ -z "$KIND" ] && ! printf '%s' "$UNQ" | LC_ALL=C grep -qE "$CRED_RECURSIVE_RE|$CRED_ENUM_RE" \
       && ! { [[ "$UNQ" == *[/~\$\*\?\[\{]* ]] && cred_cmd_reader "$UNQ"; }; then
        exit 0
    fi
    SCAN=$(_scan_of "$CMD"); UNQS=$(cred_cmd_unquote "$SCAN")
    READER=0; cred_cmd_reader "$UNQS" && READER=1
    SHOWN=$(cred_cmd_match "$UNQ") || SHOWN=""
    if [ -z "$KIND" ] && [ "$READER" = 1 ] && HIT=$(cred_cmd_operand_kinds "$UNQS" "$CWD"); then
        KIND="${HIT%%$'\t'*}"; SHOWN="${HIT#*$'\t'}"
        case "$KIND" in
            dir)      mapfile -t _lines <<<"$SHOWN"; cred_refusal dir "${_lines[0]}" "${_lines[@]:1}" >&2; exit 2 ;;
            overflow) cred_refusal overflow "$SHOWN" >&2; exit 2 ;;
        esac
    fi
    if [ -n "$KIND" ] && [ "$READER" = 1 ]; then
        cred_refusal "$KIND" "${SHOWN:-$KIND}" >&2
        exit 2
    fi
    if [ -z "$KIND" ] && DIRHIT=$(cred_cmd_recursive_dirs "$UNQS" "$CWD" "$SCAN"); then
        mapfile -t _lines <<<"$DIRHIT"
        cred_refusal dir "${_lines[0]}" "${_lines[@]:1}" >&2
        exit 2
    fi
    exit 0
fi

# ── Legacy path: no libs beside this hook ────────────────────────────────────
VAULT_HIT=0; SETTINGS_HIT=0
echo "$CMD" | grep -qE 'vault\.json' && VAULT_HIT=1
echo "$CMD" | grep -qE 'settings\.json' && SETTINGS_HIT=1
[ "$VAULT_HIT" = 1 ] || [ "$SETTINGS_HIT" = 1 ] || exit 0
SCAN=$(_scan_of "$CMD")
READ_VERB_RE='\b(cat|head|tail|less|more|grep|awk|sed|jq|xxd|od|python[23]?|node|cp|mv|tee|tar|zip|ln|install|rsync|dd)\b'
if [ "$SETTINGS_HIT" = 1 ] && echo "$SCAN" | grep -qE "$READ_VERB_RE"; then
    SV=$(_settings_view_path)
    cat >&2 <<BLOCKED_SETTINGS
BLOCKED (CFG-892): the live settings.json is a credential store — its env block holds
tokens (AFD_TOKEN and others), and reading it raw prints them into the transcript.
Use the masked reader (env values masked unless the fleet template declares the key):

  bash $SV                # the whole file, env values masked
  bash $SV | jq .hooks    # any part of it

(lib-credential-paths.sh is missing next to this hook — redeploy with sync.sh deploy; until
then every settings.json mention counts.) ls/stat/test on the file stay allowed. Never print
a credential's value.
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
exit 0
