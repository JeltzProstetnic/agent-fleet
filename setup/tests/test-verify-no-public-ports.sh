#!/usr/bin/env bash
# Tests for setup/scripts/verify-no-public-ports.sh — off-host exposure verification (CFG-594)
#
# HERMETIC BY CONSTRUCTION. Two seams are stubbed so the suite never touches the
# network or any live host:
#   VERIFY_PORTS_PROBE_CMD        — <host> <port> -> prints open|closed|noanswer
#   VERIFY_PORTS_LOCAL_ADDRS_CMD  — prints this machine's addresses, one per line
# The probe classifier (_classify_connect) is additionally unit-tested by sourcing
# the script, so the real-network decision logic is pinned without a real network.
#
# THE CONTRACT UNDER TEST (post-refutation rebuild):
#   exit 0 PASS          only when EVERY probed port was observed (open or closed)
#   exit 1 FAIL          an unexpected port was proven open (trumps blindness)
#   exit 2 USAGE         bad arguments — including empty --allow/--ports
#   exit 3 INCONCLUSIVE  any port unanswered, or the scan could not run. Never a pass.
#   exit 4 ON-HOST       probing yourself is refused
# "No answer" is not evidence of safety: target-side DROP and vantage-side egress
# block are indistinguishable from a single vantage. The refuted version folded
# both into "not open" and passed — every test here that mentions INCONCLUSIVE
# exists to keep that fail-open dead.
source "$(dirname "$0")/test-helpers.sh"

suite_header "verify-no-public-ports.sh (CFG-594)"

SCRIPT="$REPO_ROOT/setup/scripts/verify-no-public-ports.sh"

# ── Fixtures ─────────────────────────────────────────────────────────────────

# Write a port->state map. Args: "22 open" "8788 closed" ...
# Ports absent from the map answer "noanswer" — the real-world silence case.
write_port_map() {
    local map="$TEST_TMPDIR/portmap"
    printf '%s\n' "$@" > "$map"
    echo "$map"
}

# Build the stub probe and point the seam at it. Records every port it was asked
# about in $TEST_TMPDIR/probed.log so tests can assert WHAT got probed.
make_stub_probe() {
    local map="$1"
    local path="$TEST_TMPDIR/stub-probe.sh"
    cat > "$path" << 'EOF'
#!/usr/bin/env bash
port="$2"
echo "$port" >> "$STUB_PROBE_LOG"
state=$(awk -v p="$port" '$1 == p { print $2; exit }' "$STUB_PORT_MAP" 2>/dev/null)
echo "${state:-noanswer}"
EOF
    chmod +x "$path"
    STUB_PORT_MAP="$map"
    STUB_PROBE_LOG="$TEST_TMPDIR/probed.log"
    : > "$STUB_PROBE_LOG"
    STUB_PROBE="$path"
    # Reset the other knobs so state cannot leak between tests.
    LOCAL_ADDRS_CMD=""
    OVERRIDE_TMPDIR=""
}

# Run the script under test with all seams stubbed. Sets RUN_OUT and RUN_RC.
run_verify() {
    local out="" rc=0
    out=$(STUB_PORT_MAP="$STUB_PORT_MAP" \
          STUB_PROBE_LOG="$STUB_PROBE_LOG" \
          TMPDIR="${OVERRIDE_TMPDIR:-${TMPDIR:-/tmp}}" \
          VERIFY_PORTS_PROBE_CMD="$STUB_PROBE" \
          VERIFY_PORTS_LOCAL_ADDRS_CMD="${LOCAL_ADDRS_CMD:-true}" \
          bash "$SCRIPT" "$@" 2>&1) || rc=$?
    RUN_OUT="$out"
    RUN_RC=$rc
}

probed_ports() {
    sort -n -u "$STUB_PROBE_LOG" | tr '\n' ' ' | sed 's/ $//'
}

probed_count() {
    sort -n -u "$STUB_PROBE_LOG" | grep -c . || true
}

# ── Exposure and clean verdicts ──────────────────────────────────────────────

test_unexpected_open_port_fails() {
    local map; map=$(write_port_map "22 open" "80 closed" "443 closed" "8788 open")
    make_stub_probe "$map"
    run_verify example.invalid --ports 22,80,443,8788
    assert_eq "1" "$RUN_RC" "an unexpected open port must exit 1" || return 1
    assert_contains "$RUN_OUT" "8788" "the offending port must be named" || return 1
    assert_contains "$RUN_OUT" "FAIL" "verdict must read FAIL" || return 1
    assert_not_contains "$RUN_OUT" "PASS" "must not also claim a pass"
}
run_test "unexpected open port FAILS and is named" test_unexpected_open_port_fails

test_fully_observed_clean_passes() {
    local map; map=$(write_port_map "22 open" "80 closed" "443 open" "8788 closed")
    make_stub_probe "$map"
    run_verify example.invalid --ports 22,80,443,8788
    assert_eq "0" "$RUN_RC" "all ports observed, only allowlisted open: exit 0" || return 1
    assert_contains "$RUN_OUT" "PASS" "verdict must read PASS"
}
run_test "every port observed + only allowlisted open PASSES" test_fully_observed_clean_passes

# Refutation #5: a bare "PASS" satisfied the old suite. The verdict LINE itself
# must carry the host and the probed-port count — that count is the script's own
# stated mitigation for a non-exhaustive port list.
test_pass_verdict_names_host_and_count() {
    local map; map=$(write_port_map "22 open" "80 closed" "443 open" "8788 closed")
    make_stub_probe "$map"
    run_verify example.invalid --ports 22,80,443,8788
    assert_eq "0" "$RUN_RC" "precondition: this run must pass" || return 1
    local pass_line; pass_line=$(grep "PASS" <<< "$RUN_OUT")
    assert_contains "$pass_line" "example.invalid" "the PASS line itself must name the host" || return 1
    assert_contains "$pass_line" "4 probed" "the PASS line itself must state the probed count"
}
run_test "PASS verdict line carries host name and probed count" test_pass_verdict_names_host_and_count

# Refutation #4: the old assertion on "22" was satisfied by the allowlist header.
# Pin the dedicated allowed-open report, whose label the header cannot fake.
test_allowed_open_reporting_pinned() {
    local map; map=$(write_port_map "22 open" "80 closed" "443 open" "8788 closed")
    make_stub_probe "$map"
    run_verify example.invalid --ports 22,80,443,8788
    assert_eq "0" "$RUN_RC" "precondition: this run must pass" || return 1
    assert_contains "$RUN_OUT" "allowed-open: 22,443" \
        "which allowed ports are actually open must be reported as allowed-open:"
}
run_test "allowed-open ports are reported under their own label" test_allowed_open_reporting_pinned

test_custom_allowlist_permits() {
    local map; map=$(write_port_map "22 open" "8788 open")
    make_stub_probe "$map"
    run_verify example.invalid --ports 22,8788 --allow 22,8788
    assert_eq "0" "$RUN_RC" "a custom allowlist naming 8788 must pass" || return 1
    assert_contains "$RUN_OUT" "PASS" "verdict must read PASS"
}
run_test "custom allowlist is honoured (permits 8788)" test_custom_allowlist_permits

test_custom_allowlist_narrows() {
    local map; map=$(write_port_map "22 closed" "80 open" "443 closed")
    make_stub_probe "$map"
    run_verify example.invalid --ports 22,80,443 --allow 22
    assert_eq "1" "$RUN_RC" "a narrowed allowlist must reject the default-allowed 80" || return 1
    assert_contains "$RUN_OUT" "80" "port 80 must be named as unexpected"
}
run_test "custom allowlist replaces the default (80 no longer allowed)" test_custom_allowlist_narrows

# ── Blindness is loud (refutations #1 and #2) ────────────────────────────────

# Refutation #2 verbatim scenario: restricted-egress vantage, 22/80 answer,
# everything else silent, 8788 exposed but unobservable. The refuted version
# printed PASS. The only honest verdict is INCONCLUSIVE, naming the blind ports.
test_partial_blindness_is_inconclusive() {
    local map; map=$(write_port_map "22 open" "80 closed")
    make_stub_probe "$map"
    run_verify example.invalid --ports 22,80,443,8788
    assert_eq "3" "$RUN_RC" "unanswered ports must force exit 3, never 0" || return 1
    assert_contains "$RUN_OUT" "INCONCLUSIVE" "verdict must read INCONCLUSIVE" || return 1
    assert_contains "$RUN_OUT" "2 of 4" "how many ports went unobserved must be stated" || return 1
    assert_contains "$RUN_OUT" "8788" "each unanswered port must be named" || return 1
    assert_contains "$RUN_OUT" "443" "each unanswered port must be named" || return 1
    assert_not_contains "$RUN_OUT" "PASS" "a partially-blind scan must never read as a pass"
}
run_test "partially-blind scan is INCONCLUSIVE and names the unobserved ports" test_partial_blindness_is_inconclusive

test_all_unanswered_is_inconclusive() {
    local map; map=$(write_port_map)   # every probe answers "noanswer"
    make_stub_probe "$map"
    run_verify example.invalid --ports 22,80,443,8788
    assert_eq "3" "$RUN_RC" "a fully-silent target must exit 3, not 0" || return 1
    assert_contains "$RUN_OUT" "4 of 4" "total blindness must be stated as such" || return 1
    assert_not_contains "$RUN_OUT" "PASS" "silence must never read as a pass"
}
run_test "fully-silent target is INCONCLUSIVE (nothing was measured)" test_all_unanswered_is_inconclusive

# Proven exposure outranks blindness — but the blindness must still be disclosed.
test_exposure_wins_over_blindness() {
    local map; map=$(write_port_map "8788 open")
    make_stub_probe "$map"
    run_verify example.invalid --ports 22,443,8788
    assert_eq "1" "$RUN_RC" "a proven open port is a FAIL even when other ports are blind" || return 1
    assert_contains "$RUN_OUT" "FAIL" "verdict must read FAIL" || return 1
    assert_contains "$RUN_OUT" "2 of 3" "the unmeasured remainder must still be disclosed"
}
run_test "proven exposure FAILS even when other ports are blind, blindness disclosed" test_exposure_wins_over_blindness

# Refutation #1: unrecognised probe output used to be folded into "not open".
test_unrecognised_probe_output_is_unobserved() {
    local map; map=$(write_port_map "22 banana" "80 closed")
    make_stub_probe "$map"
    run_verify example.invalid --ports 22,80
    assert_eq "3" "$RUN_RC" "garbage probe output is not an observation — exit 3" || return 1
    assert_contains "$RUN_OUT" "1 of 2" "the garbage port must count as unobserved" || return 1
    assert_not_contains "$RUN_OUT" "PASS" "garbage output must never read as a pass"
}
run_test "unrecognised probe output counts as unobserved, not as safe" test_unrecognised_probe_output_is_unobserved

# Refutation #1(b): a failed mktemp meant the scan never ran, yet the verdict
# claimed "2 probed". A scan that cannot run must say so and exit non-zero.
test_scan_cannot_run_is_an_error() {
    local map; map=$(write_port_map "22 open")
    make_stub_probe "$map"
    OVERRIDE_TMPDIR="/nonexistent/verify-ports-$$"
    run_verify example.invalid --ports 22,80
    OVERRIDE_TMPDIR=""
    assert_eq "3" "$RUN_RC" "a scan that could not run must exit 3" || return 1
    assert_contains "$RUN_OUT" "could not run" "the verdict must say the scan did not happen" || return 1
    assert_not_contains "$RUN_OUT" "PASS" "an unexecuted scan must never read as a pass" || return 1
    assert_not_contains "$RUN_OUT" "probed ports observed" "must not claim any observation"
}
run_test "a scan that cannot run (mktemp failure) is a loud error, never a pass" test_scan_cannot_run_is_an_error

# ── The probe classifier itself (unit-tested by sourcing) ────────────────────

# Refutation #1 root cause: only a completed handshake or an explicit "refused"
# is an OBSERVATION. Timeouts, no-route, net-unreachable — anything else — must
# classify as noanswer, or an unroutable network reads as "everything closed"
# and the fail-open is reborn.
classify() { ( source "$SCRIPT"; _classify_connect "$1" "$2" ); }

test_classify_connect_states() {
    assert_eq "open"     "$(classify 0 "")" "rc 0 = handshake completed = open" || return 1
    assert_eq "noanswer" "$(classify 124 "")" "timeout is NOT an observation" || return 1
    assert_eq "closed"   "$(classify 1 "bash: connect: Connection refused")" \
        "an explicit refusal is an observed closed" || return 1
    assert_eq "noanswer" "$(classify 1 "bash: connect: No route to host")" \
        "no-route must NOT read as closed" || return 1
    assert_eq "noanswer" "$(classify 1 "bash: connect: Network is unreachable")" \
        "net-unreachable must NOT read as closed" || return 1
    assert_eq "noanswer" "$(classify 1 "some future error text")" \
        "unrecognised failure text is unobserved, never an implicit observation"
}
run_test "probe classifier: only handshake/refusal are observations" test_classify_connect_states

# ── Argument validation (refutation #3) ──────────────────────────────────────

test_empty_allow_is_usage_error() {
    local map; map=$(write_port_map "22 open")
    make_stub_probe "$map"
    run_verify example.invalid --ports 22 --allow ''
    assert_eq "2" "$RUN_RC" "--allow '' is a typo, exit 2 — not exit 1, which means exposure" || return 1
    assert_contains "$RUN_OUT" "ERROR" "the message must read as a usage error" || return 1
    assert_not_contains "$RUN_OUT" "FAIL" "a typo must be distinguishable from a real hit" || return 1
    assert_eq "" "$(probed_ports)" "a rejected spec must abort before probing anything"
}
run_test "--allow '' is a usage error (exit 2), never an exposure verdict" test_empty_allow_is_usage_error

test_empty_ports_is_usage_error() {
    local map; map=$(write_port_map "22 open")
    make_stub_probe "$map"
    run_verify example.invalid --ports ''
    assert_eq "2" "$RUN_RC" "--ports '' must exit 2" || return 1
    run_verify example.invalid --ports ','
    assert_eq "2" "$RUN_RC" "--ports ',' expands to nothing and must exit 2" || return 1
    assert_eq "" "$(probed_ports)" "an empty scan set must never 'pass by vacuity'"
}
run_test "empty --ports spec is a usage error, not a vacuous pass" test_empty_ports_is_usage_error

test_bad_port_spec_is_usage_error() {
    local map; map=$(write_port_map "22 open")
    make_stub_probe "$map"
    run_verify example.invalid --ports "notaport"
    assert_eq "2" "$RUN_RC" "an unparseable port spec must exit 2" || return 1
    assert_eq "" "$(probed_ports)" "a bad spec must abort before probing anything"
}
run_test "unparseable --ports spec is a usage error, probes nothing" test_bad_port_spec_is_usage_error

test_partially_bad_port_spec_is_usage_error() {
    local map; map=$(write_port_map "22 open")
    make_stub_probe "$map"
    run_verify example.invalid --ports "22,notaport"
    assert_eq "2" "$RUN_RC" "a partially-parseable spec must exit 2, not scan the good half" || return 1
    assert_eq "" "$(probed_ports)" "nothing may be probed from a rejected spec"
}
run_test "partially-parseable --ports spec is rejected, not silently truncated" test_partially_bad_port_spec_is_usage_error

test_bad_timeout_is_usage_error() {
    local map; map=$(write_port_map "22 open")
    make_stub_probe "$map"
    run_verify example.invalid --ports 22 --timeout abc
    assert_eq "2" "$RUN_RC" "a non-numeric timeout must exit 2"
}
run_test "non-numeric --timeout is a usage error" test_bad_timeout_is_usage_error

test_missing_host_is_usage_error() {
    local map; map=$(write_port_map "22 open")
    make_stub_probe "$map"
    run_verify
    assert_eq "2" "$RUN_RC" "missing host argument must exit 2"
}
run_test "missing host argument is a usage error (exit 2)" test_missing_host_is_usage_error

# ── Vantage guard ────────────────────────────────────────────────────────────

test_on_host_vantage_refused() {
    local map; map=$(write_port_map "22 open" "8788 open")
    make_stub_probe "$map"
    LOCAL_ADDRS_CMD="echo 203.0.113.9"
    run_verify 203.0.113.9 --ports 22,8788
    LOCAL_ADDRS_CMD=""
    assert_eq "4" "$RUN_RC" "probing yourself cannot answer the question — exit 4" || return 1
    assert_eq "" "$(probed_ports)" "the guard must fire before any probe runs" || return 1
    assert_not_contains "$RUN_OUT" "PASS" "must not read as a pass"
}
run_test "on-host vantage point is refused (exit 4), probes nothing" test_on_host_vantage_refused

# ── Test seams are self-identifying (refutation #6) ──────────────────────────

test_seam_marker_present_when_stubbed() {
    local map; map=$(write_port_map "22 open" "80 closed" "443 open" "8788 closed")
    make_stub_probe "$map"
    run_verify example.invalid --ports 22,80,443,8788
    assert_contains "$RUN_OUT" "TEST SEAM" \
        "a run whose probes are stubbed must say so — it measured no real network"
}
run_test "stubbed run identifies itself (TEST SEAM marker in output)" test_seam_marker_present_when_stubbed

test_no_seam_marker_when_unstubbed() {
    local out="" rc=0
    out=$(env -u VERIFY_PORTS_PROBE_CMD -u VERIFY_PORTS_LOCAL_ADDRS_CMD \
          bash "$SCRIPT" example.invalid --ports "notaport" 2>&1) || rc=$?
    assert_eq "2" "$rc" "precondition: usage error, so no probe is ever attempted" || return 1
    assert_not_contains "$out" "TEST SEAM" "a real run must not carry the seam marker"
}
run_test "unstubbed run carries no seam marker" test_no_seam_marker_when_unstubbed

# ── Scan-set behaviour ───────────────────────────────────────────────────────

test_default_scan_catches_the_incident_port() {
    local map; map=$(write_port_map "22 open" "8788 open")
    make_stub_probe "$map"
    run_verify example.invalid          # no --ports: exercise the default scan set
    assert_eq "1" "$RUN_RC" "the default scan set must catch an open app port" || return 1
    assert_contains "$RUN_OUT" "8788" "8788 (the CFG-594 clickdummy port) must be named"
}
run_test "default scan set catches the port from the real incident" test_default_scan_catches_the_incident_port

# Refutation #7: the implementer claimed 66 default ports; there were 64. The
# verdict's count must be COMPUTED from what was actually probed, never asserted.
test_verdict_count_matches_what_was_probed() {
    local map; map=$(write_port_map)    # all silent -> INCONCLUSIVE "N of N"
    make_stub_probe "$map"
    run_verify example.invalid          # default port set, whatever its size
    assert_eq "3" "$RUN_RC" "precondition: fully-silent default scan is INCONCLUSIVE" || return 1
    local stated
    stated=$(sed -n 's/.*INCONCLUSIVE: [0-9]* of \([0-9]*\) probed.*/\1/p' <<< "$RUN_OUT" | head -1)
    assert_eq "$(probed_count)" "$stated" \
        "the count in the verdict must equal the number of ports actually probed"
}
run_test "verdict port count is computed from the actual probe set" test_verdict_count_matches_what_was_probed

test_port_ranges_expand() {
    local map; map=$(write_port_map "8788 open")
    make_stub_probe "$map"
    run_verify example.invalid --ports 8786-8790 --allow 22
    assert_eq "1" "$RUN_RC" "a range must expand and catch the open port inside it" || return 1
    assert_eq "8786 8787 8788 8789 8790" "$(probed_ports)" "every port in the range must be probed"
}
run_test "--ports ranges expand and are all probed" test_port_ranges_expand

test_probes_exactly_the_requested_ports() {
    local map; map=$(write_port_map "22 closed" "80 closed" "443 closed")
    make_stub_probe "$map"
    run_verify example.invalid --ports 443,22,22,80
    assert_eq "22 80 443" "$(probed_ports)" "requested ports are deduped, sorted, and all probed" || return 1
    assert_eq "0" "$RUN_RC" "all observed closed is a clean pass"
}
run_test "--ports is honoured exactly (dedup + sort, nothing extra)" test_probes_exactly_the_requested_ports

test_exit_codes_are_distinct() {
    local codes=()

    local map; map=$(write_port_map "22 open" "443 open")
    make_stub_probe "$map"
    run_verify example.invalid --ports 22,443; codes+=("$RUN_RC")           # PASS (all observed)

    map=$(write_port_map "22 open" "8788 open")
    make_stub_probe "$map"
    run_verify example.invalid --ports 22,8788; codes+=("$RUN_RC")          # FAIL

    run_verify; codes+=("$RUN_RC")                                          # USAGE

    map=$(write_port_map)
    make_stub_probe "$map"
    run_verify example.invalid --ports 22,8788; codes+=("$RUN_RC")          # INCONCLUSIVE

    map=$(write_port_map "22 open")
    make_stub_probe "$map"
    LOCAL_ADDRS_CMD="echo 203.0.113.9"
    run_verify 203.0.113.9 --ports 22; codes+=("$RUN_RC")                   # ON-HOST
    LOCAL_ADDRS_CMD=""

    local unique
    unique=$(printf '%s\n' "${codes[@]}" | sort -u | wc -l | tr -d ' ')
    assert_eq "5" "$unique" "five outcomes must have five distinct exit codes (got: ${codes[*]})"
}
run_test "every outcome has a distinct exit code" test_exit_codes_are_distinct

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
