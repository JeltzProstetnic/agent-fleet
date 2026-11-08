#!/usr/bin/env bash
# test-corporate-ca.sh — contract tests for setup/scripts/corporate-ca.sh (CFG-864)
#
# A TLS-inspecting proxy (any vendor) re-signs every HTTPS connection with a corporate root
# that the public trust stores do not hold, and Claude Code / npm / curl then fail with
# "unable to get local issuer certificate". The script detects that by symptom and wires the
# corporate root into user-space trust. Every case here runs against generated certificate
# hierarchies: CORP_CA_CHAIN_FILE replaces the network probe and CORP_CA_STORES replaces the
# platform store discovery, so the suite never touches the network, PowerShell or a keychain.
#
# The corporate root is deliberately NOT named after any vendor: the old recipe matched
# Subject 'Zscaler' and wrote an empty pem behind every other proxy.

source "$(dirname "$0")/test-helpers.sh"

CA_SCRIPT="$REPO_ROOT/setup/scripts/corporate-ca.sh"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

# ── Fixtures ────────────────────────────────────────────────────────────────
_ext() { printf '%s\n' "$@" > "$FIX/ext.cnf"; }

gen_root() {  # <name> <subject>
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -keyout "$FIX/$1.key" -out "$FIX/$1.pem" -days 30 -subj "$2" \
        -addext basicConstraints=critical,CA:TRUE \
        -addext keyUsage=critical,keyCertSign,cRLSign >/dev/null 2>&1
}

gen_signed() {  # <name> <subject> <issuer-name> <ca|leaf>
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -keyout "$FIX/$1.key" -out "$FIX/$1.csr" -subj "$2" >/dev/null 2>&1
    if [[ "$4" == ca ]]; then
        _ext 'basicConstraints=critical,CA:TRUE' 'keyUsage=critical,keyCertSign,cRLSign' \
             'subjectKeyIdentifier=hash' 'authorityKeyIdentifier=keyid'
    else
        _ext 'subjectAltName=DNS:api.anthropic.com' 'extendedKeyUsage=serverAuth' \
             'subjectKeyIdentifier=hash' 'authorityKeyIdentifier=keyid'
    fi
    openssl x509 -req -in "$FIX/$1.csr" -CA "$FIX/$3.pem" -CAkey "$FIX/$3.key" \
        -set_serial "0x$(openssl rand -hex 8)" -days 30 -extfile "$FIX/ext.cnf" \
        -out "$FIX/$1.pem" >/dev/null 2>&1
}

# Public world: what the internet presents without a proxy.
gen_root   pubroot  "/CN=Public Test Root/O=Public Trust"
gen_signed pubinter "/CN=Public Test Issuing CA/O=Public Trust" pubroot ca
gen_signed publeaf  "/CN=api.anthropic.com" pubinter leaf
# Corporate proxy: re-signs the same host with its own root.
gen_root   corproot  "/CN=Acme Inspection Root/O=Acme Corp"
gen_signed corpinter "/CN=Acme Inspection Issuing CA/O=Acme Corp" corproot ca
gen_signed corpleaf  "/CN=api.anthropic.com" corpinter leaf
# A decoy root with the corporate root's exact subject but a different key.
gen_root   decoy     "/CN=Acme Inspection Root/O=Acme Corp"
gen_root   other1    "/CN=Unrelated Root One/O=Elsewhere"
gen_root   other2    "/CN=Unrelated Root Two/O=Elsewhere"

cat "$FIX/publeaf.pem" "$FIX/pubinter.pem" > "$FIX/chain-clean.pem"
cat "$FIX/corpleaf.pem" "$FIX/corpinter.pem" > "$FIX/chain-proxy.pem"
cat "$FIX/corpleaf.pem" "$FIX/corpinter.pem" "$FIX/corproot.pem" > "$FIX/chain-proxy-with-root.pem"
cp "$FIX/pubroot.pem" "$FIX/public-bundle.pem"
cat "$FIX/other1.pem" "$FIX/decoy.pem" "$FIX/corproot.pem" "$FIX/other2.pem" > "$FIX/store.pem"
cat "$FIX/other1.pem" "$FIX/other2.pem" > "$FIX/store-without-corp.pem"
cat "$FIX/pubroot.pem" "$FIX/other1.pem" > "$FIX/system-bundle.pem"

_fp() { openssl x509 -noout -fingerprint -sha256 -in "$1" | cut -d= -f2; }
CORP_FP="$(_fp "$FIX/corproot.pem")"

# Run the script with the hermetic inputs; extra VAR=value pairs may precede the args.
# Inside a Claude Code session CC_MIRROR_DIR / CLAUDE_CONFIG_DIR name the LIVE config, and the
# script's default settings target follows CC_MIRROR_DIR: without these -u the suite wrote
# into the live settings.json, which Claude Code hot-applied to every running session
# (2026-11-08). The CA variables are cleared so a host's own trust cannot leak in.
run_ca() {
    env -u CC_MIRROR_DIR -u CLAUDE_CONFIG_DIR -u SSL_CERT_FILE -u SSL_CERT_DIR -u NODE_EXTRA_CA_CERTS \
        -u CURL_CA_BUNDLE -u GIT_SSL_CAINFO -u REQUESTS_CA_BUNDLE \
        CORP_CA_PUBLIC_BUNDLE="$FIX/public-bundle.pem" CORP_CA_STORES="$FIX/store.pem" \
        CORP_CA_SYSTEM_BUNDLE="$FIX/system-bundle.pem" CORP_CA_CHAIN_FILE="$FIX/chain-proxy.pem" \
        CORP_CA_RC_FILES="$HOME/.bashrc" "$@"
}

_pem_count() { grep -c 'BEGIN CERTIFICATE' "$1" 2>/dev/null || echo 0; }

# ── Tests ───────────────────────────────────────────────────────────────────

test_script_exists() {
    assert_file_exists "$CA_SCRIPT"
}

test_detect_clean_chain_is_direct() {
    local out rc=0
    out=$(run_ca CORP_CA_CHAIN_FILE="$FIX/chain-clean.pem" bash "$CA_SCRIPT" detect 2>&1) || rc=$?
    assert_eq "1" "$rc" "a chain that verifies against the public roots must report no proxy"
    assert_contains "$out" "direct"
}

test_detect_proxy_chain_reports_issuer() {
    local out rc=0
    out=$(run_ca bash "$CA_SCRIPT" detect 2>&1) || rc=$?
    assert_eq "0" "$rc" "a chain the public roots cannot verify must report interception"
    assert_contains "$out" "Acme Inspection"
}

test_system_store_does_not_hide_proxy() {
    # openssl verify also loads its DEFAULT cert directory unless told otherwise. A box where
    # IT (or the manual recipe) already put the proxy root there must still read as
    # intercepted — Node ignores that directory and fails anyway.
    # OpenSSL 3 has THREE implicit sources (default file, default dir, default CAstore); the
    # env vars below point the first two at the proxy root, and the CAstore follows them.
    local d="$HOME/sysdir"; mkdir -p "$d"; cp "$FIX/corproot.pem" "$d/"
    openssl rehash "$d" >/dev/null 2>&1 || c_rehash "$d" >/dev/null 2>&1
    local rc=0
    run_ca SSL_CERT_DIR="$d" SSL_CERT_FILE="$d/corproot.pem" bash "$CA_SCRIPT" detect >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "a proxy root in the default cert dir/file must not make the chain look public"
}

test_default_store_cannot_rescue_decoy() {
    # Same trap in root selection: with the real root in the default directory, a same-name
    # decoy listed first in the store would "verify" unless verification ignores that dir.
    local d="$HOME/sysdir"; mkdir -p "$d"; cp "$FIX/corproot.pem" "$d/"
    openssl rehash "$d" >/dev/null 2>&1 || c_rehash "$d" >/dev/null 2>&1
    cat "$FIX/decoy.pem" "$FIX/corproot.pem" > "$HOME/store-decoy-first.pem"
    assert_success run_ca SSL_CERT_DIR="$d" SSL_CERT_FILE="$d/corproot.pem" \
        CORP_CA_STORES="$HOME/store-decoy-first.pem" bash "$CA_SCRIPT" setup
    assert_eq "$CORP_FP" "$(_fp "$HOME/.certs/corporate-ca.pem")" "the decoy must not be chosen"
}

test_settings_default_target_follows_cc_mirror_dir() {
    local m="$HOME/mirror"; mkdir -p "$m/config"; echo '{}' > "$m/config/settings.json"
    assert_success run_ca CC_MIRROR_DIR="$m" bash "$CA_SCRIPT" setup
    assert_file_contains "$m/config/settings.json" "NODE_EXTRA_CA_CERTS"
}

test_setup_clean_chain_is_noop() {
    echo 'existing line' > "$HOME/.bashrc"
    mkdir -p "$HOME/.cc-mirror/mclaude/config"
    echo '{"env":{"KEEP":"1"}}' > "$HOME/.cc-mirror/mclaude/config/settings.json"
    local before; before=$(cat "$HOME/.cc-mirror/mclaude/config/settings.json")
    assert_success run_ca CORP_CA_CHAIN_FILE="$FIX/chain-clean.pem" bash "$CA_SCRIPT" setup
    assert_file_not_exists "$HOME/.certs/corporate-ca.pem"
    assert_file_not_exists "$HOME/.certs/corporate-ca.env"
    assert_eq "existing line" "$(cat "$HOME/.bashrc")" "rc file untouched without a proxy"
    assert_eq "$before" "$(cat "$HOME/.cc-mirror/mclaude/config/settings.json")" "settings untouched without a proxy"
}

test_setup_finds_corporate_root_not_decoy() {
    assert_success run_ca bash "$CA_SCRIPT" setup
    assert_file_exists "$HOME/.certs/corporate-ca.pem"
    assert_eq "1" "$(_pem_count "$HOME/.certs/corporate-ca.pem")" "exactly one root written"
    assert_eq "$CORP_FP" "$(_fp "$HOME/.certs/corporate-ca.pem")" "the root that signed the chain, not the same-name decoy"
}

test_bundle_verifies_the_intercepted_chain() {
    assert_success run_ca bash "$CA_SCRIPT" setup
    local b="$HOME/.certs/ca-bundle.pem"
    assert_file_exists "$b"
    assert_success openssl verify -CAfile "$b" -untrusted "$FIX/corpinter.pem" "$FIX/corpleaf.pem"
    # The system bundle stays in it, so public sites keep working through the same variables.
    assert_success openssl verify -CAfile "$b" -untrusted "$FIX/pubinter.pem" "$FIX/publeaf.pem"
}

test_root_sent_by_network_is_never_trusted() {
    # A hostile Wi-Fi can present its own self-signed root at the top of the chain. Trusting
    # that would make the MITM persistent (rc block, NODE_EXTRA_CA_CERTS, settings). Only a
    # root that is already in a LOCAL store, or that the user names with --root, may be used.
    local rc=0
    run_ca CORP_CA_CHAIN_FILE="$FIX/chain-proxy-with-root.pem" \
        CORP_CA_STORES="$FIX/store-without-corp.pem" bash "$CA_SCRIPT" setup >/dev/null 2>&1 || rc=$?
    assert_eq "3" "$rc" "a root that only the network supplied is refused"
    assert_file_not_exists "$HOME/.certs/corporate-ca.pem"
}

test_root_sent_and_in_store_is_found_in_store() {
    assert_success run_ca CORP_CA_CHAIN_FILE="$FIX/chain-proxy-with-root.pem" bash "$CA_SCRIPT" setup
    assert_eq "$CORP_FP" "$(_fp "$HOME/.certs/corporate-ca.pem")"
}

test_partial_write_is_reported() {
    echo 'x' > "$HOME/.bashrc"; chmod 444 "$HOME/.bashrc"
    local out rc=0
    out=$(run_ca bash "$CA_SCRIPT" setup 2>&1) || rc=$?
    chmod 644 "$HOME/.bashrc"
    assert_neq "0" "$rc" "a failed rc write must not report success"
    assert_contains "$out" ".bashrc"
}

test_env_is_eval_safe_with_odd_path_chars() {
    local d="$HOME/we\$ird \"dir'"
    assert_success run_ca CORP_CA_DIR="$d" bash "$CA_SCRIPT" setup
    local got
    got=$(run_ca CORP_CA_DIR="$d" bash -c 'set -euo pipefail; eval "$(bash "$1" env)"; printf %s "$NODE_EXTRA_CA_CERTS"' _ "$CA_SCRIPT")
    assert_eq "$d/corporate-ca.pem" "$got" "eval of the env output must reproduce the path exactly"
}

test_env_skips_missing_files() {
    assert_success run_ca bash "$CA_SCRIPT" setup
    rm -f "$HOME/.certs/ca-bundle.pem"
    local out
    out=$(run_ca bash "$CA_SCRIPT" env)
    assert_eq "" "$out" "an env pointing at a deleted bundle would break every TLS client"
}

test_root_not_found_fails_cleanly() {
    local out rc=0
    out=$(run_ca CORP_CA_STORES="$FIX/store-without-corp.pem" bash "$CA_SCRIPT" setup 2>&1) || rc=$?
    assert_eq "3" "$rc" "interception without a findable root is exit 3"
    assert_contains "$out" "setup --root"
    assert_file_not_exists "$HOME/.certs/corporate-ca.env"
    assert_file_not_exists "$HOME/.certs/corporate-ca.pem"
}

test_explicit_root_file() {
    # The manual way out when no store holds the root: the user exports it and names it.
    assert_success run_ca CORP_CA_STORES="$FIX/store-without-corp.pem" bash "$CA_SCRIPT" setup --root "$FIX/corproot.pem"
    assert_eq "$CORP_FP" "$(_fp "$HOME/.certs/corporate-ca.pem")"
    assert_success openssl verify -CAfile "$HOME/.certs/ca-bundle.pem" -untrusted "$FIX/corpinter.pem" "$FIX/corpleaf.pem"
}

test_explicit_root_rejects_non_certificate() {
    echo "not a cert" > "$HOME/bogus.pem"
    local rc=0
    run_ca bash "$CA_SCRIPT" setup --root "$HOME/bogus.pem" >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "a file that is not a certificate is refused"
    assert_file_not_exists "$HOME/.certs/corporate-ca.env"
}

test_env_file_points_at_written_files() {
    assert_success run_ca bash "$CA_SCRIPT" setup
    local vals
    vals=$(bash -c '. "$HOME/.certs/corporate-ca.env"; printf "%s|%s|%s|%s|%s" "$NODE_EXTRA_CA_CERTS" "$SSL_CERT_FILE" "$CURL_CA_BUNDLE" "$GIT_SSL_CAINFO" "$REQUESTS_CA_BUNDLE"')
    local b="$HOME/.certs/ca-bundle.pem"
    assert_eq "$HOME/.certs/corporate-ca.pem|$b|$b|$b|$b" "$vals"
}

test_rc_block_is_idempotent() {
    echo 'export FOO=1' > "$HOME/.bashrc"
    assert_success run_ca bash "$CA_SCRIPT" setup
    assert_success run_ca bash "$CA_SCRIPT" setup
    assert_grep_count "$HOME/.bashrc" 'corporate-ca.env' 1
    assert_file_contains "$HOME/.bashrc" 'export FOO=1'
    local v
    v=$(bash -c '. "$HOME/.bashrc"; printf %s "$NODE_EXTRA_CA_CERTS"')
    assert_eq "$HOME/.certs/corporate-ca.pem" "$v" "sourcing the rc file sets the variables"
}

test_settings_env_merged_and_mode_kept() {
    local s="$HOME/.cc-mirror/mclaude/config/settings.json"
    mkdir -p "$(dirname "$s")"
    echo '{"model":"opus","env":{"SECRET_TOKEN":"keep-me"},"hooks":{}}' > "$s"
    chmod 600 "$s"
    assert_success run_ca bash "$CA_SCRIPT" setup
    local got
    got=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));e=d["env"];print(d["model"],e["SECRET_TOKEN"],e["NODE_EXTRA_CA_CERTS"],e["SSL_CERT_FILE"],e["REQUESTS_CA_BUNDLE"],e["CURL_CA_BUNDLE"],e["GIT_SSL_CAINFO"],"hooks" in d)' "$s")
    local b="$HOME/.certs/ca-bundle.pem"
    assert_eq "opus keep-me $HOME/.certs/corporate-ca.pem $b $b $b $b True" "$got"
    assert_eq "600" "$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$s")" "settings.json keeps mode 600"
}

test_no_settings_file_is_not_created() {
    assert_success run_ca bash "$CA_SCRIPT" setup
    assert_file_not_exists "$HOME/.cc-mirror/mclaude/config/settings.json"
}

test_persist_settings_explicit_target() {
    assert_success run_ca bash "$CA_SCRIPT" setup
    local s="$HOME/other/settings.json"
    mkdir -p "$(dirname "$s")"; echo '{}' > "$s"
    assert_success run_ca bash "$CA_SCRIPT" persist-settings "$s"
    assert_file_contains "$s" "NODE_EXTRA_CA_CERTS"
}

test_persist_settings_without_setup_is_noop() {
    local s="$HOME/x/settings.json"
    mkdir -p "$(dirname "$s")"; echo '{"a":1}' > "$s"
    assert_success run_ca bash "$CA_SCRIPT" persist-settings "$s"
    assert_eq '{"a":1}' "$(cat "$s")" "no corporate CA configured → settings untouched"
}

test_probe_failure_is_exit_2_and_setup_noop() {
    : > "$FIX/empty.pem"
    local rc=0
    run_ca CORP_CA_CHAIN_FILE="$FIX/empty.pem" bash "$CA_SCRIPT" detect >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "no chain obtained → cannot tell"
    assert_success run_ca CORP_CA_CHAIN_FILE="$FIX/empty.pem" bash "$CA_SCRIPT" setup
    assert_file_not_exists "$HOME/.certs/corporate-ca.env"
}

test_dry_run_writes_nothing() {
    local out
    out=$(run_ca bash "$CA_SCRIPT" setup --dry-run 2>&1)
    assert_contains "$out" "Acme Inspection"
    assert_eq "absent" "$([[ -e "$HOME/.certs" ]] && echo present || echo absent)" "no ~/.certs in a dry run"
    assert_file_not_exists "$HOME/.bashrc"
}

test_install_base_runs_ca_before_downloads() {
    # Product-level: install-base's main must configure trust before the first network step
    # (Homebrew/apt, nvm via curl, npm), and source the env so those steps inherit it.
    local f="$REPO_ROOT/setup/install-base.sh"
    local ca_line node_line deps_line
    ca_line=$(grep -n '^    setup_corporate_ca$' "$f" | cut -d: -f1)
    deps_line=$(grep -n '^    install_system_deps$' "$f" | cut -d: -f1)
    node_line=$(grep -n '^    install_nodejs$' "$f" | cut -d: -f1)
    assert_neq "" "$ca_line" "main() calls setup_corporate_ca"
    if [[ -n "$ca_line" ]]; then
        assert_eq "1" "$(( ca_line < deps_line && ca_line < node_line ))" "before system deps and nvm"
    fi
}

test_install_base_function_exports_env() {
    # Sourcing install-base.sh whole runs its top-level code (template-marker cleanup in the
    # repo root), so lift just the function out and run it with stub loggers.
    local f="$REPO_ROOT/setup/install-base.sh" fn
    fn=$(sed -n '/^setup_corporate_ca() {$/,/^}$/p' "$f")
    assert_neq "" "$fn" "install-base.sh defines setup_corporate_ca"
    local out
    out=$(run_ca DRY_RUN=false SCRIPT_DIR="$REPO_ROOT/setup" FN="$fn" bash -c '
        log_info() { :; }; log_warn() { :; }; log_success() { :; }; INSTALLED_STEPS=()
        eval "$FN"
        setup_corporate_ca >/dev/null 2>&1
        printf %s "${NODE_EXTRA_CA_CERTS:-unset}"')
    assert_eq "$HOME/.certs/corporate-ca.pem" "$out" "later install steps inherit the corporate CA"
}

# install-base runs under `set -euo pipefail` with an ERR trap: no outcome of the CA step
# (proxy, no proxy, root missing, probe failure) may abort the installer.
_lifted_install_step() {  # VAR=value… for run_ca; prints "rc=<n> node=<value>"
    local fn; fn=$(sed -n '/^setup_corporate_ca() {$/,/^}$/p' "$REPO_ROOT/setup/install-base.sh")
    run_ca "$@" DRY_RUN=false SCRIPT_DIR="$REPO_ROOT/setup" FN="$fn" bash -c '
        set -euo pipefail
        trap "echo TRAPPED >&2; exit 99" ERR
        log_info() { :; }; log_warn() { :; }; log_success() { :; }; INSTALLED_STEPS=()
        eval "$FN"
        setup_corporate_ca >/dev/null 2>&1
        echo "rc=0 node=${NODE_EXTRA_CA_CERTS:-unset}"' 2>&1 || echo "rc=$?"
}

test_install_step_survives_strict_mode() {
    : > "$FIX/empty.pem"
    assert_eq "rc=0 node=$HOME/.certs/corporate-ca.pem" "$(_lifted_install_step)" "proxy"
    rm -rf "$HOME/.certs"
    assert_eq "rc=0 node=unset" "$(_lifted_install_step CORP_CA_CHAIN_FILE="$FIX/chain-clean.pem")" "no proxy"
    assert_eq "rc=0 node=unset" "$(_lifted_install_step CORP_CA_STORES="$FIX/store-without-corp.pem")" "root not found"
    assert_eq "rc=0 node=unset" "$(_lifted_install_step CORP_CA_CHAIN_FILE="$FIX/empty.pem")" "probe failed"
}

test_configure_claude_persists_settings() {
    assert_file_contains "$REPO_ROOT/setup/configure-claude.sh" 'persist-settings "${CONFIG_DIR}/settings.json"'
}

_is_wsl_with_ps() { grep -qi microsoft /proc/version 2>/dev/null && command -v powershell.exe >/dev/null 2>&1; }

test_wsl_windows_store_export() {
    local out n
    out=$(env -u CORP_CA_STORES bash "$CA_SCRIPT" export-stores 2>/dev/null)
    n=$(printf '%s\n' "$out" | grep -c 'BEGIN CERTIFICATE')
    assert_eq "1" "$(( n >= 10 ))" "the Windows root store yields >= 10 PEM certificates (got $n)"
    printf '%s\n' "$out" | awk '/BEGIN CERT/{f=1} f{print} /END CERT/{exit}' > "$HOME/first.pem"
    assert_success openssl x509 -noout -in "$HOME/first.pem"
}

suite_header "corporate-ca.sh (CFG-864)"
for t in script_exists detect_clean_chain_is_direct detect_proxy_chain_reports_issuer \
         system_store_does_not_hide_proxy default_store_cannot_rescue_decoy \
         settings_default_target_follows_cc_mirror_dir \
         setup_clean_chain_is_noop setup_finds_corporate_root_not_decoy \
         bundle_verifies_the_intercepted_chain root_sent_by_network_is_never_trusted \
         root_sent_and_in_store_is_found_in_store partial_write_is_reported \
         env_is_eval_safe_with_odd_path_chars env_skips_missing_files install_step_survives_strict_mode \
         root_not_found_fails_cleanly explicit_root_file explicit_root_rejects_non_certificate \
         env_file_points_at_written_files rc_block_is_idempotent \
         settings_env_merged_and_mode_kept no_settings_file_is_not_created \
         persist_settings_explicit_target persist_settings_without_setup_is_noop \
         probe_failure_is_exit_2_and_setup_noop dry_run_writes_nothing \
         install_base_runs_ca_before_downloads install_base_function_exports_env \
         configure_claude_persists_settings; do
    run_test "$t" "test_$t"
done
if _is_wsl_with_ps; then
    run_test wsl_windows_store_export test_wsl_windows_store_export
else
    skip_test wsl_windows_store_export "not WSL"
fi
suite_summary
