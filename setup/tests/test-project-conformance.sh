#!/usr/bin/env bash
# Tests for setup/scripts/project-conformance.sh — CFG-1094 (the CLI over project-conformance-lib.sh).
#
# Modes under test: --project (the per-project SessionStart path: fix + file + one line),
# --sweep (every registered project on this machine, absent ones reported, live sessions
# skipped), --sweep --fix --commit-push (the one-time backfill — ONLY against throwaway
# clones with a local bare remote here), --trailers, and the date-gated PROJECT_DRIFT line
# (--if-due/--force/--status, pattern of fleet-drift.sh). Two cases run on sparse local
# clones of REAL project trees (known-faulty Pattern 11).
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/lib-pc-fixture.sh"

suite_header "project-conformance.sh (CFG-1094: per-project path, sweep, backfill, PROJECT_DRIFT)"

run_pc() {   # [args…] — the CLI with the test seams, stderr folded in
    PC_CACHE="${PC_CACHE:-$TEST_TMPDIR/cache/project-drift.status}" SCHED_MARKER_DIR="$TEST_TMPDIR/sched" \
    PC_SELF_DIR="${PC_SELF_DIR:-$TEST_TMPDIR/nowhere}" bash "$PC_CLI" "$@" 2>&1
}

# ── --project (SessionStart path) ─────────────────────────────────────────────

t_project_report_is_read_only() {
    pcf_cfg; pcf_project rep --legacy-inbox --no-gitignore
    local out; out=$(run_pc --project "$P")
    assert_contains "$out" "FIX|githooks|" || return 1
    assert_contains "$out" "FIX|retired|" || return 1
    assert_eq "" "$(git -C "$P" status --porcelain)" "a report writes nothing"
}
run_test "--project: reports items, writes nothing" t_project_report_is_read_only

t_project_fix_brief_line() {
    pcf_cfg; pcf_project br --legacy-inbox --tracked-tmp 2
    local out; out=$(run_pc --project "$P" --fix --file-backlog --brief)
    assert_eq "1" "$(printf '%s\n' "$out" | grep -c .)" "exactly one line: $out" || return 1
    assert_contains "$out" "PROJECT_CONFORMANCE: fixed .githooks/pre-commit copied from the template; CLAUDE.md: 1 line(s) rewritten from cross-project/inbox.md to cross-project/inbox/<project>.md" || return 1
    assert_contains "$out" "commit these in this session" || return 1
    assert_contains "$out" "--trailers" "the session is told where the Rule-removed trailers come from" || return 1
    assert_contains "$out" "Filed backlog item FIX-13 for: " || return 1
    assert_contains "$out" "Knowledge Loading lacks the code rows" || return 1
    assert_contains "$out" "2 tracked file(s) under tmp/" || return 1
    cmp -s "$P/.githooks/pre-commit" "$PC_TEMPLATE_HOOK" || return 1
    assert_eq "PROJECT_CONFORMANCE: ok" "$(run_pc --project "$P" --fix --file-backlog --brief)" \
        "once conforming and tracked, only the sentinel the check swallows (a crash is then distinguishable from nothing-to-say)"
}
run_test "--project --fix --file-backlog --brief: one line naming the fixes and the filed item" t_project_fix_brief_line

t_project_behind_upstream_defers_then_pull_succeeds() {
    pcf_cfg; pcf_project behind --legacy-inbox --no-gitignore --tracked-tmp 1
    pcf_bare_remote "$P" >/dev/null
    pcf_backfill_upstream "$P" || { echo "    fixture: backfill upstream failed" >&2; return 1; }
    local out; out=$(run_pc --project "$P" --fix --file-backlog --brief)
    assert_contains "$out" "PROJECT_CONFORMANCE: deferred — HEAD is 1 commit(s) behind @{u}; the conformance fixes run after this session's pull" || return 1
    assert_eq "" "$(git -C "$P" status --porcelain)" "nothing written while behind (an untracked .githooks/pre-commit would abort the pull)" || return 1
    git -C "$P" pull -q --ff-only >/dev/null 2>&1 || { echo "    git pull --ff-only failed after check 30 ran" >&2; return 1; }
    cmp -s "$P/.githooks/pre-commit" "$PC_TEMPLATE_HOOK" || return 1
    out=$(run_pc --project "$P" --fix --file-backlog --brief)
    assert_contains "$out" "Filed backlog item" "after the pull only the filing is left (tracked tmp/)" || return 1
    assert_not_contains "$out" "fixed" "the pull brought every mechanical item"
}
run_test "--project: behind the fetched upstream it defers, and the startup pull then succeeds (MAJOR 1)" t_project_behind_upstream_defers_then_pull_succeeds

t_project_unregistered_is_silent() {
    pcf_cfg; mkdir -p "$HOME/loose"; git -C "$HOME/loose" init -q -b main; pcf_manifest "$HOME/loose/CLAUDE.md" --legacy-inbox
    local out; out=$(run_pc --project "$HOME/loose" --fix --file-backlog --brief)
    assert_eq "PROJECT_CONFORMANCE: not a registered project" "$out" "an unregistered directory is not a fleet project: $out" || return 1
    assert_eq "" "$(git -C "$HOME/loose" status --porcelain | grep -v '^??' || true)" "and nothing is written there"
    assert_file_not_exists "$HOME/loose/.githooks/pre-commit"
}
run_test "--project: an unregistered directory gets no fixes and no line" t_project_unregistered_is_silent

t_project_explicit_name_type() {
    pcf_cfg; mkdir -p "$HOME/x"; git -C "$HOME/x" init -q -b main; pcf_manifest "$HOME/x/CLAUDE.md"
    local out; out=$(run_pc --project "$HOME/x" --name x --type writing)
    assert_contains "$out" "Knowledge Loading lacks the writing rows: prose-register.md" "--name/--type stand in for a registry row"
}
run_test "--project --name --type: a project can be checked without a registry row" t_project_explicit_name_type

# ── --sweep ───────────────────────────────────────────────────────────────────

t_sweep_report() {
    pcf_cfg
    pcf_project good --githooks --knowledge vertical-slicing.md --knowledge needs-to-requirements.md \
        --knowledge test-isolation-guards.md --knowledge anti-chain-state.md --knowledge log-evidence-traps.md --knowledge llm-provider-integration.md
    pcf_project bad --legacy-inbox --no-gitignore
    pcf_register ghost "~/ghost" code
    local out; out=$(run_pc --sweep)
    assert_contains "$out" "good: OK" || return 1
    assert_contains "$out" "bad: FIX githooks: .githooks/pre-commit missing" || return 1
    assert_contains "$out" "gitignore: .gitignore lacks: tmp/" || return 1
    assert_contains "$out" "| FILE knowledge: Knowledge Loading lacks the code rows" || return 1
    assert_contains "$out" "ghost: ABSENT ($HOME/ghost)" "a registered project not on this machine is reported, never skipped" || return 1
    assert_contains "$out" "PROJECT_DRIFT[WARN]: 3 registered, 1 conform, 1 to fix (bad), 1 to file (bad), 1 absent (ghost)" || return 1
    assert_eq "" "$(git -C "$HOME/bad" status --porcelain)" "the sweep report writes nothing"
}
run_test "--sweep: one line per project, absent ones named, a PROJECT_DRIFT summary" t_sweep_report

t_sweep_own_hook_is_a_note_not_a_finding() {
    pcf_cfg; pcf_global_rows vertical-slicing.md needs-to-requirements.md test-isolation-guards.md anti-chain-state.md \
        log-evidence-traps.md llm-provider-integration.md
    pcf_project ownhook --githooks-custom
    local out; out=$(run_pc --sweep --fix)
    assert_contains "$out" "ownhook: OK (.githooks/pre-commit differs from the template" "the note shows in the sweep line" || return 1
    assert_contains "$out" "PROJECT_DRIFT: 1 registered, 1 conform" "and raises nothing" || return 1
    assert_eq "0" "$(grep -c 'Project conformance' "$P/backlog.md")" "no backlog item for a project's own hook" || return 1
    assert_eq "2" "$(wc -l < "$P/.githooks/pre-commit")" "the own hook is untouched"
}
run_test "--sweep: a project's own .githooks/pre-commit is a NOTE — no item, never overwritten" t_sweep_own_hook_is_a_note_not_a_finding

t_sweep_all_conform() {
    pcf_cfg
    pcf_project only --githooks --knowledge vertical-slicing.md --knowledge needs-to-requirements.md \
        --knowledge test-isolation-guards.md --knowledge anti-chain-state.md --knowledge log-evidence-traps.md --knowledge llm-provider-integration.md
    assert_contains "$(run_pc --sweep)" "PROJECT_DRIFT: 1 registered, 1 conform" "no finding, no WARN tag"
}
run_test "--sweep: all conforming yields an OK summary" t_sweep_all_conform

t_sweep_fix_skips_live_and_self() {
    pcf_cfg
    pcf_project live --legacy-inbox; pcf_lock "$P" "$$"
    pcf_project self --legacy-inbox
    pcf_project free --legacy-inbox
    local out; out=$(PC_SELF_DIR="$HOME/self" run_pc --sweep --fix)
    assert_contains "$out" "live: LOCKED (held: lock pid $$ alive) — skipped" || return 1
    assert_file_not_exists "$HOME/live/.githooks/pre-commit" "a live session's tree is never touched" || return 1
    assert_contains "$out" "self: FIXED" || return 1
    assert_contains "$out" "this session's own tree — commit it here" || return 1
    assert_file_exists "$HOME/self/.githooks/pre-commit" || return 1
    assert_contains "$out" "free: FIXED githooks: .githooks/pre-commit copied from the template" || return 1
    assert_eq "0" "$(git -C "$HOME/free" log --oneline | grep -c conformance || true)" "--fix without --commit-push commits nothing" || return 1
    [ -n "$(git -C "$HOME/free" status --porcelain)" ] || { echo "    the fixes must be left uncommitted in the tree" >&2; return 1; }
}
run_test "--sweep --fix: fixes free projects, skips a live session, never commits the self project" t_sweep_fix_skips_live_and_self

t_sweep_commit_push() {
    pcf_cfg
    pcf_project pushed --legacy-inbox --tracked-tmp 1
    local bare; bare=$(pcf_bare_remote "$P")
    pcf_project local --legacy-inbox                     # no remote at all
    local out; out=$(run_pc --sweep --fix --commit-push)
    assert_contains "$out" "pushed: FIXED" || return 1
    assert_contains "$out" "committed $(git -C "$HOME/pushed" rev-parse --short HEAD), pushed to origin/main" || return 1
    assert_eq "$(git -C "$HOME/pushed" rev-parse HEAD)" "$(git -C "$bare" rev-parse main)" "the bare remote has the commit" || return 1
    local msg; msg=$(git -C "$HOME/pushed" log -1 --format=%B)
    assert_contains "$msg" "Project conformance backfill (CFG-1094)" || return 1
    assert_contains "$msg" 'Rule-removed: "' || return 1
    assert_contains "$msg" "retired-by owner 2026-11-25" || return 1
    assert_contains "$msg" "Co-Authored-By: Claude <noreply@anthropic.com>" || return 1
    bash "$REPO_ROOT/global/hooks/rule-removal-guard.sh" --replay HEAD "$HOME/pushed" >/dev/null 2>&1 \
        || { echo "    the guard would have refused the backfill commit" >&2; return 1; }
    assert_eq ".githooks/pre-commit CLAUDE.md backlog.md" "$(git -C "$HOME/pushed" show --name-only --format= HEAD | tr '\n' ' ' | sed 's/ $//')" \
        "only the fixed files and the filed backlog item are in the commit" || return 1
    assert_eq "" "$(git -C "$HOME/pushed" status --porcelain)" "nothing left uncommitted" || return 1
    assert_contains "$out" "local: FIXED" || return 1
    assert_contains "$out" "committed $(git -C "$HOME/local" rev-parse --short HEAD), not pushed (no upstream)"
}
run_test "--sweep --fix --commit-push: one commit per repo with trailers, pushed where an upstream exists" t_sweep_commit_push

t_sweep_files_p2_and_honours_opt_out() {
    pcf_cfg
    pcf_project filed --legacy-inbox --tracked-tmp 1
    pcf_project optout --legacy-inbox --no-gitignore --no-marker --tracked-tmp 2
    : > "$HOME/optout/.fleet-conformance-skip"
    git -C "$HOME/optout" add .fleet-conformance-skip >/dev/null; git -C "$HOME/optout" commit -qm marker >/dev/null
    local out; out=$(run_pc --sweep --fix --commit-push)
    assert_file_contains "$HOME/filed/backlog.md" '^- \[ \] \[P2\] `FIX-13` \*\*Project conformance\*\*' "the sweep files at P2 (Q-1094-ITEMPRIO)" || return 1
    assert_contains "$out" "optout: NOTE opted-out: .fleet-conformance-skip present — nothing checked, fixed or filed" || return 1
    assert_eq "" "$(git -C "$HOME/optout" status --porcelain)" "the opted-out tree is untouched" || return 1
    assert_eq "2" "$(git -C "$HOME/optout" rev-list --count HEAD)" "and gets no commit" || return 1
    assert_file_not_exists "$HOME/optout/.githooks/pre-commit" || return 1
    assert_eq "0" "$(grep -c 'Project conformance' "$HOME/optout/backlog.md")" "and no backlog item" || return 1
    assert_contains "$out" "PROJECT_DRIFT[WARN]: 2 registered, 0 conform, 0 to fix, 1 to file (filed), 0 absent, 1 noted (optout)" "the opt-out is noted, never WARN by itself" || return 1
    pcf_project only --legacy-inbox; : > "$P/.fleet-conformance-skip"
    rm -rf "$HOME/filed" "$HOME/optout"; pcf_cfg; pcf_register only "~/only" code
    assert_contains "$(run_pc --sweep)" "PROJECT_DRIFT: 1 registered, 0 conform, 0 to fix, 0 to file, 0 absent, 1 noted (only)" "an opted-out project alone leaves the line at OK"
}
run_test "--sweep: files P2 items; an opted-out project is a NOTE, never touched, never WARN (Q-1094-SEARXNG)" t_sweep_files_p2_and_honours_opt_out

t_commit_message_carries_no_machine_name() {
    pcf_cfg; pcf_project anon --legacy-inbox
    run_pc --sweep --fix --commit-push >/dev/null
    local msg host; msg=$(git -C "$P" log -1 --format=%B); host=$(hostname 2>/dev/null || uname -n)
    assert_not_contains "$msg" "$host" "no machine identifier in a commit message (agent-fleet is public) — MAJOR 2" || return 1
    assert_not_contains "$msg" " on " "no 'on <machine>' clause at all"
}
run_test "--commit-push: the commit message names no machine" t_commit_message_carries_no_machine_name

t_sweep_skips_template_repos_by_default() {
    pcf_cfg
    local n; for n in tpl-public tpl-corp tpl-pro; do
        pcf_project "$n" --legacy-relative --type config
        : > "$P/.template-repo"      # the fleet's own marker for a template repo (CFG-329)
    done
    pcf_project plain --legacy-inbox
    local out; out=$(run_pc --sweep --fix)
    for n in tpl-public tpl-corp tpl-pro; do
        assert_contains "$out" "$n: SKIPPED (template repo (.template-repo) — Category 3, changes go through template-push or its own session) — left alone: FIX" || return 1
        assert_file_not_exists "$HOME/$n/.githooks/pre-commit" "$n is never touched by the sweep" || return 1
        assert_file_contains "$HOME/$n/CLAUDE.md" 'cross-project/inbox.md` | One-off' || return 1
    done
    assert_contains "$out" "plain: FIXED" "every other project is fixed" || return 1
    out=$(run_pc --sweep)
    assert_contains "$out" "tpl-public: FIX githooks:" "the report still shows their items"
}
run_test "--sweep --fix skips repos carrying the .template-repo marker by default (MAJOR 2)" t_sweep_skips_template_repos_by_default

t_sweep_skips_dirty_mid_merge_detached_behind() {
    pcf_cfg
    pcf_project dirty --legacy-inbox; printf 'an uncommitted hunk\n' >> "$HOME/dirty/CLAUDE.md"
    pcf_project merging --legacy-inbox; git -C "$HOME/merging" rev-parse HEAD > "$HOME/merging/.git/MERGE_HEAD"
    pcf_project detached --legacy-inbox; git -C "$HOME/detached" checkout -q --detach
    pcf_project lagging --legacy-inbox; pcf_bare_remote "$HOME/lagging" >/dev/null; pcf_backfill_upstream "$HOME/lagging" || return 1
    pcf_project clean --legacy-inbox
    local out; out=$(run_pc --sweep --fix --commit-push)
    assert_contains "$out" "dirty: SKIPPED (dirty: CLAUDE.md) — left alone" || return 1
    assert_file_contains "$HOME/dirty/CLAUDE.md" "an uncommitted hunk" || return 1
    assert_eq "1" "$(git -C "$HOME/dirty" rev-list --count HEAD)" "the dirty hunk is never committed (MAJOR 3)" || return 1
    assert_file_not_exists "$HOME/dirty/.githooks/pre-commit" || return 1
    assert_contains "$out" "merging: SKIPPED (merge in progress) — left alone" || return 1
    assert_contains "$out" "detached: SKIPPED (detached HEAD) — left alone" || return 1
    assert_contains "$out" "lagging: SKIPPED (behind upstream by 1 commit(s) — pull first) — left alone" || return 1
    assert_contains "$out" "clean: FIXED" || return 1
    assert_contains "$out" "4 skipped" || return 1
    assert_eq ".githooks/pre-commit CLAUDE.md backlog.md" "$(git -C "$HOME/clean" show --name-only --format= HEAD | tr '\n' ' ' | sed 's/ $//')"
}
run_test "--sweep --fix: dirty target files, a merge in progress, a detached HEAD and a behind branch are skipped and reported (MAJOR 3)" t_sweep_skips_dirty_mid_merge_detached_behind

t_unfixable_findings_do_not_warn() {
    pcf_cfg; pcf_project parent --githooks --knowledge vertical-slicing.md --knowledge needs-to-requirements.md \
        --knowledge test-isolation-guards.md --knowledge anti-chain-state.md --knowledge log-evidence-traps.md --knowledge llm-provider-integration.md
    mkdir -p "$P/child"; pcf_manifest "$P/child/CLAUDE.md" --no-marker --legacy-inbox
    pcf_register child "~/parent/child" code
    local out; out=$(run_pc --sweep)
    assert_contains "$out" "child: NOTE repo: not a repository root" || return 1
    assert_contains "$out" "marker: CLAUDE.md line 1 lacks" "the finding is still shown" || return 1
    assert_contains "$out" "PROJECT_DRIFT: 2 registered, 1 conform, 0 to fix, 0 to file, 0 absent, 1 noted (child)" \
        "a finding nobody can fix or file never keeps the line at WARN (MINOR a)"
}
run_test "--sweep: unfixable findings are noted and leave PROJECT_DRIFT at OK" t_unfixable_findings_do_not_warn

t_sweep_commit_push_co_author() {
    pcf_cfg; pcf_project ca --no-gitignore
    run_pc --sweep --fix --commit-push --co-author "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" >/dev/null
    assert_contains "$(git -C "$P" log -1 --format=%B)" "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
}
run_test "--co-author: the trailer names the model that ran the backfill" t_sweep_commit_push_co_author

t_sweep_skip_and_name_cap() {
    pcf_cfg
    pcf_project upstream --legacy-inbox                   # an upstream clone the backfill must not touch
    pcf_project normal --legacy-inbox
    local i; for i in $(seq 1 12); do pcf_register "ghost$i" "~/ghost$i" code; done
    local out; out=$(run_pc --sweep --fix --skip "upstream,other")
    assert_contains "$out" "upstream: SKIPPED (--skip) — left alone: FIX githooks:" || return 1
    assert_file_not_exists "$HOME/upstream/.githooks/pre-commit" "--skip leaves the tree alone" || return 1
    assert_contains "$out" "normal: FIXED" || return 1
    assert_contains "$out" "12 absent (ghost1, ghost2, ghost3, ghost4, ghost5, ghost6, ghost7, ghost8, ghost9, ghost10, +2 more)" \
        "the summary names at most 10 projects per list" || return 1
    assert_contains "$out" "ghost12: ABSENT" "the per-project lines still carry every one"
}
run_test "--skip leaves named projects alone; the summary caps each name list at 10" t_sweep_skip_and_name_cap

t_commit_push_requires_fix() {
    pcf_cfg
    local rc=0; run_pc --sweep --commit-push >/dev/null || rc=$?
    assert_eq "2" "$rc" "--commit-push without --fix is a usage error"
}
run_test "--commit-push without --fix exits 2" t_commit_push_requires_fix

# ── --trailers ────────────────────────────────────────────────────────────────

t_trailers_mode() {
    pcf_cfg; pcf_project tm --legacy-inbox
    run_pc --project "$P" --fix >/dev/null
    local out; out=$(run_pc --trailers "$P")
    assert_contains "$out" "-m 'Rule-removed: \"| ~/cfg-agent-fleet/cross-project/inbox.md |" || return 1
    assert_contains "$out" "retired-by owner 2026-11-25'" || return 1
    assert_eq "1" "$(printf '%s\n' "$out" | grep -c "^-m 'Rule-removed")"
}
run_test "--trailers: ready-to-paste -m arguments for the rewritten manifest" t_trailers_mode

# ── PROJECT_DRIFT line: date gate + cache (pattern of fleet-drift.sh) ─────────

t_drift_gate_and_cache() {
    pcf_cfg; pcf_project gated --legacy-inbox
    local first second
    first=$(run_pc --if-due)
    assert_contains "$first" "PROJECT_DRIFT[WARN]: 1 registered, 0 conform, 1 to fix (gated)" || return 1
    assert_contains "$first" "probed $(date +%Y-%m-%d)" || return 1
    run_pc --project "$P" --fix >/dev/null                           # the tree changes…
    second=$(run_pc --if-due)
    assert_eq "$first" "$second" "…but a gated session reads the cache, not the tree" || return 1
    assert_contains "$(run_pc --force)" "PROJECT_DRIFT[WARN]: 1 registered, 0 conform, 0 to fix, 1 to file (gated)" "--force re-probes" || return 1
    assert_contains "$(run_pc --status)" "1 to file (gated)" "--status renders the cache only"
}
run_test "--if-due: probes once a day, then renders the cache; --force re-probes" t_drift_gate_and_cache

t_drift_never_probed() {
    pcf_cfg
    assert_contains "$(run_pc --status)" "PROJECT_DRIFT[WARN]: never probed on this machine"
}
run_test "--status without a cache says so, never silence" t_drift_never_probed

# ── Decision Q-1094-GITHOOKS: the copied hook RUNS through the global dispatcher ──

t_copied_hook_runs_via_dispatcher() {
    pcf_cfg; pcf_project disp
    # The fleet dispatcher as install-git-hooks.sh arms it: global core.hooksPath → ~/.claude/hooks/git
    mkdir -p "$HOME/.claude/hooks"
    ln -s "$REPO_ROOT/global/hooks/git" "$HOME/.claude/hooks/git"
    git config --global core.hooksPath "$HOME/.claude/hooks/git"
    run_pc --project "$P" --fix >/dev/null
    assert_eq "" "$(git -C "$P" config --local --get core.hooksPath || true)" "with the dispatcher armed no local hooksPath is set (CFG-892)" || return 1
    git -C "$P" add -A >/dev/null; git -C "$P" commit -qm "arm" >/dev/null
    mkdir -p "$P/data"; local i; for i in $(seq 1 151); do printf '%s\n' "$i" > "$P/data/f$i.txt"; done
    git -C "$P" add -A
    local rc=0 out; out=$(git -C "$P" commit -qm bulk 2>&1) || rc=$?
    assert_neq "0" "$rc" "151 staged files must be refused through the dispatcher chain" || return 1
    assert_contains "$out" "commit-size guard" || return 1
    assert_contains "$out" "151" "the refusal prints the measured count" || return 1
    git -C "$P" reset -q -- data/f151.txt
    git -C "$P" commit -qm bulk150 >/dev/null 2>&1 || { echo "    150 files must pass" >&2; return 1; }
}
run_test "the copied .githooks/pre-commit is chained by the global dispatcher and blocks 151 files" t_copied_hook_runs_via_dispatcher

# ── Real project trees (Pattern 11) ───────────────────────────────────────────

# _real_tree_invariants <clone> <name> <type> — fix converges, touches only the allowed paths,
# every changed manifest line carried a retired name before, deliberate mentions stay.
_real_tree_invariants() {
    local c="$1" name="$2" type="$3" m rel before
    m=$(pcf_run_lib pc_manifest "$c") || { echo "    no manifest in $c" >&2; return 1; }
    rel="${m#"$c"/}"
    before=$(git -C "$c" show "HEAD:$rel")
    run_pc --project "$c" --name "$name" --type "$type" --fix --file-backlog >/dev/null
    local changed; changed=$(git -C "$c" status --porcelain | awk '{print $2}' | sort | tr '\n' ' ')
    local p bad=""
    for p in $changed; do
        case "$p" in "$rel"|.githooks/|.githooks/pre-commit|.gitignore|backlog.md) ;; *) bad="$bad $p" ;; esac
    done
    assert_eq "" "$bad" "only the manifest, .githooks/pre-commit, .gitignore and backlog.md may change ($name)" || return 1
    # Changed manifest lines: each old line named a retired name, each new line the replacement.
    local oldl newl
    oldl=$(diff <(printf '%s\n' "$before") "$m" | grep '^<' | grep -vc 'cross-project/inbox\.md' || true)
    newl=$(diff <(printf '%s\n' "$before") "$m" | grep '^>' | grep -vc 'cross-project/inbox/<project>\.md' || true)
    assert_eq "0" "$oldl" "every removed manifest line carried the retired name ($name)" || return 1
    assert_eq "0" "$newl" "every added manifest line carries the replacement ($name)" || return 1
    local again; again=$(run_pc --project "$c" --name "$name" --type "$type" --fix)
    assert_eq "" "$(printf '%s\n' "$again" | grep '^FIXED|' || true)" "the fix converges on a real tree ($name)" || return 1
    case " $changed " in *" .githooks/"*|*" .githooks/pre-commit "*)
        cmp -s "$c/.githooks/pre-commit" "$PC_TEMPLATE_HOOK" || { echo "    a copied hook must be the template's ($name)" >&2; return 1; } ;;
    esac
}

t_real_tree_cfg() {
    local c="$TEST_TMPDIR/real-cfg"
    pcf_sparse_clone "$REPO_ROOT" "$c" || { echo "    could not clone $REPO_ROOT" >&2; return 1; }
    _real_tree_invariants "$c" cfg-agent-fleet config || return 1
    # The config repo's manifest describes the legacy inbox file on purpose; that row stays.
    assert_file_contains "$c/CLAUDE.md" '^| `cross-project/inbox.md` | Legacy spillover queue' \
        "the deliberate legacy mention in the real cfg manifest is kept (keep-when)"
}
# The config repo's own tree and its legacy-inbox manifest row exist only there (CFG-1147: this file ships verbatim to
# the public template, whose suite went red on it): run where registry.md lists the config repo, skip elsewhere.
if grep -q '^| cfg-agent-fleet |' "$REPO_ROOT/registry.md" 2>/dev/null; then
    run_test "real tree: a sparse clone of this repo — converges, deliberate legacy row kept" t_real_tree_cfg
else
    skip_test "real tree: a sparse clone of this repo" "this repo is not the config repo (no cfg-agent-fleet row in its registry.md)"
fi

# The first registered sibling project checked out on this machine (from the real registry, not a
# name list), chosen before the HOME sandbox applies; this repo's own main checkout is excluded.
REAL_SIBLING=""; REAL_SIBLING_NAME=""; REAL_SIBLING_TYPE="code"
_own_main="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)"; _own_main="$(cd "$(dirname "$_own_main")" 2>/dev/null && pwd -P)"
while IFS='|' read -r _n _p _t; do
    [ -n "$_p" ] && [ -d "$_p/.git" ] || continue
    [ "$(cd "$_p" && pwd -P)" != "$_own_main" ] || continue
    REAL_SIBLING="$_p"; REAL_SIBLING_NAME="$_n"; REAL_SIBLING_TYPE="$_t"; break
done < <(PC_REGISTRY="$REPO_ROOT/registry.md" bash -c 'source "$1"; pc_registry_rows' _ "$PC_LIB" 2>/dev/null)
t_real_tree_sibling() {
    local c="$TEST_TMPDIR/real-sibling"
    pcf_sparse_clone "$REAL_SIBLING" "$c" || { echo "    could not clone $REAL_SIBLING" >&2; return 1; }
    _real_tree_invariants "$c" "$REAL_SIBLING_NAME" "$REAL_SIBLING_TYPE"
}
if [ -n "$REAL_SIBLING" ]; then
    run_test "real tree: the first registered sibling present here ($REAL_SIBLING_NAME) — same invariants" t_real_tree_sibling
else
    skip_test "real tree: a sibling project" "no registered sibling project is checked out on this machine"
fi

suite_summary
