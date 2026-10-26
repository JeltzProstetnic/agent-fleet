#!/usr/bin/env bash
# Tests for global/hooks/cloud-routine-guard.sh (CFG-842, from CFG-841)
#
# Owner decision 2026-10-26: no cloud routines where a fleet mechanism can do the job — they cost
# tokens, send data to the provider and create provider lock-in; where none can, the owner
# chooses routine or workaround. The vendor `schedule` skill invites "remind me to
# check X tomorrow" at the point of action every session, so only a hard block holds.
#
# Payload shapes are CAPTURED from real session transcripts (2026-10-26):
#   create  → {"action":"create","body":{"job_config":…,"mcp_connections":…,"name":…,"run_once_at":…}}
#   disable → {"action":"update","trigger_id":"trig_…","body":{"enabled":false}}
#   get / list_runs → {"action":"get"|"list_runs","trigger_id":"trig_…"}
# CC 2.1.280 action enum (binary): list, get, create, update, run, create_webhook_trigger,
# list_runs, get_run_log — there is NO delete; retirement is update {"enabled": false}.
#
# Exit 2 = block. Exit 0 = allow.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${ROUTINE_GUARD:-$REPO/global/hooks/cloud-routine-guard.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/proj/.claude"

SID="sess-test-1"
# run <json> — the hook reads session_id from stdin like CC sends it.
run() { # run <json> ; echoes exit code
  printf '%s' "${1%\}},\"session_id\":\"$SID\"}" | CLAUDE_PROJECT_DIR="$TMP/proj" bash "$HOOK" >/dev/null 2>&1
  echo $?
}
expect() { # expect <label> <json> <code>
  local got; got=$(run "$2")
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1 (expected exit $3, got $got)"; fi
}

RT='"tool_name":"RemoteTrigger","tool_input":'
CREATE="{$RT{\"action\":\"create\",\"body\":{\"job_config\":{},\"mcp_connections\":[],\"name\":\"x\",\"run_once_at\":\"2026-11-01T08:00:00Z\"}}}"
DISABLE="{$RT{\"action\":\"update\",\"trigger_id\":\"trig_01XLR4wSgTY73rLkLTv39bWs\",\"body\":{\"enabled\":false}}}"
ENABLE="{$RT{\"action\":\"update\",\"trigger_id\":\"trig_01XLR4wSgTY73rLkLTv39bWs\",\"body\":{\"enabled\":true}}}"
SNEAKY="{$RT{\"action\":\"update\",\"trigger_id\":\"trig_01X\",\"body\":{\"enabled\":false,\"cron_expression\":\"0 8 * * *\"}}}"
RUN="{$RT{\"action\":\"run\",\"trigger_id\":\"trig_01X\"}}"

echo "cloud-routine-guard"
# 1. Retirement and inspection must stay possible (CFG-846 depends on it).
expect "list is allowed"      "{$RT{\"action\":\"list\"}}" 0
expect "get is allowed"       "{$RT{\"action\":\"get\",\"trigger_id\":\"trig_01X\"}}" 0
expect "list_runs is allowed" "{$RT{\"action\":\"list_runs\",\"trigger_id\":\"trig_01X\"}}" 0
expect "get_run_log is allowed" "{$RT{\"action\":\"get_run_log\",\"session_id\":\"cse_1\"}}" 0
expect "disable-only update is allowed" "$DISABLE" 0
# Spaced JSON (python json.dumps style) must parse the same.
expect "disable-only update with spaced JSON is allowed" \
  '{"tool_name": "RemoteTrigger", "tool_input": {"action": "update", "trigger_id": "trig_01X", "body": {"enabled": false}}}' 0

# 2. Creating, re-enabling, changing or running a routine is blocked.
expect "create is blocked"              "$CREATE" 2
expect "re-enabling update is blocked"  "$ENABLE" 2
expect "disable smuggling a cron change is blocked" "$SNEAKY" 2
expect "run is blocked"                 "$RUN" 2
expect "unknown action is blocked"      "{$RT{\"action\":\"frobnicate\"}}" 2
expect "create_webhook_trigger is blocked" "{$RT{\"action\":\"create_webhook_trigger\"}}" 2
expect "nonexistent delete is not advertised as allowed" "{$RT{\"action\":\"delete\",\"trigger_id\":\"trig_01X\"}}" 2
expect "spacing before the colon cannot disable the guard" '{"tool_name" : "RemoteTrigger", "tool_input" : {"action" : "create"}}' 2

# 3. The schedule skill is the vendor's front door to the same thing.
expect "Skill schedule is blocked"  '{"tool_name":"Skill","tool_input":{"skill":"schedule","args":"remind me tomorrow"}}' 2
expect "plugin-qualified schedule skill is blocked" '{"tool_name":"Skill","tool_input":{"skill":"anthropic-skills:schedule"}}' 2
expect "slash-prefixed schedule skill is blocked" '{"tool_name":"Skill","tool_input":{"skill":"/schedule"}}' 2
expect "whitespace-padded schedule skill is blocked" '{"tool_name":"Skill","tool_input":{"skill":" schedule "}}' 2
expect "routines alias is blocked" '{"tool_name":"Skill","tool_input":{"skill":"routines"}}' 2
expect "other skills pass"          '{"tool_name":"Skill","tool_input":{"skill":"lrn"}}' 0
expect "other tools pass"           '{"tool_name":"Bash","tool_input":{"command":"echo RemoteTrigger create"}}' 0

# 4. The owner's explicit choice of a routine unblocks it for this session only.
# Consent is bound to the session that wrote it, so a marker left by a crash, a cd, or a
# git sync from another machine is dead on arrival (review 2026-10-26, MAJOR 2).
echo "$SID" > "$TMP/proj/.claude/.cloud-routine-consent"
expect "create allowed with this session's consent"  "$CREATE" 0
expect "schedule skill allowed with consent" '{"tool_name":"Skill","tool_input":{"skill":"schedule"}}' 0
echo "sess-older" > "$TMP/proj/.claude/.cloud-routine-consent"
expect "another session's consent does not count"    "$CREATE" 2
: > "$TMP/proj/.claude/.cloud-routine-consent"
expect "an empty consent file does not count"        "$CREATE" 2
rm -f "$TMP/proj/.claude/.cloud-routine-consent"
expect "create blocked again after consent removed" "$CREATE" 2

# 5. The block message tells the model what to do instead.
msg=$(printf '%s' "$CREATE" | CLAUDE_PROJECT_DIR="$TMP/proj" bash "$HOOK" 2>&1 >/dev/null)
case "$msg" in *fleet-calendar*) ok "block message names the fleet calendar";; *) bad "block message lacks fleet-calendar: $msg";; esac
case "$msg" in *"cloud routine or workaround"*) ok "block message says to ask the user";; *) bad "block message lacks the ask: $msg";; esac
# The Bash tool has no CLAUDE_PROJECT_DIR, so the unblock command must carry the real path.
case "$msg" in *"$TMP/proj/.claude/.cloud-routine-consent"*) ok "unblock command names the expanded consent path";; *) bad "unblock command path not expanded: $msg";; esac
case "$msg" in *'$CLAUDE_CODE_SESSION_ID'*) ok "unblock command writes the session id";; *) bad "unblock command lacks the session id: $msg";; esac

# python3 unusable → still blocks, but says why instead of blaming a routine.
NOPY="$(mktemp -d)"; for b in bash cat printf; do ln -s "$(command -v $b)" "$NOPY/$b"; done
pmsg=$(printf '%s' '{"tool_name":"Skill","tool_input":{"skill":"lrn"}}' | PATH="$NOPY" CLAUDE_PROJECT_DIR="$TMP/proj" "$NOPY/bash" "$HOOK" 2>&1 >/dev/null); prc=$?
rm -rf "$NOPY"
if [ "$prc" = 2 ]; then ok "python3 missing fails closed"; else bad "python3 missing exit $prc"; fi
case "$pmsg" in *"could not evaluate"*) ok "python3-missing message is distinct";; *) bad "python3-missing message misleading: $pmsg";; esac

# 6. Consent is per-session: guard and SessionEnd cleaner must name the same file,
#    and the cleaner must actually remove it.
SYNC="$REPO/global/hooks/config-auto-sync.sh"
gpath=$(grep -oE '\.claude/\.cloud-routine-consent' "$HOOK" | head -1)
cpath=$(grep -oE '\.claude/\.cloud-routine-consent' "$SYNC" | head -1)
if [ -n "$gpath" ] && [ "$gpath" = "$cpath" ]; then ok "guard and SessionEnd cleaner agree on the consent path"
else bad "consent path mismatch (guard='$gpath' cleaner='$cpath')"; fi
CT="$(mktemp -d)"; mkdir -p "$CT/.claude"; touch "$CT/.claude/.cloud-routine-consent"
awk '/^# --- Phase -3:/,/^# --- Phase -2:/' "$SYNC" | grep -E '^rm -f "\$' \
  | CONFIG_REPO=/nonexistent ORIGINAL_DIR=/nonexistent CLAUDE_PROJECT_DIR="$CT" bash -s 2>/dev/null
if [ ! -f "$CT/.claude/.cloud-routine-consent" ]; then ok "SessionEnd phase removes the routine consent marker"
else bad "routine consent marker survived the SessionEnd phase (cleaner must also honour CLAUDE_PROJECT_DIR)"; fi
rm -rf "$CT"

# 7. Registered in settings through safe-run, on a matcher that reaches both tools.
SET="$REPO/setup/config/settings.json"
line=$(python3 -c "
import json;d=json.load(open('$SET'))
for e in d['hooks']['PreToolUse']:
  for h in e['hooks']:
    if 'cloud-routine-guard.sh' in h['command']: print(e['matcher']+'|'+h['command'])")
case "$line" in
  *RemoteTrigger*Skill*"safe-run.sh cloud-routine-guard.sh"*|*Skill*RemoteTrigger*"safe-run.sh cloud-routine-guard.sh"*) ok "registered via safe-run on RemoteTrigger|Skill ($line)";;
  *) bad "not registered correctly in settings.json (got '$line')";;
esac

echo
echo "cloud-routine-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
