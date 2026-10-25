#!/usr/bin/env bash
# lan-sudo.sh — run commands as root on LAN fleet hosts without unlocking the vault.
#
# Requested 2026-10-25 (P0): sudo on LAN hosts from here, no vault unlock, a store
# that someone with access "cant crack immediately" — real security explicitly NOT required
# (everything is on the home LAN). So this is OBFUSCATION: the store is AES-256 (openssl,
# PBKDF2) under a key derived from a random 0600 key file AND /etc/machine-id, so a copied
# store — even with its key file — does not open on another machine. Anyone who is already
# this user on this machine can open it; that is accepted.
#
#   lan-sudo.sh set <host>                 masked prompt, verified on the host, then stored
#   lan-sudo.sh run <host> -- <cmd> [args]  run as root (stored password, else sudo -n)
#   lan-sudo.sh run <host> --script <file>  stage a local script and run it as root
#     (only that one file is staged, to a remote /tmp path — a script that finds its
#     siblings via `dirname $0` will not find them; ship such a tree first, then use `--`)
#   lan-sudo.sh check <host> | list | forget <host>
#
# The password never reaches argv, a file on disk, or stdout: it goes from the store to
# `sudo -S` on ssh's stdin, and the command itself is staged to a remote 0600 temp file
# first (vault-ops rule 8: sudo -S only when nothing else uses that stdin).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${LAN_SUDO_DIR:-$HOME/.config/fleet-lan-sudo}"
STORE="$DIR/store.enc"
KEYF="$DIR/key"
MID_FILE="${LAN_SUDO_MACHINE_ID_FILE:-/etc/machine-id}"
SSH="${LAN_SUDO_SSH:-ssh}"
ASK="${LAN_SUDO_ASK:-$SCRIPT_DIR/ask-passphrase.sh}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=25)

die() { echo "lan-sudo: $*" >&2; exit "${2:-1}"; }

# The derived key, on stdout (callers feed it to openssl via an fd, never argv).
derive_key() {
    [[ -r "$KEYF" ]] || die "no key file ($KEYF) — store does not open" 3
    [[ -r "$MID_FILE" ]] || die "cannot read $MID_FILE" 3
    printf '%s:%s:fleet-lan-sudo-v1' "$(cat "$KEYF")" "$(cat "$MID_FILE")" | sha256sum | cut -d' ' -f1
}

# Plaintext store ("host<TAB>base64(password)" per line) on stdout; empty if no store.
load_store() {
    [[ -f "$STORE" ]] || return 0
    local k; k=$(derive_key)
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in "$STORE" -pass fd:3 3<<<"$k" 2>/dev/null \
        || die "store does not open (key file or machine-id changed)" 3
}

save_store() {
    local plain="$1" k tmp
    umask 077; mkdir -p "$DIR"
    [[ -f "$KEYF" ]] || head -c 32 /dev/urandom | base64 > "$KEYF"
    chmod 600 "$KEYF"
    k=$(derive_key); tmp="$STORE.tmp.$$"
    printf '%s' "$plain" | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -out "$tmp" -pass fd:3 3<<<"$k"
    chmod 600 "$tmp"; mv "$tmp" "$STORE"
}

# The stored password for $1 on stdout; returns 1 if the host has none.
get_pw() {
    local line; line=$(load_store | awk -F'\t' -v h="$1" '$1==h {print $2; exit}')
    [[ -n "$line" ]] || return 1
    printf '%s' "$line" | base64 -d
}

cmd_set() {
    local host="${1:?usage: lan-sudo.sh set <host>}" pw rest
    pw=$("$ASK" "sudo password for $host")
    [[ -n "$pw" ]] || die "empty password — nothing stored"
    printf '%s\n' "$pw" | "$SSH" "${SSH_OPTS[@]}" "$host" 'sudo -S -p "" -v' >/dev/null 2>&1 \
        || die "$host rejected the password (or is unreachable) — nothing stored"
    rest=$(load_store | awk -F'\t' -v h="$host" '$1!=h && NF')
    save_store "${rest:+$rest$'\n'}$host"$'\t'"$(printf '%s' "$pw" | base64 -w0)"$'\n'
    unset pw
    echo "lan-sudo: stored sudo password for $host"
}

# Stage $2 (script text) on host $1 as a 0600 temp file; echoes the remote path.
stage() {
    local host="$1" body="$2" rpath="/tmp/lan-sudo.$$.$RANDOM"
    printf '%s\n' "$body" | "$SSH" "${SSH_OPTS[@]}" "$host" "umask 077; cat > $rpath" \
        || die "could not stage the command on $host"
    echo "$rpath"
}

cmd_run() {
    local host="${1:?usage: lan-sudo.sh run <host> -- <cmd> | --script <file>}" body rpath pw tail
    shift
    case "${1:-}" in
        --)       shift; [[ $# -gt 0 ]] || die "run: no command given"; body=$(printf '%q ' "$@") ;;
        --script) [[ -r "${2:-}" ]] || die "run: script not readable: ${2:-}"; body=$(cat "$2") ;;
        *)        die "run: expected -- <cmd> or --script <file>" ;;
    esac
    rpath=$(stage "$host" "$body")
    tail="rc=\$?; rm -f $rpath; exit \$rc"
    if pw=$(get_pw "$host"); then
        printf '%s\n' "$pw" | "$SSH" "${SSH_OPTS[@]}" "$host" "sudo -S -p \"\" bash $rpath; $tail"
    else
        "$SSH" "${SSH_OPTS[@]}" "$host" "sudo -n bash $rpath; $tail" </dev/null
    fi
}

cmd_check() {
    local host="${1:?usage: lan-sudo.sh check <host>}"
    get_pw "$host" >/dev/null || die "no stored password for $host"
    echo "$host: stored"
}

cmd_forget() {
    local host="${1:?usage: lan-sudo.sh forget <host>}" rest
    rest=$(load_store | awk -F'\t' -v h="$host" '$1!=h && NF')
    save_store "${rest:+$rest$'\n'}"
    echo "lan-sudo: forgot $host"
}

case "${1:-}" in
    set)    shift; cmd_set "$@" ;;
    run)    shift; cmd_run "$@" ;;
    check)  shift; cmd_check "$@" ;;
    list)   load_store | cut -f1 ;;
    forget) shift; cmd_forget "$@" ;;
    *)      die "usage: lan-sudo.sh set|run|check|list|forget …" ;;
esac
