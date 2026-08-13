#!/usr/bin/env bash
# test-network-detect.sh — TDD for network-detect.sh (corp/dev/unknown detection).
# Pure unit tests: DNS suffix is injected via NETDETECT_DNS; no real network access.
# The probe-host path is integration-only and intentionally NOT exercised here.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$SCRIPT_DIR/../scripts/network-detect.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
assert_eq() { # $1=desc $2=expected $3=actual
    if [[ "$2" == "$3" ]]; then echo "  ok: $1"; pass=$((pass+1));
    else echo "  FAIL: $1 — expected '$2', got '$3'"; fail=$((fail+1)); fi
}
mkconf() { printf '%s\n' "$@" > "$TMP/conf"; }
run() { NETDETECT_CONFIG="$TMP/conf" NETDETECT_DNS="${1:-}" bash "$DETECT" 2>/dev/null; }

echo "test-network-detect:"

# 1. Empty/placeholder config → unknown (fail-safe)
mkconf 'CORP_DNS_SUFFIX=""' 'DEV_DNS_SUFFIX=""' 'NETWORK_FALLBACK="unknown"'
assert_eq "empty config returns unknown" "unknown" "$(run 'host.example.org')"

# 2. Corp DNS suffix matches → corp
mkconf 'CORP_DNS_SUFFIX="example.com"' 'DEV_DNS_SUFFIX="dev.example.com"' 'NETWORK_FALLBACK="unknown"'
assert_eq "corp dns suffix matches → corp" "corp" "$(run 'wsl.example.com')"

# 3. Dev DNS suffix matches → dev
assert_eq "dev dns suffix matches → dev" "dev" "$(run 'box.dev.example.com')"

# 4. No suffix matches → fallback (unknown)
assert_eq "no match → unknown fallback" "unknown" "$(run 'host.example.org')"

# 5. FAIL-SAFE: a misconfigured dev fallback must be coerced to unknown (never assume dev)
mkconf 'CORP_DNS_SUFFIX="example.com"' 'NETWORK_FALLBACK="dev"'
assert_eq "dev fallback coerced to unknown" "unknown" "$(run 'host.example.org')"

# 6. corp fallback is allowed (stricter-by-default is safe)
mkconf 'CORP_DNS_SUFFIX="example.com"' 'NETWORK_FALLBACK="corp"'
assert_eq "corp fallback honored" "corp" "$(run 'host.example.org')"

# 7. Missing config file → unknown (never crashes)
assert_eq "missing config → unknown" "unknown" "$(NETDETECT_CONFIG="$TMP/nope" NETDETECT_DNS='x.example.com' bash "$DETECT" 2>/dev/null)"

echo "  --- $pass passed, $fail failed ---"
[[ "$fail" -eq 0 ]]
