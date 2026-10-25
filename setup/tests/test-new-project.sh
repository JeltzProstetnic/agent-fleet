#!/usr/bin/env bash
# Test new-project.sh — finishes a new project so `af <name>` actually launches (CFG-786/787/789).
#
# Behaviour under test:
#   - workspace trust pre-accepted in .claude.json (CC's trust dialog defaults to "No, exit")
#   - MCP servers pre-decided in .claude/settings.local.json (no all-checked approval dialog)
#   - readiness verified through the REAL afleet resolver (parse_registry), not a grep
#   - exit 1 + no "READY" when any check fails
#
# Hermetic: every path is a temp file passed via NP_* env vars.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/setup/scripts/new-project.sh"

PASS=0; FAIL=0; ERRORS=""
assert()     { local d="$1" e="$2" a="$3"; if [[ "$e" == "$a" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  FAIL: $d (expected '$e', got '$a')"; fi; }
assert_has() { local d="$1" n="$2" h="$3"; if [[ "$h" == *"$n"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  FAIL: $d (missing '$n' in '${h:0:200}')"; fi; }
assert_not() { local d="$1" n="$2" h="$3"; if [[ "$h" != *"$n"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS="${ERRORS}\n  FAIL: $d (unexpected '$n' in '${h:0:200}')"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
PROJ="$HOME/demo"; mkdir -p "$PROJ/.claude"
printf '<!-- agent-fleet-managed -->\n# demo\n' > "$PROJ/CLAUDE.md"
export NP_CLAUDE_JSON="$T/claude.json"
export NP_MCP_JSON="$T/mcp.json"
export NP_REGISTRY="$T/registry.md"
export NP_SKIP_LSD=1
printf '{"mcpServers":{"serena":{},"github":{},"twitter":{},"context7":{},"playwright":{},"diagram":{},"google-workspace":{}}}\n' > "$NP_MCP_JSON"
printf '{"numStartups":5,"projects":{"/other":{"hasTrustDialogAccepted":true,"allowedTools":["x"]}}}\n' > "$NP_CLAUDE_JSON"
reg_with_demo() {
  cat > "$NP_REGISTRY" <<'EOF'
| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
| demo | P2 | — | `~/demo` | x | wsl | business + writing | new | n |
EOF
}
run() { OUT=$(bash "$SCRIPT" "$@" 2>&1); EXIT=$?; }

if [[ ! -f "$SCRIPT" ]]; then echo "Results: 0 passed, 1 failed"; echo -e "Failures:\n  FAIL: script missing: $SCRIPT"; exit 1; fi

# 1. Not in registry → fails, names the reason, no READY, but still exit 1
printf '| Project | Priority |\n' > "$NP_REGISTRY"
run --name demo --path "$PROJ" --type business
assert "unregistered project exits 1" "1" "$EXIT"
assert_has "unregistered names registry" "registry" "$OUT"
assert_not "unregistered never says READY" "READY: af" "$OUT"
assert_has "unregistered says NOT READY" "NOT READY" "$OUT"

# 2. Registered → READY, exit 0
reg_with_demo
run --name demo --path "$PROJ" --type "business + writing"
assert "registered project exits 0" "0" "$EXIT"
assert_has "prints READY" "READY: af demo" "$OUT"

# 3. Trust pre-accepted; other projects + top-level keys preserved
assert "trust accepted" "true" "$(jq -r --arg p "$PROJ" '.projects[$p].hasTrustDialogAccepted' "$NP_CLAUDE_JSON")"
assert "other project kept" '["x"]' "$(jq -c '.projects["/other"].allowedTools' "$NP_CLAUDE_JSON")"
assert "top-level key kept" "5" "$(jq -r '.numStartups' "$NP_CLAUDE_JSON")"

# 4. MCP pre-decided for business + writing: union of the type map, rest disabled
S="$PROJ/.claude/settings.local.json"
EN="$(jq -c '.enabledMcpjsonServers|sort' "$S")"
DIS="$(jq -c '.disabledMcpjsonServers|sort' "$S")"
assert_has "github enabled" '"github"' "$EN"
assert_has "context7 enabled" '"context7"' "$EN"
assert_not "serena not enabled for business" '"serena"' "$EN"
assert_has "serena disabled" '"serena"' "$DIS"
assert_has "twitter disabled" '"twitter"' "$DIS"
assert "every mcp.json server decided" "7" "$(jq '(.enabledMcpjsonServers+.disabledMcpjsonServers)|unique|length' "$S")"

# 5. Idempotent: second run changes nothing
B1="$(md5sum < "$NP_CLAUDE_JSON")$(md5sum < "$S")"
run --name demo --path "$PROJ" --type "business + writing"
assert "second run exit 0" "0" "$EXIT"
assert "idempotent" "$B1" "$(md5sum < "$NP_CLAUDE_JSON")$(md5sum < "$S")"

# 6. Existing user MCP choice and other settings keys are never overwritten
printf '{"enabledPlugins":{"p@m":true},"enabledMcpjsonServers":["twitter"]}\n' > "$S"
run --name demo --path "$PROJ" --type business
assert "user MCP choice kept" '["twitter"]' "$(jq -c '.enabledMcpjsonServers' "$S")"
assert "enabledPlugins kept" "true" "$(jq -r '.enabledPlugins["p@m"]' "$S")"
assert_has "says it kept the existing choice" "kept" "$OUT"

# 7. code type gets serena
P2="$HOME/codeproj"; mkdir -p "$P2"; printf '<!-- agent-fleet-managed -->\n' > "$P2/CLAUDE.md"
printf '| codeproj | P3 | — | `~/codeproj` | x | wsl | code | new | n |\n' >> "$NP_REGISTRY"
run --name codeproj --path "$P2" --type code
assert "code project exit 0" "0" "$EXIT"
assert_has "code enables serena" '"serena"' "$(jq -c '.enabledMcpjsonServers' "$P2/.claude/settings.local.json")"

# 8. Missing .claude.json is created, not an error
rm -f "$NP_CLAUDE_JSON"
run --name codeproj --path "$P2" --type code
assert "missing claude.json exit 0" "0" "$EXIT"
assert "trust written to fresh file" "true" "$(jq -r --arg p "$P2" '.projects[$p].hasTrustDialogAccepted' "$NP_CLAUDE_JSON")"

# 9. Corrupt .claude.json is NOT clobbered
printf '{broken' > "$NP_CLAUDE_JSON"
run --name codeproj --path "$P2" --type code
assert "corrupt claude.json exits 1" "1" "$EXIT"
assert "corrupt file left untouched" "{broken" "$(cat "$NP_CLAUDE_JSON")"

# 10. Missing args → usage, exit 2
run --name x
assert "missing --path exits 2" "2" "$EXIT"

# 11. .gitignore scaffolded on a new project: created when missing (CFG-817)
P3="$HOME/gi"; mkdir -p "$P3"; printf '<!-- agent-fleet-managed -->\n' > "$P3/CLAUDE.md"
printf '| gi | P3 | — | `~/gi` | x | wsl | code | new | n |\n' >> "$NP_REGISTRY"
printf '{}\n' > "$NP_CLAUDE_JSON"
run --name gi --path "$P3" --type code
assert "gitignore project exit 0" "0" "$EXIT"
GI="$(cat "$P3/.gitignore" 2>/dev/null)"
assert_has "gitignore has tmp/" "tmp/" "$GI"
assert_has "gitignore has session lock" ".claude/.session-lock" "$GI"
assert_has "gitignore has session role" ".claude/.session-role.*" "$GI"
assert_has "gitignore has terminal logs" "docs/terminal-logs/" "$GI"

# 12. Existing .gitignore: missing lines appended, nothing removed, no duplicates
printf 'node_modules/\ntmp/\n' > "$P3/.gitignore"
run --name gi --path "$P3" --type code
GI="$(cat "$P3/.gitignore")"
assert_has "existing line kept" "node_modules/" "$GI"
assert "tmp/ not duplicated" "1" "$(grep -cx 'tmp/' "$P3/.gitignore")"
assert_has "missing line appended" "docs/terminal-logs/" "$GI"
B2="$(md5sum < "$P3/.gitignore")"
run --name gi --path "$P3" --type code
assert "gitignore idempotent" "$B2" "$(md5sum < "$P3/.gitignore")"

# 13. --mcp-only: decides MCP, touches neither trust nor .gitignore, prints no READY
P4="$HOME/mo"; mkdir -p "$P4"
printf '{}\n' > "$NP_CLAUDE_JSON"
run --name mo --path "$P4" --type code --mcp-only
assert "mcp-only exit 0 even unregistered" "0" "$EXIT"
assert_has "mcp-only decides servers" '"serena"' "$(jq -c '.enabledMcpjsonServers' "$P4/.claude/settings.local.json" 2>/dev/null)"
assert "mcp-only leaves trust alone" "null" "$(jq -r --arg p "$P4" '.projects[$p].hasTrustDialogAccepted' "$NP_CLAUDE_JSON")"
assert "mcp-only creates no gitignore" "no" "$([[ -f "$P4/.gitignore" ]] && echo yes || echo no)"
assert_not "mcp-only prints no READY" "READY" "$OUT"

# 14. Type knowledge seeded into CLAUDE.md (CFG-828): a new project starts with its type's knowledge
export NP_TYPE_KNOWLEDGE="$T/type-knowledge.conf"
cat > "$NP_TYPE_KNOWLEDGE" <<'CONF'
# type | domain | file | load when
business | Deliverable authoring | deliverable-authoring.md | Before the first draft of a stakeholder deliverable
business | Vertical slicing | vertical-slicing.md | Cutting a build order or roadmap
writing  | Prose register | prose-register.md | Writing or revising human-facing text
writing  | Deliverable authoring | deliverable-authoring.md | Before the first draft of a stakeholder deliverable
CONF
P5="$HOME/kn"; mkdir -p "$P5"; printf '<!-- agent-fleet-managed -->\n# kn\n\nIntro.\n' > "$P5/CLAUDE.md"
printf '| kn | P3 | — | `~/kn` | x | wsl | business + writing | new | n |\n' >> "$NP_REGISTRY"
printf '{}\n' > "$NP_CLAUDE_JSON"
run --name kn --path "$P5" --type "business + writing"
assert "knowledge project exit 0" "0" "$EXIT"
C="$(cat "$P5/CLAUDE.md")"
assert_has "section added" "## Knowledge Loading" "$C"
assert_has "table header" "| Domain | Path | Load when... |" "$C"
assert_has "business file row" '`~/.claude/knowledge/vertical-slicing.md`' "$C"
assert_has "writing file row" '`~/.claude/knowledge/prose-register.md`' "$C"
assert "shared file listed once" "1" "$(grep -c 'deliverable-authoring.md' "$P5/CLAUDE.md")"
assert_has "intro kept" "Intro." "$C"
B5="$(md5sum < "$P5/CLAUDE.md")"
run --name kn --path "$P5" --type "business + writing"
assert "knowledge seeding idempotent" "$B5" "$(md5sum < "$P5/CLAUDE.md")"

# 15. Existing Knowledge Loading table: only missing rows appended, inside that table
printf '# kn\n\n## Knowledge Loading\n\n| Domain | Path | Load when... |\n|--------|------|-------------|\n| Mine | `~/x/mine.md` | always |\n\n## Other\n\ntext\n' > "$P5/CLAUDE.md"
run --name kn --path "$P5" --type business
C="$(cat "$P5/CLAUDE.md")"
assert "one section only" "1" "$(grep -c '^## Knowledge Loading' "$P5/CLAUDE.md")"
assert_has "own row kept" "mine.md" "$C"
assert "rows land before the next section" "yes" "$(awk '/^## Other/{o=1} /vertical-slicing/{print (o?"no":"yes"); exit}' "$P5/CLAUDE.md")"

# 16. Type with no knowledge rows adds nothing
P6="$HOME/nk"; mkdir -p "$P6"; printf '# nk\n' > "$P6/CLAUDE.md"
printf '| nk | P3 | — | `~/nk` | x | wsl | media | new | n |\n' >> "$NP_REGISTRY"
run --name nk --path "$P6" --type media
assert "no rows → CLAUDE.md unchanged" "# nk" "$(cat "$P6/CLAUDE.md")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then echo -e "Failures:$ERRORS"; exit 1; fi
echo "All tests passed."
