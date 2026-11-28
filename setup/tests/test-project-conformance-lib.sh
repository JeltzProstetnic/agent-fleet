#!/usr/bin/env bash
# Tests for setup/scripts/project-conformance-lib.sh — CFG-1094.
#
# The spec a project is checked against is DERIVED from the templates and conf files of this
# repo (marker line, .githooks/pre-commit, project-gitignore.conf, project-type-knowledge.conf
# by registry type, retired-names.conf), so a template addition extends the check with no
# code change. Mechanical items are fixed in place; everything else is one idempotent backlog
# item. The ONLY CLAUDE.md text the fix may rewrite is a pointer to a retired name
# (Q-1094-INBOX, owner decision of 2026-11-25); the marker and knowledge rows are never written.
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/lib-pc-fixture.sh"

suite_header "project-conformance-lib.sh (CFG-1094: spec from the templates, fixes in place)"

_check() { pcf_run_lib pc_check "$P" "$1" "${2:-code}"; }
_fix()   { pcf_run_lib pc_fix "$P" "$1" "${2:-code}"; }

# ── Registry ──────────────────────────────────────────────────────────────────

t_registry_rows_real() {
    local rows expected
    rows=$(PC_REGISTRY="$REPO_ROOT/registry.md" pcf_run_lib pc_registry_rows)
    assert_contains "$rows" "cfg-agent-fleet|$HOME/cfg-agent-fleet|config" "the config repo row, ~ expanded" || return 1
    [ "$(printf '%s\n' "$rows" | grep -c "|$HOME/[^/|]*/[^/|]*|")" -ge 1 ] || { echo "    no nested project row found" >&2; return 1; }
    [ "$(printf '%s\n' "$rows" | grep -c ' + ')" -ge 1 ] || { echo "    no compound-type row found" >&2; return 1; }
    assert_eq "0" "$(printf '%s\n' "$rows" | grep -vc '^[^|]*|/')" "every emitted row has an absolute path (rows without one are not projects on any machine)" || return 1
    # Exactly the Projects-table rows whose FIRST backticked token is a ~/ or / path (a row whose
    # cell only mentions a path in prose is not a project here) — the Machines table contributes none.
    expected=$(awk -F'|' '/^## /{p=($0 ~ /^## Projects/)} p && /^\| / && match($5, /`[^`]+`/) { t=substr($5, RSTART+1, RLENGTH-2); if (t ~ /^(~\/|\/)/) n++ } END{print n+0}' "$REPO_ROOT/registry.md")
    assert_eq "$expected" "$(printf '%s\n' "$rows" | grep -c .)" "one row per pathed project, nothing from other tables"
}
# The config repo's registry (its own row, nested and compound-type rows, the `## Projects` table) exists only there
# (CFG-1147: this file ships verbatim to the public template, whose local registry.md is a short other table).
if grep -q '^| cfg-agent-fleet |' "$REPO_ROOT/registry.md" 2>/dev/null; then
    run_test "registry rows: real registry.md yields name|path|type for every pathed project" t_registry_rows_real
else
    skip_test "registry rows: the real registry.md" "this repo is not the config repo (no cfg-agent-fleet row in its registry.md)"
fi

t_registry_lookup_by_dir() {
    pcf_cfg; pcf_project alpha
    local hit; hit=$(pcf_run_lib pc_registry_lookup "$P")
    assert_eq "alpha|$P|code" "$hit" "a project is found by its path" || return 1
    mkdir -p "$HOME/stranger"
    assert_failure pcf_run_lib pc_registry_lookup "$HOME/stranger"
}
run_test "registry lookup: by directory, unregistered dirs are refused" t_registry_lookup_by_dir

# ── Spec pieces ───────────────────────────────────────────────────────────────

t_gitignore_has_variants() {
    local gi="$TEST_TMPDIR/gi"
    printf 'node_modules/\r\ntmp/\r\n/docs/terminal-logs/\r\n' > "$gi"
    pcf_run_lib pc_gitignore_has "$gi" "tmp/" || { echo "    CRLF line not matched (CFG-1116)" >&2; return 1; }
    pcf_run_lib pc_gitignore_has "$gi" "docs/terminal-logs/" || { echo "    a leading slash is the same ignore" >&2; return 1; }
    assert_failure pcf_run_lib pc_gitignore_has "$gi" ".claude/.session-lock" || return 1
    assert_failure pcf_run_lib pc_gitignore_has "$TEST_TMPDIR/nope" "tmp/"
}
run_test "gitignore matcher: CRLF-tolerant, leading slash equivalent, missing file is a miss" t_gitignore_has_variants

t_retired_conf_is_read() {
    local blocks; blocks=$(pcf_run_lib pc_retired_blocks)
    assert_contains "$blocks" "cross-project/inbox.md" "the retired inbox file is a block" || return 1
    assert_eq "cross-project/inbox/<project>.md" "$(pcf_run_lib pc_retired_field 'cross-project/inbox.md' replacement)" || return 1
    assert_eq "owner" "$(pcf_run_lib pc_retired_field 'cross-project/inbox.md' approver)" "a role word keeps the conf generic across installations" || return 1
    assert_eq "2026-11-25" "$(pcf_run_lib pc_retired_field 'cross-project/inbox.md' since)"
}
run_test "retired-names.conf: blocks and fields are read" t_retired_conf_is_read

# ── pc_check ──────────────────────────────────────────────────────────────────

t_conforming_is_clean() {
    pcf_cfg; pcf_project clean --githooks --knowledge vertical-slicing.md --knowledge needs-to-requirements.md \
        --knowledge test-isolation-guards.md --knowledge anti-chain-state.md --knowledge log-evidence-traps.md \
        --knowledge llm-provider-integration.md
    local out; out=$(_check clean)
    assert_eq "" "$(printf '%s\n' "$out" | grep -E '^(FIX|FILE)\|' || true)" "a conforming project has nothing to fix or file: $out"
}
run_test "check: a project matching the templates reports nothing" t_conforming_is_clean

t_check_flags_each_shape() {
    pcf_cfg; pcf_project drift --no-marker --legacy-inbox --legacy-prose --keep-mention --no-gitignore --tracked-tmp 3
    local out; out=$(_check drift)
    assert_contains "$out" "FIX|githooks|.githooks/pre-commit missing" || return 1
    assert_contains "$out" "FIX|gitignore|.gitignore lacks: tmp/, .claude/.session-lock, .claude/.session-role.*, docs/terminal-logs/" || return 1
    assert_contains "$out" "FIX|retired|CLAUDE.md: 3 line(s) point at retired cross-project/inbox.md" "the kept legacy mention is not counted" || return 1
    assert_contains "$out" "FILE|marker|CLAUDE.md line 1 lacks the agent-fleet-managed marker" || return 1
    assert_contains "$out" "FILE|knowledge|Knowledge Loading lacks the code rows: vertical-slicing.md, needs-to-requirements.md, test-isolation-guards.md, anti-chain-state.md, log-evidence-traps.md, llm-provider-integration.md" || return 1
    assert_contains "$out" "FILE|tmp|3 tracked file(s) under tmp/" || return 1
    assert_not_contains "$out" "FIXED|" "check never fixes"
}
run_test "check: every drift shape is reported with its kind and the measured value" t_check_flags_each_shape

t_check_githooks_variants() {
    pcf_cfg; pcf_project noexec --githooks-noexec
    assert_contains "$(_check noexec)" "FIX|githooks|.githooks/pre-commit not executable" || return 1
    pcf_project custom --githooks-custom
    local out; out=$(_check custom)
    assert_contains "$out" "NOTE|githooks|.githooks/pre-commit differs from the template (the project's own hook — kept, never overwritten)" \
        "a project's own hook (a credential guard of its own) is a note, not a finding" || return 1
    assert_not_contains "$out" "FILE|githooks" "no backlog item for it" || return 1
    _fix custom >/dev/null
    assert_eq "#!/usr/bin/env bash" "$(head -1 "$P/.githooks/pre-commit")" "and it is never overwritten by the fix" || return 1
    assert_eq "2" "$(wc -l < "$P/.githooks/pre-commit")"
}
run_test "check: a non-executable hook is mechanical, a diverged one is a NOTE and stays" t_check_githooks_variants

# ── Knowledge rows: a file the GLOBAL CLAUDE.md already triggers is covered ───────────────────

t_knowledge_globally_triggered_is_covered() {
    pcf_cfg; pcf_global_rows prose-register.md deliverable-authoring.md word-editing-extraction.md office-templates.md
    pcf_project w1 --type writing
    local out; out=$(_check w1 writing)
    assert_contains "$out" "FILE|knowledge|Knowledge Loading lacks the writing rows: print-production.md, kdp-publishing.md, cover-design.md" \
        "only the files no global trigger row names are demanded" || return 1
    pcf_global_rows print-production.md kdp-publishing.md cover-design.md
    out=$(_check w1 writing)
    assert_not_contains "$out" "FILE|knowledge" "a new global row removes the finding with no code change: $out"
}
run_test "knowledge: a file named in the global CLAUDE.md's trigger table is covered" t_knowledge_globally_triggered_is_covered

t_knowledge_against_real_global_claude_md() {
    pcf_cfg; pcf_project w2 --type writing
    local expected="" f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        grep -q "knowledge/$f" "$REPO_ROOT/global/CLAUDE.md" || expected="${expected:+$expected, }$f"
    done < <(pcf_run_lib pc_type_files writing)
    local out; out=$(PC_GLOBAL_CLAUDE="$REPO_ROOT/global/CLAUDE.md" pcf_run_lib pc_check "$P" w2 writing)
    assert_eq "$expected" "$(printf '%s\n' "$out" | sed -n 's/^FILE|knowledge|Knowledge Loading lacks the writing rows: //p')" \
        "against the real global CLAUDE.md the demanded set is the type's files minus the globally triggered ones" || return 1
    assert_contains "$expected" "print-production.md" "the research finding: print-production is a real gap today"
}
run_test "knowledge: with the real global/CLAUDE.md, writing demands exactly the untriggered files" t_knowledge_against_real_global_claude_md

t_knowledge_default_is_deployed_global() {
    pcf_cfg; unset PC_GLOBAL_CLAUDE
    mkdir -p "$HOME/.claude"
    printf '| t | `knowledge/vertical-slicing.md` |\n' > "$HOME/.claude/CLAUDE.md"
    pcf_project d1
    local out; out=$(_check d1)
    assert_not_contains "$out" "vertical-slicing.md" "the deployed ~/.claude/CLAUDE.md is what a session reads" || return 1
    assert_contains "$out" "needs-to-requirements.md"
}
run_test "knowledge: without the seam the deployed ~/.claude/CLAUDE.md decides" t_knowledge_default_is_deployed_global

t_check_compound_type_union() {
    pcf_cfg; pcf_project comp --type "business + writing" --knowledge prose-register.md
    local out; out=$(_check comp "business + writing")
    assert_contains "$out" "Knowledge Loading lacks the business + writing rows:" || return 1
    assert_contains "$out" "deliverable-authoring.md" || return 1
    assert_contains "$out" "kdp-publishing.md" "writing rows are part of the union" || return 1
    assert_not_contains "$out" "prose-register.md" "a row already present is not demanded"
}
run_test "check: compound registry types take the union of their knowledge rows" t_check_compound_type_union

t_check_manifest_missing_and_nested() {
    pcf_cfg; pcf_project bare --no-manifest
    assert_contains "$(_check bare)" "NOTE|manifest|no CLAUDE.md" || return 1
    pcf_project parent; mkdir -p "$P/child"; pcf_manifest "$P/child/CLAUDE.md"
    local out; out=$(pcf_run_lib pc_check "$P/child" child code)
    assert_contains "$out" "NOTE|repo|not a repository root" || return 1
    assert_not_contains "$out" "FIX|githooks" "git items are the parent repo's business" || return 1
    : > "$HOME/parent/.mobile-repo"
    assert_contains "$(pcf_run_lib pc_check "$HOME/parent" parent code)" "NOTE|repo|mobile snapshot"
}
run_test "check: no manifest is filed; nested dirs and the mobile snapshot skip git items" t_check_manifest_missing_and_nested

t_check_dotclaude_manifest() {
    pcf_cfg; pcf_project dot --dotclaude --legacy-inbox
    assert_contains "$(_check dot)" "FIX|retired|.claude/CLAUDE.md: 1 line(s) point at retired cross-project/inbox.md"
}
run_test "check: a manifest under .claude/ is found first, as check 10 does" t_check_dotclaude_manifest

# ── pc_fix ────────────────────────────────────────────────────────────────────

t_fix_githooks_and_gitignore() {
    pcf_cfg; pcf_project fx --no-gitignore
    printf 'build/\n' > "$P/.gitignore"      # existing file without a trailing newline problem
    printf 'dist/' >> "$P/.gitignore"        # … and now without one
    local out; out=$(_fix fx)
    assert_contains "$out" "FIXED|githooks|.githooks/pre-commit copied from the template" || return 1
    cmp -s "$P/.githooks/pre-commit" "$PC_TEMPLATE_HOOK" || { echo "    copied hook differs from the template" >&2; return 1; }
    [ -x "$P/.githooks/pre-commit" ] || { echo "    copied hook is not executable" >&2; return 1; }
    assert_contains "$out" "FIXED|gitignore|.gitignore +4 line(s): tmp/, .claude/.session-lock, .claude/.session-role.*, docs/terminal-logs/" || return 1
    assert_eq "build/ dist/ tmp/ .claude/.session-lock .claude/.session-role.* docs/terminal-logs/" "$(tr '\n' ' ' < "$P/.gitignore" | sed 's/ $//')" \
        "lines appended after the existing ones, the missing newline supplied first"
}
run_test "fix: copies the template hook executable, tops up .gitignore" t_fix_githooks_and_gitignore

t_fix_gitignore_keeps_crlf() {
    pcf_cfg; pcf_project crlf --gitignore-crlf
    sed -i '/session-lock/d' "$P/.gitignore"
    _fix crlf >/dev/null
    assert_eq "1" "$(grep -c $'\\.claude/\\.session-lock\r$' "$P/.gitignore")" "the appended line takes the file's CRLF ending" || return 1
    assert_eq "0" "$(grep -c $'[^\r]$' "$P/.gitignore")" "no line left with a bare LF (no mixed endings)"
}
run_test "fix: a CRLF .gitignore gets CRLF lines (CFG-1116)" t_fix_gitignore_keeps_crlf

t_fix_chmod_only() {
    pcf_cfg; pcf_project nx --githooks-noexec
    assert_contains "$(_fix nx)" "FIXED|githooks|.githooks/pre-commit made executable" || return 1
    [ -x "$P/.githooks/pre-commit" ] || return 1
}
run_test "fix: a present but non-executable hook is only chmod-ed" t_fix_chmod_only

t_fix_rewrites_legacy_pointer_exactly() {
    pcf_cfg; pcf_project rw --legacy-inbox --legacy-prose --legacy-relative --keep-mention
    cp "$P/CLAUDE.md" "$TEST_TMPDIR/before.md"
    local out; out=$(_fix rw)
    assert_contains "$out" "FIXED|retired|CLAUDE.md: 4 line(s) rewritten from cross-project/inbox.md to cross-project/inbox/<project>.md" || return 1
    assert_file_contains "$P/CLAUDE.md" '^| `~/cfg-agent-fleet/cross-project/inbox/<project>.md`, filed with `bash ~/cfg-agent-fleet/setup/scripts/inbox-file.sh --project <p> --type <t> --body "…"` | Cross-project tasks |$' \
        "the table row keeps its description and gains the filing command (wording of b62154e5, global CLAUDE.md's <t>)" || return 1
    assert_file_contains "$P/CLAUDE.md" '^| `cross-project/inbox/<project>.md`, filed with `bash setup/scripts/inbox-file.sh --project <p> --type <t> --body "…"` | One-off cross-project tasks (transient, picked up and deleted) |$' \
        "a repo-relative mention gets a repo-relative filing command" || return 1
    assert_file_contains "$P/CLAUDE.md" 'cross-project notes go via `~/cfg-agent-fleet/cross-project/inbox/<project>.md`, filed with `bash ~/cfg-agent-fleet/setup/scripts/inbox-file.sh --project <p> --type <t> --body "…"`\.$' \
        "prose keeps its sentence end" || return 1
    # MAJOR 5: a table row must keep its cell count — an unescaped | in the suffix would split it.
    assert_eq "$(printf '%s' "$PC_LEGACY_ROW" | tr -cd '|' | wc -c)" "$(grep 'inbox/<project>.md`, filed with .* | Cross-project tasks |$' "$P/CLAUDE.md" | tr -cd '|' | wc -c)" \
        "the rewritten row has exactly as many | as the original" || return 1
    assert_file_contains "$P/CLAUDE.md" 'post task to `~/cfg-agent-fleet/cross-project/inbox/<project>.md`, filed with `bash ~/cfg-agent-fleet/setup/scripts/inbox-file.sh [^`]*` targeting \*\*sibling\*\*$' || return 1
    assert_file_contains "$P/CLAUDE.md" '^| `cross-project/inbox.md` | Legacy spillover queue — still read alongside the per-project files |$' \
        "a deliberate mention (keep-when word) is left alone" || return 1
    # Only the four pointer lines changed; the manifest is otherwise byte-identical.
    local changed; changed=$(diff "$TEST_TMPDIR/before.md" "$P/CLAUDE.md" | grep -c '^<' || true)
    assert_eq "4" "$changed" "exactly four lines differ" || return 1
    assert_eq "$(head -1 "$TEST_TMPDIR/before.md")" "$(head -1 "$P/CLAUDE.md")" "line 1 (marker) untouched"
}
run_test "fix: rewrites every legacy inbox pointer, in place, with the approved wording" t_fix_rewrites_legacy_pointer_exactly

t_fix_rewrite_keeps_crlf_manifest() {
    pcf_cfg; pcf_project mc --legacy-inbox --crlf
    _fix mc >/dev/null
    assert_eq "0" "$(grep -c $'[^\r]$' "$P/CLAUDE.md")" "a CRLF manifest stays CRLF on every line" || return 1
    assert_file_contains "$P/CLAUDE.md" 'inbox/<project>.md'
}
run_test "fix: a CRLF manifest keeps its line endings" t_fix_rewrite_keeps_crlf_manifest

t_fix_never_writes_marker_or_knowledge() {
    pcf_cfg; pcf_project nm --no-marker
    cp "$P/CLAUDE.md" "$TEST_TMPDIR/before.md"
    _fix nm >/dev/null
    cmp -s "$TEST_TMPDIR/before.md" "$P/CLAUDE.md" || { echo "    CLAUDE.md was edited although it carried no retired pointer" >&2; return 1; }
    assert_not_contains "$(_check nm)" "FIX|marker" "the marker is never a mechanical fix (its absence is check 12's /init signal)"
}
run_test "fix: never inserts the marker or knowledge rows into CLAUDE.md" t_fix_never_writes_marker_or_knowledge

t_fix_idempotent_and_lists_files() {
    pcf_cfg; pcf_project idem --legacy-inbox --no-gitignore
    local out; out=$( ( source "$PC_LIB"; pc_fix "$P" idem code >/dev/null; printf '%s' "$PC_CHANGED_FILES" ) )
    assert_eq ".githooks/pre-commit .gitignore CLAUDE.md" "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/ $//')" "PC_CHANGED_FILES names exactly what was written" || return 1
    git -C "$P" add -A >/dev/null; git -C "$P" commit -qm fixed >/dev/null
    out=$(_fix idem)
    assert_eq "" "$out" "a second fix finds nothing: $out" || return 1
    assert_eq "" "$(git -C "$P" status --porcelain)" "and writes nothing"
}
run_test "fix: idempotent, and reports the files it changed" t_fix_idempotent_and_lists_files

# ── MAJOR 4: which CLAUDE.md is the manifest ─────────────────────────────────

t_manifest_is_the_marked_file() {
    pcf_cfg; pcf_project two --legacy-inbox                      # root manifest with the marker
    pcf_manifest "$P/.claude/CLAUDE.md" --no-marker --legacy-inbox   # a rules file under .claude/
    git -C "$P" add -A >/dev/null; git -C "$P" commit -qm rules >/dev/null
    assert_eq "$P/CLAUDE.md" "$(pcf_run_lib pc_manifest "$P")" "the file whose line 1 carries the marker is the manifest" || return 1
    local out; out=$(_check two)
    assert_not_contains "$out" "FILE|marker" "the marked root manifest means no marker item" || return 1
    assert_contains "$out" "FIX|retired|CLAUDE.md: 1 line(s)" || return 1
    cp "$P/.claude/CLAUDE.md" "$TEST_TMPDIR/rules-before.md"
    _fix two >/dev/null
    assert_file_contains "$P/CLAUDE.md" 'inbox/<project>.md' "the root pointer is rewritten" || return 1
    cmp -s "$TEST_TMPDIR/rules-before.md" "$P/.claude/CLAUDE.md" || { echo "    .claude/CLAUDE.md (a rules file) was touched" >&2; return 1; }
    # Neither marked: the root wins; only .claude/ present: that one.
    sed -i '1d' "$P/CLAUDE.md"
    assert_eq "$P/CLAUDE.md" "$(pcf_run_lib pc_manifest "$P")" || return 1
    rm "$P/CLAUDE.md"
    assert_eq "$P/.claude/CLAUDE.md" "$(pcf_run_lib pc_manifest "$P")"
}
run_test "manifest: the file with the marker on line 1 wins; else root, else .claude/ (a rules file under .claude/)" t_manifest_is_the_marked_file

# ── MINOR (c): atomic write that keeps mode, final-newline state and line endings ──

t_fix_keeps_mode_and_final_newline() {
    pcf_cfg; pcf_project atom --legacy-inbox
    printf '%s' "$(cat "$P/CLAUDE.md")" > "$P/CLAUDE.md"     # no final newline
    chmod 600 "$P/CLAUDE.md"
    _fix atom >/dev/null
    assert_eq "600" "$(stat -c %a "$P/CLAUDE.md")" "the mode survives the rewrite" || return 1
    [ -n "$(tail -c1 "$P/CLAUDE.md")" ] || { echo "    a final newline was added to a file that had none" >&2; return 1; }
    assert_file_contains "$P/CLAUDE.md" 'inbox/<project>.md' || return 1
    assert_eq "0" "$(find "$P" -maxdepth 1 -name '.CLAUDE.md.*' | wc -l | tr -d ' ')" "no temp file left behind"
}
run_test "fix: rewrite is atomic, keeps mode and the missing final newline" t_fix_keeps_mode_and_final_newline

# ── MAJOR 1: never add what the upstream already has ─────────────────────────

t_fix_skips_what_upstream_already_has() {
    pcf_cfg; pcf_project up --legacy-inbox --no-gitignore
    pcf_bare_remote "$P" >/dev/null
    pcf_backfill_upstream "$P" || { echo "    fixture: backfill upstream failed" >&2; return 1; }
    assert_eq "1" "$(pcf_run_lib pc_behind_count "$P")" "HEAD is one commit behind the fetched upstream" || return 1
    local out; out=$(_fix up)
    assert_eq "" "$out" "nothing is written when @{u} already carries the hook, the lines and the rewrite: $out" || return 1
    assert_file_not_exists "$P/.githooks/pre-commit" || return 1
    assert_file_not_exists "$P/.gitignore" || return 1
    assert_file_contains "$P/CLAUDE.md" 'cross-project/inbox.md` | Cross-project tasks' "the manifest is left for the pull"
}
run_test "fix: adds nothing the fetched upstream already has (the pull would collide)" t_fix_skips_what_upstream_already_has

# ── MINOR (a): findings nobody can fix or file are notes ──────────────────────

t_unfixable_findings_are_notes() {
    pcf_cfg; pcf_project parent; mkdir -p "$P/child"; pcf_manifest "$P/child/CLAUDE.md" --no-marker --legacy-inbox
    local out; out=$(pcf_run_lib pc_check "$P/child" child code)
    assert_eq "" "$(printf '%s\n' "$out" | grep -E '^(FIX|FILE)\|' || true)" "a nested dir's findings cannot be fixed or filed: $out" || return 1
    assert_contains "$out" "NOTE|marker|" || return 1
    assert_contains "$out" "NOTE|retired|" || return 1
    pcf_project nomani --no-manifest
    out=$(_check nomani)
    assert_contains "$out" "NOTE|manifest|no CLAUDE.md" "no manifest cannot be filed anywhere" || return 1
    assert_contains "$out" "FIX|githooks|" "but the git items of a repo root stay fixable"
}
run_test "check: nested/mobile and no-manifest findings are NOTE, not FIX/FILE" t_unfixable_findings_are_notes

# ── Backlog item (check-10 precedent) ─────────────────────────────────────────

t_backlog_item_filed_once() {
    pcf_cfg; pcf_project bl
    local r; r=$(pcf_run_lib pc_file_backlog "$P" bl "knowledge rows missing: a.md; 3 tracked file(s) under tmp/")
    assert_eq "FILED|FIX-13" "$r" "next free ID under the backlog's own prefix" || return 1
    assert_file_contains "$P/backlog.md" '^- \[ \] \[P2\] `FIX-13` \*\*Project conformance\*\*: knowledge rows missing: a.md; 3 tracked file(s) under tmp/\. .*CFG-1094' \
        "the item is P2 (Q-1094-ITEMPRIO, owner 2026-11-25); check 10's own item stays P1" || return 1
    local open_line done_line
    open_line=$(grep -n 'Project conformance' "$P/backlog.md" | head -1 | cut -d: -f1)
    done_line=$(grep -n '^## Done' "$P/backlog.md" | cut -d: -f1)
    [ "$open_line" -lt "$done_line" ] || { echo "    item landed under Done" >&2; return 1; }
    r=$(pcf_run_lib pc_file_backlog "$P" bl "other text")
    assert_eq "TRACKED" "$r" "an open item suppresses a second one" || return 1
    assert_eq "1" "$(grep -c 'Project conformance' "$P/backlog.md")"
}
run_test "backlog: one P2 'Project conformance' item under Open, idempotent" t_backlog_item_filed_once

# ── Opt-out marker (Q-1094-SEARXNG, owner 2026-11-25) ────────────────────────

t_opt_out_marker_stops_everything() {
    pcf_cfg; pcf_project optout --legacy-inbox --no-gitignore --no-marker --tracked-tmp 2
    printf 'upstream clone — not ours to conform\n' > "$P/.fleet-conformance-skip"
    git -C "$P" add .fleet-conformance-skip >/dev/null; git -C "$P" commit -qm marker >/dev/null
    local out; out=$(_check optout)
    assert_eq "NOTE|opted-out|.fleet-conformance-skip present — nothing checked, fixed or filed" "$out" \
        "an opted-out project yields exactly one NOTE, whatever its content would have been: $out" || return 1
    _fix optout >/dev/null
    assert_eq "" "$(git -C "$P" status --porcelain)" "the fix writes nothing there" || return 1
    assert_file_not_exists "$P/.githooks/pre-commit" || return 1
    : > "$P/.fleet-conformance-skip"      # content is ignored: an empty marker opts out too
    assert_contains "$(_check optout)" "NOTE|opted-out|"
}
run_test "opt-out: a .fleet-conformance-skip in the project root stops the check and the fix" t_opt_out_marker_stops_everything

t_backlog_created_when_missing() {
    pcf_cfg; pcf_project nobl; rm -f "$P/backlog.md"
    local r; r=$(pcf_run_lib pc_file_backlog "$P" nobl "x")
    assert_eq "FILED|backlog.md" "$r" || return 1
    assert_file_contains "$P/backlog.md" "Project conformance"
}
run_test "backlog: created when the project has none" t_backlog_created_when_missing

# ── Trailers: what the rule-removal guard will demand ─────────────────────────

t_trailers_match_the_guard() {
    pcf_cfg; pcf_project tr --legacy-inbox --legacy-prose
    _fix tr >/dev/null
    local trailers; trailers=$(pcf_run_lib pc_trailers "$P")
    assert_eq "3" "$(printf '%s\n' "$trailers" | grep -c '^Rule-removed: ".*" retired-by owner 2026-11-25$')" "one trailer per rewritten rule unit, approver and date from the conf: $trailers" || return 1
    local args=() t
    while IFS= read -r t; do [ -n "$t" ] && args+=(-m "$t"); done <<< "$trailers"
    git -C "$P" add -A >/dev/null
    git -C "$P" commit -q -m "rewrite" "${args[@]}" >/dev/null
    bash "$REPO_ROOT/global/hooks/rule-removal-guard.sh" --replay HEAD "$P" >/dev/null 2>&1 \
        || { echo "    the guard would have blocked a commit carrying our trailers" >&2; bash "$REPO_ROOT/global/hooks/rule-removal-guard.sh" --replay HEAD "$P" >&2; return 1; }
    # Negative control: the same change without trailers is what the guard exists to refuse.
    git -C "$P" reset -q --soft HEAD^; git -C "$P" commit -q -m "rewrite, no trailers" >/dev/null
    assert_failure bash "$REPO_ROOT/global/hooks/rule-removal-guard.sh" --replay HEAD "$P"
}
run_test "trailers: exactly what rule-removal-guard.sh accepts for the rewrite" t_trailers_match_the_guard

t_trailers_only_for_our_rewrites() {
    pcf_cfg; pcf_project tro --legacy-inbox
    _fix tro >/dev/null
    sed -i '/contacts.md/d' "$P/CLAUDE.md"      # a hand-made removal in the same tree
    local trailers; trailers=$(pcf_run_lib pc_trailers "$P")
    assert_eq "1" "$(printf '%s\n' "$trailers" | grep -c '^Rule-removed')" "only the retired-name rewrite gets a trailer" || return 1
    assert_not_contains "$trailers" "contacts" "a removal that is not ours is never explained away"
}
run_test "trailers: never written for removals the retired-names rewrite did not cause" t_trailers_only_for_our_rewrites

# ── Live-session probe (read-only) ────────────────────────────────────────────

t_live_session_probe() {
    pcf_cfg; pcf_project ls
    assert_eq "free" "$(pcf_run_lib pc_live_session "$P")" "no lock, no live session" || return 1
    pcf_lock "$P" "$$"
    assert_contains "$(pcf_run_lib pc_live_session "$P")" "held: lock pid $$ alive" || return 1
    pcf_lock "$P" 2147483646
    assert_eq "free" "$(pcf_run_lib pc_live_session "$P")" "a dead pid and no live session is free" || return 1
    assert_file_exists "$P/.claude/.session-lock" "the probe never removes a lock, stale or not" || return 1
    pcf_lock "$P" 1 "another-machine"
    assert_contains "$(pcf_run_lib pc_live_session "$P")" "held: lock by another-machine"
}
run_test "live-session probe: lock pid, other machine, never removes a lock" t_live_session_probe

suite_summary
