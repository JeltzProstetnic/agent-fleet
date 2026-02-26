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

# --- Parse session-context.md ---
CONTENT=$(cat "$SESSION_FILE")

# Extract Last Updated timestamp
TIMESTAMP=$(echo "$CONTENT" | grep -oP '(?<=\*\*Last Updated\*\*: ).*' | head -1)
if [[ -z "$TIMESTAMP" ]]; then
    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi
# Shorten to YYYY-MM-DDTHH:MMZ
SHORT_TS=$(echo "$TIMESTAMP" | sed 's/\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}\).*/\1Z/')

# Extract Machine
MACHINE=$(echo "$CONTENT" | grep -oP '(?<=\*\*Machine\*\*: ).*' | head -1)
if [[ -z "$MACHINE" ]]; then
    MACHINE=$(hostname)
fi

# Extract Session Goal
GOAL=$(echo "$CONTENT" | grep -oP '(?<=\*\*Session Goal\*\*: ).*' | head -1)
if [[ -z "$GOAL" ]]; then
    GOAL="(no goal recorded)"
fi

# Extract completed items — two formats supported:
# 1. "- [x] item" checkboxes anywhere in file (may be indented)
# 2. Plain bullets under "### Completed This Session" or "### Completed" subsection
COMPLETED=""
# Format 1: checkbox items (strip indentation and checkbox prefix)
CHECKBOX_ITEMS=$(echo "$CONTENT" | grep -F '[x]' | sed 's/^[[:space:]]*- \[x\] /- /' || true)
# Format 2: plain bullets under ### Completed... subsection (only lines starting with "- ")
SECTION_ITEMS=$(echo "$CONTENT" | awk '/^### Completed/{flag=1; next} /^###|^## |^- \*\*/{flag=0} flag' | grep '^- ' || true)
# Combine
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
DECISIONS=$(echo "$CONTENT" | awk '/^## Key Decisions/{flag=1; next} /^## /{flag=0} flag' | sed '/^$/d' || true)
if [[ -z "$DECISIONS" ]]; then
    DECISIONS="- (no decisions recorded)"
fi

# Extract Recovery Instructions section content
# Get everything between "## Recovery Instructions" and the next "##" heading (or EOF)
RECOVERY=$(echo "$CONTENT" | awk '/^## Recovery Instructions/{flag=1; next} /^## /{flag=0} flag' | sed '/^$/d' || true)

# Extract Pending items from Current State
PENDING=$(echo "$CONTENT" | grep -oP '(?<=\*\*Pending\*\*: ).*' | head -1 || true)
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
    # Prepend entry after the header (first 3 lines: title + blank + description)
    TEMP=$(mktemp)
    # Extract header (everything before first ### or the first 3 lines)
    HEADER=$(head -3 "$HISTORY_FILE")
    # Extract existing entries
    EXISTING=$(tail -n +4 "$HISTORY_FILE")

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
    # Prepend entry after the header (first 3 lines)
    TEMP=$(mktemp)
    HEADER=$(head -3 "$LOG_FILE")
    EXISTING=$(tail -n +4 "$LOG_FILE")

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
