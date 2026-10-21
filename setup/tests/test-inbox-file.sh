#!/usr/bin/env bash
# Tests for CFG-541: inbox filing helper + type-tag convention.
#
# The tag makes the queue drainable: a receiving session dispatches [fact] without
# deliberating instead of meeting N items of unknown and unequal cost. The helper
# exists so the tag is MECHANICAL rather than remembered — a convention nobody can
# forget is the only kind that survives (design-inbox-routing.md).
#
# The load-bearing tests are 5 and 6: the new format must remain readable by the
# EXISTING consumers in 03-inbox-services.sh, or filing breaks delivery fleet-wide.

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAIL_DETAILS=""

pass() { ((TESTS_PASSED++)) || true; ((TESTS_RUN++)) || true; echo "  PASS: $1"; }
fail() { ((TESTS_FAILED++)) || true; ((TESTS_RUN++)) || true; FAIL_DETAILS="${FAIL_DETAILS}\n  FAIL: $1"; echo "  FAIL: $1"; }

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
HELPER="$REPO_ROOT/setup/scripts/inbox-file.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT

# Minimal registry the helper validates against
cat > "$_tmp/registry.md" <<'EOF'
## Projects

| Project | Type | Parent |
|---------|------|--------|
| cfg-agent-fleet | infra | - |
| Alpha | research | - |
| muse | code | - |

## Machines
EOF

INBOX="$_tmp/inbox.md"
: > "$INBOX"

run_helper() { bash "$HELPER" --inbox "$INBOX" --registry "$_tmp/registry.md" "$@" 2>&1; }

echo "=== CFG-541 inbox filing helper ==="

if [ ! -f "$HELPER" ]; then
    fail "helper $HELPER does not exist"
    echo; echo "── Summary ──"; echo "  Total: 1"; echo "  Failed: 1"; exit 1
fi

# ── Test 1: rejects an invalid type ─────────────────────────────────────────
if run_helper --project Alpha --type nonsense --body "x" >/dev/null 2>&1; then
    fail "invalid type was accepted"
else
    pass "invalid type is rejected"
fi

# ── Test 2: rejects a project absent from the registry ──────────────────────
# 3.2b already warns about undeliverable tags AFTER filing; catching it at filing
# time is strictly better, because the filer is the one who knows what they meant.
if run_helper --project notaproject --type fact --body "x" >/dev/null 2>&1; then
    fail "unknown project was accepted"
else
    pass "project absent from registry.md is rejected at filing time"
fi

# ── Test 3: accepts each of the four valid types ────────────────────────────
_ok=1
for t in fact rule work fyi; do
    run_helper --project muse --type "$t" --body "body for $t" >/dev/null 2>&1 || _ok=0
done
if [ "$_ok" -eq 1 ]; then pass "all four types (fact/rule/work/fyi) accepted"
else fail "at least one valid type was rejected"; fi

# ── Test 4: the tag lands AFTER the project name, in the decided format ─────
: > "$INBOX"
run_helper --project Alpha --type fact --priority P1 --source "muse WSL 2026-08-26" \
           --body "record the thing" >/dev/null 2>&1
_line="$(head -1 "$INBOX")"
if printf '%s' "$_line" | grep -q '^- \[ \] \*\*Alpha\*\* \[fact\] (P1'; then
    pass "tag is placed after the project name in the decided format"
else
    fail "unexpected line format: $_line"
fi

# ── Test 5 (load-bearing): existing project-delivery regex still matches ────
# This is the exact expression 03-inbox-services.sh Check 3.2 uses.
PROJECT_NAME=Alpha
if grep -qi -- "\- \[ \].*\*\*[[:space:]]*$PROJECT_NAME[[:space:]]*\*\*" "$INBOX"; then
    pass "Check 3.2 delivery regex still matches a tagged item"
else
    fail "tagged item is INVISIBLE to the existing delivery regex — would break routing fleet-wide"
fi

# ── Test 6 (load-bearing): 3.2b tag extraction must not ingest the type ─────
# If "[fact]" leaked into the extracted project name, every tagged item would be
# reported as an unknown tag and the warning would become permanent noise.
_extracted=$(grep -o '^\- \[ \] \*\*[^*]*\*\*' "$INBOX" \
    | sed -e 's/^\- \[ \] \*\*//' -e 's/\*\*$//' -e 's/ *(.*//' \
    | tr '[:upper:]' '[:lower:]' | sort -u)
if [ "$_extracted" = "alpha" ]; then
    pass "3.2b extracts the project name cleanly, type tag does not leak in"
else
    fail "3.2b extracted '$_extracted' instead of 'alpha'"
fi

# ── Test 7: body is preserved verbatim ──────────────────────────────────────
if grep -qF 'record the thing' "$INBOX"; then
    pass "body text is preserved verbatim"
else
    fail "body text was mangled"
fi

# ── Test 8: appends rather than truncating ──────────────────────────────────
run_helper --project muse --type work --body "second item" >/dev/null 2>&1
if [ "$(grep -c '^- \[ \]' "$INBOX")" -eq 2 ]; then
    pass "filing appends, does not truncate"
else
    fail "expected 2 items after second filing, got $(grep -c '^- \[ \]' "$INBOX")"
fi

# ── CFG-553: the inflow cap ────────────────────────────────────────────────
# Measured: ~12 items/day in, against a drain that happens maybe monthly (301 items
# on 2026-08-19 → 163 on 08-24 → 187 on 08-26). Routing and splitting bound what a
# session PAYS; neither bounds what it RECEIVES, so the queue regrows regardless.
# The asymmetry is the whole problem: filing is free and draining is expensive, so
# the cost belongs on the filer, who still has the context to consolidate.
echo "=== CFG-553 per-project inflow cap ==="

_cap_inbox="$_tmp/cap.md"
: > "$_cap_inbox"
for i in $(seq 1 5); do
    echo "- [ ] **muse** [work] (P2 — filler $i): item $i" >> "$_cap_inbox"
done

# ── CFG-559: the cap warns, it never refuses ────────────────────────────────
# The owner, 2026-09-10: "sessions have stopped reporting issues to other projects because
# they do not force without my say so." That is the whole defect in one sentence.
# CFG-553 put the cost on the FILER to make it consolidate; CFG-554 already had to
# reopen fact/fyi for the same reason. The remaining work/rule wall kept failing the
# same way, because the filer is a DIFFERENT project's session and the only escape
# hatch (--force) needs the owner's authority, which a session correctly will not self-grant.
# So the report is simply lost, and the fleet looks quiet because reporting broke.
#
# Measured corruption, not theory: an item in cfg's own inbox reads "[rule] filings to
# this project are currently refused over the ceiling, so they arrive as a [fact]" —
# a session mislabelled a rule to get past the wall, which destroys the type tag that
# CFG-541 exists to make the dispatch mechanical.
#
# New contract: every filing lands. Backpressure moves to the RECEIVER, which is the
# only party that can actually drain, and the warning says so.

# ── Test 9: a [work] filing at the ceiling is accepted ──────────────────────
if INBOX_PROJECT_CEILING=5 bash "$HELPER" --inbox "$_cap_inbox" --registry "$_tmp/registry.md" \
        --project muse --type work --body "one too many" >/dev/null 2>&1; then
    pass "a [work] filing at the ceiling is accepted — reporting never breaks"
else
    fail "a [work] filing was refused at the ceiling — the report is lost"
fi

# ── Test 10: the accepted filing was actually written ───────────────────────
if grep -q 'one too many' "$_cap_inbox"; then
    pass "the over-ceiling filing landed in the inbox"
else
    fail "over-ceiling filing was accepted but never appended"
fi

# ── Test 11: acceptance is loud, and aimed at the receiver ──────────────────
# A cap that says nothing is no cap at all. The warning must survive, it just must
# not eat the item — and it must name draining, which only the receiver can do.
_msg=$(INBOX_PROJECT_CEILING=5 bash "$HELPER" --inbox "$_cap_inbox" --registry "$_tmp/registry.md" \
        --project muse --type work --body "still over" 2>&1 || true)
if printf '%s' "$_msg" | grep -qi 'drain\|over its ceiling\|over ceiling'; then
    pass "an over-ceiling filing still warns loudly"
else
    fail "over-ceiling filing was silent: $_msg"
fi

# ── Test 12: --force always works, so a real finding is never lost ──────────
# The cap must be a speed bump, not a wall — a session at shutdown with a genuine
# finding has to be able to record it.
if INBOX_PROJECT_CEILING=5 bash "$HELPER" --inbox "$_cap_inbox" --registry "$_tmp/registry.md" \
        --project muse --type work --force --body "genuinely urgent" >/dev/null 2>&1 \
   && grep -q 'genuinely urgent' "$_cap_inbox"; then
    pass "--force overrides the cap, so nothing is ever truly blocked"
else
    fail "--force did not override the cap"
fi

# ── Test 13: the ceiling is per PROJECT, not per file ───────────────────────
# Another project must not be penalised for muse's hoard. Deliberately typed `work`,
# not `fact` — under CFG-554 a `fact` filing is exempt from the ceiling entirely, so
# a fact-typed probe here would pass without ever exercising per-project scoping.
if INBOX_PROJECT_CEILING=5 bash "$HELPER" --inbox "$_cap_inbox" --registry "$_tmp/registry.md" \
        --project Alpha --type work --body "unrelated project" >/dev/null 2>&1; then
    pass "the ceiling is scoped per project, not per file"
else
    fail "an unrelated project was blocked by muse's item count"
fi

# ── CFG-554: the ceiling must not close the correction lane ────────────────
# The owner, 2026-08-27: "report to cfg that this mechanism is unacceptable. where else
# should other projects write???" The cross-project boundary is a HARD rule — a
# project may write only inside its own directory and everything else goes through
# the inbox. A blocking ceiling on that one channel leaves a project holding a
# correction to a canonical file with no legal path at all.
#
# The asymmetry the fix rests on: `fact` and `fyi` are execute-and-delete and
# read-and-delete. Neither can accumulate unless the RECEIVER ignores it, so
# capping them punishes the writer for the reader's backlog. `work` and `rule`
# genuinely queue, so they keep the backpressure.
echo "=== CFG-554 the correction lane is never closed ==="

_lane_inbox="$_tmp/lane.md"
: > "$_lane_inbox"
for i in $(seq 1 5); do
    echo "- [ ] **muse** [work] (P2 — filler $i): item $i" >> "$_lane_inbox"
done

# ── Test 14: a `fact` is accepted at the ceiling ────────────────────────────
# The live case that surfaced this: contacts.md #29 held a wrong Zenodo concept DOI
# that had already been emailed to an external researcher. One digit, unambiguous,
# data-integrity — and the mechanism refused it.
if INBOX_PROJECT_CEILING=5 bash "$HELPER" --inbox "$_lane_inbox" --registry "$_tmp/registry.md" \
        --project muse --type fact --body "canonical file holds a wrong value" >/dev/null 2>&1 \
   && grep -q 'wrong value' "$_lane_inbox"; then
    pass "a [fact] is filed at the ceiling — the correction lane stays open"
else
    fail "a [fact] was refused at the ceiling; a correction has no legal channel"
fi

# ── Test 15: a `fyi` is accepted at the ceiling ─────────────────────────────
if INBOX_PROJECT_CEILING=5 bash "$HELPER" --inbox "$_lane_inbox" --registry "$_tmp/registry.md" \
        --project muse --type fyi --body "read and delete" >/dev/null 2>&1 \
   && grep -q 'read and delete' "$_lane_inbox"; then
    pass "a [fyi] is filed at the ceiling — read-and-delete cannot accumulate"
else
    fail "a [fyi] was refused at the ceiling"
fi

# ── Test 16: `work` and `rule` are accepted at the ceiling too ──────────────
# The inversion of the old assertion. A queued type is still the receiver's problem,
# but losing the report is strictly worse than carrying it: an item in the queue can
# be drained later, an item that was never filed is gone with the session that held it.
_all_land=1
for _t in work rule; do
    if ! INBOX_PROJECT_CEILING=5 bash "$HELPER" --inbox "$_lane_inbox" --registry "$_tmp/registry.md" \
            --project muse --type "$_t" --body "queued type $_t over ceiling" >/dev/null 2>&1; then
        _all_land=0
        fail "a [$_t] was refused at the ceiling — the report is lost"
    fi
done
[ "$_all_land" -eq 1 ] && pass "[work] and [rule] land at the ceiling — no report is ever dropped"

# ── Test 17: the warning names who must act, not how to bypass ──────────────
# The owner's question in CFG-554 was "where else should other projects write?" The answer is
# now "here, always" — so the message must stop advertising --force as the way through
# and must instead put the obligation on the receiving project, which can act on it.
_msg2=$(INBOX_PROJECT_CEILING=5 bash "$HELPER" --inbox "$_lane_inbox" --registry "$_tmp/registry.md" \
        --project muse --type work --body "warned not refused" 2>&1 || true)
if printf '%s' "$_msg2" | grep -qi 'drain' && printf '%s' "$_msg2" | grep -qi 'muse'; then
    pass "the warning names the receiving project and the drain obligation"
else
    fail "warning does not put the obligation on the receiver: $_msg2"
fi

# ── Test 19: nothing is refused at any depth ────────────────────────────────
# The anti-regression that encodes the owner's requirement directly. At 10x the ceiling every
# type must still exit 0. If this ever goes red, cross-project reporting is broken again
# and the fleet will look quiet for the wrong reason.
_deep="$_tmp/deep.md"
: > "$_deep"
for i in $(seq 1 50); do
    echo "- [ ] **muse** [work] (P2 — filler $i): item $i" >> "$_deep"
done
_never_refused=1
for _t in fact fyi work rule; do
    if ! INBOX_PROJECT_CEILING=5 bash "$HELPER" --inbox "$_deep" --registry "$_tmp/registry.md" \
            --project muse --type "$_t" --body "deep queue $_t" >/dev/null 2>&1; then
        _never_refused=0
        fail "a [$_t] was refused at 10x the ceiling"
    fi
done
if [ "$_never_refused" -eq 1 ] && [ "$(grep -c 'deep queue' "$_deep")" -eq 4 ]; then
    pass "no type is refused at any depth — reporting cannot break"
else
    fail "a filing was lost at 10x the ceiling"
fi

# ── Test 18: the exemption is reported, not silent ──────────────────────────
# An over-ceiling project must not look healthy just because facts flow through it.
_msg3=$(INBOX_PROJECT_CEILING=5 bash "$HELPER" --inbox "$_lane_inbox" --registry "$_tmp/registry.md" \
        --project muse --type fact --body "another correction" 2>&1)
if printf '%s' "$_msg3" | grep -qi 'ceiling\|over'; then
    pass "an exempt filing still reports that the project is over its ceiling"
else
    fail "exempt filing was silent about the backlog: $_msg3"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo
echo "── Summary ──"
echo "  Total:   $TESTS_RUN"
echo "  Passed:  $TESTS_PASSED"
# ══════════════════════════════════════════════════════════════════════════════
# FIX 1 (lrn 2026-09-23, owner-approved): inbox-file.sh must verify what it wrote
# ══════════════════════════════════════════════════════════════════════════════
# An item filed 2026-09-23 read "⇒ ** ist tracked und jetzt modified.**" — the filename
# had vanished, because backticks in the --body argument were run as COMMAND SUBSTITUTION
# by the caller's shell before inbox-file.sh ever saw them. Empty string, error to stderr,
# item filed anyway, caller none the wiser. Backtick identifiers are house style in inbox
# bodies; four such items were created in that one session. (It is not a rare shape: the
# same substitution ate two phrases out of a git commit message in this session.)

echo ""
echo "=== FIX 1: the filed body is verified against the passed body ==="

# A REGISTERED project name is required — the script refuses an unknown one before it ever
# appends — but --inbox redirects the write, so nothing real is touched.
_fx_dir="$(mktemp -d)"
: > "$_fx_dir/scratch-inbox.md"

_file_body() {  # <body> → stderr+stdout of a filing run against a scratch inbox
    : > "$_fx_dir/scratch-inbox.md"
    bash "$HELPER" --project cfg-agent-fleet --type fact --body "$1" \
        --inbox "$_fx_dir/scratch-inbox.md" 2>&1
}

_out=$(_file_body 'a clean one-line body with no surprises')
if printf '%s' "$_out" | grep -qi 'differ\|WARNING'; then
    fail "FIX 1: an intact body must file without a warning"
else
    pass "FIX 1: an intact body files without a warning"
fi

# A body containing a newline silently becomes SEVERAL inbox lines: the continuation lines
# carry no `- [ ]` prefix, so every sweep that counts open items misses them. This is the
# read-back check earning its keep.
_out=$(_file_body 'first line
second line that loses its item prefix')
if printf '%s' "$_out" | grep -qi 'differ\|WARNING\|verif'; then
    pass "FIX 1: a body that cannot round-trip as one line warns loudly"
else
    fail "FIX 1: a body that cannot round-trip as one line warns loudly"
fi

# The command-substitution signature: backticks were evaluated away, leaving an empty
# emphasis or code span where an identifier used to be.
_out=$(_file_body 'the file ** ist tracked und jetzt modified.**')
if printf '%s' "$_out" | grep -qi 'backtick\|substitut'; then
    pass "FIX 1: the command-substitution damage signature is named"
else
    fail "FIX 1: the command-substitution damage signature is named"
fi

rm -rf "$_fx_dir"

# ══════════════════════════════════════════════════════════════════════════════
# CFG-798 (life 2026-10-21): a target with no trailing newline swallowed the new item
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== CFG-798: appending to a file that lacks a trailing newline ==="
_nl_dir="$(mktemp -d)"
printf '# Inbox — cfg-agent-fleet\n- [ ] older item\n<!-- trailing comment, no newline -->' > "$_nl_dir/inbox.md"
bash "$HELPER" --project cfg-agent-fleet --type fact --body "newline guard probe" \
    --inbox "$_nl_dir/inbox.md" >/dev/null 2>&1
_last=$(tail -1 "$_nl_dir/inbox.md")
if [[ "$_last" == "- [ ] "*"newline guard probe" ]] && grep -qx '<!-- trailing comment, no newline -->' "$_nl_dir/inbox.md"; then
    pass "CFG-798: the new item starts its own line; the comment line is left intact"
else
    fail "CFG-798: item glued onto the previous line (last line: $_last)"
fi
rm -rf "$_nl_dir"

if [ "$TESTS_FAILED" -gt 0 ]; then
    echo "  Failed:  $TESTS_FAILED"
    echo -e "$FAIL_DETAILS"
    exit 1
fi
exit 0
