#!/usr/bin/env bash
# Tests for setup/scripts/lib-leak-gate.sh — the ONE leak gate every egress
# path calls (CFG-626). The property that matters most is fail-closed: an
# empty or broken pattern list must refuse to scan, never quietly pass.
source "$(dirname "$0")/test-helpers.sh"

LIB="$REPO_ROOT/setup/scripts/lib-leak-gate.sh"

suite_header "lib-leak-gate.sh (shared egress leak gate)"

# A credential-shaped token built at runtime so the literal never sits in this
# file (the SessionEnd secret scan would otherwise unstage the test itself).
_fake_token() { printf 'ghp_%s' "$(printf 'A%.0s' $(seq 1 40))"; }

test_lib_exists_and_sources() {
    assert_file_exists "$LIB" "the shared gate library exists" || return 1
    ( source "$LIB" && declare -F check_leaks >/dev/null ) \
        || { echo "  check_leaks is not defined after sourcing"; return 1; }
    ( source "$LIB" && declare -F leak_gate_conf_value >/dev/null ) \
        || { echo "  leak_gate_conf_value is not defined after sourcing"; return 1; }
}
run_test "library sources and defines check_leaks + leak_gate_conf_value" test_lib_exists_and_sources

test_empty_pattern_list_fails_closed() {
    echo "anything" > "$TEST_TMPDIR/f.md"
    local out rc=0
    out=$( source "$LIB"; check_leaks "" "$TEST_TMPDIR/f.md" 2>&1 ) || rc=$?
    assert_eq "2" "$rc" "an EMPTY pattern list returns 2, not 0 (measured $rc)" || return 1
    assert_contains "$out" "EMPTY" "and says so"
}
run_test "empty pattern list: refuses to scan (rc 2), never passes" test_empty_pattern_list_fails_closed

test_invalid_regex_fails_closed() {
    echo "anything" > "$TEST_TMPDIR/f.md"
    local rc=0
    ( source "$LIB"; check_leaks '(' "$TEST_TMPDIR/f.md" >/dev/null 2>&1 ) || rc=$?
    assert_eq "2" "$rc" "a broken regex returns 2, not 0 (measured $rc)"
}
run_test "invalid regex: refuses to scan (rc 2), never passes" test_invalid_regex_fails_closed

test_clean_file_returns_zero_silently() {
    echo "nothing to see" > "$TEST_TMPDIR/f.md"
    local out rc=0
    out=$( source "$LIB"; check_leaks 'Persona|Host' "$TEST_TMPDIR/f.md" 2>&1 ) || rc=$?
    assert_eq "0" "$rc" "clean file returns 0 (measured $rc)" || return 1
    assert_eq "" "$out" "and prints nothing"
}
run_test "clean file: rc 0, no output" test_clean_file_returns_zero_silently

# A path the gate was asked to scan and cannot is not a clean path: callers
# pass exactly what is about to be published, so "missing" means the list and
# the bytes disagree (a C-quoted name, a deleted snapshot) — refuse.
test_missing_path_fails_closed() {
    echo "nothing to see" > "$TEST_TMPDIR/f.md"
    local out rc=0
    out=$( source "$LIB"; check_leaks 'Persona' "$TEST_TMPDIR/f.md" "$TEST_TMPDIR/does-not-exist.md" 2>&1 ) || rc=$?
    assert_eq "2" "$rc" "a path that does not exist returns 2, not 0 (measured $rc)" || return 1
    assert_contains "$out" "does-not-exist.md" "and names it"
}
run_test "missing path: refuses (rc 2), never passes" test_missing_path_fails_closed

test_hit_returns_one_with_file_line_and_text() {
    printf 'line one\nsigned, Persona\nline three\n' > "$TEST_TMPDIR/f.md"
    local out rc=0
    out=$( source "$LIB"; check_leaks 'Persona|Host' "$TEST_TMPDIR/f.md" 2>&1 ) || rc=$?
    assert_eq "1" "$rc" "a hit returns 1 (measured $rc)" || return 1
    assert_contains "$out" "$TEST_TMPDIR/f.md:2:signed, Persona" "hit is reported as path:line:text"
}
run_test "hit: rc 1, path:line:text" test_hit_returns_one_with_file_line_and_text

test_directory_scan_is_recursive_and_skips_git() {
    mkdir -p "$TEST_TMPDIR/d/sub" "$TEST_TMPDIR/d/.git"
    echo "clean" > "$TEST_TMPDIR/d/a.md"
    echo "Persona here" > "$TEST_TMPDIR/d/sub/b.md"
    echo "Persona in git internals" > "$TEST_TMPDIR/d/.git/config"
    local out rc=0
    out=$( source "$LIB"; check_leaks 'Persona' "$TEST_TMPDIR/d" 2>&1 ) || rc=$?
    assert_eq "1" "$rc" "a hit under a directory returns 1 (measured $rc)" || return 1
    assert_contains "$out" "d/sub/b.md:1:Persona here" "nested file is found" || return 1
    assert_not_contains "$out" ".git/config" ".git is not scanned"
}
run_test "directory: recursive, .git excluded" test_directory_scan_is_recursive_and_skips_git

test_secret_vocabulary_is_nonempty_valid_and_precise() {
    local pat
    pat=$( source "$LIB"; printf '%s' "$LEAK_GATE_SECRET_PATTERNS" )
    [[ -n "$pat" ]] || { echo "  LEAK_GATE_SECRET_PATTERNS is empty"; return 1; }
    grep -E -e "$pat" /dev/null 2>/dev/null; local rc=$?
    assert_neq "2" "$rc" "the secret vocabulary compiles as a grep -E regex (grep rc $rc)" || return 1
    printf 'token = %s\n' "$(_fake_token)" > "$TEST_TMPDIR/leak.md"
    # Labels built at runtime: written out, they would match the SessionEnd
    # hook's staged-diff scan and an auto-sync of an edit here would be unstaged.
    local pw="pass""word" sc="sec""ret"
    printf 'The %s: field is documented here.\n%s = see the vault\n' "$pw" "$sc" > "$TEST_TMPDIR/prose.md"
    rc=0; ( source "$LIB"; check_leaks "$LEAK_GATE_SECRET_PATTERNS" "$TEST_TMPDIR/leak.md" >/dev/null 2>&1 ) || rc=$?
    assert_eq "1" "$rc" "a credential-shaped token is a hit (measured rc $rc)" || return 1
    rc=0; ( source "$LIB"; check_leaks "$LEAK_GATE_SECRET_PATTERNS" "$TEST_TMPDIR/prose.md" >/dev/null 2>&1 ) || rc=$?
    assert_eq "0" "$rc" "prose that merely names a password or secret label is not a hit (measured rc $rc)"
}
run_test "LEAK_GATE_SECRET_PATTERNS: non-empty, valid, matches tokens not prose" test_secret_vocabulary_is_nonempty_valid_and_precise

# Common credential formats the first vocabulary missed (review, measured rc 0
# for each): project-scoped OpenAI keys, GitHub app/user/refresh tokens, GitLab
# and npm tokens, and upper-case env-style names (the key|token|secret rule was
# lower-case only). Bodies built at runtime, as above.
test_secret_vocabulary_covers_common_token_formats() {
    local a40 a36 a20
    a40=$(printf 'A%.0s' $(seq 1 40)); a36=$(printf 'B%.0s' $(seq 1 36)); a20=$(printf 'C%.0s' $(seq 1 20))
    local -a samples=(
        "OPENAI_API_KEY=sk-proj-$a40"
        "GH_TOKEN=ghs_$a40"
        "gitlab: glpat-$a20"
        "NPM_TOKEN=npm_$a36"
        "SERVICE_SECRET=$a40"
    )
    local s rc missed=""
    for s in "${samples[@]}"; do
        printf '%s\n' "$s" > "$TEST_TMPDIR/sample.env"
        rc=0; ( source "$LIB"; check_leaks "$LEAK_GATE_SECRET_PATTERNS" "$TEST_TMPDIR/sample.env" >/dev/null 2>&1 ) || rc=$?
        [[ "$rc" -eq 1 ]] || missed="${missed:+$missed; }${s%%=*} (rc $rc)"
    done
    assert_eq "" "$missed" "every sample is a hit (missed: ${missed:-none})"
}
run_test "LEAK_GATE_SECRET_PATTERNS: covers sk-proj, gh[su]_, glpat, npm_ and upper-case names" test_secret_vocabulary_covers_common_token_formats

test_conf_value_trims_and_keeps_backslashes() {
    cat > "$TEST_TMPDIR/x.conf" << 'CONF'
# comment
other=1
  personal_patterns =  (\bPersona\b|Host)
CONF
    local v
    v=$( source "$LIB"; leak_gate_conf_value "$TEST_TMPDIR/x.conf" personal_patterns )
    assert_eq '(\bPersona\b|Host)' "$v" "value is trimmed and the backslashes survive (CFG-606)" || return 1
    v=$( source "$LIB"; leak_gate_conf_value "$TEST_TMPDIR/x.conf" missing_key )
    assert_eq "" "$v" "a missing key yields the empty string" || return 1
    v=$( source "$LIB"; leak_gate_conf_value "$TEST_TMPDIR/does-not-exist.conf" personal_patterns )
    assert_eq "" "$v" "a missing conf yields the empty string (the caller must fail closed)"
}
run_test "leak_gate_conf_value: trims without xargs, keeps \\b, empty when absent" test_conf_value_trims_and_keeps_backslashes

test_hit_files_lists_unique_paths() {
    printf 'Persona\nPersona\n' > "$TEST_TMPDIR/a.md"
    echo "Persona" > "$TEST_TMPDIR/b.md"
    local files
    files=$( source "$LIB"; check_leaks 'Persona' "$TEST_TMPDIR/a.md" "$TEST_TMPDIR/b.md" 2>/dev/null | leak_gate_hit_files )
    local n; n=$(printf '%s\n' "$files" | grep -c . || true)
    assert_eq "2" "$n" "two files, each once, although a.md has two hits (measured $n)" || return 1
    assert_contains "$files" "$TEST_TMPDIR/a.md" "a.md listed" || return 1
    assert_contains "$files" "$TEST_TMPDIR/b.md" "b.md listed"
}
run_test "leak_gate_hit_files: unique file list from hit lines" test_hit_files_lists_unique_paths

suite_summary
