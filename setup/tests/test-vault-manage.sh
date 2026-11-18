#!/usr/bin/env bash
# Tests for setup/secrets/vault-manage.sh — the encrypted token vault: the encrypt/decrypt
# cycle, the CFG-641 passphrase rules, the KDF count list, `set <dotted.key>` (value on
# stdin), and the `shm` / `shm-clean` browser-login bridge (CFG-785). The edit lock, the
# changed-underneath check, tmpfs scratch, `unset` and `keys` are in
# test-vault-manage-unset.sh (CFG-171 test-file limit). Ported from the config repo's
# suite with CFG-978; every test stages a sandboxed copy of the script with a fixture vault
# under $TEST_TMPDIR, so nothing here touches a real setup/secrets/vault.json{,.enc}.
source "$(dirname "$0")/test-helpers.sh"

VAULT_DIR="$REPO_ROOT/setup/secrets"
VAULT_SCRIPT="$VAULT_DIR/vault-manage.sh"
ITER_T=100000   # ITER in vault-manage.sh — what encrypt writes; the raw-openssl helpers read at it

suite_header "vault-manage.sh (token vault)"

# Helper: stage a sandboxed copy of the vault script (and its key-tree program) with a dummy
# plaintext vault, so tests never touch the real setup/secrets/vault.json{,.enc}.
_stage_sandbox() {
    local sandbox="$TEST_TMPDIR/secrets"
    mkdir -p "$sandbox"
    cp "$VAULT_SCRIPT" "$sandbox/vault-manage.sh"
    [ ! -f "$VAULT_DIR/vault_edit.py" ] || cp "$VAULT_DIR/vault_edit.py" "$sandbox/vault_edit.py"
    cat > "$sandbox/vault.json" <<'JSON'
{
  "_meta": {"comment": "test fixture"},
  "github_personal": {"token": "PASTE_HERE"}
}
JSON
    echo "$sandbox"
}

# Raw openssl, bypassing the script, at an explicit iteration count. Prints the plaintext
# (empty when openssl rejects the padding). Passphrase via env, never argv.
_raw_dec() {  # <enc> <pass> <iter>
    TPASS="$2" openssl enc -aes-256-cbc -d -pbkdf2 -iter "$3" -in "$1" -pass env:TPASS 2>/dev/null || true
}
_raw_enc() {  # <plain> <enc> <pass> <iter>
    TPASS="$3" openssl enc -aes-256-cbc -salt -pbkdf2 -iter "$4" -in "$1" -out "$2" -pass env:TPASS
}

# ── 1. encrypt auto-deletes plaintext on success ─────────────────────────────

test_encrypt_removes_plaintext_after_success() {
    local sandbox; sandbox=$(_stage_sandbox)
    VAULT_PASS="testpass123" VAULT_PASS_CONFIRM="testpass123" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1
    assert_file_exists "$sandbox/vault.json.enc" "encrypt should write .enc"
    assert_file_not_exists "$sandbox/vault.json" \
        "encrypt MUST auto-delete plaintext vault.json after success (stale-plaintext hazard)"
}
run_test "encrypt auto-deletes plaintext after success" test_encrypt_removes_plaintext_after_success

# ── 2. encrypt keeps plaintext if openssl fails ──────────────────────────────

test_encrypt_keeps_plaintext_on_failure() {
    local sandbox; sandbox=$(_stage_sandbox)
    local rc=0
    PATH="$TEST_TMPDIR/no-openssl-bin" VAULT_PASS="testpass123" VAULT_PASS_CONFIRM="testpass123" \
        bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "encrypt should fail when openssl is unavailable"
    assert_file_exists "$sandbox/vault.json" "encrypt must NOT delete plaintext on failure"
}
run_test "encrypt keeps plaintext if openssl fails" test_encrypt_keeps_plaintext_on_failure

# ── 3. decrypt round-trip ─────────────────────────────────────────────────────

test_encrypt_decrypt_roundtrip() {
    local sandbox; sandbox=$(_stage_sandbox)
    local original_content; original_content=$(cat "$sandbox/vault.json")
    VAULT_PASS="rtpass" VAULT_PASS_CONFIRM="rtpass" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1
    assert_file_exists "$sandbox/vault.json.enc" "encrypt produces .enc"
    assert_file_not_exists "$sandbox/vault.json" "encrypt removes plaintext"
    VAULT_PASS="rtpass" bash "$sandbox/vault-manage.sh" decrypt >/dev/null 2>&1
    assert_file_exists "$sandbox/vault.json" "decrypt restores plaintext"
    assert_eq "$original_content" "$(cat "$sandbox/vault.json")" "decrypt yields the original JSON"
    assert_eq "600" "$(stat -c %a "$sandbox/vault.json")" "the decrypted plaintext is mode 600"
}
run_test "encrypt→decrypt roundtrip preserves content" test_encrypt_decrypt_roundtrip

# ── 4. status does not error on either state, and points at keys ─────────────

test_status_works_with_no_plaintext() {
    local sandbox out rc=0; sandbox=$(_stage_sandbox)
    VAULT_PASS="x" VAULT_PASS_CONFIRM="x" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1
    out=$(bash "$sandbox/vault-manage.sh" status 2>&1) || rc=$?
    assert_eq "0" "$rc" "status command should succeed when only .enc exists" || return 1
    assert_contains "$out" "vault-manage.sh keys" "status on an encrypted-only vault points at keys (names need no plaintext)"
}
run_test "status works after encrypt (no plaintext) and points at keys" test_status_works_with_no_plaintext

# ── CFG-641: a typo'd VAULT_PASS must not silently re-encrypt the vault ───────
#
# do_encrypt used to skip its double-entry confirmation whenever VAULT_PASS was set — the
# agent-driven path. A typo then encrypted the vault under a passphrase nobody knew. The
# check that helps a non-interactive caller is proving VAULT_PASS opens the EXISTING vault
# before replacing it, plus a round-trip of the new ciphertext before the plaintext goes.

test_encrypt_rejects_passphrase_that_does_not_open_existing_vault() {
    local sandbox; sandbox=$(_stage_sandbox)
    VAULT_PASS="correctpass123" VAULT_PASS_CONFIRM="correctpass123" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1
    assert_file_exists "$sandbox/vault.json.enc" "setup: first encrypt should succeed" || return 1
    printf '{"edited": true}\n' > "$sandbox/vault.json"
    local rc=0
    VAULT_PASS="correctpass124" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "a passphrase that cannot open the existing vault must ABORT" || return 1
    assert_file_exists "$sandbox/vault.json" "plaintext must survive a rejected encrypt — losing it is the corruption"
    rm -f "$sandbox/vault.json"
    VAULT_PASS="correctpass123" bash "$sandbox/vault-manage.sh" decrypt >/dev/null 2>&1
    assert_file_exists "$sandbox/vault.json" "the original vault must remain openable" || return 1
}
run_test "encrypt aborts on a passphrase that cannot open the existing vault" \
    test_encrypt_rejects_passphrase_that_does_not_open_existing_vault

test_encrypt_still_works_with_the_right_passphrase() {
    local sandbox; sandbox=$(_stage_sandbox)
    VAULT_PASS="rightpass123" VAULT_PASS_CONFIRM="rightpass123" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1
    printf '{"edited": true}\n' > "$sandbox/vault.json"
    local rc=0
    VAULT_PASS="rightpass123" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "the correct passphrase must still re-encrypt normally" || return 1
    assert_file_not_exists "$sandbox/vault.json" "plaintext removed on success as before" || return 1
}
run_test "encrypt still succeeds with the correct passphrase" test_encrypt_still_works_with_the_right_passphrase

test_deliberate_passphrase_change_is_possible() {
    local sandbox; sandbox=$(_stage_sandbox)
    VAULT_PASS="oldpass12345" VAULT_PASS_CONFIRM="oldpass12345" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1
    printf '{"edited": true}\n' > "$sandbox/vault.json"
    local rc=0
    VAULT_ALLOW_NEW_PASSPHRASE=1 VAULT_PASS="newpass67890" VAULT_PASS_CONFIRM="newpass67890" \
        bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "an explicit passphrase change must remain possible" || return 1
    rm -f "$sandbox/vault.json"
    VAULT_PASS="newpass67890" bash "$sandbox/vault-manage.sh" decrypt >/dev/null 2>&1
    assert_file_exists "$sandbox/vault.json" "vault must open with the new passphrase" || return 1
}
run_test "a deliberate passphrase change is still possible via an explicit flag" \
    test_deliberate_passphrase_change_is_possible

# ── CFG-641 (residual): a FRESH passphrase under VAULT_PASS must arrive twice ──

test_fresh_vault_refuses_single_entry_passphrase() {
    local sandbox; sandbox=$(_stage_sandbox)
    local rc=0
    VAULT_PASS="freshpass123" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "a fresh vault under an unconfirmed VAULT_PASS must be REFUSED" || return 1
    assert_file_not_exists "$sandbox/vault.json.enc" "nothing may be written under an unconfirmed passphrase" || return 1
    assert_file_exists "$sandbox/vault.json" "the plaintext must survive the refusal"
}
run_test "fresh vault: unconfirmed VAULT_PASS is refused, plaintext kept" \
    test_fresh_vault_refuses_single_entry_passphrase

test_fresh_vault_refuses_mismatched_confirmation() {
    local sandbox; sandbox=$(_stage_sandbox)
    local rc=0
    VAULT_PASS="freshpass123" VAULT_PASS_CONFIRM="freshpass124" \
        bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "a mismatched VAULT_PASS_CONFIRM must be REFUSED" || return 1
    assert_file_not_exists "$sandbox/vault.json.enc" "nothing may be written on a mismatch" || return 1
    assert_file_exists "$sandbox/vault.json" "the plaintext must survive the refusal"
}
run_test "fresh vault: mismatched VAULT_PASS_CONFIRM is refused" test_fresh_vault_refuses_mismatched_confirmation

test_fresh_vault_accepts_confirmed_passphrase() {
    local sandbox; sandbox=$(_stage_sandbox)
    local rc=0
    VAULT_PASS="freshpass123" VAULT_PASS_CONFIRM="freshpass123" \
        bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "a confirmed fresh passphrase must encrypt" || return 1
    assert_file_not_exists "$sandbox/vault.json" "plaintext removed on success as before" || return 1
    VAULT_PASS="freshpass123" bash "$sandbox/vault-manage.sh" decrypt >/dev/null 2>&1
    assert_file_contains "$sandbox/vault.json" "github_personal" "the vault must open with the confirmed passphrase"
}
run_test "fresh vault: matching VAULT_PASS_CONFIRM encrypts and round-trips" \
    test_fresh_vault_accepts_confirmed_passphrase

test_reencrypt_of_existing_vault_needs_no_confirmation() {
    local sandbox; sandbox=$(_stage_sandbox)
    VAULT_PASS="samepass123" VAULT_PASS_CONFIRM="samepass123" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1
    printf '{"edited": true}\n' > "$sandbox/vault.json"
    local rc=0
    VAULT_PASS="samepass123" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "re-encrypting under the proven passphrase must not demand VAULT_PASS_CONFIRM"
}
run_test "re-encrypt of an existing vault still needs only VAULT_PASS" \
    test_reencrypt_of_existing_vault_needs_no_confirmation

test_passphrase_change_requires_confirmation() {
    local sandbox; sandbox=$(_stage_sandbox)
    VAULT_PASS="oldpass12345" VAULT_PASS_CONFIRM="oldpass12345" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1
    printf '{"edited": true}\n' > "$sandbox/vault.json"
    local rc=0
    VAULT_ALLOW_NEW_PASSPHRASE=1 VAULT_PASS="newpass67890" \
        bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "a passphrase CHANGE without VAULT_PASS_CONFIRM must be REFUSED" || return 1
    assert_file_exists "$sandbox/vault.json" "plaintext must survive the refusal" || return 1
    rm -f "$sandbox/vault.json"
    VAULT_PASS="oldpass12345" bash "$sandbox/vault-manage.sh" decrypt >/dev/null 2>&1
    assert_file_exists "$sandbox/vault.json" "the stored vault must be untouched and open with the old passphrase"
}
run_test "passphrase change: VAULT_ALLOW_NEW_PASSPHRASE without confirmation is refused" \
    test_passphrase_change_requires_confirmation

test_no_prev_ciphertext_is_left_behind() {
    # Prior ciphertexts live in git history (when the vault is committed); a .prev beside
    # the vault would keep data openable with a leaked passphrase outside any history scrub.
    local sandbox; sandbox=$(_stage_sandbox)
    VAULT_PASS="oldpass12345" VAULT_PASS_CONFIRM="oldpass12345" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1
    printf '{"edited": true}\n' > "$sandbox/vault.json"
    VAULT_ALLOW_NEW_PASSPHRASE=1 VAULT_PASS="newpass67890" VAULT_PASS_CONFIRM="newpass67890" \
        bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1 || return 1
    assert_file_exists "$sandbox/vault.json.enc" "the new vault is written" || return 1
    [ ! -e "$sandbox/vault.json.enc.prev" ] || { assert_eq "absent" "present" "no .prev ciphertext may be left beside the vault"; return 1; }
    [ ! -e "$sandbox/vault.json.enc.new" ] || { assert_eq "absent" "present" "no .new ciphertext may be left beside the vault"; return 1; }
}
run_test "re-encrypting leaves no vault.json.enc.prev or .new behind" test_no_prev_ciphertext_is_left_behind

# ── `set` subcommand: edit the vault without the value touching a command line ─
#
# Adding a credential used to mean hand-editing vault.json — which the credential guard
# refuses for an agent, and which puts the value on a command line where `ps` and the
# shell history can see it. `set <dotted.key>` reads the VALUE FROM STDIN so it never
# appears in argv, and does the decrypt-edit-encrypt cycle in one place.

test_set_writes_a_nested_key_from_stdin() {
    local sandbox out; sandbox=$(_stage_sandbox)
    VAULT_PASS="setpass12345" VAULT_PASS_CONFIRM="setpass12345" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1
    out=$(printf 'hunter2hunter2' | VAULT_PASS="setpass12345" \
        bash "$sandbox/vault-manage.sh" set nas.ssh_password 2>&1) || return 1
    assert_not_contains "$out" "hunter2" "set never prints the value" || return 1
    assert_file_not_exists "$sandbox/vault.json" "set must leave no plaintext behind" || return 1
    VAULT_PASS="setpass12345" bash "$sandbox/vault-manage.sh" decrypt >/dev/null 2>&1
    assert_file_contains "$sandbox/vault.json" "ssh_password" "the key must be present" || return 1
    assert_file_contains "$sandbox/vault.json" "hunter2hunter2" "with the value read from stdin" || return 1
    assert_file_contains "$sandbox/vault.json" "github_personal" "existing keys must survive" || return 1
}
run_test "set writes a nested key taken from stdin" test_set_writes_a_nested_key_from_stdin

test_set_refuses_an_empty_value() {
    local sandbox; sandbox=$(_stage_sandbox)
    VAULT_PASS="setpass12345" VAULT_PASS_CONFIRM="setpass12345" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1
    local rc=0 before; before=$(sha256sum < "$sandbox/vault.json.enc")
    printf '' | VAULT_PASS="setpass12345" \
        bash "$sandbox/vault-manage.sh" set nas.ssh_password >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "an empty value must be refused, not silently stored" || return 1
    assert_eq "$before" "$(sha256sum < "$sandbox/vault.json.enc")" "and nothing is written"
}
run_test "set refuses an empty value" test_set_refuses_an_empty_value

test_set_never_puts_the_value_in_argv() {
    local sandbox; sandbox=$(_stage_sandbox)
    VAULT_PASS="setpass12345" VAULT_PASS_CONFIRM="setpass12345" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1
    local rc=0
    printf '' | VAULT_PASS="setpass12345" \
        bash "$sandbox/vault-manage.sh" set nas.ssh_password "secretonargv" >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "a value passed as an argument must be refused" || return 1
}
run_test "set refuses a value passed as a command-line argument" test_set_never_puts_the_value_in_argv

test_set_refuses_a_wrong_passphrase_and_writes_nothing() {
    local sandbox rc=0 before; sandbox=$(_stage_sandbox)
    VAULT_PASS="setpass12345" VAULT_PASS_CONFIRM="setpass12345" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1
    before=$(sha256sum < "$sandbox/vault.json.enc")
    printf 'hunter2hunter2' | VAULT_PASS="wrongpass999" bash "$sandbox/vault-manage.sh" set nas.ssh_password >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "set under a passphrase that cannot open the vault is refused" || return 1
    assert_eq "$before" "$(sha256sum < "$sandbox/vault.json.enc")" "the ciphertext is untouched" || return 1
    assert_file_not_exists "$sandbox/vault.json" "and no plaintext appears"
}
run_test "set refuses a wrong passphrase and writes nothing" test_set_refuses_a_wrong_passphrase_and_writes_nothing

# ── KDF count: encrypt writes ITER; decrypt opens ITER and every ITER_LEGACY count ──
#
# A wrong count fails the padding check like a wrong passphrase, but about one time in 256
# it yields garbage that passes it — so a plaintext counts only when it parses as JSON.

test_encrypt_writes_the_configured_iteration_count() {
    local sandbox; sandbox=$(_stage_sandbox)
    VAULT_PASS="kdfpass12345" VAULT_PASS_CONFIRM="kdfpass12345" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1
    local at_iter at_other
    at_iter=$(_raw_dec "$sandbox/vault.json.enc" "kdfpass12345" "$ITER_T" | grep -c github_personal || true)
    at_other=$(_raw_dec "$sandbox/vault.json.enc" "kdfpass12345" 600000 | grep -c github_personal || true)
    echo "    measured: raw decrypt at $ITER_T finds the key $at_iter time(s); at 600000 $at_other time(s)"
    assert_eq "1" "$at_iter" "encrypt must write a ciphertext that opens at ITER ($ITER_T)" || return 1
    assert_eq "0" "$at_other" "and not at a count the script does not write"
}
run_test "encrypt writes the configured PBKDF2 iteration count" test_encrypt_writes_the_configured_iteration_count

test_decrypt_refuses_a_count_the_script_does_not_know() {
    local sandbox rc=0 out; sandbox=$(_stage_sandbox)
    _raw_enc "$sandbox/vault.json" "$sandbox/vault.json.enc" "anypass12345" 123457
    rm -f "$sandbox/vault.json"
    out=$(VAULT_PASS="anypass12345" bash "$sandbox/vault-manage.sh" decrypt 2>&1) || rc=$?
    echo "    measured: decrypt of a 123457-iteration vault rc=$rc; vault.json present=[$([ -e "$sandbox/vault.json" ] && echo yes || echo no)]"
    assert_neq "0" "$rc" "a ciphertext written at a count the script does not list must be refused" || return 1
    assert_contains "$out" "$ITER_T" "the refusal names the count(s) it tried" || return 1
    assert_file_not_exists "$sandbox/vault.json" "and leaves no plaintext behind"
}
run_test "decrypt refuses a ciphertext at an unlisted iteration count and names the counts it tried" \
    test_decrypt_refuses_a_count_the_script_does_not_know

test_decrypt_rejects_a_plaintext_that_is_not_json() {
    local sandbox; sandbox=$(_stage_sandbox)
    printf 'this is not json\n' > "$sandbox/notjson.txt"
    _raw_enc "$sandbox/notjson.txt" "$sandbox/vault.json.enc" "anypass12345" "$ITER_T"
    rm -f "$sandbox/vault.json"
    local rc=0
    VAULT_PASS="anypass12345" bash "$sandbox/vault-manage.sh" decrypt >/dev/null 2>&1 || rc=$?
    echo "    measured: decrypt of non-JSON content rc=$rc; vault.json present=[$([ -e "$sandbox/vault.json" ] && echo yes || echo no)]"
    assert_neq "0" "$rc" "a decrypt that does not yield JSON must fail" || return 1
    assert_file_not_exists "$sandbox/vault.json" "and must leave no garbage plaintext behind"
}
run_test "decrypt refuses a plaintext that is not JSON (padding false positive guard)" \
    test_decrypt_rejects_a_plaintext_that_is_not_json

test_decrypt_with_wrong_passphrase_leaves_nothing_behind() {
    local sandbox; sandbox=$(_stage_sandbox)
    VAULT_PASS="rightpass123" VAULT_PASS_CONFIRM="rightpass123" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1
    local rc=0
    VAULT_PASS="wrongpass123" bash "$sandbox/vault-manage.sh" decrypt >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "a wrong passphrase must fail at every iteration count" || return 1
    assert_file_not_exists "$sandbox/vault.json" "no plaintext may be left after a failed decrypt"
}
run_test "decrypt with a wrong passphrase fails and leaves no plaintext" \
    test_decrypt_with_wrong_passphrase_leaves_nothing_behind

test_kdf_and_reencrypt() {
    local sandbox out rc=0; sandbox=$(_stage_sandbox)
    VAULT_PASS="kdfpass12345" VAULT_PASS_CONFIRM="kdfpass12345" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1
    out=$(VAULT_PASS="kdfpass12345" bash "$sandbox/vault-manage.sh" kdf 2>&1) || rc=$?
    echo "    measured: rc=$rc [$(printf '%s' "$out" | grep -i iterations)]"
    assert_eq "0" "$rc" "kdf must succeed on the vault encrypt wrote" || return 1
    assert_contains "$out" "$ITER_T (current)" "kdf reports the current count" || return 1
    rc=0; VAULT_PASS="kdfpass12345" bash "$sandbox/vault-manage.sh" reencrypt >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "reencrypt under the vault's own passphrase succeeds" || return 1
    assert_file_not_exists "$sandbox/vault.json" "reencrypt must leave no plaintext behind" || return 1
    assert_eq "1" "$(_raw_dec "$sandbox/vault.json.enc" "kdfpass12345" "$ITER_T" | grep -c github_personal || true)" \
        "the re-encrypted vault still holds the content" || return 1
    rc=0; VAULT_PASS="wrongpass123" bash "$sandbox/vault-manage.sh" kdf >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "kdf with a wrong passphrase must fail"
}
run_test "kdf reports the iteration count; reencrypt rewrites in one step without a plaintext" test_kdf_and_reencrypt

# ── CFG-785: shm <dotted.key> / shm-clean — the /dev/shm browser-login bridge ──
_shm_vault() {   # → sandbox with an encrypted vault holding a login, and an empty fake shm dir
    local sandbox; sandbox=$(_stage_sandbox)
    cat > "$sandbox/vault.json" <<'JSON'
{"broker_web": {"login": "user7", "pw": "s3cr3t-Pa55 word"}, "num": {"pin": 4711}, "empty": {"v": ""}}
JSON
    VAULT_PASS="shmpass123" VAULT_PASS_CONFIRM="shmpass123" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1 || return 1
    mkdir -p "$TEST_TMPDIR/shm"; echo "$sandbox"
}

test_shm_writes_one_value_and_prints_only_path_and_length() {
    local sandbox out rc=0 f; sandbox=$(_shm_vault) || return 1
    out=$(VAULT_SHM_DIR="$TEST_TMPDIR/shm" VAULT_PASS="shmpass123" bash "$sandbox/vault-manage.sh" shm broker_web.pw 2>&1) || rc=$?
    echo "    measured: rc=$rc out=[$(printf '%s' "$out" | grep -E 'path=|length=')]"
    assert_eq "0" "$rc" "shm must succeed" || return 1
    assert_not_contains "$out" "s3cr3t" "shm must never print the value" || return 1
    f=$(printf '%s' "$out" | sed -n 's/.*path=\([^ ]*\).*/\1/p' | head -1)
    assert_contains "$f" "$TEST_TMPDIR/shm/vault-key." "the file lies in the shm dir" || return 1
    assert_eq ".txt" "${f: -4}" "a .txt name (file:// would download anything else)" || return 1
    assert_eq "s3cr3t-Pa55 word" "$(cat "$f")" "exactly the value" || return 1
    assert_eq "16" "$(wc -c < "$f" | tr -d ' ')" "no trailing newline (a newline would be typed into the field)" || return 1
    assert_eq "600" "$(stat -c %a "$f")" "mode 600" || return 1
    assert_contains "$out" "length=16" "the length is reported" || return 1
    assert_file_not_exists "$sandbox/vault.json" "no plaintext vault left beside the script" || return 1
    assert_eq "1" "$(ls "$TEST_TMPDIR/shm" | wc -l)" "only the key file in the shm dir (decrypt scratch shredded)" || return 1
    out=$(VAULT_SHM_DIR="$TEST_TMPDIR/shm" VAULT_PASS="shmpass123" bash "$sandbox/vault-manage.sh" shm num.pin 2>&1) || return 1
    f=$(printf '%s' "$out" | sed -n 's/.*path=\([^ ]*\).*/\1/p' | head -1)
    assert_eq "4711" "$(cat "$f")" "a number is written as its digits"
}
run_test "CFG-785: shm writes one value into a 600 .txt under the shm dir, prints path + length only" \
    test_shm_writes_one_value_and_prints_only_path_and_length

test_shm_refuses_and_leaves_nothing() {
    local sandbox rc out k; sandbox=$(_shm_vault) || return 1
    for k in "broker_web.nope" "broker_web" "empty.v"; do
        rc=0; out=$(VAULT_SHM_DIR="$TEST_TMPDIR/shm" VAULT_PASS="shmpass123" bash "$sandbox/vault-manage.sh" shm "$k" 2>&1) || rc=$?
        assert_neq "0" "$rc" "shm $k must fail" || return 1
        assert_not_contains "$out" "s3cr3t" "no value in the error for $k" || return 1
    done
    rc=0; out=$(VAULT_SHM_DIR="$TEST_TMPDIR/shm" VAULT_PASS="shmpass123" bash "$sandbox/vault-manage.sh" shm broker_web 2>&1) || rc=$?
    assert_contains "$out" "login, pw" "an object names its sub-keys (names are not secrets)" || return 1
    rc=0; VAULT_SHM_DIR="$TEST_TMPDIR/shm" VAULT_PASS="wrongpass99" bash "$sandbox/vault-manage.sh" shm broker_web.pw >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "a wrong passphrase fails" || return 1
    rc=0; VAULT_SHM_DIR="$TEST_TMPDIR/shm" VAULT_PASS="shmpass123" bash "$sandbox/vault-manage.sh" shm a.b extra >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "an extra argument is a usage error" || return 1
    assert_eq "0" "$(ls -A "$TEST_TMPDIR/shm" | wc -l)" "every failure leaves the shm dir empty" || return 1
    assert_file_not_exists "$sandbox/vault.json" "and no plaintext vault"
}
run_test "CFG-785: shm refuses a missing key, an object, an empty value, a wrong passphrase, extra args — nothing left" \
    test_shm_refuses_and_leaves_nothing

test_shm_clean_shreds_bridge_files_only() {
    local sandbox out f rc; sandbox=$(_shm_vault) || return 1
    out=$(VAULT_SHM_DIR="$TEST_TMPDIR/shm" VAULT_PASS="shmpass123" bash "$sandbox/vault-manage.sh" shm broker_web.login 2>&1) || return 1
    f=$(printf '%s' "$out" | sed -n 's/.*path=\([^ ]*\).*/\1/p' | head -1)
    printf 'keep' > "$TEST_TMPDIR/shm/other.txt"; printf 'keep' > "$TEST_TMPDIR/vault-key.zzzzzz.txt"
    rc=0; VAULT_SHM_DIR="$TEST_TMPDIR/shm" bash "$sandbox/vault-manage.sh" shm-clean "$TEST_TMPDIR/shm/other.txt" >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "a file that is not a bridge file is refused" || return 1
    rc=0; VAULT_SHM_DIR="$TEST_TMPDIR/shm" bash "$sandbox/vault-manage.sh" shm-clean "$TEST_TMPDIR/vault-key.zzzzzz.txt" >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "a bridge-named file outside the shm dir is refused" || return 1
    assert_file_exists "$TEST_TMPDIR/vault-key.zzzzzz.txt" "and kept" || return 1
    VAULT_SHM_DIR="$TEST_TMPDIR/shm" bash "$sandbox/vault-manage.sh" shm-clean "$f" >/dev/null 2>&1 || return 1
    assert_file_not_exists "$f" "the named bridge file is gone" || return 1
    VAULT_SHM_DIR="$TEST_TMPDIR/shm" VAULT_PASS="shmpass123" bash "$sandbox/vault-manage.sh" shm broker_web.login >/dev/null 2>&1 || return 1
    VAULT_SHM_DIR="$TEST_TMPDIR/shm" VAULT_PASS="shmpass123" bash "$sandbox/vault-manage.sh" shm num.pin >/dev/null 2>&1 || return 1
    out=$(VAULT_SHM_DIR="$TEST_TMPDIR/shm" bash "$sandbox/vault-manage.sh" shm-clean 2>&1) || return 1
    echo "    measured: [$(printf '%s' "$out" | grep -i shredded)] left=$(ls "$TEST_TMPDIR/shm" | tr '\n' ' ')"
    assert_contains "$out" "Shredded 2" "no argument: every bridge file in the shm dir" || return 1
    assert_eq "other.txt" "$(ls "$TEST_TMPDIR/shm")" "anything else in the shm dir is untouched"
}
run_test "CFG-785: shm-clean shreds a named bridge file or all of them, refuses anything else" \
    test_shm_clean_shreds_bridge_files_only

# ── deploy: a vault filled key by key, an MCP config shaped by the user, a failure ──
#
# CFG-978 review (MAJOR-3): deploy_mcp_tokens hard-indexed ['env'] and sub-keys, so a github
# server block without `env`, a twitter entry holding only api_key, or a ~/.mcp.json that is a
# symlink to the cc-mirror config (shutil.copy2 SameFileError) crashed the deploy — and the
# vault.json deploy had just decrypted stayed on disk. HOME is the test sandbox, so every
# ~/.mcp.json here is a fixture.
_deploy_vault() {   # <vault-json> → sandbox with that vault encrypted; no plaintext left
    local sandbox; sandbox=$(_stage_sandbox)
    printf '%s\n' "$1" > "$sandbox/vault.json"
    VAULT_PASS="deploypass123" VAULT_PASS_CONFIRM="deploypass123" bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1 || return 1
    echo "$sandbox"
}
_deploy() {         # <sandbox> → rc; OUT holds the output (non-interactive: stdin is not a terminal)
    local rc=0; OUT=$(VAULT_PASS="deploypass123" bash "$1/vault-manage.sh" deploy </dev/null 2>&1) || rc=$?; return $rc
}
_mcp_env() {        # <file> <server> <env key> → the value, or "-" when absent
    python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["mcpServers"].get(sys.argv[2],{}).get("env",{}).get(sys.argv[3],"-"))' "$@"
}

test_deploy_fills_a_server_block_that_has_no_env() {
    local sb rc=0; sb=$(_deploy_vault '{"_meta":{"c":"x"},"github_personal":{"token":"ghpDeployToken000001"}}') || return 1
    printf '{"mcpServers":{"github":{"command":"x"}}}\n' > "$HOME/.mcp.json"
    _deploy "$sb" || rc=$?
    echo "    measured: rc=$rc token-deployed=$(_mcp_env "$HOME/.mcp.json" github GITHUB_PERSONAL_ACCESS_TOKEN | sed 's/^ghpDeploy.*/<fixture>/') vault.json-left=$([ -e "$sb/vault.json" ] && echo yes || echo no)"
    assert_eq "0" "$rc" "a github block without env must not crash the deploy" || return 1
    assert_not_contains "$OUT" "Traceback" "no python traceback" || return 1
    assert_eq "ghpDeployToken000001" "$(_mcp_env "$HOME/.mcp.json" github GITHUB_PERSONAL_ACCESS_TOKEN)" "the token lands in a created env block" || return 1
    assert_file_not_exists "$sb/vault.json" "the plaintext deploy decrypted is gone afterwards"
}
run_test "deploy fills an MCP server block that has no env yet (setdefault), leaves no plaintext" \
    test_deploy_fills_a_server_block_that_has_no_env

test_deploy_with_a_symlinked_user_mcp_config() {
    local sb rc=0 real="$HOME/.cc-mirror/mclaude/config/.mcp.json"
    sb=$(_deploy_vault '{"github_personal":{"token":"ghpDeployToken000002"}}') || return 1
    mkdir -p "$(dirname "$real")"
    printf '{"mcpServers":{"github":{"command":"x","env":{"GITHUB_PERSONAL_ACCESS_TOKEN":"old"}}}}\n' > "$real"
    ln -s "$real" "$HOME/.mcp.json"
    _deploy "$sb" || rc=$?
    echo "    measured: rc=$rc SameFileError=$(printf '%s' "$OUT" | grep -c SameFileError || true) symlink-kept=$([ -L "$HOME/.mcp.json" ] && echo yes || echo no) vault.json-left=$([ -e "$sb/vault.json" ] && echo yes || echo no)"
    assert_eq "0" "$rc" "a ~/.mcp.json that is a symlink to the cc-mirror config must not crash the deploy" || return 1
    assert_not_contains "$OUT" "SameFileError" "no SameFileError" || return 1
    assert_eq "ghpDeployToken000002" "$(_mcp_env "$real" github GITHUB_PERSONAL_ACCESS_TOKEN)" "the token is written to the real file" || return 1
    [ -L "$HOME/.mcp.json" ] || { assert_eq "symlink" "file" "the user-level symlink is kept, not replaced by a copy"; return 1; }
    assert_file_not_exists "$sb/vault.json" "no plaintext left"
}
run_test "deploy with a symlinked user-level MCP config: no SameFileError, symlink kept, no plaintext" \
    test_deploy_with_a_symlinked_user_mcp_config

test_deploy_takes_a_vault_filled_key_by_key() {
    # A vault built with `set` holds whatever keys were set so far — a twitter entry with only
    # api_key, a google entry without email, a jira entry with only the token.
    local sb rc=0; sb=$(_deploy_vault '{"twitter": {"api_key": "twDeployKey00000001"}, "google_workspace": {"client_id": "gwDeployId0001.apps", "client_secret": "GW_DEPLOY_SECRET_PLACEHOLDER"}, "jira": {"api_token": "jiraDeployTok0001"}, "linkedin": {"access_token": "liDeployTok000001"}}') || return 1
    printf '{"mcpServers":{"twitter":{"command":"x"},"google-workspace":{"command":"x","env":{}},"jira":{"command":"x"},"linkedin":{"command":"x"}}}\n' > "$HOME/.mcp.json"
    _deploy "$sb" || rc=$?
    echo "    measured: rc=$rc twitter.API_KEY=$(_mcp_env "$HOME/.mcp.json" twitter API_KEY | sed 's/^twDeploy.*/<fixture>/') twitter.API_SECRET_KEY=$(_mcp_env "$HOME/.mcp.json" twitter API_SECRET_KEY) google.ID=$(_mcp_env "$HOME/.mcp.json" google-workspace GOOGLE_OAUTH_CLIENT_ID | sed 's/^gwDeploy.*/<fixture>/') vault.json-left=$([ -e "$sb/vault.json" ] && echo yes || echo no)"
    assert_eq "0" "$rc" "partial entries must not crash the deploy" || return 1
    assert_not_contains "$OUT" "Traceback" "no python traceback" || return 1
    assert_eq "twDeployKey00000001" "$(_mcp_env "$HOME/.mcp.json" twitter API_KEY)" "the twitter key that exists is deployed" || return 1
    assert_eq "-" "$(_mcp_env "$HOME/.mcp.json" twitter API_SECRET_KEY)" "a missing sub-key is left out, not written as an error" || return 1
    assert_eq "gwDeployId0001.apps" "$(_mcp_env "$HOME/.mcp.json" google-workspace GOOGLE_OAUTH_CLIENT_ID)" "google client id deployed without an email field" || return 1
    assert_eq "jiraDeployTok0001" "$(_mcp_env "$HOME/.mcp.json" jira JIRA_API_TOKEN)" "jira token deployed into a created env" || return 1
    assert_eq "liDeployTok000001" "$(_mcp_env "$HOME/.mcp.json" linkedin LINKEDIN_ACCESS_TOKEN)" "linkedin token deployed into a created env" || return 1
    assert_file_not_exists "$sb/vault.json" "no plaintext left"
}
run_test "deploy takes a vault filled key by key (partial twitter/google/jira/linkedin entries)" \
    test_deploy_takes_a_vault_filled_key_by_key

test_deploy_failure_shreds_the_plaintext_it_decrypted() {
    local sb rc=0 before; sb=$(_deploy_vault '{"github_personal":{"token":"ghpDeployToken000003"}}') || return 1
    before=$(sha256sum < "$sb/vault.json.enc")
    printf 'not json at all\n' > "$HOME/.mcp.json"
    _deploy "$sb" || rc=$?
    echo "    measured (deploy decrypted): rc=$rc vault.json-left=$([ -e "$sb/vault.json" ] && echo yes || echo no) [$(printf '%s' "$OUT" | grep -E 'ERROR|shred' | tr '\n' '|')]"
    assert_neq "0" "$rc" "a broken MCP config fails the deploy" || return 1
    assert_file_not_exists "$sb/vault.json" "the vault.json deploy decrypted for itself is shredded on failure" || return 1
    assert_contains "$OUT" "shredded" "and the run says so" || return 1
    assert_eq "$before" "$(sha256sum < "$sb/vault.json.enc")" "the ciphertext is untouched" || return 1
    # A vault.json the USER decrypted beforehand is theirs: a failed deploy leaves it alone.
    VAULT_PASS="deploypass123" bash "$sb/vault-manage.sh" decrypt >/dev/null 2>&1 || return 1
    rc=0; _deploy "$sb" || rc=$?
    echo "    measured (user's plaintext): rc=$rc vault.json-left=$([ -e "$sb/vault.json" ] && echo yes || echo no)"
    assert_neq "0" "$rc" "still fails" || return 1
    assert_file_exists "$sb/vault.json" "a plaintext the user decrypted is not shredded by a failed deploy"
}
run_test "a failed deploy shreds the plaintext it decrypted itself, never one the user decrypted" \
    test_deploy_failure_shreds_the_plaintext_it_decrypted

# ── the usage text names every verb the knowledge file documents ─────────────
test_usage_lists_every_verb() {
    local sandbox out v; sandbox=$(_stage_sandbox)
    out=$(bash "$sandbox/vault-manage.sh" help 2>&1 || true)
    for v in "encrypt" "decrypt" "deploy" "status" "keys [<prefix>]" "set <key>" "unset <key>" "shm <key>" "shm-clean" "reencrypt" "kdf"; do
        assert_contains "$out" "$v" "the usage text lists $v" || return 1
    done
}
run_test "the usage text lists every verb (encrypt, decrypt, deploy, status, keys, set, unset, shm, shm-clean, reencrypt, kdf)" \
    test_usage_lists_every_verb

suite_summary
