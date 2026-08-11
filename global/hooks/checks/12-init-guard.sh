#!/usr/bin/env bash
# Check 12.1: Detect if project CLAUDE.md was nuked by /init
# If a project has a CLAUDE.md without the agent-fleet-managed marker,
# AND the project is in the registry, it was likely overwritten by /init.

_project_claude_md=""
for _candidate in "$PROJECT_DIR/CLAUDE.md" "$PROJECT_DIR/.claude/CLAUDE.md"; do
    [ -f "$_candidate" ] && _project_claude_md="$_candidate" && break
done

if [ -n "$_project_claude_md" ]; then
    # Check for fleet marker
    if ! grep -q 'agent-fleet-managed' "$_project_claude_md" 2>/dev/null; then
        # Only warn if project is in registry (i.e., was set up by agent-fleet)
        _project_name="$(basename "$PROJECT_DIR")"
        if [ -f "$CONFIG_REPO/registry.md" ] && grep -q "$_project_name" "$CONFIG_REPO/registry.md" 2>/dev/null; then
            WARNINGS="${WARNINGS:+$WARNINGS;}[WARN] $PROJECT_DIR/CLAUDE.md missing agent-fleet marker — may have been overwritten by /init. Check git log and restore if needed."
        fi
    fi
fi
