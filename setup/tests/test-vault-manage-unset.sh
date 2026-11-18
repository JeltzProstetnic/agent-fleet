#!/usr/bin/env bash
# Tests for setup/secrets/vault-manage.sh — the key-editing verbs `unset` and `keys`, plus
# what every edit owes the caller: one lock around the read-modify-write, a refusal when the
# ciphertext changed underneath, and decrypted scratch that lives in tmpfs and is shredded on
# any exit, a signal included. Split from test-vault-manage.sh (CFG-171 test-file limit).
# Ported from the config repo's suite with CFG-978 (CFG-1008 and its review rounds): INT/TERM/HUP
# mid-set/reencrypt/unset/keys leave no plaintext outside tmpfs; the lock is taken after the
# prompts and held by every edit verb; a pattern needs --yes; _meta is refused; the unset/keys
# program is setup/secrets/vault_edit.py. Fixture vaults and passphrases only.
source "$(dirname "$0")/test-helpers.sh"

VAULT_DIR="$REPO_ROOT/setup/secrets"
VAULT_SCRIPT="$VAULT_DIR/vault-manage.sh"
PASS="unsetpass123"
ITER_T=100000   # ITER in vault-manage.sh — the raw-openssl helpers read and write at it

suite_header "vault-manage.sh unset / keys / edit lock"

# ── helpers ──────────────────────────────────────────────────────────────────
_raw_dec() {  # <enc> <pass> <iter> → plaintext on stdout (empty when openssl refuses)
    TPASS="$2" openssl enc -aes-256-cbc -d -pbkdf2 -iter "$3" -in "$1" -pass env:TPASS 2>/dev/null || true
}
_raw_enc() {  # <plain> <enc> <pass> <iter>
    TPASS="$3" openssl enc -aes-256-cbc -salt -pbkdf2 -iter "$4" -in "$1" -out "$2" -pass env:TPASS
}
_unset_vault() {   # → sandbox with an encrypted fixture vault; empty scratch dirs $TEST_TMPDIR/{tmp,ram}
    local sandbox="$TEST_TMPDIR/secrets"
    mkdir -p "$sandbox" "$TEST_TMPDIR/tmp" "$TEST_TMPDIR/ram"
    cp "$VAULT_SCRIPT" "$sandbox/vault-manage.sh"
    [ ! -f "$VAULT_DIR/vault_edit.py" ] || cp "$VAULT_DIR/vault_edit.py" "$sandbox/vault_edit.py"
    cat > "$sandbox/vault.json" <<'JSON'
{"_meta": {"comment": "test fixture"}, "github_personal": {"token": "ghpUnsetKeep0001"},
 "old_survey_admin_pw": {"_owner": "infrastructure", "deploy_to": "vps:/opt/svc/.env", "note": "survey", "value": "svcAdminS3cret01"},
 "old_survey_oauth": {"client_id": "cid-svc", "client_key": "svcOauthS3cret02"},
 "nested": {"inner": {"leaf": "nestLeafS3cret03"}, "keep": "nestKeepS3cret04"}, "empty_obj": {}}
JSON
    VAULT_PASS="$PASS" VAULT_PASS_CONFIRM="$PASS" VAULT_SHM_DIR="$TEST_TMPDIR/ram" TMPDIR="$TEST_TMPDIR/tmp" \
        bash "$sandbox/vault-manage.sh" encrypt >/dev/null 2>&1 || return 1
    echo "$sandbox"
}
_vault_json() {    # <sandbox> → the vault as sorted one-line JSON, via raw openssl (no file written)
    _raw_dec "$1/vault.json.enc" "$PASS" "$ITER_T" \
        | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))'
}
_top() {           # <sandbox> → the vault's top-level key names, space-separated (for measured lines)
    _raw_dec "$1/vault.json.enc" "$PASS" "$ITER_T" \
        | python3 -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin))))'
}
_scratch_left() {  # → how many files remain in the two scratch dirs (TMPDIR and the tmpfs stand-in)
    find "$TEST_TMPDIR/tmp" "$TEST_TMPDIR/ram" -mindepth 1 2>/dev/null | wc -l | tr -d ' '
}
# An openssl wrapper that logs its argv (never the fd-3 passphrase) to calls.log. With
# OSSL_GATE=<dir> and OSSL_GATE_ON=enc (the encrypt), rt (the round-trip decrypt of the
# .new file), dec (a decrypt of the vault itself) or any (every call) the matching call
# touches <dir>/started, waits for <dir>/go, runs, then touches <dir>/done — a
# deterministic pause inside a running rewrite. The patterns match whole words: a scratch
# name like vault-dec.* contains "-d", so a substring match on the encrypt
# (… -in …/vault-dec.X -out vault.json.enc.new) would gate the wrong call.
_ossl() {
    local d="$TEST_TMPDIR/osslbin" real; real=$(command -v openssl); mkdir -p "$d"
    cat > "$d/openssl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/calls.log"
gate=""
case "\${OSSL_GATE_ON:-}:\$* " in enc:*" -salt "*|rt:*" -d "*"-in "*".new "*|dec:*" -in vault.json.enc "*|any:*) gate="\${OSSL_GATE:-}" ;; esac
[ -n "\$gate" ] || exec "$real" "\$@"
touch "\$gate/started"; n=0
while [ ! -e "\$gate/go" ] && [ "\$n" -lt 600 ]; do sleep 0.1; n=\$((n + 1)); done
"$real" "\$@"; rc=\$?; touch "\$gate/done"; exit "\$rc"
EOF
    chmod +x "$d/openssl"; echo "$d"
}
_wait_file() {     # <file> <tenths> — 0 once it exists
    local n=0; while [ ! -e "$1" ] && [ "$n" -lt "$2" ]; do sleep 0.1; n=$((n + 1)); done; [ -e "$1" ]
}
_wait_gone() {     # <pid> <tenths> — 0 once the process has exited
    local n=0; while kill -0 "$1" 2>/dev/null && [ "$n" -lt "$2" ]; do sleep 0.1; n=$((n + 1)); done
    ! kill -0 "$1" 2>/dev/null
}
_vm() {            # <sandbox> <openssl-dir|-> <pass> <verb> [args…] — scratch dirs inside the test dir
    local sb="$1" od="$2" pw="$3"; shift 3
    local p="$PATH"; [ "$od" = "-" ] || p="$od:$PATH"
    PATH="$p" TMPDIR="$TEST_TMPDIR/tmp" VAULT_SHM_DIR="$TEST_TMPDIR/ram" VAULT_PASS="$pw" \
        bash "$sb/vault-manage.sh" "$@"
}
_unset() { local sb="$1" od="$2" pw="$3"; shift 3; _vm "$sb" "$od" "$pw" unset "$@"; }
_encs() { grep -c -- '-salt' "$1/calls.log" 2>/dev/null || true; }
_lock_free() { flock -n "$1/.vault.lock" true; }   # <sandbox> — 0 while no run holds the edit lock
_wait_text() {     # <file> <fixed string> <tenths> — 0 once the file contains it
    local n=0; while ! grep -qF -- "$2" "$1" 2>/dev/null && [ "$n" -lt "$3" ]; do sleep 0.1; n=$((n + 1)); done
    grep -qF -- "$2" "$1" 2>/dev/null
}
_plain_on_disk() { # <sandbox> → a vault.json beside the script, or any file outside the tmpfs stand-in holding a fixture secret
    { [ ! -e "$1/vault.json" ] || echo vault.json
      grep -rlF -e nestKeepS3cret04 -e ghpUnsetKeep0001 -e fixSigVal0001 "$1" "$TEST_TMPDIR/tmp" 2>/dev/null || true
    } | sort -u | tr '\n' ' ' | sed 's/ $//'
}
# A background job of a non-interactive shell starts with SIGINT ignored, and bash cannot trap
# a signal ignored on entry; this launcher restores the default first, as a terminal's Ctrl-C finds it.
_SIGDFL='import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL); signal.signal(signal.SIGQUIT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])'

# ── unset <dotted.key>… ───────────────────────────────────────────────────────
test_unset_removes_keys_in_one_rewrite_and_prints_no_value() {
    local sandbox out rc=0 ossl encs fp_before fp_after json; sandbox=$(_unset_vault) || return 1
    ossl=$(_ossl); fp_before=$(wc -l < "$sandbox/.secret-fingerprints" | tr -d ' ')
    out=$(_unset "$sandbox" "$ossl" "$PASS" old_survey_admin_pw old_survey_oauth 2>&1) || rc=$?
    encs=$(_encs "$ossl")
    fp_after=$(wc -l < "$sandbox/.secret-fingerprints" | tr -d ' ')
    echo "    measured: rc=$rc encrypt-calls=$encs fingerprints $fp_before->$fp_after out=[$(printf '%s' "$out" | grep -E 'removed|remain|deploy_to' | tr '\n' '|')]"
    assert_eq "0" "$rc" "unset of two present keys must succeed" || return 1
    assert_eq "1" "$encs" "every key is removed in ONE encrypt — one atomic rewrite" || return 1
    assert_contains "$out" "removed old_survey_admin_pw" "the removed key is named" || return 1
    assert_contains "$out" "removed old_survey_oauth" "every removed key is named" || return 1
    assert_not_contains "$out" "S3cret" "no value is ever printed" || return 1
    assert_not_contains "$out" "cid-svc" "not even a non-secret value" || return 1
    assert_contains "$out" "deploy_to: vps:/opt/svc/.env" "a removed key's deploy target is named" || return 1
    assert_contains "$out" "3 vault keys remain" "the remaining count is reported (_meta not counted)" || return 1
    json=$(_vault_json "$sandbox")
    assert_not_contains "$json" "old_survey" "both keys are gone from the ciphertext" || return 1
    assert_contains "$json" '"github_personal"' "other keys survive" || return 1
    assert_contains "$json" '"nested"' "other keys survive" || return 1
    assert_file_not_exists "$sandbox/vault.json" "no plaintext vault.json beside the script" || return 1
    assert_eq "0" "$(_scratch_left)" "the decrypt scratch file is shredded (TMPDIR and tmpfs)" || return 1
    assert_eq "$fp_before" "$fp_after" "fingerprints of removed values are kept (merge, never drop)"
}
run_test "unset removes several keys in one rewrite, names them, prints no value" \
    test_unset_removes_keys_in_one_rewrite_and_prints_no_value

test_unset_refuses_and_writes_nothing() {
    local sandbox out rc ossl before after k encs; sandbox=$(_unset_vault) || return 1
    ossl=$(_ossl); before=$(sha256sum < "$sandbox/vault.json.enc")
    for k in "nope" "github_personal.token.deeper" "nested..keep" ".nested" "nested."; do
        rc=0; out=$(_unset "$sandbox" "$ossl" "$PASS" old_survey_oauth "$k" 2>&1) || rc=$?
        assert_neq "0" "$rc" "one absent or malformed key ($k) must refuse the whole call" || return 1
        assert_contains "$out" "$k" "the refusal names the offending key ($k)" || return 1
        assert_not_contains "$out" "S3cret" "no value in the refusal for $k" || return 1
    done
    rc=0; _unset "$sandbox" "$ossl" wrongpass999 old_survey_oauth >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "a wrong passphrase is refused" || return 1
    rc=0; _unset "$sandbox" "$ossl" "$PASS" >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "no key named is a usage error" || return 1
    printf '{"stale": true}\n' > "$sandbox/vault.json"
    rc=0; _unset "$sandbox" "$ossl" "$PASS" old_survey_oauth >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "a stale plaintext vault.json beside the vault is refused" || return 1
    assert_eq '{"stale": true}' "$(cat "$sandbox/vault.json")" "and left exactly as it was" || return 1
    rm -f "$sandbox/vault.json"
    after=$(sha256sum < "$sandbox/vault.json.enc")
    encs=$(_encs "$ossl")
    echo "    measured: encrypt-calls=$encs ciphertext-unchanged=$([ "$before" = "$after" ] && echo yes || echo no) scratch-left=$(_scratch_left)"
    assert_eq "0" "$encs" "no refusal ever reaches an encrypt" || return 1
    assert_eq "$before" "$after" "the ciphertext is byte-identical after every refusal" || return 1
    assert_eq "0" "$(_scratch_left)" "no decrypt scratch is left behind" || return 1
    assert_contains "$(_vault_json "$sandbox")" '"old_survey_oauth"' "the present key named beside the absent one is still there"
}
run_test "unset refuses an absent/malformed key, wrong passphrase, no key, stale plaintext — nothing written" \
    test_unset_refuses_and_writes_nothing

test_unset_prunes_emptied_parents_inverse_of_set() {
    local sandbox json before after rc=0; sandbox=$(_unset_vault) || return 1
    _unset "$sandbox" - "$PASS" nested.inner.leaf >/dev/null 2>&1 || return 1
    json=$(_vault_json "$sandbox")
    assert_not_contains "$json" '"inner"' "a parent the removal leaves empty is pruned" || return 1
    assert_contains "$json" '"keep": "nestKeepS3cret04"' "its sibling stays" || return 1
    assert_contains "$json" '"empty_obj": {}' "an object that was already empty is not touched" || return 1
    before=$(_vault_json "$sandbox")
    printf 'brandNewS3cret05' | _vm "$sandbox" - "$PASS" set brand.new.leaf >/dev/null 2>&1 || return 1
    _unset "$sandbox" - "$PASS" brand.new.leaf >/dev/null 2>&1 || return 1
    after=$(_vault_json "$sandbox")
    echo "    measured: after set+unset of brand.new.leaf the vault is $([ "$before" = "$after" ] && echo identical || echo DIFFERENT)"
    assert_eq "$before" "$after" "set k then unset k restores the vault exactly (set creates parents, unset prunes them)" || return 1
    _unset "$sandbox" - "$PASS" nested nested.keep nested >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "a key inside another named key, and a repeated name, are accepted" || return 1
    assert_not_contains "$(_vault_json "$sandbox")" '"nested"' "the ancestor goes, with everything under it" || return 1
    local out; out=$(_unset "$sandbox" - "$PASS" old_survey_admin_pw.value 2>&1) || return 1
    echo "    measured: [$(printf '%s' "$out" | grep -E 'NOTE' | tr '\n' '|')]"
    assert_contains "$out" "old_survey_admin_pw.value had deploy_to: vps:/opt/svc/.env" \
        "removing one field of an entry names the entry's deploy target" || return 1
    assert_not_contains "$out" "S3cret" "and prints no value" || return 1
    assert_contains "$(_vault_json "$sandbox")" '"_owner": "infrastructure"' "the entry's other fields stay"
}
run_test "unset prunes the parents it empties, so set+unset round-trips" \
    test_unset_prunes_emptied_parents_inverse_of_set

test_unset_and_keys_are_in_the_usage_text() {
    local sandbox out; sandbox=$(_unset_vault) || return 1
    out=$(bash "$sandbox/vault-manage.sh" help 2>&1 || true)
    assert_contains "$out" "unset <key>" "the usage text lists unset" || return 1
    assert_contains "$out" "keys [<prefix>]" "the usage text lists keys"
}
run_test "the usage text lists unset and keys" test_unset_and_keys_are_in_the_usage_text

# ── key names without a plaintext vault on disk ───────────────────────────────
test_keys_lists_names_of_an_encrypted_only_vault() {
    local sb out rc=0; sb=$(_unset_vault) || return 1
    out=$(_vm "$sb" - "$PASS" keys 2>&1) || rc=$?
    echo "    measured (all): rc=$rc [$(printf '%s' "$out" | grep -v Reminder | tr '\n' '|')]"
    assert_eq "0" "$rc" "keys must work on a vault that exists only as ciphertext" || return 1
    assert_contains "$out" "old_survey_admin_pw: [_owner, deploy_to, note, value]" "an entry with its sub-key names" || return 1
    assert_contains "$out" "github_personal: [token]" "every top-level key" || return 1
    assert_contains "$out" "5 key(s) match" "the count, _meta not counted" || return 1
    assert_not_contains "$out" "_meta" "_meta is not a vault key" || return 1
    for v in S3cret cid-svc vps:/opt infrastructure ghpUnset; do
        assert_not_contains "$out" "$v" "no value of any kind is printed ($v)" || return 1
    done
    out=$(_vm "$sb" - "$PASS" keys old_survey_ 2>&1) || return 1
    assert_contains "$out" "old_survey_oauth: [client_id, client_key]" "a prefix lists what starts with it" || return 1
    assert_not_contains "$out" "github_personal" "and nothing else" || return 1
    assert_contains "$out" "2 key(s) match" "two survey keys" || return 1
    out=$(_vm "$sb" - "$PASS" keys 'old_survey_*' 2>&1) || return 1
    assert_contains "$out" "2 key(s) match" "the pattern form unset takes lists the same keys" || return 1
    out=$(_vm "$sb" - "$PASS" keys nested. 2>&1) || return 1
    assert_contains "$out" "nested.inner: [leaf]" "a dotted prefix lists the children" || return 1
    assert_contains "$out" "nested.keep" "a scalar child is named" || return 1
    assert_file_not_exists "$sb/vault.json" "no plaintext vault.json ever appears" || return 1
    assert_eq "0" "$(_scratch_left)" "the decrypt scratch is shredded" || return 1
    rc=0; _vm "$sb" - wrongpass999 keys >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "a wrong passphrase fails" || return 1
    out=$(bash "$sb/vault-manage.sh" status 2>&1)
    assert_contains "$out" "vault-manage.sh keys" "status on an encrypted-only vault points at keys"
}
run_test "keys lists names (prefix, pattern, dotted) of an encrypted-only vault, never a value" \
    test_keys_lists_names_of_an_encrypted_only_vault

test_unset_pattern_removes_every_match_in_one_rewrite() {
    local sb out rc ossl before bad json; sb=$(_unset_vault) || return 1
    ossl=$(_ossl); before=$(sha256sum < "$sb/vault.json.enc")
    for bad in '*' '*_oauth' 'nested.*' 'old_*.value' 'old_survey_zz*' '_*'; do
        rc=0; out=$(_unset "$sb" "$ossl" "$PASS" "$bad" 2>&1) || rc=$?
        assert_neq "0" "$rc" "pattern $bad must be refused (no literal prefix, * outside the last segment, or no match)" || return 1
        assert_contains "$out" "$bad" "the refusal names $bad" || return 1
    done
    assert_eq "$before" "$(sha256sum < "$sb/vault.json.enc")" "refused patterns write nothing" || return 1
    rc=0; out=$(_unset "$sb" "$ossl" "$PASS" --yes 'old_survey_*' 2>&1) || rc=$?
    echo "    measured: rc=$rc encrypt-calls=$(_encs "$ossl") keys-left=[$(_top "$sb")] out=[$(printf '%s' "$out" | grep -E 'matched|removed' | tr '\n' '|')]"
    assert_eq "0" "$rc" "a pattern with a literal prefix is accepted" || return 1
    assert_contains "$out" "old_survey_* matched: old_survey_admin_pw, old_survey_oauth" "the matched names are echoed" || return 1
    assert_contains "$out" "removed old_survey_oauth" "each match is removed and named" || return 1
    assert_eq "1" "$(_encs "$ossl")" "all matches in one rewrite" || return 1
    json=$(_vault_json "$sb")
    assert_not_contains "$json" "old_survey" "every match is gone" || return 1
    assert_contains "$json" '"_meta"' "_meta is never matched" || return 1
    assert_contains "$json" '"github_personal"' "non-matching keys stay"
}
run_test "unset --yes 'prefix*' removes every match in one rewrite and echoes the names; bare/misplaced/empty patterns refused" \
    test_unset_pattern_removes_every_match_in_one_rewrite

# ── no lost update between concurrent edits ───────────────────────────────────
test_lock_a_set_during_an_unset_is_not_lost() {
    local sb ossl g="$TEST_TMPDIR/g1" up sp urc=0 src=0 json; sb=$(_unset_vault) || return 1
    ossl=$(_ossl); mkdir -p "$g"
    OSSL_GATE="$g" OSSL_GATE_ON=enc _unset "$sb" "$ossl" "$PASS" old_survey_oauth >"$TEST_TMPDIR/u.out" 2>&1 & up=$!
    _wait_file "$g/started" 300 || { touch "$g/go"; wait "$up"; assert_eq started never "unset reached its encrypt"; return 1; }
    printf 'fixNewKey0001' | _vm "$sb" "$ossl" "$PASS" set newkey.token >"$TEST_TMPDIR/s.out" 2>&1 & sp=$!
    _wait_gone "$sp" 40 || true   # unlocked, set finishes inside the window; locked, it waits for unset
    touch "$g/go"; wait "$up" || urc=$?; wait "$sp" || src=$?
    json=$(_vault_json "$sb")
    echo "    measured: unset rc=$urc set rc=$src keys=[$(_top "$sb")]"
    assert_eq "0" "$urc" "the unset succeeds" || return 1
    assert_eq "0" "$src" "the concurrent set succeeds" || return 1
    assert_contains "$json" '"newkey"' "the set's key survives the unset's rewrite" || return 1
    assert_not_contains "$json" "old_survey_oauth" "and the unset's removal holds"
}
run_test "a set started during an unset's rewrite is not lost (edit lock)" \
    test_lock_a_set_during_an_unset_is_not_lost

test_lock_an_unset_is_not_undone_by_a_concurrent_set() {
    local sb ossl g1="$TEST_TMPDIR/g1" g2="$TEST_TMPDIR/g2" up sp urc=0 src=0 json; sb=$(_unset_vault) || return 1
    ossl=$(_ossl); mkdir -p "$g1" "$g2"
    OSSL_GATE="$g1" OSSL_GATE_ON=enc _unset "$sb" "$ossl" "$PASS" old_survey_oauth >"$TEST_TMPDIR/u.out" 2>&1 & up=$!
    _wait_file "$g1/started" 300 || { touch "$g1/go"; wait "$up"; assert_eq started never "unset reached its encrypt"; return 1; }
    printf 'fixNewKey0001' | OSSL_GATE="$g2" OSSL_GATE_ON=enc _vm "$sb" "$ossl" "$PASS" set newkey.token >"$TEST_TMPDIR/s.out" 2>&1 & sp=$!
    _wait_file "$g2/started" 40 || true   # unlocked, set has decrypted the OLD vault by now
    touch "$g1/go"; wait "$up" || urc=$?
    touch "$g2/go"; wait "$sp" || src=$?
    json=$(_vault_json "$sb")
    echo "    measured: unset rc=$urc set rc=$src keys=[$(_top "$sb")]"
    assert_eq "0" "$urc" "the unset succeeds" || return 1
    assert_eq "0" "$src" "the concurrent set succeeds" || return 1
    assert_not_contains "$json" "old_survey_oauth" "the removed key does not come back" || return 1
    assert_contains "$json" '"newkey"' "and the set's key is there"
}
run_test "an unset is not undone by a set that started during it (edit lock)" \
    test_lock_an_unset_is_not_undone_by_a_concurrent_set

test_unset_refuses_when_the_ciphertext_changed_underneath() {
    local sb ossl g="$TEST_TMPDIR/g1" up urc=0 want out; sb=$(_unset_vault) || return 1
    ossl=$(_ossl); mkdir -p "$g"
    printf '{"pulled": {"token": "pulledS3cret06"}, "old_survey_oauth": {"x": "y"}}\n' > "$TEST_TMPDIR/pulled.json"
    _raw_enc "$TEST_TMPDIR/pulled.json" "$TEST_TMPDIR/pulled.enc" "$PASS" "$ITER_T"
    OSSL_GATE="$g" OSSL_GATE_ON=enc _unset "$sb" "$ossl" "$PASS" old_survey_oauth >"$TEST_TMPDIR/u.out" 2>&1 & up=$!
    _wait_file "$g/started" 300 || { touch "$g/go"; wait "$up"; return 1; }
    cp "$TEST_TMPDIR/pulled.enc" "$sb/vault.json.enc.pull"; mv -f "$sb/vault.json.enc.pull" "$sb/vault.json.enc"
    want=$(sha256sum < "$sb/vault.json.enc")
    touch "$g/go"; wait "$up" || urc=$?; out=$(cat "$TEST_TMPDIR/u.out")
    echo "    measured: rc=$urc pulled-kept=$([ "$want" = "$(sha256sum < "$sb/vault.json.enc")" ] && echo yes || echo no) [$(printf '%s' "$out" | grep -E 'ERROR' | tr '\n' '|')]"
    assert_neq "0" "$urc" "a ciphertext replaced mid-edit (git pull, restore) must refuse the rewrite" || return 1
    assert_contains "$out" "changed" "the refusal says the vault changed underneath" || return 1
    assert_eq "$want" "$(sha256sum < "$sb/vault.json.enc")" "the replacement is kept byte for byte" || return 1
    assert_file_not_exists "$sb/vault.json.enc.new" "no half-written ciphertext is left" || return 1
    assert_eq "0" "$(_scratch_left)" "no scratch left"
}
run_test "unset refuses to overwrite a ciphertext that changed underneath it" \
    test_unset_refuses_when_the_ciphertext_changed_underneath

test_set_and_reencrypt_leave_no_stale_plaintext_when_refused() {
    # set and reencrypt decrypt into tmpfs scratch only. When the changed-underneath check
    # refuses, that plaintext predates the new ciphertext: left behind, the next encrypt or
    # set would write it over the pulled vault. Nothing may remain.
    local sb ossl g verb rc want out; sb=$(_unset_vault) || return 1; ossl=$(_ossl)
    printf '{"pulled": {"token": "pulledS3cret06"}}\n' > "$TEST_TMPDIR/pulled.json"
    for verb in set reencrypt; do
        g="$TEST_TMPDIR/g-$verb"; mkdir -p "$g"; rc=0
        _raw_enc "$TEST_TMPDIR/pulled.json" "$TEST_TMPDIR/pulled.enc" "$PASS" "$ITER_T"   # fresh salt: differs from what is there
        if [ "$verb" = set ]; then
            printf 'fixNewKey0001' | OSSL_GATE="$g" OSSL_GATE_ON=enc _vm "$sb" "$ossl" "$PASS" set newkey.token >"$TEST_TMPDIR/v.out" 2>&1 &
        else
            OSSL_GATE="$g" OSSL_GATE_ON=enc _vm "$sb" "$ossl" "$PASS" reencrypt >"$TEST_TMPDIR/v.out" 2>&1 &
        fi
        local pid=$!
        _wait_file "$g/started" 300 || { touch "$g/go"; wait "$pid"; return 1; }
        cp "$TEST_TMPDIR/pulled.enc" "$sb/vault.json.enc.pull"; mv -f "$sb/vault.json.enc.pull" "$sb/vault.json.enc"
        want=$(sha256sum < "$sb/vault.json.enc"); touch "$g/go"; wait "$pid" || rc=$?; out=$(cat "$TEST_TMPDIR/v.out")
        echo "    measured ($verb): rc=$rc plaintext-left=$([ -e "$sb/vault.json" ] && echo yes || echo no) pulled-kept=$([ "$want" = "$(sha256sum < "$sb/vault.json.enc")" ] && echo yes || echo no)"
        assert_neq "0" "$rc" "$verb refuses a ciphertext that changed underneath it" || return 1
        assert_contains "$out" "changed" "$verb says why" || return 1
        assert_file_not_exists "$sb/vault.json" "$verb leaves no stale plaintext vault.json behind" || return 1
        assert_eq "$want" "$(sha256sum < "$sb/vault.json.enc")" "$verb keeps the replacement" || return 1
        assert_file_not_exists "$sb/vault.json.enc.new" "$verb leaves no .new" || return 1
        rm -f "$sb/vault.json"
    done
}
run_test "set and reencrypt refused by the changed-underneath check remove the plaintext they decrypted" \
    test_set_and_reencrypt_leave_no_stale_plaintext_when_refused

# ── scratch in tmpfs, shredded on a signal too ────────────────────────────────
test_term_mid_rewrite_leaves_no_plaintext() {
    local sb ossl g="$TEST_TMPDIR/g1" pid rc=0 before ram tmp out; sb=$(_unset_vault) || return 1
    ossl=$(_ossl); mkdir -p "$g"; before=$(sha256sum < "$sb/vault.json.enc")
    PATH="$ossl:$PATH" TMPDIR="$TEST_TMPDIR/tmp" VAULT_SHM_DIR="$TEST_TMPDIR/ram" VAULT_PASS="$PASS" \
        OSSL_GATE="$g" OSSL_GATE_ON=rt bash "$sb/vault-manage.sh" unset old_survey_oauth >"$TEST_TMPDIR/u.out" 2>&1 & pid=$!
    _wait_file "$g/started" 300 || { touch "$g/go"; wait "$pid"; return 1; }
    ram=$(find "$TEST_TMPDIR/ram" -mindepth 1 -name 'vault-*' | wc -l | tr -d ' ')
    tmp=$(find "$TEST_TMPDIR/tmp" -mindepth 1 | wc -l | tr -d ' ')
    kill -TERM "$pid"; sleep 0.3; touch "$g/go"
    wait "$pid" || rc=$?; _wait_file "$g/done" 50 || true; sleep 0.2
    out=$(cat "$TEST_TMPDIR/u.out")
    echo "    measured: mid-rewrite scratch in tmpfs=$ram in TMPDIR=$tmp; after TERM rc=$rc left=$(_scratch_left) new=$([ -e "$sb/vault.json.enc.new" ] && echo yes || echo no)"
    assert_neq "0" "$ram" "the decrypted scratch lives in the tmpfs dir (VAULT_SHM_DIR)" || return 1
    assert_eq "0" "$tmp" "and never in TMPDIR, which may be disk" || return 1
    assert_eq "143" "$rc" "TERM ends the run" || return 1
    assert_eq "0" "$(_scratch_left)" "every scratch plaintext is shredded, the round-trip copy included" || return 1
    assert_file_not_exists "$sb/vault.json.enc.new" "no half-written ciphertext is left" || return 1
    assert_eq "$before" "$(sha256sum < "$sb/vault.json.enc")" "the vault is untouched" || return 1
    assert_contains "$out" "nothing was written" "the run says nothing was written" || return 1
    assert_not_contains "$out" "[OK] removed" "and claims no removal"
}
run_test "TERM during the round-trip leaves no plaintext, no .new, an untouched vault; scratch is in tmpfs" \
    test_term_mid_rewrite_leaves_no_plaintext

# ── say what was pruned; claim nothing that was not written ───────────────────
test_unset_names_every_parent_it_prunes() {
    local sb out; sb=$(_unset_vault) || return 1
    printf 'soloS3cret07xx' | _vm "$sb" - "$PASS" set solo.token >/dev/null 2>&1 || return 1
    out=$(_unset "$sb" - "$PASS" solo.token nested.inner.leaf 2>&1) || return 1
    echo "    measured: [$(printf '%s' "$out" | grep -E 'removed|pruned' | tr '\n' '|')]"
    assert_contains "$out" "pruned solo" "an entry emptied by removing its only field is named as pruned" || return 1
    assert_contains "$out" "pruned nested.inner" "a nested parent too" || return 1
    assert_not_contains "$out" "pruned nested " "a parent that keeps a child is not pruned" || return 1
    assert_not_contains "$(_vault_json "$sb")" '"solo"' "and solo is gone"
}
run_test "unset names every parent it prunes" test_unset_names_every_parent_it_prunes

test_unset_failed_rewrite_claims_no_removal() {
    local sb out rc=0; sb=$(_unset_vault) || return 1
    chmod 555 "$sb"
    out=$(_unset "$sb" - "$PASS" old_survey_oauth 2>&1) || rc=$?
    chmod 755 "$sb"
    echo "    measured: rc=$rc [$(printf '%s' "$out" | grep -E 'OK|ERROR' | tr '\n' '|')]"
    assert_neq "0" "$rc" "a rewrite that cannot be written fails" || return 1
    assert_not_contains "$out" "[OK] removed" "no removal is claimed for a write that did not happen" || return 1
    assert_contains "$out" "nothing was written" "the run says nothing was written" || return 1
    assert_contains "$(_vault_json "$sb")" '"old_survey_oauth"' "and the key is still in the vault" || return 1
    assert_eq "0" "$(_scratch_left)" "no scratch left"
}
run_test "a failed rewrite prints no '[OK] removed' and says nothing was written" \
    test_unset_failed_rewrite_claims_no_removal

# ── the fingerprint refresh and the passphrase pin are exercised ──────────────
test_unset_refreshes_fingerprints_and_ignores_a_new_passphrase_flag() {
    local sb rc=0 salt fp; sb=$(_unset_vault) || return 1
    rm -f "$sb/.secret-fingerprints"
    VAULT_ALLOW_NEW_PASSPHRASE=1 _unset "$sb" - "$PASS" old_survey_oauth >/dev/null 2>&1 || rc=$?
    salt=$(cat "$sb/.fingerprint-salt")
    fp=$(printf '%s%s' "$salt" "ghpUnsetKeep0001" | sha256sum | cut -c1-64)
    echo "    measured: rc=$rc fingerprint-file=$([ -s "$sb/.secret-fingerprints" ] && wc -l < "$sb/.secret-fingerprints" | tr -d ' ' || echo absent) remaining-secret-fingerprinted=$(grep -c "^$fp\$" "$sb/.secret-fingerprints" 2>/dev/null || echo 0)"
    assert_eq "0" "$rc" "VAULT_ALLOW_NEW_PASSPHRASE in the caller's env does not turn unset into a passphrase change" || return 1
    assert_file_contains "$sb/.secret-fingerprints" "$fp" "unset refreshes the guard's fingerprints from the vault it wrote"
}
run_test "unset rewrites the fingerprint file and is immune to VAULT_ALLOW_NEW_PASSPHRASE" \
    test_unset_refreshes_fingerprints_and_ignores_a_new_passphrase_flag

# ── the rewrite keeps raw UTF-8 and names keys it collapses ───────────────────
test_unset_keeps_utf8_and_names_duplicate_keys() {
    local sb out rc=0 raw_before raw_after; sb=$(_unset_vault) || return 1
    printf '%s\n' '{"dup": {"token": "fixDupFirst0001"}, "dup": {"token": "fixDupSecond002"},' \
        ' "greet": {"note": "Grüße"}, "old_survey_a": {"value": "svcS3cretA00001"}}' > "$sb/vault.json"
    rm -f "$sb/vault.json.enc"
    VAULT_PASS="$PASS" VAULT_PASS_CONFIRM="$PASS" VAULT_SHM_DIR="$TEST_TMPDIR/ram" TMPDIR="$TEST_TMPDIR/tmp" \
        bash "$sb/vault-manage.sh" encrypt >/dev/null 2>&1 || return 1
    raw_before=$(_raw_dec "$sb/vault.json.enc" "$PASS" "$ITER_T" | grep -c 'Grüße' || true)
    out=$(_unset "$sb" - "$PASS" old_survey_a 2>&1) || rc=$?
    raw_after=$(_raw_dec "$sb/vault.json.enc" "$PASS" "$ITER_T" | grep -c 'Grüße' || true)
    echo "    measured: rc=$rc raw-UTF-8 'Grüße' lines $raw_before->$raw_after [$(printf '%s' "$out" | grep -E 'WARN' | tr '\n' '|')]"
    assert_eq "0" "$rc" "unset still works on a vault with a duplicate key" || return 1
    assert_eq "1" "$raw_after" "non-ASCII text stays raw UTF-8, not rewritten as \\u escapes" || return 1
    assert_contains "$out" "duplicate key" "the collapse of a duplicated key is announced" || return 1
    assert_contains "$out" "dup" "and the duplicated key is named" || return 1
    assert_not_contains "$out" "fixDup" "without printing either value"
}
run_test "unset keeps raw UTF-8 and names a duplicate key the rewrite collapses" \
    test_unset_keeps_utf8_and_names_duplicate_keys

# ── a signal mid-edit leaves no plaintext outside tmpfs ───────────────────────
_signal_mid_edit() {  # <sb> <ossl> <verb> <gate> <sig> — pause <verb> at its <gate> openssl call, send <sig>
    local sb="$1" ossl="$2" verb="$3" gate="$4" sig="$5" g="$TEST_TMPDIR/g-$3-$5" pid rc=0 disk ram
    local -a args=("$verb"); case "$verb" in set) args+=(sig.token) ;; unset) args+=(old_survey_oauth) ;; esac
    mkdir -p "$g"
    printf 'fixSigVal0001' | PATH="$ossl:$PATH" TMPDIR="$TEST_TMPDIR/tmp" VAULT_SHM_DIR="$TEST_TMPDIR/ram" \
        VAULT_PASS="$PASS" OSSL_GATE="$g" OSSL_GATE_ON="$gate" \
        python3 -c "$_SIGDFL" bash "$sb/vault-manage.sh" "${args[@]}" >"$g.out" 2>&1 & pid=$!
    _wait_file "$g/started" 300 || { touch "$g/go"; wait "$pid" || true; echo "never-paused"; return 0; }
    disk=$(_plain_on_disk "$sb"); ram=$(find "$TEST_TMPDIR/ram" -mindepth 1 -name 'vault-*' | wc -l | tr -d ' ')
    kill -"$sig" "$pid"; sleep 0.3; touch "$g/go"
    wait "$pid" || rc=$?; _wait_file "$g/done" 50 || true; sleep 0.2
    echo "rc=$rc mid-disk=[$disk] mid-tmpfs=$ram after-disk=[$(_plain_on_disk "$sb")] scratch-left=$(_scratch_left) new=$([ -e "$sb/vault.json.enc.new" ] && echo yes || echo no)"
}
test_signal_mid_edit_leaves_no_plaintext_outside_tmpfs() {
    local sb ossl before verb gate sig want line; sb=$(_unset_vault) || return 1
    ossl=$(_ossl); before=$(sha256sum < "$sb/vault.json.enc")
    for verb in set reencrypt unset keys; do
        gate=enc; [ "$verb" = keys ] && gate=dec
        for sig in INT TERM HUP; do
            case "$sig" in INT) want=130 ;; TERM) want=143 ;; HUP) want=129 ;; esac
            line=$(_signal_mid_edit "$sb" "$ossl" "$verb" "$gate" "$sig")
            echo "    measured ($verb, SIG$sig at its $gate call): $line"
            assert_contains "$line" "rc=$want " "SIG$sig ends $verb with $want" || return 1
            assert_contains "$line" "mid-disk=[] " "mid-$verb, no plaintext lies outside tmpfs (no vault.json, nothing in TMPDIR)" || return 1
            assert_not_contains "$line" "mid-tmpfs=0 " "mid-$verb, the decrypted copy is in the tmpfs dir" || return 1
            assert_contains "$line" "after-disk=[] scratch-left=0 new=no" "SIG$sig: every plaintext shredded, no .new" || return 1
            assert_eq "$before" "$(sha256sum < "$sb/vault.json.enc")" "SIG$sig during $verb: the ciphertext is unchanged" || return 1
        done
    done
}
run_test "INT, TERM and HUP mid-set/reencrypt/unset/keys leave no plaintext outside tmpfs and the ciphertext unchanged" \
    test_signal_mid_edit_leaves_no_plaintext_outside_tmpfs

# ── a pattern previews without --yes; _meta is never removed ──────────────────
test_unset_pattern_previews_without_yes_and_needs_a_3_char_prefix() {
    local sb ossl before out rc bad; sb=$(_unset_vault) || return 1
    ossl=$(_ossl); before=$(sha256sum < "$sb/vault.json.enc")
    rc=0; out=$(_unset "$sb" "$ossl" "$PASS" 'old_survey_*' 2>&1) || rc=$?
    echo "    measured (no --yes): rc=$rc encrypt-calls=$(_encs "$ossl") [$(printf '%s' "$out" | grep -v Reminder | tr '\n' '|')]"
    assert_neq "0" "$rc" "a pattern without --yes only previews" || return 1
    assert_contains "$out" "old_survey_admin_pw" "the preview names every match" || return 1
    assert_contains "$out" "old_survey_oauth" "every match" || return 1
    assert_contains "$out" "--yes" "and says how to go ahead" || return 1
    rc=0; _unset "$sb" "$ossl" "$PASS" nested.keep 'old_survey_*' >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "an exact key beside an unconfirmed pattern is not removed either" || return 1
    for bad in 'ol*' 'o*' 'nested.in*'; do
        rc=0; out=$(_unset "$sb" "$ossl" "$PASS" --yes "$bad" 2>&1) || rc=$?
        assert_neq "0" "$rc" "pattern $bad (literal prefix under 3 characters) is refused even with --yes" || return 1
        assert_contains "$out" "$bad" "the refusal names $bad" || return 1
    done
    assert_eq "0" "$(_encs "$ossl")" "no preview or refusal reaches an encrypt" || return 1
    assert_eq "$before" "$(sha256sum < "$sb/vault.json.enc")" "nothing was written" || return 1
    rc=0; out=$(_unset "$sb" "$ossl" "$PASS" --yes 'old*' 2>&1) || rc=$?
    echo "    measured (--yes 'old*'): rc=$rc keys-left=[$(_top "$sb")]"
    assert_eq "0" "$rc" "a 3-character literal prefix with --yes is accepted" || return 1
    assert_not_contains "$(_vault_json "$sb")" "old_survey" "and removes every match"
}
run_test "unset 'prefix*' without --yes previews the matches and writes nothing; a literal prefix under 3 chars is refused" \
    test_unset_pattern_previews_without_yes_and_needs_a_3_char_prefix

test_unset_refuses_meta() {
    local sb ossl before out rc k; sb=$(_unset_vault) || return 1
    ossl=$(_ossl); before=$(sha256sum < "$sb/vault.json.enc")
    for k in _meta _meta.comment; do
        rc=0; out=$(_unset "$sb" "$ossl" "$PASS" "$k" 2>&1) || rc=$?
        echo "    measured (unset $k): rc=$rc [$(printf '%s' "$out" | grep -E 'ERROR|OK' | tr '\n' '|')]"
        assert_neq "0" "$rc" "unset $k is refused" || return 1
        assert_contains "$out" "_meta" "the refusal names _meta" || return 1
    done
    assert_eq "0" "$(_encs "$ossl")" "no encrypt ran" || return 1
    assert_eq "$before" "$(sha256sum < "$sb/vault.json.enc")" "nothing was written" || return 1
    assert_contains "$(_vault_json "$sb")" '"comment": "test fixture"' "_meta is intact"
}
run_test "unset _meta and unset _meta.<field> are refused, nothing written" test_unset_refuses_meta

# ── when the lock is taken, and that every edit verb takes it ─────────────────
test_lock_is_taken_only_after_the_password_prompt() {
    command -v flock >/dev/null 2>&1 || { echo "    SKIP: flock not installed"; return 0; }
    local sb verb fifo out pid rc free; sb=$(_unset_vault) || return 1
    for verb in reencrypt unset decrypt encrypt deploy; do   # decrypt leaves the vault.json encrypt consumes
        fifo="$TEST_TMPDIR/in-$verb"; out="$TEST_TMPDIR/p-$verb.out"; mkfifo "$fifo"; exec 7<>"$fifo"
        local -a args=("$verb"); [ "$verb" = unset ] && args+=(nested.keep)
        env -u VAULT_PASS TMPDIR="$TEST_TMPDIR/tmp" VAULT_SHM_DIR="$TEST_TMPDIR/ram" \
            bash "$sb/vault-manage.sh" "${args[@]}" <"$fifo" >"$out" 2>&1 7>&- & pid=$!
        if ! _wait_text "$out" "Password:" 300; then
            kill "$pid" 2>/dev/null; exec 7>&-; assert_eq "a prompt" "none" "$verb asks for the password"; return 1
        fi
        free=yes; _lock_free "$sb" || free=no
        printf '%s\n%s\n' "$PASS" "$PASS" >&7; exec 7>&-
        rc=0; _wait_gone "$pid" 300 || kill "$pid" 2>/dev/null; wait "$pid" || rc=$?
        echo "    measured ($verb): lock free while it waits at the password prompt=$free rc=$rc"
        assert_eq "yes" "$free" "$verb takes the edit lock only after the password is typed" || return 1
        assert_eq "0" "$rc" "$verb completes once the password is typed" || return 1
    done
}
run_test "encrypt, decrypt, reencrypt, unset and deploy do not hold the lock while they wait at the password prompt" \
    test_lock_is_taken_only_after_the_password_prompt

test_deploy_asks_its_question_before_taking_the_lock() {
    command -v flock >/dev/null 2>&1 && command -v script >/dev/null 2>&1 || { echo "    SKIP: flock or script not installed"; return 0; }
    local sb fifo="$TEST_TMPDIR/in-deploy" out="$TEST_TMPDIR/deploy.out" pid rc=0 free; sb=$(_unset_vault) || return 1
    mkfifo "$fifo"; exec 7<>"$fifo"
    SHELL=/bin/bash script -qec "TMPDIR='$TEST_TMPDIR/tmp' VAULT_SHM_DIR='$TEST_TMPDIR/ram' VAULT_PASS='$PASS' bash '$sb/vault-manage.sh' deploy" \
        /dev/null <"$fifo" >"$out" 2>&1 7>&- & pid=$!
    if ! _wait_text "$out" "[Y/n]" 300; then
        kill "$pid" 2>/dev/null; exec 7>&-; assert_eq "a question" "none" "deploy at a terminal asks about vault.json"; return 1
    fi
    free=yes; _lock_free "$sb" || free=no
    printf 'n\n' >&7; exec 7>&-
    _wait_gone "$pid" 300 || kill "$pid" 2>/dev/null; wait "$pid" || rc=$?
    echo "    measured: lock free while deploy waits at its [Y/n] question=$free rc=$rc vault.json-kept=$([ -e "$sb/vault.json" ] && echo yes || echo no)"
    assert_eq "yes" "$free" "deploy holds no lock while it waits for the answer" || return 1
    assert_eq "0" "$rc" "deploy completes" || return 1
    assert_file_exists "$sb/vault.json" "the answer n, given before the deploy, still keeps vault.json" || return 1
    rm -f "$sb/vault.json"
}
run_test "deploy at a terminal asks its delete question before it takes the lock, and honours the answer" \
    test_deploy_asks_its_question_before_taking_the_lock

test_exported_internal_flags_change_nothing() {
    command -v flock >/dev/null 2>&1 || { echo "    SKIP: flock not installed"; return 0; }
    local sb ossl g="$TEST_TMPDIR/g6" pid rc=0 erc=0 held; sb=$(_unset_vault) || return 1
    ossl=$(_ossl); mkdir -p "$g"
    _VAULT_LOCKED=1 OSSL_GATE="$g" OSSL_GATE_ON=enc _unset "$sb" "$ossl" "$PASS" nested.keep >"$g.out" 2>&1 & pid=$!
    _wait_file "$g/started" 300 || { touch "$g/go"; wait "$pid"; assert_eq paused never "unset reached its encrypt"; return 1; }
    held=yes; _lock_free "$sb" && held=no
    touch "$g/go"; wait "$pid" || rc=$?
    printf '{"plain": {"token": "plainS3cret0009"}}\n' > "$sb/vault.json"
    _VAULT_BASE_SHA=deadbeef _VAULT_WROTE=1 _vm "$sb" - "$PASS" encrypt >"$g.enc" 2>&1 || erc=$?
    echo "    measured: exported _VAULT_LOCKED=1 → lock held during unset=$held (rc=$rc); exported _VAULT_BASE_SHA → encrypt rc=$erc"
    assert_eq "yes" "$held" "an exported _VAULT_LOCKED=1 does not skip the edit lock" || return 1
    assert_eq "0" "$rc" "the unset completes" || return 1
    assert_eq "0" "$erc" "an exported _VAULT_BASE_SHA does not make encrypt refuse a vault that did not change"
}
run_test "internal flags exported by the caller (_VAULT_LOCKED, _VAULT_BASE_SHA) change nothing" \
    test_exported_internal_flags_change_nothing

test_every_edit_verb_holds_the_lock_while_it_works() {
    command -v flock >/dev/null 2>&1 || { echo "    SKIP: flock not installed"; return 0; }
    local sb ossl verb g pid rc held; sb=$(_unset_vault) || return 1; ossl=$(_ossl)
    for verb in set unset reencrypt decrypt encrypt deploy; do   # decrypt leaves the vault.json encrypt consumes
        g="$TEST_TMPDIR/g9-$verb"; mkdir -p "$g"; rc=0
        local -a args=("$verb"); case "$verb" in set|unset) args+=(lock.token) ;; esac
        printf 'fixLockVal0001' | OSSL_GATE="$g" OSSL_GATE_ON=any _vm "$sb" "$ossl" "$PASS" "${args[@]}" >"$g.out" 2>&1 & pid=$!
        _wait_file "$g/started" 300 || { touch "$g/go"; wait "$pid"; assert_eq paused never "$verb reached openssl"; return 1; }
        held=yes; _lock_free "$sb" && held=no
        touch "$g/go"; wait "$pid" || rc=$?
        echo "    measured ($verb): lock held at its first openssl call=$held rc=$rc"
        assert_eq "yes" "$held" "$verb holds .vault.lock while it reads or rewrites the vault" || return 1
        assert_eq "0" "$rc" "$verb completes" || return 1
    done
}
run_test "set, unset, reencrypt, decrypt, encrypt and deploy each hold the edit lock while they work" \
    test_every_edit_verb_holds_the_lock_while_it_works

# ── the key-tree program's own file; what git tracks and ignores under setup/secrets ──
test_tree_program_lives_in_its_own_file() {
    local vm="$VAULT_SCRIPT" sb out rc=0 before
    echo "    measured: vault-manage.sh $(wc -l < "$vm" | tr -d ' ') lines; vault_edit.py=$([ -f "$VAULT_DIR/vault_edit.py" ] && wc -l < "$VAULT_DIR/vault_edit.py" | tr -d ' ' || echo absent) lines"
    assert_file_exists "$VAULT_DIR/vault_edit.py" "the unset/keys program is its own file beside vault-manage.sh" || return 1
    sb=$(_unset_vault) || return 1; rm -f "$sb/vault_edit.py"; before=$(sha256sum < "$sb/vault.json.enc")
    out=$(_unset "$sb" - "$PASS" nested.keep 2>&1) || rc=$?
    assert_neq "0" "$rc" "a copy of vault-manage.sh without vault_edit.py beside it refuses unset" || return 1
    assert_contains "$out" "vault_edit.py" "and names the missing file" || return 1
    assert_eq "$before" "$(sha256sum < "$sb/vault.json.enc")" "nothing was written" || return 1
    assert_eq "0" "$(_scratch_left)" "no scratch left"
}
run_test "the unset/keys program lives in setup/secrets/vault_edit.py; without it unset refuses and writes nothing" \
    test_tree_program_lives_in_its_own_file

test_secrets_dir_tracks_the_programs_and_ignores_the_state() {
    # setup/secrets/.gitignore ignores everything but the scaffold: the programs must be
    # un-ignored or a clone never gets them, and the lock, the fingerprint pair and every
    # plaintext must stay ignored. Judged by git itself (check-ignore), not by reading the file.
    local f rc tracked=() ignored=()
    for f in vault-manage.sh vault_edit.py vault.json.example .gitignore; do
        rc=0; git -C "$REPO_ROOT" check-ignore -q "setup/secrets/$f" || rc=$?
        [ "$rc" -eq 0 ] && tracked+=("$f:IGNORED") || tracked+=("$f:ok")
        assert_neq "0" "$rc" "setup/secrets/$f must NOT be gitignored (a clone needs it)" || return 1
    done
    for f in vault.json .vault.lock .secret-fingerprints .fingerprint-salt vault.json.enc.prev vault.json.enc.new; do
        rc=0; git -C "$REPO_ROOT" check-ignore -q "setup/secrets/$f" || rc=$?
        [ "$rc" -eq 0 ] && ignored+=("$f:ok") || ignored+=("$f:TRACKED")
        assert_eq "0" "$rc" "setup/secrets/$f must be gitignored (local state or plaintext)" || return 1
    done
    echo "    measured: programs [${tracked[*]}]; state [${ignored[*]}]"
}
run_test "setup/secrets: git tracks vault-manage.sh + vault_edit.py and ignores the lock, fingerprints and every plaintext" \
    test_secrets_dir_tracks_the_programs_and_ignores_the_state

suite_summary
