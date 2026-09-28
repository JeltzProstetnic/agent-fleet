#!/usr/bin/env bash
# Tests for CFG-238: Telegram-to-inbox pre-launch automation
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/afleet.sh"

suite_header "telegram-inbox (CFG-238)"

# ── Helpers ──────────────────────────────────────────────────────────────────

create_telegram_env() {
    local dir="$TEST_TMPDIR/env"
    mkdir -p "$dir/cross-project"
    # Create empty inbox
    cat > "$dir/cross-project/inbox.md" << 'EOF'
# Cross-Project Inbox

| Source | Target | Task | Date | Parent |
|--------|--------|------|------|--------|
EOF
    # Create registry
    cat > "$dir/registry.md" << 'EOF'
# Project Registry

## Projects

| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
| Alpha | P1 | — | `~/Alpha` | `example-user/Alpha` | wsl-host | research | active | |
| cfg-agent-fleet | P1 | — | `~/cfg-agent-fleet` | `example-user/cfg-agent-fleet` | wsl-host | meta | active | |
| social | P1 | — | `~/social` | `example-user/social` | wsl-host | marketing | active | |
| muse | P2 | — | `~/muse` | `example-user/muse` | wsl-host | code | active | |
EOF
    echo "$dir"
}

# Source afleet once; override env vars to use mock directories
_telegram_sourced=0
setup_telegram_test() {
    local env_dir="$1"
    if [[ "$_telegram_sourced" -eq 0 ]]; then
        AFLEET_SOURCE_ONLY=1 source "$SCRIPT"
        _telegram_sourced=1
    fi
    # Override paths to point at mock env
    INBOX_FILE="$env_dir/cross-project/inbox.md"
    REGISTRY="$env_dir/registry.md"
}

# Mock afd that returns canned JSON messages
create_mock_afd() {
    local dir="$1"
    local messages="$2"
    mkdir -p "$dir"
    cat > "$dir/afd" << MOCK
#!/usr/bin/env bash
if [[ "\$1" == "messages" ]]; then
    cat << 'MESSAGES'
$messages
MESSAGES
elif [[ "\$1" == "health" ]]; then
    echo "Status: ok  Uptime: 100s"
fi
MOCK
    chmod +x "$dir/afd"
}

# ── 1. No messages → no action ──────────────────────────────────────────────

test_no_messages_no_action() {
    local env_dir
    env_dir=$(create_telegram_env)

    create_mock_afd "$TEST_TMPDIR/bin" ""

    setup_telegram_test "$env_dir"

    local output
    output=$(PATH="$TEST_TMPDIR/bin:$PATH" telegram_inbox_check 2>&1)
    local rc=$?

    assert_eq "0" "$rc" "should return 0 when no messages"
    # Inbox should be unchanged (no new entries)
    local inbox_lines
    inbox_lines=$(grep -c '^\- \[ \]' "$env_dir/cross-project/inbox.md" 2>/dev/null; true)
    assert_eq "0" "$inbox_lines" "inbox should have no new entries"
}
run_test "no Telegram messages → no inbox entries" test_no_messages_no_action

# ── 2. Message with @project tag → correct project inbox entry ──────────────

test_tagged_message_creates_inbox_entry() {
    local env_dir
    env_dir=$(create_telegram_env)

    create_mock_afd "$TEST_TMPDIR/bin" '{"id":1,"message":"@social check the latest post engagement","timestamp":"2026-03-19T10:00:00Z","persona":null}'

    setup_telegram_test "$env_dir"

    local output
    output=$(PATH="$TEST_TMPDIR/bin:$PATH" telegram_inbox_check 2>&1)

    assert_file_contains "$env_dir/cross-project/inbox.md" "social" "inbox should contain social project entry"
    assert_file_contains "$env_dir/cross-project/inbox.md" "check the latest post engagement" "inbox should contain message text"
    assert_file_contains "$env_dir/cross-project/inbox.md" "Telegram" "inbox should note Telegram source"
}
run_test "message with @social tag → social inbox entry" test_tagged_message_creates_inbox_entry

# ── 3. Message without @tag → fallback to cfg-agent-fleet ───────────────────

test_untagged_message_goes_to_cfg() {
    local env_dir
    env_dir=$(create_telegram_env)

    create_mock_afd "$TEST_TMPDIR/bin" '{"id":2,"message":"remember to check the NAS backup","timestamp":"2026-03-19T10:05:00Z","persona":null}'

    setup_telegram_test "$env_dir"

    local output
    output=$(PATH="$TEST_TMPDIR/bin:$PATH" telegram_inbox_check 2>&1)

    assert_file_contains "$env_dir/cross-project/inbox.md" "cfg-agent-fleet" "untagged message should go to cfg-agent-fleet"
    assert_file_contains "$env_dir/cross-project/inbox.md" "remember to check the NAS backup" "inbox should contain message text"
}
run_test "message without @tag → cfg-agent-fleet inbox entry" test_untagged_message_goes_to_cfg

# ── 4. Message with @nonexistent tag → fallback to cfg-agent-fleet ──────────

test_unknown_tag_falls_back() {
    local env_dir
    env_dir=$(create_telegram_env)

    create_mock_afd "$TEST_TMPDIR/bin" '{"id":3,"message":"@nonexistent do something","timestamp":"2026-03-19T10:10:00Z","persona":null}'

    setup_telegram_test "$env_dir"

    local output
    output=$(PATH="$TEST_TMPDIR/bin:$PATH" telegram_inbox_check 2>&1)

    assert_file_contains "$env_dir/cross-project/inbox.md" "cfg-agent-fleet" "unknown tag should fallback to cfg-agent-fleet"
    assert_file_contains "$env_dir/cross-project/inbox.md" "@nonexistent do something" "inbox should preserve full message including unknown tag"
}
run_test "message with @nonexistent tag → cfg-agent-fleet fallback" test_unknown_tag_falls_back

# ── 5. Multiple messages → multiple inbox entries ───────────────────────────

test_multiple_messages() {
    local env_dir
    env_dir=$(create_telegram_env)

    create_mock_afd "$TEST_TMPDIR/bin" '{"id":4,"message":"@social post update","timestamp":"2026-03-19T10:00:00Z","persona":null}
{"id":5,"message":"@Alpha check submission status","timestamp":"2026-03-19T10:01:00Z","persona":null}
{"id":6,"message":"general reminder","timestamp":"2026-03-19T10:02:00Z","persona":null}'

    setup_telegram_test "$env_dir"

    local output
    output=$(PATH="$TEST_TMPDIR/bin:$PATH" telegram_inbox_check 2>&1)

    local entry_count
    entry_count=$(grep -c '^\- \[ \]' "$env_dir/cross-project/inbox.md" 2>/dev/null; true)
    assert_eq "3" "$entry_count" "should create 3 inbox entries"

    assert_file_contains "$env_dir/cross-project/inbox.md" "social" "should have social entry"
    assert_file_contains "$env_dir/cross-project/inbox.md" "Alpha" "should have Alpha entry"
    assert_file_contains "$env_dir/cross-project/inbox.md" "cfg-agent-fleet" "should have cfg fallback entry"

    # Check summary output
    assert_contains "$output" "3" "summary should mention count"
    assert_contains "$output" "Telegram" "summary should mention Telegram"
}
run_test "multiple messages → multiple inbox entries with summary" test_multiple_messages

# ── 6. Summary output format ────────────────────────────────────────────────

test_summary_shows_project_routing() {
    local env_dir
    env_dir=$(create_telegram_env)

    create_mock_afd "$TEST_TMPDIR/bin" '{"id":7,"message":"@social check metrics","timestamp":"2026-03-19T10:00:00Z","persona":null}
{"id":8,"message":"@social update profile","timestamp":"2026-03-19T10:01:00Z","persona":null}'

    setup_telegram_test "$env_dir"

    local output
    output=$(PATH="$TEST_TMPDIR/bin:$PATH" telegram_inbox_check 2>&1)

    assert_contains "$output" "social" "summary should list target projects"
}
run_test "summary shows project routing" test_summary_shows_project_routing

# ── 7. afd not available → graceful skip ────────────────────────────────────

test_afd_unavailable_skips() {
    local env_dir
    env_dir=$(create_telegram_env)

    # No mock afd — remove from PATH
    setup_telegram_test "$env_dir"

    local output
    output=$(PATH="/usr/bin:/bin" telegram_inbox_check 2>&1)
    local rc=$?

    assert_eq "0" "$rc" "should return 0 when afd unavailable"
    # Inbox unchanged
    local inbox_lines
    inbox_lines=$(grep -c '^\- \[ \]' "$env_dir/cross-project/inbox.md" 2>/dev/null; true)
    assert_eq "0" "$inbox_lines" "inbox should have no entries when afd unavailable"
}
run_test "afd not available → graceful skip" test_afd_unavailable_skips

# ── 8. Message with @tag at different positions ─────────────────────────────

test_tag_not_at_start() {
    local env_dir
    env_dir=$(create_telegram_env)

    create_mock_afd "$TEST_TMPDIR/bin" '{"id":9,"message":"hey @muse check gallery deployment","timestamp":"2026-03-19T10:00:00Z","persona":null}'

    setup_telegram_test "$env_dir"

    local output
    output=$(PATH="$TEST_TMPDIR/bin:$PATH" telegram_inbox_check 2>&1)

    assert_file_contains "$env_dir/cross-project/inbox.md" "muse" "should find @tag even in middle of message"
}
run_test "@tag in middle of message still routes correctly" test_tag_not_at_start

# ── 9. Case-insensitive tag matching ────────────────────────────────────────

test_case_insensitive_tag() {
    local env_dir
    env_dir=$(create_telegram_env)

    create_mock_afd "$TEST_TMPDIR/bin" '{"id":10,"message":"@Social update bio","timestamp":"2026-03-19T10:00:00Z","persona":null}'

    setup_telegram_test "$env_dir"

    local output
    output=$(PATH="$TEST_TMPDIR/bin:$PATH" telegram_inbox_check 2>&1)

    assert_file_contains "$env_dir/cross-project/inbox.md" "social" "should match case-insensitive"
}
run_test "case-insensitive @tag matching" test_case_insensitive_tag

# ── 10. Inbox entry format ──────────────────────────────────────────────────

test_inbox_entry_format() {
    local env_dir
    env_dir=$(create_telegram_env)

    create_mock_afd "$TEST_TMPDIR/bin" '{"id":11,"message":"@Alpha review chapter 3 edits","timestamp":"2026-03-19T14:30:00Z","persona":null}'

    setup_telegram_test "$env_dir"

    PATH="$TEST_TMPDIR/bin:$PATH" telegram_inbox_check >/dev/null 2>&1

    # Entry format: - [ ] **project**: message text. Source: Telegram YYYY-MM-DD.
    local entry
    entry=$(grep '^\- \[ \]' "$env_dir/cross-project/inbox.md" | head -1)
    assert_contains "$entry" "**Alpha**" "entry should have bold project name"
    assert_contains "$entry" "review chapter 3 edits" "entry should have message text without @tag"
    assert_contains "$entry" "Telegram" "entry should note Telegram source"
    local today
    today=$(date +%Y-%m-%d)
    assert_contains "$entry" "$today" "entry should have date"
}
run_test "inbox entry follows standard format" test_inbox_entry_format

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
