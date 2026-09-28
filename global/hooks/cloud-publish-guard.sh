#!/usr/bin/env bash
# Approved by the owner 2026-08-24 as P0, fleet-wide.
# PreToolUse hook: block publishing user content to third-party cloud hosting.
#
# Incident 2026-08-24: the Artifact tool published a user's unpublished cover art and book
# positioning to claude.ai without consent, while the user owned self-hosted targets that were
# the correct place. For employer or client content the same call is egress to a third-party
# processor — a compliance breach.
#
# Per-installation settings (env, e.g. in settings.json "env"):
#   CLOUD_PUBLISH_ALTERNATIVES   extra lines listing the user's own hosting (one per line)
#   CLOUD_PUBLISH_PROTECTED_ORG  organisation whose content must never be published this way
#
# A prose rule cannot win this. The Artifact tool description states "Publishing proactively is
# fine for your own work-product" at the point of action, every turn, on every machine, and
# cannot be edited. Only a hard block outranks it.
#
# Allowed: action "list" (read-only enumeration, no egress).
# Allowed: publishing when the user has explicitly consented this session (marker file below).
# Blocked: every other Artifact call.
# Exit 2 = block with message. Exit 0 = allow.

INPUT=$(cat)

# Only care about the Artifact tool
case "$INPUT" in
    *'"tool_name":"Artifact"'*|*'"tool_name": "Artifact"'*) ;;
    *) exit 0 ;;
esac

# Extract the action field
ACTION=""
if command -v jq &>/dev/null; then
    ACTION=$(echo "$INPUT" | jq -r '.tool_input.action // empty' 2>/dev/null)
else
    ACTION=$(echo "$INPUT" | grep -oE '"action"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
             | sed 's/.*"action"[^"]*"\([^"]*\)"/\1/')
fi

# Enumerating existing artifacts sends nothing outward.
[ "$ACTION" = "list" ] && exit 0

# Explicit per-session consent. The user creates this deliberately:
#   touch "$CLAUDE_PROJECT_DIR/.claude/.artifact-consent"
# It is git-ignored and cleared by the SessionEnd hook, so consent never persists silently.
CONSENT="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/.artifact-consent"
[ -f "$CONSENT" ] && exit 0

_org="${CLOUD_PUBLISH_PROTECTED_ORG:-}"
if [ -n "$_org" ]; then _prohibit="$_org content must NEVER be published this way under any circumstances."
else _prohibit="Employer or client content must NEVER be published this way under any circumstances."; fi
{
  echo "BLOCKED: cloud-publish-guard — publishing to third-party hosting requires explicit user consent."
  echo
  echo "This would upload user content to claude.ai. Use self-owned hosting instead:"
  echo "  - local     : write the .html, then open it locally"
  [ -n "${CLOUD_PUBLISH_ALTERNATIVES:-}" ] && printf '%s\n' "$CLOUD_PUBLISH_ALTERNATIVES"
  echo
  echo "$_prohibit"
  echo
  echo "If the user has explicitly asked for a cloud artifact, they enable it for this session with:"
  echo '  touch "$CLAUDE_PROJECT_DIR/.claude/.artifact-consent"'
} >&2
exit 2
