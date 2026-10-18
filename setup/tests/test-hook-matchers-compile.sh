#!/usr/bin/env bash
# test-hook-matchers-compile.sh — CFG-764: every hook matcher in the shipped
# settings template must compile as a JavaScript RegExp.
#
# Why this is a lockout guard and not a style check. Claude Code 2.1.288:
#   "Fixed PreToolUse and PermissionRequest hooks being skipped when matching
#    them failed or the tool's input could not be serialized to JSON; the call
#    is now blocked"                                      (CHANGELOG, 2.1.288)
# Before 2.1.288 a matcher that threw inside `new RegExp()` silently SKIPPED
# its hook (fail-open). From 2.1.288 the same typo BLOCKS every tool call the
# event covers — for PreToolUse that is a session that can run nothing, and
# safe-run.sh cannot help because the failure happens before any hook starts.
# CC matches with JavaScript's RegExp, so the check runs in node: grep's and
# python's dialects accept and reject different patterns and cannot stand in.
#
# Mirrors CC's matcher semantics: an omitted or empty matcher means "match
# all" and is fine; a string must compile; anything else is an error (CC
# cannot match on it, and from 2.1.288 "cannot match" means "block").
#
# Test-only knob: HOOK_MATCHERS_SETTINGS=<file> points the template case at
# another settings file (e.g. a deliberately broken copy) to replay red/green.
source "$(dirname "$0")/test-helpers.sh"

suite_header "hook matchers compile (CFG-764, CC 2.1.288 fail-closed matching)"

SETTINGS="${HOOK_MATCHERS_SETTINGS:-$REPO_ROOT/setup/config/settings.json}"
# The deployed file CC reads on THIS machine, resolved before any sandboxing of
# HOME. mclaude points CLAUDE_CONFIG_DIR at the live config; ~/.claude is the
# fallback for installs without it.
DEPLOYED="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

# Prints one line per matcher ("OK <event>[<i>] <matcher>" or
# "INVALID <event>[<i>] <matcher>: <reason>") and a final "checked=N invalid=K".
# Exit 0 when every matcher compiles, 1 when any does not, 2 when the file
# cannot be read or parsed — so an unparseable settings file can never pass.
check_matchers() {
    node -e '
const fs = require("fs");
const file = process.argv[1];
let s;
try { s = JSON.parse(fs.readFileSync(file, "utf8")); }
catch (e) { console.log("UNREADABLE " + file + ": " + e.message); process.exit(2); }
let checked = 0, invalid = 0;
for (const [event, groups] of Object.entries(s.hooks || {})) {
  if (!Array.isArray(groups)) continue;
  groups.forEach((g, i) => {
    const m = g.matcher, tag = event + "[" + i + "] " + JSON.stringify(m);
    checked++;
    if (m === undefined || m === "") { console.log("OK " + tag + " (match all)"); return; }
    if (typeof m !== "string") { invalid++; console.log("INVALID " + tag + ": matcher must be a string"); return; }
    try { new RegExp(m); console.log("OK " + tag); }
    catch (e) { invalid++; console.log("INVALID " + tag + ": " + e.message); }
  });
}
console.log("checked=" + checked + " invalid=" + invalid);
process.exit(invalid > 0 ? 1 : 0);
' "$1"
}

count_of() { # count_of <key> <checker output>
    printf '%s\n' "$2" | tail -1 | tr ' ' '\n' | awk -F= -v k="$1" '$1==k {print $2}'
}

write_fixture() { # write_fixture <path> <json for the "hooks" value>
    printf '{"permissions":{"allow":[]},"hooks":%s}\n' "$2" > "$1"
}

if ! command -v node >/dev/null 2>&1; then
    skip_test "every matcher in the template compiles" \
        "node not installed — CC matches with JavaScript RegExp; no other engine can stand in"
    suite_summary
    exit $?
fi

# ── The guard itself ─────────────────────────────────────────────────────────

test_template_matchers_compile() {
    local out rc=0 checked
    out=$(check_matchers "$SETTINGS") || rc=$?
    checked=$(count_of checked "$out")
    assert_eq "0" "$rc" "every matcher in $SETTINGS compiles (output: $out)" || return 1
    # A file with no hooks would pass vacuously; the template registers tool hooks.
    assert_contains "$out" "OK PreToolUse[" "the file under test registers PreToolUse hooks" || return 1
    [[ "${checked:-0}" -gt 0 ]] || { printf '    no matchers found in %s\n' "$SETTINGS"; return 1; }
    printf '    measured: %s matchers compiled, %s invalid in %s\n' \
        "$checked" "$(count_of invalid "$out")" "$SETTINGS"
}
run_test "every hook matcher in the settings template compiles as a JS RegExp" \
    test_template_matchers_compile

# ── Proof the guard can fail (fixtures, never the real template) ─────────────

test_invalid_regex_is_rejected_and_named() {
    local f="$TEST_TMPDIR/broken.json" out rc=0
    write_fixture "$f" '{"PreToolUse":[{"matcher":"Bash(","hooks":[{"type":"command","command":"true"}]}]}'
    out=$(check_matchers "$f") || rc=$?
    assert_eq "1" "$rc" "an unterminated group must fail the check" || return 1
    assert_contains "$out" 'INVALID PreToolUse[0] "Bash("' "the offending event, index and matcher are named"
}
run_test "an invalid regex matcher fails the check and is named" \
    test_invalid_regex_is_rejected_and_named

test_one_bad_among_good_is_pinpointed() {
    local f="$TEST_TMPDIR/mixed.json" out rc=0
    write_fixture "$f" '{"PreToolUse":[
        {"matcher":"Bash","hooks":[{"type":"command","command":"true"}]},
        {"matcher":"Write|Edit","hooks":[{"type":"command","command":"true"}]},
        {"matcher":"mcp__.*|WebSearch|WebFetch(","hooks":[{"type":"command","command":"true"}]}]}'
    out=$(check_matchers "$f") || rc=$?
    assert_eq "1" "$rc" "one broken matcher fails the whole file" || return 1
    assert_contains "$out" "INVALID PreToolUse[2]" "the broken entry is index 2" || return 1
    assert_not_contains "$out" "INVALID PreToolUse[0]" "the valid entries are not blamed" || return 1
    assert_contains "$out" "checked=3 invalid=1" "counts are measured, not assumed"
}
run_test "one invalid matcher among valid ones is pinpointed by index" \
    test_one_bad_among_good_is_pinpointed

test_non_string_matcher_is_rejected() {
    local f="$TEST_TMPDIR/typed.json" out rc=0
    write_fixture "$f" '{"PreToolUse":[{"matcher":42,"hooks":[{"type":"command","command":"true"}]}]}'
    out=$(check_matchers "$f") || rc=$?
    assert_eq "1" "$rc" "a non-string matcher must fail" || return 1
    assert_contains "$out" "matcher must be a string"
}
run_test "a non-string matcher is rejected" test_non_string_matcher_is_rejected

test_empty_and_omitted_matchers_pass() {
    local f="$TEST_TMPDIR/matchall.json" out rc=0
    write_fixture "$f" '{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"true"}]}],
                        "SessionEnd":[{"hooks":[{"type":"command","command":"true"}]}]}'
    out=$(check_matchers "$f") || rc=$?
    assert_eq "0" "$rc" "CC treats an omitted or empty matcher as match-all" || return 1
    assert_contains "$out" "checked=2 invalid=0"
}
run_test "empty and omitted matchers pass (CC match-all semantics)" \
    test_empty_and_omitted_matchers_pass

test_unparseable_file_cannot_pass() {
    local f="$TEST_TMPDIR/garbage.json" out rc=0
    printf '{"hooks": [not json\n' > "$f"
    out=$(check_matchers "$f") || rc=$?
    assert_eq "2" "$rc" "an unparseable settings file is an error, not a pass" || return 1
    assert_contains "$out" "UNREADABLE $f"
}
run_test "an unparseable settings file fails instead of passing vacuously" \
    test_unparseable_file_cannot_pass

# ── The file CC actually reads on this machine (skipped where absent) ───────

test_deployed_matchers_compile() {
    local out rc=0
    out=$(check_matchers "$DEPLOYED") || rc=$?
    assert_eq "0" "$rc" "every matcher in deployed $DEPLOYED compiles (output: $out)" || return 1
    printf '    measured: %s matchers compiled, %s invalid in %s\n' \
        "$(count_of checked "$out")" "$(count_of invalid "$out")" "$DEPLOYED"
}
if [[ -f "$DEPLOYED" ]]; then
    run_test "every hook matcher in the deployed settings compiles" test_deployed_matchers_compile
else
    skip_test "every hook matcher in the deployed settings compiles" "no settings at $DEPLOYED"
fi

suite_summary
