#!/usr/bin/env bash
# lib-pending-work.sh — the parsed work-item state block of a docs/pending-*.md (CFG-948).
#
# Block, in the header lines next to `<!-- Action: … -->` (bare `Work:` form parsed too):
#   <!-- Work: stage=<word>; status=<open|blocked|awaiting-proof|done>; next=<one line>; approved=<YYYY-MM-DD who|none> -->
# Fields in any order, `;`-separated (so no `;` inside a value); stage and status are
# required, next and approved optional. Any other key is a malformed block — that is
# how a typo like `state=` gets caught instead of silently ignored.
#
# pending_work_parse <file>   — sets _pw_present (0/1), _pw_stage, _pw_status, _pw_next,
#                               _pw_approved, _pw_error ("" when valid).
#                               rc 0 = valid block, 1 = no block, 2 = malformed.
# pending_work_format         — prints the compact form from the parsed globals:
#                               "stage/status[: next]" (next cut to 70 chars) or "MALFORMED: <reason>".
# pending_work_summary <file> — parse + format in one call, same rc as parse.

pending_work_parse() {
    local f="$1" line kv key val
    _pw_present=0; _pw_stage=""; _pw_status=""; _pw_next=""; _pw_approved=""; _pw_error=""
    line=$(head -10 "$f" 2>/dev/null | sed -e 's/<!--//' -e 's/-->//' \
        | sed -n 's/^[[:space:]]*[Ww]ork:[[:space:]]*\(.*\)$/\1/p' | head -1)
    [ -n "$line" ] || return 1
    _pw_present=1
    local IFS=';'
    for kv in $line; do
        kv="${kv#"${kv%%[![:space:]]*}"}"; kv="${kv%"${kv##*[![:space:]]}"}"
        [ -n "$kv" ] || continue
        case "$kv" in *=*) ;; *) _pw_error="field without '=': $kv"; return 2 ;; esac
        key="${kv%%=*}"; val="${kv#*=}"
        case "$key" in
            stage)    _pw_stage="$val" ;;
            status)   _pw_status="$val" ;;
            next)     _pw_next="$val" ;;
            approved) _pw_approved="$val" ;;
            *)        _pw_error="unknown field '$key=' (allowed: stage status next approved)"; return 2 ;;
        esac
    done
    case "$_pw_stage" in
        '') _pw_error="missing stage="; return 2 ;;
        *[!A-Za-z0-9_.-]*) _pw_error="stage=$_pw_stage is not one word"; return 2 ;;
    esac
    case "$_pw_status" in
        open|blocked|awaiting-proof|done) ;;
        '') _pw_error="missing status="; return 2 ;;
        *)  _pw_error="status=$_pw_status is not one of open, blocked, awaiting-proof, done"; return 2 ;;
    esac
    case "$_pw_approved" in
        ''|none) ;;
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ ?*) ;;
        *) _pw_error="approved=$_pw_approved is neither none nor 'YYYY-MM-DD who'"; return 2 ;;
    esac
    return 0
}

pending_work_format() {
    if [ -n "${_pw_error:-}" ]; then printf 'MALFORMED: %s' "$_pw_error"; return 2; fi
    [ "${_pw_present:-0}" = 1 ] || return 1
    local next="${_pw_next:-}"
    [ "${#next}" -gt 70 ] && next="${next:0:69}…"
    printf '%s/%s' "$_pw_stage" "$_pw_status"
    [ -n "$next" ] && printf ': %s' "$next"
    return 0
}

pending_work_summary() {
    local rc=0
    pending_work_parse "$1" || rc=$?
    [ "$rc" = 1 ] && return 1
    pending_work_format
}
