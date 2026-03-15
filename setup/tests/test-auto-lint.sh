#!/usr/bin/env bash
# Tests for global/hooks/auto-lint.sh — PostToolUse linting hook
source "$(dirname "$0")/test-helpers.sh"

HOOK_SCRIPT="$REPO_ROOT/global/hooks/auto-lint.sh"

suite_header "auto-lint.sh (PostToolUse linter)"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Run the hook with a simulated PostToolUse JSON input
run_lint_hook() {
    local tool_name="$1"
    local file_path="$2"
    echo "{\"tool_name\": \"$tool_name\", \"tool_input\": {\"file_path\": \"$file_path\"}, \"hook_event_name\": \"PostToolUse\"}" \
        | bash "$HOOK_SCRIPT" 2>/dev/null
}

# ── Skip conditions ─────────────────────────────────────────────────────────

test_skip_non_file_tool() {
    local output
    output=$(echo '{"tool_name": "Bash", "tool_input": {"command": "ls"}, "hook_event_name": "PostToolUse"}' \
        | bash "$HOOK_SCRIPT" 2>/dev/null)
    assert_eq "" "$output" "should produce no output for non-Write/Edit tools"
}
run_test "skip: Bash tool produces no output" test_skip_non_file_tool

test_skip_nonexistent_file() {
    local output
    output=$(run_lint_hook "Write" "/tmp/nonexistent-file-$$.sh")
    assert_eq "" "$output" "should produce no output when file doesn't exist"
}
run_test "skip: nonexistent file produces no output" test_skip_nonexistent_file

test_skip_unsupported_extension() {
    local tmpfile="$TEST_TMPDIR/file.txt"
    echo "hello world" > "$tmpfile"
    local output
    output=$(run_lint_hook "Write" "$tmpfile")
    assert_eq "" "$output" "should produce no output for .txt files"
}
run_test "skip: unsupported extension (.txt) produces no output" test_skip_unsupported_extension

# ── Bash linting ─────────────────────────────────────────────────────────────

test_bash_clean() {
    local tmpfile="$TEST_TMPDIR/script.sh"
    cat > "$tmpfile" << 'EOF'
#!/usr/bin/env bash
echo "hello world"
EOF
    local output
    output=$(run_lint_hook "Write" "$tmpfile")
    assert_eq "" "$output" "should produce no output for valid bash"
}
run_test "bash: clean script produces no output" test_bash_clean

test_bash_syntax_error() {
    local tmpfile="$TEST_TMPDIR/bad.sh"
    cat > "$tmpfile" << 'EOF'
#!/usr/bin/env bash
if [[ true
    echo "unclosed conditional"
fi
EOF
    local output
    output=$(run_lint_hook "Write" "$tmpfile")
    assert_contains "$output" "systemMessage" "should output JSON with systemMessage"
    assert_contains "$output" "bad.sh" "should mention the filename"
}
run_test "bash: syntax error detected" test_bash_syntax_error

test_bash_edit_tool() {
    local tmpfile="$TEST_TMPDIR/edited.sh"
    cat > "$tmpfile" << 'EOF'
#!/usr/bin/env bash
if [[ true
    echo broken
fi
EOF
    local output
    output=$(run_lint_hook "Edit" "$tmpfile")
    assert_contains "$output" "systemMessage" "should work for Edit tool too"
}
run_test "bash: Edit tool also triggers lint" test_bash_edit_tool

# ── Python linting ───────────────────────────────────────────────────────────

test_python_clean() {
    local tmpfile="$TEST_TMPDIR/script.py"
    cat > "$tmpfile" << 'EOF'
def hello():
    print("hello world")
EOF
    local output
    output=$(run_lint_hook "Write" "$tmpfile")
    assert_eq "" "$output" "should produce no output for valid python"
}
run_test "python: clean script produces no output" test_python_clean

test_python_syntax_error() {
    local tmpfile="$TEST_TMPDIR/bad.py"
    cat > "$tmpfile" << 'EOF'
def hello(
    print("missing closing paren"
EOF
    local output
    output=$(run_lint_hook "Write" "$tmpfile")
    assert_contains "$output" "systemMessage" "should output JSON with systemMessage"
    assert_contains "$output" "bad.py" "should mention the filename"
}
run_test "python: syntax error detected" test_python_syntax_error

# ── JSON linting ─────────────────────────────────────────────────────────────

test_json_clean() {
    local tmpfile="$TEST_TMPDIR/config.json"
    echo '{"key": "value", "num": 42}' > "$tmpfile"
    local output
    output=$(run_lint_hook "Write" "$tmpfile")
    assert_eq "" "$output" "should produce no output for valid JSON"
}
run_test "json: valid JSON produces no output" test_json_clean

test_json_syntax_error() {
    local tmpfile="$TEST_TMPDIR/bad.json"
    echo '{"key": "value" "missing": "comma"}' > "$tmpfile"
    local output
    output=$(run_lint_hook "Write" "$tmpfile")
    assert_contains "$output" "systemMessage" "should output JSON with systemMessage"
    assert_contains "$output" "bad.json" "should mention the filename"
}
run_test "json: invalid JSON detected" test_json_syntax_error

# ── Output format ────────────────────────────────────────────────────────────

test_output_is_valid_json() {
    local tmpfile="$TEST_TMPDIR/bad.sh"
    cat > "$tmpfile" << 'EOF'
#!/usr/bin/env bash
if [[ true
    echo broken
fi
EOF
    local output
    output=$(run_lint_hook "Write" "$tmpfile")
    # Verify it's valid JSON
    echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null
    local rc=$?
    assert_eq "0" "$rc" "hook output should be valid JSON"
}
run_test "output: error output is valid JSON" test_output_is_valid_json

test_output_has_continue_true() {
    local tmpfile="$TEST_TMPDIR/bad.sh"
    cat > "$tmpfile" << 'EOF'
#!/usr/bin/env bash
if [[ true
    echo broken
fi
EOF
    local output
    output=$(run_lint_hook "Write" "$tmpfile")
    local cont
    cont=$(echo "$output" | python3 -c "import json,sys; print(json.load(sys.stdin).get('continue', 'MISSING'))")
    assert_eq "True" "$cont" "should have continue: true (non-blocking)"
}
run_test "output: includes continue=true (non-blocking)" test_output_has_continue_true

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
