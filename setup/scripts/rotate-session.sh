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
if [[ -z "$HAS_GOAL" ]]; then
    echo "ERROR: session-context.md has no Session Goal — refusing to rotate."
    echo "Set Session Goal (even if just 'No significant activity') before rotating."
    exit 1
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
    MACHINE=$(hostname)
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
    FIRST_ENTRY_LINE=$(grep -n '^### ' "$HISTORY_FILE" | head -1 | cut -d: -f1)
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
    FIRST_ENTRY_LINE=$(grep -n '^### ' "$LOG_FILE" | head -1 | cut -d: -f1)
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
EOF

echo "Reset session-context.md to blank template."
echo "Rotation complete."
echo ""
echo "Reminder: if significant decisions were made, update docs/decisions.md."
