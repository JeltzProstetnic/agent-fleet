#!/usr/bin/env bash
# test-nas-address-lint.sh — fleet code addresses network storage by NAME, never by IP (CFG-600)
#
# ⛔ The NAS is on DHCP. When its lease moved after a power outage, every script and mount
#    that carried the old number hit a DIFFERENT device that answers ping but refuses every
#    port — which looks exactly like a dead NAS. The hostname survives a lease change.
# The lint is generic (any IPv4 in an SMB target or a NAS_* assignment), so it names no
# address itself. Comments are exempt: dated history may quote the old number. Tests are
# exempt: fixtures deliberately carry IPs (fix-nas-mount.sh rewrites them).
source "$(dirname "$0")/test-helpers.sh"

suite_header "NAS address lint (CFG-600: hostname, never a DHCP lease)"

IPV4='[0-9]{1,3}(\.[0-9]{1,3}){3}'

# Print every offending "file:line:text" under <root>; silent when clean.
scan_for_nas_ips() {
    local root="$1" files
    if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        files=$(git -C "$root" ls-files)
    else
        files=$(cd "$root" && find . -type f | sed 's|^\./||')
    fi
    printf '%s\n' "$files" \
        | grep -vE '^(setup/tests|dms/tests)/' \
        | grep -E '\.(sh|bash|py|conf|service|mount|automount|json|bat|cmd|ps1)$|^sync\.sh$' \
        | while IFS= read -r f; do
            [[ -f "$root/$f" ]] || continue
            # //IP/ (fstab/mount/UNC-style, not after a URL scheme's ':'), smb:// or cifs://
            # with an IP, a Windows \\IP\ path, `smbclient -L IP`, a NAS_* assignment.
            # Only a '//' followed by whitespace counts as a comment: '//IP/share' at the start
            # of a line is the fstab form itself.
            grep -nE "(^|[^:])//${IPV4}/|(smb|cifs)://${IPV4}|\\\\\\\\${IPV4}\\\\|smbclient[^#]*-L[[:space:]]*${IPV4}|NAS[A-Z_]*=[^#]*${IPV4}" "$root/$f" 2>/dev/null \
                | grep -vE '^[0-9]+:[[:space:]]*(#|REM |::|//([[:space:]]|$))' \
                | sed "s|^|$f:|"
        done
}

test_lint_catches_ip_targets() {
    mkdir -p "$TEST_TMPDIR/repo/scripts" "$TEST_TMPDIR/repo/setup/tests"
    printf 'NAS_HOST="${X:-10.1.2.3}"\n' > "$TEST_TMPDIR/repo/scripts/a.sh"
    printf 'mount -t cifs //10.1.2.3/Public /mnt/nas\n' > "$TEST_TMPDIR/repo/scripts/b.sh"
    printf 'net use Z: \\\\10.1.2.3\\Public\n' > "$TEST_TMPDIR/repo/scripts/c.bat"
    printf '# history: it used to live at //10.1.2.3/Public\n' > "$TEST_TMPDIR/repo/scripts/ok-comment.sh"
    printf 'NAS_HOST="${X:-MYNAS}"\n' > "$TEST_TMPDIR/repo/scripts/ok-name.sh"
    printf 'echo //10.1.2.3/Public\n' > "$TEST_TMPDIR/repo/setup/tests/test-fixture.sh"
    local out
    out=$(scan_for_nas_ips "$TEST_TMPDIR/repo")
    assert_contains "$out" "scripts/a.sh:1:" "NAS_* assignment with an IP" || return 1
    assert_contains "$out" "scripts/b.sh:1:" "SMB target with an IP" || return 1
    assert_contains "$out" "scripts/c.bat:1:" "Windows UNC path with an IP" || return 1
    assert_not_contains "$out" "ok-comment" "comments may quote history" || return 1
    assert_not_contains "$out" "ok-name" "a hostname is the fix" || return 1
    assert_not_contains "$out" "setup/tests/" "test fixtures are exempt"
}
run_test "the lint catches IP-addressed NAS targets (and only those)" test_lint_catches_ip_targets

test_lint_catches_fstab_and_smbclient_forms() {
    # Review of the first cut: a line STARTING with '//' was exempted as a comment, so the
    # canonical fstab form written through a heredoc slipped through; `smbclient -L <ip>` and
    # smb:// URLs were not matched at all.
    mkdir -p "$TEST_TMPDIR/repo/scripts"
    printf 'cat >> /etc/fstab <<EOF\n//10.1.2.3/Public /mnt/nas cifs guest 0 0\nEOF\n' > "$TEST_TMPDIR/repo/scripts/fstab.sh"
    printf 'smbclient -N -L 10.1.2.3\n' > "$TEST_TMPDIR/repo/scripts/probe.sh"
    printf 'xdg-open smb://10.1.2.3/Public\n' > "$TEST_TMPDIR/repo/scripts/open.sh"
    printf '// a C-style comment mentioning //10.1.2.3/Public\n' > "$TEST_TMPDIR/repo/scripts/ok-slashcomment.sh"
    local out
    out=$(scan_for_nas_ips "$TEST_TMPDIR/repo")
    assert_contains "$out" "scripts/fstab.sh:2:" "fstab line (starts with //)" || return 1
    assert_contains "$out" "scripts/probe.sh:1:" "smbclient -L with an IP" || return 1
    assert_contains "$out" "scripts/open.sh:1:" "smb:// URL with an IP" || return 1
    assert_not_contains "$out" "ok-slashcomment" "a real // comment is still exempt"
}
run_test "the lint catches the fstab, smbclient -L and smb:// forms" test_lint_catches_fstab_and_smbclient_forms

test_lint_ignores_http_urls() {
    # `//IPv4/` alone matched every http URL with an IP and a path — unrelated code (a health
    # check, a router admin URL) would turn the suite red.
    mkdir -p "$TEST_TMPDIR/repo/scripts"
    printf 'curl -fsS http://127.0.0.1/health\n' > "$TEST_TMPDIR/repo/scripts/health.sh"
    printf 'URL=http://192.168.1.1/admin\n' > "$TEST_TMPDIR/repo/scripts/router.sh"
    local out
    out=$(scan_for_nas_ips "$TEST_TMPDIR/repo")
    assert_eq "" "$out" "http(s) URLs are not NAS targets"
}
run_test "the lint does not flag http(s) URLs that carry an IP" test_lint_ignores_http_urls

test_repo_has_no_ip_addressed_nas() {
    local out
    out=$(scan_for_nas_ips "$REPO_ROOT")
    if [[ -n "$out" ]]; then
        printf '    NAS addressed by IP (use the hostname):\n%s\n' "$(sed 's/^/      /' <<<"$out")"
        return 1
    fi
}
run_test "no fleet script or config addresses the NAS by IP" test_repo_has_no_ip_addressed_nas

suite_summary
