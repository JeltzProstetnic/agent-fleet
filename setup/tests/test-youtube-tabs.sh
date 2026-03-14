#!/usr/bin/env bash
# Tests for youtube-tabs.sh — Chrome YouTube tab collection
source "$(dirname "$0")/test-helpers.sh"

suite_header "YouTube Tabs (CFG-39)"

SCRIPT="$REPO_ROOT/setup/scripts/youtube-tabs.sh"

# ── Helper: create fake SNSS-like binary with embedded strings ──────────────

# Creates a fake Chrome Sessions file with known YouTube data embedded as
# UTF-16LE strings (which is how Chrome stores titles/URLs in SNSS format)
create_fake_session() {
    local output_file="$1"
    shift
    # Each remaining arg is "title\turl" — we embed them as UTF-16LE strings
    # with some binary padding between records
    > "$output_file"
    for entry in "$@"; do
        local title="${entry%%	*}"
        local url="${entry#*	}"
        # Write title as UTF-16LE (iconv), then some binary noise, then URL
        printf '%s - YouTube' "$title" | iconv -f UTF-8 -t UTF-16LE >> "$output_file"
        # Binary separator (null bytes + random)
        printf '\x00\x00\x01\x02\x03\x00\x00' >> "$output_file"
        printf '%s' "$url" | iconv -f UTF-8 -t UTF-16LE >> "$output_file"
        printf '\x00\x00\x04\x05\x00\x00' >> "$output_file"
    done
}

# ── Test: script exists and is executable ───────────────────────────────────

test_script_exists() {
    assert_file_exists "$SCRIPT"
}
run_test "youtube-tabs.sh exists" test_script_exists

# ── Test: usage/help with no args ───────────────────────────────────────────

test_usage_no_args() {
    local output
    output=$(bash "$SCRIPT" 2>&1) || true
    assert_contains "$output" "Usage"
}
run_test "shows usage with no arguments" test_usage_no_args

# ── Test: save extracts YouTube URLs from session files ─────────────────────

test_save_extracts_urls() {
    local sessions_dir="$TEST_TMPDIR/Sessions"
    mkdir -p "$sessions_dir"

    create_fake_session "$sessions_dir/Tabs_1234567890" \
        "First Video	https://www.youtube.com/watch?v=abc123" \
        "Second Video	https://www.youtube.com/watch?v=def456"

    local output_file="$TEST_TMPDIR/youtube-tabs.json"

    YOUTUBE_TABS_FILE="$output_file" \
    CHROME_SESSIONS_DIR="$sessions_dir" \
    MACHINE_NAME="test-machine" \
        bash "$SCRIPT" save

    assert_file_exists "$output_file"

    # Verify JSON structure and content
    local count
    count=$(python3 -c "import json; d=json.load(open('$output_file')); print(len(d['tabs']))")
    assert_eq "2" "$count" "should have 2 tabs"

    assert_file_contains "$output_file" "abc123"
    assert_file_contains "$output_file" "def456"
    assert_file_contains "$output_file" "First Video"
    assert_file_contains "$output_file" "Second Video"
    assert_file_contains "$output_file" "test-machine"
}
run_test "save extracts YouTube URLs from session files" test_save_extracts_urls

# ── Test: save deduplicates URLs ────────────────────────────────────────────

test_save_deduplicates() {
    local sessions_dir="$TEST_TMPDIR/Sessions"
    mkdir -p "$sessions_dir"

    # Same URL appears in two session files
    create_fake_session "$sessions_dir/Tabs_111" \
        "Same Video	https://www.youtube.com/watch?v=dup111"
    create_fake_session "$sessions_dir/Session_222" \
        "Same Video	https://www.youtube.com/watch?v=dup111"

    local output_file="$TEST_TMPDIR/youtube-tabs.json"

    YOUTUBE_TABS_FILE="$output_file" \
    CHROME_SESSIONS_DIR="$sessions_dir" \
    MACHINE_NAME="test-machine" \
        bash "$SCRIPT" save

    local count
    count=$(python3 -c "import json; d=json.load(open('$output_file')); print(len(d['tabs']))")
    assert_eq "1" "$count" "duplicates should be removed"
}
run_test "save deduplicates identical URLs" test_save_deduplicates

# ── Test: save merges with other machines ───────────────────────────────────

test_save_merges_machines() {
    local sessions_dir="$TEST_TMPDIR/Sessions"
    mkdir -p "$sessions_dir"

    create_fake_session "$sessions_dir/Tabs_111" \
        "WSL Video	https://www.youtube.com/watch?v=wsl001"

    local output_file="$TEST_TMPDIR/youtube-tabs.json"

    # Pre-existing data from another machine
    cat > "$output_file" << 'EXISTING'
{
  "tabs": [
    {
      "url": "https://www.youtube.com/watch?v=deck001",
      "title": "Deck Video",
      "machine": "steamdeck",
      "saved_at": "2026-03-04T10:00:00Z"
    }
  ]
}
EXISTING

    YOUTUBE_TABS_FILE="$output_file" \
    CHROME_SESSIONS_DIR="$sessions_dir" \
    MACHINE_NAME="wsl-test" \
        bash "$SCRIPT" save

    # Should have both machines' tabs
    local count
    count=$(python3 -c "import json; d=json.load(open('$output_file')); print(len(d['tabs']))")
    assert_eq "2" "$count" "should keep tabs from both machines"

    assert_file_contains "$output_file" "deck001"
    assert_file_contains "$output_file" "wsl001"
}
run_test "save merges with tabs from other machines" test_save_merges_machines

# ── Test: save replaces current machine's old entries ───────────────────────

test_save_replaces_own_machine() {
    local sessions_dir="$TEST_TMPDIR/Sessions"
    mkdir -p "$sessions_dir"

    create_fake_session "$sessions_dir/Tabs_111" \
        "New Video	https://www.youtube.com/watch?v=new001"

    local output_file="$TEST_TMPDIR/youtube-tabs.json"

    # Pre-existing data from THIS machine (should be replaced)
    cat > "$output_file" << 'EXISTING'
{
  "tabs": [
    {
      "url": "https://www.youtube.com/watch?v=old001",
      "title": "Old Video",
      "machine": "wsl-test",
      "saved_at": "2026-03-04T10:00:00Z"
    }
  ]
}
EXISTING

    YOUTUBE_TABS_FILE="$output_file" \
    CHROME_SESSIONS_DIR="$sessions_dir" \
    MACHINE_NAME="wsl-test" \
        bash "$SCRIPT" save

    local count
    count=$(python3 -c "import json; d=json.load(open('$output_file')); print(len(d['tabs']))")
    assert_eq "1" "$count" "should replace old entries from same machine"

    assert_file_contains "$output_file" "new001"
    assert_file_not_contains "$output_file" "old001"
}
run_test "save replaces current machine's old entries" test_save_replaces_own_machine

# ── Test: list shows saved tabs ─────────────────────────────────────────────

test_list_shows_tabs() {
    local output_file="$TEST_TMPDIR/youtube-tabs.json"
    cat > "$output_file" << 'DATA'
{
  "tabs": [
    {
      "url": "https://www.youtube.com/watch?v=abc123",
      "title": "Alpha Video",
      "machine": "wsl",
      "saved_at": "2026-03-04T18:00:00Z"
    },
    {
      "url": "https://www.youtube.com/watch?v=def456",
      "title": "Beta Video",
      "machine": "steamdeck",
      "saved_at": "2026-03-04T19:00:00Z"
    }
  ]
}
DATA

    local output
    output=$(YOUTUBE_TABS_FILE="$output_file" bash "$SCRIPT" list)

    assert_contains "$output" "Alpha Video"
    assert_contains "$output" "Beta Video"
    assert_contains "$output" "abc123"
    assert_contains "$output" "def456"
}
run_test "list shows all saved tabs" test_list_shows_tabs

# ── Test: list filters by query ─────────────────────────────────────────────

test_list_filters() {
    local output_file="$TEST_TMPDIR/youtube-tabs.json"
    cat > "$output_file" << 'DATA'
{
  "tabs": [
    {
      "url": "https://www.youtube.com/watch?v=abc123",
      "title": "Star Citizen News",
      "machine": "wsl",
      "saved_at": "2026-03-04T18:00:00Z"
    },
    {
      "url": "https://www.youtube.com/watch?v=def456",
      "title": "Time Crystal Physics",
      "machine": "steamdeck",
      "saved_at": "2026-03-04T19:00:00Z"
    }
  ]
}
DATA

    local output
    output=$(YOUTUBE_TABS_FILE="$output_file" bash "$SCRIPT" list "crystal")

    assert_not_contains "$output" "Star Citizen"
    assert_contains "$output" "Time Crystal"
}
run_test "list filters tabs by query" test_list_filters

# ── Test: open with query ───────────────────────────────────────────────────

test_open_generates_url() {
    local output_file="$TEST_TMPDIR/youtube-tabs.json"
    cat > "$output_file" << 'DATA'
{
  "tabs": [
    {
      "url": "https://www.youtube.com/watch?v=abc123",
      "title": "Star Citizen News",
      "machine": "wsl",
      "saved_at": "2026-03-04T18:00:00Z"
    }
  ]
}
DATA

    # With DRY_RUN, open should print the URL instead of launching browser
    local output
    output=$(YOUTUBE_TABS_FILE="$output_file" DRY_RUN=1 bash "$SCRIPT" open "citizen")

    assert_contains "$output" "abc123"
}
run_test "open finds matching tab URL" test_open_generates_url

# ── Test: open with no match ───────────────────────────────────────────────

test_open_no_match() {
    local output_file="$TEST_TMPDIR/youtube-tabs.json"
    cat > "$output_file" << 'DATA'
{
  "tabs": [
    {
      "url": "https://www.youtube.com/watch?v=abc123",
      "title": "Star Citizen",
      "machine": "wsl",
      "saved_at": "2026-03-04T18:00:00Z"
    }
  ]
}
DATA

    local output
    output=$(YOUTUBE_TABS_FILE="$output_file" DRY_RUN=1 bash "$SCRIPT" open "nonexistent" 2>&1) || true

    assert_contains "$output" "No matching"
}
run_test "open reports no match" test_open_no_match

# ── Test: save with no Chrome sessions dir ──────────────────────────────────

test_save_no_chrome() {
    local output_file="$TEST_TMPDIR/youtube-tabs.json"

    local output
    output=$(YOUTUBE_TABS_FILE="$output_file" \
    CHROME_SESSIONS_DIR="$TEST_TMPDIR/nonexistent" \
    MACHINE_NAME="test" \
        bash "$SCRIPT" save 2>&1) || true

    assert_contains "$output" "not found"
}
run_test "save fails gracefully with no Chrome sessions" test_save_no_chrome

# ── Test: handles tabs without titles ───────────────────────────────────────

test_save_no_title() {
    local sessions_dir="$TEST_TMPDIR/Sessions"
    mkdir -p "$sessions_dir"

    # URL without a preceding title (happens with some session entries)
    # Write just a URL as UTF-16LE without a title
    local f="$sessions_dir/Tabs_111"
    printf '\x00\x00\x01\x02' > "$f"
    printf 'https://www.youtube.com/watch?v=notitle1' | iconv -f UTF-8 -t UTF-16LE >> "$f"
    printf '\x00\x00' >> "$f"

    local output_file="$TEST_TMPDIR/youtube-tabs.json"

    YOUTUBE_TABS_FILE="$output_file" \
    CHROME_SESSIONS_DIR="$sessions_dir" \
    MACHINE_NAME="test" \
        bash "$SCRIPT" save

    assert_file_exists "$output_file"
    assert_file_contains "$output_file" "notitle1"
}
run_test "save handles URLs without titles" test_save_no_title

# ── Test: ignores non-watch YouTube URLs ────────────────────────────────────

test_save_ignores_homepage() {
    local sessions_dir="$TEST_TMPDIR/Sessions"
    mkdir -p "$sessions_dir"

    create_fake_session "$sessions_dir/Tabs_111" \
        "Real Video	https://www.youtube.com/watch?v=real001"

    # Also embed just homepage URLs (not watch pages)
    printf 'https://www.youtube.com/' | iconv -f UTF-8 -t UTF-16LE >> "$sessions_dir/Tabs_111"
    printf '\x00\x00' >> "$sessions_dir/Tabs_111"
    printf 'https://studio.youtube.com/persist_identity' | iconv -f UTF-8 -t UTF-16LE >> "$sessions_dir/Tabs_111"

    local output_file="$TEST_TMPDIR/youtube-tabs.json"

    YOUTUBE_TABS_FILE="$output_file" \
    CHROME_SESSIONS_DIR="$sessions_dir" \
    MACHINE_NAME="test" \
        bash "$SCRIPT" save

    local count
    count=$(python3 -c "import json; d=json.load(open('$output_file')); print(len(d['tabs']))")
    assert_eq "1" "$count" "should only capture watch/shorts URLs"

    assert_file_not_contains "$output_file" "studio.youtube"
    assert_file_not_contains "$output_file" "persist_identity"
}
run_test "save ignores YouTube homepage and studio URLs" test_save_ignores_homepage

suite_summary
