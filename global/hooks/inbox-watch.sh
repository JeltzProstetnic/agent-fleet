#!/usr/bin/env bash
# inbox-watch.sh — UserPromptSubmit hook (CFG-775): name this project's open
# cross-project inbox items on EVERY turn until they are dispatched.
#
# Startup reads the inbox once. Items filed later were only noticed by chance:
# 2026-10-19 a session told to wait for another project missed two items for ~1.5 h
# while reporting "still waiting". This is enforcement of startup step 1, not a rule.
#
# Silent when the project has no open items. Otherwise, every turn:
#   INBOX_PENDING: N open item(s) for <project> (M new since last turn) — ...
# M = items whose line hash is not in this session's seen-set, a hook-only marker
# ${TMPDIR:-/tmp}/cc-inbox-seen-<session_id> that the model never reads.
# stdout of a UserPromptSubmit hook is added to the model's context.

INPUT=""
[[ -t 0 ]] || INPUT=$(timeout 2 cat 2>/dev/null)

SID="nosession"; CWD=""
[[ "$INPUT" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && SID="${BASH_REMATCH[1]}"
[[ "$INPUT" =~ \"cwd\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && CWD="${BASH_REMATCH[1]}"
[[ -n "$CWD" ]] || CWD="$PWD"
PROJECT=$(basename "$CWD")   # same derivation as checks/03-inbox-services.sh

REPO="${INBOX_REPO:-${CONFIG_REPO:-$HOME/cfg-agent-fleet}}"
LIB="$REPO/setup/scripts/inbox-lib.sh"
[[ -f "$LIB" ]] || exit 0
# shellcheck disable=SC1090
. "$LIB" 2>/dev/null || exit 0
command -v inbox_items_for >/dev/null 2>&1 || exit 0

ITEMS=$(inbox_items_for "$PROJECT" 2>/dev/null | grep -- '^- \[ \]' || true)
[[ -n "$ITEMS" ]] || exit 0
N=$(printf '%s\n' "$ITEMS" | grep -c .)

SEEN="${TMPDIR:-/tmp}/cc-inbox-seen-${SID//[^A-Za-z0-9_-]/_}"
HASHES=$(printf '%s\n' "$ITEMS" | while IFS= read -r l; do printf '%s' "$l" | cksum | cut -d' ' -f1; done)
M=0
while IFS= read -r h; do
    [[ -n "$h" ]] || continue
    grep -qxF -- "$h" "$SEEN" 2>/dev/null || M=$((M + 1))
done <<< "$HASHES"
printf '%s\n' "$HASHES" > "$SEEN" 2>/dev/null

echo "INBOX_PENDING: $N open item(s) for $PROJECT ($M new since last turn) — read $REPO/cross-project/inbox/$(basename "$(inbox_project_file "$PROJECT")") and dispatch per startup step 1 now"
exit 0
