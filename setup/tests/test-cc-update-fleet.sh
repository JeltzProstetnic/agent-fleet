#!/usr/bin/env bash
# Tests for setup/scripts/cc-update-fleet.sh — drives cc-update.sh on remote fleet
# machines over SSH. TDD: tests written first.
#
# Transport is injectable (CC_FLEET_SSH / CC_FLEET_SCP) precisely so these tests never
# touch a real machine. A subagent/test reaching a live Deck is exactly the class of
# accident this file exists to prevent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

FLEET="$REPO_ROOT/setup/scripts/cc-update-fleet.sh"

suite_header "cc-update-fleet.sh"

# ── Stub transport ──────────────────────────────────────────────────────────
# ssh stub: answers a probe (marker CCPROBE) from STUB_PROBE_<host>, a verify
# (marker CCVERIFY) from STUB_VERIFY_<host>, anything else with exit 0.
# Every invocation is appended to $STUBLOG.

make_stubs() {
    mkdir -p "$TEST_TMPDIR/stub"
    STUBLOG="$TEST_TMPDIR/stub/calls.log"
    : > "$STUBLOG"
    cat > "$TEST_TMPDIR/stub/ssh" << 'SSHEOF'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$STUBLOG"
# `-o BatchMode=yes` is TWO argv entries and the second does not start with `-`,
# so a naive "first non-dash arg" scan reads the OPTION VALUE as the hostname.
args=("$@"); host=""; i=0
while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
        -o|-i|-p|-F|-l) i=$((i + 2)) ;;
        -*)             i=$((i + 1)) ;;
        *)              host="${args[$i]}"; break ;;
    esac
done
cmd="$*"
san=${host//[^a-zA-Z0-9]/_}
if [[ "$cmd" == *CCPROBE* ]]; then
    v="STUB_PROBE_$san"; printf '%s\n' "${!v:-}"
elif [[ "$cmd" == *CCVERIFY* ]]; then
    v="STUB_VERIFY_$san"; printf '%s\n' "${!v:-}"
fi
exit 0
SSHEOF
    cat > "$TEST_TMPDIR/stub/scp" << 'SCPEOF'
#!/usr/bin/env bash
printf 'scp %s\n' "$*" >> "$STUBLOG"
exit 0
SCPEOF
    chmod +x "$TEST_TMPDIR/stub/ssh" "$TEST_TMPDIR/stub/scp"
    export STUBLOG
    export CC_FLEET_SSH="$TEST_TMPDIR/stub/ssh"
    export CC_FLEET_SCP="$TEST_TMPDIR/stub/scp"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true
}

stub_binary() {  # <version> → path to a stand-in for the tarball ELF
    printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$1" > "$TEST_TMPDIR/claude.src"
    chmod +x "$TEST_TMPDIR/claude.src"
    printf '%s' "$TEST_TMPDIR/claude.src"
}

count_calls() { local n; n=$(grep -c "^$1 " "$STUBLOG" 2>/dev/null || true); printf '%s' "${n:-0}"; }
count_match() { local n; n=$(grep "^$1 " "$STUBLOG" 2>/dev/null | grep -c -- "$2" || true); printf '%s' "${n:-0}"; }

# ══════════════════════════════════════════════════════════════════════════════
# TEST 1: a non-concrete target is refused before any machine is contacted
# ══════════════════════════════════════════════════════════════════════════════

test_refuses_vague_version() {
    make_stubs
    local out rc=0
    out=$(bash "$FLEET" --host deck --version 2.1 --binary "$(stub_binary 2.1.280)" 2>&1) || rc=$?
    echo "    measured rc=$rc ssh_calls=$(count_calls ssh) out=$(printf '%s' "$out" | tail -1 | cut -c1-70)"
    [[ "$rc" -ne 0 ]] || { echo "    must refuse a non-concrete version" >&2; return 1; }
    assert_eq "0" "$(count_calls ssh)" "no machine may be contacted before the target is concrete"
}
run_test "refuses a non-concrete --version before contacting anything" test_refuses_vague_version

# ══════════════════════════════════════════════════════════════════════════════
# TEST 2: the source binary is verified LOCALLY before any host is touched
# ══════════════════════════════════════════════════════════════════════════════
# Shipping an unverified 236 MB binary to four machines and finding out afterwards
# is how you brick a fleet from bed.

test_verifies_source_before_any_host() {
    make_stubs
    export STUB_PROBE_deck=$'arch=x86_64\nlayout=native\nversion=2.1.113\nlive=0'
    local out rc=0
    out=$(bash "$FLEET" --host deck --version 2.1.280 --binary "$(stub_binary 2.1.99)" 2>&1) || rc=$?
    echo "    measured rc=$rc ssh=$(count_calls ssh) scp=$(count_calls scp)"
    [[ "$rc" -ne 0 ]] || { echo "    must refuse a source reporting the wrong version" >&2; return 1; }
    assert_contains "$out" "2.1.99" "the error must print what the source actually reported" || return 1
    assert_eq "0" "$(count_calls scp)" "nothing may be shipped when the source fails verification"
}
run_test "verifies the source binary locally before touching any host" test_verifies_source_before_any_host

# ══════════════════════════════════════════════════════════════════════════════
# TEST 3: --dry-run contacts hosts to probe, but ships and runs nothing
# ══════════════════════════════════════════════════════════════════════════════

test_dry_run_ships_nothing() {
    make_stubs
    export STUB_PROBE_deck=$'arch=x86_64\nlayout=native\nversion=2.1.113\nlive=0'
    local out
    out=$(bash "$FLEET" --host deck --version 2.1.280 --binary "$(stub_binary 2.1.280)" --dry-run 2>&1 || true)
    echo "    measured scp=$(count_calls scp) plan=$(printf '%s' "$out" | grep -ci 'dry-run' || true)"
    assert_eq "0" "$(count_calls scp)" "--dry-run must ship nothing" || return 1
    assert_contains "$out" "2.1.113" "the plan must state each host's current version" || return 1
    assert_contains "$out" "2.1.280" "the plan must state the target"
}
run_test "--dry-run probes but ships and runs nothing" test_dry_run_ships_nothing

# ══════════════════════════════════════════════════════════════════════════════
# TEST 4: a host already at the target is skipped
# ══════════════════════════════════════════════════════════════════════════════

test_skips_up_to_date_host() {
    make_stubs
    export STUB_PROBE_vps=$'arch=x86_64\nlayout=npm\nversion=2.1.280\nlive=0'
    export STUB_VERIFY_vps="2.1.280 (Claude Code)"
    local out
    out=$(bash "$FLEET" --host vps --version 2.1.280 --binary "$(stub_binary 2.1.280)" 2>&1 || true)
    local binary_ships; binary_ships=$(count_match scp 'claude.new')
    local ran_wrapper;  ran_wrapper=$(count_match ssh 'cc-update.sh')
    echo "    measured: binary ships=$binary_ships, cc-update.sh runs=$ran_wrapper"
    assert_contains "$out" "up to date" "an already-current host must say so" || return 1
    assert_eq "0" "$binary_ships" "the 233 MB binary must NOT be shipped to an up-to-date host" || return 1
    # ...but the config IS still checked. deck2 sat at the target version with the fleet
    # update-checker absent from its launcher, so nothing would ever have reported that it
    # had begun drifting again. Version-equal is not the same as correctly configured.
    [[ "$ran_wrapper" -ge 1 ]] || { echo "    an up-to-date host must still have its config verified" >&2; return 1; }
    assert_eq "0" "$(count_match ssh '--via binary')" "config-only must not take the install road"
}
run_test "skips a host already at the target version" test_skips_up_to_date_host

# ══════════════════════════════════════════════════════════════════════════════
# TEST 5: a host with a live Claude Code session is refused without --force
# ══════════════════════════════════════════════════════════════════════════════
# MG uses the Decks in bed in the evening. Swapping the binary under a live session
# is the one failure mode that hits him rather than the fleet.

test_refuses_host_with_live_session() {
    make_stubs
    export STUB_PROBE_deck=$'arch=x86_64\nlayout=native\nversion=2.1.113\nlive=1'
    local out rc=0
    out=$(bash "$FLEET" --host deck --version 2.1.280 --binary "$(stub_binary 2.1.280)" 2>&1) || rc=$?
    echo "    measured rc=$rc scp=$(count_calls scp)"
    assert_contains "$out" "live" "the refusal must name the live session" || return 1
    assert_eq "0" "$(count_calls scp)" "no swap under a live session" || return 1
    [[ "$rc" -ne 0 ]] || { echo "    a refused host must make the run non-zero" >&2; return 1; }

    # --force overrides, deliberately
    make_stubs
    export STUB_PROBE_deck=$'arch=x86_64\nlayout=native\nversion=2.1.113\nlive=1'
    export STUB_VERIFY_deck="2.1.280 (Claude Code)"
    bash "$FLEET" --host deck --version 2.1.280 --binary "$(stub_binary 2.1.280)" --force >/dev/null 2>&1 || true
    echo "    measured with --force: scp=$(count_calls scp)"
    [[ "$(count_calls scp)" -gt 0 ]] || { echo "    --force must proceed" >&2; return 1; }
}
run_test "refuses a host with a live session unless --force" test_refuses_host_with_live_session

# ══════════════════════════════════════════════════════════════════════════════
# TEST 6: the road is chosen per host — binary for native, npm for npm
# ══════════════════════════════════════════════════════════════════════════════

test_picks_road_per_layout() {
    make_stubs
    export STUB_PROBE_deck=$'arch=x86_64\nlayout=native\nversion=2.1.113\nlive=0'
    export STUB_VERIFY_deck="2.1.280 (Claude Code)"
    bash "$FLEET" --host deck --version 2.1.280 --binary "$(stub_binary 2.1.280)" >/dev/null 2>&1 || true
    local native_cmds; native_cmds=$(count_match ssh '--via binary')
    local shipped;     shipped=$(count_calls scp)
    echo "    measured native host: '--via binary' in $native_cmds ssh call(s), $shipped scp call(s)"
    [[ "$native_cmds" -ge 1 ]] || { echo "    a native host must be updated via the binary road" >&2; return 1; }
    [[ "$shipped" -ge 2 ]] || { echo "    a native host needs both the binary and cc-update.sh shipped" >&2; return 1; }

    make_stubs
    export STUB_PROBE_vps=$'arch=x86_64\nlayout=npm\nversion=2.1.87\nlive=0'
    export STUB_VERIFY_vps="2.1.280 (Claude Code)"
    bash "$FLEET" --host vps --version 2.1.280 --binary "$(stub_binary 2.1.280)" >/dev/null 2>&1 || true
    local npm_binary; npm_binary=$(count_match ssh '--via binary')
    echo "    measured npm host: '--via binary' in $npm_binary ssh call(s)"
    assert_eq "0" "$npm_binary" "an npm-layout host must use the npm road, not the binary road"
}
run_test "picks the binary road for native hosts and npm for npm hosts" test_picks_road_per_layout

# ══════════════════════════════════════════════════════════════════════════════
# TEST 7: a non-x86_64 host is refused, not shipped an incompatible ELF
# ══════════════════════════════════════════════════════════════════════════════

test_refuses_foreign_arch() {
    make_stubs
    export STUB_PROBE_deck=$'arch=aarch64\nlayout=native\nversion=2.1.113\nlive=0'
    local out rc=0
    out=$(bash "$FLEET" --host deck --version 2.1.280 --binary "$(stub_binary 2.1.280)" 2>&1) || rc=$?
    echo "    measured rc=$rc scp=$(count_calls scp)"
    assert_contains "$out" "aarch64" "the refusal must name the arch it measured" || return 1
    assert_eq "0" "$(count_calls scp)" "an x86-64 ELF must never be shipped to a foreign arch"
}
run_test "refuses a host whose arch does not match the binary" test_refuses_foreign_arch

# ══════════════════════════════════════════════════════════════════════════════
# TEST 8: --all reads the host list from config, and says so when there is none
# ══════════════════════════════════════════════════════════════════════════════
# The list is config-driven rather than hardcoded because one fleet's SSH aliases are
# personal data: a built-in default would not survive the propagation leak gate.

test_all_reads_host_config() {
    make_stubs
    printf '# comment\nnuc vps\ndeck   # trailing comment\n' > "$TEST_TMPDIR/hosts.conf"
    export CC_FLEET_HOSTS_FILE="$TEST_TMPDIR/hosts.conf"
    export STUB_PROBE_nuc=$'arch=x86_64\nlayout=native\nversion=2.1.280\nlive=0'
    export STUB_PROBE_vps=$'arch=x86_64\nlayout=npm\nversion=2.1.280\nlive=0'
    export STUB_PROBE_deck=$'arch=x86_64\nlayout=native\nversion=2.1.280\nlive=0'
    local out
    out=$(bash "$FLEET" --all --version 2.1.280 --binary "$(stub_binary 2.1.280)" 2>&1 || true)
    echo "    measured hosts in summary: $(printf '%s' "$out" | grep -c 'up to date' || true)"
    assert_contains "$out" "nuc" "nuc must be read from the conf" || return 1
    assert_contains "$out" "deck" "a host with a trailing comment must still parse" || return 1

    make_stubs
    export CC_FLEET_HOSTS_FILE="$TEST_TMPDIR/absent.conf"
    local rc=0
    out=$(bash "$FLEET" --all --version 2.1.280 --binary "$(stub_binary 2.1.280)" 2>&1) || rc=$?
    echo "    measured with no conf: rc=$rc ssh=$(count_calls ssh)"
    [[ "$rc" -ne 0 ]] || { echo "    --all with no host list must refuse" >&2; return 1; }
    assert_contains "$out" "CC_FLEET_HOSTS" "the error must say how to supply a list" || return 1
    assert_eq "0" "$(count_calls ssh)" "nothing may be contacted when there is no list"
}
run_test "--all reads the host list from config (and refuses without one)" test_all_reads_host_config

# ══════════════════════════════════════════════════════════════════════════════
# TEST 9: it RUNS inside a Claude Code session — that is the whole point
# ══════════════════════════════════════════════════════════════════════════════
# cc-update.sh refuses when CLAUDE_CONFIG_DIR is set, correctly: it rewrites the install
# under the running session. This script rewrites OTHER machines. Inheriting that guard
# would make "update the fleet from here" impossible, which is the task it exists for.
# A machine running a session is protected by the per-host live= probe instead.

test_runs_inside_a_session() {
    make_stubs
    export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/fake-config"
    export STUB_PROBE_deck=$'arch=x86_64\nlayout=native\nversion=2.1.113\nlive=0'
    local out
    out=$(bash "$FLEET" --host deck --version 2.1.280 --binary "$(stub_binary 2.1.280)" --dry-run 2>&1 || true)
    unset CLAUDE_CONFIG_DIR
    echo "    measured with CLAUDE_CONFIG_DIR set: ssh=$(count_calls ssh) out=$(printf '%s' "$out" | head -1 | cut -c1-70)"
    assert_not_contains "$out" "Exit CC first" "must not inherit cc-update.sh's in-session refusal" || return 1
    [[ "$(count_calls ssh)" -gt 0 ]] || { echo "    it must still reach the host" >&2; return 1; }
    assert_contains "$out" "2.1.113" "the probe must have run"
}
run_test "runs inside a Claude Code session (updates OTHER machines)" test_runs_inside_a_session

# ══════════════════════════════════════════════════════════════════════════════
# TEST 10: the npm SHIM is refused, and named as the shim
# ══════════════════════════════════════════════════════════════════════════════
# MEASURED 2026-09-23: `npm pack @anthropic-ai/claude-code@2.1.280` yields a
# package/bin/claude.exe of 500 bytes, ASCII, that prints "claude native binary not
# installed". The real ~233 MB ELF comes from the platform optional dependency that
# postinstall downloads. Shipping the shim to three machines would brick all three,
# and the failure would read as "the update ran and CC is broken".

test_refuses_the_npm_shim() {
    make_stubs
    cat > "$TEST_TMPDIR/shim" << 'SHIMEOF'
#!/bin/sh
echo "Error: claude native binary not installed." >&2
exit 1
SHIMEOF
    chmod +x "$TEST_TMPDIR/shim"
    export STUB_PROBE_deck=$'arch=x86_64\nlayout=native\nversion=2.1.113\nlive=0'
    local out rc=0
    out=$(bash "$FLEET" --host deck --version 2.1.280 --binary "$TEST_TMPDIR/shim" 2>&1) || rc=$?
    echo "    measured rc=$rc scp=$(count_calls scp) hint=$(printf '%s' "$out" | grep -ci 'postinstall' || true)"
    [[ "$rc" -ne 0 ]] || { echo "    the shim must be refused" >&2; return 1; }
    assert_eq "0" "$(count_calls scp)" "a shim must never be shipped" || return 1
    assert_contains "$out" "SHIM" "the error must name it as the shim, not just a version mismatch" || return 1
    assert_contains "$out" "postinstall" "the error must name the cause"
}
run_test "refuses the npm shim and names it as the shim" test_refuses_the_npm_shim

# ══════════════════════════════════════════════════════════════════════════════

suite_summary
