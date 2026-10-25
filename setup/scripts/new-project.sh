#!/usr/bin/env bash
# new-project.sh — finish a new fleet project so `af <name>` actually launches (CFG-786/787/789).
#
# Run AFTER the project dir, its CLAUDE.md and its registry.md row exist. It:
#   1. pre-accepts Claude Code's workspace trust for the dir (the dialog defaults to "No, exit",
#      so a habitual Enter drops the user straight back to the shell)
#   2. pre-decides the MCP servers in .claude/settings.local.json from project-mcp-defaults.conf
#      (otherwise the approval dialog opens with every ~/.mcp.json server checked)
#   3. creates .gitignore, or appends its missing lines (tmp/, session lock/role, terminal logs)
#   4. seeds CLAUDE.md's Knowledge Loading table with the type's generic knowledge (CFG-828)
#   5. verifies readiness through afleet's own resolver and prints READY only if it passes
#
# Usage: new-project.sh --name <name> --path <dir> [--type "<type>[ + <type>]"] [--mcp-only]
#   --mcp-only: step 2 alone (afleet uses it for projects set up by hand, CFG-817)
# Env overrides (tests): NP_CLAUDE_JSON NP_MCP_JSON NP_REGISTRY NP_MCP_DEFAULTS NP_TYPE_KNOWLEDGE NP_SKIP_LSD
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"

NAME="" PATH_ARG="" TYPE="default" MCP_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --path) PATH_ARG="${2:-}"; shift 2 ;;
    --type) TYPE="${2:-default}"; shift 2 ;;
    --mcp-only) MCP_ONLY=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ -z "$NAME" || -z "$PATH_ARG" ]]; then
  echo "Usage: new-project.sh --name <name> --path <dir> [--type <type>]" >&2; exit 2
fi
PROJ="$(cd "$PATH_ARG" 2>/dev/null && pwd)" || { echo "FAIL: project dir does not exist: $PATH_ARG" >&2; exit 1; }

if [[ -n "${NP_CLAUDE_JSON:-}" ]]; then CJ="$NP_CLAUDE_JSON"
elif [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then CJ="$CLAUDE_CONFIG_DIR/.claude.json"
else CJ="$HOME/.claude.json"; fi
MCPJ="${NP_MCP_JSON:-$HOME/.mcp.json}"
REG="${NP_REGISTRY:-$REPO/registry.md}"
DEFAULTS="${NP_MCP_DEFAULTS:-$REPO/setup/config/project-mcp-defaults.conf}"
KNOWLEDGE="${NP_TYPE_KNOWLEDGE:-$REPO/setup/config/project-type-knowledge.conf}"
FAILS=0
fail() { echo "  FAIL: $*"; FAILS=$((FAILS+1)); }

# Atomic JSON rewrite: jq into a sibling temp file, then rename. Never touches an unparseable file.
json_update() {
  local file="$1"; shift
  local tmp; tmp="$(mktemp "$(dirname "$file")/.np.XXXXXX")" || return 1
  if jq "$@" "$file" > "$tmp"; then mv "$tmp" "$file"; else rm -f "$tmp"; return 1; fi
}

# ── 1. Workspace trust ──────────────────────────────────────────────────────
trust_project() {
  [[ -f "$CJ" ]] || { mkdir -p "$(dirname "$CJ")"; echo '{}' > "$CJ"; }
  if ! jq -e . "$CJ" >/dev/null 2>&1; then fail "$CJ is not valid JSON — left untouched"; return; fi
  if [[ "$(jq -r --arg p "$PROJ" '.projects[$p].hasTrustDialogAccepted // false' "$CJ")" == "true" ]]; then
    echo "  trust: already accepted"; return
  fi
  json_update "$CJ" --arg p "$PROJ" '.projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true})' \
    && echo "  trust: accepted for $PROJ" || fail "could not write trust to $CJ"
}

# ── 2. MCP servers ──────────────────────────────────────────────────────────
wanted_servers() {
  local t part line found=""
  IFS='+' read -ra parts <<< "$TYPE"
  for part in "${parts[@]}"; do
    t="$(echo "$part" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    line="$(grep -E "^${t}[[:space:]]*\|" "$DEFAULTS" 2>/dev/null | head -1)"
    [[ -n "$line" ]] && found="$found ${line#*|}"
  done
  [[ -z "${found// /}" ]] && { line="$(grep -E '^default[[:space:]]*\|' "$DEFAULTS" | head -1)"; found="${line#*|}"; }
  echo $found | tr ' ' '\n' | sort -u
}

decide_mcp() {
  local s="$PROJ/.claude/settings.local.json"
  mkdir -p "$PROJ/.claude"
  [[ -f "$s" ]] || echo '{}' > "$s"
  if ! jq -e . "$s" >/dev/null 2>&1; then fail "$s is not valid JSON — left untouched"; return; fi
  if jq -e 'has("enabledMcpjsonServers") or has("disabledMcpjsonServers")' "$s" >/dev/null; then
    echo "  mcp: kept the existing server choice in settings.local.json"; return
  fi
  [[ -f "$MCPJ" ]] || { echo "  mcp: no $MCPJ — nothing to decide"; return; }
  local all wanted en dis
  all="$(jq -r '.mcpServers // {} | keys[]' "$MCPJ" | sort -u)"
  wanted="$(wanted_servers)"
  en="$(comm -12 <(echo "$all") <(echo "$wanted") | jq -R . | jq -sc .)"
  dis="$(comm -23 <(echo "$all") <(echo "$wanted") | jq -R . | jq -sc 'map(select(. != ""))')"
  json_update "$s" --argjson e "$en" --argjson d "$dis" '. + {enabledMcpjsonServers: $e, disabledMcpjsonServers: $d}' \
    && echo "  mcp: enabled $(jq -r 'join(", ")' <<< "$en")" || fail "could not write $s"
}

# ── 3. .gitignore — create, or append the missing lines; never remove anything ──
GITIGNORE_LINES=("tmp/" ".claude/.session-lock" ".claude/.session-role.*" "docs/terminal-logs/")
scaffold_gitignore() {
  local gi="$PROJ/.gitignore" line added=0
  [[ -f "$gi" ]] || : > "$gi"
  [[ -s "$gi" && -n "$(tail -c1 "$gi")" ]] && echo >> "$gi"
  for line in "${GITIGNORE_LINES[@]}"; do
    grep -qxF -- "$line" "$gi" || { echo "$line" >> "$gi"; added=$((added+1)); }
  done
  echo "  gitignore: $added line(s) added"
}

# ── 4. Type knowledge — rows for the type's files in CLAUDE.md's Knowledge Loading table ──
seed_knowledge() {
  local md="$PROJ/CLAUDE.md"
  [[ -f "$md" && -f "$KNOWLEDGE" ]] || return 0
  python3 - "$md" "$KNOWLEDGE" "$TYPE" <<'PY' || fail "could not seed knowledge rows into $md"
import sys
md, conf, typ = sys.argv[1:4]
types = [t.strip().lower() for t in typ.split('+') if t.strip()]
rows, seen = [], set()
for line in open(conf):
    if not line.strip() or line.lstrip().startswith('#'): continue
    t, domain, f, when = [x.strip() for x in line.split('|', 3)]
    if t.lower() in types and f not in seen:
        seen.add(f); rows.append((domain, f, when))
text = open(md).read()
new = [f"| {d} | `~/.claude/knowledge/{f}` | {w} |" for d, f, w in rows if f"knowledge/{f}" not in text]
if not new:
    print("  knowledge: nothing to add"); sys.exit(0)
L = text.split('\n')
try:
    i = next(n for n, l in enumerate(L) if l.strip() == '## Knowledge Loading')
    j = i + 1
    while j < len(L) and not L[j].startswith('## '): j += 1
    k = j
    while k > i + 1 and not L[k - 1].strip(): k -= 1
    L[k:k] = new
except StopIteration:
    while L and not L[-1].strip(): L.pop()
    L += ['', '## Knowledge Loading', '', '| Domain | Path | Load when... |', '|--------|------|-------------|'] + new + ['']
open(md, 'w').write('\n'.join(L))
print(f"  knowledge: {len(new)} row(s) added")
PY
}

# ── 5. Readiness — through afleet's own resolver ────────────────────────────
verify() {
  local hit
  hit="$(REGISTRY="$REG" CONFIG_REPO="$REPO" bash -c 'source "$1/setup/scripts/afleet-lib.sh"; parse_registry' _ "$REPO" 2>/dev/null \
         | grep -i "^${NAME}|" | head -1)"
  if [[ -z "$hit" ]]; then fail "'$NAME' not resolvable from the registry ($REG) — af $NAME would exit"
  elif [[ "$(cd "${hit#*|}" 2>/dev/null && pwd)" != "$PROJ" ]]; then fail "registry maps '$NAME' to ${hit#*|}, not $PROJ"; fi
  [[ -f "$PROJ/CLAUDE.md" ]] || fail "no CLAUDE.md in $PROJ"
  [[ "$(jq -r --arg p "$PROJ" '.projects[$p].hasTrustDialogAccepted // false' "$CJ" 2>/dev/null)" == "true" ]] \
    || fail "workspace trust not recorded in $CJ"
}

if [[ "$MCP_ONLY" == "1" ]]; then
  decide_mcp
  [[ $FAILS -gt 0 ]] && exit 1
  exit 0
fi

echo "new-project: $NAME ($PROJ, type: $TYPE)"
trust_project
decide_mcp
scaffold_gitignore
seed_knowledge
verify
if [[ "${NP_SKIP_LSD:-0}" != "1" && -f "$SCRIPT_DIR/lsd-refresh.sh" ]]; then
  bash "$SCRIPT_DIR/lsd-refresh.sh" >/dev/null 2>&1 || echo "  warn: lsd-refresh failed (picker list may be stale)"
fi
if [[ $FAILS -gt 0 ]]; then echo "NOT READY: $FAILS check(s) failed"; exit 1; fi
echo "READY: af $NAME will open $PROJ (trust pre-accepted, MCP servers pre-decided)"
