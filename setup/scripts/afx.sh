#!/usr/bin/env bash
# afx — fleet dispatcher: `afx <verb> [args…]` runs the fleet script <verb> from the config repo
# (CFG-1093 Q-1093-NAMING/-CMDNAME, built as a CFG-1087 slice). Rules and hook messages name a verb, never a
# platform-specific path: the dispatcher finds the repo, picks the interpreter and converts paths for native
# programs, so the same words work in bash on Linux/macOS/WSL, in Git Bash and (through afx.cmd) in PowerShell.
#
#   afx <verb> [args…]     run it; the verb's exit code is afx's
#   afx --list             every verb with its one-line description
#   afx --which <verb>     the script a verb resolves to
#   afx --install <dir>    put `afx` into <dir> (link, or a marked copy where links are unavailable) and, on
#                          native Windows, an afx.cmd shim for PowerShell/cmd; 3 when <dir>/afx is not ours
#
# A verb is the file name without .sh/.py of a script in setup/scripts/ or dms/scripts/, searched in that order
# (.sh before .py), plus exactly three names outside them: `sync` (the repo-root sync.sh) and `vault` /
# `vault-manage` (secrets/vault-manage.sh) — the root installer and secrets helpers are not verbs. Library files
# (lib-*, *-lib, *_lib) are not verbs. Anything else — an unknown name, a path, a suffix, an option-like word —
# exits 2 and runs nothing; there is no fall-through to anything else.
# .sh verbs run under the bash afx runs in; .py verbs under the Python lib-portable.sh resolves (python3, or on
# native Windows the first of python3/python/`py -3` that really is Python 3; 127 when none is). On native
# Windows a .py verb's script path and absolute-path arguments (also --opt=/abs) are converted with `cygpath -m`;
# .sh verbs, and every verb off native Windows, get their arguments byte for byte. The verb sees CONFIG_REPO set
# to the repo afx resolved — found like the hooks find it (lib-detect-repo.sh): a set CONFIG_REPO wins, so with
# the fleet's settings.json env a worktree's or template clone's afx still dispatches to $CONFIG_REPO's scripts.
# afx.cmd passes %* through cmd.exe, which re-parses it: quote arguments carrying & | ^ < > or %…% from PowerShell.
set -uo pipefail

_afx_usage() {
    cat <<'EOF'
Usage: afx <verb> [args…]     run a fleet script by name
       afx --list             list the verbs
       afx --which <verb>     print the script a verb runs
       afx --install <dir>    install afx (and afx.cmd on native Windows) into <dir>
EOF
}

_afx_die() { local rc="$1"; shift; echo "afx: $*" >&2; exit "$rc"; }

# Real path of a file, following symlinks (readlink -f where it exists; a manual walk elsewhere).
_afx_realpath() {
    local p="$1" d l
    if readlink -f / >/dev/null 2>&1; then readlink -f "$p"; return; fi
    while [ -L "$p" ]; do
        d=$(cd "$(dirname "$p")" && pwd -P); l=$(readlink "$p")
        case "$l" in /*) p="$l" ;; *) p="$d/$l" ;; esac
    done
    echo "$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
}

AFX_SELF="$(_afx_realpath "${BASH_SOURCE[0]}")"
AFX_SELF_DIR="$(dirname "$AFX_SELF")"

# Libraries: the repo this file lives in first (a clone or worktree uses its own), then the deployed copies.
_AFX_LIBDIR=""
for _d in "$AFX_SELF_DIR/../../global/hooks" "$HOME/.claude/hooks"; do
    if [ -f "$_d/lib-portable.sh" ] && [ -f "$_d/lib-detect-repo.sh" ]; then _AFX_LIBDIR="$_d"; break; fi
done
if [ -n "$_AFX_LIBDIR" ]; then
    # shellcheck source=../../global/hooks/lib-portable.sh
    source "$_AFX_LIBDIR/lib-portable.sh"
    # shellcheck source=../../global/hooks/lib-detect-repo.sh
    source "$_AFX_LIBDIR/lib-detect-repo.sh"
fi

_afx_repo() {
    local r=""
    if declare -F _detect_config_repo >/dev/null; then
        r="$(_detect_config_repo)"
    elif [ -n "${CONFIG_REPO:-}" ] && [ -f "${CONFIG_REPO}/sync.sh" ]; then
        r="$CONFIG_REPO"
    else
        local d
        for d in "$HOME/cfg-agent-fleet" "$HOME/agent-fleet"; do [ -f "$d/sync.sh" ] && { r="$d"; break; }; done
    fi
    [ -n "$r" ] && [ -f "$r/sync.sh" ] || return 1
    echo "$r"
}

# A verb is lower-case letters, digits, '-' and '_', starting with a letter or digit — never a path.
_afx_valid_verb() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; }
_afx_is_lib() { [[ "$1" == lib-* || "$1" == *-lib || "$1" == *_lib || "$1" == afx ]]; }
AFX_DIRS=(setup/scripts dms/scripts)

# _afx_resolve <repo> <verb> — prints the script path; 1 when the verb does not exist
_afx_resolve() {
    local repo="$1" verb="$2" d ext
    _afx_valid_verb "$verb" || return 1
    _afx_is_lib "$verb" && return 1
    case "$verb" in
        sync) [ -f "$repo/sync.sh" ] && { echo "$repo/sync.sh"; return 0; }; return 1 ;;
        vault|vault-manage) [ -f "$repo/secrets/vault-manage.sh" ] && { echo "$repo/secrets/vault-manage.sh"; return 0; }; return 1 ;;
    esac
    for d in "${AFX_DIRS[@]}"; do
        for ext in sh py; do
            if [ -f "$repo/$d/$verb.$ext" ]; then
                echo "$repo/$d/$verb.$ext"
                return 0
            fi
        done
    done
    return 1
}

# First descriptive comment of a script: line 2+ `# …` (bash) or a """docstring""" (python), trimmed.
_afx_describe() {
    local f="$1" name line
    name="$(basename "$f")"
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in
            '#!'*|'') continue ;;
            '# '*) line="${line#\# }" ;;
            '"""'*) line="${line#\"\"\"}"; line="${line%\"\"\"}" ;;
            *) continue ;;
        esac
        # "name.sh — text" / "name — text" → "text"
        line="${line#"$name" — }"; line="${line#"${name%.*}" — }"
        printf '%s' "${line:0:90}"
        return 0
    done < <(head -n 6 "$f" 2>/dev/null)
}

_afx_list() {
    local repo="$1" d f base verb n=0 out="" seen=" "   # a string, not declare -A: macOS ships bash 3.2
    for d in "${AFX_DIRS[@]}"; do
        for f in "$repo/$d"/*.sh "$repo/$d"/*.py; do
            [ -f "$f" ] || continue
            base="$(basename "$f")"; verb="${base%.*}"
            _afx_valid_verb "$verb" || continue
            _afx_is_lib "$verb" && continue
            [[ "$seen" == *" $verb "* ]] && continue
            seen+="$verb "
            out+="$(printf '%-28s %s' "$verb" "$(_afx_describe "$f")")"$'\n'
            n=$((n + 1))
        done
    done
    if [ -f "$repo/sync.sh" ]; then
        out+="$(printf '%-28s %s' sync "the config repo's sync.sh (setup, deploy, check, template-push …)")"$'\n'; n=$((n + 1))
    fi
    if [ -f "$repo/secrets/vault-manage.sh" ]; then
        out+="$(printf '%-28s %s' vault-manage "$(_afx_describe "$repo/secrets/vault-manage.sh")")"$'\n'
        out+="$(printf '%-28s %s' vault "alias of vault-manage")"$'\n'; n=$((n + 2))
    fi
    printf '# %s — %d verbs\n' "$repo" "$n"
    printf '%s' "$out" | sort
}

# Native Windows only: an absolute MSYS path (or the value of --opt=/abs) → C:/… for a native program.
_afx_native_arg() {
    local a="$1"
    if _afx_native; then
        case "$a" in
            /*) cygpath -m "$a"; return ;;
            --*=/*) printf '%s=%s\n' "${a%%=*}" "$(cygpath -m "${a#*=}")"; return ;;
        esac
    fi
    printf '%s\n' "$a"
}
_afx_native() { declare -F _is_native_windows >/dev/null && _is_native_windows && command -v cygpath >/dev/null 2>&1; }

_afx_run() {
    local repo="$1" verb="$2" script; shift 2
    script="$(_afx_resolve "$repo" "$verb")" || _afx_die 2 "unknown verb '$verb' — afx --list shows the verbs"
    export CONFIG_REPO="$repo"
    case "$script" in
        *.sh) exec "${BASH:-bash}" "$script" "$@" ;;
        *.py)
            declare -F _fleet_python >/dev/null || _afx_die 127 "no Python resolver (lib-portable.sh not found) for $verb"
            _fleet_python >/dev/null || _afx_die 127 "no usable Python 3 found for '$verb' (${_FLEET_PYTHON_WHY:-probe failed})"
            local args=() a
            if _afx_native; then
                # convert only path-shaped args; $(…) would strip trailing newlines from anything else
                for a in "$@"; do
                    case "$a" in /*|--*=/*) args+=("$(_afx_native_arg "$a")") ;; *) args+=("$a") ;; esac
                done
            else
                args=("$@")
            fi
            # shellcheck disable=SC2086  # `py -3` is two words by design
            local target="$script"; _afx_native && target="$(_afx_native_arg "$script")"
            exec $_FLEET_PYTHON "$target" ${args[@]+"${args[@]}"} ;;
    esac
    _afx_die 2 "cannot run $script"
}

# ---- install --------------------------------------------------------------------------------------
# Ours: a link to some clone's setup/scripts/afx.sh, or a copy carrying this file's marker line.
_afx_is_ours() {
    local f="$1"
    [ -e "$f" ] || [ -L "$f" ] || return 0
    if [ -L "$f" ]; then
        case "$(readlink "$f")" in */setup/scripts/afx.sh) return 0 ;; esac
        [ "$(_afx_realpath "$f")" = "$AFX_SELF" ] && return 0
        return 1
    fi
    grep -q '^# afx — fleet dispatcher' "$f" 2>/dev/null
}

# The Git for Windows bash.exe wrapper (it sets up PATH like Git Bash), else the bash running now.
_afx_win_bash() {
    if [ -n "${AFX_WIN_BASH:-}" ]; then cygpath -w "$AFX_WIN_BASH"; return; fi
    local root; root="$(cygpath -m / 2>/dev/null)"
    if [ -n "$root" ] && [ -f "${root%/}/bin/bash.exe" ]; then cygpath -w "${root%/}/bin/bash.exe"; return; fi
    cygpath -w "${BASH:-/usr/bin/bash}"
}

_afx_install() {
    local bin="$1" mode="copied" dst
    [ -n "$bin" ] || _afx_die 2 "--install needs a directory"
    mkdir -p "$bin" || _afx_die 1 "cannot create $bin"
    dst="$bin/afx"
    _afx_is_ours "$dst" || _afx_die 3 "$dst exists and is not ours — left untouched; use the full path or remove it"
    declare -F _link_file >/dev/null || _afx_die 1 "lib-portable.sh not found — cannot install"
    # cp writes THROUGH a symlink (onto the dispatcher itself), so drop an old link first
    [ -L "$dst" ] && rm -f "$dst"
    _link_file "$AFX_SELF" "$dst" || _afx_die 1 "could not place $dst"
    [ -L "$dst" ] && mode="linked"
    chmod +x "$dst" 2>/dev/null || true
    echo "Deployed: afx → $dst ($mode)"
    if declare -F _is_native_windows >/dev/null && _is_native_windows && command -v cygpath >/dev/null 2>&1; then
        local cmd="$bin/afx.cmd" wb target
        if [ -e "$cmd" ] && ! grep -q 'REM afx -- PowerShell/cmd shim' "$cmd" 2>/dev/null; then
            _afx_die 3 "$cmd exists and is not ours — left untouched"
        fi
        wb="$(_afx_win_bash)"; target="$(cygpath -w "$AFX_SELF")"
        printf '@echo off\r\nREM afx -- PowerShell/cmd shim for the fleet dispatcher (written by afx --install; CFG-1093).\r\nREM Calls the Git Bash that installed it: a bare "bash" in PowerShell is the WSL launcher.\r\n"%s" "%s" %%*\r\nexit /b %%ERRORLEVEL%%\r\n' \
            "$wb" "$target" > "$cmd" || _afx_die 1 "could not write $cmd"
        echo "Deployed: afx.cmd → $cmd (PowerShell/cmd; $bin must be on the Windows PATH)"
    fi
}

# ---- main -----------------------------------------------------------------------------------------
[ $# -ge 1 ] || { _afx_usage >&2; exit 2; }
case "$1" in
    -h|--help) _afx_usage; exit 0 ;;
    --install) _afx_install "${2:-}"; exit $? ;;
esac
REPO="$(_afx_repo)" || _afx_die 2 "no config repo found (cfg-agent-fleet or agent-fleet with sync.sh) — set CONFIG_REPO"
case "$1" in
    --list) _afx_list "$REPO"; exit 0 ;;
    --which)
        [ -n "${2:-}" ] || _afx_die 2 "--which needs a verb"
        _afx_resolve "$REPO" "$2" || _afx_die 2 "unknown verb '$2' — afx --list shows the verbs"
        exit 0 ;;
    -*) _afx_usage >&2; _afx_die 2 "unknown option '$1'" ;;
esac
_afx_run "$REPO" "$@"
