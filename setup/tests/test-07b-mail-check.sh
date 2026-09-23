#!/usr/bin/env bash
# checks/07b-platform-env.sh — Check 7b.3, the optional startup mail check.
#
# CFG-676: the check used to name ONE script (`<persona>-mail-check.sh`) and ONE
# output tag, which kept the whole hook Category 3 (never propagated) and
# stranded a security fix in 7b.4 on a single machine. The check is now data-
# driven: any `setup/scripts/*mail-check.sh` is discovered, MAIL_CHECK_SCRIPT
# overrides discovery, and the injected tag is derived from the script's name
# (`acme-mail-check.sh` → `ACME_MAIL:`, `mail-check.sh` → `MAIL:`) so every
# deployment keeps the field name its own CLAUDE.md tells the model to surface.
#
# Runs the REAL 07b sourced in a controlled env: _FORCE_WSL=0 disables the
# wsl.conf auto-fix, a bare CONFIG_REPO makes 7b.2 a no-op, and no session-lock
# lib means 7b.4 is skipped — so only 7b.3 exercises.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/setup/tests/test-helpers.sh"

HOOK_07B="$REPO_ROOT/global/hooks/checks/07b-platform-env.sh"

suite_header "checks/07b — 7b.3 mail check is discovered by pattern and tagged by name (CFG-676)"

# Runner: source 07b with the given CONFIG_REPO, print the resulting INBOX_MSG.
# Extra env (MAIL_CHECK_SCRIPT, MAIL_CHECK_TAG) is inherited from the caller.
_run_7b3() {   # <config_repo>
    local cr="$1" proj="$TEST_TMPDIR/proj"
    mkdir -p "$proj"
    cat > "$TEST_TMPDIR/run07b.sh" << EOF
#!/usr/bin/env bash
export _FORCE_WSL=0
export CONFIG_REPO="$cr" PROJECT_DIR="$proj"
WARNINGS="" INBOX_MSG=""
cd "$proj"
source "$HOOK_07B"
printf '%s' "\$INBOX_MSG"
EOF
    bash "$TEST_TMPDIR/run07b.sh" 2>/dev/null || true
}

# A mail-check script that prints two JSON lines (one message per line), like
# the real ones do; it ignores its arguments (--since 24).
_mk_mail_script() {   # <path>
    mkdir -p "$(dirname "$1")"
    printf '#!/usr/bin/env bash\nprintf '"'"'{"subject":"Invoice 42"}\\n{"subject":"Hello"}\\n'"'"'\n' > "$1"
    chmod +x "$1"
}

test_named_script_discovered_and_tagged() {
    local cr="$TEST_TMPDIR/cr" out
    _mk_mail_script "$cr/setup/scripts/acme-mail-check.sh"
    out="$(_run_7b3 "$cr")"
    assert_eq "ACME_MAIL: 2 message(s) in last 24h: Invoice 42; Hello" "$out" \
        "acme-mail-check.sh is found by pattern and tagged ACME_MAIL (measured: '$out')"
}
run_test "7b.3: <name>-mail-check.sh is discovered and tagged <NAME>_MAIL" test_named_script_discovered_and_tagged

test_plain_script_gets_plain_tag() {
    local cr="$TEST_TMPDIR/cr" out
    _mk_mail_script "$cr/setup/scripts/mail-check.sh"
    out="$(_run_7b3 "$cr")"
    assert_eq "MAIL: 2 message(s) in last 24h: Invoice 42; Hello" "$out" \
        "mail-check.sh (the unprefixed default) is tagged MAIL (measured: '$out')"
}
run_test "7b.3: mail-check.sh is tagged MAIL" test_plain_script_gets_plain_tag

test_env_override_beats_discovery() {
    local cr="$TEST_TMPDIR/cr" out
    # A discoverable decoy that would print a different subject...
    mkdir -p "$cr/setup/scripts"
    printf '#!/usr/bin/env bash\nprintf '"'"'{"subject":"DECOY"}\\n'"'"'\n' > "$cr/setup/scripts/decoy-mail-check.sh"
    chmod +x "$cr/setup/scripts/decoy-mail-check.sh"
    # ...and an explicit script outside the scanned directory.
    _mk_mail_script "$TEST_TMPDIR/elsewhere/ops-mail-check.sh"
    out="$(MAIL_CHECK_SCRIPT="$TEST_TMPDIR/elsewhere/ops-mail-check.sh" _run_7b3 "$cr")"
    assert_eq "OPS_MAIL: 2 message(s) in last 24h: Invoice 42; Hello" "$out" \
        "MAIL_CHECK_SCRIPT wins over discovery and the tag follows ITS name (measured: '$out')"
}
run_test "7b.3: MAIL_CHECK_SCRIPT overrides discovery" test_env_override_beats_discovery

test_tag_override() {
    local cr="$TEST_TMPDIR/cr" out
    _mk_mail_script "$cr/setup/scripts/acme-mail-check.sh"
    out="$(MAIL_CHECK_TAG="CUSTOM" _run_7b3 "$cr")"
    assert_eq "CUSTOM: 2 message(s) in last 24h: Invoice 42; Hello" "$out" \
        "MAIL_CHECK_TAG overrides the derived tag (measured: '$out')"
}
run_test "7b.3: MAIL_CHECK_TAG overrides the derived tag" test_tag_override

test_no_script_is_silent() {
    local cr="$TEST_TMPDIR/cr" out
    mkdir -p "$cr/setup/scripts"
    out="$(_run_7b3 "$cr")"
    assert_eq "" "$out" "no *mail-check.sh → nothing injected (measured: '$out')"
}
run_test "7b.3: no mail-check script → no injection" test_no_script_is_silent

test_empty_output_is_silent() {
    local cr="$TEST_TMPDIR/cr" out
    mkdir -p "$cr/setup/scripts"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$cr/setup/scripts/quiet-mail-check.sh"
    chmod +x "$cr/setup/scripts/quiet-mail-check.sh"
    out="$(_run_7b3 "$cr")"
    assert_eq "" "$out" "a script that prints nothing injects nothing (measured: '$out')"
}
run_test "7b.3: a mail-check script with no messages → no injection" test_empty_output_is_silent

suite_summary
