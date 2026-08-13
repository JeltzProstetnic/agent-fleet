#!/usr/bin/env bash
# test-afleet-local-model.sh — tests for local-model mode (CFG-506) and the `af` shortcut (CFG-507)
# Pure unit tests: never starts LM Studio, never loads a model, never launches Claude Code.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRIVER="$REPO_ROOT/setup/scripts/afleet-local-model.sh"
AFLEET="$REPO_ROOT/setup/scripts/afleet.sh"
INSTALL="$REPO_ROOT/setup/install.sh"
CONF="$REPO_ROOT/setup/config/local-models.conf"
LEAN="$REPO_ROOT/setup/config-local"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
chk() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '\n== afleet local-model mode ==\n'

# --- static ------------------------------------------------------------------
bash -n "$DRIVER"  2>/dev/null && ok "driver syntax valid"  || bad "driver syntax valid"
bash -n "$AFLEET"  2>/dev/null && ok "afleet.sh syntax valid" || bad "afleet.sh syntax valid"
bash -n "$INSTALL" 2>/dev/null && ok "install.sh syntax valid" || bad "install.sh syntax valid"
[[ -f "$CONF" ]] && ok "local-models.conf exists" || bad "local-models.conf exists"

# --- lean profile ------------------------------------------------------------
for f in CLAUDE.md settings.json .mcp.json; do
  [[ -f "$LEAN/$f" ]] && ok "lean profile has $f" || bad "lean profile has $f"
done
python3 -c "import json;json.load(open('$LEAN/settings.json'))" 2>/dev/null \
  && ok "lean settings.json is valid JSON" || bad "lean settings.json is valid JSON"
python3 -c "import json;json.load(open('$LEAN/.mcp.json'))" 2>/dev/null \
  && ok "lean .mcp.json is valid JSON" || bad "lean .mcp.json is valid JSON"
# The entire point of the lean profile: no MCP servers, no hooks.
chk "lean profile declares ZERO mcp servers" \
  "$(python3 -c "import json;print(len(json.load(open('$LEAN/.mcp.json')).get('mcpServers',{})))")" "0"
chk "lean profile declares NO hooks" \
  "$(python3 -c "import json;print(len(json.load(open('$LEAN/settings.json')).get('hooks',{})))")" "0"
grep -qi "no git commits" "$LEAN/CLAUDE.md" && ok "lean CLAUDE.md forbids commits" \
  || bad "lean CLAUDE.md forbids commits"

# --- alias resolution --------------------------------------------------------
cat > "$TMP/models.conf" <<'EOF'
# comment line must be ignored
alpha | some-model-key   | 4096  | max | 60 | lean
beta  | another/key-v2   | 8192  | 0.5 | 0  | fleet
EOF
CONFIG_REPO="$REPO_ROOT" ALM_CONF="$TMP/models.conf"
# shellcheck disable=SC1090
source "$DRIVER"

alm_resolve alpha && ok "resolves a known alias" || bad "resolves a known alias"
chk "parses model key"      "$ALM_KEY"     "some-model-key"
chk "parses context"        "$ALM_CTX"     "4096"
chk "parses gpu"            "$ALM_GPU"     "max"
chk "parses profile"        "$ALM_PROFILE" "lean"
alm_resolve beta >/dev/null && chk "parses a key containing a slash" "$ALM_KEY" "another/key-v2" \
  || bad "parses a key containing a slash"
alm_resolve nosuch 2>/dev/null && bad "unknown alias must not resolve" || ok "unknown alias must not resolve"
chk "lists aliases for error messages" "$(alm_list_aliases)" "alpha beta"

# A comment line must never be parsed as an alias.
alm_resolve "#" 2>/dev/null && bad "comment line is not an alias" || ok "comment line is not an alias"

# --- no silent cloud fallback (the core safety property) ---------------------
grep -q "no cloud fallback" "$AFLEET" && ok "afleet aborts rather than falling back to cloud" \
  || bad "afleet aborts rather than falling back to cloud"
grep -q "AFLEET_LOCAL_MODEL" "$AFLEET" && ok "afleet exports the local-model marker" \
  || bad "afleet exports the local-model marker"
# mclaude hardcodes CLAUDE_CONFIG_DIR, so local mode must NOT go through it.
grep -q "claude-code/bin/claude" "$AFLEET" && ok "local mode execs the CC entrypoint directly" \
  || bad "local mode execs the CC entrypoint directly"

# --- real conf sanity --------------------------------------------------------
BADROW=""
while IFS='|' read -r a k c g t p; do
  [[ -z "${a// }" ]] && continue
  [[ "${a// }" == \#* ]] && continue
  [[ "${c// }" =~ ^[0-9]+$ ]] || BADROW="${a// } ctx='${c// }'"
  [[ "${p// }" =~ ^(lean|fleet)$ ]] || BADROW="${a// } profile='${p// }'"
done < <(grep -vE '^\s*(#|$)' "$CONF")
chk "every real conf row has an integer ctx and a valid profile" "${BADROW:-none}" "none"
# "max" as a context value is the exact mistake --estimate-only invites.
grep -vE '^\s*(#|$)' "$CONF" | awk -F'|' '{gsub(/ /,"",$3); print $3}' | grep -qx "max" \
  && bad "context must never be the string 'max'" || ok "context must never be the string 'max'"

# --- af shortcut (CFG-507) ---------------------------------------------------
grep -q 'bin/af"' "$INSTALL" && ok "install.sh creates the af shortcut" || bad "install.sh creates the af shortcut"
grep -q "unrelated 'af' already exists" "$INSTALL" && ok "install.sh refuses to clobber an existing af" \
  || bad "install.sh refuses to clobber an existing af"

printf '\n  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
