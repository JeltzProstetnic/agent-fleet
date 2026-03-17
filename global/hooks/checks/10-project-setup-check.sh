# Check group 10: Incomplete project setup detection
# Warns when a project's CLAUDE.md exists but is missing key sections.
# Shared vars used: PROJECT_DIR, WARNINGS

# Find CLAUDE.md (check .claude/ first, then root)
_PROJECT_CLAUDE=""
if [ -f "$PROJECT_DIR/.claude/CLAUDE.md" ]; then
    _PROJECT_CLAUDE="$PROJECT_DIR/.claude/CLAUDE.md"
elif [ -f "$PROJECT_DIR/CLAUDE.md" ]; then
    _PROJECT_CLAUDE="$PROJECT_DIR/CLAUDE.md"
fi

if [ -n "$_PROJECT_CLAUDE" ]; then
    _setup_issues=""
    _line_count=$(wc -l < "$_PROJECT_CLAUDE" 2>/dev/null || echo "0")

    # Check for Active Roster section
    if ! grep -qi "## .*Roster" "$_PROJECT_CLAUDE" 2>/dev/null; then
        _setup_issues="${_setup_issues}missing Roster, "
    fi

    # Check for Reference section
    if ! grep -qi "## Reference" "$_PROJECT_CLAUDE" 2>/dev/null; then
        _setup_issues="${_setup_issues}missing Reference, "
    fi

    # Check for Project Structure section
    if ! grep -qi "## Project Structure\|## Structure" "$_PROJECT_CLAUDE" 2>/dev/null; then
        _setup_issues="${_setup_issues}missing Project Structure, "
    fi

    # Check minimum line count (properly set up projects have 40+ lines)
    if [ "$_line_count" -lt 40 ]; then
        _setup_issues="${_setup_issues}only ${_line_count} lines (expect 40+), "
    fi

    # If issues found, warn
    if [ -n "$_setup_issues" ]; then
        _setup_issues=$(echo "$_setup_issues" | sed 's/, $//')
        WARNINGS="${WARNINGS:+$WARNINGS | }PROJECT SETUP INCOMPLETE: ${_setup_issues}. Load foundation/project-setup.md and complete setup before starting work."
    fi
fi
