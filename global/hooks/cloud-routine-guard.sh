#!/usr/bin/env bash
# Approved by the owner 2026-10-26 as P0 (CFG-841 / CFG-842).
# PreToolUse hook (matcher RemoteTrigger|Skill): block creating or changing cloud routines.
#
# Owner's decision 2026-10-26: cloud routines cost tokens, send data to the LLM provider and
# create provider lock-in. Dated work goes on the fleet calendar; a routine is used only where
# no fleet mechanism can do the job, and then the owner chooses routine or workaround.
#
# A prose rule cannot win this. The vendor `schedule` skill description invites "remind me to
# check X tomorrow" at the point of action, every session, and cannot be edited.
#
# CC 2.1.280 RemoteTrigger actions: list, get, create, update, run, create_webhook_trigger,
# list_runs, get_run_log. There is no delete — retirement is update {"enabled": false}.
# Allowed: list / get / list_runs / get_run_log, and an update whose body is exactly
#          {"enabled": false} — inspection and retirement of existing routines.
# Allowed: anything, when the owner chose a routine in THIS session (consent below).
# Blocked: everything else, and the schedule skill (name trimmed, leading "/", plugin prefix,
#          alias "routines" — CC resolves all of these to it).
# If python3 cannot evaluate the call, it is blocked with a message saying so.
# Exit 2 = block with message. Exit 0 = allow.

INPUT=$(cat)
CONSENT="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/.cloud-routine-consent"

VERDICT=$(printf '%s' "$INPUT" | CONSENT="$CONSENT" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
tool, inp = d.get("tool_name"), d.get("tool_input") or {}
if tool == "Skill":
    s = str(inp.get("skill", "")).strip().lstrip("/")
    risky = s.split(":")[-1] in ("schedule", "routines")
elif tool == "RemoteTrigger":
    a = inp.get("action")
    risky = not (a in ("list", "get", "list_runs", "get_run_log")
                 or (a == "update" and inp.get("body") == {"enabled": False}))
else:
    risky = False
if not risky:
    print("allow"); sys.exit()
# Consent counts only for the session that wrote it: a marker left behind by a crash,
# a changed cwd, or a git sync from another machine carries a different id.
sid = str(d.get("session_id") or "")
try:
    mark = open(os.environ["CONSENT"]).read().strip()
except OSError:
    mark = ""
print("allow" if sid and mark == sid else "block")
' 2>/dev/null)

[ "$VERDICT" = "allow" ] && exit 0

if [ "$VERDICT" != "block" ]; then
  echo "BLOCKED: cloud-routine-guard could not evaluate this call (python3 missing or failed). Fix python3; the guard fails closed." >&2
  exit 2
fi

{
  echo "BLOCKED: cloud-routine-guard — no cloud routines where a fleet mechanism can do the job (CFG-841)."
  echo
  echo "Cloud routines cost tokens, send data to the provider and tie the fleet to one provider."
  echo "Instead: put the date on the fleet calendar (knowledge/fleet-calendar.md, title '@<project> …',"
  echo "give a deadline a time) and write a dated docs/pending-*.md in the owning project."
  echo
  echo "If no fleet mechanism can do this, ask the user: cloud routine or workaround."
  echo "Only if they choose the routine, enable it for this session with:"
  echo "  echo \"\$CLAUDE_CODE_SESSION_ID\" > \"$CONSENT\""
  echo
  echo "Retiring routines stays allowed: list, get, list_runs, get_run_log, and update with body {\"enabled\": false}."
} >&2
exit 2
