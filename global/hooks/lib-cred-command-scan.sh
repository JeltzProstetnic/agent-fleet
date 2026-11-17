#!/usr/bin/env bash
# lib-cred-command-scan.sh — what a Bash COMMAND LINE does to a credential store (CFG-960
# part 2). Sourced by vault-read-guard.sh after lib-credential-paths.sh, which says WHICH
# files are credential stores; this file says whether the command READS one:
#   cred_cmd_unquote <cmd>              quotes removed, so set""tings.json and ~/'.git-credentials' read as one word
#   cred_cmd_kinds <unq> <raw>          the class a spelled path belongs to (settings|mcp|credentials|git|vault|nas), or ""
#   cred_cmd_match <unq>                the spelling that matched, for the refusal text
#   cred_cmd_reader <unq>               0 when a read primitive is present: a reader verb, a `< f` / `<> f` / `$(< f)`
#                                       redirect, a `source f` / `. f`
#   cred_cmd_operand_kinds <unq> <cwd>  every path-like operand RESOLVED up to the 100th — `..`, `.`, `//`, `$(echo ~)/x`,
#                                       symlinks, hardlinks, a symlinked config dir, globs and one level of braces
#                                       (compgen: a listing, nothing executes) — → "kind<TAB>path"; a credential
#                                       DIRECTORY (spelled or reached through a glob) beside ln/cp/rsync/tar/zip/scp
#                                       → "dir<TAB>dir<NL>files…"; beyond the 100th operand only the spelling is
#                                       judged and an operand the spelling cannot judge (glob, brace, `..`, `$…`)
#                                       → "overflow<TAB>token" (the command must be split); more than 50 glob
#                                       results → the pattern's directory is judged instead (readdir order is not
#                                       sorted, so a cap would be a bypass)
#   cred_cmd_recursive_dirs <unq> <cwd> [<raw>]  a recursive search over a directory that holds a credential file — grep -r /
#                                       -R / -d recurse / --directories=recurse, rg, ag, ack, find/fd -exec|-x|-X <reader>,
#                                       and an ENUMERATION (find, fd, tree, ls) feeding a loop, a substitution or
#                                       xargs beside a reader — → "<dir>\n<file>…"; judged like the Grep tool
#
# A reader ANYWHERE in the command blocks, whatever metadata sits beside it (CFG-959); the
# words that are readers only as a command (install, rev, source, pr, view, ex, ed, …) count
# only at the head of a segment, so `pip install`, `git rev-parse`, `gh pr view`, `--source x`
# do not. No glob/type filter exempts a directory search.
#
# Accepted residuals — the guard under-blocks what it cannot resolve without executing the
# command: a path assembled at run time (`$(printf …)`, `$v/…`, `${x:-…}`, eval, variables
# beyond the run-time marker heuristics for settings.json and .mcp.json); backslash-split
# spellings (set\tings.json); a two-step alias whose link was created OUTSIDE this guard (a
# pre-existing `~/cl -> ~/.claude` is resolved and refused, but a link minted by another
# tool or user is only caught once it is READ through a resolvable path); /mnt/c and other
# case-insensitive mounts (SETTINGS.JSON folds to settings.json on NTFS; the regexes are
# case-sensitive); readers reached through aliases, functions or PATH shims; an interpreter
# that lists a directory and opens files from its own code; `sudo install`; nested braces;
# a glob under a hung mount (compgen itself cannot be bounded); a copy or archive of the
# filesystem ROOT (`cp -r / x`, `tar … /`): a bare `/` or `//` is a prose separator ("cp / mv")
# far more often than an operand, so a slash-only token is not resolved for the copy clause
# (a recursive search over `/` is still refused when `/` stands as its own shell word; one
# inside a quoted multi-word argument — `bash -c "grep -r x /"` — is taken as program text,
# CFG-980, so jq's `//` and awk's `/` beside a recursive grep pass); a symlink alias of a credential spelled as
# the 101st or later operand of one command (only the first 100 are resolved — the spelling
# is still judged there). These are documented, not silent.

[[ "${_LIB_CRED_COMMAND_SCAN_LOADED:-}" == "true" ]] && return 0
_LIB_CRED_COMMAND_SCAN_LOADED="true"

# Every regex here is ASCII; matched under LC_ALL=C because the UTF-8 multibyte path of glibc
# regex is quadratic on `([A-Za-z0-9_]+-)?` across a long run (2 MB ≈ 146 s; C locale: ms).
_cg() { LC_ALL=C grep "$@"; }

CRED_BASENAME_RE='(settings\.json|\.mcp\.json|\.credentials\.json|\.git-credentials|nas-credentials|vault\.json)'
CRED_READER_ANY_RE='\b(cat|tac|head|tail|less|more|most|grep|egrep|fgrep|rg|awk|gawk|mawk|sed|jq|yq|xxd|od|hexdump|strings|base64|base32|sort|uniq|cut|paste|cksum|(sha|md5|b2)[0-9a-z]*sum|diff|sdiff|cmp|python[23]?|node|perl|ruby|php|sqlite3|curl|wget|scp|sftp|rsync|rclone|xargs|cp|mv|ln|dd|tee|tar|zip|unzip|gzip|gunzip|zcat|xz|xzcat|bzip2|bzcat|zstd|zstdcat|7z|7za|cpio|vim|vi|nvim|nano|emacs|bat|batcat|shuf|split|iconv|expand|unexpand|fmt|gpg|age|openssl|look)\b'
CRED_READER_HEAD_RE='(^|[;&|(])[[:space:]]*(install|rev|nl|fold|column|comm|ag|ack|lua|source|pr|view|ex|ed|pager)[[:space:]]'
CRED_REDIRECT_RE="(^|[^<>])<>?[[:space:]]*[^[:space:]<>|;&()]*${CRED_BASENAME_RE}"
CRED_DOTSOURCE_RE="(^|[[:space:];&|(])\.[[:space:]]+[^[:space:]]*${CRED_BASENAME_RE}"
CRED_RECURSIVE_RE='(\b(rg|ag|ack)\b|\b(grep|egrep|fgrep)\b[^|;&]*[[:space:]](-[A-Za-z]*[rR][A-Za-z]*|--(dereference-)?recursive|-d[[:space:]]*recurse|--directories=recurse)\b|\b(find|fd)\b[^|;&]*[[:space:]]-(exec|execdir|ok|okdir|x|X|-exec)[[:space:]]|\b(find|fd)\b[^|;&]*\|[[:space:]]*xargs\b)'
CRED_ENUM_RE='\b(find|fd|tree|ls)\b'   # an enumeration counts only beside a LOOP marker and a reader (see _cred_cmd_is_recursive)
CRED_LOOP_RE='\b(while|for)\b|\$\(|<\(|`|\|[[:space:]]*xargs\b'
CRED_MCP_RUNTIME_RE='(HOME\]?|\.home\(\)|homedir\(\)|~\))[[:space:]]*\+?[[:space:]]*/\.mcp\.json'
CRED_COPY_RE='\b(ln|cp|rsync|tar|zip|scp|install)\b'

cred_cmd_unquote() { local s="$1"; s="${s//\"/}"; printf '%s' "${s//\'/}"; }

cred_cmd_kinds() {   # <unq> <raw> → class on stdout, or "" (run-time marker heuristics run too)
    local k rest
    case "$1" in *settings.json*|*.mcp.json*|*credentials*|*vault.json*) ;; *) return 1 ;; esac   # linear pre-filter
    k=$(cred_kind_of_string "$1") && { printf '%s' "$k"; return 0; }
    printf '%s' "$1" | _cg -qE "$CRED_MCP_RUNTIME_RE" && { printf 'mcp'; return 0; }
    rest=${2//"setup/config/settings.json"/}; rest=${rest//"/.claude/settings.json"/}
    if [[ "$rest" == *settings.json* ]] && { printf '%s' "$2" | _cg -qE "$CRED_LIVE_MARKER_RE" ||
         { printf '%s' "$2" | _cg -qE "$CRED_HOME_MARKER_RE" && [[ "$2" == *.claude* ]]; }; }; then
        printf 'settings'; return 0
    fi
    return 1
}

cred_cmd_match() {   # <unq> → the credential spelling that matched (first class), or ""
    local re
    for re in "$CRED_SETTINGS_RE" "$CRED_MCP_RE" "$CRED_CREDENTIALS_RE" "$CRED_GIT_RE" "$CRED_VAULT_RE" "$CRED_NAS_RE"; do
        printf '%s' "$1" | _cg -oE "$re" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*//; s/[^A-Za-z0-9_.~/$}-]+$//' | grep . && return 0
    done
    return 1
}

CRED_GIT_READER_RE='\bgit\b[^|;&]*[[:space:]](show|cat-file|hash-object)\b'   # git plumbing that prints or fingerprints a path's content

cred_cmd_reader() {   # <unq> → 0 when the command carries a read primitive
    printf '%s' "$1" | _cg -qE "$CRED_READER_ANY_RE" && return 0
    printf '%s' "$1" | _cg -qE "$CRED_READER_HEAD_RE" && return 0
    printf '%s' "$1" | _cg -qE "$CRED_GIT_READER_RE" && return 0
    printf '%s' "$1" | _cg -qE "$CRED_REDIRECT_RE" && return 0
    printf '%s' "$1" | _cg -qE "$CRED_DOTSOURCE_RE" && return 0
    return 1
}

_cred_cmd_tokens() {   # <unq> → path-like operands (a /, ~, ., $ start or a glob char), one per line; after 2048 a <<TRUNCATED>> line
    local t="${1//[;&|()<>]/ }" w n=0
    set -f; set -- $t; set +f
    for w in "$@"; do
        case "$w" in -*|*=*|'') continue ;; */*|'~'*|.*|'$'*) ;; *) [[ "$w" == *[\*\?\[\{]* ]] || continue ;; esac
        n=$((n + 1)); [ "$n" -le 2048 ] || { printf '<<TRUNCATED>>\n'; break; }
        printf '%s\n' "$w"
    done
}

_cred_cmd_bare_dirs() {   # <unq> <cwd> → bare words (no path char) that name a DIRECTORY under cwd, ≤64 checks
    local t="${1//[;&|()<>]/ }" cwd="$2" w n=0   # cwd saved first: `set --` below replaces $2
    set -f; set -- $t; set +f
    for w in "$@"; do
        case "$w" in -*|*=*|''|*/*|'~'*|.*|'$'*|*[\*\?\[\{]*) continue ;; esac
        n=$((n + 1)); [ "$n" -le 64 ] || break
        [ -d "$cwd/$w" ] && printf '%s\n' "$w"
    done
    return 0
}

_cred_cmd_brace() {   # <token> → the token's one-level brace variants, one per line
    local pre mid post a
    if [[ "$1" =~ ^([^{}]*)\{([^{}]*)\}(.*)$ ]]; then
        pre="${BASH_REMATCH[1]}"; mid="${BASH_REMATCH[2]}"; post="${BASH_REMATCH[3]}"
        IFS=',' read -r -a a <<<"$mid"
        for a in "${a[@]}"; do printf '%s\n' "$pre$a$post"; done
    else
        printf '%s\n' "$1"
    fi
}

_cred_cmd_glob_hit() {   # <expanded pattern> <cwd> <display> <copying> → a hit among the results, or the pattern's dir on overflow
    local r k hits
    local -a res=()
    mapfile -t res < <(compgen -G "$1" 2>/dev/null | head -n 51)
    if [ "${#res[@]}" -gt 50 ]; then   # the directory is judged, before any result is resolved
        hits=$(cred_files_under "$(dirname "$1")" "$2")
        [ -n "$hits" ] && { printf 'dir\t%s\n%s' "$(dirname "$3")" "$hits"; return 0; }
        return 1
    fi
    for r in "${res[@]}"; do
        [ -n "$r" ] || continue
        k=$(cred_kind_of_path "$r" "$2") && { printf '%s\t%s' "$k" "$r"; return 0; }
        if [ "${4:-0}" = 1 ] && [ -d "$r" ]; then   # a result that is a credential DIRECTORY beside a copy verb
            hits=$(cred_files_under "$r" "$2"); [ -n "$hits" ] && { printf 'dir\t%s\n%s' "$r" "$hits"; return 0; }
        fi
    done
    return 1
}

# The first 100 path-like operands are RESOLVED (readlink + inode, ~4 ms each with the roots
# cached: 100 ≈ 0.4 s); beyond that only the spelling is judged, without the filesystem, and
# an operand the spelling cannot judge — a glob, a brace, a `..`, a `$`-prefixed path — is
# refused outright (an unresolved operand could be the credential). A symlink alias past
# position 100 is the accepted residual; a plainly spelled credential there is still caught.
cred_cmd_operand_kinds() {   # <unq> <cwd> → "kind<TAB>path" | "dir<TAB>dir<NL>files…" | "overflow<TAB>token" ; 1 = nothing
    local tok v p k n=0 copying=0 hits
    printf '%s' "$1" | _cg -qE "$CRED_COPY_RE" && copying=1
    _cred_index; _cred_norm_init   # built HERE, in the parent: a $(…) below would rebuild them per operand
    if [ "$copying" = 1 ]; then   # a bare word that is a directory under cwd (`cp -r secrets /tmp`)
        while IFS= read -r tok; do
            hits=$(cred_files_under "$tok" "$2"); [ -n "$hits" ] && { printf 'dir\t%s\n%s' "$tok" "$hits"; return 0; }
        done < <(_cred_cmd_bare_dirs "$1" "$2")
    fi
    while IFS= read -r tok; do
        [ "$tok" = '<<TRUNCATED>>' ] && { printf 'overflow\t%s' "the 2049th path operand"; return 0; }
        n=$((n + 1))
        if [ "$n" -gt 100 ]; then
            case "$tok" in *[\*\?\[\{]*|*..*|'$'*) printf 'overflow\t%s' "$tok"; return 0 ;; esac
            case "$tok" in *settings.json*|*.mcp.json*|*credentials*|*vault.json*)   # the spelling alone, no filesystem
                k=$(cred_kind_of_string "$(_cred_normalize "$(cred_expand_path "$tok" "$2")")") && { printf '%s\t%s' "$k" "$tok"; return 0; } ;;
            esac
            continue
        fi
        while IFS= read -r v; do
            p=$(cred_expand_path "$v" "$2")
            if [[ "$v" == *[\*\?\[]* ]]; then
                _cred_cmd_glob_hit "$p" "$2" "$v" "$copying" && return 0
            else
                k=$(cred_kind_of_path "$v" "$2") && { printf '%s\t%s' "$k" "$v"; return 0; }
                if [ "$copying" = 1 ] && [ -d "$p" ] && [[ "$v" == *[!/]* ]]; then   # a bare / is prose ("cp / mv"), not an operand
                    hits=$(cred_files_under "$p" "$2"); [ -n "$hits" ] && { printf 'dir\t%s\n%s' "$v" "$hits"; return 0; }
                fi
            fi
        done < <(_cred_cmd_brace "$tok")
    done < <(_cred_cmd_tokens "$1")
    return 1
}

_cred_cmd_is_recursive() {   # <unq> → 0 when the command searches or enumerates directories into a reader
    local s="$1"
    if printf '%s' "$s" | _cg -qE "$CRED_RECURSIVE_RE"; then
        if [[ "$s" =~ -(exec|execdir|ok|okdir|x|X|-exec)[[:space:]]+(.*)$ ]] || [[ "$s" =~ \|[[:space:]]*xargs[[:space:]]+(.*)$ ]]; then
            printf '%s' "$s" | _cg -qE '\b(rg|ag|ack)\b|\b(grep|egrep|fgrep)\b[^|;&]*[[:space:]](-[A-Za-z]*[rR]|--(dereference-)?recursive|-d[[:space:]]*recurse|--directories=recurse)' \
                && return 0
            printf '%s' "${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}" | _cg -qE "$CRED_READER_ANY_RE" && return 0
            return 1
        fi
        return 0
    fi
    printf '%s' "$s" | _cg -qE "$CRED_ENUM_RE" && printf '%s' "$s" | _cg -qE "$CRED_LOOP_RE" \
        && printf '%s' "$s" | _cg -qE "$CRED_READER_ANY_RE" && return 0
    return 1
}

# CFG-980: a slash-only word (/, //, …) is the filesystem root only when it stands as its own
# shell word. Inside a quoted multi-word argument it is program text — jq's `//` alternative,
# awk's division, a grep pattern like '// TODO'. Quoted strings are paired left to right with
# backslash escapes honoured, so an escaped quote cannot pair two strings around a real root and
# an unterminated quote leaves the rest visible; past 64 KB the root is assumed (no O(n²) walk).
_cred_cmd_root_word() {   # <raw> → 0 when a slash-only word stands as its own shell word
    local LC_ALL=C rest="$1" out="" q sq="'" dq='"' bs='\\' re root_re
    [ "${#rest}" -le 65536 ] || return 0
    re="^(([^${sq}${dq}${bs}]|${bs}.)*)(${sq}[^${sq}]*${sq}|${dq}([^${dq}${bs}]|${bs}.)*${dq})(.*)\$"
    while [[ "$rest" =~ $re ]]; do
        q="${BASH_REMATCH[3]}"; out+="${BASH_REMATCH[1]}"
        if [[ "$q" == *[[:space:]]* ]]; then out+=" "; else out+="$q"; fi
        rest="${BASH_REMATCH[5]}"
    done
    out+="$rest"
    root_re="(^|[[:space:];&|()<>])[${sq}${dq}]?/+[${sq}${dq}]?([[:space:];&|()<>]|\$)"
    [[ "$out" =~ $root_re ]]
}

cred_cmd_recursive_dirs() {   # <unq> <cwd> [<raw>] → "<dir>" then the credential files a recursive search over it would read
    local s="$1" cwd="$2" raw="${3:-}" tok p hits n=0 root=""
    _cred_cmd_is_recursive "$s" || return 1
    _cred_index
    while IFS= read -r tok; do
        if [[ "$tok" =~ ^/+$ ]] && [ -n "$raw" ]; then   # CFG-980: judged against the raw command, once
            [ -n "$root" ] || { root=no; _cred_cmd_root_word "$raw" && root=yes; }
            [ "$root" = yes ] || continue
        fi
        n=$((n + 1))
        if [ "$n" -gt 100 ] || [ "$tok" = '<<TRUNCATED>>' ]; then   # an unresolved directory operand could be the credential dir
            printf '%s\n%s' "$tok" "(more than 100 path operands beside a recursive search: not resolved — split the command)"; return 0
        fi
        p=$(cred_expand_path "$tok" "$cwd")
        [ -d "$p" ] || continue
        hits=$(cred_files_under "$p" "$cwd")
        [ -n "$hits" ] && { printf '%s\n%s' "$tok" "$hits"; return 0; }
    done < <(_cred_cmd_tokens "$s")
    if [ "$n" -eq 0 ]; then   # no path-like operand at all: the search runs over cwd
        hits=$(cred_files_under "$cwd" "$cwd")
        [ -n "$hits" ] && { printf '%s\n%s' "$cwd" "$hits"; return 0; }
    fi
    return 1
}
