#!/usr/bin/env bash
# Tests for global/hooks/credential-read-guard.sh (CFG-960): the PreToolUse guard for the
# FILE tools — Read, Grep, NotebookRead — aimed at a credential store. vault-read-guard.sh
# covers the Bash tool; without this hook the Read tool was the open door (no PreToolUse
# matcher for Read, live permissions.deny = []), and .credentials.json, the live .mcp.json
# copies and ~/.git-credentials were covered by nothing at all.
#
# Every credential file here is a FIXTURE under the sandboxed $HOME. The marker string
# written into them must never appear in the hook's output.
source "$(dirname "$0")/test-helpers.sh"

HOOK="$REPO_ROOT/global/hooks/credential-read-guard.sh"
LIB="$REPO_ROOT/global/hooks/lib-credential-paths.sh"
TEMPLATE="$REPO_ROOT/setup/config/settings.json"

suite_header "credential-read-guard.sh (PreToolUse Read/Grep/NotebookRead credential guard, CFG-960)"

# ── fixtures ────────────────────────────────────────────────────────────────
_fixture() {
    CFG="$HOME/.cc-mirror/mclaude/config"
    REPO="$HOME/cfg-agent-fleet"
    mkdir -p "$CFG" "$HOME/.claude/knowledge" "$HOME/proj/.claude" "$REPO/secrets" \
             "$REPO/setup/config" "$REPO/global/hooks" "$HOME/custom-profile"
    MARK="fixture-$$-not-a-real-credential"
    printf '{"env":{"AFD_TOKEN":"%s"},"hooks":{}}\n' "$MARK" > "$CFG/settings.json"
    printf '{"mcpServers":{"x":{"env":{"T":"%s"}}}}\n' "$MARK" > "$CFG/.mcp.json"
    printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$MARK" > "$CFG/.credentials.json"
    cp "$CFG/settings.json" "$HOME/.claude/settings.json"
    cp "$CFG/.credentials.json" "$HOME/.claude/.credentials.json"
    cp "$CFG/.mcp.json" "$HOME/.mcp.json"
    cp "$CFG/settings.json" "$CFG/settings.json.bak"
    printf 'https://u:%s@github.com\n' "$MARK" > "$HOME/.git-credentials"
    printf 'password=%s\n' "$MARK" > "$HOME/nas-credentials"
    printf 'ciphertext\n' > "$REPO/secrets/vault.json.enc"
    printf '{"hooks":{},"env":{"FLEET_KEY":"policy"}}\n' > "$REPO/setup/config/settings.json"
    printf '#!/usr/bin/env bash\n' > "$REPO/global/hooks/a.sh"
    printf '# knowledge\n' > "$HOME/.claude/knowledge/k.md"
    printf '{}\n' > "$HOME/.claude/settings.local.json"
    printf '{"permissions":{}}\n' > "$HOME/proj/.claude/settings.json"
    printf 'notes\n' > "$HOME/proj/notes.md"
    ln -s "$HOME/.git-credentials" "$HOME/alias.json"
    ln -s "$CFG" "$HOME/cfgdir"
}
_plaintext_vault() { printf '{"k":"%s"}\n' "$MARK" > "$REPO/secrets/vault.json"; }

# _run <tool> <field> <value> [cwd] — sets RC and OUT. An empty value sends no field
# (Grep without a path). CLAUDE_CONFIG_DIR is the fixture's unless CFG_OVERRIDE is set.
_run() {
    local input
    input=$(jq -n --arg t "$1" --arg k "$2" --arg v "$3" --arg cwd "${4:-$HOME/proj}" \
        '{tool_name:$t, cwd:$cwd, tool_input: (if $v == "" then {} else {($k): $v} end)}')
    RC=0; OUT=$(printf '%s' "$input" | CLAUDE_CONFIG_DIR="${CFG_OVERRIDE:-$CFG}" bash "$HOOK" 2>&1) || RC=$?
}
_run_json() {   # <raw hook input json>
    RC=0; OUT=$(printf '%s' "$1" | CLAUDE_CONFIG_DIR="${CFG_OVERRIDE:-$CFG}" bash "$HOOK" 2>&1) || RC=$?
}

# ── Read: the live settings.json in every spelling ──────────────────────────
test_read_live_settings_absolute() {
    _fixture; _run Read file_path "$CFG/settings.json"
    echo "    measured: rc=$RC"
    assert_eq "2" "$RC" "Read of \$CLAUDE_CONFIG_DIR/settings.json must be refused" || return 1
    assert_contains "$OUT" "settings-view.sh" "the refusal must name the masked reader" || return 1
    assert_not_contains "$OUT" "$MARK" "the hook must never echo the file"
}
run_test "Read refuses the live settings.json (absolute path) and names settings-view.sh" test_read_live_settings_absolute

test_read_live_settings_tilde_and_home_var() {
    _fixture
    _run Read file_path '~/.cc-mirror/mclaude/config/settings.json'
    assert_eq "2" "$RC" "a ~ spelling must be refused" || return 1
    _run Read file_path '$HOME/.cc-mirror/mclaude/config/settings.json'
    assert_eq "2" "$RC" "a literal \$HOME spelling must be refused" || return 1
    _run Read file_path '${HOME}/.cc-mirror/mclaude/config/settings.json'
    assert_eq "2" "$RC" "a literal \${HOME} spelling must be refused"
}
run_test "Read refuses ~, \$HOME and \${HOME} spellings of the live settings.json" test_read_live_settings_tilde_and_home_var

test_read_relative_and_dotdot() {
    _fixture
    _run Read file_path '../.cc-mirror/mclaude/config/settings.json' "$HOME/proj"
    assert_eq "2" "$RC" "a cwd-relative path must be resolved and refused" || return 1
    _run Read file_path "$HOME/proj/../.claude/settings.json"
    assert_eq "2" "$RC" "a path with .. must be resolved and refused"
}
run_test "Read refuses relative and .. spellings (resolved against cwd)" test_read_relative_and_dotdot

test_read_home_claude_settings_copy() {
    # The deployed copy carries the same env block (measured: a 64-char AFD_TOKEN on a
    # machine where ~/.claude/settings.json is NOT the live one) — blocked by shape.
    _fixture; _run Read file_path "$HOME/.claude/settings.json"
    assert_eq "2" "$RC" "~/.claude/settings.json must be refused" || return 1
    _run Read file_path "/home/someone/.claude/settings.json"
    assert_eq "2" "$RC" "another user's ~/.claude/settings.json must be refused by shape"
}
run_test "Read refuses ~/.claude/settings.json (deployed copy, same env block)" test_read_home_claude_settings_copy

test_read_settings_copy_with_suffix() {
    _fixture; _run Read file_path "$CFG/settings.json.bak"
    assert_eq "2" "$RC" "settings.json.bak is a copy of the credential store"
}
run_test "Read refuses settings.json.bak (a copy is a copy)" test_read_settings_copy_with_suffix

test_read_custom_config_dir_by_resolution() {
    # A CLAUDE_CONFIG_DIR outside every known shape: only resolution catches it.
    _fixture; printf '{"env":{"T":"%s"}}\n' "$MARK" > "$HOME/custom-profile/settings.json"
    CFG_OVERRIDE="$HOME/custom-profile" _run Read file_path "$HOME/custom-profile/settings.json"
    echo "    measured: rc=$RC"
    assert_eq "2" "$RC" "\$CLAUDE_CONFIG_DIR/settings.json must be refused whatever the dir is called"
}
run_test "Read refuses settings.json under a custom CLAUDE_CONFIG_DIR (resolved, not assumed)" test_read_custom_config_dir_by_resolution

test_read_symlink_alias_to_credential() {
    _fixture; _run Read file_path "$HOME/alias.json"
    echo "    measured: rc=$RC"
    assert_eq "2" "$RC" "a symlink to ~/.git-credentials must be resolved and refused" || return 1
    _run Read file_path "$HOME/cfgdir/settings.json"
    assert_eq "2" "$RC" "a symlinked config dir must be resolved and refused"
}
run_test "Read refuses symlink aliases (file and directory) of credential files" test_read_symlink_alias_to_credential

# ── Read: the files nothing covered before (CFG-960 part 4) ──────────────────
test_read_credentials_json() {
    _fixture
    _run Read file_path "$CFG/.credentials.json"
    assert_eq "2" "$RC" "\$CLAUDE_CONFIG_DIR/.credentials.json must be refused" || return 1
    _run Read file_path "$HOME/.claude/.credentials.json"
    assert_eq "2" "$RC" "~/.claude/.credentials.json (a stale copy is still a token) must be refused" || return 1
    assert_contains "$OUT" "never" "the refusal must tell the reader never to print the value"
}
run_test "Read refuses .credentials.json (CC OAuth store, both copies)" test_read_credentials_json

test_read_live_mcp_json() {
    _fixture
    _run Read file_path "$CFG/.mcp.json"
    assert_eq "2" "$RC" "\$CLAUDE_CONFIG_DIR/.mcp.json must be refused" || return 1
    _run Read file_path '~/.mcp.json'
    assert_eq "2" "$RC" "~/.mcp.json must be refused" || return 1
    assert_contains "$OUT" "vault key" "the refusal must point at naming the vault key"
}
run_test "Read refuses the live .mcp.json copies (server env tokens)" test_read_live_mcp_json

test_read_git_credentials() {
    _fixture; _run Read file_path "$HOME/.git-credentials"
    assert_eq "2" "$RC" "~/.git-credentials must be refused" || return 1
    assert_not_contains "$OUT" "$MARK" "the hook must never echo the file"
}
run_test "Read refuses ~/.git-credentials" test_read_git_credentials

test_read_plaintext_vault_and_prefixed_vault() {
    _fixture; _plaintext_vault
    _run Read file_path "$REPO/secrets/vault.json"
    assert_eq "2" "$RC" "secrets/vault.json must be refused" || return 1
    assert_contains "$OUT" "vault-manage.sh" "the refusal must name vault-manage.sh" || return 1
    _run Read file_path "$REPO/secrets/corp-vault.json"
    assert_eq "2" "$RC" "a <prefix>-vault.json must be refused (generic, like the Bash guard)"
}
run_test "Read refuses secrets/vault.json and <prefix>-vault.json" test_read_plaintext_vault_and_prefixed_vault

test_read_nas_credentials() {
    _fixture
    _run Read file_path "/etc/nas-credentials"
    assert_eq "2" "$RC" "/etc/nas-credentials must be refused" || return 1
    _run Read file_path "$HOME/nas-credentials"
    assert_eq "2" "$RC" "a copy named nas-credentials must be refused"
}
run_test "Read refuses /etc/nas-credentials and a copy by that name" test_read_nas_credentials

test_notebookread_live_settings() {
    _fixture; _run NotebookRead notebook_path "$CFG/settings.json"
    assert_eq "2" "$RC" "NotebookRead of the live settings.json must be refused"
}
run_test "NotebookRead refuses the live settings.json (notebook_path)" test_notebookread_live_settings

# ── Grep ─────────────────────────────────────────────────────────────────────
test_grep_live_settings_file() {
    _fixture; _run Grep path "$CFG/settings.json"
    assert_eq "2" "$RC" "Grep with the live settings.json as path must be refused" || return 1
    assert_contains "$OUT" "settings-view.sh" "and name the masked reader"
}
run_test "Grep refuses the live settings.json as its path" test_grep_live_settings_file

test_grep_config_dir_refused() {
    _fixture; _run Grep path "$CFG"
    echo "    measured: rc=$RC"
    assert_eq "2" "$RC" "Grep over \$CLAUDE_CONFIG_DIR must be refused" || return 1
    assert_contains "$OUT" "settings.json" "the refusal must name the credential file(s) under the dir" || return 1
    assert_contains "$OUT" ".credentials.json" "all of them"
}
run_test "Grep refuses a directory that holds credential files (\$CLAUDE_CONFIG_DIR) and lists them" test_grep_config_dir_refused

test_grep_home_and_dot_claude_refused() {
    _fixture
    _run Grep path "$HOME"
    assert_eq "2" "$RC" "Grep over ~ must be refused (.git-credentials, .mcp.json live there)" || return 1
    _run Grep path "$HOME/.claude"
    assert_eq "2" "$RC" "Grep over ~/.claude must be refused (settings.json, .credentials.json)" || return 1
    _run Grep path "$HOME/cfgdir"
    assert_eq "2" "$RC" "Grep over a symlinked config dir must be refused"
}
run_test "Grep refuses ~, ~/.claude and a symlinked config dir" test_grep_home_and_dot_claude_refused

test_grep_without_path_uses_cwd() {
    _fixture
    _run Grep path "" "$HOME"
    assert_eq "2" "$RC" "Grep with no path searches cwd — cwd=~ must be refused" || return 1
    _run Grep path "" "$HOME/proj"
    assert_eq "0" "$RC" "cwd=a project dir without credential files must pass"
}
run_test "Grep without a path is judged on cwd" test_grep_without_path_uses_cwd

test_grep_glob_or_type_filter_does_not_exempt() {
    _fixture
    _run_json "$(jq -n --arg p "$CFG" '{tool_name:"Grep", tool_input:{pattern:"x", path:$p, glob:"*.md"}}')"
    assert_eq "2" "$RC" "a glob filter must not exempt a Grep over a credential dir" || return 1
    _run_json "$(jq -n --arg p "$CFG" '{tool_name:"Grep", tool_input:{pattern:"x", path:$p, type:"md"}}')"
    assert_eq "2" "$RC" "a type filter must not exempt it either" || return 1
    assert_contains "$OUT" "glob" "the refusal must say why a filter is not accepted"
}
run_test "Grep over a credential dir is refused even with a glob/type filter" test_grep_glob_or_type_filter_does_not_exempt

test_grep_repo_root_with_plaintext_vault() {
    _fixture; _plaintext_vault
    _run Grep path "$REPO"
    echo "    measured: rc=$RC"
    assert_eq "2" "$RC" "Grep over the config repo while secrets/vault.json is plaintext must be refused" || return 1
    assert_contains "$OUT" "encrypt" "and tell the reader to encrypt it"
}
run_test "Grep over the config repo is refused while a plaintext vault.json exists" test_grep_repo_root_with_plaintext_vault

test_grep_repo_root_without_plaintext_vault_allowed() {
    _fixture; _run Grep path "$REPO"
    echo "    measured: rc=$RC"
    assert_eq "0" "$RC" "Grep over the config repo with only vault.json.enc must pass"
}
run_test "Grep over the config repo passes when only the ciphertext vault exists" test_grep_repo_root_without_plaintext_vault_allowed

test_grep_subdirs_allowed() {
    _fixture
    for d in "$REPO/global/hooks" "$HOME/.claude/knowledge" "$REPO/setup/config" "$HOME/proj"; do
        _run Grep path "$d"
        assert_eq "0" "$RC" "Grep over [$d] holds no credential file and must pass" || return 1
    done
}
run_test "Grep over subdirectories without credential files passes" test_grep_subdirs_allowed

# ── allowed reads ────────────────────────────────────────────────────────────
test_read_allowed_files() {
    _fixture
    local f
    for f in "$REPO/setup/config/settings.json" "$REPO/secrets/vault.json.enc" \
             "$HOME/proj/.claude/settings.json" "$HOME/.claude/settings.local.json" \
             "$HOME/.claude/knowledge/k.md" "$HOME/proj/notes.md" "$REPO/global/hooks/a.sh"; do
        _run Read file_path "$f"
        assert_eq "0" "$RC" "Read of [$f] must pass" || return 1
    done
}
run_test "Read passes: repo template settings.json, vault.json.enc, a project's .claude/settings.json, settings.local.json, ordinary files" test_read_allowed_files

test_other_tools_pass_through() {
    _fixture
    _run_json "$(jq -n --arg c "cat $CFG/settings.json" '{tool_name:"Bash", tool_input:{command:$c}}')"
    assert_eq "0" "$RC" "Bash is vault-read-guard's job — this hook passes it" || return 1
    _run_json "$(jq -n --arg p "$HOME/proj/notes.md" '{tool_name:"Write", tool_input:{file_path:$p, content:"\"tool_name\":\"Read\" in the body"}}')"
    assert_eq "0" "$RC" "a Write whose CONTENT spells a Read tool_name is not a Read"
}
run_test "non-file tools pass through (Bash; a Write whose content mentions \"tool_name\":\"Read\")" test_other_tools_pass_through

# ── degradation and hygiene ──────────────────────────────────────────────────
test_missing_lib_degrades_to_false_block() {
    # A copy of the hook with no lib beside it (a broken deploy): a credential-looking
    # name is still refused, an ordinary file still passes, and the message says to redeploy.
    _fixture; local d="$TEST_TMPDIR/alone"; mkdir -p "$d"; cp "$HOOK" "$d/"
    RC=0; OUT=$(jq -n --arg p "$CFG/settings.json" '{tool_name:"Read", tool_input:{file_path:$p}}' \
        | CLAUDE_CONFIG_DIR="$CFG" bash "$d/credential-read-guard.sh" 2>&1) || RC=$?
    echo "    measured: rc=$RC"
    assert_eq "2" "$RC" "without the lib the live settings.json must still be refused" || return 1
    assert_contains "$OUT" "lib-credential-paths.sh" "and the message must name the missing lib" || return 1
    RC=0; OUT=$(jq -n --arg p "$HOME/proj/notes.md" '{tool_name:"Read", tool_input:{file_path:$p}}' \
        | bash "$d/credential-read-guard.sh" 2>&1) || RC=$?
    assert_eq "0" "$RC" "without the lib an ordinary file must still pass"
}
run_test "a hook copy without its lib refuses credential-looking names and passes the rest (false block, never a read)" \
    test_missing_lib_degrades_to_false_block

test_hook_and_lib_carry_no_personal_path() {
    # /home/x/ is the lib's generic normalization spelling, not a user; any other
    # /home/<name>/ or a <dir>/secrets/ prefix in the source is a deployment's path.
    local hits; hits=$(grep -ohE '/home/[a-z]+/|[A-Za-z0-9_.~-]+/secrets/' "$HOOK" "$LIB" 2>/dev/null \
        | grep -vE '^(/home/x/|root/secrets/|setup/secrets/)$' | grep -c . || true)
    echo "    measured: personal path literals in hook+lib = $hits"
    assert_eq "0" "$hits" "the public hook and lib must not spell out a deployment's paths (CFG-869)"
}
run_test "hook and lib source carry no personal path literal (CFG-869)" test_hook_and_lib_carry_no_personal_path

test_registered_in_template_via_safe_run() {
    local matcher
    matcher=$(jq -r '.hooks.PreToolUse[] | select(.hooks[].command | test("safe-run\\.sh credential-read-guard\\.sh")) | .matcher' "$TEMPLATE" 2>/dev/null | head -1)
    echo "    measured: matcher=[$matcher]"
    [ -n "$matcher" ] || { assert_eq "registered" "absent" "credential-read-guard.sh must be registered in the template through safe-run.sh"; return 1; }
    local t
    for t in Read Grep NotebookRead; do
        printf '%s' "$t" | grep -qE "^($matcher)$" || { assert_eq "$t matched" "not matched" "the matcher must cover $t"; return 1; }
    done
    printf '%s' "Bash" | grep -qE "^($matcher)$" && { assert_eq "Bash not matched" "matched" "the matcher must not cover Bash (vault-read-guard's job)"; return 1; }
    return 0
}
run_test "registered in setup/config/settings.json via safe-run.sh with a matcher covering Read, Grep, NotebookRead" \
    test_registered_in_template_via_safe_run

test_hook_sizes_within_cap() {
    local h; h=$(wc -l < "$HOOK" | tr -d ' ')
    local v; v=$(wc -l < "$REPO_ROOT/global/hooks/vault-read-guard.sh" | tr -d ' ')
    echo "    measured: credential-read-guard.sh=${h}L vault-read-guard.sh=${v}L (hook cap: warn 200, split 300)"
    [ "$h" -le 300 ] || { assert_eq "<=300" "$h" "credential-read-guard.sh over the hook cap"; return 1; }
    [ "$v" -le 300 ] || { assert_eq "<=300" "$v" "vault-read-guard.sh still over the hook cap (CFG-960 split)"; return 1; }
    return 0
}
run_test "both guards sit under the 300-line hook cap (CFG-960 split of vault-read-guard.sh)" test_hook_sizes_within_cap

# ── fix round (adversarial review 2026-11-12) ─────────────────────────────────

test_read_hardlink_twin_refused() {
    # A hardlink has no shape and readlink -f returns it unchanged; only device:inode tells.
    _fixture; ln "$CFG/settings.json" "$HOME/hardlink.json"; ln "$HOME/.git-credentials" "$HOME/proj/twin.txt"
    _run Read file_path "$HOME/hardlink.json"
    echo "    measured: rc=$RC"
    assert_eq "2" "$RC" "a hardlink twin of the live settings.json must be refused" || return 1
    assert_contains "$OUT" "settings-view.sh" "and classified as the settings file it is" || return 1
    _run Read file_path "$HOME/proj/twin.txt"
    assert_eq "2" "$RC" "a hardlink twin of ~/.git-credentials must be refused"
}
run_test "Read refuses a hardlink twin of a credential file (device:inode match)" test_read_hardlink_twin_refused

test_read_vault_twin_outside_repo_roots_refused() {
    _fixture; mkdir -p "$HOME/other/secrets"
    printf '{"k":"%s"}\n' "$MARK" > "$HOME/other/secrets/vault.json"; ln "$HOME/other/secrets/vault.json" "$HOME/other/secrets/twin.json"
    _run Read file_path "$HOME/other/secrets/twin.json"
    echo "    measured: rc=$RC"
    assert_eq "2" "$RC" "a hardlink twin of a plaintext vault outside the repo roots must be refused (R2-3)" || return 1
    assert_contains "$OUT" "vault-manage.sh" "classified as the vault"
}
run_test "R2-3: Read refuses a hardlink twin of a plaintext vault outside the repo roots" test_read_vault_twin_outside_repo_roots_refused

test_settings_refusal_says_where_to_edit() {
    # Edit needs a prior Read, so the live file cannot be edited through tools any more:
    # the refusal has to say where settings ARE edited.
    _fixture; _run Read file_path "$CFG/settings.json"
    assert_contains "$OUT" "setup/config/settings.json" "the refusal must name the template as the place to edit" || return 1
    assert_contains "$OUT" "sync.sh deploy" "and the deploy that carries it to the live file"
}
run_test "the settings refusal says where to EDIT (template, then sync.sh deploy)" test_settings_refusal_says_where_to_edit

# A PATH that lacks jq (the corporate notebook has none; the Decks lose it on a SteamOS update), built from
# symlinks to everything else the hook needs, so it works wherever jq is installed.
_path_without() {   # <dir> <binaries to omit…> → prints the dir
    local d="$1"; shift; mkdir -p "$d"
    local b p
    for b in bash readlink stat timeout awk grep sed head basename dirname cat ln python3 jq; do
        case " $* " in *" $b "*) continue ;; esac
        p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$d/$b"
    done
    printf '%s' "$d"
}
_run_nojq() {   # like _run, hook PATH without jq (+ NOJQ_ALSO binaries); RAW overrides the payload
    local P; P=$(_path_without "$TEST_TMPDIR/bin-nojq" jq ${NOJQ_ALSO:-})
    local input="${RAW:-}"
    [ -n "$input" ] || input=$(jq -n --arg t "$1" --arg k "$2" --arg v "$3" --arg cwd "${4:-$HOME/proj}" \
        '{tool_name:$t, cwd:$cwd, tool_input: (if $v == "" then {} else {($k): $v} end)}')
    RC=0; OUT=$(printf '%s' "$input" | PATH="$P" CLAUDE_CONFIG_DIR="$CFG" bash "$HOOK" 2>&1) || RC=$?
}

test_nojq_live_settings_and_git_credentials_refused() {
    _fixture; _run_nojq Read file_path "$CFG/settings.json"
    echo "    measured: rc=$RC, jq on the hook's PATH: $(PATH="$TEST_TMPDIR/bin-nojq" command -v jq || echo none)"
    assert_eq "2" "$RC" "without jq the live settings.json must still be refused" || return 1
    assert_contains "$OUT" "settings-view.sh" || return 1
    _run_nojq Read file_path "$HOME/.git-credentials"
    assert_eq "2" "$RC" "without jq ~/.git-credentials must still be refused"
}
run_test "no jq: Read of the live settings.json and ~/.git-credentials refused" test_nojq_live_settings_and_git_credentials_refused

test_nojq_grep_config_dir_and_cwd_refused() {
    _fixture; _run_nojq Grep path "$CFG"
    assert_eq "2" "$RC" "without jq a Grep over the config dir must be refused" || return 1
    _run_nojq Grep path "" "$HOME"
    assert_eq "2" "$RC" "without jq the cwd field must still be read (Grep with no path, cwd=~)"
}
run_test "no jq: Grep over the config dir and Grep-without-path at cwd=~ refused" test_nojq_grep_config_dir_and_cwd_refused

test_nojq_normal_file_allowed() {
    _fixture; _run_nojq Read file_path "$HOME/proj/notes.md"
    assert_eq "0" "$RC" "without jq an ordinary file must pass" || return 1
    _run_nojq Grep path "$REPO/global/hooks"
    assert_eq "0" "$RC" "without jq a clean directory must pass"
}
run_test "no jq: an ordinary file and a clean directory pass" test_nojq_normal_file_allowed

test_nojq_json_escapes_and_key_order() {
    # python3 decodes what the textual fallback cannot: \u-escaped and \/-escaped spellings,
    # and tool_input serialized before tool_name.
    _fixture
    # The JSON escape for "." is BUILT here: a \u escape spelled in this file is decoded by the
    # tooling that writes the file, so the test would silently use the plain spelling.
    local E; E=$(printf '\\u002e')
    RAW='{"tool_name":"Read","cwd":"'"$HOME"'/proj","tool_input":{"file_path":"'"$HOME"'/'"$E"'cc-mirror/mclaude/config/settings'"$E"'json"}}' _run_nojq
    echo "    measured: \\u002e spelling rc=$RC"
    assert_eq "2" "$RC" "a \\u002e-escaped spelling of the live settings.json must be refused without jq" || return 1
    RAW='{"tool_name":"Read","cwd":"'"$HOME"'/proj","tool_input":{"file_path":"'"$HOME"'\/.cc-mirror\/mclaude\/config\/settings.json"}}' _run_nojq
    assert_eq "2" "$RC" "a \\/-escaped spelling must be refused without jq" || return 1
    RAW='{"tool_input":{"file_path":"'"$CFG"'/settings.json"},"tool_name":"Read","cwd":"'"$HOME"'/proj"}' _run_nojq
    assert_eq "2" "$RC" "tool_input serialized before tool_name must be refused without jq"
}
run_test "no jq: JSON escapes and key order are decoded (python3 path)" test_nojq_json_escapes_and_key_order

test_no_jq_no_python_textual_last_resort() {
    _fixture
    NOJQ_ALSO=python3 _run_nojq Read file_path "$CFG/settings.json"
    echo "    measured: rc=$RC, python3 on the hook's PATH: $(PATH="$TEST_TMPDIR/bin-nojq" command -v python3 || echo none)"
    assert_eq "2" "$RC" "with neither jq nor python3 the plain spelling must still be refused" || return 1
    NOJQ_ALSO=python3 _run_nojq Grep path "" "$HOME"
    assert_eq "2" "$RC" "and the cwd field still read" || return 1
    NOJQ_ALSO=python3 _run_nojq Read file_path "$HOME/proj/notes.md"
    assert_eq "0" "$RC" "and an ordinary file still passes"
}
run_test "no jq, no python3: the textual last resort refuses the plain spelling and passes the rest" \
    test_no_jq_no_python_textual_last_resort

test_grep_dir_whose_only_credential_is_unreadable_passes() {
    # /etc: nas-credentials is root:600, so a Grep there reads nothing from it. Directory case only.
    _fixture; rm "$HOME/.claude/settings.json"; chmod 000 "$HOME/.claude/.credentials.json"
    _run Grep path "$HOME/.claude"
    echo "    measured: rc=$RC"
    assert_eq "0" "$RC" "a directory whose only credential file the user cannot read leaks nothing to Grep" || return 1
    _run Read file_path "$HOME/.claude/.credentials.json"
    assert_eq "2" "$RC" "the Read of the file itself stays refused (shape)"
}
run_test "Grep over a directory whose only credential file is unreadable passes; Read of it stays refused" \
    test_grep_dir_whose_only_credential_is_unreadable_passes

test_hung_resolution_is_bounded() {
    # A readlink (and stat) that hangs on one path (a dead CIFS/9P mount): the hook must answer
    # within the resolver's own timeout, by shape — refuse a matching name, pass a non-matching
    # one — and must not pay a SECOND timeout on stat once readlink has timed out (SF-B).
    _fixture
    # The shadows run under the hook's stripped PATH, so sleep and the real binaries are absolute.
    local P; P=$(_path_without "$TEST_TMPDIR/bin-hang"); rm -f "$P/readlink" "$P/stat"
    printf '#!/usr/bin/env bash\ncase "$*" in *hungmount*) %s 30 ;; esac\nexec %s "$@"\n' "$(command -v sleep)" "$(command -v readlink)" > "$P/readlink"
    printf '#!/usr/bin/env bash\ncase "$*" in *hungmount*) %s 30 ;; esac\nexec %s "$@"\n' "$(command -v sleep)" "$(command -v stat)" > "$P/stat"
    chmod +x "$P/readlink" "$P/stat"
    mkdir -p "$HOME/hungmount/.cc-mirror/v/config"
    printf '{}\n' > "$HOME/hungmount/.cc-mirror/v/config/settings.json"; printf 'n\n' > "$HOME/hungmount/notes.md"
    local t0=$SECONDS e1 e2
    RC=0; OUT=$(printf '{"tool_name":"Read","cwd":"%s/proj","tool_input":{"file_path":"%s/hungmount/.cc-mirror/v/config/settings.json"}}' "$HOME" "$HOME" \
        | PATH="$P" CLAUDE_CONFIG_DIR="$CFG" bash "$HOOK" 2>&1) || RC=$?
    e1=$((SECONDS - t0))
    echo "    measured: shape-matching name under the hung mount: rc=$RC in ${e1}s"
    assert_eq "2" "$RC" "resolution timed out → judged by shape → refused" || return 1
    [ "$e1" -le 7 ] || { assert_eq "<=7s" "${e1}s" "the hook must not stall until the hook timeout"; return 1; }
    t0=$SECONDS
    RC=0; OUT=$(printf '{"tool_name":"Read","cwd":"%s/proj","tool_input":{"file_path":"%s/hungmount/notes.md"}}' "$HOME" "$HOME" \
        | PATH="$P" CLAUDE_CONFIG_DIR="$CFG" bash "$HOOK" 2>&1) || RC=$?
    e2=$((SECONDS - t0))
    echo "    measured: ordinary name under the hung mount: rc=$RC in ${e2}s"
    assert_eq "0" "$RC" "an ordinary name under the hung mount passes" || return 1
    [ "$e2" -le 7 ] || { assert_eq "<=7s" "${e2}s" "one resolver timeout, no second one on stat (SF-B)"; return 1; }
    t0=$SECONDS
    RC=0; OUT=$(printf '{"tool_name":"Grep","cwd":"%s/proj","tool_input":{"pattern":"x","path":"%s/hungmount"}}' "$HOME" "$HOME" \
        | PATH="$P" CLAUDE_CONFIG_DIR="$CFG" bash "$HOOK" 2>&1) || RC=$?
    e2=$((SECONDS - t0))
    echo "    measured: Grep over the hung dir: rc=$RC in ${e2}s"
    assert_eq "0" "$RC" "a Grep over a dir the resolver cannot answer for passes (nothing known lives there)" || return 1
    [ "$e2" -le 7 ] || { assert_eq "<=7s" "${e2}s" "one resolver timeout for the directory case too (SF-B)"; return 1; }
    return 0
}
run_test "a hung resolver is bounded: shape still refuses, an ordinary name passes, both within the resolver timeout" \
    test_hung_resolution_is_bounded

test_sfa_structured_tier_without_a_tool_name_falls_through() {
    # jq present but the payload is not JSON it can parse (LEADING garbage — jq streams, so
    # trailing garbage still yields the first value): the structured tiers yield no tool
    # name, and the textual tier must still see the Read.
    _fixture
    _run_json "garbage-prefix {\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$CFG/settings.json\"}}"
    echo "    measured: rc=$RC"
    assert_eq "2" "$RC" "unparseable JSON must fall through to the textual tier, not pass"
}
run_test "SF-A: a payload the structured tiers cannot parse falls through to the textual tier" \
    test_sfa_structured_tier_without_a_tool_name_falls_through

test_sfa_python_tier_survives_a_lone_surrogate() {
    # No jq; a .-escaped spelling (only a JSON parser decodes it) plus a lone surrogate in
    # the same field. Without surrogatepass the python write fails, the tier yields nothing,
    # and the textual tier cannot decode the \\u002e escape — the read would pass. (The escape is
    # written doubly escaped here because the file is produced through a JSON tool parameter.)
    _fixture
    local E; E=$(printf '\\u002e')   # built at run time, see test_nojq_json_escapes_and_key_order
    RAW='{"tool_name":"Read","cwd":"'"$HOME"'/proj","tool_input":{"file_path":"'"$HOME"'/'"$E"'cc-mirror/mclaude/config/settings'"$E"'json\udc80"}}' _run_nojq
    echo "    measured: rc=$RC"
    assert_eq "2" "$RC" "the python tier must emit the decoded path even with a lone surrogate in it"
}
run_test "SF-A: the python tier writes a decoded path that carries a lone surrogate (surrogatepass)" \
    test_sfa_python_tier_survives_a_lone_surrogate

suite_summary
