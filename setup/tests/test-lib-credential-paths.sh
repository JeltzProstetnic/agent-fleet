#!/usr/bin/env bash
# Tests for global/hooks/lib-credential-paths.sh (CFG-960): the one list of credential
# stores shared by vault-read-guard.sh (Bash command TEXT) and credential-read-guard.sh
# (a Read/Grep/NotebookRead PATH). The text regexes are pinned to what vault-read-guard.sh
# matched before the split, so the Bash guard's behaviour is unchanged by construction.
source "$(dirname "$0")/test-helpers.sh"

LIB="$REPO_ROOT/global/hooks/lib-credential-paths.sh"

suite_header "lib-credential-paths.sh (shared credential-path knowledge, CFG-960)"

_load() { source "$LIB"; }

# ── text form (what the Bash guard greps a command for) ──────────────────────
test_text_settings_spellings() {
    _load
    local s
    for s in 'cat ~/.cc-mirror/mclaude/config/settings.json' 'jq .env "$CLAUDE_CONFIG_DIR/settings.json"' \
             'grep T ${CLAUDE_CONFIG_DIR}/settings.json' "open('/home/someone/.claude/settings.json')" \
             'cat $HOME/.claude/settings.json' 'cat ${HOME}/.claude/settings.json' 'cat /root/.claude/settings.json' \
             'cat /Users/me/.claude/settings.json' 'cp ~/.claude/settings.json.bak /tmp/x'; do
        assert_eq "settings" "$(cred_kind_of_string "$s" || echo none)" "[$s] must classify as settings" || return 1
    done
}
run_test "text: every live settings.json spelling classifies as settings" test_text_settings_spellings

test_text_settings_non_live_forms() {
    _load
    local s
    for s in 'cat setup/config/settings.json' 'jq .permissions ~/someproject/.claude/settings.json' \
             'cat ~/.claude/settings.local.json' 'cat setup/tests/test-vault-manage.sh' 'cat secrets/vault.json.enc'; do
        assert_eq "none" "$(cred_kind_of_string "$s" || echo none)" "[$s] is not a credential store" || return 1
    done
}
run_test "text: the repo template, a project's .claude/settings.json, settings.local.json, .enc are not credential stores" \
    test_text_settings_non_live_forms

test_text_vault_mcp_credentials_git_nas() {
    _load
    assert_eq "vault" "$(cred_kind_of_string 'cat secrets/vault.json' || echo none)" || return 1
    assert_eq "vault" "$(cred_kind_of_string 'head secrets/corp-vault.json' || echo none)" || return 1
    assert_eq "mcp" "$(cred_kind_of_string 'cat ~/.mcp.json' || echo none)" || return 1
    assert_eq "mcp" "$(cred_kind_of_string 'jq . $CLAUDE_CONFIG_DIR/.mcp.json' || echo none)" || return 1
    assert_eq "mcp" "$(cred_kind_of_string 'cat ~/.cc-mirror/v/config/.mcp.json' || echo none)" || return 1
    assert_eq "none" "$(cred_kind_of_string 'cat setup/config/mcp.json.template' || echo none)" "the template is not live" || return 1
    assert_eq "credentials" "$(cred_kind_of_string 'cat ~/.claude/.credentials.json' || echo none)" || return 1
    assert_eq "git" "$(cred_kind_of_string 'cat ~/.git-credentials' || echo none)" || return 1
    assert_eq "nas" "$(cred_kind_of_string 'cat /etc/nas-credentials' || echo none)"
}
run_test "text: vault, mcp, credentials, git and nas classes" test_text_vault_mcp_credentials_git_nas

test_text_regex_identical_to_pre_split_bash_guard() {
    # The exact SETTINGS_RE and vault regex vault-read-guard.sh carried before CFG-960.
    _load
    local want='(\.cc-mirror/[^/[:space:]]+/config/settings\.json|CLAUDE_CONFIG_DIR\}?/settings\.json|(~|\$HOME|\$\{HOME\}|/home/[^/[:space:]]+|/root|/Users/[^/[:space:]]+)/\.claude/settings\.json)'
    assert_eq "$want" "$CRED_SETTINGS_RE" "CRED_SETTINGS_RE must be the pre-split SETTINGS_RE verbatim" || return 1
    assert_eq '(^|[[:space:]/])([A-Za-z0-9_]+-)?vault\.json([[:space:]]|$|[^a-zA-Z0-9.])' "$CRED_VAULT_RE" \
        "CRED_VAULT_RE must be the pre-split vault regex verbatim" || return 1
    assert_eq 'CLAUDE_CONFIG_DIR|\.cc-mirror|~/\.claude' "$CRED_LIVE_MARKER_RE" || return 1
    assert_eq 'HOME|Path\.home\(|expanduser\(|homedir\(' "$CRED_HOME_MARKER_RE"
}
run_test "text: the regexes are the Bash guard's pre-split regexes verbatim" test_text_regex_identical_to_pre_split_bash_guard

# ── path form (what the file guard resolves) ─────────────────────────────────
_fx() {
    CFG="$HOME/.cc-mirror/mclaude/config"; mkdir -p "$CFG" "$HOME/.claude" "$HOME/proj" "$HOME/repo/secrets" "$HOME/custom"
    printf '{}\n' > "$CFG/settings.json"; printf '{}\n' > "$CFG/.mcp.json"; printf '{}\n' > "$CFG/.credentials.json"
    printf '{}\n' > "$HOME/.claude/settings.json"; printf '{}\n' > "$HOME/.mcp.json"; printf 'x\n' > "$HOME/.git-credentials"
    printf '{}\n' > "$HOME/repo/secrets/vault.json"; printf 'c\n' > "$HOME/repo/secrets/vault.json.enc"
    printf '{}\n' > "$HOME/custom/settings.json"
    ln -s "$HOME/.git-credentials" "$HOME/alias"; ln -s "$CFG" "$HOME/cfgdir"
}

test_path_expansion_and_resolution() {
    _load; _fx
    assert_eq "$HOME/x/y" "$(cred_expand_path '~/x/y')" "~ expands" || return 1
    assert_eq "$HOME/x" "$(cred_expand_path '$HOME/x')" "\$HOME expands" || return 1
    assert_eq "$HOME/x" "$(cred_expand_path '${HOME}/x')" "\${HOME} expands" || return 1
    assert_eq "$HOME/proj/rel" "$(cred_expand_path 'rel' "$HOME/proj")" "a relative path joins cwd" || return 1
    assert_eq "$(readlink -f "$HOME/.git-credentials")" "$(cred_resolve_path "$HOME/alias")" "a symlink resolves" || return 1
    assert_eq "$(readlink -f "$HOME/.claude")/settings.json" "$(cred_resolve_path "$HOME/proj/../.claude/settings.json")" ".. resolves"
}
run_test "path: ~, \$HOME, \${HOME}, cwd-relative, symlink and .. resolution" test_path_expansion_and_resolution

test_path_kind_by_shape_and_by_resolution() {
    _load; _fx
    assert_eq "settings" "$(CLAUDE_CONFIG_DIR=$CFG cred_kind_of_path "$CFG/settings.json" || echo none)" || return 1
    assert_eq "settings" "$(CLAUDE_CONFIG_DIR=$CFG cred_kind_of_path '~/.claude/settings.json' || echo none)" "shape, under a sandboxed HOME" || return 1
    assert_eq "settings" "$(CLAUDE_CONFIG_DIR=$HOME/custom cred_kind_of_path "$HOME/custom/settings.json" || echo none)" "a custom config dir by resolution" || return 1
    assert_eq "settings" "$(CLAUDE_CONFIG_DIR=$CFG cred_kind_of_path "$HOME/cfgdir/settings.json" || echo none)" "through a dir symlink" || return 1
    assert_eq "git" "$(cred_kind_of_path "$HOME/alias" || echo none)" "through a file symlink" || return 1
    assert_eq "mcp" "$(cred_kind_of_path '~/.mcp.json' || echo none)" || return 1
    assert_eq "credentials" "$(CLAUDE_CONFIG_DIR=$CFG cred_kind_of_path "$CFG/.credentials.json" || echo none)" || return 1
    assert_eq "vault" "$(cred_kind_of_path "$HOME/repo/secrets/vault.json" || echo none)" || return 1
    assert_eq "none" "$(cred_kind_of_path "$HOME/repo/secrets/vault.json.enc" || echo none)" "ciphertext passes" || return 1
    assert_eq "none" "$(CLAUDE_CONFIG_DIR=$CFG cred_kind_of_path "$CFG/projects/p/memory/x.md" || echo none)" "other files under the config dir pass" || return 1
    assert_eq "none" "$(cred_kind_of_path "$HOME/proj/.claude/settings.json" || echo none)" "a project's settings pass"
}
run_test "path: kind by shape (sandboxed HOME) and by resolution (custom config dir, symlinks)" test_path_kind_by_shape_and_by_resolution

test_files_under_directory() {
    _load; _fx
    local hits
    hits=$(CLAUDE_CONFIG_DIR=$CFG cred_files_under "$CFG")
    echo "    measured: under CFG = [$(printf '%s' "$hits" | tr '\n' ' ')]"
    assert_contains "$hits" "$CFG/settings.json" || return 1
    assert_contains "$hits" "$CFG/.mcp.json" || return 1
    assert_contains "$hits" "$CFG/.credentials.json" || return 1
    hits=$(CLAUDE_CONFIG_DIR=$CFG cred_files_under "$HOME")
    assert_contains "$hits" "$HOME/.git-credentials" "~ holds .git-credentials" || return 1
    assert_contains "$hits" "$HOME/.claude/settings.json" "and the deployed settings copy" || return 1
    hits=$(cred_files_under "$HOME/repo")
    assert_contains "$hits" "$HOME/repo/secrets/vault.json" "a plaintext vault under the dir" || return 1
    assert_not_contains "$hits" "vault.json.enc" "never the ciphertext" || return 1
    assert_eq "" "$(cred_files_under "$HOME/proj")" "a clean dir lists nothing" || return 1
    assert_eq "" "$(CLAUDE_CONFIG_DIR=$CFG cred_files_under "$CFG/projects")" "a clean subdir of the config dir lists nothing"
}
run_test "path: credential files under a directory (config dir, ~, a repo with a plaintext vault; clean dirs empty)" \
    test_files_under_directory

test_repo_tool_resolution_and_placeholder() {
    _load
    local sv; sv=$(cred_repo_tool setup/scripts/settings-view.sh)
    echo "    measured: settings-view resolves to [$sv]"
    assert_eq "$REPO_ROOT/setup/scripts/settings-view.sh" "$sv" "from the checkout the lib resolves its own repo" || return 1
    local d="$TEST_TMPDIR/nowhere/hooks"; mkdir -p "$d"; cp "$LIB" "$d/"
    local got; got=$(bash -c "source '$d/lib-credential-paths.sh'; cred_repo_tool setup/scripts/settings-view.sh")
    assert_eq "<config-repo>/setup/scripts/settings-view.sh" "$got" "a copy with no repo around it uses the placeholder"
}
run_test "path: repo tools resolve from the checkout, placeholder when nothing resolves (CFG-869)" test_repo_tool_resolution_and_placeholder

test_refusal_texts_name_the_safe_alternative() {
    _load
    local m
    m=$(cred_refusal settings "$HOME/.claude/settings.json")
    assert_contains "$m" "settings-view.sh" "settings → the masked reader" || return 1
    for k in mcp credentials git vault nas; do
        m=$(cred_refusal "$k" "/some/path")
        assert_contains "$m" "never" "[$k] → never print the value" || return 1
    done
    m=$(cred_refusal dir "$HOME" "$HOME/.git-credentials")
    assert_contains "$m" ".git-credentials" "dir → names the files" || return 1
    assert_contains "$m" "glob" "dir → explains why a filter is not accepted"
}
run_test "refusal texts name the safe alternative for every class" test_refusal_texts_name_the_safe_alternative

# ── fix round (adversarial review 2026-11-12) ─────────────────────────────────

test_hardlink_twin_is_the_file() {
    # The vault must sit where the lib looks for one (a conventional repo root); a plaintext
    # vault in an unknown directory is outside the list, as before this round.
    _load; _fx; mkdir -p "$HOME/cfg-agent-fleet/secrets"; printf '{}\n' > "$HOME/cfg-agent-fleet/secrets/vault.json"
    ln "$CFG/settings.json" "$HOME/twin.json"; ln "$HOME/cfg-agent-fleet/secrets/vault.json" "$HOME/proj/v.txt"
    assert_eq "settings" "$(CLAUDE_CONFIG_DIR=$CFG cred_kind_of_path "$HOME/twin.json" || echo none)" "a hardlink of the live settings is the live settings" || return 1
    assert_eq "vault" "$(cred_kind_of_path "$HOME/proj/v.txt" || echo none)" "a hardlink of a plaintext vault is the vault"
}
run_test "path: a hardlink twin classifies as the file it shares an inode with" test_hardlink_twin_is_the_file

test_office_layout_lists_each_file_once() {
    # The office layout: ~/.cc-mirror/mclaude/config is a symlink to ~/.claude, so every file
    # there has two spellings. The directory refusal must list each file once.
    _load; mkdir -p "$HOME/.claude" "$HOME/.cc-mirror/mclaude"; ln -s "$HOME/.claude" "$HOME/.cc-mirror/mclaude/config"
    printf '{}\n' > "$HOME/.claude/settings.json"; printf '{}\n' > "$HOME/.claude/.credentials.json"
    local hits n total
    hits=$(CLAUDE_CONFIG_DIR="$HOME/.cc-mirror/mclaude/config/" cred_files_under "$HOME/.claude")
    n=$(printf '%s\n' "$hits" | grep -c 'settings\.json$' || true); total=$(printf '%s\n' "$hits" | grep -c . || true)
    echo "    measured: settings.json listed $n time(s); $total line(s) for 2 files"
    assert_eq "1" "$n" "one file, one line" || return 1
    assert_eq "2" "$total" "two files under the dir, two lines"
}
run_test "path: the office layout (config dir symlinked to ~/.claude) lists each file once" test_office_layout_lists_each_file_once

test_unreadable_file_not_listed_under_dir_but_still_a_credential() {
    _load; _fx; chmod 000 "$HOME/.git-credentials"
    local hits; hits=$(cred_files_under "$HOME")
    assert_not_contains "$hits" ".git-credentials" "a file the user cannot read is not listed for a directory" || return 1
    assert_contains "$hits" "$HOME/.mcp.json" "the readable ones still are" || return 1
    assert_eq "git" "$(cred_kind_of_path "$HOME/.git-credentials" || echo none)" "the file itself is still a credential"
}
run_test "path: an unreadable credential file is not listed for a directory, but stays a credential itself" \
    test_unreadable_file_not_listed_under_dir_but_still_a_credential

test_resolver_timeout_falls_back_to_the_input() {
    _load; local P="$TEST_TMPDIR/bin-hang"; mkdir -p "$P" "$HOME/proj"
    printf '#!/usr/bin/env bash\ncase "$*" in *hungmount*) %s 30 ;; esac\nexec %s "$@"\n' "$(command -v sleep)" "$(command -v readlink)" > "$P/readlink"
    chmod +x "$P/readlink"
    local t0=$SECONDS got e
    got=$(PATH="$P:$PATH" cred_resolve_path "$HOME/hungmount/x"); e=$((SECONDS - t0))
    echo "    measured: returned [$got] in ${e}s"
    assert_eq "$HOME/hungmount/x" "$got" "on a timeout the input is returned unresolved" || return 1
    [ "$e" -le 8 ] || { assert_eq "<=8s" "${e}s" "and within the resolver timeout"; return 1; }
    got=$(PATH="$P:$PATH" cred_resolve_path "$HOME/proj/../proj")
    assert_eq "$(readlink -f "$HOME/proj")" "$got" "a path the resolver answers is still resolved"
}
run_test "path: a hung readlink is cut off by the resolver timeout and the input is judged as is" \
    test_resolver_timeout_falls_back_to_the_input

test_settings_refusal_names_the_edit_path() {
    _load
    local m; m=$(cred_refusal settings "/x/settings.json")
    assert_contains "$m" "$(cred_repo_tool setup/config/settings.json)" "names the template to edit" || return 1
    assert_contains "$m" "sync.sh deploy" "and the deploy"
}
run_test "refusal: settings names the template to edit and sync.sh deploy" test_settings_refusal_names_the_edit_path

suite_summary
