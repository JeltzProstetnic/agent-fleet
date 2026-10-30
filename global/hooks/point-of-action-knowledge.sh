#!/usr/bin/env bash
# point-of-action-knowledge.sh — PreToolUse hook (requires CC >= 2.1.170).
#
# Delivers point-of-action knowledge: the FIRST time a mapped tool is used in a
# session, it injects the matching knowledge-file gotchas straight into context via
# hookSpecificOutput.additionalContext — instead of relying on the model having
# loaded a conditional knowledge file mid-session. Subsequent uses pass silently.
#
# DATA-DRIVEN: to map a new tool, add one line to POAK_TOOL_GROUP (tool_name → group)
# and, for a new group, one entry to POAK_PAYLOAD (group → injected text). No
# settings.json edit needed — this hook is registered match-all and self-filters.
# Only tool/MCP-triggered knowledge belongs here; semantic triggers stay in CLAUDE.md.
#
# OUTPUT CONTRACT (verified against the installed claude.exe 2.1.170 Zod schema,
# 2026-06-17 — PreToolUse accepts additionalContext as an optional field):
#   inject : exit 0 + {"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"..."}}
#   pass   : exit 0 + empty stdout
# NB: no permissionDecision is set, so the tool runs normally — this only informs.

INPUT=$(cat)

# ── MAP 1: tool_name → knowledge group ──────────────────────────────
declare -A POAK_TOOL_GROUP=(
  [mcp__google-workspace__draft_gmail_message]=gmail-compose
  [mcp__google-workspace__send_gmail_message]=gmail-compose
  [mcp__claude_ai_Gmail__create_draft]=gmail-compose
  [mcp__claude_ai_Gmail__reply]=gmail-compose
  # Label changes: the top-level intake label is a read-and-trash queue (POAK_INTAKE_LABEL)
  [mcp__google-workspace__modify_gmail_message_labels]=gmail-label
  [mcp__google-workspace__batch_modify_gmail_message_labels]=gmail-label
  [mcp__claude_ai_Gmail__label_message]=gmail-label
  [mcp__claude_ai_Gmail__label_thread]=gmail-label
  [mcp__claude_ai_Gmail__update_message_labels]=gmail-label
  # Serena code-nav (NOT activate_project — that IS the action the gotcha asks for)
  [mcp__serena__find_symbol]=serena-nav
  [mcp__serena__get_symbols_overview]=serena-nav
  [mcp__serena__find_referencing_symbols]=serena-nav
  [mcp__serena__search_for_pattern]=serena-nav
  [mcp__serena__replace_symbol_body]=serena-nav
  [mcp__serena__insert_before_symbol]=serena-nav
  [mcp__serena__insert_after_symbol]=serena-nav
  [mcp__serena__rename_symbol]=serena-nav
  [mcp__serena__list_dir]=serena-nav
  # Playwright browser-automation
  [mcp__playwright__browser_navigate]=browser-automation
  [mcp__playwright__browser_click]=browser-automation
  [mcp__playwright__browser_snapshot]=browser-automation
  [mcp__playwright__browser_take_screenshot]=browser-automation
  [mcp__playwright__browser_fill_form]=browser-automation
  [mcp__playwright__browser_type]=browser-automation
  [mcp__playwright__browser_select_option]=browser-automation
  [mcp__playwright__browser_evaluate]=browser-automation
  [mcp__playwright__browser_press_key]=browser-automation
  # GitHub repo creation — create_repository targets the USER, not an org (mcp-catalog.md).
  # Further GitHub MCP servers (a second account) are matched by GITHUB_REPO_OPS_RE below.
  [mcp__github__create_repository]=github-repo-ops
  [mcp__github__fork_repository]=github-repo-ops
  # Web research — BUILT-IN tools, not mcp__ ones. The settings.json matcher must name them
  # explicitly or this mapping is dead on arrival (see test 22, and CFG-440 for the precedent).
  [WebSearch]=web-research
  [WebFetch]=web-research
)

# ── MAP 2: knowledge group → injected payload (the gotchas) ─────────
_IL="${POAK_INTAKE_LABEL:-intake}"   # the mail-intake label (settings.json env)
declare -A POAK_PAYLOAD=(
  [gmail-compose]=$'Gmail compose — four gotchas from knowledge/gmail-management.md before you call this tool:\n1. ATTACHMENTS: attachments[].path must point inside ~/.workspace-mcp/attachments/ — project and /tmp paths are BLOCKED by workspace-mcp. Stage the file first: mkdir -p ~/.workspace-mcp/attachments && cp <file> ~/.workspace-mcp/attachments/ , then reference that path.\n2. DRAFT DEDUP: before drafting, search in:drafts to:<recipient> (or subject:<topic>) and TRASH any existing draft for the same recipient+subject. Search Sent by the recipient\'s address (in:sent to:<address>), never by name or subject, before drafting or recreating any mail.\n3. STANDALONE ONLY: never pass thread_id / in_reply_to / references — threaded drafts are invisible (Gmail API bug). Create the draft standalone.\n4. AFTER drafting or sending a reply, move its source thread out of INBOX into a '"$_IL"$'/<topic> sublabel, never top-level '"$_IL"$' (that label is the trash-intake queue).'
  [gmail-label]=$'Gmail labels — from knowledge/gmail-management.md: handled mail leaves INBOX into a '"$_IL"$'/<topic> sublabel (create it if missing), never top-level '"$_IL"$' — the top-level label is the intake queue that gets read and trashed.'
  [serena-nav]=$'Serena code-nav — three gotchas from reference/serena.md before you go further:\n1. ACTIVATE FIRST: call mcp__serena__activate_project with the project root BEFORE any other Serena tool — other tools fail or return wrong context if no project is active.\n2. SHAPE BEFORE BODY: prefer include_body=False on find_symbol / get_symbols_overview to read structure first (signatures, members); only fetch include_body=True for the specific symbol you actually need to edit/read. Cuts context cost by ~90%.\n3. IMPACT BEFORE EDIT: run find_referencing_symbols on a symbol before replace_symbol_body / rename_symbol — discover all callers in one pass instead of finding breakage later. For non-code files (markdown, YAML, config) Serena is wasted — use Read instead.'
  [browser-automation]=$'Playwright/browser-automation — four gotchas from knowledge/dev-browser-ops.md before you drive the browser:\n1. SNAPSHOT > SCREENSHOT: browser_snapshot returns a structured accessibility tree (text, cheap to read) — browser_take_screenshot returns an image (expensive, image-only). Use snapshot for inspection and decisions; reserve screenshots for visual evidence the user asked to see.\n2. CHROMIUM DRIFT: if startup fails with "Chromium not found" (or you get a missing-binary error), the Playwright MCP\'s expected Chromium was wiped by a version update. Fix: cd skills/dev-browser && npx playwright install chromium (or `npx -y playwright install chromium` standalone). Do NOT re-run `npm i` speculatively — only on an actual missing-module error.\n3. STATE PERSISTS: cookies/login persist in profiles/browser-data/ across restarts. First standalone session requires manual login — do NOT loop "navigate → login" if a prior session already authed.\n4. LOGIN: a vault-held password is filled by YOU via the /dev/shm bridge in dev-browser-ops.md (browser_run_code reads the file, returns only the length) — never browser_type a password, never hand the field to the user, never snapshot a login page with a filled password field. Read form fields by name and never return an input\'s value from a page that holds a password field — check a filled credential by its length only.'
  [web-research]=$'Web research — three gotchas from knowledge/web-acquisition-health.md before you rely on what comes back:\n1. NEVER assert what an organisation\'s own policy, terms, or compliance document says without having fetched that document — a search summary reads like evidence and is not. A GDPR assessment was written from snippets while the decisive self-contradiction sat verbatim in a document nobody had opened.\n2. TWO FAILED FETCHES IS NOT A DEAD END: escalate curl -sS with a real user-agent (WebFetch and curl disagree — believe curl) -> headless Chromium with --window-size and --virtual-time-budget for client-rendered pages -> a site:-scoped search for the document at another URL. Hand the verification back to the user AFTER that ladder, not before it.\n3. A tool failure is a fact about the TOOL, not about the world — a 403, a non-200 or a connection error does not establish that the document is missing.'
  [vault-ops]=$'Vault work — gotchas from knowledge/vault-ops.md (CFG-853), read that file before going further:\n1. YOU RUN IT: you run ask-passphrase.sh and vault-manage.sh yourself; the masked dialog pops up on the user\'s desktop and they only type into it. Never stage a `! bash` script for the user to run a vault step.\n2. ONE PROMPT PER CYCLE: collect VAULT_PASS once into a variable and pass it to every vault-manage.sh call of that cycle.\n3. WRITES: `vault-manage.sh set <dotted.key>` reads the value from stdin, never argv; never hand-edit vault.json.\n4. NEVER SHOW A VALUE: record a key name, path or fingerprint — not the secret — in chat, files, commits or handovers.'
  [github-repo-ops]=$'GitHub repo creation — gotcha from reference/mcp-catalog.md before you call this tool:\n1. create_repository ALWAYS targets the authenticated USER personal account — it CANNOT create a repo in a GitHub org; calling it for an org silently makes a stray personal repo.\n2. To create an ORG repo use the org API endpoint: curl -X POST -H "Authorization: token $TOKEN" https://api.github.com/orgs/<ORG>/repos with name+private in the body (get $TOKEN from an existing org repo remote or ~/.git-credentials), OR fork_repository with organization=<ORG>.\n3. ALWAYS verify the returned owner/full_name before pushing — never push to a just-created repo without confirming it landed in the intended org.'
)
# ────────────────────────────────────────────────────────────────────

# Fast-exit: cheap substring pre-filter so unmapped tool calls cost ~0 (no jq spawn).
# Driven by MAP 1's keys — stays in sync automatically.
_hit=0
for _t in "${!POAK_TOOL_GROUP[@]}"; do
  case "$INPUT" in *"$_t"*) _hit=1; break ;; esac
done
case "$INPUT" in *mcp__github*__create_repository*|*mcp__github*__fork_repository*) _hit=1 ;; esac
case "$INPUT" in *vault-manage.sh*|*ask-passphrase.sh*) _hit=1 ;; esac
[ "$_hit" -eq 0 ] && exit 0

# Extract tool_name + session_id for a precise match (not just a substring in args).
TOOL_NAME=""; SESSION_ID=""
if command -v jq &>/dev/null; then
  TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
else
  TOOL_NAME=$(printf '%s' "$INPUT" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  SESSION_ID=$(printf '%s' "$INPUT" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
fi

# Any GitHub MCP server (mcp__github, mcp__github-<x>, mcp__github_<x>): repo create/fork.
GITHUB_REPO_OPS_RE='^mcp__github([-_][A-Za-z0-9]+)*__(create|fork)_repository$'
GROUP="${POAK_TOOL_GROUP[$TOOL_NAME]:-}"
[[ -z "$GROUP" && "$TOOL_NAME" =~ $GITHUB_REPO_OPS_RE ]] && GROUP=github-repo-ops
# Content-triggered (CFG-853): vault work happens in Bash commands and written scripts.
if [[ -z "$GROUP" && ( "$TOOL_NAME" == Bash || "$TOOL_NAME" == Write ) ]]; then
  case "$INPUT" in *vault-manage.sh*|*ask-passphrase.sh*) GROUP=vault-ops ;; esac
fi
[ -z "$GROUP" ] && exit 0   # matched a substring in args, but the actual tool isn't mapped

MSG="${POAK_PAYLOAD[$GROUP]:-}"
[ -z "$MSG" ] && exit 0      # group has no payload (misconfig) — fail open, never block

# Once-per-session dedup: marker keyed on session_id + group.
MARKER_DIR="${POAK_MARKER_DIR:-/tmp}"
SID_SAFE=$(printf '%s' "${SESSION_ID:-nosess}" | tr -c 'A-Za-z0-9._-' '_')
MARKER="$MARKER_DIR/.poak-${SID_SAFE}-${GROUP}"
[ -f "$MARKER" ] && exit 0
: > "$MARKER" 2>/dev/null || true   # best-effort; if it fails we just inject again later

# Emit additionalContext (allow + inject). jq guarantees correct JSON escaping.
if command -v jq &>/dev/null; then
  jq -cn --arg ctx "$MSG" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$ctx}}'
else
  _esc=$(printf '%s' "$MSG" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"}{print}')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$_esc"
fi
exit 0
