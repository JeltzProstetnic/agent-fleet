#!/usr/bin/env bash
# PreToolUse hook: warn before committing manifest-tracked files without template-push verification.
# Blocks `git commit` (Bash tool) when staged files appear in template-sync-manifest.md
# AND no `.template-push-verified-<HEAD-sha>` marker exists for the current HEAD.
#
# Escape hatch: wrap commit in `bash -c '...'` to bypass (mirrors flatpak-kill-guard pattern).
# Exit 0 = allow, Exit 2 + stderr = block with instructions.
set -euo pipefail

INPUT=$(cat)

# Fast exit: only inspect Bash tool calls
if [[ "$INPUT" != *'"tool_name":"Bash"'* && "$INPUT" != *'"tool_name": "Bash"'* ]]; then
    exit 0
fi

# Extract command
cmd=""
if command -v jq &>/dev/null; then
    cmd=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
    cmd=$(echo "$INPUT" | grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"command"[^"]*"\([^"]*\)"/\1/')
fi
[ -z "$cmd" ] && exit 0

# Escape hatch: explicit bash -c wrapper bypasses the guard
if [[ "$cmd" =~ ^[[:space:]]*bash[[:space:]]+-c[[:space:]] ]]; then
    exit 0
fi

# Match `git commit` or `git -C <path> commit` (allow flags before "commit")
# Reject anything that isn't a commit invocation
if [[ ! "$cmd" =~ (^|[[:space:]\;\&\|])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(.*[[:space:]])?commit([[:space:]]|$) ]]; then
    exit 0
fi

# Determine repo (honor `git -C <path>`; default to PWD)
repo="${PWD}"
if [[ "$cmd" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
    repo="${BASH_REMATCH[1]}"
fi
repo="${repo/#\~/$HOME}"

# Only enforce inside the cfg-agent-fleet repo
manifest="$repo/template-sync-manifest.md"
[ -f "$manifest" ] || exit 0

# Collect manifest-tracked file list (parse "Tracked Files — Must Be Identical" + "Intentional Diffs" tables)
# Lines like: "| `path/to/file` | reason |"
mapfile -t tracked < <(grep -oE '^\|[[:space:]]*`[^`]+`' "$manifest" 2>/dev/null | sed -E 's/^\|[[:space:]]*`([^`]+)`.*/\1/' | sort -u)
[ "${#tracked[@]}" -eq 0 ] && exit 0

# What's staged?
staged=$(git -C "$repo" diff --cached --name-only 2>/dev/null) || exit 0
[ -z "$staged" ] && exit 0

# Find intersection
hits=()
while IFS= read -r f; do
    [ -z "$f" ] && continue
    for t in "${tracked[@]}"; do
        [[ "$f" == "$t" ]] && hits+=("$f") && break
    done
done <<< "$staged"
[ "${#hits[@]}" -eq 0 ] && exit 0

# Check marker for current HEAD
head_sha=$(git -C "$repo" rev-parse HEAD 2>/dev/null) || exit 0
marker="$repo/.template-push-verified-${head_sha}"
[ -f "$marker" ] && exit 0

# Block: emit guidance to stderr
{
    echo "MANIFEST_PUSH_CHECK — staged commit touches template-tracked files but no verification marker for HEAD ${head_sha:0:8}."
    echo
    echo "Files in commit that are tracked by template-sync-manifest.md:"
    for h in "${hits[@]}"; do echo "  - $h"; done
    echo
    echo "Required before committing:"
    echo "  1. bash sync.sh template-push --dry-run"
    echo "  2. If drift reported: bash sync.sh template-push --commit"
    echo "  3. Push agent-fleet if needed: git -C ~/agent-fleet push"
    echo "  4. touch '$marker'"
    echo
    echo "Escape hatch (only if you've verified another way): re-run as bash -c '<git commit ...>'"
} >&2
exit 2
