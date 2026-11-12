#!/usr/bin/env bash
# lib-credential-paths.sh — WHICH files are credential stores (CFG-960). One list, two
# readers: vault-read-guard.sh judges a Bash command's TEXT, credential-read-guard.sh judges
# the PATH a Read / Grep / NotebookRead call names. A file the Bash guard refuses to `cat`
# must not be readable through the Read tool, and the reverse — so both take the list here.
#
# The regexes are ERE over a STRING, which is what lets one spelling serve both: a command
# line ("jq .env $CLAUDE_CONFIG_DIR/settings.json") and an expanded, resolved path
# (/home/<u>/.cc-mirror/<variant>/config/settings.json). cred_kind_of_path rewrites a concrete
# path into the spelling the regexes know ($HOME → /home/x, $CLAUDE_CONFIG_DIR → the literal
# variable) and ALSO compares it, resolved, with the live files, so a config dir under any name
# and a symlink alias are caught without a shape for them.
#
# The classes, and why each is a credential store:
#   settings     the Claude Code settings.json whose env block carries tokens (AFD_TOKEN and
#                others, CFG-892): $CLAUDE_CONFIG_DIR/settings.json, a cc-mirror variant's
#                config/settings.json, <home>/.claude/settings.json — live where the two are
#                symlinked, and everywhere else a DEPLOYED COPY with the same env block
#                (measured 2026-11-11: a 64-char AFD_TOKEN in a copy that is not the live
#                file). A suffix (settings.json.bak) is a copy. NOT the repo template
#                setup/config/settings.json (no secrets by invariant) and NOT a project's
#                <project>/.claude/settings.json.
#   mcp          the live .mcp.json copies — server env blocks hold API tokens: <home>/.mcp.json,
#                $CLAUDE_CONFIG_DIR/.mcp.json, a variant's config/.mcp.json, <home>/.claude/.mcp.json.
#                NOT the repo's templates (mcp.json.template, setup/config-*/.mcp.json).
#   credentials  Claude Code's OAuth store .credentials.json, wherever a copy sits.
#   git          .git-credentials (plaintext PATs), wherever a copy sits.
#   vault        the plaintext token vault, vault.json or <prefix>-vault.json in any directory;
#                vault.json.enc (ciphertext) is fine.
#   nas          /etc/nas-credentials (the NAS password), or a copy by that name.
#
# Contract (every function is pure, nothing here reads a credential file's CONTENT):
#   cred_kind_of_string <s>            kind on stdout, 1 when <s> names no credential store
#   cred_kind_of_path <raw> [cwd]      the same for a tool path, expanded and resolved
#   cred_files_under <raw-dir> [cwd]   existing credential files under a directory, one per line
#   cred_expand_path / cred_resolve_path / cred_live_files / cred_repo_tool / cred_refusal

[[ "${_LIB_CREDENTIAL_PATHS_LOADED:-}" == "true" ]] && return 0
_LIB_CREDENTIAL_PATHS_LOADED="true"

# ── the list, in text form (verbatim the regexes vault-read-guard.sh carried before CFG-960) ──
CRED_HOME_RE='(~|\$HOME|\$\{HOME\}|/home/[^/[:space:]]+|/root|/Users/[^/[:space:]]+)'
CRED_SETTINGS_RE="(\.cc-mirror/[^/[:space:]]+/config/settings\.json|CLAUDE_CONFIG_DIR\}?/settings\.json|${CRED_HOME_RE}/\.claude/settings\.json)"
CRED_MCP_RE="(\.cc-mirror/[^/[:space:]]+/config/\.mcp\.json|CLAUDE_CONFIG_DIR\}?/\.mcp\.json|${CRED_HOME_RE}/(\.claude/)?\.mcp\.json)"
CRED_VAULT_RE='(^|[[:space:]/])([A-Za-z0-9_]+-)?vault\.json([[:space:]]|$|[^a-zA-Z0-9.])'
CRED_CREDENTIALS_RE='(^|[[:space:]/])\.credentials\.json([[:space:]]|$|[^a-zA-Z0-9])'
CRED_GIT_RE='(^|[[:space:]/])\.git-credentials([[:space:]]|$|[^a-zA-Z0-9])'
CRED_NAS_RE='(^|[[:space:]/])nas-credentials([[:space:]]|$|[^a-zA-Z0-9])'
# CFG-959: a settings.json built at run time counts as live when the command also names a
# live location (first) or a home resolver together with .claude (second).
CRED_LIVE_MARKER_RE='CLAUDE_CONFIG_DIR|\.cc-mirror|~/\.claude'
CRED_HOME_MARKER_RE='HOME|Path\.home\(|expanduser\(|homedir\('

cred_kind_of_string() {   # <string> → settings|mcp|credentials|git|vault|nas ; 1 = none
    local s="$1"
    [[ "$s" =~ $CRED_SETTINGS_RE ]]    && { echo settings;    return 0; }
    [[ "$s" =~ $CRED_MCP_RE ]]         && { echo mcp;         return 0; }
    [[ "$s" =~ $CRED_CREDENTIALS_RE ]] && { echo credentials; return 0; }
    [[ "$s" =~ $CRED_GIT_RE ]]         && { echo git;         return 0; }
    [[ "$s" =~ $CRED_VAULT_RE ]]       && { echo vault;       return 0; }
    [[ "$s" =~ $CRED_NAS_RE ]]         && { echo nas;         return 0; }
    return 1
}

# ── path form ────────────────────────────────────────────────────────────────
cred_expand_path() {   # <raw> [cwd] → ~, $HOME, ${HOME} expanded; a relative path joined to cwd
    local p="$1" cwd="${2:-$PWD}"
    case "$p" in
        '~') p="$HOME" ;; '~/'*) p="$HOME/${p#\~/}" ;;
        '$HOME') p="$HOME" ;; '$HOME/'*) p="$HOME/${p#\$HOME/}" ;;
        '${HOME}') p="$HOME" ;; '${HOME}/'*) p="$HOME/${p#\$\{HOME\}/}" ;;
    esac
    [[ "$p" == /* ]] || p="${cwd%/}/$p"
    printf '%s' "$p"
}

# Every call that touches the target's filesystem is bounded: a dead CIFS/9P mount must not
# stall every Read under it until the hook timeout. On a timeout the caller judges the
# unresolved spelling by shape — a matching name is still refused, never allowed blindly.
_CRED_RESOLVE_TIMED_OUT=0
_cred_tmo() { if command -v timeout >/dev/null 2>&1; then timeout 5 "$@"; else "$@"; fi; }

cred_resolve_path() {   # <abs> → canonical path (symlinks, . and ..); the input when unresolvable or timed out
    local r rc=0
    r=$(_cred_tmo readlink -f "$1" 2>/dev/null) || rc=$?
    [ "$rc" = 124 ] && _CRED_RESOLVE_TIMED_OUT=1
    [ "$rc" = 0 ] && [ -n "$r" ] && { printf '%s' "$r"; return; }
    printf '%s' "$1"
}

_cred_ident() {   # <path> → "device:inode" of the file it names (a hardlink twin shares it); empty when unknown
    _cred_tmo stat -Lc '%d:%i' "$1" 2>/dev/null || _cred_tmo stat -L -f '%d:%i' "$1" 2>/dev/null || true
}

# A concrete path in the spelling the text regexes know: under $CLAUDE_CONFIG_DIR (either
# spelling of it) → "$CLAUDE_CONFIG_DIR/<rest>", under $HOME → "/home/x/<rest>".
_cred_normalize() {
    local p="$1" d
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
        for d in "$(cred_resolve_path "${CLAUDE_CONFIG_DIR%/}")" "${CLAUDE_CONFIG_DIR%/}"; do
            [[ "$p" == "$d"/* ]] && { printf '$CLAUDE_CONFIG_DIR/%s' "${p#"$d"/}"; return; }
        done
    fi
    for d in "$(cred_resolve_path "${HOME%/}")" "${HOME%/}"; do
        [[ "$p" == "$d"/* ]] && { printf '/home/x/%s' "${p#"$d"/}"; return; }
    done
    printf '%s' "$p"
}

cred_live_files() {   # the credential files that EXIST at their known locations, one per line
    local c
    local -a cands=()
    [ -n "${CLAUDE_CONFIG_DIR:-}" ] && cands+=("${CLAUDE_CONFIG_DIR%/}/settings.json" \
        "${CLAUDE_CONFIG_DIR%/}/.mcp.json" "${CLAUDE_CONFIG_DIR%/}/.credentials.json")
    cands+=("$HOME/.claude/settings.json" "$HOME/.claude/.mcp.json" "$HOME/.claude/.credentials.json" \
            "$HOME/.mcp.json" "$HOME/.git-credentials" /etc/nas-credentials
            "$HOME"/.cc-mirror/*/config/settings.json "$HOME"/.cc-mirror/*/config/.mcp.json \
            "$HOME"/.cc-mirror/*/config/.credentials.json)
    for c in "${cands[@]}"; do [ -f "$c" ] && printf '%s\n' "$c"; done
    return 0
}

cred_config_repo() {   # the config repo this lib was deployed from; 1 when none is found
    local root
    [ -n "${CC_CONFIG_REPO:-}" ] && [ -d "$CC_CONFIG_REPO/global/hooks" ] && { printf '%s' "$CC_CONFIG_REPO"; return 0; }
    root=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/../foundation" 2>/dev/null) || root=""
    root="${root%/global/foundation}"
    for root in "$root" "$HOME/cfg-agent-fleet" "$HOME/agent-fleet"; do
        [ -n "$root" ] && [ -d "$root/global/hooks" ] && [ -d "$root/setup/scripts" ] && { printf '%s' "$root"; return 0; }
    done
    return 1
}

_cred_plaintext_vaults() {   # <resolved dir> → plaintext vaults that may sit under it
    local root f
    for root in "$1" "$(cred_config_repo || true)" "$HOME/cfg-agent-fleet" "$HOME/agent-fleet"; do
        [ -n "$root" ] || continue
        for f in "$root"/*vault.json "$root"/secrets/*vault.json "$root"/setup/secrets/*vault.json; do
            [ -f "$f" ] && [[ "$f" =~ $CRED_VAULT_RE ]] && printf '%s\n' "$f"
        done
    done
    return 0
}

cred_kind_of_path() {   # <raw path> [cwd] → kind ; 1 = not a credential file
    local p r f id
    p=$(cred_expand_path "$1" "${2:-$PWD}")
    cred_kind_of_string "$(_cred_normalize "$p")" && return 0       # shape first: nothing to resolve
    _CRED_RESOLVE_TIMED_OUT=0; r=$(cred_resolve_path "$p")
    cred_kind_of_string "$(_cred_normalize "$r")" && return 0
    [ "$_CRED_RESOLVE_TIMED_OUT" = 1 ] && return 1                  # the mount hangs: shape is all there is
    id=$(_cred_ident "$r")
    while IFS= read -r f; do   # the same FILE under a name no shape knows: a custom config dir, a hardlink twin
        [ -n "$f" ] || continue
        if [ "$(cred_resolve_path "$f")" = "$r" ] || { [ -n "$id" ] && [ "$(_cred_ident "$f")" = "$id" ]; }; then
            cred_kind_of_string "$(_cred_normalize "$f")" || echo settings; return 0
        fi
    done < <(cred_live_files; _cred_plaintext_vaults "$(dirname "$r")")
    return 1
}

cred_files_under() {   # <raw dir> [cwd] → credential files at or below it the USER CAN READ, one line per file
    local dir f r
    dir=$(cred_resolve_path "$(cred_expand_path "$1" "${2:-$PWD}")"); dir="${dir%/}"
    while IFS= read -r f; do
        [ -n "$f" ] && [ -r "$f" ] || continue      # unreadable (root:600 /etc/nas-credentials) leaks nothing to a Grep
        r=$(cred_resolve_path "$f")
        [[ "$r" == "$dir" || "$r" == "$dir"/* ]] && printf '%s\t%s\n' "$r" "$f"
    done < <(cred_live_files; _cred_plaintext_vaults "$dir") | awk -F'\t' '!seen[$1]++ {print $2}'   # one line per FILE, not per spelling
    return 0
}

cred_repo_tool() {   # <relative path> → the tool in the config repo, or a placeholder (CFG-869)
    local root
    root=$(cred_config_repo) && [ -f "$root/$1" ] && { printf '%s' "$root/$1"; return; }
    printf '<config-repo>/%s' "$1"
}
_cred_vault_manage() {
    [ -n "${CC_VAULT_MANAGE:-}" ] && [ -f "$CC_VAULT_MANAGE" ] && { printf '%s' "$CC_VAULT_MANAGE"; return; }
    local p; p=$(cred_repo_tool secrets/vault-manage.sh)
    [[ "$p" == '<config-repo>/'* ]] && p=$(cred_repo_tool setup/secrets/vault-manage.sh)
    [[ "$p" == '<config-repo>/'* ]] && p='<config-repo>/secrets/vault-manage.sh'
    printf '%s' "$p"
}

cred_refusal() {   # <kind> <path> [files…] → the refusal text (caller sends it to stderr)
    local kind="$1" path="$2"; shift 2
    local sv vm; sv=$(cred_repo_tool setup/scripts/settings-view.sh); vm=$(_cred_vault_manage)
    case "$kind" in
        settings) printf 'BLOCKED (CFG-960/CFG-892): %s is a Claude Code settings.json whose env block holds tokens (AFD_TOKEN and others); Read/Grep print it raw into the transcript.\nUse the masked reader (env values masked unless the fleet template declares the key):\n  bash %s                   # the live file\n  bash %s | jq .hooks       # any part of it\n  bash %s --file <path>     # a copy\nTo CHANGE a setting (Edit needs a prior Read, so never the live file): edit the fleet template\n  %s\nthen bash %s deploy. ls/stat on the file stay allowed. Never print a credential'\''s value.\n' \
            "$path" "$sv" "$sv" "$sv" "$(cred_repo_tool setup/config/settings.json)" "$(cred_repo_tool sync.sh)" ;;
        mcp) printf 'BLOCKED (CFG-960): %s is a live .mcp.json — its server env blocks hold API tokens.\nFor the server list and shape read the repo template (setup/config/mcp.json.template); for a token name its vault key (bash %s status lists keys) — never read or print the value.\n' "$path" "$vm" ;;
        credentials) printf 'BLOCKED (CFG-960): %s is Claude Code'\''s OAuth credential store (.credentials.json). Nothing in it is for reading — /login manages it, and a stale copy is still a token. Name the account, never the value.\n' "$path" ;;
        git) printf 'BLOCKED (CFG-960): %s is the plaintext git credential store (PATs). Check auth with `git ls-remote <remote>`; rotate through the vault (bash %s deploy); name the vault key, never read or print the value.\n' "$path" "$vm" ;;
        vault) printf 'BLOCKED (CFG-960): %s is the plaintext token vault. Use the canonical tool (knowledge/vault-ops.md):\n  bash %s status    # keys, no values\n  bash %s decrypt | deploy | encrypt\nThe ciphertext vault.json.enc is readable. Name the key, never print a credential'\''s value.\n' "$path" "$vm" "$vm" ;;
        nas) printf 'BLOCKED (CFG-960): %s holds the NAS password. Use the mount (/mnt/nas) or `smbclient -A /etc/nas-credentials`; the vault key is `nas` — name it, never read or print the value.\n' "$path" ;;
        dir) printf 'BLOCKED (CFG-960): a Grep over %s would read these credential files:\n' "$path"
             printf '  %s\n' "$@"
             printf 'Narrow the path to a subdirectory that holds none, or Read the one non-credential file you need. A glob/type filter is not accepted: ripgrep'\''s glob dialect (braces, negation, **) cannot be re-verified here, and a wrong exclusion is a leak.\n'
             case "$*" in *vault.json*) printf 'A plaintext vault.json is listed: bash %s encrypt removes it; until then Grep its repo'\''s subdirectories.\n' "$vm" ;; esac ;;
    esac
}
