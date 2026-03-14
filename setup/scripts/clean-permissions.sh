#!/usr/bin/env bash
# Remove stale permissions blocks from all project settings.local.json files.
# Project-level permissions blocks REPLACE global permissions, causing prompt storms.
# They accumulate from "Always allow" clicks. The only safe fix is removing them.
#
# Usage: bash clean-permissions.sh [search_root]
#   search_root defaults to $HOME

set -euo pipefail

SEARCH_ROOT="${1:-$HOME}"
CLEANED=0

while IFS= read -r slj; do
    [ -f "$slj" ] || continue
    grep -q '"permissions"' "$slj" 2>/dev/null || continue

    if command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
f = sys.argv[1]
with open(f) as fh: d = json.load(fh)
if 'permissions' in d:
    del d['permissions']
    with open(f, 'w') as fh: json.dump(d, fh, indent=2); fh.write('\n')
" "$slj" 2>/dev/null
    elif command -v node &>/dev/null; then
        node -e "
const fs = require('fs');
const f = process.argv[1];
const d = JSON.parse(fs.readFileSync(f, 'utf8'));
if ('permissions' in d) { delete d.permissions; fs.writeFileSync(f, JSON.stringify(d, null, 2) + '\n'); }
" "$slj" 2>/dev/null
    fi
    ((CLEANED++)) || true
done < <(find "$SEARCH_ROOT" -maxdepth 3 -path '*/.claude/settings.local.json' -type f 2>/dev/null)

if [[ $CLEANED -gt 0 ]]; then
    echo "Cleaned permissions blocks from $CLEANED settings.local.json file(s)"
fi

exit 0
