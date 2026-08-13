#!/usr/bin/env bash
# network-detect.sh — Detect whether this machine is on the corporate or development network.
# Echoes exactly one of: corp | dev | unknown   (the agent treats 'unknown' as corp = stricter).
#
# Cross-platform: Linux/WSL (resolv.conf) + macOS (scutil --dns). Fail-safe by design:
#   - missing/empty config            → unknown
#   - no signal matches               → NETWORK_FALLBACK (coerced to corp|unknown; never dev)
#
# Signals come from setup/config/network-signals.conf (populated by Global IT).
# Test/override hooks (used by test-network-detect.sh — keep the unit tests off the real network):
#   NETDETECT_CONFIG  — path to the signals config (default: ../config/network-signals.conf)
#   NETDETECT_DNS     — inject the DNS suffix string instead of reading the system

set -uo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${NETDETECT_CONFIG:-$_SELF_DIR/../config/network-signals.conf}"

# Defaults (overridden by the config if present)
CORP_DNS_SUFFIX=""; DEV_DNS_SUFFIX=""
CORP_PROBE_HOST=""; CORP_PROBE_PORT="443"
DEV_PROBE_HOST="";  DEV_PROBE_PORT="443"
NETWORK_FALLBACK="unknown"

# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && source "$CONFIG" 2>/dev/null

# Fail-safe: the fallback may only be corp or unknown — never dev.
case "$NETWORK_FALLBACK" in corp|unknown) : ;; *) NETWORK_FALLBACK="unknown" ;; esac

# --- Gather the current DNS search/domain string ---
_dns_string() {
    if [[ -n "${NETDETECT_DNS:-}" ]]; then printf '%s' "$NETDETECT_DNS"; return; fi
    if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
        scutil --dns 2>/dev/null | awk '/search domain|domain *:/ {print $NF}' | tr '\n' ' '
    else
        awk '/^(search|domain)/ {for(i=2;i<=NF;i++) printf "%s ", $i}' /etc/resolv.conf 2>/dev/null
    fi
}

# --- longest-suffix match across corp+dev lists ---
# Dev networks are commonly a subdomain of corp (dev.example.com ⊂ example.com), so a plain
# substring/first-match would misclassify. We match on a dot boundary (host == suffix OR host
# ends with ".suffix") and the LONGEST (most specific) matching suffix wins. Ties favour corp
# (stricter), since corp needles are evaluated first and only a strictly-longer needle replaces.
# Echoes "corp", "dev", or "" (no match).
_best_match() {
    local dns="$1" corp_list="$2" dev_list="$3"
    local best_net="" best_len=0 token needle net list
    for token in $dns; do
        for net in corp dev; do
            [[ "$net" == corp ]] && list="$corp_list" || list="$dev_list"
            IFS=',' read -r -a _arr <<< "$list"
            for needle in "${_arr[@]}"; do
                needle="$(printf '%s' "$needle" | tr -d '[:space:]')"
                [[ -z "$needle" ]] && continue
                if [[ "$token" == "$needle" || "$token" == *".$needle" ]]; then
                    if (( ${#needle} > best_len )); then best_len=${#needle}; best_net="$net"; fi
                fi
            done
        done
    done
    printf '%s' "$best_net"
}

# --- TCP reachability probe (integration path; skipped when host empty) ---
_probe() {
    local host="$1" port="$2"
    [[ -z "$host" ]] && return 1
    timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null && return 0
    return 1
}

DNS="$(_dns_string)"

# Decision order: DNS (longest-suffix-wins) → corp probe → dev probe → fallback
_dns_net="$(_best_match "$DNS" "$CORP_DNS_SUFFIX" "$DEV_DNS_SUFFIX")"
if [[ -n "$_dns_net" ]]; then echo "$_dns_net"; exit 0; fi
if _probe "$CORP_PROBE_HOST" "$CORP_PROBE_PORT"; then echo "corp"; exit 0; fi
if _probe "$DEV_PROBE_HOST"  "$DEV_PROBE_PORT";  then echo "dev";  exit 0; fi

echo "$NETWORK_FALLBACK"
