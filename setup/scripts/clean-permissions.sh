#!/usr/bin/env bash
# Remove ACCUMULATED permissions blocks from project settings.local.json files.
#
# Why this exists: when Claude Code asks "Allow this tool?" and the user clicks
# Allow, it appends the pattern to the project's settings.local.json under
# permissions.allow. Per knowledge/claude-code-permissions.md a project-level
# `permissions` key REPLACES the global one rather than merging with it, so an
# accumulated block silently shadows the whole global allow-list and every other
# command starts prompting. Cleaning has to be all-or-nothing for that reason:
# leaving a partial block behind still shadows global.
#
# Why the marker exists: that logic is right for a block nobody meant to create
# and wrong for one the user wrote on purpose. This script used to delete both.
# MG authored a project allow-list on 2026-08-15 so an unattended run would not
# stop on prompts; it was deleted at the next session start, because the script
# runs unconditionally from SessionStart check 4.1. An authored block could not
# survive one session boundary.
#
#   To protect a project's permissions block:
#       touch <project>/.claude/.permissions-authored
#
#   Trade-off that comes with it, stated once: a protected block still REPLACES
#   the global permissions for that project. It must therefore be COMPLETE — any
#   command not listed in it will prompt, global settings notwithstanding.
#
# Anything not protected is still cleaned, but is now backed up to
# <project>/.claude/.permissions-backup-<timestamp>.json first, so the operation
# is recoverable rather than final.
#
# Usage: bash clean-permissions.sh [search_root]
#   search_root defaults to $HOME

set -uo pipefail   # deliberately NOT -e: one unreadable project must not abort
                   # the sweep, and this runs from a SessionStart hook.

SEARCH_ROOT="${1:-$HOME}"
MARKER_NAME=".permissions-authored"
CLEANED=0
PROTECTED=0

_strip_permissions() {
    # Remove the permissions key from $1, writing the removed block to $2 first.
    # rc 0 = removed, 1 = nothing to do / unparseable (file left untouched).
    local file="$1" backup="$2"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$file" "$backup" <<'PY' 2>/dev/null
import json, sys
src, backup = sys.argv[1], sys.argv[2]
try:
    with open(src) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)                      # unparseable: leave the file exactly as found
if not isinstance(data, dict) or 'permissions' not in data:
    sys.exit(1)
removed = data.pop('permissions')
with open(backup, 'w') as fh:        # back up BEFORE the destructive write
    json.dump({'permissions': removed}, fh, indent=2)
    fh.write('\n')
with open(src, 'w') as fh:
    json.dump(data, fh, indent=2)
    fh.write('\n')
PY
        return $?
    elif command -v node >/dev/null 2>&1; then
        node -e '
const fs = require("fs");
const [src, backup] = process.argv.slice(1);
let data;
try { data = JSON.parse(fs.readFileSync(src, "utf8")); } catch (e) { process.exit(1); }
if (typeof data !== "object" || data === null || Array.isArray(data) || !("permissions" in data)) process.exit(1);
const removed = data.permissions;
delete data.permissions;
fs.writeFileSync(backup, JSON.stringify({permissions: removed}, null, 2) + "\n");
fs.writeFileSync(src, JSON.stringify(data, null, 2) + "\n");
' "$file" "$backup" 2>/dev/null
        return $?
    fi
    return 1
}

while IFS= read -r slj; do
    [ -f "$slj" ] || continue
    grep -q '"permissions"' "$slj" 2>/dev/null || continue

    claude_dir="$(dirname "$slj")"

    # User-authored block — never touched, and no backup churn either.
    if [ -e "$claude_dir/$MARKER_NAME" ]; then
        PROTECTED=$((PROTECTED + 1))
        continue
    fi

    backup="$claude_dir/.permissions-backup-$(date +%Y%m%dT%H%M%S).json"
    if _strip_permissions "$slj" "$backup"; then
        CLEANED=$((CLEANED + 1))
    else
        rm -f "$backup" 2>/dev/null || true   # nothing removed ⇒ no stray backup
    fi
done < <(find "$SEARCH_ROOT" -maxdepth 3 -path '*/.claude/settings.local.json' -type f 2>/dev/null)

if [[ $CLEANED -gt 0 ]]; then
    echo "Cleaned permissions blocks from $CLEANED settings.local.json file(s) (backed up alongside each)"
    echo "  To keep one: touch <project>/.claude/$MARKER_NAME"
fi
if [[ $PROTECTED -gt 0 ]]; then
    echo "Kept $PROTECTED user-authored permissions block(s) ($MARKER_NAME present)"
fi

exit 0
