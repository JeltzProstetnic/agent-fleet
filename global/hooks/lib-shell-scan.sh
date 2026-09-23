#!/usr/bin/env bash
# lib-shell-scan.sh — what would this shell command WRITE? Answered without running it
# (CFG-674). Sourced by cfg-boundary-guard.sh; per-command extractors: lib-shell-write-cmds.sh.
# Contract: the caller defines `_on_write_target ABS_PATH HOW`, sets _CWD to the directory
# relative targets resolve against, and calls `_scan_text "$command"`. Redirect targets are
# reported as they appear; command operands go through _flush_clause → _cmd_*. Heuristic by
# design: quoted strings and heredoc bodies are data, and a target that needs the command to
# run to be known (variable, substitution, unknown cwd) is skipped, never guessed.

[[ "${_LIB_SHELL_SCAN_LOADED:-}" == "true" ]] && return 0
_LIB_SHELL_SCAN_LOADED="true"
source "$(dirname "${BASH_SOURCE[0]}")/lib-shell-write-cmds.sh"

_CWD="${_CWD:-$PWD}"   # simulated working directory; "" = unknown → relatives skipped
_CWD_STACK=()
_R=""                   # result register: no command substitution, no fork
_DEPTH=0
_SCAN_ROOT_TEXT=""

# _norm ABS → _R: ABS with ./, ../ and // collapsed. Builtins only.
_norm() {
    local -a parts stack=()
    local seg out=""
    IFS='/' read -ra parts <<< "$1"
    for seg in "${parts[@]}"; do
        case "$seg" in
            ''|'.') ;;
            '..') [[ ${#stack[@]} -gt 0 ]] && unset 'stack[-1]' ;;
            *) stack+=("$seg") ;;
        esac
    done
    for seg in "${stack[@]}"; do out+="/$seg"; done
    _R="${out:-/}"
}

# _resolve TOKEN → _R, or 1 when the path cannot be known without running the command.
_resolve() {
    local t="$1"
    t="${t//\"/}"; t="${t//\'/}"; t="${t//\\/}"
    case "$t" in
        '~')         t="$HOME" ;;
        '~/'*)       t="$HOME${t:1}" ;;
        '$HOME')     t="$HOME" ;;
        '$HOME/'*)   t="$HOME${t:5}" ;;
        '${HOME}')   t="$HOME" ;;
        '${HOME}/'*) t="$HOME${t:7}" ;;
    esac
    [[ -z "$t" || "$t" == *'$'* || "$t" == *'`'* || "$t" == '~'* ]] && return 1
    if [[ "$t" != /* ]]; then
        [[ -n "$_CWD" ]] || return 1
        t="$_CWD/$t"
    fi
    _norm "$t"
}

# _check TOKEN HOW — resolve against the simulated cwd and report; _check_in BASE TOKEN HOW — under BASE.
_check() { _resolve "$1" || return 0; _on_write_target "$_R" "$2"; return 0; }
_check_in() { local save="$_CWD"; _CWD="$1"; _check "$2" "$3"; _CWD="$save"; }

_do_cd() {
    local a t=""
    for a in "$@"; do [[ "$a" == -* ]] && continue; t="$a"; break; done
    if [[ -z "$t" ]]; then _CWD="$HOME"; return 0; fi
    if [[ "$t" == "-" ]]; then _CWD=""; return 0; fi
    if _resolve "$t"; then _CWD="$_R"; else _CWD=""; fi
}

# _flush_clause — the words of one simple command are in _TOKENS (scanner-local).
_flush_clause() {
    local -a w=("${_TOKENS[@]+"${_TOKENS[@]}"}")
    _TOKENS=()
    local i=0 n=${#w[@]} tok
    while [[ $i -lt $n ]]; do   # assignments, wrappers and keywords before the command name
        tok="${w[$i]}"
        case "$tok" in
            [A-Za-z_]*=*) i=$((i + 1)) ;;
            sudo|command|exec|env|nice|nohup|time|builtin|'{'|'}'|'!'|do|then|else|elif|if|while|until) i=$((i + 1)) ;;
            -u|-g) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
        esac
    done
    if [[ $i -ge $n ]]; then _INFILE=""; return 0; fi
    local cmd="${w[$i]}"
    cmd="${cmd//\"/}"; cmd="${cmd//\'/}"; cmd="${cmd##*/}"; cmd="${cmd#\\}"
    local -a args=("${w[@]:$((i + 1))}")
    case "$cmd" in
        cd|pushd)   _do_cd "${args[@]+"${args[@]}"}" ;;
        popd)       _CWD="" ;;
        tee|mv|mkdir|touch|truncate) _cmd_operands "$cmd" "${args[@]+"${args[@]}"}" ;;
        cp|install|ln|rsync)         _cmd_copy "$cmd" "${args[@]+"${args[@]}"}" ;;
        sed)        _cmd_sed "${args[@]+"${args[@]}"}" ;;
        dd)         for tok in "${args[@]+"${args[@]}"}"; do [[ "$tok" == of=* ]] && _check "${tok#of=}" "dd of="; done ;;
        git)        _cmd_git "${args[@]+"${args[@]}"}" ;;
        patch)      _cmd_patch "${args[@]+"${args[@]}"}" ;;
        bash|sh|zsh|dash|ksh) _scan_dash_c "${args[@]+"${args[@]}"}" ;;
    esac
    _INFILE=""
}

# bash -c '...': the string is a command of its own (one level; a subprocess, so its cd does not leak back).
_scan_dash_c() {
    local -a a=("$@")
    local k inner save="$_CWD"
    for ((k = 0; k + 1 < ${#a[@]}; k++)); do
        [[ "${a[$k]}" == -c ]] || continue
        inner="${a[$((k + 1))]}"
        case "$inner" in \"*\"|\'*\') inner="${inner:1:${#inner}-2}" ;; esac
        _scan_text "$inner"
        _CWD="$save"
        break
    done
}

# One token off the head of a line: a shell operator, or a word in which single
# quotes, double quotes (with \" escapes) and backslash escapes stay intact — so a
# '>' or a path inside a string is data, never a target.
_TOK_RE='^[[:space:]]*(&&|\|\||;;|;|[0-9]*[<>]&-?[0-9]*|&>>|&>|[0-9]*>>|[0-9]*>\|?|[0-9]*<<<|[0-9]*<<-?|[0-9]*<|\||&|\(|\)|('"'"'[^'"'"']*'"'"'|"([^"\\]|\\.)*"|\\.|[^[:space:]'"'"'"\\|&;<>()])+)'
_OP_RE='^([0-9]*[<>]|[&|;()])'

# _scan_line LINE — tokenize one logical line; uses the scanner's locals (_TOKENS, _INFILE, hdoc, hdoc_tabs, inq).
_scan_line() {
    local rest="$1" tok d expect_redir="" expect_hdoc=0 skip_next=0
    while [[ -n "$rest" ]]; do
        if ! [[ "$rest" =~ $_TOK_RE ]]; then   # unbalanced quote: the string continues on the next line
            d="${rest#"${rest%%[![:space:]]*}"}"
            case "$d" in "'"*) inq="'" ;; '"'*) inq='"' ;; esac
            return 0
        fi
        tok="${BASH_REMATCH[1]}"; rest="${rest:${#BASH_REMATCH[0]}}"
        [[ -n "$tok" ]] || return 0
        if [[ "$tok" =~ $_OP_RE ]]; then
            expect_redir=""; expect_hdoc=0; skip_next=0
            case "$tok" in
                '&&'|'||'|';'|';;'|'|'|'&') _flush_clause ;;
                '(') _CWD_STACK+=("$_CWD"); _flush_clause ;;
                ')') _flush_clause
                     if [[ ${#_CWD_STACK[@]} -gt 0 ]]; then _CWD="${_CWD_STACK[-1]}"; unset '_CWD_STACK[-1]'; fi ;;
                *'<<<'*) skip_next=1 ;;
                *'<<-'*) expect_hdoc=2 ;;
                *'<<'*)  expect_hdoc=1 ;;
                *'>&'*|*'<&'*) ;;                    # fd duplication: nothing on disk
                *'<'*)   expect_redir="<" ;;
                *'>'*)   expect_redir="$tok" ;;
            esac
            continue
        fi
        if [[ $skip_next -eq 1 ]]; then
            skip_next=0
        elif [[ $expect_hdoc -ne 0 ]]; then
            d="$tok"; d="${d//\'/}"; d="${d//\"/}"; d="${d//\\/}"
            hdoc+=("$d"); hdoc_tabs+=($(( expect_hdoc == 2 ))); expect_hdoc=0
        elif [[ -n "$expect_redir" ]]; then
            if [[ "$expect_redir" == "<" ]]; then _INFILE="$tok"; else _check "$tok" "redirect '$expect_redir'"; fi
            expect_redir=""
        else
            _TOKENS+=("$tok")
        fi
    done
}

# _resume_after_quote LINE → _R: LINE after the close of a string begun on an earlier line (quote in inq); 1 if still open.
_resume_after_quote() {
    local rest="$1" pre
    if [[ "$inq" == "'" ]]; then
        [[ "$rest" == *"'"* ]] || return 1
        _R="${rest#*\'}"; inq=""; return 0
    fi
    while [[ "$rest" == *'"'* ]]; do
        pre="${rest%%\"*}"; rest="${rest#*\"}"
        if [[ "$pre" == *'\' && "$pre" != *'\\' ]]; then continue; fi
        _R="$rest"; inq=""; return 0
    done
    return 1
}

# _scan_text TEXT — walk TEXT line by line; heredoc bodies and multi-line strings are skipped.
_scan_text() {
    local -a _TOKENS=() hdoc=() hdoc_tabs=()
    local _INFILE="" inq="" joined="" line cmp
    _DEPTH=$((_DEPTH + 1))
    if [[ $_DEPTH -gt 2 ]]; then _DEPTH=$((_DEPTH - 1)); return 0; fi
    [[ $_DEPTH -eq 1 ]] && _SCAN_ROOT_TEXT="$1"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == *'\' && "$line" != *'\\' ]]; then joined+="${line%\\}"; continue; fi
        line="$joined$line"; joined=""
        if [[ ${#hdoc[@]} -gt 0 ]]; then                    # inside a heredoc body
            cmp="$line"
            if [[ "${hdoc_tabs[0]}" == 1 ]]; then while [[ "$cmp" == $'\t'* ]]; do cmp="${cmp:1}"; done; fi
            if [[ "$cmp" == "${hdoc[0]}" ]]; then hdoc=("${hdoc[@]:1}"); hdoc_tabs=("${hdoc_tabs[@]:1}"); fi
            continue
        fi
        if [[ -n "$inq" ]]; then _resume_after_quote "$line" || continue; line="$_R"; fi
        _scan_line "$line"
        _flush_clause
    done <<< "$1"
    _flush_clause
    _DEPTH=$((_DEPTH - 1))
}
