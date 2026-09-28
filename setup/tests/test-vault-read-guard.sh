#!/usr/bin/env bash
# Tests for global/hooks/vault-read-guard.sh — PreToolUse hook that blocks
# direct reads of secrets/vault.json{,.enc} bypassing vault-manage.sh.
source "$(dirname "$0")/test-helpers.sh"

HOOK="$REPO_ROOT/global/hooks/vault-read-guard.sh"

suite_header "vault-read-guard.sh (PreToolUse vault read guard)"

# Helper: feed a Bash tool invocation to the hook, capture stderr + exit code
_run_hook() {
    local cmd="$1"
    local input
    input=$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
    local rc=0
    HOOK_STDERR=$(echo "$input" | bash "$HOOK" 2>&1) || rc=$?
    echo "$rc"
}

# ── BLOCKS ──────────────────────────────────────────────────────────────────

test_block_cat_vault_json() {
    local rc; rc=$(_run_hook "cat secrets/vault.json")
    assert_eq "2" "$rc" "cat secrets/vault.json must be blocked (exit 2)"
}
run_test "blocks: cat secrets/vault.json" test_block_cat_vault_json

test_block_python3_vault_json() {
    local rc; rc=$(_run_hook "python3 -c 'import json; print(json.load(open(\"secrets/vault.json\")))'")
    assert_eq "2" "$rc" "python3 reading vault.json must be blocked"
}
run_test "blocks: python3 reading vault.json" test_block_python3_vault_json

test_block_grep_on_vault_json() {
    local rc; rc=$(_run_hook "grep token secrets/vault.json")
    assert_eq "2" "$rc" "grep on vault.json must be blocked"
}
run_test "blocks: grep on vault.json" test_block_grep_on_vault_json

test_block_head_vault_json() {
    local rc; rc=$(_run_hook "head secrets/vault.json")
    assert_eq "2" "$rc" "head on vault.json must be blocked"
}
run_test "blocks: head secrets/vault.json" test_block_head_vault_json

test_block_jq_vault_json() {
    local rc; rc=$(_run_hook "jq . secrets/vault.json")
    assert_eq "2" "$rc" "jq on vault.json must be blocked"
}
run_test "blocks: jq on vault.json" test_block_jq_vault_json

test_block_corp_vault_cat() {
    local rc; rc=$(_run_hook "cat secrets/corp-vault.json")
    assert_eq "2" "$rc" "cat corp-vault.json (a prefixed vault) must be blocked"
}
run_test "blocks: cat secrets/corp-vault.json" test_block_corp_vault_cat

test_block_cp_vault_elsewhere() {
    local rc; rc=$(_run_hook "cp secrets/vault.json /tmp/x")
    assert_eq "2" "$rc" "cp vault.json elsewhere must be blocked (leaks plaintext)"
}
run_test "blocks: cp vault.json to /tmp/" test_block_cp_vault_elsewhere

test_block_cat_with_absolute_path() {
    local rc; rc=$(_run_hook "cat /home/deck/cfg-agent-fleet/secrets/vault.json")
    assert_eq "2" "$rc" "cat with absolute path must be blocked"
}
run_test "blocks: cat with absolute path" test_block_cat_with_absolute_path

# ── ALLOWS ──────────────────────────────────────────────────────────────────

test_allow_vault_manage_decrypt() {
    local rc; rc=$(_run_hook "bash secrets/vault-manage.sh decrypt")
    assert_eq "0" "$rc" "vault-manage.sh decrypt must be allowed"
}
run_test "allows: bash vault-manage.sh decrypt" test_allow_vault_manage_decrypt

test_allow_vault_manage_status() {
    local rc; rc=$(_run_hook "bash secrets/vault-manage.sh status")
    assert_eq "0" "$rc" "vault-manage.sh status must be allowed"
}
run_test "allows: bash vault-manage.sh status" test_allow_vault_manage_status

test_allow_env_vault_pass_vault_manage() {
    local rc; rc=$(_run_hook 'VAULT_PASS=x bash secrets/vault-manage.sh deploy')
    assert_eq "0" "$rc" "VAULT_PASS=x vault-manage.sh deploy must be allowed"
}
run_test "allows: VAULT_PASS=x vault-manage.sh deploy" test_allow_env_vault_pass_vault_manage

test_allow_rm_vault_plaintext() {
    local rc; rc=$(_run_hook "rm secrets/vault.json")
    assert_eq "0" "$rc" "rm secrets/vault.json must be allowed (deletion is safe)"
}
run_test "allows: rm secrets/vault.json" test_allow_rm_vault_plaintext

test_allow_ls_vault() {
    local rc; rc=$(_run_hook "ls -la secrets/vault.json")
    assert_eq "0" "$rc" "ls -la must be allowed (metadata only)"
}
run_test "allows: ls -la secrets/vault.json" test_allow_ls_vault

test_allow_stat_vault() {
    local rc; rc=$(_run_hook "stat secrets/vault.json")
    assert_eq "0" "$rc" "stat must be allowed"
}
run_test "allows: stat secrets/vault.json" test_allow_stat_vault

test_allow_encrypted_blob() {
    # The .enc file is encrypted ciphertext — reading it is harmless (no plaintext exposure)
    local rc; rc=$(_run_hook "cat secrets/vault.json.enc")
    assert_eq "0" "$rc" ".enc blob is harmless — must be allowed"
}
run_test "allows: cat secrets/vault.json.enc (ciphertext)" test_allow_encrypted_blob

test_allow_unrelated_test_file() {
    # Reading test-vault-manage.sh has nothing to do with vault.json content
    local rc; rc=$(_run_hook "cat setup/tests/test-vault-manage.sh")
    assert_eq "0" "$rc" "test file reads must be allowed (no vault.json path)"
}
run_test "allows: cat test-vault-manage.sh (no vault.json path)" test_allow_unrelated_test_file

# ── CFG-621: verbs inside a commit MESSAGE are prose, not a read ─────────────
# The blocked-verb list contains the English words `more` and `less`, and the
# verb match ran over the whole command string — including a quoted -m body —
# with no positional relationship to the vault path. A commit whose message
# read "describe secrets/vault.json more usefully" was blocked although it read
# nothing. The fix strips -m/--message bodies and prose heredocs before the verb
# match; the path check stays on the full string. Both directions are pinned:
# prose must pass, a real pager or a read hidden inside the message must block.

test_allow_commit_message_mentioning_vault_with_more() {
    local rc; rc=$(_run_hook 'git commit -m "vault-ops: describe secrets/vault.json more usefully"')
    assert_eq "0" "$rc" "the word 'more' in an -m body is prose, not a pager — must be allowed"
}
run_test "allows: commit -m mentioning vault.json with the word 'more' (CFG-621)" \
    test_allow_commit_message_mentioning_vault_with_more

test_allow_commit_am_single_quoted_message_with_less() {
    local rc; rc=$(_run_hook "git commit -am 'secrets/vault.json is read less often now'")
    assert_eq "0" "$rc" "'less' inside a single-quoted -am body must be allowed"
}
run_test "allows: commit -am with 'less' in a single-quoted message (CFG-621)" \
    test_allow_commit_am_single_quoted_message_with_less

test_allow_long_message_option_with_equals() {
    local rc; rc=$(_run_hook 'git commit --message="head of secrets/vault.json docs rewritten"')
    assert_eq "0" "$rc" "--message=... body is prose and must be allowed"
}
run_test "allows: --message=... body containing a verb word (CFG-621)" \
    test_allow_long_message_option_with_equals

test_allow_heredoc_commit_message_via_cat_substitution() {
    # The form Claude Code actually uses for multi-line messages.
    local rc; rc=$(_run_hook "git commit -m \"\$(cat <<'EOF'
vault-ops: one vault

secrets/vault.json is described more usefully; the tail of the doc moved.
EOF
)\"")
    assert_eq "0" "$rc" "a heredoc message fed through cat is prose and must be allowed"
}
run_test "allows: heredoc commit message via \$(cat <<'EOF') (CFG-621)" \
    test_allow_heredoc_commit_message_via_cat_substitution

test_allow_heredoc_commit_message_via_F_stdin() {
    local rc; rc=$(_run_hook "git commit -F - <<'EOF'
docs: secrets/vault.json section trimmed, more to follow
EOF")
    assert_eq "0" "$rc" "a heredoc fed to 'git commit -F -' is prose and must be allowed"
}
run_test "allows: heredoc commit message via -F - (CFG-621)" \
    test_allow_heredoc_commit_message_via_F_stdin

test_block_more_pager_on_vault() {
    local rc; rc=$(_run_hook "more secrets/vault.json")
    assert_eq "2" "$rc" "'more' as a real pager against the plaintext must still be blocked"
}
run_test "blocks: more secrets/vault.json (still a pager)" test_block_more_pager_on_vault

test_block_less_pager_on_vault() {
    local rc; rc=$(_run_hook "less secrets/vault.json")
    assert_eq "2" "$rc" "'less' as a real pager against the plaintext must still be blocked"
}
run_test "blocks: less secrets/vault.json (still a pager)" test_block_less_pager_on_vault

test_block_read_hidden_in_message_substitution() {
    # A $(...) inside the -m body EXECUTES: this puts the plaintext into the
    # commit message. Stripping the message must not strip the substitution.
    local rc; rc=$(_run_hook 'git commit -m "$(cat secrets/vault.json)"')
    assert_eq "2" "$rc" "a command substitution inside -m is a real read and must be blocked"
}
run_test "blocks: \$(cat vault.json) inside an -m body is a real read" \
    test_block_read_hidden_in_message_substitution

test_block_read_after_commit_in_same_command() {
    local rc; rc=$(_run_hook 'git commit -m "note" && cat secrets/vault.json')
    assert_eq "2" "$rc" "a read outside the message body must still be blocked"
}
run_test "blocks: cat vault.json chained after a commit" test_block_read_after_commit_in_same_command

test_block_heredoc_fed_to_interpreter() {
    # Only heredocs fed to cat or to git commit are prose; one fed to an
    # interpreter can read the vault from inside its body.
    local rc; rc=$(_run_hook "bash <<'EOF'
cat secrets/vault.json
EOF")
    assert_eq "2" "$rc" "a heredoc fed to bash is code, not prose — must be blocked"
}
run_test "blocks: heredoc body fed to bash that reads vault.json" test_block_heredoc_fed_to_interpreter

test_block_interpreter_heredoc_inside_message() {
    local rc; rc=$(_run_hook "git commit -m \"\$(bash <<'EOF'
cat secrets/vault.json
EOF
)\"")
    assert_eq "2" "$rc" "an interpreter heredoc inside -m executes and must be blocked"
}
run_test "blocks: \$(bash <<EOF cat vault.json) inside an -m body" test_block_interpreter_heredoc_inside_message

test_allow_quoted_heredoc_prose_with_literal_substitution() {
    # With a QUOTED tag nothing in the body expands: "$(hostname)" is prose.
    local rc; rc=$(_run_hook "git commit -m \"\$(cat <<'EOF'
subject

prose mentions \$(hostname) and secrets/vault.json, more to come
EOF
)\"")
    assert_eq "0" "$rc" "a literal \$(...) in a quoted-tag heredoc does not execute — must be allowed"
}
run_test "allows: literal \$(...) prose inside a quoted-tag heredoc message (CFG-621)" \
    test_allow_quoted_heredoc_prose_with_literal_substitution

test_block_heredoc_written_to_vault_plaintext() {
    # A heredoc redirected INTO the plaintext is a hand-written vault, which the
    # guard blocked before CFG-621 and must keep blocking (use `set` instead).
    local rc; rc=$(_run_hook "cat <<'EOF' > secrets/vault.json
{}
EOF")
    assert_eq "2" "$rc" "a heredoc redirected into vault.json is not prose — must stay blocked"
}
run_test "blocks: cat <<EOF > secrets/vault.json (hand-written plaintext)" \
    test_block_heredoc_written_to_vault_plaintext

test_block_unquoted_heredoc_with_substitution() {
    # Unquoted <<EOF expands $(...) in the body: that line is a read, keep it.
    local rc; rc=$(_run_hook "git commit -m \"\$(cat <<EOF
\$(cat secrets/vault.json)
EOF
)\"")
    assert_eq "2" "$rc" "a substitution inside an unquoted heredoc body executes and must be blocked"
}
run_test "blocks: \$(cat vault.json) inside an unquoted heredoc body" test_block_unquoted_heredoc_with_substitution

# ── CFG-621 repair: a $(cat <<EOF) is prose ONLY as a commit message ─────────
# The first CFG-621 fix treated EVERY `$(cat <<'EOF' … EOF)` as prose because
# the heredoc's own command is `cat`, and dropped the body. What consumes the
# substitution's output decides whether the body runs: `bash -c "$(cat <<…)"`,
# `eval`, `perl -e` and `… | sh` execute it. The base guard blocked all of
# these; each one below really reads the plaintext when run.

test_block_cat_heredoc_fed_to_bash_c() {
    local rc; rc=$(_run_hook "bash -c \"\$(cat <<'EOF'
cat secrets/vault.json
EOF
)\"")
    assert_eq "2" "$rc" "bash -c \"\$(cat <<EOF …)\" executes the body and must be blocked"
}
run_test "blocks: bash -c \"\$(cat <<EOF cat vault.json)\" (CFG-621 repair)" test_block_cat_heredoc_fed_to_bash_c

test_block_cat_heredoc_fed_to_eval() {
    local rc; rc=$(_run_hook "eval \"\$(cat <<'EOF'
cat ~/cfg-agent-fleet/secrets/vault.json
EOF
)\"")
    assert_eq "2" "$rc" "eval \"\$(cat <<EOF …)\" executes the body and must be blocked"
}
run_test "blocks: eval \"\$(cat <<EOF cat vault.json)\" (CFG-621 repair)" test_block_cat_heredoc_fed_to_eval

test_block_cat_heredoc_echoed_into_sh() {
    local rc; rc=$(_run_hook "echo \"\$(cat <<'EOF'
head -50 secrets/vault.json
EOF
)\" | sh")
    assert_eq "2" "$rc" "echo \"\$(cat <<EOF …)\" | sh executes the body and must be blocked"
}
run_test "blocks: echo \"\$(cat <<EOF head vault.json)\" | sh (CFG-621 repair)" test_block_cat_heredoc_echoed_into_sh

test_block_cat_heredoc_fed_to_perl_e() {
    local rc; rc=$(_run_hook "perl -e \"\$(cat <<'EOF'
open F,'secrets/vault.json'; print <F>
EOF
)\"")
    assert_eq "2" "$rc" "perl -e \"\$(cat <<EOF …)\" executes the body and must be blocked"
}
run_test "blocks: perl -e \"\$(cat <<EOF open vault.json)\" (CFG-621 repair)" test_block_cat_heredoc_fed_to_perl_e

test_block_cat_heredoc_assigned_then_evaluated() {
    local rc; rc=$(_run_hook "x=\$(cat <<'EOF'
cat secrets/vault.json
EOF
)
eval \"\$x\"")
    assert_eq "2" "$rc" "a heredoc captured into a variable and eval'd must be blocked"
}
run_test "blocks: x=\$(cat <<EOF …); eval \"\$x\" (CFG-621 repair)" test_block_cat_heredoc_assigned_then_evaluated

test_block_message_option_outside_git_commit() {
    # -m belongs to git commit only; `unshare -m` is a mount-namespace flag.
    local rc; rc=$(_run_hook "unshare -m cat secrets/vault.json")
    assert_eq "2" "$rc" "an -m of another command is not a commit message and must not hide the read"
}
run_test "blocks: unshare -m cat vault.json (CFG-621 repair)" test_block_message_option_outside_git_commit

test_block_message_option_inside_a_quoted_string() {
    local rc; rc=$(_run_hook "echo ' -m \"'; cat secrets/vault.json; echo '\"'")
    assert_eq "2" "$rc" "a ' -m \"' inside a quoted string is not an option and must not hide the read"
}
run_test "blocks: ' -m \"' inside a quoted string does not hide a read (CFG-621 repair)" \
    test_block_message_option_inside_a_quoted_string

# Every real commit-message form must still pass under the narrower rule.
_heredoc_msg() {  # _heredoc_msg <prefix up to the $(>; prints the full command
    printf '%s' "$1\"\$(cat <<'EOF'
vault-ops: secrets/vault.json is described more usefully
EOF
)\""
}

test_allow_heredoc_message_forms() {
    local form rc
    for form in 'git commit -am ' 'git commit --message=' 'git commit --message ' \
                'git -C /tmp/r commit -m ' 'cd /tmp/r && git commit -m ' \
                'git commit -m "subject; more" -m ' 'GIT_AUTHOR_NAME=x git commit -m '; do
        rc=$(_run_hook "$(_heredoc_msg "$form")")
        assert_eq "0" "$rc" "heredoc message via '$form' is prose and must be allowed" || return 1
    done
}
run_test "allows: heredoc message via -am, --message=, -C, cd &&, a second -m, env prefix (CFG-621 repair)" \
    test_allow_heredoc_message_forms

# ── CFG-621 (b): the employer vault no longer exists ─────────────────────────
# The hook named a second vault deleted in 7752b2e and told the reader to run a
# `--vault` flag vault-manage.sh never had — advice that would be followed in a
# credential emergency. The employer name was also the only reason the guard
# was held back from the public template. The filename match is generic now.

test_hook_source_names_no_employer_vault() {
    # Built by concatenation so this test file carries no employer literal itself.
    local employer="ivo""clar"
    local hits; hits=$(grep -ci "$employer" "$HOOK" || true)
    assert_eq "0" "$hits" "the hook must not reference the deleted employer vault"
}
run_test "hook source carries no employer-vault reference (CFG-621)" test_hook_source_names_no_employer_vault

test_block_message_has_no_dead_vault_flag() {
    _run_hook "cat secrets/vault.json" >/dev/null
    assert_not_contains "$HOOK_STDERR" "--vault" "the block message must not advise a --vault flag that does not exist"
}
run_test "block message does not advise the nonexistent --vault flag (CFG-621)" test_block_message_has_no_dead_vault_flag

test_block_prefixed_vault_filename_generically() {
    local rc; rc=$(_run_hook "cat secrets/other-vault.json")
    assert_eq "2" "$rc" "any <prefix>-vault.json plaintext must be guarded, not one hard-coded name"
}
run_test "blocks: cat secrets/<prefix>-vault.json generically (CFG-621)" test_block_prefixed_vault_filename_generically

# ── NON-BASH TOOL ────────────────────────────────────────────────────────────

test_non_bash_tool_ignored() {
    local input='{"tool_name": "Read", "tool_input": {"file_path": "secrets/vault.json"}}'
    local rc=0
    echo "$input" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
    # NOTE: this hook only inspects Bash. Read tool reads are handled by
    # separate permission rules (Read tool can be denied via deny list).
    assert_eq "0" "$rc" "non-Bash tools should pass through this hook"
}
run_test "passes through: non-Bash tools" test_non_bash_tool_ignored

suite_summary
