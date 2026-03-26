#!/usr/bin/env bash
# rotate-session.sh — Archive current session context to history + log
# Usage: rotate-session.sh [project-dir]
# Defaults to current directory if no argument.
#
# What it does:
# 1. Parses session-context.md → extracts session info, completed items, key decisions
# 2. Prepends a compact entry to session-history.md (rolling last 3)
# 3. Appends same entry to docs/session-log.md (full archive)
# 4. Resets session-context.md to blank template

set -euo pipefail

# Source lib.sh for get_hostname() if available
_ROTATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_ROTATE_SCRIPT_DIR}/../lib.sh" ]]; then
    source "${_ROTATE_SCRIPT_DIR}/../lib.sh"
fi

PROJECT_DIR="${1:-.}"
SESSION_FILE="$PROJECT_DIR/session-context.md"
HISTORY_FILE="$PROJECT_DIR/session-history.md"
LOG_DIR="$PROJECT_DIR/docs"
LOG_FILE="$LOG_DIR/session-log.md"

# --- Check session-context.md exists and has content ---
if [[ ! -f "$SESSION_FILE" ]]; then
    echo "No session-context.md found in $PROJECT_DIR — nothing to rotate."
    exit 0
fi

if [[ ! -s "$SESSION_FILE" ]]; then
    echo "session-context.md is empty — nothing to rotate."
    exit 0
fi

# --- Detect blank template (never populated by the session) ---
# A session-context.md is "blank" if Session Goal is empty AND there are no
# completed items (checkboxes or section) AND no key decisions recorded.
# This prevents useless "(no completed items recorded)" entries in history.
CONTENT=$(cat "$SESSION_FILE")

HAS_GOAL=$(printf '%s\n' "$CONTENT" | sed -n 's/.*\*\*Session Goal\*\*: \(.\+\)/\1/p' | head -1 || true)
HAS_COMPLETED=$(printf '%s\n' "$CONTENT" | grep -i '^\s*- \[x\]' || true)
HAS_COMPLETED_SECTION=$(printf '%s\n' "$CONTENT" | awk '/^### Completed/{flag=1; next} /^###|^## |^- \*\*/{flag=0} flag' | grep '^- ' || true)
HAS_DECISIONS=$(printf '%s\n' "$CONTENT" | awk '/^##+ Key Decisions/{flag=1; next} /^## /{flag=0} flag' | sed '/^$/d' || true)

# Require: goal AND (at least one completed item OR at least one decision)
# Goal alone is not enough — prevents "Quick check" with zero content from creating garbage entries.
# No goal = blank template (already rotated or never used) — exit silently, not an error.
if [[ -z "$HAS_GOAL" ]]; then
    exit 0
fi

if [[ -z "$HAS_COMPLETED" && -z "$HAS_COMPLETED_SECTION" && -z "$HAS_DECISIONS" ]]; then
    echo "ERROR: session-context.md has a goal but no completed items or key decisions."
    echo "Before rotating, add at minimum:"
    echo "  - At least one completed item (- [x] ...)"
    echo "  - OR at least one key decision explaining what happened"
    echo ""
    echo "This prevents useless entries in session-history.md and session-log.md."
    exit 1
fi

# --- Fix A: Detect dangling forward references ---
# Patterns that suggest session-context references its own content:
#   "see below", "see ##", "see the ... section", "(below)"
# These become dangling pointers after rotation. Warn but don't block.
DANGLING_REFS=$(printf '%s\n' "$CONTENT" | grep -inE 'see below|see ##|see the .+ section|\(below\)' || true)
if [[ -n "$DANGLING_REFS" ]]; then
    echo "WARNING: session-context.md contains forward references that will become dangling after rotation:" >&2
    echo "$DANGLING_REFS" >&2
    echo "" >&2
    echo "Consider saving the referenced content to a dedicated file before rotating." >&2
    echo "" >&2
fi

# --- Fix B: Extract ## Next Session Task section ---
NEXT_TASK_FILE="$PROJECT_DIR/next-session-task.md"
NEXT_TASK_CONTENT=$(printf '%s\n' "$CONTENT" | awk '/^## Next Session Task/{flag=1; next} /^## /{flag=0} flag' | sed '/^$/d' || true)
if [[ -n "$NEXT_TASK_CONTENT" ]]; then
    printf '%s\n' "$NEXT_TASK_CONTENT" > "$NEXT_TASK_FILE"
    echo "Extracted ## Next Session Task to next-session-task.md."
else
    printf 'task: false\n' > "$NEXT_TASK_FILE"
fi

# --- Parse session-context.md ---

# Extract Last Updated timestamp
TIMESTAMP=$(printf '%s\n' "$CONTENT" | sed -n 's/.*\*\*Last Updated\*\*: \(.*\)/\1/p' | head -1)
if [[ -z "$TIMESTAMP" ]]; then
    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi
# Shorten to YYYY-MM-DDTHH:MMZ
SHORT_TS=$(echo "$TIMESTAMP" | sed 's/\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}\).*/\1Z/')

# Extract Machine
MACHINE=$(printf '%s\n' "$CONTENT" | sed -n 's/.*\*\*Machine\*\*: \(.*\)/\1/p' | head -1)
if [[ -z "$MACHINE" ]]; then
    MACHINE=$(get_hostname)
fi

# Extract Session Goal
GOAL=$(printf '%s\n' "$CONTENT" | sed -n 's/.*\*\*Session Goal\*\*: \(.*\)/\1/p' | head -1)
if [[ -z "$GOAL" ]]; then
    GOAL="(no goal recorded)"
fi

# Extract completed items — two formats supported:
# 1. "- [x] item" checkboxes anywhere in file (may be indented)
# 2. Plain bullets under "### Completed This Session" or "### Completed" subsection
COMPLETED=""
# Format 1: checkbox items — strict match: line must start with optional whitespace then "- [x]"
# (Loose grep -F '[x]' would also match template help text like "use `- [x]` checkbox...")
CHECKBOX_ITEMS=$(printf '%s\n' "$CONTENT" | grep -i '^\s*- \[x\]' | sed 's/^[[:space:]]*- \[[xX]\] /- /' || true)
# Format 2: plain bullets under ### Completed... subsection (only lines starting with "- ")
SECTION_ITEMS=$(printf '%s\n' "$CONTENT" | awk '/^### Completed/{flag=1; next} /^###|^## |^- \*\*/{flag=0} flag' | grep '^- ' || true)
# Combine (prefer checkbox if both exist, deduplicate unlikely but harmless)
if [[ -n "$CHECKBOX_ITEMS" && -n "$SECTION_ITEMS" ]]; then
    COMPLETED="$CHECKBOX_ITEMS
$SECTION_ITEMS"
elif [[ -n "$CHECKBOX_ITEMS" ]]; then
    COMPLETED="$CHECKBOX_ITEMS"
elif [[ -n "$SECTION_ITEMS" ]]; then
    COMPLETED="$SECTION_ITEMS"
fi
if [[ -z "$COMPLETED" ]]; then
    COMPLETED="- (no completed items recorded)"
fi

# Extract Key Decisions section content
# Get everything between "## Key Decisions" and the next "##" heading
DECISIONS=$(printf '%s\n' "$CONTENT" | awk '/^##+ Key Decisions/{flag=1; next} /^## /{flag=0} flag' | sed '/^$/d' || true)
if [[ -z "$DECISIONS" ]]; then
    DECISIONS="- (no decisions recorded)"
fi

# Extract Recovery Instructions section content
# Get everything between "## Recovery Instructions" and the next "##" heading (or EOF)
RECOVERY=$(printf '%s\n' "$CONTENT" | awk '/^## Recovery Instructions/{flag=1; next} /^## /{flag=0} flag' | sed '/^$/d' || true)

# Extract Pending items from Current State
PENDING=$(printf '%s\n' "$CONTENT" | sed -n 's/.*\*\*Pending\*\*: \(.*\)/\1/p' | head -1 || true)
# Strip placeholder values
[[ "$PENDING" == "—" || "$PENDING" == "-" || "$PENDING" == "none" || -z "$PENDING" ]] && PENDING=""

# --- Build the entry ---
# Include recovery/pending only if they have content
ENTRY="### $SHORT_TS — $MACHINE
**Goal:** $GOAL
**Completed:**
$COMPLETED
**Key Decisions:**
$DECISIONS"

# Append pending if non-empty
if [[ -n "$PENDING" ]]; then
    ENTRY="$ENTRY
**Pending at shutdown:** $PENDING"
fi

# Append recovery instructions if non-empty
if [[ -n "$RECOVERY" ]]; then
    ENTRY="$ENTRY
**Recovery/Next session:**
$RECOVERY"
fi

# --- Create/update session-history.md (rolling last 3) ---
if [[ ! -f "$HISTORY_FILE" ]]; then
    cat > "$HISTORY_FILE" <<EOF
# Session History

Rolling window of the last 3 sessions. Newest first.

$ENTRY
EOF
    echo "Created session-history.md with first entry."
else
    # Prepend entry after the header (everything before first ### entry)
    TEMP=$(mktemp)
    FIRST_ENTRY_LINE=$(grep -n '^### ' "$HISTORY_FILE" | head -1 | cut -d: -f1 || true)
    if [[ -n "$FIRST_ENTRY_LINE" ]]; then
        HEADER=$(head -n $((FIRST_ENTRY_LINE - 1)) "$HISTORY_FILE")
        EXISTING=$(tail -n +$FIRST_ENTRY_LINE "$HISTORY_FILE")
    else
        # No entries yet — header is the whole file
        HEADER=$(cat "$HISTORY_FILE")
        EXISTING=""
    fi

    {
        echo "$HEADER"
        echo ""
        echo "$ENTRY"
        echo ""
        echo "$EXISTING"
    } > "$TEMP"

    # Now trim to 3 entries max
    # Count ### entries and keep only first 3
    awk '
        BEGIN { count=0 }
        /^### / { count++ }
        count <= 3 { print }
    ' "$TEMP" > "${TEMP}.trimmed"

    mv "${TEMP}.trimmed" "$HISTORY_FILE"
    rm -f "$TEMP"

    # Count how many entries remain
    ENTRY_COUNT=$(grep -c '^### ' "$HISTORY_FILE" || true)
    echo "Updated session-history.md ($ENTRY_COUNT entries, max 3)."
fi

# --- Append to docs/session-log.md (full archive) ---
mkdir -p "$LOG_DIR"

if [[ ! -f "$LOG_FILE" ]]; then
    cat > "$LOG_FILE" <<EOF
# Session Log

Full session history. Newest first. Never pruned.

$ENTRY
EOF
    echo "Created docs/session-log.md with first entry."
else
    # Prepend entry after the header (everything before first ### entry)
    TEMP=$(mktemp)
    FIRST_ENTRY_LINE=$(grep -n '^### ' "$LOG_FILE" | head -1 | cut -d: -f1 || true)
    if [[ -n "$FIRST_ENTRY_LINE" ]]; then
        HEADER=$(head -n $((FIRST_ENTRY_LINE - 1)) "$LOG_FILE")
        EXISTING=$(tail -n +$FIRST_ENTRY_LINE "$LOG_FILE")
    else
        HEADER=$(cat "$LOG_FILE")
        EXISTING=""
    fi

    {
        echo "$HEADER"
        echo ""
        echo "$ENTRY"
        echo ""
        echo "$EXISTING"
    } > "$TEMP"

    mv "$TEMP" "$LOG_FILE"
    echo "Prepended entry to docs/session-log.md."
fi

# --- Check for multiple pending files from today ---
TODAY=$(date +%Y-%m-%d)
PENDING_TODAY=0
PENDING_LIST=""
for pf in "$PROJECT_DIR"/docs/pending-*.md; do
    [[ -f "$pf" ]] || continue
    PF_DATE=$(date -r "$pf" +%Y-%m-%d 2>/dev/null || true)
    if [[ "$PF_DATE" == "$TODAY" ]]; then
        PENDING_TODAY=$((PENDING_TODAY + 1))
        PENDING_LIST="${PENDING_LIST:+$PENDING_LIST, }$(basename "$pf")"
    fi
done
if [[ "$PENDING_TODAY" -gt 1 ]]; then
    echo "WARNING: Multiple pending files from today ($PENDING_TODAY): $PENDING_LIST" >&2
    echo "Consider consolidating into a single handoff file with headers." >&2
    echo "" >&2
fi

# --- Check for new backlog items without approval tracking ---
if [[ -f "$PROJECT_DIR/backlog.md" ]]; then
    # Extract only progress checkboxes and key decisions — not carry-over, pending refs, etc.
    _PROGRESS_CONTENT=$(printf '%s\n' "$CONTENT" | grep -i '^\s*- \[x\]' || true)
    _DECISIONS_CONTENT=$(printf '%s\n' "$CONTENT" | awk '/^##+ Key Decisions/{flag=1; next} /^## /{flag=0} flag' | sed '/^$/d' || true)
    _ACTIONABLE="${_PROGRESS_CONTENT}
${_DECISIONS_CONTENT}"
    # Find task IDs only in actionable sections (not carry-over, metadata, etc.)
    _SC_CFGIDS=$(printf '%s\n' "$_ACTIONABLE" | grep -oE '[A-Z]+-[0-9]+' | sort -u || true)
    if [[ -n "$_SC_CFGIDS" ]]; then
        _UNAPPROVED=""
        for _cid in $_SC_CFGIDS; do
            # Check if this ID appears in backlog as an open item (new this session?)
            _in_backlog=$(grep -c "^\- \[ \] .*\`$_cid\`" "$PROJECT_DIR/backlog.md" 2>/dev/null | head -1 || echo 0)
            [ "$_in_backlog" -gt 0 ] || continue
            # Check if session-context mentions approval for this item (search full content)
            _approved=$(printf '%s\n' "$CONTENT" | grep -ci "approv.*$_cid\|$_cid.*approv" || true)
            if [[ "$_approved" -eq 0 ]]; then
                _UNAPPROVED="${_UNAPPROVED:+$_UNAPPROVED, }$_cid"
            fi
        done
        if [[ -n "$_UNAPPROVED" ]]; then
            echo "WARNING: Open backlog items referenced in session without approval note: $_UNAPPROVED" >&2
            echo "Add 'user approved <ID> at <priority>' to session-context.md Key Decisions." >&2
            echo "" >&2
        fi
    fi
fi

# --- Reset session-context.md to blank template ---
cat > "$SESSION_FILE" <<'EOF'
# Session Context

## Session Info
- **Last Updated**:
- **Machine**:
- **Working Directory**:
- **Session Goal**:

## Current State
- **Active Task**:
- **Progress** (use `- [x]` checkbox for each completed item):
- **Pending**:

## Key Decisions

## Recovery Instructions

## Next Session Task
<!-- Fill this in during shutdown if the next session should continue specific work.
     Required fields: task: true|false, file: <path>, description: <text>
     The file: MUST point to a dedicated file (e.g., docs/pending-*.md), NEVER to session-context.md.
     rotate-session.sh extracts this section to next-session-task.md automatically. -->
EOF

# Pre-populate deterministic fields so the template isn't fully blank
_sed_i "s/^\(- \*\*Last Updated\*\*:\)$/\1 $(date +%Y-%m-%dT%H:%M:%S%z) (rotated)/" "$SESSION_FILE"
echo "Reset session-context.md to blank template (pre-populated timestamp)."
echo "Rotation complete."
echo ""
echo "Reminder: if significant decisions were made, update docs/decisions.md."
