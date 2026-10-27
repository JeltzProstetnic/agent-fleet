#!/usr/bin/env bash
# Test point-of-action-knowledge.sh — PreToolUse knowledge injector (CFG: point-of-action hook).
#
# Verifies the CC >=2.1.170 PreToolUse additionalContext contract (verified in-binary 2026-06-17):
#   - Unmapped tool        → exit 0, EMPTY stdout (silent allow, fast-exit)
#   - Mapped tool 1st use  → exit 0, JSON {hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:...}}
#   - Mapped tool repeat   → exit 0, EMPTY stdout (once-per-session dedup)
#   - New session          → injects again (markers are session-scoped)
#   - tool_name precise    → no false-positive inject when the tool name only appears as Bash command text
#
# Hermetic: POAK_MARKER_DIR points markers at a temp dir.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="${HOOK:-$REPO_ROOT/global/hooks/point-of-action-knowledge.sh}"

PASS=0; FAIL=0; ERRORS=""
assert()        { local d="$1" e="$2" a="$3"; if [[ "$e" == "$a" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  FAIL: $d (expected '$e', got '$a')"; fi; }
assert_empty()  { local d="$1" a="$2";        if [[ -z "$a" ]];      then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  FAIL: $d (expected empty, got '${a:0:100}')"; fi; }
assert_has()    { local d="$1" n="$2" h="$3"; if [[ "$h" == *"$n"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  FAIL: $d (missing '$n' in '${h:0:140}')"; fi; }

if [[ ! -f "$HOOK" ]]; then
    echo "Results: 0 passed, 1 failed"
    echo -e "Failures:\n  FAIL: hook not found at $HOOK"
    exit 1
fi

MARKDIR="$(mktemp -d)"
export POAK_MARKER_DIR="$MARKDIR"
trap 'rm -rf "$MARKDIR"' EXIT

EXIT=0
run() { local out; out=$(printf '%s' "$1" | bash "$HOOK" 2>/dev/null); EXIT=$?; printf '%s' "$out"; }

echo "Testing point-of-action-knowledge.sh ..."

# 1. Unmapped tool: Read → silent allow
OUT=$(run '{"session_id":"s1","tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}')
assert "Read exit 0" "0" "$EXIT"; assert_empty "Read no stdout" "$OUT"

# 2. Unmapped tool: Bash → silent allow
OUT=$(run '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"echo hi"}}')
assert "Bash exit 0" "0" "$EXIT"; assert_empty "Bash no stdout" "$OUT"

# 3. False-positive guard: tool_name is Bash but command text contains a mapped tool name → NO inject
OUT=$(run '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"echo mcp__google-workspace__draft_gmail_message"}}')
assert "Bash-with-mapped-name-in-text exit 0" "0" "$EXIT"
assert_empty "no inject when tool_name=Bash" "$OUT"

# 4. Mapped first use: draft_gmail_message → inject valid PreToolUse additionalContext JSON
OUT=$(run '{"session_id":"sgmail","tool_name":"mcp__google-workspace__draft_gmail_message","tool_input":{}}')
assert "gmail draft exit 0" "0" "$EXIT"
if echo "$OUT" | jq -e . >/dev/null 2>&1; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  FAIL: gmail draft output not valid JSON: ${OUT:0:140}"; fi
assert "hookEventName==PreToolUse" "PreToolUse" "$(echo "$OUT" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)"
CTX="$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
assert_has "ctx: attachments dir rule"   ".workspace-mcp/attachments" "$CTX"
assert_has "ctx: draft dedup"            "DEDUP"                       "$CTX"
assert_has "ctx: standalone-only"        "standalone"                  "$CTX"
assert_has "ctx: points to KB file"      "gmail-management.md"         "$CTX"

# 5. Repeat same session → dedup, silent
OUT=$(run '{"session_id":"sgmail","tool_name":"mcp__google-workspace__draft_gmail_message","tool_input":{}}')
assert "gmail draft 2nd use exit 0" "0" "$EXIT"; assert_empty "gmail draft 2nd use deduped" "$OUT"

# 6. send_gmail_message shares the gmail-compose group → also deduped in same session
OUT=$(run '{"session_id":"sgmail","tool_name":"mcp__google-workspace__send_gmail_message","tool_input":{}}')
assert "gmail send same-session exit 0" "0" "$EXIT"; assert_empty "gmail send shares group dedup" "$OUT"

# 7. New session → re-injects
OUT=$(run '{"session_id":"sgmail2","tool_name":"mcp__google-workspace__send_gmail_message","tool_input":{}}')
assert "gmail send new-session exit 0" "0" "$EXIT"
assert_has "new session re-injects" "PreToolUse" "$OUT"

# 8. Missing session_id → still injects once
OUT=$(run '{"tool_name":"mcp__google-workspace__draft_gmail_message","tool_input":{}}')
assert "no session_id exit 0" "0" "$EXIT"
assert_has "no session_id injects" "PreToolUse" "$OUT"

# 10. Mapped first use: Serena find_symbol → inject serena-nav payload
OUT=$(run '{"session_id":"sserena","tool_name":"mcp__serena__find_symbol","tool_input":{}}')
assert "serena find_symbol exit 0" "0" "$EXIT"
if echo "$OUT" | jq -e . >/dev/null 2>&1; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  FAIL: serena find_symbol output not valid JSON: ${OUT:0:140}"; fi
CTX="$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
assert_has "serena ctx: activate_project first"     "activate_project"        "$CTX"
assert_has "serena ctx: include_body guidance"      "include_body"            "$CTX"
assert_has "serena ctx: KB pointer"                 "serena.md"               "$CTX"

# 11. Serena get_symbols_overview shares serena-nav → deduped in same session
OUT=$(run '{"session_id":"sserena","tool_name":"mcp__serena__get_symbols_overview","tool_input":{}}')
assert "serena overview same-session exit 0" "0" "$EXIT"
assert_empty "serena overview shares group dedup" "$OUT"

# 12. Playwright browser_navigate → inject browser-automation payload (different session)
OUT=$(run '{"session_id":"splay","tool_name":"mcp__playwright__browser_navigate","tool_input":{}}')
assert "playwright navigate exit 0" "0" "$EXIT"
if echo "$OUT" | jq -e . >/dev/null 2>&1; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  FAIL: playwright navigate output not valid JSON: ${OUT:0:140}"; fi
CTX="$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
assert_has "playwright ctx: snapshot vs screenshot" "browser_snapshot"        "$CTX"
assert_has "playwright ctx: Chromium drift"         "Chromium"                "$CTX"
assert_has "playwright ctx: KB pointer"             "dev-browser-ops.md"      "$CTX"
assert_has "playwright ctx: vault login via /dev/shm bridge" "/dev/shm"     "$CTX"
assert_has "playwright ctx: never browser_type a password" "never browser_type a password" "$CTX"

# 13. Playwright browser_snapshot shares browser-automation → deduped in same session
OUT=$(run '{"session_id":"splay","tool_name":"mcp__playwright__browser_snapshot","tool_input":{}}')
assert "playwright snapshot same-session exit 0" "0" "$EXIT"
assert_empty "playwright snapshot shares group dedup" "$OUT"

# 14. Group independence: in a fresh session, Serena and Playwright each inject (their groups are independent)
OUT=$(run '{"session_id":"smix","tool_name":"mcp__serena__find_symbol","tool_input":{}}')
assert "mix: serena injects" "0" "$EXIT"; assert_has "mix: serena PreToolUse" "PreToolUse" "$OUT"
OUT=$(run '{"session_id":"smix","tool_name":"mcp__playwright__browser_click","tool_input":{}}')
assert "mix: playwright still injects" "0" "$EXIT"; assert_has "mix: playwright PreToolUse" "PreToolUse" "$OUT"
# Gmail in same session also still injects (third independent group)
OUT=$(run '{"session_id":"smix","tool_name":"mcp__google-workspace__draft_gmail_message","tool_input":{}}')
assert "mix: gmail still injects" "0" "$EXIT"; assert_has "mix: gmail PreToolUse" "PreToolUse" "$OUT"

# 15. activate_project itself is NOT mapped (it IS the action the gotcha asks for — injecting on it is redundant)
OUT=$(run '{"session_id":"snoact","tool_name":"mcp__serena__activate_project","tool_input":{}}')
assert "activate_project exit 0" "0" "$EXIT"
assert_empty "activate_project is not mapped" "$OUT"

# 17. GitHub repo creation: create_repository injects github-repo-ops payload (lrn 2026-06-23)
OUT=$(run '{"session_id":"sgh","tool_name":"mcp__github__create_repository","tool_input":{}}')
assert "github create_repo exit 0" "0" "$EXIT"
if echo "$OUT" | jq -e . >/dev/null 2>&1; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  FAIL: github create_repo output not valid JSON: ${OUT:0:140}"; fi
CTX="$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
assert_has "github ctx: targets user not org" "personal account" "$CTX"
assert_has "github ctx: org endpoint"         "orgs/<ORG>/repos"  "$CTX"
assert_has "github ctx: KB pointer"           "mcp-catalog.md"    "$CTX"

# 18. fork_repository shares github-repo-ops → deduped same session
OUT=$(run '{"session_id":"sgh","tool_name":"mcp__github__fork_repository","tool_input":{}}')
assert "github fork same-session exit 0" "0" "$EXIT"
assert_empty "github fork shares group dedup" "$OUT"

# 16. INTEGRATION GUARD (CFG-440): the registered PreToolUse matcher must actually fire for MCP tools.
#    Claude Code treats a matcher of ONLY [A-Za-z0-9_|] as an EXACT string match (not a regex), so a
#    bare "mcp__" never matches "mcp__google-workspace__draft_gmail_message" and the hook silently never
#    runs. A regex metachar (. * ^ etc.) flips CC into unanchored-regex mode. This guards the dead-matcher
#    regression that shipped 2026-06-17 (the script passed all unit tests but was never invoked live).
SETTINGS="$REPO_ROOT/setup/config/settings.json"
if [[ -f "$SETTINGS" ]] && command -v jq >/dev/null 2>&1; then
    MATCHER=$(jq -r '.hooks.PreToolUse[] | select(any(.hooks[]; .command | test("point-of-action-knowledge.sh"))) | .matcher' "$SETTINGS" 2>/dev/null)
    assert "settings registers POAK matcher" "1" "$([[ -n "$MATCHER" ]] && echo 1 || echo 0)"
    if [[ "$MATCHER" =~ [^A-Za-z0-9_|] ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  FAIL: POAK matcher '$MATCHER' is a bare literal — CC exact-matches it, so it NEVER fires for MCP tools; use regex form e.g. 'mcp__.*'"; fi
    if [[ "mcp__google-workspace__draft_gmail_message" =~ $MATCHER ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  FAIL: POAK matcher '$MATCHER' does not match mcp__google-workspace__draft_gmail_message"; fi
else
    echo "  (skip test 9: jq or settings.json unavailable)"
fi

# 19. web-research group (R2-A, MG-approved 2026-09-17): WebSearch first use injects the
#     false-attribution ban. The failure it exists to prevent: an EduPage GDPR assessment written
#     from search snippets, whose decisive self-contradiction was verbatim in a document nobody
#     had opened. This is a BUILT-IN tool, not an mcp__ one — see the matcher guard below.
OUT=$(run '{"session_id":"swr","tool_name":"WebSearch","tool_input":{"query":"edupage gdpr"}}')
assert "WebSearch exit 0" "0" "$EXIT"
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
assert "WebSearch injects context" "1" "$([[ -n "$CTX" ]] && echo 1 || echo 0)"
assert_has "web ctx: names the ban"       "having fetched that document" "$CTX"
assert_has "web ctx: names the trap"      "reads like evidence"        "$CTX"
assert_has "web ctx: KB pointer"          "web-acquisition-health.md"  "$CTX"

# 20. WebFetch shares web-research → deduped in the same session (one nudge per session, per group)
OUT=$(run '{"session_id":"swr","tool_name":"WebFetch","tool_input":{"url":"https://example.invalid"}}')
assert "WebFetch same-session exit 0" "0" "$EXIT"
assert_empty "WebFetch shares group dedup" "$OUT"

# 21. WebFetch in a FRESH session does inject (proves 20 was dedup, not a dead mapping)
OUT=$(run '{"session_id":"swr2","tool_name":"WebFetch","tool_input":{"url":"https://example.invalid"}}')
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
assert "WebFetch fresh session injects" "1" "$([[ -n "$CTX" ]] && echo 1 || echo 0)"

# 22. INTEGRATION GUARD for the built-ins. The matcher was "mcp__.*" and WebSearch/WebFetch are
#     NOT mcp__ tools, so mapping them in the script alone leaves the hook permanently un-invoked
#     for them — the same dead-matcher class as CFG-440 above, which passed every unit test while
#     never firing live.
if [[ -f "$SETTINGS" ]] && command -v jq >/dev/null 2>&1; then
    for _bt in WebSearch WebFetch; do
        if [[ "$_bt" =~ $MATCHER ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  FAIL: POAK matcher '$MATCHER' does not match built-in '$_bt' — the web-research payload can never fire"; fi
    done
fi

# 23. CFG-700: GitHub repo ops match ANY GitHub MCP server by pattern, so the hook names
#     no particular account or organisation and ships to every fleet as-is.
OUT=$(run '{"session_id":"sgh2","tool_name":"mcp__github-work__create_repository","tool_input":{}}')
assert_has "secondary github server create_repo injects" "personal account" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
OUT=$(run '{"session_id":"sgh3","tool_name":"mcp__github_corp__fork_repository","tool_input":{}}')
assert_has "underscore-named github server fork injects" "personal account" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
OUT=$(run '{"session_id":"sgh4","tool_name":"mcp__notgithub__create_repository","tool_input":{}}')
assert_empty "a non-github server named *github* only by suffix does not inject" "$OUT"
OUT=$(run '{"session_id":"sgh5","tool_name":"mcp__github-work__get_issue","tool_input":{}}')
assert_empty "other tools of a secondary github server stay silent" "$OUT"
_named=$(grep -cE 'mcp__github-[a-z]+__' "$HOOK" || true)
assert "hook names no specific secondary github server" "0" "$_named"

# 23. CONTENT-triggered group (CFG-853): vault work is a Bash/Write action, not an MCP tool, so the
#     trigger is the command/content text. vault-ops gotchas inject once per session.
OUT=$(run '{"session_id":"svault","tool_name":"Bash","tool_input":{"command":"bash ~/cfg-agent-fleet/secrets/vault-manage.sh status"}}')
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
assert_has "vault-manage in Bash injects vault-ops" "vault-ops.md" "$CTX"
assert_has "vault ctx: agent runs the dialog itself" "you run" "$CTX"
assert_has "vault ctx: set reads stdin" "stdin" "$CTX"
OUT=$(run '{"session_id":"svault","tool_name":"Bash","tool_input":{"command":"bash ~/cfg-agent-fleet/secrets/vault-manage.sh deploy"}}')
assert_empty "vault-ops injects once per session" "$OUT"
OUT=$(run '{"session_id":"svault2","tool_name":"Write","tool_input":{"file_path":"/tmp/x.sh","content":"P=$(bash setup/scripts/ask-passphrase.sh)"}}')
assert_has "ask-passphrase in Write content injects vault-ops" "vault-ops.md" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
OUT=$(run '{"session_id":"svault3","tool_name":"Read","tool_input":{"file_path":"/x/vault-manage.sh"}}')
assert_empty "reading the script does not inject" "$OUT"
SETTINGS="$REPO_ROOT/setup/config/settings.json"
MATCHER=$(jq -r '.hooks.PreToolUse[] | select(any(.hooks[]; .command | test("point-of-action-knowledge.sh"))) | .matcher' "$SETTINGS" 2>/dev/null | head -1)
for t in Bash Write; do
  if [[ "$t" =~ ^($MATCHER)$ ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  FAIL: POAK matcher '$MATCHER' does not fire for $t — the vault-ops group is dead"; fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then echo -e "Failures:$ERRORS"; exit 1; fi
echo "All tests passed."
