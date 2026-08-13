#!/usr/bin/env bash
# diagnose-macos-fetch.sh — diagnose cc-mirror "fetch failed" on macOS.
#
# cc-mirror downloads Claude Code via Node's global fetch(). On a corporate
# Mac that fetch can fail two very different ways:
#   (a) TLS interception — Node ships its OWN CA store and rejects the
#       company's root CA, even though macOS curl (Keychain) trusts it.
#   (b) firewall / required proxy — public npm is simply unreachable.
# The fix is opposite for each, so this script tells them apart, and for (a)
# extracts a CA bundle from the Mac Keychain and PROVES the NODE_EXTRA_CA_CERTS
# fix before you touch anything else.
#
# Read-only / idempotent: probes the network + reads PUBLIC Keychain certs,
# writes only under /tmp. No sudo, no password prompts.

set -u

URL="https://registry.npmjs.org/cc-mirror"
# cc-mirror's `mirror` provider downloads Claude Code itself from Google Cloud
# Storage, NOT npm. This is the host that actually matters for the variant build.
GCS="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/stable"
FT="/tmp/iv-ft.mjs"
CA="/tmp/iv-macos-ca.pem"
CURL_OK=0
NODE_OK=0
GCS_CURL_OK=0
GCS_NODE_OK=0

hr()  { printf '%s\n' "------------------------------------------------------------"; }
say() { printf '%s\n' "$*"; }

say "=== iv-agent-fleet macOS fetch diagnostic ==="
say "url under test: $URL"
hr

# [1] Node / cc-mirror environment ------------------------------------------
say "[1] Node environment"
say "    node:      $(command -v node || echo MISSING)  ($(node -v 2>/dev/null || echo '?'))"
say "    npm:       $(command -v npm  || echo MISSING)  ($(npm -v  2>/dev/null || echo '?'))"
say "    cc-mirror: $(command -v cc-mirror || echo 'MISSING (wrong Node version? run: nvm use 22)')"
say "    NODE_EXTRA_CA_CERTS = ${NODE_EXTRA_CA_CERTS:-<unset>}"
hr

# [2] npm config ------------------------------------------------------------
say "[2] npm config"
say "    registry:    $(npm config get registry    2>/dev/null)"
say "    proxy:       $(npm config get proxy        2>/dev/null)"
say "    https-proxy: $(npm config get https-proxy  2>/dev/null)"
hr

# [3] curl reachability — macOS curl trusts the Keychain (incl. MDM corp CA) -
say "[3] curl reachability (macOS Keychain trust)"
curl_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$URL" 2>/tmp/iv-curl.err)"
curl_rc=$?
if [ "$curl_rc" -eq 0 ] && [ "$curl_code" = "200" ]; then
  say "    curl: OK (HTTP $curl_code)"
  CURL_OK=1
else
  say "    curl: FAIL (rc=$curl_rc, http=$curl_code) -> $(tr -d '\n' </tmp/iv-curl.err 2>/dev/null)"
fi
hr

# [4] Node fetch — exactly what cc-mirror does ------------------------------
say "[4] Node fetch (what cc-mirror uses)"
cat > "$FT" <<'EOF'
const url = process.argv[2] || "https://registry.npmjs.org/cc-mirror";
try {
  const r = await fetch(url);
  console.log("RESULT=OK HTTP " + r.status);
} catch (e) {
  console.log("RESULT=FAIL");
  console.log("message: " + e.message);
  const c = e.cause;
  if (c) {
    console.log("cause.code: " + (c.code || "(none)"));
    console.log("cause.message: " + (c.message || String(c)));
  } else {
    console.log("cause: (none)");
  }
}
EOF
node_out="$(node "$FT" "$URL" 2>&1)"
printf '%s\n' "$node_out" | sed 's/^/    /'
printf '%s' "$node_out" | grep -q "RESULT=OK" && NODE_OK=1
hr

# [5] cc-mirror's REAL download host: Google Cloud Storage -------------------
say "[5] Google Cloud Storage (where cc-mirror downloads Claude Code itself)"
gcs_curl="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$GCS" 2>/tmp/iv-gcs.err)"
gcs_curl_rc=$?
if [ "$gcs_curl_rc" -eq 0 ] && printf '%s' "$gcs_curl" | grep -qE '^(200|30[12])$'; then
  say "    curl GCS: OK (HTTP $gcs_curl)"
  GCS_CURL_OK=1
else
  say "    curl GCS: FAIL (rc=$gcs_curl_rc, http=$gcs_curl) -> $(tr -d '\n' </tmp/iv-gcs.err 2>/dev/null)"
fi
gcs_node="$(node "$FT" "$GCS" 2>&1)"
printf '%s\n' "$gcs_node" | sed 's/^/    node GCS: /'
printf '%s' "$gcs_node" | grep -q "RESULT=OK" && GCS_NODE_OK=1
hr

# Keychain CA helper — TLS-interception fix attempt for a given URL ----------
try_keychain_ca() {
  local testurl="$1"
  command -v security >/dev/null 2>&1 || { say "    (no 'security' tool — not macOS? cannot auto-extract CA)"; return 1; }
  : > "$CA"
  security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain >>"$CA" 2>/dev/null
  security find-certificate -a -p /Library/Keychains/System.keychain                        >>"$CA" 2>/dev/null
  security find-certificate -a -p "$HOME/Library/Keychains/login.keychain-db"                >>"$CA" 2>/dev/null
  local certs; certs="$(grep -c 'BEGIN CERTIFICATE' "$CA" 2>/dev/null)"; certs="${certs:-0}"
  say "    extracted ${certs} Keychain certs -> $CA; re-testing Node..."
  if NODE_EXTRA_CA_CERTS="$CA" node "$FT" "$testurl" 2>&1 | grep -q "RESULT=OK"; then
    say "    *** FIX CONFIRMED — run this, then rerun the create: ***"
    say "      export NODE_EXTRA_CA_CERTS=$CA"
    return 0
  fi
  say "    Keychain bundle did not satisfy Node — ask IT for the corp root CA .pem."
  return 1
}

# [6] Verdict ----------------------------------------------------------------
say "[6] Verdict"
if [ "$CURL_OK" -eq 1 ] && [ "$NODE_OK" -eq 0 ]; then
  say "    npm: curl OK but Node fetch FAILS -> corporate TLS interception on npm."
  try_keychain_ca "$URL"
  say "    Then: cc-mirror quick --provider mirror --name ivclaude --no-tweak --claude-version latest"
elif [ "$CURL_OK" -eq 0 ] && [ "$NODE_OK" -eq 0 ]; then
  say "    npm unreachable for BOTH curl and Node -> firewall/proxy on npm itself."
  say "    Ask IT for the HTTPS proxy, or point npm at a corp Artifactory. curl err:"
  say "      $(tr -d '\n' </tmp/iv-curl.err 2>/dev/null)"
elif [ "$GCS_NODE_OK" -eq 1 ]; then
  say "    npm AND Google Cloud Storage are both reachable from Node. cc-mirror's"
  say "    'fetch failed' is something else (sub-URL or cc-mirror bug). Capture it:"
  say "      npm view cc-mirror version"
  say "      cc-mirror quick --provider mirror --name ivclaude --no-tweak --claude-version latest"
elif [ "$GCS_CURL_OK" -eq 0 ]; then
  say "    *** DIAGNOSIS: storage.googleapis.com is BLOCKED on this network. ***"
  say "    npm + git work, but cc-mirror downloads Claude Code from Google Cloud"
  say "    Storage, which is filtered here (curl AND Node both fail to reach it)."
  say "    This is firewall/proxy POLICY — not fixable on the laptop alone."
  say ""
  say "    -> Send Global IT this allowlist request for Marco's Mac:"
  say "         host:  storage.googleapis.com   (ideally *.googleapis.com)"
  say "         url:   $GCS"
  say "    Then rerun: cc-mirror quick --provider mirror --name ivclaude --no-tweak --claude-version latest"
else
  say "    curl reaches GCS but Node does not -> TLS interception scoped to GCS."
  try_keychain_ca "$GCS"
  say "    Then rerun the create command."
fi
hr
say "done."
