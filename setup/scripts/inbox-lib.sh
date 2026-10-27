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
