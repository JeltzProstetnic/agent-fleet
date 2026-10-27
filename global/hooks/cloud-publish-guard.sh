#!/usr/bin/env bash
# Approved by the owner 2026-08-24 as P0, fleet-wide. Consent hardening CFG-847 (2026-10-27).
# PreToolUse hook (matcher Artifact): block publishing user content to third-party cloud hosting.
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
# Allowed: publishing when the user consented in THIS session (consent file holds the session id).
# Blocked: every other Artifact call. If python3 cannot evaluate the call, it is blocked.
# Exit 2 = block with message. Exit 0 = allow.

INPUT=$(cat)
CONSENT="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/.artifact-consent"

VERDICT=$(printf '%s' "$INPUT" | CONSENT="$CONSENT" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
if d.get("tool_name") != "Artifact" or (d.get("tool_input") or {}).get("action") == "list":
    print("allow"); sys.exit()
# Consent counts only for the session that wrote it: a marker left behind by a crash,
# a changed cwd, or a git sync from another machine carries a different id (CFG-847).
sid = str(d.get("session_id") or "")
try:
    mark = open(os.environ["CONSENT"]).read().strip()
except OSError:
    mark = ""
print("allow" if sid and mark == sid else "block")
' 2>/dev/null)

[ "$VERDICT" = "allow" ] && exit 0

if [ "$VERDICT" != "block" ]; then
  echo "BLOCKED: cloud-publish-guard could not evaluate this call (python3 missing or failed). Fix python3; the guard fails closed." >&2
  exit 2
fi

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
  echo "  echo \"\$CLAUDE_CODE_SESSION_ID\" > \"$CONSENT\""
} >&2
exit 2
