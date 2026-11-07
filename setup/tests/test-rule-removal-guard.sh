#!/usr/bin/env bash
# Tests for global/hooks/rule-removal-guard.sh — CFG-897.
#
# A 2026-10-30 audit of this fleet's rule files found rules that had vanished from the
# global CLAUDE.md with no recorded owner decision: "User actions go LAST" + CFG-609
# (0a26da91), "Feature self-integrity" (61765dd3), the subagent no-files guardrail
# (3d8cb52c, an auto-sync commit), "Parallelization is mandatory" moved to a conditionally
# loaded file (1e6c6741). Replacements were written fresh and executed as "replace bullet";
# nothing checked that each removed sentence was moved, merged or retired by the owner. The
# guard refuses a `git commit` that drops a sentence or table row from a rule file unless
# the message carries a verified `Rule-removed:` trailer for it, and config-auto-sync holds
# such files back instead of sweeping them in.
#
# Every assertion message prints the measured value (rc, output), never only the claim.
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/test-config-auto-sync-helpers.sh"

GUARD="$REPO_ROOT/global/hooks/rule-removal-guard.sh"
SETTINGS="$REPO_ROOT/setup/config/settings.json"

suite_header "rule-removal-guard.sh (CFG-897)"

# Both print the exit code AND set RC + HOOK_STDERR. `rc=$(_rc …)` runs in a subshell and
# loses HOOK_STDERR, so a test that reads the refusal text calls `_rc … >/dev/null; rc=$RC`.
_rc() {  # <command> → exit code; HOOK_STDERR holds the hook's output
    local input; RC=0
    input=$(jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}')
    HOOK_STDERR=$(printf '%s' "$input" | bash "$GUARD" 2>&1) || RC=$?
    printf '%s' "$RC"
}
_rc_from() {  # <cwd> <command>
    local input; RC=0
    input=$(jq -n --arg c "$2" '{tool_name: "Bash", tool_input: {command: $c}}')
    HOOK_STDERR=$(cd "$1" && printf '%s' "$input" | bash "$GUARD" 2>&1) || RC=$?
    printf '%s' "$RC"
}

# Fixture: a repo with rule files of every in-scope shape plus two out-of-scope files.
_repo() {
    R="$TEST_TMPDIR/repo"
    mkdir -p "$R/global/knowledge/sub" "$R/.claude/reference" "$R/docs" "$R/sub"
    git -C "$R" init -q -b main
    git -C "$R" config color.diff always   # the fleet sets this; the guard must not read colour
    cat > "$R/CLAUDE.md" <<'EOF'
# Project

<!-- consumed-by: docs/other.md (reads the rules table) -->

## Development Rules

- **Backup discipline:** Keep backups of evry tier before a wipe. Verify the copy before deleting the source.
- **Quiet hooks:** Hooks print nothing on success, so a silent hook is a healthy hook.
- Normal rule that stays here forever and is never touched by any test.
- Subagents must commit nothing without explicit authorization from the delegating prompt.

| Trigger | File |
|---------|------|
| Vault ops, credentials, deploy secrets | `knowledge/vault-ops.md` |
| Konsole tabs, qdbus, terminal tab operations | `knowledge/konsole-tabs.md` |

```
- **Fenced:** this bullet is code, not a rule, and may go at any time.
```

See below.
EOF
    printf '# K\n\nParagraph rule sentence one lives here and stays. Second sentence of the paragraph is the one tests remove.\n' > "$R/global/knowledge/k.md"
    printf '# Deep\n\n- Nested knowledge bullet sits two levels down and is out of scope by the directly-under rule.\n' > "$R/global/knowledge/sub/deep.md"
    printf '# R\n\n- Reference bullet one is clearly a rule sentence that must not vanish silently.\n' > "$R/.claude/reference/r.md"
    printf '# Notes\n\n- A note bullet that reads like a rule but lives outside every rule directory.\n' > "$R/docs/notes.md"
    git -C "$R" add -A && git -C "$R" commit -qm init
}
_drop_quiet() { sed -i '/Quiet hooks/d' "$R/CLAUDE.md"; }   # the removal most tests use
QUIET='Rule-removed: "Quiet hooks: Hooks print nothing on success, so a silent"'

# ── MUST BLOCK ────────────────────────────────────────────────────────────────

t_blocks_removed_bullet() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    local rc; _rc "git -C $R commit -m 'tidy'" >/dev/null; rc=$RC
    assert_eq "2" "$rc" "exit was $rc: a bullet removed without a trailer must block (2)"
    assert_contains "$HOOK_STDERR" "CLAUDE.md" "refusal must name the file; got: ${HOOK_STDERR:0:200}"
    assert_contains "$HOOK_STDERR" "Quiet hooks" "refusal must quote the removed sentence; got: ${HOOK_STDERR:0:200}"
}
run_test "blocks a removed bullet without a trailer and names file + sentence" t_blocks_removed_bullet

t_blocks_table_row() {
    _repo; sed -i '/Konsole tabs/d' "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    local rc; _rc "git -C $R commit -m 'x'" >/dev/null; rc=$RC
    assert_eq "2" "$rc" "exit was $rc: a removed table row is a removed rule (2)"
    assert_contains "$HOOK_STDERR" "Konsole tabs" "refusal must quote the row; got: ${HOOK_STDERR:0:200}"
}
run_test "blocks a removed markdown table row" t_blocks_table_row

t_blocks_paragraph_sentence_in_knowledge() {
    _repo; sed -i 's/ Second sentence of the paragraph is the one tests remove\.//' "$R/global/knowledge/k.md"
    git -C "$R" add global/knowledge/k.md
    local rc; rc=$(_rc "git -C $R commit -m 'x'")
    assert_eq "2" "$rc" "exit was $rc: a sentence dropped from a paragraph in global/knowledge/*.md must block (2)"
}
run_test "blocks a sentence dropped from a paragraph in global/knowledge/" t_blocks_paragraph_sentence_in_knowledge

t_blocks_dot_claude_reference() {
    _repo; sed -i '/Reference bullet one/d' "$R/.claude/reference/r.md"; git -C "$R" add .claude/reference/r.md
    local rc; rc=$(_rc "git -C $R commit -m 'x'")
    assert_eq "2" "$rc" "exit was $rc: .claude/reference/*.md is a rule file (2)"
}
run_test "blocks a removal in .claude/reference/*.md" t_blocks_dot_claude_reference

t_blocks_commit_all() {
    _repo; _drop_quiet   # unstaged: -a takes it at commit time
    local rc; rc=$(_rc "git -C $R commit -am 'x'")
    assert_eq "2" "$rc" "exit was $rc: -a commits the working-tree removal (2)"
}
run_test "blocks it when -a stages the removal at commit time" t_blocks_commit_all

t_blocks_add_then_commit() {
    _repo; _drop_quiet   # unstaged: the add in the same call stages it, after PreToolUse ran
    local rc; rc=$(_rc "git -C $R add CLAUDE.md && git -C $R commit -m 'x'")
    assert_eq "2" "$rc" "exit was $rc: git add <file> && git commit in one call must be seen (2)"
}
run_test "blocks git add CLAUDE.md && git commit in one call" t_blocks_add_then_commit

t_blocks_cd_form() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    local rc; rc=$(_rc_from "$TEST_TMPDIR" "cd \"$R\" && git commit -m 'x'")
    assert_eq "2" "$rc" "exit was $rc: cd \"<repo>\" && git commit must resolve to <repo> (2)"
}
run_test "blocks cd \"<repo>\" && git commit from another cwd" t_blocks_cd_form

t_blocks_rewording_of_substance() {
    _repo; sed -i 's/so a silent hook is a healthy hook/so a silent hook may well be a broken hook/' "$R/CLAUDE.md"
    git -C "$R" add CLAUDE.md
    local rc; rc=$(_rc "git -C $R commit -m 'x'")
    assert_eq "2" "$rc" "exit was $rc: replacing a clause changes the rule and needs a trailer (2)"
}
run_test "blocks a clause replacement inside a sentence (below the similarity threshold)" t_blocks_rewording_of_substance

t_blocks_move_without_trailer() {
    _repo; _drop_quiet
    printf -- '- **Quiet hooks:** Hooks print nothing on success, so a silent hook is a healthy hook.\n' >> "$R/global/knowledge/k.md"
    git -C "$R" add CLAUDE.md global/knowledge/k.md
    local rc; rc=$(_rc "git -C $R commit -m 'move rule to knowledge'")
    assert_eq "2" "$rc" "exit was $rc: a move to another file is still a removal of this file (2)"
}
run_test "blocks a rule moved to another file when no moved-to trailer says so" t_blocks_move_without_trailer

t_blocks_moved_to_target_lacks_text() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    local rc; _rc "git -C $R commit -m 'x' -m '$QUIET moved-to global/knowledge/k.md'" >/dev/null; rc=$RC
    assert_eq "2" "$rc" "exit was $rc: moved-to must be grep-verified in the staged target (2)"
    assert_contains "$HOOK_STDERR" "global/knowledge/k.md" "refusal must say which target lacks the text; got: ${HOOK_STDERR:0:300}"
}
run_test "blocks moved-to when the staged target does not contain the text" t_blocks_moved_to_target_lacks_text

t_blocks_merged_into_title_absent() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    local rc; _rc "git -C $R commit -m 'x' -m '$QUIET merged-into \"Nonexistent heading\"'" >/dev/null; rc=$RC
    assert_eq "2" "$rc" "exit was $rc: merged-into needs the title present in a staged rule file (2)"
    assert_contains "$HOOK_STDERR" "Nonexistent heading" "refusal must name the missing title; got: ${HOOK_STDERR:0:300}"
}
run_test "blocks merged-into when the title is in no staged rule file" t_blocks_merged_into_title_absent

t_blocks_retired_bad_date() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    local rc; rc=$(_rc "git -C $R commit -m 'x' -m '$QUIET retired-by OWNER 2026-13-40'")
    assert_eq "2" "$rc" "exit was $rc: 2026-13-40 is not a date (2)"
}
run_test "blocks retired-by with an invalid date" t_blocks_retired_bad_date

t_blocks_retired_future_date() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    local rc; _rc "git -C $R commit -m 'x' -m '$QUIET retired-by OWNER 2999-01-01'" >/dev/null; rc=$RC
    assert_eq "2" "$rc" "exit was $rc: a retirement cannot be dated in the future (2)"
    assert_contains "$HOOK_STDERR" "2999-01-01" "refusal must name the rejected date; got: ${HOOK_STDERR:0:300}"
}
run_test "blocks retired-by with a future date" t_blocks_retired_future_date

t_blocks_short_prefix() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    local rc; rc=$(_rc "git -C $R commit -m 'x' -m 'Rule-removed: \"Quiet hooks\" retired-by OWNER 2026-10-30'")
    assert_eq "2" "$rc" "exit was $rc: a 11-char prefix cannot identify a sentence (2)"
}
run_test "blocks a trailer whose quoted text is shorter than the 30-char prefix minimum" t_blocks_short_prefix

t_blocks_unparseable_message() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    local rc; _rc "git -C $R commit -m \"\$MSG\"" >/dev/null; rc=$RC
    assert_eq "2" "$rc" "exit was $rc: a message held in a variable cannot be checked (2)"
    assert_contains "$HOOK_STDERR" "cannot be read" "refusal must explain the unreadable message; got: ${HOOK_STDERR:0:300}"
}
run_test "blocks when removals exist and the message cannot be parsed (-m \"\$VAR\")" t_blocks_unparseable_message

t_blocks_amend_without_trailer() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md; git -C "$R" commit -qm 'dropped it'   # recorded, bypassing the hook
    local bare ok
    bare=$(_rc "git -C $R commit --amend -m 'reword'")
    ok=$(_rc "git -C $R commit --amend -m 'reword' -m '$QUIET retired-by OWNER 2026-10-30'")
    assert_eq "2 0" "$bare $ok" "exits were '$bare $ok': --amend is judged against HEAD^ (bare 2, trailered 0)"
}
run_test "--amend compares against HEAD^: blocks bare, allows with trailer" t_blocks_amend_without_trailer

t_block_message_carries_template() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    _rc "git -C $R commit -m 'x'" >/dev/null
    assert_contains "$HOOK_STDERR" 'retired-by <who> YYYY-MM-DD' "refusal must carry the paste template; got: ${HOOK_STDERR:0:400}"
    assert_contains "$HOOK_STDERR" 'Rule-removed: "Quiet hooks: Hooks print nothing on success' "template must be filled with the sentence prefix; got: ${HOOK_STDERR:0:400}"
}
run_test "refusal carries a ready-to-paste trailer template with the sentence prefix" t_block_message_carries_template

# ── MUST ALLOW ────────────────────────────────────────────────────────────────

t_allows_typo_fix() {
    _repo; sed -i 's/evry tier/every tier/' "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    local rc; rc=$(_rc "git -C $R commit -m 'typo'")
    assert_eq "0" "$rc" "exit was $rc: a one-word typo fix is not a removal (0)"
}
run_test "allows a typo fix (near-identical sentence)" t_allows_typo_fix

t_allows_extension() {
    _repo; sed -i 's/deleting the source\./deleting the source, and log the checksum./' "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    local rc; rc=$(_rc "git -C $R commit -m 'extend'")
    assert_eq "0" "$rc" "exit was $rc: extending a sentence keeps it (0)"
}
run_test "allows extending a sentence ('X.' -> 'X, but Y.')" t_allows_extension

t_allows_mid_sentence_extension() {
    _repo; sed -i 's/so a silent hook is a healthy hook/so a silent hook, one that logs nowhere, is a healthy hook/' "$R/CLAUDE.md"
    git -C "$R" add CLAUDE.md
    local rc; rc=$(_rc "git -C $R commit -m 'extend'")
    assert_eq "0" "$rc" "exit was $rc: an insertion in the middle keeps every word of the rule (0)"
}
run_test "allows a mid-sentence extension (every old word kept)" t_allows_mid_sentence_extension

t_blocks_negation_insert() {
    _repo; sed -i 's/Keep backups of evry tier/Do not keep backups of evry tier/' "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    local rc; rc=$(_rc "git -C $R commit -m 'x'")
    assert_eq "2" "$rc" "exit was $rc: inserting 'not' inverts the rule although every old word is kept (2)"
}
run_test "blocks an inserted negation even though every old word is kept" t_blocks_negation_insert

t_allows_non_rule_file() {
    _repo; sed -i '/A note bullet/d' "$R/docs/notes.md"; git -C "$R" add docs/notes.md
    local rc; rc=$(_rc "git -C $R commit -m 'notes'")
    assert_eq "0" "$rc" "exit was $rc: docs/notes.md is not a rule file (0)"
}
run_test "allows removals in a non-rule file" t_allows_non_rule_file

t_allows_deep_knowledge_file() {
    _repo; sed -i '/Nested knowledge bullet/d' "$R/global/knowledge/sub/deep.md"; git -C "$R" add global/knowledge/sub/deep.md
    local rc; rc=$(_rc "git -C $R commit -m 'x'")
    assert_eq "0" "$rc" "exit was $rc: only files DIRECTLY under knowledge/ are rule files (0)"
}
run_test "allows removals in global/knowledge/<sub>/*.md (not directly under)" t_allows_deep_knowledge_file

t_allows_moved_to_verified() {
    _repo; _drop_quiet
    printf -- '- **Quiet hooks:** Hooks print nothing on success, so a silent hook is a healthy hook.\n' >> "$R/global/knowledge/k.md"
    git -C "$R" add CLAUDE.md global/knowledge/k.md
    local a b
    a=$(_rc "git -C $R commit -m 'move' -m '$QUIET moved-to global/knowledge/k.md'")
    b=$(_rc "git -C $R commit -m 'move' -m '$QUIET moved-to ~/.claude/knowledge/k.md'")
    assert_eq "0 0" "$a $b" "exits were '$a $b': moved-to verified in the staged target, repo path and ~/.claude form (0 0)"
}
run_test "allows moved-to when the staged target carries the text (repo path and ~/.claude/ form)" t_allows_moved_to_verified

t_allows_moved_to_target_added_in_same_call() {
    _repo; _drop_quiet
    printf -- '- **Quiet hooks:** Hooks print nothing on success, so a silent hook is a healthy hook.\n' >> "$R/global/knowledge/k.md"
    git -C "$R" add CLAUDE.md   # k.md is NOT staged yet: the add in the same call stages it after PreToolUse ran
    local rc; rc=$(_rc "git -C $R add global/knowledge/k.md && git -C $R commit -m 'move' -m '$QUIET moved-to global/knowledge/k.md'")
    assert_eq "0" "$rc" "exit was $rc: the target staged by an add in the same call must count as staged (0)"
}
run_test "allows moved-to when the target is staged by a git add in the same call" t_allows_moved_to_target_added_in_same_call

t_allows_merged_into_verified() {
    _repo; _drop_quiet
    sed -i 's/before deleting the source\./before deleting the source. Hooks print nothing on success./' "$R/CLAUDE.md"
    git -C "$R" add CLAUDE.md
    local rc; rc=$(_rc "git -C $R commit -m 'merge' -m '$QUIET merged-into \"Backup discipline\"'")
    assert_eq "0" "$rc" "exit was $rc: merged-into a bold label present in the staged file (0)"
}
run_test "allows merged-into when the title is a bold label in the staged file" t_allows_merged_into_verified

t_allows_retired_valid_date() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    local rc; rc=$(_rc "git -C $R commit -m 'retire' -m '$QUIET retired-by OWNER 2026-10-30'")
    assert_eq "0" "$rc" "exit was $rc: retired-by OWNER with a valid past date (0)"
}
run_test "allows retired-by OWNER <past date>" t_allows_retired_valid_date

t_allows_fleet_convention_multi_m() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    local rc; rc=$(_rc_from "$TEST_TMPDIR" "git -C \"$R\" commit -m \"Subject\" -m '$QUIET retired-by OWNER 2026-10-30' -m \"Co-Authored-By: Claude <noreply@anthropic.com>\"")
    assert_eq "0" "$rc" "exit was $rc: the fleet's multiple -m form with the trailer in its own -m (0)"
}
run_test "allows the trailer as its own -m among several" t_allows_fleet_convention_multi_m

t_allows_message_eq_and_file_forms() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    printf 'retire\n\n%s retired-by OWNER 2026-10-30\n' "$QUIET" > "$TEST_TMPDIR/msg.txt"
    local a b
    a=$(_rc "git -C $R commit --message='x' --message='$QUIET retired-by OWNER 2026-10-30'")
    b=$(_rc "git -C $R commit -F $TEST_TMPDIR/msg.txt")
    assert_eq "0 0" "$a $b" "exits were '$a $b': --message= and -F <file> carry the trailer (0 0)"
}
run_test "allows --message= and -F <file> forms" t_allows_message_eq_and_file_forms

t_allows_heredoc_stdin_message() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    local cmd rc
    cmd=$(printf 'git -C %s commit -F - <<EOF\nretire\n\n%s retired-by OWNER 2026-10-30\nEOF' "$R" "$QUIET")
    rc=$(_rc "$cmd")
    assert_eq "0" "$rc" "exit was $rc: a heredoc feeding -F - is the message (0)"
}
run_test "allows the trailer in a heredoc feeding -F -" t_allows_heredoc_stdin_message

t_allows_cmdsub_heredoc_message() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    local cmd rc
    cmd=$(printf 'git -C "%s" commit -m "$(cat <<'"'"'EOF'"'"'\nretire\n\n%s retired-by OWNER 2026-10-30\nEOF\n)"' "$R" "$QUIET")
    rc=$(_rc_from "$TEST_TMPDIR" "$cmd")
    assert_eq "0" "$rc" "exit was $rc: the \$(cat <<'EOF' …) message form carries the trailer (0)"
}
run_test "allows the trailer inside a \$(cat <<'EOF' …) message" t_allows_cmdsub_heredoc_message

t_allows_structure_only_changes() {
    _repo
    sed -i '/^## Development Rules$/d; /^<!-- consumed-by/d; /Fenced:/d; /^See below\.$/d' "$R/CLAUDE.md"
    git -C "$R" add CLAUDE.md
    local rc; rc=$(_rc "git -C $R commit -m 'x'")
    assert_eq "0" "$rc" "exit was $rc: headings, HTML comments, fenced code and a 10-char fragment are not rules (0)"
}
run_test "allows removing a heading, an HTML comment, fenced content and a too-short fragment" t_allows_structure_only_changes

t_allows_reorder_and_respacing() {
    _repo
    python3 - "$R/CLAUDE.md" <<'PY'
import sys
p = sys.argv[1]; lines = open(p, encoding="utf-8").read().split("\n")
q = [l for l in lines if "Quiet hooks" in l][0]
lines.remove(q); i = [k for k, l in enumerate(lines) if "Normal rule" in l][0]
lines.insert(i + 1, q.replace("Hooks print", "Hooks   print"))
open(p, "w", encoding="utf-8").write("\n".join(lines))
PY
    git -C "$R" add CLAUDE.md
    local rc; rc=$(_rc "git -C $R commit -m 'reorder'")
    assert_eq "0" "$rc" "exit was $rc: moving a bullet within the file and re-spacing it removes nothing (0)"
}
run_test "allows moving a bullet within the file and changing its whitespace" t_allows_reorder_and_respacing

t_allows_new_rule_file() {
    _repo; printf '# Sub\n\n- A brand-new rule in a brand-new CLAUDE.md.\n' > "$R/sub/CLAUDE.md"
    local rc; rc=$(_rc "git -C $R add sub/CLAUDE.md && git -C $R commit -m 'new'")
    assert_eq "0" "$rc" "exit was $rc: a new file removes nothing (0)"
}
run_test "allows adding a new rule file" t_allows_new_rule_file

t_allows_rename_of_rule_file() {
    _repo; git -C "$R" mv global/knowledge/k.md global/knowledge/k-renamed.md
    local rc; rc=$(_rc "git -C $R commit -m 'rename'")
    assert_eq "0" "$rc" "exit was $rc: a renamed rule file keeps every sentence (0)"
}
run_test "allows a rename of a rule file" t_allows_rename_of_rule_file

t_allows_only_pathspec_commit() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md; printf 'more\n' >> "$R/docs/notes.md"
    local rc; rc=$(_rc_from "$R" "git commit -m notes docs/notes.md")
    assert_eq "0" "$rc" "exit was $rc: a pathspec commit (--only) records just that path (0)"
}
run_test "allows git commit <other path> while the removal sits staged" t_allows_only_pathspec_commit

t_allows_unstaged_bystander() {
    _repo; _drop_quiet; printf 'more\n' >> "$R/docs/notes.md"; git -C "$R" add docs/notes.md
    local rc; rc=$(_rc "git -C $R commit -m 'notes'")
    assert_eq "0" "$rc" "exit was $rc: an unstaged removal is not in this commit (0)"
}
run_test "allows a commit that does not carry the unstaged removal" t_allows_unstaged_bystander

t_allows_merge_in_progress() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    git -C "$R" rev-parse HEAD > "$R/.git/MERGE_HEAD"   # a merge is being concluded
    local rc; rc=$(_rc "git -C $R commit -m 'merge'")
    assert_eq "0" "$rc" "exit was $rc: a merge commit passes through (0)"
}
run_test "passes through a commit that concludes a merge" t_allows_merge_in_progress

t_allows_non_commit_and_non_bash() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    local a b=0
    a=$(_rc "git -C $R log --oneline -3 && git -C $R status --short")
    printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"CLAUDE.md"}}' | bash "$GUARD" >/dev/null 2>&1 || b=$?
    assert_eq "0 0" "$a $b" "exits were '$a $b': non-commit git commands and non-Bash tools pass (0 0)"
}
run_test "allows non-commit commands and ignores non-Bash tools" t_allows_non_commit_and_non_bash

# ── Real-shape replays from this repo's history (Pattern 11: fixtures from git show) ──

t_replay_9dfbbb4b_passes() {
    _repo
    cat > "$R/global/CLAUDE.md" <<'EOF'
# Global

**Backlog convention:** `backlog.md` at project root. Don't read at startup. Tasks use `PRJ-NN` IDs. Four states: `[ ]` open, `[>]` in-progress, `[?]` awaiting verification, `[x]` done. Mark `[>]` when implementation begins; revert to `[ ]` at shutdown if incomplete. `[?]` means shipped and waiting on a live proof — it must name the observation that closes it, and is never swept back to `[ ]`. Full rules: `~/.claude/reference/backlog-convention.md`.
EOF
    mkdir -p "$R/global/reference"
    cat > "$R/global/reference/backlog-convention.md" <<'EOF'
# Backlog Convention

## Format

Every project has `backlog.md` at root. Do NOT read at session start — only when active tasks are done or user asks.
EOF
    git -C "$R" add global/CLAUDE.md global/reference/backlog-convention.md && git -C "$R" commit -qm 'before 9dfbbb4b'
    sed -i "s/Don't read at startup\./Don't read at startup, but grep it before telling MG nothing is open on a topic./" "$R/global/CLAUDE.md"
    sed -i "s/only when active tasks are done or user asks\./only when active tasks are done, the user asks, or before telling MG nothing is open on a topic./" "$R/global/reference/backlog-convention.md"
    git -C "$R" add global/CLAUDE.md global/reference/backlog-convention.md
    local rc; rc=$(_rc "git -C $R commit -m 'Q-RULE-BGREP: grep backlog before telling MG nothing is open (MG-approved); template task filed' -m 'Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>'")
    assert_eq "0" "$rc" "exit was $rc: 9dfbbb4b extended two sentences (one at the end, one in the middle) and removed none — must pass (0)"
}
run_test "replay 9dfbbb4b (CLAUDE.md end-extension + backlog-convention.md mid-extension) passes" t_replay_9dfbbb4b_passes

t_replay_0a26da91_blocks() {
    _repo
    cat > "$R/global/CLAUDE.md" <<'EOF'
# Global

- **MCP config changes require restart:** Changes to `.mcp.json` are invisible to current session. After fixes: verify file, tell user to restart, flag verification pending. Never mark done without live tool test.
- **User actions go LAST, labelled by ID.** End every response that needs something from the user with the action list, and label each item with its stable ID or a short keyword — never a bare ordinal. Tool results generate hundreds of scrollback lines; action items buried mid-response are invisible, and a bare ordinal makes "1. go" ambiguous between the item and its priority.
- **Form-fill content → file, not console.** When the user needs content to paste into online forms, write ALL fields to a `tmp/` text file and open in editor.
EOF
    git -C "$R" add global/CLAUDE.md && git -C "$R" commit -qm 'before 0a26da91'
    python3 - "$R/global/CLAUDE.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read().split("\n")
i = [k for k, l in enumerate(s) if "User actions go LAST" in l][0]
s[i] = ("- **User decisions as selectable options.** User decisions go at the end of the work or first thing at "
        "session start, asked one by one as selectable options via AskUserQuestion (recommended option first, "
        "each labelled with its stable ID) — never as a prose list.")
open(p, "w", encoding="utf-8").write("\n".join(s))
PY
    git -C "$R" add global/CLAUDE.md
    local cmd rc
    cmd=$(printf '%s' "git -C $R commit -m 'lrn: decisions as selectable options, one by one, at end of work or session start (MG-approved)' -m \"The old 'User actions go LAST' rule prescribed the prose list itself; replaced. Handover decisions must be written as question + 2-4 options for verbatim AskUserQuestion at session start. CFG-701 approved (option C); CFG-702..709 priorities agreed.\" -m 'Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>'")
    _rc "$cmd" >/dev/null; rc=$RC
    assert_eq "2" "$rc" "exit was $rc: 0a26da91 dropped 'User actions go LAST' and CFG-609 'never a bare ordinal' with no Rule-removed trailer — must block (2)"
    assert_contains "$HOOK_STDERR" "never a bare ordinal" "refusal must quote the lost CFG-609 sentence; got: ${HOOK_STDERR:0:600}"
}
run_test "replay 0a26da91 (global/CLAUDE.md bullet replaced) blocks" t_replay_0a26da91_blocks

# ── Fix round after the adversarial review (2026-11-04) ───────────────────────

t_allows_one_word_swap_in_long_sentence() {   # B1: SequenceMatcher autojunk made any ≥200-char sentence score ~0.19
    _repo
    local long='- **Evidence rule:** When a verification step reads a log, a diff or a grep result as evidence that a job finished, that a line is absent, that a scrub came back clean or that a bug is fixed, re-derive the claim from the artifact itself before repeating it, because the evidence may be stale, truncated, coloured or self-matched by the very command that produced it.'
    printf '%s\n' "$long" >> "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md; git -C "$R" commit -qm long
    sed -i 's/because the evidence may be stale,/because the evidence may be outdated,/' "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    local rc; rc=$(_rc "git -C $R commit -m 'wording'")
    assert_eq "0" "$rc" "exit was $rc: one word swapped in a $(printf '%s' "$long" | wc -c)-char sentence is a typo-level edit (0)"
}
run_test "allows a one-word swap in a 300-char sentence (autojunk off)" t_allows_one_word_swap_in_long_sentence

t_blocks_rename_out_of_scope() {   # B2 + S2: the 1e6c6741 class — a rule file moved out of rule scope
    _repo; git -C "$R" mv global/knowledge/k.md docs/k-archive.md
    local a b
    a=$(_rc "git -C $R commit -m 'archive'")
    _repo; b=$(_rc "git -C $R mv global/knowledge/k.md docs/k-archive.md && git -C $R commit -m 'archive'")
    assert_eq "2 2" "$a $b" "exits were '$a $b': a rule file renamed out of rule scope, staged or by git mv in the same call, is a deletion (2 2)"
}
run_test "blocks git mv <rule file> <outside rule scope> (staged and same-call)" t_blocks_rename_out_of_scope

t_blocks_git_rm_same_call() {   # S2
    _repo
    local rc; rc=$(_rc "git -C $R rm -q global/knowledge/k.md && git -C $R commit -m 'retire k'")
    assert_eq "2" "$rc" "exit was $rc: git rm in the same call deletes every sentence of the file (2)"
}
run_test "blocks git rm <rule file> && git commit in one call" t_blocks_git_rm_same_call

t_allows_amend_no_edit_after_trailered_commit() {   # S1
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    git -C "$R" commit -qm 'retire' -m "$QUIET retired-by OWNER 2026-10-30"
    printf 'more\n' >> "$R/docs/notes.md"; git -C "$R" add docs/notes.md
    local rc; rc=$(_rc "git -C $R commit --amend --no-edit")
    assert_eq "0" "$rc" "exit was $rc: --amend --no-edit keeps HEAD's trailer, which the guard must read (0)"
}
run_test "allows --amend --no-edit after a correctly trailered commit" t_allows_amend_no_edit_after_trailered_commit

t_blocks_vacuous_merged_into() {   # S3: the title must be a heading or bold label (≥ 8 chars) in a staged RULE file
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    local a b
    a=$(_rc "git -C $R commit -m 'x' -m '$QUIET merged-into \"the\"'")
    printf '# Notes\n\n## Quiet hooks and more\n' > "$R/docs/notes.md"; git -C "$R" add docs/notes.md
    b=$(_rc "git -C $R commit -m 'x' -m '$QUIET merged-into \"Quiet hooks and more\"'")
    assert_eq "2 2" "$a $b" "exits were '$a $b': a 3-char title, or a heading that exists only in a non-rule file, attests nothing (2 2)"
}
run_test "blocks merged-into with a vacuous title or a title found only in a non-rule file" t_blocks_vacuous_merged_into

t_blocks_weakened_force_words() {   # S4
    _repo; local a b c d
    sed -i 's/so a silent hook is a healthy hook/so a silent hook is usually a healthy hook/' "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md; a=$(_rc "git -C $R commit -m x")
    git -C "$R" checkout -q -- CLAUDE.md; sed -i 's/before deleting the source\./before deleting the source, when time permits./' "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md; b=$(_rc "git -C $R commit -m x")
    git -C "$R" checkout -q -- CLAUDE.md; sed -i 's/Subagents must commit nothing/Subagents should commit nothing/' "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md; c=$(_rc "git -C $R commit -m x")
    git -C "$R" checkout -q -- CLAUDE.md; sed -i 's/before a wipe\./before a wipe if possible./' "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md; d=$(_rc "git -C $R commit -m x")
    assert_eq "2 2 2 2" "$a $b $c $d" "exits were '$a $b $c $d': 'usually', 'when time permits', must→should, 'if possible' each weaken a rule (2 2 2 2)"
}
run_test "blocks hedges and force-word swaps (usually, when time permits, must→should, if possible)" t_blocks_weakened_force_words

t_blocks_strikethrough() {   # S5
    _repo; sed -i 's/^- Normal rule that stays here forever and is never touched by any test\.$/- ~~Normal rule that stays here forever and is never touched by any test.~~ (obsolete since 2026-11, see decisions.md)/' "$R/CLAUDE.md"
    git -C "$R" add CLAUDE.md
    local rc; rc=$(_rc "git -C $R commit -m x")
    assert_eq "2" "$rc" "exit was $rc: a struck-through sentence is a removed sentence (2)"
}
run_test "blocks a sentence struck through with ~~…~~ and marked obsolete" t_blocks_strikethrough

t_allows_sentence_split() {   # S6
    _repo; printf -- '- Mark `[>]` when implementation begins; revert to `[ ]` at shutdown if incomplete.\n' >> "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md; git -C "$R" commit -qm mark
    sed -i 's/begins; revert to/begins. Revert to/' "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    local rc; rc=$(_rc "git -C $R commit -m x")
    assert_eq "0" "$rc" "exit was $rc: splitting one sentence into two keeps every word in order (0)"
}
run_test "allows splitting a sentence in two ('begins; revert' -> 'begins. Revert')" t_allows_sentence_split

t_blocks_short_imperative_with_negation() {   # N1
    _repo; sed -i 's/ Verify the copy before deleting the source\./ Verify the copy before deleting the source. Never use `sed -i`./' "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md; git -C "$R" commit -qm never
    sed -i 's/ Never use `sed -i`\.//' "$R/CLAUDE.md"; git -C "$R" add CLAUDE.md
    local rc; rc=$(_rc "git -C $R commit -m x")
    assert_eq "2" "$rc" "exit was $rc: a 16-char imperative carrying 'never' is a rule, not a fragment (2)"
}
run_test "blocks removing a short imperative that carries a negation ('Never use sed -i.')" t_blocks_short_imperative_with_negation

t_allows_case_insensitive_trailer_and_any_approver() {   # N6 + the generic third form
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    local a b
    a=$(_rc "git -C $R commit -m 'x' -m 'rule-removed: \"Quiet hooks: Hooks print nothing on success, so a silent\" retired-by owner-initials 2026-10-30'")
    b=$(_rc "git -C $R commit -m 'x' -m 'Rule-removed: \"Quiet hooks: Hooks print nothing on success, so a silent\" retired-by 2026-10-30'")
    assert_eq "0 2" "$a $b" "exits were '$a $b': the key is case-insensitive and any approver token counts, but a missing approver does not (0 2)"
}
run_test "accepts a lower-case key and any approver token; rejects a missing approver" t_allows_case_insensitive_trailer_and_any_approver

# ── Check mode and the config-auto-sync hold ──────────────────────────────────

t_check_staged_mode() {
    _repo; _drop_quiet; git -C "$R" add CLAUDE.md
    local rc=0 out
    out=$(bash "$GUARD" --check-staged "$R" 2>/dev/null) || rc=$?
    assert_eq "1" "$rc" "exit was $rc: --check-staged with an unexplained removal exits 1"
    assert_eq "CLAUDE.md" "$out" "stdout was '$out': --check-staged lists the offending file(s)"
    git -C "$R" restore --staged CLAUDE.md; git -C "$R" checkout -- CLAUDE.md
    printf 'more\n' >> "$R/docs/notes.md"; git -C "$R" add docs/notes.md
    rc=0; out=$(bash "$GUARD" --check-staged "$R" 2>/dev/null) || rc=$?
    assert_eq "0" "$rc" "exit was $rc: --check-staged with no rule-file removal exits 0 (stdout '$out')"
}
run_test "--check-staged <repo>: exit 1 + file list on removals, exit 0 otherwise" t_check_staged_mode

t_auto_sync_holds_offending_file() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project" mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"
    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    mkdir -p "$config_repo/global/hooks"
    cp "$GUARD" "$REPO_ROOT/global/hooks/lib-rule-removal.sh" "$REPO_ROOT/global/hooks/lib-commit-scan.sh" "$config_repo/global/hooks/"
    printf '# G\n\n- **Keep:** this rule stays and nobody touches it in the test.\n- **Drop:** this rule is removed without any recorded decision.\n' > "$config_repo/global/CLAUDE.md"
    (cd "$config_repo" && git add -A && git commit -qm "base" && git push -q origin main)
    sed -i '/Drop:/d' "$config_repo/global/CLAUDE.md"
    local before; before=$(sha256sum "$config_repo/global/CLAUDE.md" | cut -c1-64)
    echo "session data" > "$config_repo/session-context.md"
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    local staged after committed held
    staged=$(git -C "$config_repo" diff --cached --name-only)
    after=$(sha256sum "$config_repo/global/CLAUDE.md" | cut -c1-64)
    committed=$(git -C "$config_repo" log -1 --name-only --format=)
    held=$(cat "$config_repo/.sync-warnings.log" 2>/dev/null)
    assert_not_contains "$staged" "global/CLAUDE.md" "staged after hook: '$staged' — the rule file must be held back"
    assert_eq "$before" "$after" "working tree sha before=$before after=$after — the owner's edit must survive byte-identical"
    assert_contains "$committed" "session-context.md" "last commit touched: '$committed' — the rest must still be committed"
    assert_not_contains "$committed" "global/CLAUDE.md" "last commit touched: '$committed' — the rule file must not be in it"
    assert_contains "$held" "RULE_REMOVAL_HELD: $config_repo: global/CLAUDE.md" "drift log was: '$held' — the hold must be recorded for the next SessionStart"
}
run_test "config-auto-sync holds a rule file with an unexplained removal, commits the rest, records RULE_REMOVAL_HELD" t_auto_sync_holds_offending_file

t_auto_sync_commits_rule_file_when_clean() {
    local config_repo="$TEST_TMPDIR/config-repo" project_dir="$TEST_TMPDIR/project" mock_home="$TEST_TMPDIR/home"
    mkdir -p "$project_dir" "$mock_home"
    create_mock_config_repo "$config_repo"
    create_tracked_repo_main "$config_repo" "$TEST_TMPDIR/remote.git"
    mkdir -p "$config_repo/global/hooks"
    cp "$GUARD" "$REPO_ROOT/global/hooks/lib-rule-removal.sh" "$REPO_ROOT/global/hooks/lib-commit-scan.sh" "$config_repo/global/hooks/"
    printf '# G\n\n- **Keep:** this rule stays and nobody touches it in the test.\n' > "$config_repo/global/CLAUDE.md"
    (cd "$config_repo" && git add -A && git commit -qm "base" && git push -q origin main)
    printf -- '- **Added:** a new rule removes nothing and must be swept in as before.\n' >> "$config_repo/global/CLAUDE.md"
    local patched; patched=$(create_patched_hook "$config_repo" "$project_dir" "$mock_home")
    run_hook "$patched" || true
    local committed; committed=$(git -C "$config_repo" log -1 --name-only --format=)
    assert_contains "$committed" "global/CLAUDE.md" "last commit touched: '$committed' — an additive rule edit is committed as before"
}
run_test "config-auto-sync still commits a rule file whose change removes nothing" t_auto_sync_commits_rule_file_when_clean

# ── Registration ──────────────────────────────────────────────────────────────

t_registered_via_safe_run() {
    local n
    n=$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command
             | select(. == "bash ~/.claude/hooks/safe-run.sh rule-removal-guard.sh")] | length' "$SETTINGS")
    assert_eq "1" "$n" "settings.json registers the guard $n time(s); must be exactly once, on Bash, through safe-run.sh"
}
run_test "registered in settings.json on Bash via safe-run.sh" t_registered_via_safe_run

suite_summary
