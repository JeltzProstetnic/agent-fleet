#!/usr/bin/env bash
# Check group 4b: auto-memory detection (split out of 04-auto-fix.sh by CFG-201, 2026-11-04)
# Checks: 4.7 (MEMORY.md / memory/ in the project dir), 4.7b (flag + CC's real memory location)
# Shared vars used: PROJECT_DIR, WARNINGS, CLAUDE_CONFIG_DIR, CLAUDE_CODE_DISABLE_AUTO_MEMORY
#
# NOTE: stdout from a check is a JSON contract (CFG-503). Never echo here.

# Check 4.7: MEMORY.md / memory/ violation detection (fleet rules prohibit auto-memory)
if [ -f "$PROJECT_DIR/MEMORY.md" ] || [ -d "$PROJECT_DIR/memory" ]; then
    _mem_targets=""
    [ -f "$PROJECT_DIR/MEMORY.md" ] && _mem_targets="MEMORY.md"
    [ -d "$PROJECT_DIR/memory" ] && _mem_targets="${_mem_targets:+$_mem_targets or }memory/"
    WARNINGS="${WARNINGS:+$WARNINGS | }[WARN] $PROJECT_DIR has $_mem_targets — fleet rules prohibit auto-memory. Delete and use proper fleet structure."
fi
# Check 4.7b (CFG-201): auto-memory is OFF fleet-wide via the settings template. CC writes it to
# $CLAUDE_CONFIG_DIR/projects/<cwd>/memory/, never the project dir. Report the flag missing from
# this session's env, and any memory file written after the 2026-11-04 cutover (older files are
# migrated history — silent, or this would warn every session forever).
case "${CLAUDE_CODE_DISABLE_AUTO_MEMORY:-}" in
    1|true|TRUE|True|yes|on) ;;
    *) WARNINGS="${WARNINGS:+$WARNINGS | }[WARN] auto-memory is ON in this session (CLAUDE_CODE_DISABLE_AUTO_MEMORY=${CLAUDE_CODE_DISABLE_AUTO_MEMORY:-unset}) — run sync.sh deploy, then restart (CFG-201)." ;;
esac
_MEM_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
if [ -d "$_MEM_ROOT" ]; then
    _mem_new=$(find "$_MEM_ROOT" -mindepth 3 -maxdepth 3 -path '*/memory/*' -type f -newermt 2026-11-04 2>/dev/null \
        | sed "s|^$_MEM_ROOT/||; s|/memory/.*||" | sort -u)
    if [ -n "$_mem_new" ]; then
        _mem_n=$(printf '%s\n' "$_mem_new" | wc -l | tr -d ' ')
        WARNINGS="${WARNINGS:+$WARNINGS | }[WARN] auto-memory written after the CFG-201 cutover in $_mem_n project(s): $(printf '%s\n' "$_mem_new" | head -3 | paste -sd, -) (under $_MEM_ROOT) — move the content into fleet files, then delete it."
    fi
fi
