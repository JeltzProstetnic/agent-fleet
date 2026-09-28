#!/usr/bin/env bash
# Tests for global/hooks/hard-rule-guard.sh — CFG-388.
#
# Meta-rule "Rule changes require user consent — NO EXCEPTIONS" was honor-system only.
# 2026-04-21: an agent-added, over-constrained HARD RULE ("Executor affinity …")
# landed in a project's CLAUDE.md without approval, echoed into five other places, and cost a
# session ~20 minutes arguing for an invented design. The guard refuses a `git commit`
# that adds a `HARD RULE` line to any CLAUDE.md unless the commit message carries an
# `Approved-By:` trailer.
#
# NOTE: one decisive assert per test — this harness lets only the FINAL assert decide.
source "$(dirname "$0")/test-helpers.sh"

HOOK="$REPO_ROOT/global/hooks/hard-rule-guard.sh"
SETTINGS="$REPO_ROOT/setup/config/settings.json"

suite_header "hard-rule-guard.sh (CFG-388)"

_rc() {
    local input rc=0
    input=$(jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}')
    HOOK_STDERR=$(printf '%s' "$input" | bash "$HOOK" 2>&1) || rc=$?
    printf '%s' "$rc"
}

# A repo with a committed CLAUDE.md that already carries one HARD RULE.
_repo() {
    R="$TEST_TMPDIR/repo"
    mkdir -p "$R/sub" "$R/docs"
    git -C "$R" init -q
    git -C "$R" config color.diff always   # the fleet sets this; --no-color must win
    cat > "$R/CLAUDE.md" <<'EOF'
# Project

## Rules
- **Existing — HARD RULE:** keep backups.
- Normal rule.
EOF
    printf '# Sub\n' > "$R/sub/CLAUDE.md"
    printf '# Notes\n' > "$R/docs/notes.md"
    git -C "$R" add -A && git -C "$R" commit -qm init
}

_add_rule() {  # <file>
    printf -- '- **HARD RULE:** Executor affinity: never write to a tier that is not yours.\n' >> "$1"
}

# ── MUST BLOCK ────────────────────────────────────────────────────────────────

t_blocks_staged_new_rule() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "2" "$(_rc "git -C $R commit -m 'Add executor affinity'")" "an unapproved new HARD RULE must be refused"
}
run_test "blocks a staged new HARD RULE without a trailer" t_blocks_staged_new_rule

t_blocks_nested_claude_md() {
    _repo; _add_rule "$R/sub/CLAUDE.md"; git -C "$R" add sub/CLAUDE.md
    assert_eq "2" "$(_rc "git -C $R commit -m 'x'")" "every CLAUDE.md in the repo is in scope"
}
run_test "blocks it in a nested CLAUDE.md" t_blocks_nested_claude_md

t_blocks_inline_hard_rule() {
    _repo; printf -- '- **Vault completeness — HARD RULE:** new thing.\n' >> "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "2" "$(_rc "git -C $R commit -m 'x'")" "the '— HARD RULE:' form inside the bold label counts"
}
run_test "blocks the '<label> — HARD RULE:' form" t_blocks_inline_hard_rule

t_blocks_reworded_rule() {
    _repo; sed -i 's/keep backups\./keep backups on every tier./' "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "2" "$(_rc "git -C $R commit -m 'tweak'")" "a reworded HARD RULE is a rule change too"
}
run_test "blocks a reworded HARD RULE" t_blocks_reworded_rule

t_blocks_commit_all() {
    _repo; _add_rule "$R/CLAUDE.md"   # NOT staged — -a stages it at commit time
    assert_eq "2" "$(_rc "git -C $R commit -am 'x'")" "-a commits unstaged tracked changes; they must be seen"
}
run_test "blocks it when -a would stage it at commit time" t_blocks_commit_all

t_blocks_pathspec_commit() {
    _repo; _add_rule "$R/CLAUDE.md"
    assert_eq "2" "$(_rc "cd $R && git commit CLAUDE.md -m 'x'")" "a pathspec commit of CLAUDE.md takes the working tree"
}
run_test "blocks a pathspec commit naming CLAUDE.md" t_blocks_pathspec_commit

# `git add X && git commit` in ONE Bash call is the everyday form, and PreToolUse runs
# before the add: the index does not show the change yet, so the guard must work out
# what the add will stage.
t_blocks_add_then_commit() {
    _repo; _add_rule "$R/CLAUDE.md"
    assert_eq "2" "$(_rc "git -C $R add CLAUDE.md && git -C $R commit -m 'x'")" \
        "a rule staged by an add in the same command must be seen"
}
run_test "blocks git add CLAUDE.md && git commit in one call" t_blocks_add_then_commit

t_blocks_add_all_then_commit() {
    _repo; _add_rule "$R/sub/CLAUDE.md"
    assert_eq "2" "$(_rc "cd $R && git add -A && git commit -m 'x'")" "git add -A stages every CLAUDE.md"
}
run_test "blocks git add -A && git commit" t_blocks_add_all_then_commit

t_blocks_add_directory_then_commit() {
    _repo; _add_rule "$R/sub/CLAUDE.md"
    assert_eq "2" "$(_rc "git -C $R add sub/ && git -C $R commit -m 'x'")" "a directory pathspec covers the CLAUDE.md inside it"
}
run_test "blocks git add <dir> && git commit when the dir holds the CLAUDE.md" t_blocks_add_directory_then_commit

t_blocks_new_claude_md() {
    _repo; mkdir -p "$R/newproj"; _add_rule "$R/newproj/CLAUDE.md"
    assert_eq "2" "$(_rc "git -C $R add newproj/CLAUDE.md && git -C $R commit -m 'x'")" "a brand-new CLAUDE.md counts too"
}
run_test "blocks a HARD RULE in a new, untracked CLAUDE.md being added" t_blocks_new_claude_md

t_allows_add_of_other_file() {
    _repo; _add_rule "$R/CLAUDE.md"; printf 'more\n' >> "$R/docs/notes.md"
    assert_eq "0" "$(_rc "git -C $R add docs/notes.md && git -C $R commit -m 'notes'")" \
        "adding an unrelated file does not commit the CLAUDE.md edit"
}
run_test "allows git add <other file> && git commit" t_allows_add_of_other_file

t_blocks_heredoc_without_trailer() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    local cmd
    cmd=$(printf 'git -C %s commit -F - <<EOF\nAdd rule\n\nBody text.\nEOF' "$R")
    assert_eq "2" "$(_rc "$cmd")" "a heredoc message without the trailer is still unapproved"
}
run_test "blocks a heredoc message without the trailer" t_blocks_heredoc_without_trailer

# ── Quoting, subshells and prefixes (review repair) ───────────────────────────
# The first parser DELETED every quoted string before splitting, to keep a message from
# faking a clause. That also deleted quoted paths: `git -C "<repo>" commit` parsed as
# `git -C commit`, no commit clause was found, and an unapproved rule committed. A quoted
# path is the form agents are told to use, so every case below runs from ANOTHER cwd.

_rc_from() {  # <cwd> <command>
    local rc=0 input
    input=$(jq -n --arg c "$2" '{tool_name: "Bash", tool_input: {command: $c}}')
    HOOK_STDERR=$(cd "$1" && printf '%s' "$input" | bash "$HOOK" 2>&1) || rc=$?
    printf '%s' "$rc"
}

t_blocks_quoted_C() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "2" "$(_rc_from "$TEST_TMPDIR" "git -C \"$R\" commit -m \"x\"")" "git -C \"<repo>\" must resolve to <repo>"
}
run_test "blocks git -C \"<repo>\" commit (double-quoted path)" t_blocks_quoted_C

t_blocks_single_quoted_C() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "2" "$(_rc_from "$TEST_TMPDIR" "git -C '$R' commit -m wip")" "git -C '<repo>' must resolve to <repo>"
}
run_test "blocks git -C '<repo>' commit (single-quoted path)" t_blocks_single_quoted_C

t_blocks_quoted_cd() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "2" "$(_rc_from "$TEST_TMPDIR" "cd \"$R\" && git commit -m wip")" "cd \"<repo>\" must move the commit there"
}
run_test "blocks cd \"<repo>\" && git commit" t_blocks_quoted_cd

t_blocks_quoted_cd_add_commit() {
    _repo; _add_rule "$R/CLAUDE.md"   # unstaged: the add in the same call stages it
    assert_eq "2" "$(_rc_from "$TEST_TMPDIR" "cd \"$R\" && git add CLAUDE.md && git commit -m 'x'")" \
        "cd \"<repo>\" && git add && git commit from another cwd"
}
run_test "blocks cd \"<repo>\" && git add CLAUDE.md && git commit" t_blocks_quoted_cd_add_commit

t_blocks_quoted_add_spec() {
    _repo; _add_rule "$R/CLAUDE.md"
    assert_eq "2" "$(_rc_from "$R" "git add \"CLAUDE.md\" && git commit -m 'x'")" "a quoted add pathspec is still a pathspec"
}
run_test "blocks git add \"CLAUDE.md\" && git commit" t_blocks_quoted_add_spec

t_blocks_quoted_commit_pathspec() {
    _repo; _add_rule "$R/CLAUDE.md"
    assert_eq "2" "$(_rc_from "$R" "git commit -m x -- \"CLAUDE.md\"")" "a quoted commit pathspec after -- takes the working tree"
}
run_test "blocks git commit -m x -- \"CLAUDE.md\"" t_blocks_quoted_commit_pathspec

t_blocks_quoted_config_option() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "2" "$(_rc_from "$R" "git -c \"user.name=x\" commit -m wip")" "git -c \"k=v\" takes one argument"
}
run_test "blocks git -c \"k=v\" commit" t_blocks_quoted_config_option

t_blocks_subshell() {
    _repo; _add_rule "$R/CLAUDE.md"
    assert_eq "2" "$(_rc_from "$TEST_TMPDIR" "(cd $R && git add CLAUDE.md && git commit -m 'x')")" "a ( … ) subshell is still a command"
}
run_test "blocks (cd <repo> && git add && git commit)" t_blocks_subshell

t_blocks_env_prefix() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "2" "$(_rc_from "$R" "GIT_AUTHOR_NAME=x git commit -m wip")" "an env assignment prefix is not a different command"
}
run_test "blocks VAR=x git commit" t_blocks_env_prefix

t_blocks_command_prefix() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "2" "$(_rc_from "$R" "command git commit -m wip")" "command git is git"
}
run_test "blocks command git commit" t_blocks_command_prefix

t_blocks_sudo_prefix() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "2" "$(_rc_from "$TEST_TMPDIR" "sudo -u root git -C \"$R\" commit -m wip")" "sudo git is git"
}
run_test "blocks sudo -u <user> git -C \"<repo>\" commit" t_blocks_sudo_prefix

t_blocks_work_tree() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "2" "$(_rc_from "$TEST_TMPDIR" "git --git-dir=\"$R/.git\" --work-tree=\"$R\" commit -m wip")" \
        "--work-tree names the repo being committed to"
}
run_test "blocks git --git-dir=… --work-tree=… commit" t_blocks_work_tree

t_blocks_cmdsub_heredoc_message() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    local cmd
    cmd=$(printf 'git -C "%s" commit -m "$(cat <<'"'"'EOF'"'"'\nAdd a rule\n\nIt says "never"; cd /tmp (a message line).\nEOF\n)"' "$R")
    assert_eq "2" "$(_rc_from "$TEST_TMPDIR" "$cmd")" "the usual \$(cat <<'EOF') message form, without a trailer"
}
run_test "blocks a \$(cat <<'EOF' …) message without the trailer" t_blocks_cmdsub_heredoc_message

t_blocks_diff_external() {
    _repo; git -C "$R" config diff.external /bin/true   # a user diff driver must not blind the guard
    _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "2" "$(_rc "git -C $R commit -m 'x'")" "diff.external must not hide the added rule"
}
run_test "blocks it with diff.external configured" t_blocks_diff_external

t_blocks_include_pathspec() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md; printf 'more\n' >> "$R/docs/notes.md"
    assert_eq "2" "$(_rc_from "$R" "git commit -i -m wip docs/notes.md")" "--include commits the index as well as the paths"
}
run_test "blocks git commit -i <other> with the rule staged" t_blocks_include_pathspec

t_blocks_add_dot_in_subdir_rule() {
    _repo; _add_rule "$R/sub/CLAUDE.md"
    assert_eq "2" "$(_rc_from "$TEST_TMPDIR" "cd \"$R/sub\" && git add . && git commit -m x")" "git add . in sub/ takes sub/CLAUDE.md"
}
run_test "blocks cd sub && git add . && git commit when sub/CLAUDE.md has the rule" t_blocks_add_dot_in_subdir_rule

t_blocks_home_relative_quoted_C() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    local rc=0 input
    input=$(jq -n --arg c 'git -C "$HOME/repo" commit -m x' '{tool_name: "Bash", tool_input: {command: $c}}')
    (cd / && printf '%s' "$input" | HOME="$TEST_TMPDIR" bash "$HOOK" >/dev/null 2>&1) || rc=$?
    assert_eq "2" "$rc" "\"\$HOME/<repo>\" is the usual way to name a repo"
}
run_test "blocks git -C \"\$HOME/<repo>\" commit" t_blocks_home_relative_quoted_C

t_blocks_commit_after_heredoc() {
    _repo; _add_rule "$R/CLAUDE.md"   # unstaged — the -a below takes it
    local cmd
    cmd=$(printf 'cat > /dev/null <<EOF\nnotes that say git status\nEOF\ngit -C "%s" commit -am x' "$R")
    assert_eq "2" "$(_rc_from "$TEST_TMPDIR" "$cmd")" "a commit after the heredoc ends is still a commit"
}
run_test "blocks a commit that follows a heredoc" t_blocks_commit_after_heredoc

t_allows_commit_inside_heredoc_body() {
    _repo; _add_rule "$R/CLAUDE.md"   # unstaged
    local cmd
    cmd=$(printf 'cat > /dev/null <<EOF\ngit -C %s commit -am x\nEOF' "$R")
    assert_eq "0" "$(_rc_from "$TEST_TMPDIR" "$cmd")" "a heredoc body is data, not a command"
}
run_test "allows git commit text inside a heredoc body" t_allows_commit_inside_heredoc_body

t_allows_quoted_trailer_cmdsub() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    local cmd
    cmd=$(printf 'git -C "%s" commit -m "$(cat <<'"'"'EOF'"'"'\nAdd a rule\n\nApproved-By: MG\nEOF\n)"' "$R")
    assert_eq "0" "$(_rc_from "$TEST_TMPDIR" "$cmd")" "a trailer inside the \$(cat <<'EOF') message counts"
}
run_test "allows the trailer inside a \$(cat <<'EOF' …) message" t_allows_quoted_trailer_cmdsub

t_allows_message_that_mentions_commit() {
    _repo; _add_rule "$R/CLAUDE.md"   # unstaged — only a real `commit -a` would take it
    assert_eq "0" "$(_rc_from "$R" "echo \"next: git commit -am 'x'; cd /\"")" "text inside quotes is not a clause"
}
run_test "allows quoted text that only mentions git commit" t_allows_message_that_mentions_commit

t_allows_only_pathspec_commit() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md; printf 'more\n' >> "$R/docs/notes.md"
    assert_eq "0" "$(_rc_from "$R" "git commit -m wip docs/notes.md")" \
        "a pathspec commit (--only) commits just those paths, not the staged CLAUDE.md"
}
run_test "allows git commit <other path> while the rule sits staged" t_allows_only_pathspec_commit

t_allows_add_dot_in_other_subdir() {
    _repo; _add_rule "$R/CLAUDE.md"; printf 'more\n' >> "$R/docs/notes.md"
    assert_eq "0" "$(_rc_from "$TEST_TMPDIR" "cd $R/docs && git add . && git commit -m notes")" \
        "git add . in docs/ does not take the root CLAUDE.md"
}
run_test "allows cd docs && git add . && git commit past an unstaged root rule" t_allows_add_dot_in_other_subdir

t_message_names_trailer() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    _rc "git -C $R commit -m 'x'" >/dev/null
    local ok=1
    case "$HOOK_STDERR" in *"Approved-By:"*) ;; *) ok=0 ;; esac
    case "$HOOK_STDERR" in *"CLAUDE.md"*) ;; *) ok=0 ;; esac
    case "$HOOK_STDERR" in *"Executor affinity"*) ;; *) ok=0 ;; esac
    assert_eq "1" "$ok" "refusal must name the file, quote the rule, and name the trailer"
}
run_test "refusal names the file, the rule and the trailer" t_message_names_trailer

# ── MUST ALLOW ────────────────────────────────────────────────────────────────

t_allows_trailer_second_m() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "0" "$(_rc "git -C $R commit -m 'Add rule' -m 'Approved-By: user'")" "the trailer is the approval"
}
run_test "allows it with an Approved-By trailer (-m)" t_allows_trailer_second_m

t_allows_trailer_heredoc() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    local cmd
    cmd=$(printf 'git -C %s commit -F - <<EOF\nAdd rule\n\nApproved-By: MG\nEOF' "$R")
    assert_eq "0" "$(_rc "$cmd")" "a trailer inside a heredoc message counts"
}
run_test "allows it with the trailer in a heredoc" t_allows_trailer_heredoc

t_allows_trailer_option() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "0" "$(_rc "git -C $R commit -m 'x' --trailer 'Approved-By=user'")" "git's own --trailer form counts"
}
run_test "allows git --trailer Approved-By=…" t_allows_trailer_option

t_allows_trailer_in_file() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    printf 'Add rule\n\nApproved-By: user\n' > "$TEST_TMPDIR/msg.txt"
    assert_eq "0" "$(_rc "git -C $R commit -F $TEST_TMPDIR/msg.txt")" "a -F message file carrying the trailer counts"
}
run_test "allows it with the trailer in a -F message file" t_allows_trailer_in_file

t_allows_moved_rule() {
    _repo
    cat > "$R/CLAUDE.md" <<'EOF'
# Project

## Rules
- Normal rule.
- **Existing — HARD RULE:** keep backups.
EOF
    git -C "$R" add CLAUDE.md
    assert_eq "0" "$(_rc "git -C $R commit -m 'reorder'")" "moving an existing rule verbatim changes no rule"
}
run_test "allows moving an existing HARD RULE verbatim" t_allows_moved_rule

t_allows_other_files() {
    _repo; _add_rule "$R/docs/notes.md"; git -C "$R" add docs/notes.md
    assert_eq "0" "$(_rc "git -C $R commit -m 'notes'")" "only CLAUDE.md files are in scope"
}
run_test "allows HARD RULE text in a non-CLAUDE.md file" t_allows_other_files

t_allows_plain_edit() {
    _repo; printf -- '- Another normal rule.\n' >> "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "0" "$(_rc "git -C $R commit -m 'x'")" "ordinary CLAUDE.md edits are not gated"
}
run_test "allows an ordinary CLAUDE.md edit" t_allows_plain_edit

t_allows_unstaged_bystander() {
    _repo; _add_rule "$R/CLAUDE.md"   # unstaged, and NOT part of this commit
    printf 'more\n' >> "$R/docs/notes.md"; git -C "$R" add docs/notes.md
    assert_eq "0" "$(_rc "git -C $R commit -m 'notes'")" "an unstaged CLAUDE.md edit is not being committed"
}
run_test "allows a commit that does not include the unstaged rule" t_allows_unstaged_bystander

t_allows_non_commit() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "0" "$(_rc "git -C $R log --grep 'HARD RULE' --oneline")" "git log is not a commit"
}
run_test "allows non-commit git commands" t_allows_non_commit

t_ignores_non_bash() {
    local rc=0
    printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"CLAUDE.md"}}' | bash "$HOOK" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "only Bash tool calls are inspected"
}
run_test "ignores non-Bash tools" t_ignores_non_bash

# ── Approval is read from the MESSAGE, not the command (review repair 2) ──────
# The first check grepped the whole command for `Approved-By:`, so any clause that
# mentioned the token (`&& echo Approved-By: x`, an unrelated heredoc) approved the commit.
# Only -m/--message/--trailer values, a -F file, and the heredoc or here-string feeding
# `-F -` are the message.

t_blocks_trailer_outside_message() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "2" "$(_rc "git -C $R commit -m 'x' && echo Approved-By: y")" \
        "a token in another clause is not a trailer on the commit"
}
run_test "blocks git commit -m x && echo Approved-By: y" t_blocks_trailer_outside_message

t_blocks_trailer_in_unrelated_heredoc() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    local cmd
    cmd=$(printf 'cat > /dev/null <<EOF\nApproved-By: MG\nEOF\ngit -C %s commit -m x' "$R")
    assert_eq "2" "$(_rc "$cmd")" "a heredoc that is not the commit's stdin is not its message"
}
run_test "blocks the trailer in a heredoc that feeds another command" t_blocks_trailer_in_unrelated_heredoc

t_allows_fleet_convention_multi_m() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "0" "$(_rc_from "$TEST_TMPDIR" "git -C \"$R\" commit -m \"Subject\" -m \"Approved-By: owner 2026-09-27\" -m \"Co-Authored-By: Claude <noreply@anthropic.com>\"")" \
        "the fleet's multiple -m form, trailer in the second -m, must pass"
}
run_test "allows the fleet convention: git -C <repo> commit -m Subject -m Approved-By -m Co-Authored-By" t_allows_fleet_convention_multi_m

t_allows_trailer_option_colon_and_eq_forms() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "0 0" "$(_rc "git -C $R commit -m 'x' --trailer \"Approved-By: owner 2026-09-27\"") $(_rc "git -C $R commit --message='x' --trailer='Approved-By: MG'")" \
        "--trailer \"Approved-By: …\" and --trailer=/--message= forms carry the trailer"
}
run_test "allows --trailer \"Approved-By: …\" and the --trailer=/--message= forms" t_allows_trailer_option_colon_and_eq_forms

t_allows_trailer_in_cluster_m() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "0" "$(_rc "git -C $R commit -m 'Add rule' -am 'Approved-By: MG'")" "-am <msg> is -a plus -m <msg>"
}
run_test "allows the trailer as the value of a -am cluster" t_allows_trailer_in_cluster_m

t_allows_trailer_here_string() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "0" "$(_rc "git -C $R commit -F - <<< 'Add rule. Approved-By: MG'")" "a here-string feeding -F - is the message"
}
run_test "allows the trailer in a here-string feeding -F -" t_allows_trailer_here_string

t_judges_heredoc_before_command_name() {   # bash allows the redirection anywhere in the command
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    local bare ok
    bare=$(printf '<<EOF git -C %s commit -F -\nAdd rule\nEOF' "$R")
    ok=$(printf 'git <<EOF -C %s commit -F -\nAdd rule\n\nApproved-By: MG\nEOF' "$R")
    assert_eq "2 0" "$(_rc "$bare") $(_rc "$ok")" "a leading or mid-command heredoc must not hide the commit, and still feeds -F -"
}
run_test "judges a commit whose heredoc operator precedes git or commit" t_judges_heredoc_before_command_name

t_allows_whitespace_only_change() {
    _repo; sed -i 's/HARD RULE:\*\* keep backups\./HARD RULE:\*\*   keep backups.  /' "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    assert_eq "0" "$(_rc "git -C $R commit -m 'fmt'")" "spacing inside or after an existing HARD RULE line changes no rule"
}
run_test "allows a whitespace-only change to an existing HARD RULE line" t_allows_whitespace_only_change

t_refusal_has_no_paste_literal() {
    _repo; _add_rule "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    _rc "git -C $R commit -m 'x'" >/dev/null
    assert_not_contains "$HOOK_STDERR" '-m "Approved-By:' "the refusal must not hand the agent a ready-made trailer flag" || return 1
    assert_not_contains "$HOOK_STDERR" 'Approved-By: user' "the refusal must not print a paste-ready trailer value"
}
run_test "refusal carries no copy-paste-able Approved-By example" t_refusal_has_no_paste_literal

# ── Registration ──────────────────────────────────────────────────────────────

t_registered_via_safe_run() {
    local n
    n=$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command
             | select(. == "bash ~/.claude/hooks/safe-run.sh hard-rule-guard.sh")] | length' "$SETTINGS")
    assert_eq "1" "$n" "settings.json must register the guard once, on Bash, through safe-run.sh"
}
run_test "registered in settings.json on Bash via safe-run.sh" t_registered_via_safe_run

suite_summary
