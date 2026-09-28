#!/usr/bin/env bash
# Tests for global/hooks/flatpak-kill-guard.sh — PreToolUse hook refusing
# `flatpak kill <app-id>`.  CFG-412.
#
# `flatpak kill` takes an INSTANCE, which may be a numeric instance id or an APPLICATION
# id — and given an application id it stops EVERY running instance of that app, not the
# one the session started. Recurring offense (lrn audit 2026-04-24, Finding B);
# the rule lived in a machine file, which is never loaded at the moment
# someone types the command. Safe forms: `kill <PID>` of the instance you launched, or
# `flatpak kill <instance-id>`. Deliberate escape hatch: `bash -c 'flatpak kill <id>'`,
# the same shape manifest-push-check.sh uses.
#
# NOTE: one decisive assert per test — this harness lets only the FINAL assert decide.
source "$(dirname "$0")/test-helpers.sh"

HOOK="$REPO_ROOT/global/hooks/flatpak-kill-guard.sh"
SETTINGS="$REPO_ROOT/setup/config/settings.json"

suite_header "flatpak-kill-guard.sh (CFG-412)"

_rc() {
    local input rc=0
    input=$(jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}')
    HOOK_STDERR=$(printf '%s' "$input" | bash "$HOOK" 2>&1) || rc=$?
    printf '%s' "$rc"
}

# ── MUST BLOCK ────────────────────────────────────────────────────────────────

t_blocks_app_id() {
    assert_eq "2" "$(_rc 'flatpak kill org.chromium.Chromium')" "an application id kills every instance"
}
run_test "blocks flatpak kill <app-id>" t_blocks_app_id

t_blocks_after_separator() {
    assert_eq "2" "$(_rc 'flatpak ps && flatpak kill com.valvesoftware.Steam; echo done')" \
        "a flatpak kill after && must still be seen"
}
run_test "blocks it after a shell separator" t_blocks_after_separator

t_blocks_inside_ssh() {
    assert_eq "2" "$(_rc "ssh deck 'flatpak kill org.mozilla.firefox'")" \
        "the payload of an ssh command runs the same kill on the remote box"
}
run_test "blocks it inside an ssh '...' payload" t_blocks_inside_ssh

t_blocks_with_sudo_and_options() {
    assert_eq "2" "$(_rc 'sudo flatpak --user kill -v org.videolan.VLC')" \
        "sudo and global/subcommand options must not evade the guard"
}
run_test "blocks it with sudo and options" t_blocks_with_sudo_and_options

t_blocks_quoted_app_id() {
    assert_eq "2" "$(_rc "flatpak kill 'org.chromium.Chromium'")" "a quoted app id is still an app id"
}
run_test "blocks a quoted app id" t_blocks_quoted_app_id

t_message_recommends_pid() {
    _rc 'flatpak kill org.chromium.Chromium' >/dev/null
    local ok=1
    case "$HOOK_STDERR" in *"kill <PID>"*) ;; *) ok=0 ;; esac
    case "$HOOK_STDERR" in *"flatpak ps"*) ;; *) ok=0 ;; esac
    case "$HOOK_STDERR" in *"bash -c 'flatpak kill org.chromium.Chromium'"*) ;; *) ok=0 ;; esac
    assert_eq "1" "$ok" "refusal must recommend kill <PID>, point at flatpak ps, and name the escape hatch with the caller's own id"
}
run_test "refusal recommends kill <PID> and names the escape hatch" t_message_recommends_pid

# ── MUST ALLOW ────────────────────────────────────────────────────────────────

t_allows_escape_hatch() {
    assert_eq "0" "$(_rc "bash -c 'flatpak kill org.chromium.Chromium'")" \
        "bash -c is the deliberate, visible override"
}
run_test "allows the bash -c escape hatch" t_allows_escape_hatch

t_allows_instance_id() {
    assert_eq "0" "$(_rc 'flatpak kill 1739542631')" "a numeric instance id stops exactly one instance"
}
run_test "allows flatpak kill <instance-id>" t_allows_instance_id

t_allows_plain_kill() {
    assert_eq "0" "$(_rc 'kill 12345')" "kill <PID> is the recommended form (kill-guard judges ownership)"
}
run_test "allows plain kill <PID>" t_allows_plain_kill

t_allows_flatpak_ps() {
    assert_eq "0" "$(_rc 'flatpak ps --columns=instance,pid,application')" "listing instances kills nothing"
}
run_test "allows flatpak ps" t_allows_flatpak_ps

t_allows_grep() {
    assert_eq "0" "$(_rc "grep -rn 'flatpak kill org.x.Y' global/")" "searching for the string is not running it"
}
run_test "allows grepping for the literal string" t_allows_grep

t_allows_help() {
    assert_eq "0" "$(_rc 'flatpak kill --help')" "--help kills nothing"
}
run_test "allows flatpak kill --help" t_allows_help

t_allows_unresolved() {
    assert_eq "0" "$(_rc 'flatpak kill "$INSTANCE"')" "an unresolved target passes (guards under-block, CFG-658)"
}
run_test "allows an unresolved variable target" t_allows_unresolved

t_allows_commit_message() {
    assert_eq "0" "$(_rc 'git commit -m "Add guard against flatpak kill org.x.Y"')" \
        "a commit message describing the command is not the command"
}
run_test "allows the string inside a commit message" t_allows_commit_message

t_allows_heredoc_commit_message() {
    local cmd
    cmd=$(printf 'git commit -F - <<EOF\nAdd flatpak-kill-guard\n\nBlocks flatpak kill org.x.Y, which stops every instance.\nEOF')
    assert_eq "0" "$(_rc "$cmd")" "a heredoc body is data, not a command"
}
run_test "allows the string inside a heredoc body" t_allows_heredoc_commit_message

t_allows_placeholder() {
    assert_eq "0" "$(_rc 'echo "never run: flatpak kill <app-id>"')" "a <placeholder> names no app"
}
run_test "allows a <placeholder> target" t_allows_placeholder

t_blocks_after_heredoc() {
    local cmd
    cmd=$(printf 'tee /tmp/n.txt >/dev/null <<EOF\nnotes\nEOF\nflatpak kill org.chromium.Chromium')
    assert_eq "2" "$(_rc "$cmd")" "a command after the heredoc ends is still a command"
}
run_test "still blocks a kill after a heredoc ends" t_blocks_after_heredoc

# ── Heredocs that are executed, not data (review repair) ──────────────────────
# Dropping every heredoc body (to allow `git commit -F - <<EOF`) also dropped the ones
# fed to ssh or a shell, which RUN — and a heredoc is the natural way to drive the Deck.

t_blocks_ssh_heredoc() {
    assert_eq "2" "$(_rc "$(printf "ssh deck <<'EOF'\nflatpak kill com.valvesoftware.Steam\nEOF")")" \
        "a heredoc fed to ssh is run on the remote box"
}
run_test "blocks flatpak kill in a heredoc fed to ssh" t_blocks_ssh_heredoc

t_blocks_ssh_bash_s_heredoc() {
    assert_eq "2" "$(_rc "$(printf 'ssh deck bash -s <<EOF\nflatpak kill com.valvesoftware.Steam\nEOF')")" \
        "ssh <host> bash -s <<EOF runs the body"
}
run_test "blocks flatpak kill in a heredoc fed to ssh bash -s" t_blocks_ssh_bash_s_heredoc

t_blocks_bash_heredoc() {
    assert_eq "2" "$(_rc "$(printf 'bash <<EOF\nflatpak kill com.valvesoftware.Steam\nEOF')")" \
        "bash <<EOF runs the body"
}
run_test "blocks flatpak kill in a heredoc fed to bash" t_blocks_bash_heredoc

t_blocks_heredoc_piped_to_ssh() {
    assert_eq "2" "$(_rc "$(printf 'cat <<EOF | ssh deck sh\nflatpak kill com.valvesoftware.Steam\nEOF')")" \
        "a heredoc piped on into a remote shell runs too"
}
run_test "blocks flatpak kill in a heredoc piped into ssh" t_blocks_heredoc_piped_to_ssh

t_blocks_after_arith_shift() {
    assert_eq "2" "$(_rc "$(printf 'echo $((1<<X))\nflatpak kill org.mozilla.firefox')")" \
        "an arithmetic << is a shift, not a heredoc — scanning must not stop there"
}
run_test "blocks a kill after \$((1<<X))" t_blocks_after_arith_shift

t_blocks_after_herestring() {
    assert_eq "2" "$(_rc "$(printf 'cat <<<"x"\nflatpak kill org.mozilla.firefox')")" \
        "a <<< here-string is not a heredoc"
}
run_test "blocks a kill after a <<< here-string" t_blocks_after_herestring

t_allows_heredoc_to_file() {
    assert_eq "0" "$(_rc "$(printf 'cat > notes.md <<EOF\nNever run flatpak kill org.x.Y — it stops every instance.\nEOF')")" \
        "a heredoc written to a file is data"
}
run_test "allows the string in a heredoc written to a file" t_allows_heredoc_to_file

# ── The read-only exemption and the escape hatch are per command, not per line ─

t_blocks_after_readonly_first_word() {
    assert_eq "2" "$(_rc 'cat /tmp/launch.log; flatpak kill org.chromium.Chromium')" \
        "a harmless first command must not exempt the rest of the line"
}
run_test "blocks a kill after a read-only first command" t_blocks_after_readonly_first_word

t_blocks_after_escape_hatch_prefix() {
    assert_eq "2" "$(_rc 'bash -c "echo hi" && flatpak kill org.x.Y')" \
        "the bash -c hatch covers its own payload, not what follows it"
}
run_test "blocks a kill that merely follows a bash -c" t_blocks_after_escape_hatch_prefix

t_allows_escape_hatch_then_more() {
    assert_eq "0" "$(_rc "bash -c 'flatpak kill org.x.Y' && echo done")" \
        "the deliberate hatch still works with a follow-up command"
}
run_test "allows the bash -c hatch followed by another command" t_allows_escape_hatch_then_more

t_allows_cd_then_grep() {
    assert_eq "0" "$(_rc "cd ~/notes && grep -rn 'flatpak kill org.mozilla' .")" \
        "cd then a search runs nothing"
}
run_test "allows cd … && grep for the string" t_allows_cd_then_grep

t_allows_grep_piped() {
    assert_eq "0" "$(_rc "grep -rn 'flatpak kill org.mozilla' docs/ | head -5")" \
        "a search piped into head runs nothing"
}
run_test "allows grep … | head" t_allows_grep_piped

t_allows_git_log_search() {
    assert_eq "0" "$(_rc "git log -S 'flatpak kill org.mozilla' --oneline")" "searching history runs nothing"
}
run_test "allows git log -S for the string" t_allows_git_log_search

t_blocks_cmdsub_in_readonly() {
    assert_eq "2" "$(_rc 'echo $(flatpak kill org.x.Y)')" "a command substitution runs, whatever its host command"
}
run_test "blocks flatpak kill inside \$(…) even after echo" t_blocks_cmdsub_in_readonly

# ── Quotes are read the way the shell reads them (review repair 2) ────────────
# The exemption swapped '…' for Q first and "…" second, so the apostrophe in
# "it's" paired with a LATER single quote and the Q swallowed the kill between
# them: `echo "…it's…"; flatpak kill <app-id>; echo 'done'` became one `echo …`
# and passed. Whichever quote opens first governs and backslashes escape. A line
# the exemption cannot read for certain — an unclosed quote, a word starting with #
# (a comment's apostrophe is no quote; inside ${…} a # is no comment) — is not exempt.

t_blocks_apostrophe_in_double_quotes() {
    local c
    for c in "echo \"Stopping Steam, it's hung\"; flatpak kill com.valvesoftware.Steam; echo 'done'" \
             "cd ~ && echo \"it's stuck\" && flatpak kill com.valvesoftware.Steam && echo 'killed'" \
             "git status; echo \"won't wait\"; flatpak kill org.mozilla.firefox; echo 'ok'"; do
        assert_eq "2" "$(_rc "$c")" "an apostrophe inside \"…\" is not a quote: $c" || return 1
    done
}
run_test "blocks a kill between \"…it's…\" and a later '…'" t_blocks_apostrophe_in_double_quotes

t_blocks_escaped_double_quote() {
    assert_eq "2" "$(_rc 'echo "say \"hi"; flatpak kill org.mozilla.firefox; echo "ok"')" \
        "a backslash-escaped \" does not close the string"
}
run_test "blocks a kill after an escaped \\\" inside \"…\"" t_blocks_escaped_double_quote

t_blocks_ansi_c_quote() {
    assert_eq "2" "$(_rc "echo \$'it\\'s'; flatpak kill org.mozilla.firefox; echo 'ok'")" \
        "inside \$'…' a backslash escapes the quote"
}
run_test "blocks a kill after an \$'…\\'…' string" t_blocks_ansi_c_quote

t_blocks_after_comment_apostrophe() {
    local cmd
    cmd=$(printf "echo hi   # it's late\nflatpak kill org.mozilla.firefox; echo won\\\\'t")
    assert_eq "2" "$(_rc "$cmd")" "an apostrophe in a comment opens no string"
}
run_test "blocks a kill after an apostrophe in a comment" t_blocks_after_comment_apostrophe

t_blocks_after_hash_in_param_expansion() {
    assert_eq "2" "$(_rc 'echo ${a:- #b}; flatpak kill org.mozilla.firefox')" \
        "inside \${…} a # opens no comment — the kill after it runs"
}
run_test "blocks a kill after a # inside \${…}" t_blocks_after_hash_in_param_expansion

t_blocks_git_command_runner() {
    assert_eq "2" "$(_rc 'git bisect run flatpak kill org.mozilla.firefox')" \
        "git runs commands too (bisect run, rebase -x, submodule foreach): only its readers are exempt"
}
run_test "blocks git bisect run flatpak kill <app-id>" t_blocks_git_command_runner

t_allows_readonly_with_apostrophe() {
    assert_eq "0" "$(_rc "echo \"it's never: flatpak kill org.x.Y\"; echo 'noted'")" \
        "an apostrophe inside \"…\" does not end the exemption" || return 1
    assert_eq "0" "$(_rc "git -C ~/notes --no-pager log -S 'flatpak kill org.x.Y' --oneline")" \
        "git's readers stay exempt, with -C and --no-pager"
}
run_test "still allows echo \"…it's…\" and git -C … log -S" t_allows_readonly_with_apostrophe

# ── $$ is one token, and \<newline> is joined first (review repair 3) ─────────
# The tokenizer took any `$` before a `'` for a $'…' opener, in which \' does not close.
# Bash lexes `$$` (the PID) first, so in `$$'…'` the quote is a plain '…' that no backslash
# escapes. Bash also drops a \<newline> before it looks past a `$`: `$\<newline>'` opens
# $'…', and `$\<newline>$'` is $$ then a plain '…'. Misread, the exemption stayed inside a
# quote across `; flatpak kill <app-id>;`, saw one `echo` clause and passed a kill that
# ec38c532 blocked. Each case is first run through bash with the kill swapped for
# `echo RAN`, which shows that bash really runs the command in the middle.

_bash_runs_it() {  # <command with a flatpak kill> → 0 when bash runs the command in its place
    local probe="${1/flatpak kill /echo RAN }"
    [ "$(bash -c "$probe" 2>/dev/null | grep -c '^RAN')" = "1" ]
}

t_blocks_after_pid_then_quote() {
    local c nl=$'\n'
    for c in "echo \$\$'\\'; flatpak kill org.mozilla.firefox; echo '\\'" \
             "echo pid=\$\$'\\'; flatpak kill org.mozilla.firefox; echo '\\'" \
             "cd /tmp && echo \$\$'\\' && flatpak kill com.valvesoftware.Steam && echo '\\'" \
             "echo \$\\${nl}\$'\\'; flatpak kill org.mozilla.firefox; echo '\\'" \
             "echo \$\\${nl}'\\'\"'; flatpak kill org.mozilla.firefox; echo \"'\" # '"; do
        _bash_runs_it "$c" || { echo "    premise: bash does not run the middle command of: $c"; return 1; }
        assert_eq "2" "$(_rc "$c")" "bash runs the kill between the quotes: $c" || return 1
    done
}
run_test "blocks a kill after \$\$'…' or a \$\\<newline> quote" t_blocks_after_pid_then_quote

t_allows_ansi_c_after_pid() {
    local nl=$'\n'
    assert_eq "0" "$(_rc "echo \$\$\$'it\\'s'; echo 'flatpak kill org.x.Y'")" \
        "\$\$ then \$'…' is still \$'…': the \\' inside it does not close" || return 1
    assert_eq "0" "$(_rc "echo \$\\${nl}'it\\'s'; echo 'flatpak kill org.x.Y'")" \
        "\$\\<newline>'…' is \$'…' to bash, so the line only echoes"
}
run_test "still allows \$\$\$'…\\'…' and \$\\<newline>'…\\'…' read-only lines" t_allows_ansi_c_after_pid

# ── Together with kill-guard.sh (same Bash matcher) ───────────────────────────
# The refusal recommends `flatpak kill <instance-id>`, and kill-guard.sh read that as
# `kill <PID>` of a pid nobody owns: a session following the advice was stopped by the
# sibling guard, leaving only the kill-every-instance escape hatch open. kill-guard now
# judges the process the instance id resolves to (like pkill's pattern), so both guards
# agree: this session's own instance may be stopped, somebody else's may not.

KG="$REPO_ROOT/global/hooks/kill-guard.sh"
BOTH_RC=""; KG_STDERR=""
_both() {  # <command> → BOTH_RC="<flatpak-kill-guard rc> <kill-guard rc>" (mock `flatpak ps` on PATH)
    local input a=0 b=0
    input=$(jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}')
    printf '%s' "$input" | PATH="$TEST_TMPDIR/bin:$PATH" bash "$HOOK" >/dev/null 2>&1 || a=$?
    KG_STDERR=$(printf '%s' "$input" | PATH="$TEST_TMPDIR/bin:$PATH" CC_LAUNCH_REGISTRY="$TEST_TMPDIR/reg.tsv" \
        CC_LAUNCH_REGISTRY_LIB="$REPO_ROOT/setup/scripts/launch-registry.sh" bash "$KG" 2>&1) || b=$?
    BOTH_RC="$a $b"
}
_mock_flatpak() {  # <instance> <pid> … → a `flatpak ps --columns=instance,pid` stand-in
    mkdir -p "$TEST_TMPDIR/bin"
    { echo '#!/usr/bin/env bash'
      echo '[ "$1" = ps ] || exit 1'
      while [ $# -ge 2 ]; do printf 'printf "%%s\\t%%s\\n" %s %s\n' "$1" "$2"; shift 2; done
    } > "$TEST_TMPDIR/bin/flatpak"
    chmod +x "$TEST_TMPDIR/bin/flatpak"
}

t_both_allow_own_instance() {
    sleep 60 & local own=$!
    _mock_flatpak 1739542631 "$own"
    _both 'flatpak kill 1739542631'; local r="$BOTH_RC"
    kill "$own" 2>/dev/null
    echo "    measured (flatpak-kill-guard, kill-guard) = ($r)"
    assert_eq "0 0" "$r" "the refusal's advice — stop your own instance by id — must pass both guards"
}
run_test "both guards allow flatpak kill <own instance-id>" t_both_allow_own_instance

t_kill_guard_judges_instance_owner() {
    setsid sleep 120 >/dev/null 2>&1 &
    sleep 0.3
    local foreign; foreign=$(pgrep -n -f 'sleep 120' | head -1)
    [ -n "$foreign" ] || { echo "    could not create a foreign process" >&2; return 1; }
    _mock_flatpak 1739542631 "$foreign"
    _both 'flatpak kill 1739542631'; local r="$BOTH_RC"
    kill -9 "$foreign" 2>/dev/null
    echo "    measured (flatpak-kill-guard, kill-guard) = ($r)"
    local ok=1
    [ "$r" = "0 2" ] || ok=0
    case "$KG_STDERR" in *"$foreign"*) ;; *) ok=0 ;; esac
    assert_eq "1" "$ok" "somebody else's instance is refused by kill-guard, naming the pid it resolves to"
}
run_test "kill-guard refuses another session's instance, by its real pid" t_kill_guard_judges_instance_owner

t_both_allow_unknown_instance() {
    _mock_flatpak 1 1
    _both 'flatpak kill 424242'
    assert_eq "0 0" "$BOTH_RC" "an instance id flatpak does not know kills nothing (flatpak fails on its own)"
}
run_test "an unknown instance id passes both guards" t_both_allow_unknown_instance

t_plain_kill_still_judged() {
    setsid sleep 120 >/dev/null 2>&1 &
    sleep 0.3
    local foreign; foreign=$(pgrep -n -f 'sleep 120' | head -1)
    [ -n "$foreign" ] || return 1
    sleep 60 & local own=$!
    _mock_flatpak 1739542631 "$own"
    _both "flatpak kill 1739542631 && kill $foreign"; local r="$BOTH_RC"
    kill -9 "$foreign" "$own" 2>/dev/null
    assert_eq "0 2" "$r" "a plain kill after a flatpak kill is still kill-guard's to judge"
}
run_test "a plain kill after flatpak kill is still judged" t_plain_kill_still_judged

t_ignores_non_bash() {
    local rc=0
    printf '%s' '{"tool_name":"Edit","tool_input":{"command":"flatpak kill org.x.Y"}}' | bash "$HOOK" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "only Bash tool calls are inspected"
}
run_test "ignores non-Bash tools" t_ignores_non_bash

# ── Registration ──────────────────────────────────────────────────────────────

t_registered_via_safe_run() {
    local n
    n=$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command
             | select(. == "bash ~/.claude/hooks/safe-run.sh flatpak-kill-guard.sh")] | length' "$SETTINGS")
    assert_eq "1" "$n" "settings.json must register the guard once, on Bash, through safe-run.sh"
}
run_test "registered in settings.json on Bash via safe-run.sh" t_registered_via_safe_run

suite_summary
