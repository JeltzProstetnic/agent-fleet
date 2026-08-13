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
STATUSLINE="$REPO_ROOT/setup/config/statusline-command.sh"
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
  [[ "${p// }" =~ ^(lean|fleet|readonly)$ ]] || BADROW="${a// } profile='${p// }'"
done < <(grep -vE '^\s*(#|$)' "$CONF")
chk "every real conf row has an integer ctx and a valid profile" "${BADROW:-none}" "none"
# "max" as a context value is the exact mistake --estimate-only invites.
grep -vE '^\s*(#|$)' "$CONF" | awk -F'|' '{gsub(/ /,"",$3); print $3}' | grep -qx "max" \
  && bad "context must never be the string 'max'" || ok "context must never be the string 'max'"

# --- af shortcut (CFG-507) ---------------------------------------------------
grep -q 'bin/af"' "$INSTALL" && ok "install.sh creates the af shortcut" || bad "install.sh creates the af shortcut"
grep -q "unrelated 'af' already exists" "$INSTALL" && ok "install.sh refuses to clobber an existing af" \
  || bad "install.sh refuses to clobber an existing af"


# --- quant-aware size detection (regression 2026-08-13) ---------------------
# An lms key may carry `@q4_k_m`. Matching the base name alone picks the LARGEST
# co-located quant (the Q8), over-stating VRAM need and refusing loads that fit.
grep -q 'quant="${ALM_KEY##\*@}"' "$DRIVER" && ok "size lookup honours the @quant suffix" \
  || bad "size lookup honours the @quant suffix"
mkdir -p "$TMP/models/pub/repo"
head -c 3000000 /dev/zero > "$TMP/models/pub/repo/thing-Q4_K_M.gguf"
head -c 9000000 /dev/zero > "$TMP/models/pub/repo/thing-Q8_0.gguf"
( ALM_KEY="thing@q4_k_m"; HOME="$TMP"; mkdir -p "$TMP/.lmstudio"; ln -sfn "$TMP/models" "$TMP/.lmstudio/models"
  source "$DRIVER"; sz=$(alm_model_size_mib)
  [ "$sz" = "2" ] && echo PASSQ || echo "FAILQ:$sz" ) > "$TMP/q.out" 2>/dev/null
if grep -q PASSQ "$TMP/q.out"; then ok "picks the Q4 file, not the larger Q8 beside it"
else bad "picks the Q4 file, not the larger Q8 beside it" "$(cat "$TMP/q.out")"; fi


# --- MCP mode selection (CFG-506) -------------------------------------------
# Default MUST be none: 13 servers' tool definitions do not fit a local context.
grep -q 'MCP_MODE="none"' "$AFLEET" && ok "MCP defaults to none" || bad "MCP defaults to none"
grep -q '^\s*-mcp)' "$AFLEET"  && ok "-mcp flag is parsed" || bad "-mcp flag is parsed"
grep -q '^\s*mcp-)' "$AFLEET"  && ok "mcp- flag is parsed" || bad "mcp- flag is parsed"
# Both must be matched BEFORE the -* and * catch-alls, or those swallow them.
MCPL=$(grep -n '^\s*-mcp)' "$AFLEET" | cut -d: -f1)
DASHL=$(grep -n '^\s*-\*)' "$AFLEET" | head -1 | cut -d: -f1)
STARL=$(grep -n '^\s*\*)  if \[\[ -z "$PROJECT_ARG"' "$AFLEET" | head -1 | cut -d: -f1)
if [ -n "$MCPL" ] && [ -n "$DASHL" ] && [ "$MCPL" -lt "$DASHL" ]; then
  ok "-mcp is matched before the -* catch-all"
else bad "-mcp is matched before the -* catch-all" "mcp=$MCPL dash=$DASHL"; fi
MINL=$(grep -n '^\s*mcp-)' "$AFLEET" | cut -d: -f1)
if [ -n "$MINL" ] && [ -n "$STARL" ] && [ "$MINL" -lt "$STARL" ]; then
  ok "mcp- is matched before the positional catch-all"
else bad "mcp- is matched before the positional catch-all" "min=$MINL star=$STARL"; fi
grep -q 'ALM_MCP_MINIMAL' "$AFLEET" && ok "minimal set is configurable" || bad "minimal set is configurable"
grep -q 'mcp-' "$CONF" && ok "conf documents the MCP flags" || bad "conf documents the MCP flags"


# --- read-only profile (CFG-506) -------------------------------------------
# The deny list IS the guarantee. An abliterated 7B has no refusal behaviour, so a
# prompt-level restriction is not a restriction. These assertions protect that.
RO="$REPO_ROOT/setup/config-readonly"
for f in CLAUDE.md settings.json .mcp.json; do
  [[ -f "$RO/$f" ]] && ok "readonly profile has $f" || bad "readonly profile has $f"
done
for tool in Write Edit NotebookEdit Bash Agent; do
  python3 -c "
import json,sys
d=json.load(open('$RO/settings.json'))
sys.exit(0 if '$tool' in d.get('permissions',{}).get('deny',[]) else 1)" 2>/dev/null \
    && ok "readonly DENIES $tool" || bad "readonly DENIES $tool"
done
chk "readonly declares zero MCP servers" \
  "$(python3 -c "import json;print(len(json.load(open('$RO/.mcp.json')).get('mcpServers',{})))")" "0"
# A flag must never be able to widen a safety profile.
grep -q 'readonly" \]\] && MCP_MODE="none"' "$AFLEET" && ok "readonly forces MCP none, ignoring -mcp" \
  || bad "readonly forces MCP none, ignoring -mcp"
grep -q 'readonly) _pdir="config-readonly"' "$AFLEET" && ok "profile maps to its own config dir" \
  || bad "profile maps to its own config dir"
grep -q 'no public messages' "$RO/CLAUDE.md" && ok "readonly prompt forbids outward-facing output" \
  || bad "readonly prompt forbids outward-facing output"


# --- the profile's MCP set must be AUTHORITATIVE (CFG-506) ------------------
# Hit live 2026-08-13: the readonly profile shipped zero servers and got twelve.
# CC walks up from the project dir and picked up ~/.mcp.json, and the project's own
# .claude/settings.local.json carried enableAllProjectMcpServers, auto-approving the
# lot. LM Studio then built a ~4,880-rule GBNF and llama.cpp refused it — every turn
# of that session failed. A profile that merely DECLARES no servers is not enough;
# the shim has to tell CC to ignore every other MCP source.
grep -q -- '--strict-mcp-config' "$AFLEET" \
  && ok "local shim passes --strict-mcp-config" || bad "local shim passes --strict-mcp-config"
grep -q -- '--mcp-config' "$AFLEET" \
  && ok "local shim names its own .mcp.json via --mcp-config" \
  || bad "local shim names its own .mcp.json via --mcp-config"
# --strict-mcp-config without --mcp-config means NO servers ever, which would
# silently break the -mcp / mcp- flags rather than honouring them.
SHIMBLK=$(sed -n '/cat > "\$_shim" <<SHIM$/,/^SHIM$/p' "$AFLEET")
grep -q -- '--mcp-config' <<<"$SHIMBLK" && grep -q -- '--strict-mcp-config' <<<"$SHIMBLK" \
  && ok "both MCP flags are in the generated shim, not merely in the file" \
  || bad "both MCP flags are in the generated shim, not merely in the file" "$SHIMBLK"

# --- the Workflow tool breaks llama.cpp's grammar parser (2026-08-14) -------
# THIS, not MCP, is what killed the reported session. llama.cpp builds a GBNF from
# the tool schemas, and Workflow's `script` field carries maxLength 524288, which
# emits `char{0,524288}` and trips "number of repetitions exceeds sane defaults".
# It is a BUILT-IN tool, so it fires with zero MCP servers and on every model.
# Measured: with Workflow disallowed the same request parses and answers.
grep -q -- '--disallowedTools' "$AFLEET" \
  && ok "local shim disallows the tool that breaks GBNF" \
  || bad "local shim disallows the tool that breaks GBNF"
grep -q -- 'disallowedTools Workflow' "$AFLEET" \
  && ok "the disallowed tool is Workflow specifically" \
  || bad "the disallowed tool is Workflow specifically"

# --- a context pin below the tool-definition floor cannot start a session ----
# Measured 2026-08-14: system prompt + built-in tool schemas + a three-word user
# turn = 37,035 tokens, with zero MCP servers. A model pinned under that gets
# "request exceeds the available context size" on turn one, having already spent
# a minute loading. Refuse up front and say why, like the VRAM preflight does.
grep -q 'ALM_MIN_CTX' "$DRIVER" \
  && ok "driver enforces a minimum usable context" || bad "driver enforces a minimum usable context"
grep -q '37035\|37,035' "$CONF" \
  && ok "conf records the measured floor, not a guess" || bad "conf records the measured floor, not a guess"

# --- context readout (CRI) must exist in local mode -------------------------
# A local window is 16k-256k, not 1M, so knowing what is left matters MORE here
# than on cloud Opus. Both profiles shipped without a statusLine at all.
for P in "$LEAN" "$RO"; do
  N="$(basename "$P")"
  chk "$N declares a statusLine" \
    "$(python3 -c "import json;print('yes' if json.load(open('$P/settings.json')).get('statusLine') else 'no')")" "yes"
done
# The statusline cannot guess a local window: CC reports the alias as the model
# name and no size, and statusline-command.sh then falls back to 1,000,000 — a
# 16k session would render as 2% full when it is nearly gone. The pinned context
# from local-models.conf is known at launch, so the shim must pass it through.
grep -q 'AFLEET_LOCAL_CTX' "$AFLEET" \
  && ok "shim exports the pinned context for the statusline" \
  || bad "shim exports the pinned context for the statusline"
grep -q 'AFLEET_LOCAL_CTX' "$STATUSLINE" \
  && ok "statusline honours the pinned local context" \
  || bad "statusline honours the pinned local context"
grep -q 'AFLEET_LOCAL_CTX' "$DRIVER" \
  && ok "driver exports the resolved context" || bad "driver exports the resolved context"

printf '\n  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
