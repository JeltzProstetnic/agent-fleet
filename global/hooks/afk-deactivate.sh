#!/usr/bin/env bash
# UserPromptSubmit hook: deactivate AFK + inject pending Telegram messages
# stdout from this hook IS added to Claude's context.
# CRITICAL: This hook runs on EVERY Enter press. It MUST be fast.
# Any network call MUST have a timeout — a hang here = "Interrupted..." for the user.
#
# CFG-770: AFK stays on through console typing until the user says "afk off"
# (decided 2026-10-18). Task notifications, subagent hand-backs, cross-session messages
# and scheduled fires also fire UserPromptSubmit and never end AFK, whatever they quote
# (hook_prompt_is_synthetic, lib-hook-stdin.sh). Every deactivation is logged to
# ~/.claude/logs/afk.log.
#
# CFG-1021: a typed `care` / `care off` that is the WHOLE message arms or ends session caretaking
# (§1b, lib-care.sh, its own state ~/.afd-care that AFK never changes); a Telegram-only
# `care off` ends it too (lib-afd-msg.sh).
#
# CFG-1036: §0 prints AFK_CHANGED / DND_CHANGED once when another session, Telegram or a shell
# switched a mode since this session's last turn (lib-afd-mode.sh); a switch this hook makes
# itself (§1, §1c, §2) is recorded for this session, not echoed back.
#
# CFG-1035: a typed `dnd` / `dnd on` / `dnd off` that is the WHOLE message switches DND through
# `afd dnd on|off` (§1c), which holds every afd notify until the digest at dnd off; a Telegram
# message that is only one of those does the same (lib-afd-msg.sh).

AFD_CLI="${HOME}/.local/bin/afd"
AFK_LOG="$HOME/.claude/logs/afk.log"

INPUT=""
[[ -t 0 ]] || INPUT=$(timeout 2 cat 2>/dev/null)
# One field of the hook input JSON (bash 3.2 compatible: no NUL-split array read).
_field() {
  printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
v = d.get(sys.argv[1], "") if isinstance(d, dict) else ""
sys.stdout.write(v if isinstance(v, str) else "")' "$1" 2>/dev/null
}
PROMPT=$(_field prompt)
CWD=$(_field cwd)
[[ -n "$CWD" ]] || CWD="$PWD"

source "$(dirname "${BASH_SOURCE[0]}")/lib-afd-msg.sh" 2>/dev/null || true
source "$(dirname "${BASH_SOURCE[0]}")/lib-hook-stdin.sh" 2>/dev/null || true  # hook_prompt_is_synthetic
ME=$(afd_project_of "$CWD" 2>/dev/null || basename "$CWD")
SID=""
[[ "$INPUT" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && SID="${BASH_REMATCH[1]}"

# --- 0. CFG-1036: a mode switch made elsewhere since this session's last turn ---
# Without the lib (a partial deploy) nothing is reported and nothing else changes.
_mode_seen() { declare -F afd_mode_seen >/dev/null && afd_mode_seen "$SID" "$1"; return 0; }   # <afk|dnd>: only the mode this hook switched
if source "$(dirname "${BASH_SOURCE[0]}")/lib-afd-mode.sh" 2>/dev/null && declare -F afd_mode_check >/dev/null; then
  afd_mode_check "$SID"
  [[ -n "$AFD_MODE_LINES" ]] && echo "$AFD_MODE_LINES"
  if declare -F afd_mode_held_note >/dev/null; then   # held DND messages a cut-short dnd off never sent
    afd_mode_held_note "$SID"
    [[ -n "$AFD_MODE_HELD" ]] && echo "$AFD_MODE_HELD"
  fi
fi

# --- 1. Only a typed "afk off" ends AFK ---
# A harness-delivered turn never does, whatever it quotes: hand-backs, notifications,
# cross-session messages, and scheduled fires, known by the payload's `source` or a cron
# the Stop hook recorded. The test is shared with context-budget.sh's detectors (CFG-911).
# A partial deploy keeps a text test: an older lib-hook-stdin.sh its prompt_is_synthetic,
# no lib the pre-CFG-911 inline test; either way a typed "afk off" still ends AFK.
_afk_turn_synthetic() {
  if declare -F hook_prompt_is_synthetic >/dev/null; then
    hook_prompt_is_synthetic "$INPUT"
  elif declare -F prompt_is_synthetic >/dev/null; then
    prompt_is_synthetic "$PROMPT"
  else
    [[ "$PROMPT" =~ ^[[:space:]]*\<(task-notification|cross-session-message|agent-message) ]]
  fi
}
if [[ -f "$HOME/.afd-afk" ]] \
   && printf '%s' "$PROMPT" | grep -qiE '(^|[^[:alnum:]_])afk[[:space:]]+off([^[:alnum:]_]|$)' \
   && ! _afk_turn_synthetic; then
  rm -f "$HOME/.afd-afk"
  date '+%Y-%m-%dT%H:%M:%S%z' > "$HOME/.afd-afk.off" 2>/dev/null   # the switch time, for the others (CFG-1036)
  _mode_seen afk
  mkdir -p "$(dirname "$AFK_LOG")" 2>/dev/null
  echo "$(date +%Y-%m-%dT%H:%M:%S%z) deactivated by=afk-deactivate project=$ME trigger=afk-off" >> "$AFK_LOG" 2>/dev/null
  echo "AFK mode deactivated."
fi

# --- 1b. CFG-1021: a typed `care` / `care off` (the whole message) arms or ends caretaking ---
# lib-care.sh holds the state machine; a harness-delivered turn never arms or disarms (the same
# strict test as §1). On any turn it reminds the caretaker when its watch stopped beating. No
# care file and no care command: pure bash, nothing spawned. A partial deploy without the lib,
# or a bash older than 4.2, skips this step and changes nothing else. (SID was read above.)
if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) )) \
   && source "$(dirname "${BASH_SOURCE[0]}")/lib-care.sh" 2>/dev/null; then
  care_on_prompt "$PROMPT" "$ME" "$SID" _afk_turn_synthetic
fi

# --- 1c. CFG-1035: a typed `dnd` / `dnd off` (the whole message) switches DND ---
# The CLI holds the flag and sends the digest at off (bounded: the digest is one network call per
# persona). A harness-delivered turn never switches (the strict test of §1).
_dnd=""
if [[ "$PROMPT" =~ ^[[:space:]]*[Dd][Nn][Dd]([[:space:]]+([Oo][Nn]|[Oo][Ff][Ff]))?[[:space:]!.]*$ ]]; then
  case "${BASH_REMATCH[2]}" in [Oo][Ff][Ff]) _dnd=off ;; *) _dnd=on ;; esac   # before the test below reuses BASH_REMATCH
fi
if [[ -n "$_dnd" ]] && ! _afk_turn_synthetic; then
  _DND=ON; [[ "$_dnd" == off ]] && _DND=OFF
  if [[ -x "$AFD_CLI" ]]; then
    # 45 s: within Claude Code's prompt-hook limit. A digest cut off by it loses nothing: the CLI
    # recovers the claim at the next `afd dnd off` (review #2).
    _out=$(timeout -k 2 45 "$AFD_CLI" dnd "$_dnd" 2>&1) \
      || _out="${_out:-no output} (the afd CLI did not finish; held messages stay held: run afd dnd $_dnd again)"
    _mode_seen dnd
    echo "DND_$_DND: $_out"
  else
    echo "DND_$_DND: FAILED — the afd CLI is missing, so DND is unchanged."
  fi
fi

# --- 2. Inject this project's Telegram messages (others are queued for theirs) ---
MESSAGES=""
if [[ -x "$AFD_CLI" ]]; then
  if declare -F afd_route_messages >/dev/null; then
    FOREIGN=$(afd_route_messages "$ME")
    # A waiting AskUserQuestion relay owns this project's queue (2026-10-20, #406/#408).
    afd_question_waiting "$ME" || MESSAGES=$(afd_take_messages "$ME")
    for t in $FOREIGN; do
      case "$t" in
        afk:on)  _mode_seen afk; echo "AFK switched ON from Telegram. Confirm it there: afd notify all \"[$ME] AFK is on\" --channel telegram" ;;
        afk:off) _mode_seen afk; echo "AFK switched OFF from Telegram. Confirm it there: afd notify all \"[$ME] AFK is off\" --channel telegram" ;;
        dnd:on)  _mode_seen dnd; echo "DND switched ON from Telegram (CFG-1035) on this machine; the CLI already told the user so, naming the host, so send no confirmation. afd notify now holds every message for one digest at dnd off; only afd notify --critical gets through. Do not ask the user: write each question into your handover with a stable ID and keep working." ;;
        dnd:off) _mode_seen dnd; echo "DND switched OFF from Telegram (CFG-1035); the digest of held messages went out. Messages and questions reach the user again." ;;
        dnd:on:noack) _mode_seen dnd; echo "DND switched ON from Telegram (CFG-1035) on this machine, but the acknowledgement could not be sent: the user does not know it took effect here. Do not message the user now; afd notify holds every message for one digest at dnd off. Do not ask: write each question into your handover with a stable ID and keep working." ;;
        dnd:off:noack) _mode_seen dnd; echo "DND switched OFF from Telegram (CFG-1035); nothing was held, and the acknowledgement could not be sent. Tell the user: afd notify all \"[$ME] DND is off\" --channel telegram" ;;
        dnd:*:failed) echo "DND switch from Telegram FAILED (${t%:failed}): afd dnd did not succeed; run afd dnd status, then tell the user: afd notify all \"[$ME] dnd switch failed - send it again\" --channel telegram" ;;
        care:off) echo "CARE_OFF: caretaking switched OFF from Telegram; AFK is unchanged. The caretaker is told by its watch or on its next turn, and runs §Stop of ~/.claude/knowledge/session-care.md. Confirm it there: afd notify all \"[$ME] care is off\" --channel telegram" ;;
        care:off:owner) echo "CARE_OFF: caretaking switched OFF from Telegram; AFK is unchanged. You were the caretaker: run §Stop of ~/.claude/knowledge/session-care.md now (TaskStop the watch first). Confirm it there: afd notify all \"[$ME] care is off\" --channel telegram" ;;
        care:off:none) echo "CARE_OFF from Telegram: caretaking was not on; nothing changed. Tell it there: afd notify all \"[$ME] care was not on\" --channel telegram" ;;
        care:off:failed) echo "CARE_OFF from Telegram FAILED: the care lock was busy, caretaking is unchanged. Tell it there: afd notify all \"[$ME] care off failed (busy) - send care off again\" --channel telegram" ;;
        reask:*) IFS=: read -r _ _n _m <<< "$t"
                 echo "REASK: the user sent re-ask on Telegram; this hook re-sent $_n open AFK question(s) and a summary of $_m default decision(s) there (CFG-1034). Nothing for you to do." ;;
        *) echo "Telegram message(s) for @$t were queued for that project, not this one. Do not act on them. If a $t session is live (ListAgents), wake it with SendMessage: \"Telegram message(s) are queued for you; your prompt hook delivers them.\"" ;;
      esac
    done
  else
    echo "WARNING: lib-afd-msg.sh missing next to afk-deactivate.sh; Telegram messages are not routed per project."
    MESSAGES=$(timeout -k 2 3 "$AFD_CLI" messages 2>/dev/null)
  fi
  if [[ -n "$MESSAGES" ]]; then
    HAS_UNTAGGED=false
    LAST_PERSONA=""
    COLLECTED=""

    # Persona-agnostic: the channel a message arrived on is read from the message
    # itself, never hardcoded, so this works with whatever personas are configured
    # in foundation/personas.md. The server tags EVERY message with its bot's persona;
    # only one other than AFD_DEFAULT_PERSONA asks the model to switch persona.
    # A line the user redirected here through an ask-back (CFG-779) is addressed to
    # this project: labelled, and exempt from the untagged triage note.
    while IFS= read -r line; do
      msg=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message',''))" 2>/dev/null)
      ts=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('timestamp','')[:16])" 2>/dev/null)
      persona=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('persona','') or '')" 2>/dev/null)
      redirected=$(echo "$line" | python3 -c "import sys,json; print('(redirected here by the user) ' if json.load(sys.stdin).get('redirected') else '')" 2>/dev/null)
      # CFG-1034: a late answer to this session's timed-out AFK question (or to its re-ask).
      [[ -z "$redirected" && "$line" == *late_answer_to* ]] && redirected=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print('(late answer to your AFK question #%s \"%s\", which timed out: revisit the default you took) ' % (d['late_answer_to'], d.get('late_question','')))" 2>/dev/null)
      # CFG-839: a Reply to this project's own message is addressed here too.
      [[ -z "$redirected" ]] && redirected=$(echo "$line" | ME="$ME" python3 -c "import sys,json,os; d=json.load(sys.stdin); print('(reply to #%s) ' % d.get('reply_to') if d.get('reply_to') and d.get('reply_to_project') == os.environ['ME'] else '')" 2>/dev/null)
      if [[ -n "$msg" ]]; then
        [[ "$msg" == @* || -n "$redirected" ]] || HAS_UNTAGGED=true
        if [[ -n "$persona" ]]; then
          COLLECTED="${COLLECTED}[$ts] ($persona channel) $redirected$msg"$'\n'
          [[ "$persona" != "${AFD_DEFAULT_PERSONA:-}" ]] && LAST_PERSONA="$persona"
        else
          COLLECTED="${COLLECTED}[$ts] $redirected$msg"$'\n'
        fi
      fi
    done <<< "$MESSAGES"

    if [[ -n "$COLLECTED" ]]; then
      echo ""
      echo "=== Telegram from ${AFD_USER_LABEL:-the user} ==="
      echo "$COLLECTED"
      if [[ -n "$LAST_PERSONA" ]]; then
        echo "ACTION: These arrived on the '$LAST_PERSONA' persona channel. Reply as that persona, then switch back."
        echo "Send reply: afd notify all \"<your reply>\" --channel telegram --persona $LAST_PERSONA"
      else
        echo "Reply via: afd notify all \"[$ME] your reply\" --channel telegram"
      fi
      if [[ "$HAS_UNTAGGED" == "true" ]]; then
        echo "NOTE: message(s) above are not addressed to a project (no @tag); this session got them first. Decide for each whether it is for $ME. If it is, act on it. If not, relay it verbatim to the right session with SendMessage (ListAgents for live sessions; if none is live, file it with inbox-file.sh), and tell the user on Telegram where it went, tagged [$ME]."
      fi
      echo "==="
    fi
  fi
fi

# --- 3. CFG-776: another project's queue nobody picked up → tell this model to wake it ---
# (SID was read from the payload above §0.)
if declare -F afd_wake_hint >/dev/null; then
  afd_wake_hint "$ME" "$SID"
fi
