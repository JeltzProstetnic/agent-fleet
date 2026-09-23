#!/usr/bin/env bash
# lib-shell-write-cmds.sh — per-command write-target extraction for lib-shell-scan.sh (CFG-674).
# Each _cmd_* gets the words after the command name and reports every operand the command
# would write via _check TOKEN HOW (relative to the simulated cwd) or _check_in BASE TOKEN HOW.
# _INFILE is the clause's `<` target, set by the scanner. Option parsing is deliberately
# shallow: a mis-read option makes an extractor look at the wrong token, and a wrong token
# resolves outside the owned area — under-blocking, never a false block.

[[ "${_LIB_SHELL_WRITE_CMDS_LOADED:-}" == "true" ]] && return 0
_LIB_SHELL_WRITE_CMDS_LOADED="true"

# git [-C DIR] apply|checkout|restore|rm|mv ...
_cmd_git() {
    local -a args=("$@")
    local gdir="" sub="" j=0 base
    while [[ $j -lt ${#args[@]} ]]; do
        case "${args[$j]}" in
            -C) gdir="${args[$((j + 1))]:-}"; j=$((j + 2)) ;;
            -c) j=$((j + 2)) ;;
            --work-tree=*) gdir="${args[$j]#--work-tree=}"; j=$((j + 1)) ;;
            -*) j=$((j + 1)) ;;
            *)  sub="${args[$j]}"; j=$((j + 1)); break ;;
        esac
    done
    if [[ -n "$gdir" ]]; then _resolve "$gdir" || return 0; base="$_R"; else base="$_CWD"; fi
    [[ -n "$base" ]] || return 0
    local -a rest=("${args[@]:$j}") files=(); local a root="" strip=1 seen_dd=0
    case "$sub" in
        apply)
            for a in "${rest[@]+"${rest[@]}"}"; do
                case "$a" in
                    --directory=*) root="${a#--directory=}" ;;
                    -p*)           strip="${a#-p}" ;;
                    -*)            ;;
                    *)             files+=("$a") ;;
                esac
            done
            [[ -n "$root" ]] && base="$base/$root"
            [[ "$strip" =~ ^[0-9]+$ ]] || strip=1
            [[ ${#files[@]} -eq 0 ]] && files=("$_INFILE")
            for a in "${files[@]}"; do _patch_targets "$base" "$strip" "$a"; done ;;
        checkout|restore|rm|mv)
            for a in "${rest[@]+"${rest[@]}"}"; do
                if [[ $seen_dd -eq 0 ]]; then
                    [[ "$a" == "--" ]] && { seen_dd=1; continue; }
                    [[ "$a" == -* ]] && continue
                fi
                _check_in "$base" "$a" "git $sub"
            done ;;
    esac
}

# patch [-d DIR] [-pN] [-i FILE] [ORIGFILE [PATCHFILE]]   (also: patch < FILE)
_cmd_patch() {
    local -a args=("$@") pos=()
    local pdir="" pfile="" strip="all" j=0 base
    while [[ $j -lt ${#args[@]} ]]; do
        case "${args[$j]}" in
            -d)             pdir="${args[$((j + 1))]:-}"; j=$((j + 2)) ;;
            --directory=*)  pdir="${args[$j]#--directory=}"; j=$((j + 1)) ;;
            -i)             pfile="${args[$((j + 1))]:-}"; j=$((j + 2)) ;;
            --input=*)      pfile="${args[$j]#--input=}"; j=$((j + 1)) ;;
            -p)             strip="${args[$((j + 1))]:-}"; j=$((j + 2)) ;;
            -p*)            strip="${args[$j]#-p}"; j=$((j + 1)) ;;
            --strip=*)      strip="${args[$j]#--strip=}"; j=$((j + 1)) ;;
            -o)             _check "${args[$((j + 1))]:-}" "patch -o"; j=$((j + 2)) ;;
            -B|-D|-F|-r|-V|-x|-Y|-z|-g) j=$((j + 2)) ;;
            -*)             j=$((j + 1)) ;;
            *)              pos+=("${args[$j]}"); j=$((j + 1)) ;;
        esac
    done
    if [[ -n "$pdir" ]]; then _resolve "$pdir" || return 0; base="$_R"; else base="$_CWD"; fi
    [[ -n "$base" ]] || return 0
    [[ "$strip" == all || "$strip" =~ ^[0-9]+$ ]] || strip=all
    [[ -n "${pos[0]:-}" ]] && _check_in "$base" "${pos[0]}" "patch"
    [[ -z "$pfile" ]] && pfile="${pos[1]:-$_INFILE}"
    [[ -n "$pfile" ]] && _patch_targets "$base" "$strip" "$pfile"
    return 0
}

# _patch_targets BASE STRIP PATCHFILE — every '+++ ' path a patch would write under BASE, after
# stripping STRIP leading components ("all" = basename, GNU patch's default). Source: the named
# file when readable (relative to BASE, then the cwd), else the command text (a heredoc patch).
_patch_targets() {
    local base="$1" strip="$2" pfile="$3" src="" line n=0 save="$_CWD"
    if [[ -n "$pfile" ]]; then
        _CWD="$base"; _resolve "$pfile" && [[ -r "$_R" && -f "$_R" ]] && src="$_R"
        _CWD="$save"
        [[ -z "$src" ]] && _resolve "$pfile" && [[ -r "$_R" && -f "$_R" ]] && src="$_R"
    fi
    if [[ -n "$src" ]]; then
        while IFS= read -r line; do
            n=$((n + 1)); [[ $n -gt 5000 ]] && break
            _patch_line "$base" "$strip" "$line"
        done < "$src"
    else
        while IFS= read -r line; do _patch_line "$base" "$strip" "$line"; done <<< "$_SCAN_ROOT_TEXT"
    fi
}

_patch_line() {   # BASE STRIP LINE
    local path="$3" k
    [[ "$path" == '+++ '* ]] || return 0
    path="${path#+++ }"; path="${path%%$'\t'*}"; [[ "$path" == /dev/null ]] && return 0
    if [[ "$2" == all ]]; then
        path="${path##*/}"
    else
        for ((k = 0; k < $2; k++)); do [[ "$path" == */* ]] && path="${path#*/}"; done
    fi
    _check_in "$1" "$path" "patch hunk (+++ $path)"
}

# sed: only with -i / --in-place; the script word is skipped unless -e/-f named it.
_cmd_sed() {
    local -a args=("$@") files=()
    local inplace=0 script_seen=0 j=0 a
    while [[ $j -lt ${#args[@]} ]]; do
        a="${args[$j]}"
        case "$a" in
            -e|--expression|-f|--file) script_seen=1; j=$((j + 2)) ;;
            --expression=*|--file=*)   script_seen=1; j=$((j + 1)) ;;
            --in-place*)     inplace=1; j=$((j + 1)) ;;
            --)              j=$((j + 1)); files+=("${args[@]:$j}"); break ;;
            --*)             j=$((j + 1)) ;;
            -*)              [[ "$a" =~ ^-[nEersuzb]*i ]] && inplace=1; j=$((j + 1)) ;;
            *)               if [[ $script_seen -eq 0 ]]; then script_seen=1; else files+=("$a"); fi; j=$((j + 1)) ;;
        esac
    done
    [[ $inplace -eq 1 ]] || return 0
    for a in "${files[@]+"${files[@]}"}"; do _check "$a" "sed -i"; done
}

# cp / install / ln / rsync: the destination is the last operand, or -t DIR.
_cmd_copy() {
    local cmd="$1"; shift
    local -a args=("$@") pos=(); local tdir="" mkdirs=0 j=0 a
    while [[ $j -lt ${#args[@]} ]]; do
        a="${args[$j]}"
        case "$a" in
            --) j=$((j + 1)); pos+=("${args[@]:$j}"); break ;;
            -t) [[ "$cmd" != rsync ]] && { tdir="${args[$((j + 1))]:-}"; j=$((j + 2)); continue; }; j=$((j + 1)) ;;
            --target-directory=*) tdir="${a#--target-directory=}"; j=$((j + 1)) ;;
            -S) [[ "$cmd" != rsync ]] && { j=$((j + 2)); continue; }; j=$((j + 1)) ;;
            -m|-o|-g) [[ "$cmd" == install ]] && { j=$((j + 2)); continue; }; j=$((j + 1)) ;;
            -d) [[ "$cmd" == install ]] && mkdirs=1; j=$((j + 1)) ;;
            -e|-T|-B|-M|-f) [[ "$cmd" == rsync ]] && { j=$((j + 2)); continue; }; j=$((j + 1)) ;;
            -*) j=$((j + 1)) ;;
            *)  pos+=("$a"); j=$((j + 1)) ;;
        esac
    done
    if [[ -n "$tdir" ]]; then _check "$tdir" "$cmd -t"; return 0; fi
    if [[ $mkdirs -eq 1 ]]; then for a in "${pos[@]+"${pos[@]}"}"; do _check "$a" "install -d"; done; return 0; fi
    [[ ${#pos[@]} -ge 2 ]] || return 0
    local dest="${pos[-1]}"
    if [[ "$cmd" == rsync ]]; then
        [[ "$dest" == rsync://* ]] && return 0
        [[ "$dest" == *:* && "${dest%%:*}" != */* ]] && return 0   # host:path is remote
    fi
    _check "$dest" "$cmd destination"
}

# mv / mkdir / touch / truncate / tee: every operand is written (mv: or removed).
_cmd_operands() {
    local cmd="$1"; shift
    local -a args=("$@"); local j=0 a
    while [[ $j -lt ${#args[@]} ]]; do
        a="${args[$j]}"
        case "$a" in
            --) j=$((j + 1)); while [[ $j -lt ${#args[@]} ]]; do _check "${args[$j]}" "$cmd"; j=$((j + 1)); done; break ;;
            -t) [[ "$cmd" == mv ]] && _check "${args[$((j + 1))]:-}" "mv -t"
                if [[ "$cmd" == mv || "$cmd" == touch ]]; then j=$((j + 2)); else j=$((j + 1)); fi ;;
            --target-directory=*) [[ "$cmd" == mv ]] && _check "${a#--target-directory=}" "mv -t"; j=$((j + 1)) ;;
            -S) [[ "$cmd" == mv ]] && { j=$((j + 2)); continue; }; j=$((j + 1)) ;;
            -m) [[ "$cmd" == mkdir ]] && { j=$((j + 2)); continue; }; j=$((j + 1)) ;;
            -d|-r) [[ "$cmd" == touch || "$cmd" == truncate ]] && { j=$((j + 2)); continue; }; j=$((j + 1)) ;;
            -s) [[ "$cmd" == truncate ]] && { j=$((j + 2)); continue; }; j=$((j + 1)) ;;
            -*) j=$((j + 1)) ;;
            *)  _check "$a" "$cmd"; j=$((j + 1)) ;;
        esac
    done
}

# Interpreter literals anywhere in TEXT (heredoc bodies included): open(path, 'w'|'a'|'x'…), Path(path).write_text/bytes.
_scan_interpreter_literals() {
    local text="$1" s q="'\"" open_re path_re
    [[ "$text" == *"open("* || "$text" == *".write_text("* || "$text" == *".write_bytes("* ]] || return 0
    open_re="open\\([${q}]([^${q}]+)[${q}][[:space:]]*,[[:space:]]*(mode[[:space:]]*=[[:space:]]*)?[${q}]([wax][^${q}]*)[${q}]"
    path_re="Path\\([${q}]([^${q}]+)[${q}]\\)\\.write_(text|bytes)\\("
    s="$text"
    while [[ "$s" =~ $open_re ]]; do
        _check "${BASH_REMATCH[1]}" "open(..., '${BASH_REMATCH[3]}')"
        s="${s#*"${BASH_REMATCH[0]}"}"
    done
    s="$text"
    while [[ "$s" =~ $path_re ]]; do
        _check "${BASH_REMATCH[1]}" "Path(...).write_${BASH_REMATCH[2]}()"
        s="${s#*"${BASH_REMATCH[0]}"}"
    done
}
