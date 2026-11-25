#!/usr/bin/env bash
# CFG-542 — resolver for per-project inbox files.
#
# Sourced, not executed. Callers: global/hooks/checks/03-inbox-services.sh,
# 03b-inbox-typing.sh, setup/scripts/inbox-file.sh.
#
# Layout:
#   cross-project/inbox/<project>.md   canonical, one file per project
#   cross-project/inbox.md             legacy spillover, still read
#
# The migration is ADDITIVE. Readers consult both, so every writer that has not been
# migrated (config-auto-sync Cat-3 filing, afleet-nav, telegram intake, mobile-deploy)
# keeps working unchanged. A hard cutover across 7 scripts and 14 test files would
# have risked delivery fleet-wide for no additional benefit.
#
# NOTE: hooks source this. Every function must degrade quietly — a missing directory
# or file is a normal un-migrated machine, not an error, and must never emit to stdout
# outside its documented return value (the SessionStart JSON contract, CFG-503).

_inbox_repo() { printf '%s' "${INBOX_REPO:-${CONFIG_REPO:-$HOME/cfg-agent-fleet}}"; }

inbox_dir()    { printf '%s/cross-project/inbox' "$(_inbox_repo)"; }
inbox_legacy() { printf '%s/cross-project/inbox.md' "$(_inbox_repo)"; }

# Map a project tag to its file. Tags are case-insensitive (CFG-483) and may contain
# a parent/child slash (`acme/app`), so the name is folded and flattened. Anything
# that is not [a-z0-9._-] becomes '-', which also neutralises `..` traversal — the
# result is always a single file directly inside the inbox directory.
inbox_project_file() {
    local _raw="${1:-}" _safe
    _safe=$(printf '%s' "$_raw" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -e 's#[^a-z0-9._-]#-#g' -e 's#\.\.*#.#g' -e 's#^[.-]*##' -e 's#[.-]*$##')
    [ -n "$_safe" ] || _safe="unrouted"
    printf '%s/%s.md' "$(inbox_dir)" "$_safe"
}

# Open items addressed to a project, from the per-project file first, then any
# still-unmigrated items in the legacy file. The legacy match is the same expression
# Check 3.2 has always used, so behaviour there is unchanged.
inbox_items_for() {
    local _proj="${1:-}" _pf _legacy
    [ -n "$_proj" ] || return 0
    _pf="$(inbox_project_file "$_proj")"
    _legacy="$(inbox_legacy)"

    [ -f "$_pf" ] && grep -- '^- \[ \]' "$_pf" 2>/dev/null
    [ -f "$_legacy" ] && grep -i -- "- \[ \].*\*\*[[:space:]]*$_proj[[:space:]]*\*\*" "$_legacy" 2>/dev/null
    return 0
}

# CFG-65: the legacy file opens with documentation — a format example containing a
# literal `- [ ] [Task description]` and dated prose — so a whole-file read reports an
# item and a stale date in an empty inbox. Items live below this marker; a file without
# it (older machines, test fixtures) is read whole, as before.
INBOX_ITEMS_MARKER='<!-- Pending tasks appear below this line -->'

inbox_legacy_body() {
    local _legacy
    _legacy="$(inbox_legacy)"
    [ -f "$_legacy" ] || return 0
    if grep -qF -- "$INBOX_ITEMS_MARKER" "$_legacy" 2>/dev/null; then
        awk -v m="$INBOX_ITEMS_MARKER" 'found; index($0, m) { found = 1 }' "$_legacy" 2>/dev/null
    else
        cat "$_legacy" 2>/dev/null
    fi
    return 0
}

# Every open item across both sources. Used for the oversize/staleness signals, which
# must describe the whole corpus rather than one project's slice.
inbox_all_items() {
    local _d _f
    _d="$(inbox_dir)"
    if [ -d "$_d" ]; then
        for _f in "$_d"/*.md; do
            [ -f "$_f" ] || continue
            grep -- '^- \[ \]' "$_f" 2>/dev/null
        done
    fi
    inbox_legacy_body | grep -- '^- \[ \]' 2>/dev/null
    return 0
}

inbox_total_count() { inbox_all_items | grep -c '^- \[ \]' 2>/dev/null | head -1; }

# Open items for any of several names, each line once (a session answers to more than
# one name, see inbox_names_for_dir).
inbox_items_for_any() {
    local _n
    for _n in "$@"; do inbox_items_for "$_n"; done | awk '!seen[$0]++'
    return 0
}

# ── Registry (CFG-1091) ──────────────────────────────────────────────────────
# registry.md is the only map from a tag to a session. Three facts the delivery code
# never read: a project's registry NAME can differ from its directory (fleet-auditor
# lives in auditor/), a row can be `deleted …` (jasmin, 2026-11-04), and the Removed
# Projects table exists. Each made mail undeliverable with no signal (audit 2026-11-20).
inbox_registry() { printf '%s' "${INBOX_REGISTRY:-$(_inbox_repo)/registry.md}"; }

# Every project row as `name|parent|path|phase|table|notes`; `table` is main for the
# Projects table and removed for the Removed Projects table (its Status column is the
# phase). Columns are located by header name, so a fixture with fewer columns and a
# future column move both parse; the `—` placeholder reads as empty.
inbox_registry_rows() {
    local _r
    _r="$(inbox_registry)"
    [ -f "$_r" ] || return 0
    sed -n '/^## Projects/,/^## [^P]/p' "$_r" 2>/dev/null | awk -F'|' '
        function trim(s) { gsub(/^[ \t`*]+|[ \t`*]+$/, "", s); return s }
        function col(n) { return (n in idx) ? trim($idx[n]) : "" }
        BEGIN { tbl = "main" }
        /^\|/ {
            if (trim($2) == "Project") {
                split("", idx); for (i = 2; i < NF; i++) idx[trim($i)] = i
                tbl = ("Previous Path" in idx) ? "removed" : "main"; next
            }
            if ($2 ~ /^[ \t]*-+[ \t]*$/) next
            name = trim($2); if (name == "") next
            par = col("Parent"); if (par == "—" || par == "-") par = ""
            path = col("Path"); if (path == "") path = col("Previous Path")
            phase = col("Phase"); if (phase == "") phase = col("Status")
            printf "%s|%s|%s|%s|%s|%s\n", name, par, path, phase, tbl, col("Notes")
        }' 2>/dev/null
    return 0
}

# Live rows only: a `deleted …` phase or a Removed Projects row is not a destination.
_inbox_live_rows() { inbox_registry_rows | awk -F'|' '$5 == "main" && tolower($4) !~ /^deleted/'; }

inbox_registry_all_names()  { inbox_registry_rows | awk -F'|' '{ print tolower($1) }' | sort -u; }
inbox_registry_live_names() { _inbox_live_rows | awk -F'|' '{ print tolower($1) }' | sort -u; }

# Directory basenames of live projects (lower-case): the names a session's cwd carries.
inbox_registry_live_dirnames() {
    _inbox_live_rows | awk -F'|' '$3 != "" {
        p = $3; sub(/\/+$/, "", p); sub(/.*\//, "", p); if (p != "") print tolower(p) }' | sort -u
}

# Dead target? Prints `phase|successor` and returns 0 for a `deleted …` row or a Removed
# Projects row; returns 1 for a live or unknown name. The successor is the Parent column,
# else the live project the notes name after "merged/absorbed into" or "superseded by".
inbox_registry_dead() {
    local _want _row _parent _phase _notes _succ=""
    _want=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    [ -n "$_want" ] || return 1
    _row=$(inbox_registry_rows | awk -F'|' -v w="$_want" \
        'tolower($1) == w && ($5 == "removed" || tolower($4) ~ /^deleted/) { print; exit }')
    [ -n "$_row" ] || return 1
    _parent=$(printf '%s' "$_row" | cut -d'|' -f2)
    _phase=$(printf '%s' "$_row" | cut -d'|' -f4)
    _notes=$(printf '%s' "$_row" | cut -d'|' -f6-)
    if [ -n "$_parent" ]; then
        _succ="$_parent"
    else
        _succ=$(printf '%s %s' "$_phase" "$_notes" \
            | grep -oiE '(merged|absorbed) into [`~/]*[A-Za-z0-9._-]+|superseded by [`~/]*[A-Za-z0-9._-]+' \
            | head -1 | sed -E 's/^.* (into|by) [`~\/]*//')
        if [ -n "$_succ" ] && ! inbox_registry_live_names | grep -qxF -- "$(printf '%s' "$_succ" | tr '[:upper:]' '[:lower:]')"; then
            _succ=""
        fi
    fi
    printf '%s|%s\n' "$_phase" "$_succ"
    return 0
}

# Registry name of the project living in <dir>: the live row whose Path basename equals
# the directory's basename; an exact path match (with ~ expanded) wins over a basename tie.
inbox_registry_name_for_dir() {
    local _dir="${1:-}" _base _home
    [ -n "$_dir" ] || return 0
    _base=$(basename "$_dir" | tr '[:upper:]' '[:lower:]')
    _home="${USER_HOME:-${HOME:-}}"
    _inbox_live_rows | awk -F'|' -v b="$_base" -v d="$_dir" -v h="$_home" '
        $3 != "" {
            p = $3; sub(/\/+$/, "", p); full = p; sub(/^~/, h, full)
            n = p; sub(/.*\//, "", n)
            if (full == d) exact = $1
            else if (tolower(n) == b && first == "") first = $1
        }
        END { if (exact != "") print exact; else if (first != "") print first }'
    return 0
}

# The names a session in <dir> answers to: its directory basename, plus its registry
# name when that differs (CFG-1091 D2: fleet-auditor's mail sat in inbox/fleet-auditor.md
# while the hook in auditor/ read inbox/auditor.md).
inbox_names_for_dir() {
    local _dir="${1:-$(pwd)}" _base _reg
    _base=$(basename "$_dir")
    printf '%s\n' "$_base"
    _reg=$(inbox_registry_name_for_dir "$_dir")
    if [ -n "$_reg" ] && [ "$(printf '%s' "$_reg" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$_base" | tr '[:upper:]' '[:lower:]')" ]; then
        printf '%s\n' "$_reg"
    fi
    return 0
}

# Children (registry Parent column) of any of the names given. A deleted child stays
# listed: its parent is the one who can still act on its mail.
inbox_children_of() {
    local _p _w="|"
    for _p in "$@"; do _w="$_w$(printf '%s' "$_p" | tr '[:upper:]' '[:lower:]')|"; done
    inbox_registry_rows | awk -F'|' -v w="$_w" \
        '$5 == "main" && $2 != "" && index(w, "|" tolower($2) "|") { print $1 }'
    return 0
}

# What a parent is told about each child's mail: the count plus a brief of at most 5
# items cut to 160 chars, so a parent with many children never imports the CFG-515
# payload problem (CFG-134 surfaced children; CFG-1091 D4 made it read the per-project
# files, where every item has lived since CFG-542).
inbox_child_report() {
    local _child _items _n _brief _more _msg=""
    while IFS= read -r _child; do
        [ -n "$_child" ] || continue
        _items=$(inbox_items_for "$_child")
        [ -n "$_items" ] || continue
        _n=$(printf '%s\n' "$_items" | grep -c -- '^- \[ \]' 2>/dev/null | head -1)
        [ -n "$_n" ] && [ "$_n" -gt 0 ] 2>/dev/null || _n=1
        _brief=$(printf '%s\n' "$_items" | head -n 5 | cut -c1-160 | tr '\n' '~' | sed 's/~$//; s/~/ … /g')
        _more=$(( _n - 5 ))
        [ "$_more" -gt 0 ] && _brief="$_brief (+$_more more)"
        _msg="${_msg:+$_msg | }$_child ($_n item(s)): $_brief"
    done <<EOF
$(inbox_children_of "$@")
EOF
    printf '%s' "$_msg"
    return 0
}

# Per-project files no session will ever read: the stem matches neither a live registry
# name nor a live project directory, both folded as inbox_project_file folds them.
# Prints `stem count` per offender. Silent without a registry; `new-project` is the
# reserved placeholder (CFG-483).
inbox_unreadable_files() {
    local _d _f _stem _n _ok
    _d="$(inbox_dir)"
    [ -d "$_d" ] || return 0
    _ok=$( { inbox_registry_live_names; inbox_registry_live_dirnames; } \
        | while IFS= read -r _n; do [ -n "$_n" ] && basename "$(inbox_project_file "$_n")" .md; done | sort -u)
    [ -n "$_ok" ] || return 0
    for _f in "$_d"/*.md; do
        [ -f "$_f" ] || continue
        _n=$(grep -c -- '^- \[ \]' "$_f" 2>/dev/null | head -1)
        [ "${_n:-0}" -gt 0 ] 2>/dev/null || continue
        _stem=$(basename "$_f" .md)
        [ "$_stem" = "new-project" ] && continue
        printf '%s\n' "$_ok" | grep -qxF -- "$_stem" && continue
        printf '%s %s\n' "$_stem" "$_n"
    done
    return 0
}
