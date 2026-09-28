#!/usr/bin/env bash
# PreToolUse hook: refuse a `git commit` that adds or rewords a `HARD RULE` line in any
# CLAUDE.md unless the commit message carries an `Approved-By:` trailer.  CFG-388.
#
# The meta-rule "Rule changes require user consent — NO EXCEPTIONS" was honor-system
# only. 2026-04-21: an over-constrained HARD RULE the user never asked for
# ("Executor affinity … never write directly to a storage tier that isn't yours") landed
# in a project's CLAUDE.md, echoed into five other files, and a later session spent ~20 minutes
# defending an invented design because of it. The trailer is an attestation — it makes
# the claim "the user approved this" explicit and visible in history, where it can be
# checked, instead of implicit.
#
# Scope: every file named CLAUDE.md in the repo being committed to — each project's own,
# and every one in cfg-agent-fleet (global/CLAUDE.md is the source of ~/.claude/CLAUDE.md,
# which is not under git itself).
# Sees: staged changes, plus the working-tree changes the command will stage — -a/--all,
# a commit pathspec, or a `git add` earlier in the same Bash call (PreToolUse runs
# before that add, so the index does not show it yet). A pathspec commit without
# -i/--include takes only those paths (git's --only mode).
# Finds the commit wherever the shell would: quoted paths (`git -C "<repo>"`,
# `cd "<repo>" &&`), subshells, and prefixes (VAR=x, env, sudo, command, …). Every
# commit in the command is judged, each against the repo it runs in.
# Exempt: a HARD RULE line moved verbatim within the same file, or changed only in
# whitespace (no rule changed).
# Approval: `Approved-By: <who>` in the commit's OWN message — a -m/--message/--trailer
# value, a `-F <file>`, or the heredoc/here-string feeding `-F -`. The same token anywhere
# else in the command (another clause, an env var, an unrelated heredoc) does not count.
# NOT covered: commits made outside a Bash tool call (the SessionEnd auto-sync commits
# directly) — see the CFG-388 backlog entry.
# Exit 2 = block. Exit 0 = allow.

INPUT=$(cat)

case "$INPUT" in
    *'"tool_name":"Bash"'*|*'"tool_name": "Bash"'*) ;;
    *) exit 0 ;;
esac

CMD=""
if command -v jq >/dev/null 2>&1; then
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
fi
if [ -z "$CMD" ]; then
    CMD=$(printf '%s' "$INPUT" | grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
          | sed 's/.*"command"[^"]*"\([^"]*\)"/\1/')
fi
[ -z "$CMD" ] && exit 0

# Cheap reject before any git work.
case "$CMD" in
    *git*commit*) ;;
    *) exit 0 ;;
esac

# ── Split the command the way the shell will ──────────────────────────────────
# One output line per simple command, fields separated by \037, quotes UNWRAPPED (a
# quoted path is a path — deleting quoted text dropped `-C "<repo>"` and failed open).
# Data is not split: a quoted string, a $(…)/`…` substitution and a heredoc body stay
# inside one word or are skipped, so a commit message cannot fake a clause. Redirections
# and their targets are dropped. `(` and `)` come out as \036( and \036) marker lines so
# a `cd` inside a subshell does not leak out of it. What a command reads on stdin is kept
# for `commit -F -`: a `<<` leaves a \036< token in its clause and the body follows as a
# \036H<body> line; a `<<<` word comes out as \036<<word>.
_TOKENIZER='
function flush_tok() {
    if (intok) {
        if (dropnext) dropnext = 0
        else { if (hsnext) { tok = MARK "<" tok; hsnext = 0 } gsub(/[\n\r\t]/, " ", tok); out = out (ntok++ ? SEP : "") tok }
    }
    tok = ""; intok = 0
}
function flush_fd() { if (intok && tok ~ /^[0-9]+$/) { tok = ""; intok = 0 } flush_tok() }
function end_clause() { flush_tok(); if (ntok) print out; out = ""; ntok = 0; dropnext = 0; hsnext = 0 }
function mark(m) { end_clause(); print MARK m }
function sq_end(k,   p) { p = index(substr(s, k), "\047"); return p ? k + p - 1 : n + 1 }
function bq_end(k,   c) {
    while (k <= n) { c = substr(s, k, 1); if (c == "\\") { k += 2; continue } if (c == "`") return k; k++ }
    return n + 1
}
function dq_end(k,   c) {
    while (k <= n) {
        c = substr(s, k, 1)
        if (c == "\\") { k += 2; continue }
        if (c == "\"") return k
        if (c == "$" && substr(s, k + 1, 1) == "(") { k = paren_end(k + 2, substr(s, k + 2, 1) == "("); continue }
        if (c == "`") { k = bq_end(k + 1) + 1; continue }
        k++
    }
    return n + 1
}
function paren_end(k, arith,   depth, c) {   # k: just past "$(" → index just past the matching ")"
    depth = 1
    while (k <= n) {
        c = substr(s, k, 1)
        if (c == "\\") { k += 2; continue }
        if (!arith && c == "\047") { k = sq_end(k + 1) + 1; continue }
        if (!arith && c == "\"") { k = dq_end(k + 1) + 1; continue }
        if (!arith && c == "`") { k = bq_end(k + 1) + 1; continue }
        if (c == "$" && substr(s, k + 1, 1) == "(") { k = paren_end(k + 2, substr(s, k + 2, 1) == "("); continue }
        if (c == "(") { depth++; k++; continue }
        if (c == ")") { depth--; k++; if (depth == 0) return k; continue }
        if (!arith && substr(s, k, 2) == "<<" && substr(s, k + 2, 1) != "<") { k = hd_word(k + 2); continue }
        if (!arith && c == "\n") { k = hd_skip(k + 1); continue }
        k++
    }
    return n + 1
}
function hd_word(k,   dash, w, c, p) {   # k: just past "<<" → registers the delimiter
    dash = 0
    if (substr(s, k, 1) == "-") { dash = 1; k++ }
    while (substr(s, k, 1) == " " || substr(s, k, 1) == "\t") k++
    w = ""
    while (k <= n) {
        c = substr(s, k, 1)
        if (c ~ /[ \t\n;&|<>()]/) break
        if (c == "\047") { p = sq_end(k + 1); w = w substr(s, k + 1, p - k - 1); k = p + 1; continue }
        if (c == "\"") { p = dq_end(k + 1); w = w substr(s, k + 1, p - k - 1); k = p + 1; continue }
        if (c == "\\") { w = w substr(s, k + 1, 1); k += 2; continue }
        w = w c; k++
    }
    if (w != "") { hdw[nhd] = w; hdd[nhd] = dash; nhd++ }
    return k
}
function hd_skip(k, keep,   h, e, line) {   # k: start of the line after the heredoc operator(s)
    for (h = 0; h < nhd; h++) {
        while (k <= n) {
            e = index(substr(s, k), "\n")
            if (e) { line = substr(s, k, e - 1); k = k + e } else { line = substr(s, k); k = n + 1 }
            if (hdd[h]) sub(/^\t+/, "", line)
            if (line == hdw[h]) break
            if (keep) hdbody = hdbody line "\n"
        }
    }
    nhd = 0
    return k
}
{ s = s $0 "\n" }
END {
    n = length(s); SEP = "\037"; MARK = "\036"; i = 1; nhd = 0   # nhd: numeric, or hdw[nhd] keys on ""
    while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\") { if (substr(s, i + 1, 1) != "\n") { tok = tok substr(s, i + 1, 1); intok = 1 } i += 2; continue }
        if (c == "\047") { p = sq_end(i + 1); tok = tok substr(s, i + 1, p - i - 1); intok = 1; i = p + 1; continue }
        if (c == "\"") { p = dq_end(i + 1); tok = tok substr(s, i + 1, p - i - 1); intok = 1; i = p + 1; continue }
        if (c == "$" && substr(s, i + 1, 1) == "(") { p = paren_end(i + 2, substr(s, i + 2, 1) == "("); tok = tok substr(s, i, p - i); intok = 1; i = p; continue }
        if (c == "`") { p = bq_end(i + 1); tok = tok substr(s, i, p - i + 1); intok = 1; i = p + 1; continue }
        if (c == " " || c == "\t") { flush_tok(); i++; continue }
        if (c == "\n") { end_clause(); had = nhd; hdbody = ""; i = hd_skip(i + 1, 1); if (had) { gsub(/[\n\r\t]/, " ", hdbody); print MARK "H" hdbody } continue }
        if (c == "#" && !intok) { while (i <= n && substr(s, i, 1) != "\n") i++; continue }
        if (c == "&" && substr(s, i + 1, 1) == ">") { flush_fd(); i += 2; if (substr(s, i, 1) == ">") i++; dropnext = 1; continue }
        if (substr(s, i, 3) == "<<<") { flush_fd(); i += 3; hsnext = 1; continue }
        if (substr(s, i, 2) == "<<") { flush_fd(); i = hd_word(i + 2); tok = MARK "<"; intok = 1; flush_tok(); continue }
        if (c == "<" || c == ">") {
            flush_fd(); i++; nc = substr(s, i, 1)
            if (nc == ">" || nc == "&" || (c == ">" && nc == "|")) i++
            dropnext = 1; continue
        }
        if (c == "(" || c == ")") { mark(c); i++; continue }
        if (c == ";" || c == "&" || c == "|") { end_clause(); i++; continue }
        tok = tok c; intok = 1; i++
    }
    end_clause()
}'

_US=$(printf '\037'); _MK=$(printf '\036')

_expand() {  # a leading ~, $HOME, ${HOME} or $PWD; anything else is taken literally
    local p="$1"
    case "$p" in
        "~")         p="$HOME" ;;
        "~/"*)       p="$HOME/${p#"~/"}" ;;
        '$HOME'|'${HOME}') p="$HOME" ;;
        '$HOME/'*)   p="$HOME/${p#'$HOME/'}" ;;
        '${HOME}/'*) p="$HOME/${p#'${HOME}/'}" ;;
        '$PWD'|'${PWD}') p="$PWD" ;;
        '$PWD/'*)    p="$PWD/${p#'$PWD/'}" ;;
    esac
    printf '%s' "$p"
}
_join() {  # <base dir, may be empty> <path> → the path as seen from base
    local p; p=$(_expand "$2")
    case "$p" in /*) printf '%s' "$p" ;; *) if [ -n "$1" ]; then printf '%s/%s' "$1" "$p"; else printf '%s' "$p"; fi ;; esac
}
_abs() { case "$1" in /*) printf '%s' "$1" ;; '') printf '%s' "$PWD" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }

# <dir> <pathspec> → the pathspec relative to $ROOT (git's own view, so symlinks and
# Git-Bash drive letters agree); status 1 when it lies outside $ROOT.
_spec_rel() {
    local d="$1" p="$2" full base out top pre nl='
'
    case "$p" in
        :/*) printf '%s' "${p#:/}"; return 0 ;;
        :*)  return 0 ;;                       # other pathspec magic: may cover anything
    esac
    p=$(_expand "$p")
    case "$p" in /*) full="$p" ;; *) full="$d/$p" ;; esac
    base=""
    if [ ! -d "$full" ]; then base="${full##*/}"; full="${full%/*}"; [ -n "$full" ] || full=/; fi
    [ -d "$full" ] || return 1
    out=$(git -C "$full" rev-parse --show-toplevel --show-prefix 2>/dev/null) || return 1
    top="${out%%"$nl"*}"
    case "$out" in *"$nl"*) pre="${out#*"$nl"}" ;; *) pre="" ;; esac
    [ "$top" = "$ROOT" ] || return 1
    pre="$pre$base"; printf '%s' "${pre%/}"
}
_covers() {  # <repo-relative pathspec> <repo-relative file>
    local t="$1" f="$2"
    [ -z "$t" ] && return 0
    [ "$f" = "$t" ] && return 0
    case "$f" in "$t"/*) return 0 ;; esac
    case "$t" in *[\*\?\[]*) case "$f" in $t|$t/*) return 0 ;; esac ;; esac
    return 1
}
_add_takes() {  # <file> <tracked 0|1> → 0 when a `git add` earlier in the command stages it
    local f="$1" tr="$2" kind d p t
    while IFS="$_US" read -r kind d p; do
        case "$kind" in
            all)     _spec_rel "$d" . >/dev/null && return 0 ;;
            tracked) [ "$tr" -eq 1 ] && _spec_rel "$d" . >/dev/null && return 0 ;;
            path|tpath)
                [ "$kind" = tpath ] && [ "$tr" -eq 0 ] && continue
                t=$(_spec_rel "$d" "$p") || continue
                _covers "$t" "$f" && return 0 ;;
        esac
    done <<ADDS
$_adds
ADDS
    return 1
}
_commit_takes() {  # <file> → 0 when a pathspec on the commit itself names it
    local f="$1" p t
    [ "${#_cpaths[@]}" -gt 0 ] || return 1
    for p in "${_cpaths[@]}"; do
        t=$(_spec_rel "$_cdir" "$p") || continue
        _covers "$t" "$f" && return 0
    done
    return 1
}

# ── Which CLAUDE.md changes will one commit carry? ────────────────────────────
# The index, plus the working-tree changes git takes at commit time: -a/--all, a commit
# pathspec, or a `git add` earlier in the command (PreToolUse runs before that add, so
# the index does not show it yet). A pathspec commit without -i/--include is git's
# --only mode: just those paths go in, whatever else sits staged.
DIFF=""
_judge() {
    local f tr cov only=0 has_head=0
    [ -d "$_cdir" ] || return 0
    ROOT=$(git -C "$_cdir" rev-parse --show-toplevel 2>/dev/null) || return 0
    [ -n "$ROOT" ] || return 0
    [ "${#_cpaths[@]}" -gt 0 ] && [ "$_cinc" -eq 0 ] && only=1
    git -C "$ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1 && has_head=1
    local _spec=(-- 'CLAUDE.md' ':(glob)**/CLAUDE.md')
    local IFS='
'
    for f in $( { git -c core.quotePath=false -C "$ROOT" diff --cached --name-only "${_spec[@]}"
                  [ "$has_head" -eq 1 ] && git -c core.quotePath=false -C "$ROOT" diff HEAD --name-only "${_spec[@]}"
                  git -c core.quotePath=false -C "$ROOT" ls-files --others --exclude-standard "${_spec[@]}"; } 2>/dev/null | sort -u ); do
        tr=0; git -C "$ROOT" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && tr=1
        cov=0; _commit_takes "$f" && cov=1
        if [ "$only" -eq 1 ]; then
            [ "$cov" -eq 1 ] || continue
        else
            [ "$_call" -eq 1 ] && [ "$tr" -eq 1 ] && cov=1
            [ "$cov" -eq 0 ] && _add_takes "$f" "$tr" && cov=1
        fi
        if [ "$tr" -eq 1 ]; then
            if [ "$cov" -eq 1 ] && [ "$has_head" -eq 1 ]; then
                DIFF="$DIFF
$(git -C "$ROOT" diff HEAD --no-color --no-ext-diff --no-textconv -- "$f" 2>/dev/null)"
            else
                DIFF="$DIFF
$(git -C "$ROOT" diff --cached --no-color --no-ext-diff --no-textconv -- "$f" 2>/dev/null)"
            fi
        elif [ "$cov" -eq 1 ]; then
            # Untracked and about to be added: every line is new.
            DIFF="$DIFF
+++ b/$f
$(sed 's/^/+/' "$ROOT/$f" 2>/dev/null)"
        fi
    done
}

# ── Walk the commands: cd, git add, git commit ────────────────────────────────
# Prefixes that still run git: VAR=value, env, sudo/doas, command, exec, nice, nohup,
# time, timeout, and the shell keywords a command can follow ({ ! if then do …).
set -f   # nothing below may glob against the cwd
_cd=""; _cdstack=""; _adds=""; _msgfiles=""; _msgs=""; _hdwant=0
_msg() { _msgs="$_msgs
$1"; }
_mf() { _msgfiles="$_msgfiles
$_c$_US$1"; [ "$1" != "-" ] || _cstdin=1; }
_oifs="$IFS"
while IFS= read -r _clause; do
    case "$_clause" in
        "$_MK(") _cdstack="$_cd$_US$_cdstack"; continue ;;
        "$_MK)") case "$_cdstack" in *"$_US"*) _cd="${_cdstack%%"$_US"*}"; _cdstack="${_cdstack#*"$_US"}" ;; esac; continue ;;
        "$_MK"H*) [ "$_hdwant" -eq 0 ] || _msg "${_clause#"$_MK"H}"; _hdwant=0; continue ;;   # heredoc body: the last commit's stdin?
    esac
    IFS="$_US"; set -- $_clause; IFS="$_oifs"
    _pd=""; _stdin=""
    while [ $# -gt 0 ]; do
        case "$1" in
            '{'|'!'|if|then|else|elif|do|while|until|time|command|exec|nohup) shift ;;
            "$_MK<"*) _stdin="$1"; shift ;;   # a redirection may sit anywhere in a simple command
            nice) shift; case "${1:-}" in -n) shift; [ $# -gt 0 ] && shift ;; -*) shift ;; esac ;;
            timeout|gtimeout)
                shift
                while [ $# -gt 0 ]; do
                    case "$1" in -s|-k|--signal|--kill-after) shift; [ $# -gt 0 ] && shift ;; -*) shift ;; *) break ;; esac
                done
                [ $# -gt 0 ] && shift ;;
            env|sudo|doas)
                shift
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -C|-D|--chdir) _pd="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
                        --chdir=*) _pd="${1#--chdir=}"; shift ;;
                        -u|-g|-h|-p|-r|-t|-U|-T|-S|--user|--group|--host|--prompt|--role|--type|--unset|--split-string|--other-user)
                            shift; [ $# -gt 0 ] && shift ;;
                        --) shift; break ;;
                        -*) shift ;;
                        *=*) shift ;;
                        *) break ;;
                    esac
                done ;;
            *=*) case "${1%%=*}" in *[!A-Za-z0-9_]*|[0-9]*|'') break ;; esac; shift ;;
            *) break ;;
        esac
    done
    [ $# -gt 0 ] || continue
    case "$1" in
        cd|pushd)
            shift
            while [ $# -gt 0 ]; do case "$1" in -L|-P|-e|-@|"$_MK<"*) shift ;; --) shift; break ;; *) break ;; esac; done
            case "${1:-~}" in -|+*|-[0-9]*) ;; *) _cd=$(_join "$_cd" "${1:-~}") ;; esac
            continue ;;
    esac
    [ "${1##*/}" = "git" ] || continue
    shift
    _c="$_cd"; [ -n "$_pd" ] && _c=$(_join "$_cd" "$_pd")
    _wt=""; _gd=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -C) _c=$(_join "$_c" "${2:-}"); shift; [ $# -gt 0 ] && shift ;;
            --work-tree) _wt="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
            --work-tree=*) _wt="${1#--work-tree=}"; shift ;;
            --git-dir) _gd="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
            --git-dir=*) _gd="${1#--git-dir=}"; shift ;;
            -c|--namespace|--config-env|--super-prefix|--exec-path) shift; [ $# -gt 0 ] && shift ;;
            "$_MK<"*) _stdin="$1"; shift ;;
            -*) shift ;;
            *) break ;;
        esac
    done
    if [ -n "$_wt" ]; then _c=$(_join "$_c" "$_wt")
    elif [ -n "$_gd" ]; then case "$_gd" in */.git|*/.git/) _gd="${_gd%/}"; _c=$(_join "$_c" "${_gd%/.git}") ;; .git|.git/) ;; esac
    fi
    _c=$(_abs "$_c")
    case "${1:-}" in
        add)
            shift
            _k_all=0; _k_upd=0; _specs=0; _dd=0
            while [ $# -gt 0 ]; do
                case "$1" in "$_MK<"*) shift; continue ;; esac   # stdin is not a pathspec
                if [ "$_dd" -eq 0 ]; then
                    case "$1" in
                        --) _dd=1; shift; continue ;;
                        -A|--all|--no-ignore-removal) _k_all=1; shift; continue ;;
                        -u|--update) _k_upd=1; shift; continue ;;
                        --pathspec-from-file|--pathspec-from-file=*) _k_all=1; _specs=0; break ;;  # unknowable: assume all
                        --*) shift; continue ;;
                        -?*) case "$1" in -*A*) _k_all=1 ;; esac; case "$1" in -*u*) _k_upd=1 ;; esac; shift; continue ;;
                    esac
                fi
                if [ "$_k_upd" -eq 1 ] && [ "$_k_all" -eq 0 ]; then _kind=tpath; else _kind=path; fi
                _adds="$_adds
$_kind$_US$_c$_US$1"
                _specs=$((_specs + 1)); shift
            done
            if [ "$_specs" -eq 0 ]; then
                if [ "$_k_all" -eq 1 ]; then _adds="$_adds
all$_US$_c$_US"
                elif [ "$_k_upd" -eq 1 ]; then _adds="$_adds
tracked$_US$_c$_US"
                fi
            fi ;;
        commit)
            shift
            _cdir="$_c"; _call=0; _cinc=0; _cstdin=0; _cpaths=(); _dd=0
            while [ $# -gt 0 ]; do
                if [ "$_dd" -eq 1 ]; then _cpaths[${#_cpaths[@]}]="$1"; shift; continue; fi
                case "$1" in
                    --) _dd=1; shift ;;
                    -a|--all) _call=1; shift ;;
                    -i|--include) _cinc=1; shift ;;
                    -F|--file) _mf "${2:-}"; shift; [ $# -gt 0 ] && shift ;;
                    --file=*) _mf "${1#--file=}"; shift ;;
                    -m|--message|--trailer) _msg "${2:-}"; shift; [ $# -gt 0 ] && shift ;;
                    --message=*|--trailer=*) _msg "${1#*=}"; shift ;;
                    "$_MK<"*) _stdin="$1"; shift ;;
                    -C|-c|-t|--reuse-message|--reedit-message|--template|--author|--date|--cleanup|--fixup|--squash|--pathspec-from-file)
                        shift; [ $# -gt 0 ] && shift ;;
                    --*) shift ;;
                    -?*)
                        _cl="${1#-}"; shift
                        while [ -n "$_cl" ]; do
                            _ch="${_cl%"${_cl#?}"}"; _cl="${_cl#?}"
                            case "$_ch" in
                                a) _call=1 ;;
                                i) _cinc=1 ;;
                                F|m) if [ -z "$_cl" ] && [ $# -gt 0 ]; then _cl="$1"; shift; fi
                                     if [ "$_ch" = F ]; then _mf "$_cl"; else _msg "$_cl"; fi; break ;;
                                C|c|t) [ -z "$_cl" ] && [ $# -gt 0 ] && shift; break ;;
                            esac
                        done ;;
                    *) _cpaths[${#_cpaths[@]}]="$1"; shift ;;
                esac
            done
            if [ "$_cstdin" -eq 1 ]; then   # -F -: a here-string word is the message; a heredoc body follows the clause
                case "$_stdin" in "$_MK<") _hdwant=1 ;; "$_MK<"?*) _msg "${_stdin#"$_MK<"}" ;; esac
            fi
            _judge
            _adds="" ;;   # what was added is now committed; later adds start afresh
    esac
done <<EOF
$(printf '%s\n' "$CMD" | LC_ALL=C awk "$_TOKENIZER")
EOF
set +f
[ -n "$(printf '%s' "$DIFF" | tr -d '[:space:]')" ] || exit 0

# Added HARD RULE lines that were not merely moved within the same file. Lines are compared
# with whitespace collapsed and trimmed: re-spacing a rule is not rewording it.
# --no-color above: this fleet sets color.diff=always, which breaks every ^+ match.
HITS=$(printf '%s\n' "$DIFF" | awk '
    function norm(l) { gsub(/[ \t\r]+/, " ", l); sub(/^ /, "", l); sub(/ $/, "", l); return l }
    /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); next }
    /^--- /    { next }
    /^-/ && /HARD RULE/ { gone[f SUBSEP norm(substr($0, 2))] = 1; next }
    /^\+/ && /HARD RULE/ { n++; file[n] = f; line[n] = substr($0, 2); next }
    END { for (i = 1; i <= n; i++) if (!((file[i] SUBSEP norm(line[i])) in gone)) print file[i] "\t" line[i] }
')
[ -n "$HITS" ] || exit 0

# ── Approval trailer ──────────────────────────────────────────────────────────
# Only the message values collected above are searched — never the command as a whole,
# where `&& echo Approved-By: x` would pass as an attestation.
_approved=0
printf '%s\n' "$_msgs" | grep -qiE 'Approved-By[[:space:]]*[:=][[:space:]]*[^[:space:]'"'"'"]' && _approved=1
if [ "$_approved" -eq 0 ]; then
    # -F <file> message files, as parsed above (relative to the directory git runs in).
    while IFS="$_US" read -r _d _mf; do
        [ -n "$_mf" ] && [ "$_mf" != "-" ] || continue
        _mf=$(_join "$_d" "$_mf")
        [ -f "$_mf" ] && grep -qiE '^Approved-By[[:space:]]*:[[:space:]]*[^[:space:]]' "$_mf" && { _approved=1; break; }
    done <<MSGFILES
$_msgfiles
MSGFILES
fi
[ "$_approved" -eq 1 ] && exit 0

{
    echo "BLOCKED (CFG-388): this commit adds or rewords a HARD RULE in CLAUDE.md without an"
    echo "approval trailer."
    echo ""
    printf '%s\n' "$HITS" | head -10 | while IFS="$(printf '\t')" read -r _f _l; do
        printf '  %s: %s\n' "$_f" "$(printf '%s' "$_l" | cut -c1-160)"
    done
    echo ""
    echo "Rule changes require user consent — NO EXCEPTIONS. On 2026-04-21 an agent-added HARD RULE"
    echo "nobody asked for landed in a project's CLAUDE.md, spread into five other files, and a later session"
    echo "spent 20 minutes defending a design the user never wanted."
    echo ""
    echo "This adds or rewords a HARD RULE line, and that needs the owner's consent. If they approved"
    echo 'THIS rule, in their own words, record who approved and when in an `Approved-By:` trailer (-m)'
    echo "and commit again. Do not add one yourself without that consent: take the rule out of the"
    echo "commit and ask them first."
} >&2
exit 2
