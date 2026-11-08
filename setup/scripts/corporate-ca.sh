#!/usr/bin/env bash
# corporate-ca.sh — trust a TLS-inspecting proxy's root certificate in user space (CFG-864)
#
# A corporate TLS-inspecting proxy (any vendor) re-signs every HTTPS connection with its own
# root, which public trust stores do not hold, so Claude Code, npm, curl and git fail with
# "unable to get local issuer certificate". This script detects that BY SYMPTOM: it fetches
# the certificate chain of a few install hosts and checks it against a public-only root
# bundle. It never matches a vendor name. When a chain fails, it finds the root that signed
# it in the local stores (Linux bundle, the Windows root store from WSL, macOS keychains),
# confirms it with `openssl verify`, and writes:
#   ~/.certs/corporate-ca.pem   the proxy root(s)
#   ~/.certs/ca-bundle.pem      system bundle + proxy root(s)
#   ~/.certs/corporate-ca.env   NODE_EXTRA_CA_CERTS, SSL_CERT_FILE, CURL_CA_BUNDLE,
#                               GIT_SSL_CAINFO, REQUESTS_CA_BUNDLE
# plus a marked block in the shell rc that sources the env file, and the same variables in
# every Claude Code settings.json env it finds. No sudo. Without a proxy it changes nothing.
#
# Usage:
#   corporate-ca.sh detect                 exit 0 = proxy found, 1 = direct, 2 = could not probe
#   corporate-ca.sh setup [--dry-run] [--root <pem>]
#                                          exit 0 = done or nothing to do, 3 = root not found
#   corporate-ca.sh env                    print the env file (for eval), nothing if unset
#   corporate-ca.sh persist-settings [settings.json ...]
#   corporate-ca.sh export-stores          print every candidate root as PEM (diagnostics)
#
# Test seams: CORP_CA_CHAIN_FILE (replaces the network probe), CORP_CA_PUBLIC_BUNDLE,
# CORP_CA_STORES (colon-separated PEM files; replaces store discovery), CORP_CA_SYSTEM_BUNDLE,
# CORP_CA_RC_FILES (space-separated), CORP_CA_HOSTS, CORP_CA_DIR.

set -uo pipefail

CERT_DIR="${CORP_CA_DIR:-$HOME/.certs}"
ROOT_PEM="$CERT_DIR/corporate-ca.pem"
BUNDLE_PEM="$CERT_DIR/ca-bundle.pem"
ENV_FILE="$CERT_DIR/corporate-ca.env"
HOSTS="${CORP_CA_HOSTS:-api.anthropic.com github.com registry.npmjs.org}"
MARK_BEGIN="# >>> agent-fleet corporate CA (CFG-864) >>>"
MARK_END="# <<< agent-fleet corporate CA (CFG-864) <<<"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/corporate-ca.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

say() { printf 'corporate-ca: %s\n' "$*" >&2; }

# ── PEM helpers ─────────────────────────────────────────────────────────────

# split_pem <file> <dir>: one file per certificate, c0001.pem … in input order.
split_pem() {
    mkdir -p "$2"
    awk -v d="$2" '/-----BEGIN CERTIFICATE-----/{n++; f=sprintf("%s/c%04d.pem", d, n)}
        f{print > f} /-----END CERTIFICATE-----/{if (f) close(f); f=""}' "$1" 2>/dev/null
}

is_cert() { openssl x509 -noout -in "$1" >/dev/null 2>&1; }

# verify_with <cafile> <untrusted|empty> <leaf>: trust ONLY <cafile>. Even with -CAfile,
# openssl also loads its default cert directory and (OpenSSL 3) its default CAstore, so a
# proxy root IT already installed would make a proxied chain look public and let a same-name
# decoy "verify". Measured 2026-11-08: OpenSSL 3.0.13 verified api.anthropic.com's real chain
# against a CAfile holding one unrelated root until -no-CAstore was added.
VERIFY_ISOLATION=() VERIFY_READY=0
verify_isolation() {
    [[ $VERIFY_READY -eq 1 ]] && return 0
    VERIFY_READY=1
    local help; help=$(openssl verify -help 2>&1)
    if [[ "$help" == *-no-CApath* ]]; then VERIFY_ISOLATION+=(-no-CApath)
    else mkdir -p "$WORK/empty-capath"; VERIFY_ISOLATION+=(-CApath "$WORK/empty-capath"); fi   # LibreSSL
    [[ "$help" == *-no-CAstore* ]] && VERIFY_ISOLATION+=(-no-CAstore)
    return 0
}
verify_with() {
    verify_isolation
    local args=(-CAfile "$1" "${VERIFY_ISOLATION[@]}")
    [[ -s "$2" ]] && args+=(-untrusted "$2")
    openssl verify "${args[@]}" "$3" >/dev/null 2>&1
}

# chain_parts <chain> <dir>: split, then write <dir>/leaf.pem and <dir>/rest.pem.
# Bash 3.2 safe (macOS runs this before Homebrew can install a newer bash): no negative
# indexes, no mapfile, no expansion of a possibly empty array under `set -u`.
chain_parts() {
    split_pem "$1" "$2/c"
    local certs=("$2"/c/c*.pem) n i
    [[ -f "${certs[0]}" ]] || return 1
    n=${#certs[@]}
    cp "${certs[0]}" "$2/leaf.pem"
    : > "$2/rest.pem"
    for ((i = 1; i < n; i++)); do cat "${certs[$i]}" >> "$2/rest.pem"; done
    printf '%s\n' "${certs[$((n - 1))]}" > "$2/top"
}

# ── Sources ─────────────────────────────────────────────────────────────────

system_bundle() {
    if [[ -n "${CORP_CA_SYSTEM_BUNDLE:-}" ]]; then printf '%s\n' "$CORP_CA_SYSTEM_BUNDLE"; return 0; fi
    local f
    for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
        [[ -s "$f" ]] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

# public_bundle <out>: public roots only, so a corporate root already added to the system
# store does not hide the proxy (Node ignores the system store and would still fail).
public_bundle() {
    if [[ -n "${CORP_CA_PUBLIC_BUNDLE:-}" ]]; then cp "$CORP_CA_PUBLIC_BUNDLE" "$1"; return; fi
    if compgen -G '/usr/share/ca-certificates/mozilla/*.crt' >/dev/null; then
        cat /usr/share/ca-certificates/mozilla/*.crt > "$1"; return 0
    fi
    local kc=/System/Library/Keychains/SystemRootCertificates.keychain
    if [[ -e "$kc" ]] && command -v security >/dev/null 2>&1; then
        security find-certificate -a -p "$kc" > "$1" 2>/dev/null && [[ -s "$1" ]] && return 0
    fi
    local p sys
    p=$(python3 -c 'import certifi; print(certifi.where())' 2>/dev/null)
    sys=$(system_bundle) || sys=""
    if [[ -s "$p" ]] && [[ "$(readlink -f "$p")" != "$(readlink -f "$sys" 2>/dev/null)" ]]; then
        cp "$p" "$1"; return 0
    fi
    [[ -n "$sys" ]] && cp "$sys" "$1"   # weakest fallback: misses roots IT already installed
}

export_windows_roots() {
    command -v powershell.exe >/dev/null 2>&1 || return 1
    local ps='foreach ($s in "LocalMachine","CurrentUser") { foreach ($c in Get-ChildItem "Cert:\$s\Root") {
        "-----BEGIN CERTIFICATE-----"; [Convert]::ToBase64String($c.RawData, "InsertLineBreaks"); "-----END CERTIFICATE-----" } }'
    ( cd /mnt/c 2>/dev/null || cd /; _timeout powershell.exe -NoProfile -NonInteractive -Command "$ps" ) 2>/dev/null | tr -d '\r'
}

export_macos_roots() {
    command -v security >/dev/null 2>&1 || return 1
    local kc
    for kc in /Library/Keychains/System.keychain /System/Library/Keychains/SystemRootCertificates.keychain \
              "$HOME/Library/Keychains/login.keychain-db"; do
        [[ -e "$kc" ]] && security find-certificate -a -p "$kc" 2>/dev/null
    done
    return 0
}

# export_stores: every local root a proxy root could be found in, as PEM on stdout.
export_stores() {
    if [[ -n "${CORP_CA_STORES:-}" ]]; then
        local f; IFS=: read -ra _stores <<< "$CORP_CA_STORES"
        for f in "${_stores[@]}"; do cat "$f" 2>/dev/null; done
        return 0
    fi
    local sys; sys=$(system_bundle) && cat "$sys"
    grep -qi microsoft /proc/version 2>/dev/null && export_windows_roots
    [[ "$(uname -s)" == Darwin ]] && export_macos_roots
    return 0
}

# ── Probe and detection ─────────────────────────────────────────────────────

_timeout() { if command -v timeout >/dev/null 2>&1; then timeout 20 "$@"; else "$@"; fi; }

# probe_chain <host> <out>: the chain the network presents for <host>.
probe_chain() {
    if [[ -n "${CORP_CA_CHAIN_FILE:-}" ]]; then cp "$CORP_CA_CHAIN_FILE" "$2"; [[ -s "$2" ]]; return; fi
    command -v openssl >/dev/null 2>&1 || return 1
    local args=(-connect "$1:443" -servername "$1" -showcerts)
    local proxy="${https_proxy:-${HTTPS_PROXY:-}}"
    if [[ -n "$proxy" ]]; then
        proxy="${proxy#*://}"; proxy="${proxy##*@}"; proxy="${proxy%%/*}"
        args+=(-proxy "$proxy")
    fi
    _timeout openssl s_client "${args[@]}" </dev/null 2>/dev/null \
        | awk '/-----BEGIN CERTIFICATE-----/{p=1} p{print} /-----END CERTIFICATE-----/{p=0}' > "$2"
    grep -q 'BEGIN CERTIFICATE' "$2"
}

# detect_all: fills $WORK/hosts/<n>/ per probed host; prints intercepted hosts; sets PROBED.
PROBED=0
detect_all() {
    local hosts=($HOSTS) n=0 h d
    [[ -n "${CORP_CA_CHAIN_FILE:-}" ]] && hosts=(probe)
    public_bundle "$WORK/public.pem" || return 2
    for h in "${hosts[@]}"; do
        n=$((n + 1)); d="$WORK/hosts/$n"; mkdir -p "$d"
        probe_chain "$h" "$d/chain.pem" || continue
        chain_parts "$d/chain.pem" "$d" || continue
        PROBED=$((PROBED + 1))
        if verify_with "$WORK/public.pem" "$d/rest.pem" "$d/leaf.pem"; then continue; fi
        touch "$d/intercepted"
        printf 'intercepted %s — issuer: %s\n' "$h" "$(openssl x509 -noout -issuer -in "$(cat "$d/top")" | sed 's/^issuer= *//')"
    done
    return 0
}

intercepted_dirs() { local d; for d in "$WORK"/hosts/*/; do [[ -f "$d/intercepted" ]] && printf '%s\n' "${d%/}"; done; }

# find_root <hostdir> <stores.pem> <out>: the LOCAL root that makes this chain verify.
# Never a root the server sent: a hostile network can present its own self-signed root, and
# trusting it would make the interception permanent. A genuinely installed corporate root has
# the same subject hash as a self-signed top, so the store search still finds it.
find_root() {
    local d="$1" top want c
    top=$(cat "$d/top")
    want=$(openssl x509 -noout -issuer_hash -in "$top")
    [[ -d "$WORK/store" ]] || split_pem "$2" "$WORK/store"
    for c in "$WORK"/store/c*.pem; do
        [[ -f "$c" ]] || continue
        [[ "$(openssl x509 -noout -subject_hash -in "$c" 2>/dev/null)" == "$want" ]] || continue
        verify_with "$c" "$d/rest.pem" "$d/leaf.pem" && { cp "$c" "$3"; return 0; }
    done
    return 1
}

# ── Writers ─────────────────────────────────────────────────────────────────

# sq <string>: single-quoted for the shell, so eval/source reproduce it byte for byte.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

write_trust() {  # <roots.pem>
    local sys; sys=$(system_bundle) || sys=""
    if [[ ! -d "$CERT_DIR" ]]; then mkdir -p "$CERT_DIR" && chmod 700 "$CERT_DIR" || return 1; fi
    cp "$1" "$ROOT_PEM" || return 1
    { [[ -n "$sys" ]] && cat "$sys"; cat "$1"; } > "$BUNDLE_PEM" || return 1
    local r b; r=$(sq "$ROOT_PEM"); b=$(sq "$BUNDLE_PEM")
    printf '%s\n' "# Written by corporate-ca.sh (CFG-864): trust for a TLS-inspecting proxy. Re-run setup to refresh." \
        "export NODE_EXTRA_CA_CERTS=$r" "export SSL_CERT_FILE=$b" "export CURL_CA_BUNDLE=$b" \
        "export GIT_SSL_CAINFO=$b" "export REQUESTS_CA_BUNDLE=$b" > "$ENV_FILE"
}

rc_targets() {
    if [[ -n "${CORP_CA_RC_FILES:-}" ]]; then printf '%s\n' $CORP_CA_RC_FILES; return; fi
    [[ "$(uname -s)" != Darwin || -f "$HOME/.bashrc" ]] && printf '%s\n' "$HOME/.bashrc"
    [[ "$(uname -s)" == Darwin || -f "$HOME/.zshrc" ]] && printf '%s\n' "$HOME/.zshrc"
}

write_rc_blocks() {  # 1 and names the file if any rc could not be written
    local rc tmp e failed=0
    e=$(sq "$ENV_FILE")
    while IFS= read -r rc; do
        [[ -n "$rc" ]] || continue
        tmp="$WORK/rc.tmp"
        { [[ -f "$rc" ]] || : > "$rc"; } 2>/dev/null \
            && awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$rc" > "$tmp" \
            && printf '%s\n[ -f %s ] && . %s\n%s\n' "$MARK_BEGIN" "$e" "$e" "$MARK_END" >> "$tmp" \
            && cat "$tmp" > "$rc" 2>/dev/null \
            || { say "could not write the trust block into $rc"; failed=1; }
    done < <(rc_targets)
    return $failed
}

settings_targets() {
    if [[ -n "${CC_MIRROR_DIR:-}" ]]; then printf '%s\n' "$CC_MIRROR_DIR/config/settings.json"; return; fi
    local f; for f in "$HOME"/.cc-mirror/*/config/settings.json; do [[ -f "$f" ]] && printf '%s\n' "$f"; done
    return 0
}

# persist_settings [file…]: the same variables into each settings.json env (mode and other keys kept).
persist_settings() {
    [[ -f "$ENV_FILE" ]] || return 0
    local f
    if [[ $# -eq 0 ]]; then
        while IFS= read -r f; do [[ -n "$f" ]] && set -- "$@" "$f"; done < <(settings_targets)
    fi
    [[ $# -gt 0 ]] || return 0
    local failed=0
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        python3 - "$f" "$ROOT_PEM" "$BUNDLE_PEM" <<'PY' || { say "could not update $f (left unchanged)"; failed=1; }
import json, os, sys
path, root, bundle = sys.argv[1:4]
real = os.path.realpath(path)
with open(real) as fh:
    data = json.load(fh)
env = data.setdefault("env", {})
env.update({"NODE_EXTRA_CA_CERTS": root, "SSL_CERT_FILE": bundle, "CURL_CA_BUNDLE": bundle,
            "GIT_SSL_CAINFO": bundle, "REQUESTS_CA_BUNDLE": bundle})
mode = os.stat(real).st_mode & 0o777
tmp = real + ".corpca.tmp"
if os.path.exists(tmp):
    os.unlink(tmp)
# Created with the final mode: settings.json holds credentials, never world-readable, not even briefly.
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
with os.fdopen(fd, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
os.chmod(tmp, mode)
os.replace(tmp, real)
PY
    done
    return $failed
}

# ── Commands ────────────────────────────────────────────────────────────────

cmd_detect() {
    detect_all; local rc=$?
    [[ $rc -eq 2 || $PROBED -eq 0 ]] && { say "could not obtain any certificate chain"; return 2; }
    [[ -n "$(intercepted_dirs)" ]] && return 0
    echo "direct — no TLS-inspecting proxy in the path"; return 1
}

collect_roots() {  # <out>: every intercepted chain's root, deduplicated; 1 if any is missing
    local d fp
    export_stores > "$WORK/stores.pem"
    : > "$1"; : > "$WORK/fps"
    while IFS= read -r d; do
        find_root "$d" "$WORK/stores.pem" "$d/root.pem" || return 1
        fp=$(openssl x509 -noout -fingerprint -sha256 -in "$d/root.pem")
        grep -qxF "$fp" "$WORK/fps" || { echo "$fp" >> "$WORK/fps"; cat "$d/root.pem" >> "$1"; }
    done < <(intercepted_dirs)
}

cmd_setup() {
    local dry=0 root_arg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in --dry-run) dry=1 ;; --root) root_arg="${2:-}"; shift ;; esac; shift
    done
    local roots="$WORK/roots.pem"
    if [[ -n "$root_arg" ]]; then
        is_cert "$root_arg" || { say "$root_arg is not a PEM certificate"; return 4; }
        cp "$root_arg" "$roots"
    else
        detect_all
        if [[ $PROBED -eq 0 ]]; then say "could not probe any host — leaving trust unchanged"; return 0; fi
        [[ -n "$(intercepted_dirs)" ]] || { say "no TLS-inspecting proxy detected — nothing to do"; return 0; }
        if ! collect_roots "$roots"; then
            say "the certificate chain does not verify against the public roots, and no local store"
            say "holds a root that completes it (a TLS-inspecting proxy, or a server sending an incomplete chain)."
            say "If it is a proxy, export its root to a PEM file (ask IT, or take it from the OS"
            say "certificate store) and run:  bash $0 setup --root <file.pem>"
            return 3
        fi
    fi
    if [[ $dry -eq 1 ]]; then
        say "dry run — would trust: $(openssl x509 -noout -subject -in "$roots" | sed 's/^subject= *//')"
        say "dry run — would write $ROOT_PEM, $BUNDLE_PEM, $ENV_FILE, rc blocks and settings env"
        return 0
    fi
    write_trust "$roots" || { say "could not write $CERT_DIR — nothing trusted"; return 5; }
    local failed=0
    write_rc_blocks || failed=1
    persist_settings || failed=1
    if [[ $failed -ne 0 ]]; then
        say "trusted in $ENV_FILE, but not everywhere (see above) — fix and re-run setup"; return 6
    fi
    say "trusted: $(openssl x509 -noout -subject -in "$ROOT_PEM" | sed 's/^subject= *//') → $ENV_FILE"
}

case "${1:-}" in
    detect)           cmd_detect ;;
    setup)            shift; cmd_setup "$@" ;;
    # Only when every file it names exists: an env pointing at a deleted bundle breaks every TLS client.
    env)              [[ -f "$ENV_FILE" && -f "$ROOT_PEM" && -f "$BUNDLE_PEM" ]] && cat "$ENV_FILE"; exit 0 ;;
    persist-settings) shift; persist_settings "$@" ;;
    export-stores)    export_stores ;;
    *) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 64 ;;
esac
