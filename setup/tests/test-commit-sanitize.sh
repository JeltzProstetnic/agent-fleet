#!/usr/bin/env bash
# Tests for sanitize_text() in filtered-push.sh — commit message sanitization
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/filtered-push.sh"

suite_header "filtered-push.sh: commit message sanitization"

# Source just the sanitize_text function from filtered-push.sh
# We extract it by sourcing in a subshell with a guard
extract_sanitize_text() {
    # Source the function definition only (not the main script logic)
    eval "$(sed -n '/^sanitize_text()/,/^}/p' "$SCRIPT")"
}

# ── 1. Email addresses are redacted ─────────────────────────────────────────

test_sanitize_email() {
    extract_sanitize_text
    local input="Fix bug reported by user@example.com in module"
    local result
    result=$(sanitize_text "$input")
    assert_not_contains "$result" "user@example.com" "email should be redacted"
    assert_contains "$result" "[REDACTED-EMAIL]" "should contain redacted marker"
}
run_test "sanitize_text redacts email addresses" test_sanitize_email

# ── 2. Multiple emails in one message ────────────────────────────────────────

test_sanitize_multiple_emails() {
    extract_sanitize_text
    local input="From alice@company.org to bob.smith@domain.co.uk"
    local result
    result=$(sanitize_text "$input")
    assert_not_contains "$result" "alice@company.org"
    assert_not_contains "$result" "bob.smith@domain.co.uk"
}
run_test "sanitize_text redacts multiple email addresses" test_sanitize_multiple_emails

# ── 3. IPv4 addresses are redacted ──────────────────────────────────────────

test_sanitize_ipv4() {
    extract_sanitize_text
    local input="Connected to server at 192.168.1.100 on port 443"
    local result
    result=$(sanitize_text "$input")
    assert_not_contains "$result" "192.168.1.100" "IP should be redacted"
    assert_contains "$result" "[REDACTED-IP]" "should contain redacted marker"
}
run_test "sanitize_text redacts IPv4 addresses" test_sanitize_ipv4

# ── 4. Multiple IPs in one message ──────────────────────────────────────────

test_sanitize_multiple_ips() {
    extract_sanitize_text
    local input="Proxy 10.0.0.1 forwarding to 172.16.254.3"
    local result
    result=$(sanitize_text "$input")
    assert_not_contains "$result" "10.0.0.1"
    assert_not_contains "$result" "172.16.254.3"
}
run_test "sanitize_text redacts multiple IPv4 addresses" test_sanitize_multiple_ips

# ── 5. DESKTOP-* hostnames are redacted ─────────────────────────────────────

test_sanitize_desktop_hostname() {
    extract_sanitize_text
    local input="Session on DESKTOP-32ILURB completed"
    local result
    result=$(sanitize_text "$input")
    assert_not_contains "$result" "DESKTOP-32ILURB" "hostname should be redacted"
    assert_contains "$result" "[REDACTED-HOST]" "should contain redacted marker"
}
run_test "sanitize_text redacts DESKTOP-* hostnames" test_sanitize_desktop_hostname

# ── 6. srv* hostnames are redacted ──────────────────────────────────────────

test_sanitize_srv_hostname() {
    extract_sanitize_text
    local input="Deploy to srv123456 via SSH"
    local result
    result=$(sanitize_text "$input")
    assert_not_contains "$result" "srv123456" "srv hostname should be redacted"
    assert_contains "$result" "[REDACTED-HOST]" "should contain redacted marker"
}
run_test "sanitize_text redacts srv* hostnames" test_sanitize_srv_hostname

# ── 7. Username paths are redacted ──────────────────────────────────────────

test_sanitize_username_in_path() {
    extract_sanitize_text
    local input="File at /home/jeltz/projects/config and /home/gruber/work"
    local result
    result=$(sanitize_text "$input")
    assert_not_contains "$result" "/home/jeltz/" "username path should be redacted"
    assert_not_contains "$result" "/home/gruber/" "username path should be redacted"
    assert_contains "$result" "/home/[REDACTED-USER]/" "should contain redacted user marker"
}
run_test "sanitize_text redacts usernames in /home/ paths" test_sanitize_username_in_path

# ── 8. Windows user paths are redacted ──────────────────────────────────────

test_sanitize_windows_user_path() {
    extract_sanitize_text
    local input="Located at /mnt/c/Users/JohnDoe/Documents/file.txt"
    local result
    result=$(sanitize_text "$input")
    assert_not_contains "$result" "/mnt/c/Users/JohnDoe/" "Windows user path should be redacted"
    assert_contains "$result" "/mnt/c/Users/[REDACTED-USER]/" "should contain redacted user marker"
}
run_test "sanitize_text redacts Windows user paths" test_sanitize_windows_user_path

# ── 9. Clean messages pass through unchanged ────────────────────────────────

test_sanitize_clean_passthrough() {
    extract_sanitize_text
    local input="Fix AFT-32: add commit message sanitization"
    local result
    result=$(sanitize_text "$input")
    assert_eq "$input" "$result" "clean message should pass through unchanged"
}
run_test "clean messages pass through unchanged" test_sanitize_clean_passthrough

# ── 10. Co-Authored-By lines are preserved ──────────────────────────────────

test_sanitize_preserves_coauthor() {
    extract_sanitize_text
    local input="Fix bug

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
    local result
    result=$(sanitize_text "$input")
    assert_contains "$result" "Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>" \
        "Co-Authored-By with noreply should be preserved"
}
run_test "Co-Authored-By lines with noreply are preserved" test_sanitize_preserves_coauthor

# ── 11. Mixed content is fully sanitized ────────────────────────────────────

test_sanitize_mixed_content() {
    extract_sanitize_text
    local input="Fix for user@domain.com on DESKTOP-ABC123 at 10.0.0.5
Updated /home/alice/config"
    local result
    result=$(sanitize_text "$input")
    assert_not_contains "$result" "user@domain.com"
    assert_not_contains "$result" "DESKTOP-ABC123"
    assert_not_contains "$result" "10.0.0.5"
    assert_not_contains "$result" "/home/alice/"
}
run_test "mixed content is fully sanitized" test_sanitize_mixed_content

# ── 12. Multiline commit messages are handled ───────────────────────────────

test_sanitize_multiline() {
    extract_sanitize_text
    local input="Subject line

Body with IP 192.168.0.1 and email test@test.com
More details on DESKTOP-WORKPC"
    local result
    result=$(sanitize_text "$input")
    assert_not_contains "$result" "192.168.0.1"
    assert_not_contains "$result" "test@test.com"
    assert_not_contains "$result" "DESKTOP-WORKPC"
    assert_contains "$result" "Subject line" "subject should survive"
}
run_test "multiline commit messages are handled" test_sanitize_multiline

# ── 13. noreply@ emails are NOT redacted (standard git convention) ──────────

test_sanitize_noreply_preserved() {
    extract_sanitize_text
    local input="Commit by bot <noreply@github.com>"
    local result
    result=$(sanitize_text "$input")
    assert_contains "$result" "noreply@github.com" "noreply emails should be preserved"
}
run_test "noreply@ emails are preserved" test_sanitize_noreply_preserved

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
