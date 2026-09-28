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

# Every open item across both sources. Used for the oversize/staleness signals, which
# must describe the whole corpus rather than one project's slice.
inbox_all_items() {
    local _d _legacy _f
    _d="$(inbox_dir)"; _legacy="$(inbox_legacy)"
    if [ -d "$_d" ]; then
        for _f in "$_d"/*.md; do
            [ -f "$_f" ] || continue
            grep -- '^- \[ \]' "$_f" 2>/dev/null
        done
    fi
    [ -f "$_legacy" ] && grep -- '^- \[ \]' "$_legacy" 2>/dev/null
    return 0
}

inbox_total_count() { inbox_all_items | grep -c '^- \[ \]' 2>/dev/null | head -1; }
