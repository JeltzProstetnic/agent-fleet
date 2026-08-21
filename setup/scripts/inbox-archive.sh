#!/usr/bin/env bash
# inbox-archive.sh — Archive completed [x] items from cross-project inbox
#
# Usage: inbox-archive.sh <inbox-path> <archive-path>
#
# Strips all `- [x]` items (including multi-line continuations) from inbox,
# appends them to archive with a date header. Cleans up excessive blank lines.
# No-op if no completed items found.

set -euo pipefail

# Source lib.sh for _sed_i() if available
_ARCHIVE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_ARCHIVE_SCRIPT_DIR}/../lib.sh" ]]; then
    source "${_ARCHIVE_SCRIPT_DIR}/../lib.sh"
fi

INBOX="${1:?Usage: inbox-archive.sh <inbox-path> <archive-path>}"
ARCHIVE="${2:?Usage: inbox-archive.sh <inbox-path> <archive-path>}"

[[ -f "$INBOX" ]] || { echo "inbox-archive: inbox file not found: $INBOX" >&2; exit 1; }

# Parse inbox into keep/archive buckets
keep_lines=()
archive_lines=()
blank_buffer=()
state="header"  # header|completed|open
completed_count=0

while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^-\ \[x\] ]]; then
        # Start of completed item — flush blank buffer to archive
        archive_lines+=("${blank_buffer[@]}")
        blank_buffer=()
        archive_lines+=("$line")
        state="completed"
        ((completed_count++)) || true
    elif [[ "$line" =~ ^-\ \[\ \] ]]; then
        # Start of open item — flush blank buffer to keep
        keep_lines+=("${blank_buffer[@]}")
        blank_buffer=()
        keep_lines+=("$line")
        state="open"
    elif [[ -z "$line" ]]; then
        # Blank line — buffer it
        blank_buffer+=("$line")
    elif [[ "$state" == "header" ]]; then
        keep_lines+=("${blank_buffer[@]}")
        blank_buffer=()
        keep_lines+=("$line")
    elif [[ "$state" == "completed" ]]; then
        # Continuation of completed item (indented or non-list line)
        archive_lines+=("${blank_buffer[@]}")
        blank_buffer=()
        archive_lines+=("$line")
    elif [[ "$state" == "open" ]]; then
        # Continuation of open item
        keep_lines+=("${blank_buffer[@]}")
        blank_buffer=()
        keep_lines+=("$line")
    else
        # Fallback: keep
        keep_lines+=("${blank_buffer[@]}")
        blank_buffer=()
        keep_lines+=("$line")
    fi
done < "$INBOX"

# Flush remaining blank buffer to keep (trailing blanks)
keep_lines+=("${blank_buffer[@]}")

# No-op if nothing to archive
if [[ $completed_count -eq 0 ]]; then
    exit 0
fi

# Write archive — append to existing or create new
if [[ -f "$ARCHIVE" ]]; then
    # Append with date section
    {
        echo ""
        echo "## Archived $(date +%Y-%m-%d)"
        echo ""
        printf '%s\n' "${archive_lines[@]}"
    } >> "$ARCHIVE"
else
    # Create new archive
    {
        echo "# Cross-Project Inbox — Archive"
        echo ""
        echo "Completed items moved here by inbox-archive.sh or manually during sessions."
        echo ""
        echo "## Archived $(date +%Y-%m-%d)"
        echo ""
        printf '%s\n' "${archive_lines[@]}"
    } > "$ARCHIVE"
fi

# Rewrite inbox — collapse excessive blank lines
{
    prev_blank=0
    for line in "${keep_lines[@]}"; do
        if [[ -z "$line" ]]; then
            ((prev_blank++)) || true
            # Allow max 1 consecutive blank line
            if [[ $prev_blank -le 1 ]]; then
                echo "$line"
            fi
        else
            prev_blank=0
            echo "$line"
        fi
    done
} > "$INBOX"

# Remove trailing blank lines
_sed_i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$INBOX"

echo "Archived $completed_count completed item(s) from $(basename "$INBOX")"
