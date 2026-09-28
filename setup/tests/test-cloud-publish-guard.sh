#!/usr/bin/env bash
# Tests for global/hooks/cloud-publish-guard.sh
#
# Incident 2026-08-24: the Artifact tool published a user's
# unpublished cover art to claude.ai without consent. No hook matched Artifact
# and no rule mentioned publishing, so nothing in the fleet could have stopped
# it. The vendor tool description says "Publishing proactively is fine for your
# own work-product" at the point of action every turn and cannot be edited —
# only a hard block outranks it.
#
# Exit 2 = block. Exit 0 = allow.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${CLOUD_GUARD:-$REPO/global/hooks/cloud-publish-guard.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/proj/.claude"

run() { # run <json> ; echoes exit code
  printf '%s' "$1" | CLAUDE_PROJECT_DIR="$TMP/proj" bash "$HOOK" >/dev/null 2>&1
  echo $?
}

expect() { # expect <label> <json> <code>
  local got; got=$(run "$2")
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1 (expected exit $3, got $got)"; fi
}

if [ ! -f "$HOOK" ]; then
  echo "  FAIL: hook not found at $HOOK"
  echo; echo "cloud-publish-guard: 0 passed, 1 failed"; exit 1
fi

echo "== cloud-publish-guard =="

# 1. The incident itself: a bare publish must be blocked.
expect "publish is blocked" \
  '{"tool_name":"Artifact","tool_input":{"file_path":"/tmp/cover.html","favicon":"📕"}}' 2

# 2. Explicit action:publish must be blocked too.
expect "explicit action:publish is blocked" \
  '{"tool_name":"Artifact","tool_input":{"action":"publish","file_path":"/tmp/x.html"}}' 2

# 3. Enumeration sends nothing outward and must be allowed.
expect "action:list is allowed" \
  '{"tool_name":"Artifact","tool_input":{"action":"list"}}' 0

# 4. Other tools must pass straight through — this hook must not become a
#    general chokepoint on every tool call.
expect "non-Artifact tool passes through" \
  '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x"}}' 0

# 5. Spacing variants of the JSON must not defeat the matcher.
expect "spaced JSON key still matches" \
  '{"tool_name": "Artifact", "tool_input": {"file_path": "/tmp/x.html"}}' 2

# 6. Explicit per-session consent unblocks it.
touch "$TMP/proj/.claude/.artifact-consent"
expect "consent marker allows publish" \
  '{"tool_name":"Artifact","tool_input":{"file_path":"/tmp/cover.html"}}' 0
rm -f "$TMP/proj/.claude/.artifact-consent"

# 7. Removing the marker re-arms the block — consent must not be sticky.
expect "block re-arms once consent is removed" \
  '{"tool_name":"Artifact","tool_input":{"file_path":"/tmp/cover.html"}}' 2

# 8. The block message must name a usable alternative, or the next session just
#    retries the same call. Self-owned hosting is the whole point.
msg=$(printf '%s' '{"tool_name":"Artifact","tool_input":{"file_path":"/tmp/x.html"}}' \
      | CLAUDE_PROJECT_DIR="$TMP/proj" bash "$HOOK" 2>&1 >/dev/null)
if grep -qi 'vps\|nuc\|hostinger\|local' <<<"$msg"; then ok "block message names a self-hosted alternative"
else bad "block message gives no alternative"; fi

# 9. The protected organisation is configured, not hardcoded (CFG-700): with
#    CLOUD_PUBLISH_PROTECTED_ORG set, the block message names it; unset, it still
#    carries a generic corporate-content prohibition.
msg_org=$(printf '%s' '{"tool_name":"Artifact","tool_input":{"file_path":"/tmp/x.html"}}' \
      | CLOUD_PUBLISH_PROTECTED_ORG="Acme Corp" CLAUDE_PROJECT_DIR="$TMP/proj" bash "$HOOK" 2>&1 >/dev/null)
if grep -q 'Acme Corp content must NEVER' <<<"$msg_org"; then ok "block message names the configured protected organisation"
else bad "configured protected organisation missing from the block message"; fi
if grep -qi 'employer or client content must NEVER' <<<"$msg"; then ok "unconfigured: generic corporate prohibition"
else bad "unconfigured message lacks the corporate prohibition"; fi

# 9b. The self-hosted alternatives are configured per installation.
msg_alt=$(printf '%s' '{"tool_name":"Artifact","tool_input":{"file_path":"/tmp/x.html"}}' \
      | CLOUD_PUBLISH_ALTERNATIVES="  - myhost : ssh myhost" CLAUDE_PROJECT_DIR="$TMP/proj" bash "$HOOK" 2>&1 >/dev/null)
if grep -q 'myhost : ssh myhost' <<<"$msg_alt"; then ok "configured hosting alternatives are listed"
else bad "configured hosting alternatives missing"; fi

# 10. The guard's consent path and the SessionEnd cleaner must name the SAME
#     file. If they drift apart the marker is never expired, consent silently
#     becomes permanent, and the guard looks armed while being disabled.
SYNC="$REPO/global/hooks/config-auto-sync.sh"
gpath=$(grep -oE '\.claude/\.artifact-consent' "$HOOK" | head -1)
cpath=$(grep -oE '\.claude/\.artifact-consent' "$SYNC" | head -1)
if [ -n "$gpath" ] && [ "$gpath" = "$cpath" ]; then
  ok "guard and SessionEnd cleaner agree on the consent path"
else
  bad "consent path mismatch (guard='$gpath' cleaner='$cpath') — consent would never expire"
fi

# 11. Behavioural: the cleaner actually removes a marker for the session's project.
CT="$(mktemp -d)"; mkdir -p "$CT/.claude"; touch "$CT/.claude/.artifact-consent"
awk '/^# --- Phase -3:/,/^# --- Phase -2:/' "$SYNC" \
  | grep -E '^rm -f "\$ORIGINAL_DIR' \
  | ORIGINAL_DIR="$CT" bash -s 2>/dev/null
if [ ! -f "$CT/.claude/.artifact-consent" ]; then ok "SessionEnd phase removes the consent marker"
else bad "consent marker survived the SessionEnd phase"; fi
rm -rf "$CT"

echo
echo "cloud-publish-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
