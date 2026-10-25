#!/usr/bin/env bash
# TDD tests for setup/scripts/lan-sudo.sh — LAN host sudo without unlocking the vault.
# Run: bash setup/tests/test-lan-sudo.sh
#
# Requested 2026-10-25 (P0): "local machines should be sudoable from here without
# needing me to unlock vault, create your own vault use some trick so someone with access
# cant crack it immediately, real security for this not required its all within lan".
# Obfuscation, not security: the store is AES-encrypted with a key derived from a 0600 key
# file AND this machine's machine-id, so a copied store (or store + key file on another box)
# does not open. ssh and the masked prompt are stubbed — no test touches a real host.
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/lan-sudo.sh"
PW='S3cret pass;word$1'

suite_header "lan-sudo.sh (obfuscated LAN sudo store)"

# Stub ssh: records argv and stdin per call; `sudo -S -v` succeeds only for $STUB_GOOD_PW.
# Any other remote command "runs" and exits 0. stdin of each call goes to call-N.stdin.
make_stubs() {
    STUB="$TEST_TMPDIR/stub"; mkdir -p "$STUB"
    MID="$TEST_TMPDIR/machine-id"; echo "0123456789abcdef0123456789abcdef" > "$MID"
    cat > "$STUB/ssh" << 'EOF'
#!/usr/bin/env bash
d="$STUB_DIR"; n=$(( $(ls "$d"/call-*.argv 2>/dev/null | wc -l) + 1 ))
printf '%s\n' "$@" > "$d/call-$n.argv"
cat > "$d/call-$n.stdin"
if grep -q -- 'sudo -S -p "" -v' "$d/call-$n.argv"; then
    [[ "$(head -1 "$d/call-$n.stdin")" == "$STUB_GOOD_PW" ]] && exit 0 || exit 1
fi
exit 0
EOF
    printf '#!/usr/bin/env bash\nprintf "%%s" "$STUB_ASK_PW"\n' > "$STUB/ask"
    chmod +x "$STUB/ssh" "$STUB/ask"
    export STUB_DIR="$STUB" STUB_GOOD_PW="$PW" STUB_ASK_PW="$PW"
    export LAN_SUDO_SSH="$STUB/ssh" LAN_SUDO_ASK="$STUB/ask" LAN_SUDO_MACHINE_ID_FILE="$MID"
}

OUT=""; RC=0
lan() { RC=0; OUT=$(bash "$SCRIPT" "$@" 2>&1) || RC=$?; }
store() { echo "$HOME/.config/fleet-lan-sudo/store.enc"; }
keyf()  { echo "$HOME/.config/fleet-lan-sudo/key"; }

# ── 1: set verifies, stores encrypted, 0600, never echoes the password ───────
test_set_stores_obfuscated() {
    make_stubs
    lan set deck
    assert_eq "0" "$RC" "set must succeed with the right password (got $RC: $OUT)" || return 1
    assert_file_exists "$(store)" "store file must exist" || return 1
    assert_eq "600" "$(stat -c %a "$(store)")" "store must be mode 600" || return 1
    assert_eq "600" "$(stat -c %a "$(keyf)")" "key file must be mode 600" || return 1
    grep -qF "$PW" "$(store)" && { echo "    password in plaintext in the store" >&2; return 1; }
    assert_not_contains "$OUT" "$PW" "set must never print the password"
}
run_test "set: verifies, stores encrypted (0600), never prints the password" test_set_stores_obfuscated

# ── 2: a wrong password is refused and NOT stored ────────────────────────────
test_set_refuses_wrong_password() {
    make_stubs; export STUB_ASK_PW="wrong"
    lan set deck
    assert_neq "0" "$RC" "set must fail when the host rejects the password" || return 1
    lan check deck
    assert_neq "0" "$RC" "a rejected password must not end up stored"
}
run_test "set: a password the host rejects is not stored" test_set_refuses_wrong_password

# ── 3: run pipes the stored password to sudo -S, command staged, not on stdin ─
test_run_uses_stored_password() {
    make_stubs; lan set deck; rm -f "$STUB"/call-*
    lan run deck -- systemctl restart foo
    assert_eq "0" "$RC" "run must succeed (got $RC: $OUT)" || return 1
    local sudo_call; sudo_call=$(grep -l -- 'sudo -S -p ""' "$STUB"/call-*.argv | head -1)
    [[ -n "$sudo_call" ]] || { echo "    no ssh call used sudo -S" >&2; return 1; }
    assert_eq "$PW" "$(head -1 "${sudo_call%.argv}.stdin")" "sudo -S must receive the stored password on stdin" || return 1
    grep -rqF 'systemctl restart foo' "$STUB"/call-*.stdin \
        || { echo "    command was not staged to the host" >&2; return 1; }
    assert_not_contains "$OUT" "$PW" "run must never print the password"
}
run_test "run: stored password goes to sudo -S stdin; command is staged" test_run_uses_stored_password

# ── 4: a host with no stored password uses sudo -n (passwordless, e.g. NUC) ──
test_run_without_password_uses_sudo_n() {
    make_stubs
    lan run nuc -- true
    assert_eq "0" "$RC" "run on a passwordless host must succeed (got $RC: $OUT)" || return 1
    grep -lq -- 'sudo -n' "$STUB"/call-*.argv || { echo "    expected sudo -n for a host with no stored password" >&2; return 1; }
}
run_test "run: host without a stored password falls through to sudo -n" test_run_without_password_uses_sudo_n

# ── 5: store + key copied to another machine (different machine-id) do not open ─
test_copied_store_does_not_open() {
    make_stubs; lan set deck
    echo "ffffffffffffffffffffffffffffffff" > "$MID"
    lan check deck
    assert_neq "0" "$RC" "a different machine-id must not open the store" || return 1
    assert_not_contains "$OUT" "$PW" "a failed open must not print the password"
}
run_test "obfuscation: store + key under another machine-id do not open" test_copied_store_does_not_open

# ── 6: store without its key file does not open ──────────────────────────────
test_store_without_key_does_not_open() {
    make_stubs; lan set deck; rm -f "$(keyf)"
    lan check deck
    assert_neq "0" "$RC" "the store must not open without its key file"
}
run_test "obfuscation: store without the key file does not open" test_store_without_key_does_not_open

# ── 7: a second host does not clobber the first ──────────────────────────────
test_two_hosts() {
    make_stubs; lan set deck
    export STUB_ASK_PW="other-pw" STUB_GOOD_PW="other-pw"; lan set deck2
    assert_eq "0" "$RC" "second set must succeed" || return 1
    lan check deck;  assert_eq "0" "$RC" "deck must still be stored" || return 1
    lan check deck2; assert_eq "0" "$RC" "deck2 must be stored" || return 1
    lan list
    assert_contains "$OUT" "deck2" "list must name stored hosts" || return 1
    assert_not_contains "$OUT" "other-pw" "list must not print passwords"
}
run_test "set/list: two hosts coexist; list names hosts only" test_two_hosts

# ── 8: usage errors ──────────────────────────────────────────────────────────
test_usage() {
    make_stubs
    lan run deck
    assert_neq "0" "$RC" "run without a command must fail" || return 1
    lan bogus
    assert_neq "0" "$RC" "unknown verb must fail"
}
run_test "usage: missing command / unknown verb fail" test_usage

suite_summary
