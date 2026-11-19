#!/usr/bin/env bash
# Tests for setup/scripts/diagnose-macos-fetch.sh — the macOS "cc-mirror fetch failed"
# diagnostic. It probes the network, so every probe here is a PATH stub: curl and node
# answer per URL, npm prints a fixed config, and there is no `security` tool (not macOS),
# so the Keychain step reports that and the verdict still prints its next command.
#
# What is pinned (CFG-1077): the verdict commands name the configured variant
# (CC_MIRROR_VARIANT, default mclaude — the name the template's install uses), the
# script writes its scratch files under TMPDIR, and it speaks of no particular company,
# person or machine.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/setup/tests/test-helpers.sh"

suite_header "diagnose-macos-fetch.sh (verdicts, variant name, scratch dir)"

SCRIPT="$REPO_ROOT/setup/scripts/diagnose-macos-fetch.sh"

# _stubs <dir> <node-npm: ok|fail> <curl-gcs: ok|fail> — curl always reaches npm.
_stubs() {
    local d="$1" node_npm="$2" curl_gcs="$3"
    mkdir -p "$d"
    cat > "$d/curl" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do url="\$a"; done
case "\$url" in
  *registry.npmjs.org*) printf 200; exit 0 ;;
  *storage.googleapis.com*) if [ "$curl_gcs" = ok ]; then printf 200; exit 0; fi
                            echo "Could not resolve host" >&2; printf 000; exit 6 ;;
esac
printf 000; exit 7
EOF
    cat > "$d/node" <<EOF
#!/usr/bin/env bash
case "\$1" in -v) echo v22.0.0; exit 0 ;; esac
case "\${2:-}" in
  *registry.npmjs.org*) if [ "$node_npm" = ok ]; then echo "RESULT=OK HTTP 200"; exit 0; fi ;;
esac
echo "RESULT=FAIL"; echo "message: fetch failed"; exit 0
EOF
    cat > "$d/npm" <<'EOF'
#!/usr/bin/env bash
case "$1" in -v) echo 10.0.0 ;; config) echo "https://registry.npmjs.org/" ;; esac
exit 0
EOF
    chmod +x "$d/curl" "$d/node" "$d/npm"
}

# _run <stubdir> [VAR=value...] — run the script with only the stubs and the system tools.
_run() {
    local stubs="$1"; shift
    env -i HOME="$TEST_TMPDIR/home" TMPDIR="$TEST_TMPDIR/scratch" \
        PATH="$stubs:/usr/bin:/bin" "$@" bash "$SCRIPT" 2>&1 || true
}

test_gcs_blocked_names_the_configured_variant() {
    _stubs "$TEST_TMPDIR/s1" ok fail
    mkdir -p "$TEST_TMPDIR/home" "$TEST_TMPDIR/scratch"
    local out; out=$(_run "$TEST_TMPDIR/s1" CC_MIRROR_VARIANT=fooclaude)
    assert_contains "$out" "storage.googleapis.com is BLOCKED" "GCS-blocked verdict reached" || return 1
    assert_contains "$out" "--name fooclaude " "the rerun command names CC_MIRROR_VARIANT (fooclaude)" || return 1
    assert_contains "$out" "allowlist request for this Mac" "the IT request names no person's machine"
}
run_test "GCS blocked: allowlist request is generic, rerun names CC_MIRROR_VARIANT" test_gcs_blocked_names_the_configured_variant

test_npm_tls_interception_defaults_to_mclaude() {
    _stubs "$TEST_TMPDIR/s2" fail ok
    mkdir -p "$TEST_TMPDIR/home" "$TEST_TMPDIR/scratch"
    local out; out=$(_run "$TEST_TMPDIR/s2")
    assert_contains "$out" "corporate TLS interception on npm" "TLS-interception verdict reached" || return 1
    assert_contains "$out" "--name mclaude " "with CC_MIRROR_VARIANT unset the variant is mclaude"
}
run_test "npm TLS interception: rerun command defaults to the mclaude variant" test_npm_tls_interception_defaults_to_mclaude

test_banner_is_generic() {
    _stubs "$TEST_TMPDIR/s3" ok fail
    mkdir -p "$TEST_TMPDIR/home" "$TEST_TMPDIR/scratch"
    local out; out=$(_run "$TEST_TMPDIR/s3")
    assert_contains "$out" "=== agent-fleet macOS fetch diagnostic ===" "banner names the generic fleet"
}
run_test "banner names agent-fleet, not a particular deployment" test_banner_is_generic

test_scratch_files_live_under_tmpdir() {
    _stubs "$TEST_TMPDIR/s4" ok fail
    mkdir -p "$TEST_TMPDIR/home" "$TEST_TMPDIR/scratch"
    _run "$TEST_TMPDIR/s4" >/dev/null
    local n; n=$(find "$TEST_TMPDIR/scratch" -maxdepth 1 -name 'afdiag-*' | wc -l)
    [[ "$n" -ge 2 ]] || { echo "  scratch files under TMPDIR: $n (expected the fetch probe + curl logs)"; return 1; }
    echo "  scratch files under TMPDIR: $n"
}
run_test "scratch files go under TMPDIR with the afdiag- prefix" test_scratch_files_live_under_tmpdir

suite_summary
