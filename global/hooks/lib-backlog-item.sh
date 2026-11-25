#!/usr/bin/env bash
# lib-backlog-item.sh — file one open item into a project's backlog.md (CFG-574, CFG-1094).
# Sourced by checks/10-project-setup-check.sh and setup/scripts/project-conformance-lib.sh.
# The caller decides idempotency (grep for its own item first) and the item's text; this
# library owns the ID allocation and the placement.

[[ "${_LIB_BACKLOG_ITEM_LOADED:-}" == "true" ]] && return 0
_LIB_BACKLOG_ITEM_LOADED="true"

# backlog_next_id <backlog> — the next free ID under the backlog's dominant prefix, padded like
# the widest existing one; empty when the backlog uses none. The prefix is judged on the ID
# each ITEM opens with — a young backlog may cite another project's IDs (`CFG-512`) more often
# than it has items of its own — and only falls back to every ID in the file when no item
# carries one. The number is what follows the last '-': `S3-12` is 12, not 312.
backlog_next_id() {
    local bl="$1" prefix="" num=""
    [ -f "$bl" ] || return 0
    prefix=$(sed -nE 's/^[[:space:]]*[-*] \[[^]]*\][^`]*`([A-Z][A-Z0-9]{1,4})-[0-9]+`.*/\1/p' "$bl" 2>/dev/null \
        | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')
    [ -n "$prefix" ] || prefix=$(grep -oE '`[A-Z][A-Z0-9]{1,4}-[0-9]+`' "$bl" 2>/dev/null | tr -d '`' \
        | sed 's/-[0-9]*$//' | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')
    [ -n "$prefix" ] || return 0
    num=$(grep -oE "\`$prefix-[0-9]+\`" "$bl" | sed -E 's/.*-([0-9]+)`$/\1/' | sort -n | tail -1)
    printf "%s-%0${#num}d" "$prefix" "$((10#$num + 1))"
}

# backlog_add_item <backlog> <project-name> <item-line> — append <item-line> right under
# "## Open" (else at the end), creating the backlog when the project has none. The literal
# {ID} in <item-line> becomes "`<next id>` " or nothing. Echoes the ID used (may be empty);
# non-zero when the backlog cannot be written.
backlog_add_item() {
    local bl="$1" name="$2" item="$3" id="" tmp
    if [ ! -e "$bl" ]; then
        printf '# Backlog — %s\n\n## Open\n\n' "$name" > "$bl" 2>/dev/null || return 1
    fi
    [ -f "$bl" ] && [ -w "$bl" ] || return 1
    id=$(backlog_next_id "$bl")
    item="${item//\{ID\}/${id:+\`$id\` }}"
    tmp=$(mktemp "${TMPDIR:-/tmp}/bl-item.XXXXXX" 2>/dev/null) || return 1
    awk -v item="$item" '
        { print }
        !done && /^## Open[[:space:]]*$/ { getline nxt; if (nxt != "") { print ""; print item; print nxt } else { print nxt; print item }; done = 1 }
        END { if (!done) { print ""; print item } }
    ' "$bl" > "$tmp" && cat "$tmp" > "$bl" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    printf '%s' "$id"
}
