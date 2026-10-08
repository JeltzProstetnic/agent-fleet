#!/usr/bin/env bash
# Tests for tmux-launch.sh — session launch, death detection, exit code logging
source "$(dirname "$0")/test-helpers.sh"

TMUX_LAUNCH="$REPO_ROOT/setup/scripts/tmux-launch.sh"

# Mock gpi globally to prevent test pollution of ~/.claude/.gpi-state.json
MOCK_BIN="$(mktemp -d)"
cat > "$MOCK_BIN/gpi" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
chmod +x "$MOCK_BIN/gpi"
export PATH="$MOCK_BIN:$PATH"

# CFG-741: a pass-through systemd-run shim so every test is deterministic regardless of
# whether this box has a user systemd. It records its argv, then runs what follows `--`.
cat > "$MOCK_BIN/systemd-run" << 'MOCKEOF'
#!/usr/bin/env bash
echo "systemd-run $*" >> "$(dirname "$0")/calls.log"   # next to itself: the pane does not inherit our env
while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
shift
exec "$@"
MOCKEOF
chmod +x "$MOCK_BIN/systemd-run"
export TMUX_LAUNCH_SYSTEMD_RUN="$MOCK_BIN/systemd-run"

# Helper: kill tmux session if it exists (cleanup)
kill_session() {
    tmux kill-session -t "$1" 2>/dev/null || true
}

suite_header "tmux-launch.sh Tests"

# ── Argument Validation ─────────────────────────────────────────────────────

test_missing_args() {
    local output
    output=$(bash "$TMUX_LAUNCH" 2>&1) || true
    assert_contains "$output" "Usage"
}
run_test "missing args prints usage" test_missing_args

test_two_args_fails() {
    local output
    output=$(bash "$TMUX_LAUNCH" sess label 2>&1) || true
    assert_contains "$output" "Usage"
}
run_test "two args prints usage" test_two_args_fails

# CFG-742: tmux forbids '.' and ':' in session names; the job then "died immediately"
test_dot_in_name_rejected() {
    local out rc=0
    out=$(bash "$TMUX_LAUNCH" "tl-dot-0.4" "dot" "sleep 1" 2>&1) || rc=$?
    assert_eq "2" "$rc" "dot in name must exit 2" || return 1
    assert_contains "$out" "may not contain" "message names the problem" || return 1
    if tmux has-session -t="tl-dot-0.4" 2>/dev/null; then echo "session was created"; return 1; fi
}
run_test "session name with a dot is rejected before launch" test_dot_in_name_rejected

test_colon_in_name_rejected() {
    local out rc=0
    out=$(bash "$TMUX_LAUNCH" "tl:colon" "colon" "sleep 1" 2>&1) || rc=$?
    assert_eq "2" "$rc" "colon in name must exit 2" || return 1
    assert_contains "$out" "may not contain" "message names the problem" || return 1
}
run_test "session name with a colon is rejected before launch" test_colon_in_name_rejected

# ── Log Pre-Creation ────────────────────────────────────────────────────────

test_log_precreated() {
    local session="tl-precreate-$$"
    local logfile="$TEST_TMPDIR/pre.log"
    bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" "sleep 5" 2>/dev/null
    # Log should exist immediately (created before tmux, not by tmux)
    assert_file_exists "$logfile" "log should be pre-created before tmux starts" || return 1
    assert_file_contains "$logfile" "Session:" "log header should contain session name" || return 1
    # The command itself lives in the .meta sidecar (CFG-659), not here — the
    # header must only POINT at it, so no command text can collide with a
    # sentinel the job later writes into this same log.
    assert_file_contains "$logfile" "Command logged to:" "log header should point at the meta sidecar" || return 1
    kill_session "$session"
}
run_test "log file pre-created with header" test_log_precreated

test_log_dir_created() {
    local session="tl-logdir-$$"
    local logfile="$TEST_TMPDIR/deep/nested/dir/test.log"
    bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" "sleep 5" 2>/dev/null
    assert_file_exists "$logfile" "log dir should be created automatically" || return 1
    kill_session "$session"
}
run_test "missing log directory created automatically" test_log_dir_created

# CFG-659: the header used to echo the command verbatim into the same log the
# command writes its completion sentinel to, so `grep -c 'RSYNC DONE'` matched
# the line ANNOUNCING the sentinel and returned 1 from the first second — a
# completion check that reports success while the job is still running.
# Measured on a life-session Audio mirror: grep said done at 516 of 1162 files.
test_sentinel_not_in_header() {
    local session="tl-sentinel-$$"
    local logfile="$TEST_TMPDIR/sentinel.log"
    bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" \
        "sleep 5; echo 'RSYNC DONE' >> $logfile" 2>/dev/null
    # At launch the job has not finished, so the sentinel must not be present.
    local n
    # `grep -c` already prints 0 on no-match and THEN exits 1 — a `|| echo 0`
    # here appends a second zero and the assert compares against "0\n0".
    n=$(grep -c 'RSYNC DONE' "$logfile" 2>/dev/null || true)
    kill_session "$session"
    assert_eq "0" "$n" "log must not contain the sentinel before the job emits it"
}
run_test "completion sentinel in the command does not appear in the log header" test_sentinel_not_in_header

test_command_recorded_in_meta() {
    local session="tl-meta-$$"
    local logfile="$TEST_TMPDIR/meta.log"
    bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" "sleep 5" 2>/dev/null
    assert_file_exists "$logfile.meta" "command should be recorded in a .meta sidecar" || return 1
    assert_file_contains "$logfile.meta" "sleep 5" "meta should carry the command" || return 1
    kill_session "$session"
}
run_test "launch command is recorded in a .meta sidecar, not the log" test_command_recorded_in_meta

# ── Session Verification ────────────────────────────────────────────────────

test_session_exists_after_launch() {
    local session="tl-verify-$$"
    local logfile="$TEST_TMPDIR/verify.log"
    bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" "sleep 30" 2>/dev/null
    # Session should be alive
    tmux has-session -t "$session" 2>/dev/null
    local rc=$?
    assert_eq "0" "$rc" "tmux session should exist after launch" || return 1
    kill_session "$session"
}
run_test "session exists after successful launch" test_session_exists_after_launch

# ── Immediate Death Detection ───────────────────────────────────────────────

test_immediate_death_detected() {
    local session="tl-die-$$"
    local logfile="$TEST_TMPDIR/die.log"
    # Command that exits immediately with error
    local output
    output=$(bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" "exit 1" 2>&1) || true
    # Should report error on stderr
    assert_contains "$output" "ERROR" "should report session death" || return 1
    assert_contains "$output" "died immediately" "should say session died" || return 1
}
run_test "immediate session death is detected and reported" test_immediate_death_detected

test_immediate_death_exit_code() {
    local session="tl-die-rc-$$"
    local logfile="$TEST_TMPDIR/die-rc.log"
    # Command that exits immediately
    bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" "exit 1" 2>/dev/null
    local rc=$?
    assert_neq "0" "$rc" "should exit non-zero when session dies immediately" || return 1
}
run_test "immediate death returns non-zero exit code" test_immediate_death_exit_code

test_immediate_death_logged() {
    local session="tl-die-log-$$"
    local logfile="$TEST_TMPDIR/die-log.log"
    bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" "exit 1" 2>/dev/null || true
    assert_file_contains "$logfile" "ERROR" "log should record the session death" || return 1
}
run_test "immediate death recorded in log file" test_immediate_death_logged

# ── Exit Code Capture ───────────────────────────────────────────────────────

test_exit_code_logged_success() {
    local session="tl-rc0-$$"
    local logfile="$TEST_TMPDIR/rc0.log"
    bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" "echo done" 2>/dev/null
    # Wait for command to finish (it's fast)
    sleep 2
    assert_file_contains "$logfile" "EXIT_CODE: 0" "successful command should log exit code 0" || return 1
}
run_test "exit code 0 logged for successful command" test_exit_code_logged_success

test_exit_code_logged_failure() {
    local session="tl-rc42-$$"
    local logfile="$TEST_TMPDIR/rc42.log"
    # Use a command that takes a moment so the session doesn't die instantly
    bash "$TMUX_LAUNCH" "$session" "test" --log "$logfile" "sleep 0.5; exit 42" 2>/dev/null || true
    # Wait for command to finish
    sleep 3
    assert_file_contains "$logfile" "EXIT_CODE: 42" "failed command should log exit code 42" || return 1
}
run_test "non-zero exit code logged for failed command" test_exit_code_logged_failure

# ── Duplicate Session Handling ──────────────────────────────────────────────

test_duplicate_session_replaced() {
    local session="tl-dup-$$"
    local logfile1="$TEST_TMPDIR/dup1.log"
    local logfile2="$TEST_TMPDIR/dup2.log"
    # Start first session
    bash "$TMUX_LAUNCH" "$session" "first" --log "$logfile1" "sleep 30" 2>/dev/null
    tmux has-session -t "$session" 2>/dev/null
    assert_eq "0" "$?" "first session should exist" || return 1
    # Start second session with same name
    bash "$TMUX_LAUNCH" "$session" "second" --log "$logfile2" "sleep 30" 2>/dev/null
    tmux has-session -t "$session" 2>/dev/null
    assert_eq "0" "$?" "replacement session should exist" || return 1
    # Second log should exist and have header
    assert_file_exists "$logfile2" || return 1
    assert_file_contains "$logfile2" "Session:" "replacement log should have header" || return 1
    kill_session "$session"
}
run_test "duplicate session name replaces old session" test_duplicate_session_replaced

# ── No --log Mode ───────────────────────────────────────────────────────────

test_no_log_still_verifies() {
    local session="tl-nolog-$$"
    # Launch without --log
    local output
    output=$(bash "$TMUX_LAUNCH" "$session" "test" "sleep 30" 2>&1)
    assert_contains "$output" "launched" "should report successful launch" || return 1
    tmux has-session -t "$session" 2>/dev/null
    assert_eq "0" "$?" "session should exist without --log" || return 1
    kill_session "$session"
}
run_test "launch without --log still verifies session" test_no_log_still_verifies

test_no_log_death_detected() {
    local session="tl-nolog-die-$$"
    local output
    output=$(bash "$TMUX_LAUNCH" "$session" "test" "exit 1" 2>&1) || true
    assert_contains "$output" "ERROR" "should detect death even without --log" || return 1
}
run_test "immediate death detected without --log" test_no_log_death_detected

# ── GPI Registration ────────────────────────────────────────────────────────

test_gpi_called() {
    local session="tl-gpi-$$"
    local logfile="$TEST_TMPDIR/gpi.log"
    # Create a mock gpi that logs calls
    local mock_dir="$TEST_TMPDIR/mockbin"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/gpi" << 'MOCKEOF'
#!/usr/bin/env bash
echo "gpi $*" >> "${GPI_CALL_LOG:-/tmp/gpi-calls.log}"
MOCKEOF
    chmod +x "$mock_dir/gpi"
    local call_log="$TEST_TMPDIR/gpi-calls.log"
    GPI_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" \
        bash "$TMUX_LAUNCH" "$session" "testing gpi" --log "$logfile" "sleep 5" 2>/dev/null
    assert_file_exists "$call_log" "gpi should have been called" || return 1
    assert_file_contains "$call_log" "start" "gpi start should be called" || return 1
    assert_file_contains "$call_log" "$session" "gpi called with session name" || return 1
    kill_session "$session"
}
run_test "GPI registration called on launch" test_gpi_called

# ── Session-name prefix matching (CFG-616 family) ───────────────────────────
# tmux resolves `-t name` by exact match, then PREFIX match. Measured on WSL
# 2026-09-17: with a live session `zztest2`, `tmux kill-session -t zztest`
# returns 0 and kills `zztest2`, while `-t=zztest` correctly fails. So a launch
# whose session name is a PREFIX of a running job's name silently killed that
# running job, and the death check could pass on a stranger's session.

test_prefix_sibling_survives_and_death_still_detected() {
    local sib="zzpfxsib2" own="zzpfxsib"
    tmux kill-session -t="$sib" 2>/dev/null || true
    tmux kill-session -t="$own" 2>/dev/null || true
    tmux new-session -d -s "$sib" "sleep 30"
    sleep 0.5

    local out rc=0
    out=$(bash "$TMUX_LAUNCH" "$own" "prefix probe" "exit 1" 2>&1) || rc=$?

    local sib_alive=1
    tmux has-session -t="$sib" 2>/dev/null || sib_alive=0

    tmux kill-session -t="$own" 2>/dev/null || true
    tmux kill-session -t="$sib" 2>/dev/null || true

    # The launcher must not touch a session that merely shares its prefix.
    assert_eq "1" "$sib_alive" "prefix-sharing sibling session must survive the launch" || return 1
    # And with the sibling still alive, an immediately dead session must still be caught.
    assert_neq "0" "$rc" "immediate death must be detected even with a prefix-sharing sibling alive" || return 1
    assert_contains "$out" "died immediately" "death message must still be reported" || return 1
}
run_test "prefix-named sibling is neither killed nor mistaken for our session" test_prefix_sibling_survives_and_death_still_detected

# ── Detached server (CFG-616) ───────────────────────────────────────────────
# With no tmux server running, `tmux new-session -d` spawns the server from the
# caller's process tree — a Claude Code bash call — and the first background job
# of a session died with it (measured on WSL 2026-09-15: empty log, `no
# server running`). The launcher must start tmux through `setsid`, so the server
# is born outside the caller's session. These tests use a PRIVATE socket dir so
# "no server running" is deterministic and no shared server is touched.

_private_tmux() {
    unset TMUX
    export TMUX_TMPDIR="$TEST_TMPDIR/tmuxsock"
    mkdir -p "$TMUX_TMPDIR"
}

_private_tmux_cleanup() {
    # TMUX_TMPDIR is the private dir here, so this can only reach our own server.
    [[ "${TMUX_TMPDIR:-}" == "$TEST_TMPDIR/tmuxsock" ]] && tmux kill-server 2>/dev/null || true
    unset TMUX_TMPDIR
}

_mock_setsid() {
    local dir="$TEST_TMPDIR/setsidbin"
    mkdir -p "$dir"
    cat > "$dir/setsid" << 'MOCKEOF'
#!/usr/bin/env bash
echo "setsid $*" >> "$SETSID_CALL_LOG"
while [[ "${1:-}" == -* ]]; do shift; done
exec "$@"
MOCKEOF
    chmod +x "$dir/setsid"
    echo "$dir"
}

test_server_started_via_setsid() {
    _private_tmux
    local mock_dir call_log="$TEST_TMPDIR/setsid-calls.log"
    mock_dir=$(_mock_setsid)
    : > "$call_log"
    tmux list-sessions >/dev/null 2>&1 && { echo "precondition: private server already running" >&2; _private_tmux_cleanup; return 1; }

    local rc=0
    SETSID_CALL_LOG="$call_log" PATH="$mock_dir:$PATH" \
        bash "$TMUX_LAUNCH" "tl-setsid-$$" "setsid probe" "sleep 30" >/dev/null 2>&1 || rc=$?
    local alive=1
    tmux has-session -t="tl-setsid-$$" 2>/dev/null || alive=0
    _private_tmux_cleanup

    assert_eq "0" "$rc" "launch should succeed" || return 1
    assert_eq "1" "$alive" "session should be alive on the private server" || return 1
    assert_file_contains "$call_log" "tmux" "tmux must be started through setsid when no server is running" || return 1
}
run_test "no running server: tmux is started through setsid (CFG-616)" test_server_started_via_setsid

test_server_is_own_session_leader() {
    _private_tmux
    local rc=0
    bash "$TMUX_LAUNCH" "tl-sid-$$" "sid probe" "sleep 30" >/dev/null 2>&1 || rc=$?
    local spid sid mysid
    spid=$(tmux display-message -p -t="tl-sid-$$" '#{pid}' 2>/dev/null || true)
    sid=$(ps -o sid= -p "${spid:-0}" 2>/dev/null | tr -d ' ')
    mysid=$(ps -o sid= -p $$ 2>/dev/null | tr -d ' ')
    _private_tmux_cleanup

    assert_eq "0" "$rc" "launch should succeed" || return 1
    [[ -n "$spid" ]] || { echo "    no server pid" >&2; return 1; }
    assert_neq "$mysid" "$sid" "tmux server must not share the caller's session" || return 1
}
# NOTE: a regression guard, not proof of the CFG-616 fix — tmux daemonizes its server
# itself, so on Linux this also holds without setsid (measured: ppid 1, own session).
run_test "spawned tmux server does not share the caller's session" test_server_is_own_session_leader

# ── GPI reporting honesty (CFG-616 / CFG-598) ───────────────────────────────
# `gpi start … 2>/dev/null || true` swallowed every registration error and the
# final line said "GPI registered" unconditionally, so a failed registration
# reported success and the statusline silently lacked the job.

_mock_failing_gpi() {
    local dir="$TEST_TMPDIR/failgpi"
    mkdir -p "$dir"
    cat > "$dir/gpi" << 'MOCKEOF'
#!/usr/bin/env bash
echo "gpi: jq: command not found" >&2
exit 1
MOCKEOF
    chmod +x "$dir/gpi"
    echo "$dir"
}

test_gpi_failure_not_reported_as_success() {
    _private_tmux
    local mock_dir out rc=0
    mock_dir=$(_mock_failing_gpi)
    out=$(PATH="$mock_dir:$PATH" bash "$TMUX_LAUNCH" "tl-gpifail-$$" "gpi fail" "sleep 30" 2>&1) || rc=$?
    local alive=1
    tmux has-session -t="tl-gpifail-$$" 2>/dev/null || alive=0
    _private_tmux_cleanup

    # A registration failure must not cost the job: the launch still succeeds...
    assert_eq "0" "$rc" "a gpi failure must not fail the launch" || return 1
    assert_eq "1" "$alive" "the job must still be running" || return 1
    # ...but it must be reported, not dressed up as success.
    assert_not_contains "$out" "GPI registered" "a failed registration must not print 'GPI registered'" || return 1
    assert_contains "$out" "GPI registration FAILED" "the failure must be reported" || return 1
    assert_contains "$out" "jq: command not found" "gpi's own error must be surfaced, not swallowed" || return 1
}
run_test "failed GPI registration is reported, not claimed as success" test_gpi_failure_not_reported_as_success

test_gpi_success_still_reported() {
    _private_tmux
    local out rc=0
    out=$(bash "$TMUX_LAUNCH" "tl-gpiok-$$" "gpi ok" "sleep 30" 2>&1) || rc=$?
    _private_tmux_cleanup
    assert_eq "0" "$rc" "launch should succeed" || return 1
    assert_contains "$out" "GPI registered" "a successful registration is still reported" || return 1
}
run_test "successful GPI registration is still reported" test_gpi_success_still_reported

# ── Memory cap (CFG-741) ────────────────────────────────────────────────────
# 2026-10-07: an uncapped fan-out filled 48 GB RAM + 16 GB swap, the kernel never
# OOM-killed, WSL froze ~40 min. Each job now runs in its own cgroup with MemoryMax.

_meminfo() {   # <total_kB> <avail_kB> — writes a fake /proc/meminfo, prints its path
    local f="$TEST_TMPDIR/meminfo-$1-$2"
    printf 'MemTotal:       %s kB\nMemFree:        1 kB\nMemAvailable:   %s kB\n' "$1" "$2" > "$f"
    echo "$f"
}

_shim() {   # <name> — private copy of the pass-through shim; prints its path (calls.log beside it)
    local d="$TEST_TMPDIR/sd-$1"; mkdir -p "$d"; cp "$MOCK_BIN/systemd-run" "$d/"; : > "$d/calls.log"; echo "$d/systemd-run"
}

_wait_exit_code() {   # <log> — wait up to 10 s for the job's EXIT_CODE line
    local i; for i in $(seq 1 50); do grep -q 'EXIT_CODE:' "$1" 2>/dev/null && return 0; sleep 0.2; done; return 1
}

test_mem_default_from_available() {
    # 48 GiB total, 20 GiB available -> available - 4 GiB = 16 GiB = 16384M
    local session="tl-mem-def-$$" log="$TEST_TMPDIR/mem-def.log" sd; sd=$(_shim def); local calls="$(dirname "$sd")/calls.log"
    TMUX_LAUNCH_SYSTEMD_RUN="$sd" TMUX_LAUNCH_MEMINFO="$(_meminfo 50331648 20971520)" \
        bash "$TMUX_LAUNCH" "$session" "mem" --log "$log" "echo job-ran" >/dev/null 2>&1
    _wait_exit_code "$log"; kill_session "$session"
    echo "    measured: $(grep -v -- '-- true' "$calls" | head -1)"
    assert_file_contains "$calls" "MemoryMax=16384M" "default cap = available - 4 GiB" || return 1
    assert_file_contains "$calls" "MemorySwapMax=0" "the job may not escape into swap" || return 1
    assert_file_contains "$log" "job-ran" "the job still runs and logs through the cap" || return 1
    assert_file_contains "$log" "EXIT_CODE: 0" "exit code still captured" || return 1
}
run_test "default memory cap is sized from available memory" test_mem_default_from_available

test_mem_default_ceiling() {
    # 48 GiB total, 46 GiB available -> min(42 GiB, 75% of 48 = 36 GiB) = 36864M
    local session="tl-mem-ceil-$$" log="$TEST_TMPDIR/mem-ceil.log" sd; sd=$(_shim ceil); local calls="$(dirname "$sd")/calls.log"
    TMUX_LAUNCH_SYSTEMD_RUN="$sd" TMUX_LAUNCH_MEMINFO="$(_meminfo 50331648 48234496)" \
        bash "$TMUX_LAUNCH" "$session" "mem" --log "$log" "true" >/dev/null 2>&1
    _wait_exit_code "$log"; kill_session "$session"
    assert_file_contains "$calls" "MemoryMax=36864M" "default cap never exceeds 75% of total" || return 1
}
run_test "default memory cap is at most 75% of total" test_mem_default_ceiling

test_mem_explicit_override() {
    local session="tl-mem-x-$$" log="$TEST_TMPDIR/mem-x.log" sd; sd=$(_shim x); local calls="$(dirname "$sd")/calls.log"
    TMUX_LAUNCH_SYSTEMD_RUN="$sd" bash "$TMUX_LAUNCH" "$session" "mem" --mem 2G --log "$log" "true" >/dev/null 2>&1
    _wait_exit_code "$log"; kill_session "$session"
    assert_file_contains "$calls" "MemoryMax=2G" "--mem sets the cap verbatim" || return 1
}
run_test "--mem overrides the default cap" test_mem_explicit_override

test_mem_none_runs_uncapped() {
    local session="tl-mem-none-$$" log="$TEST_TMPDIR/mem-none.log" sd; sd=$(_shim none); local calls="$(dirname "$sd")/calls.log" out
    out=$(TMUX_LAUNCH_SYSTEMD_RUN="$sd" bash "$TMUX_LAUNCH" "$session" "mem" --log "$log" --mem none "echo free" 2>&1)
    _wait_exit_code "$log"; kill_session "$session"
    assert_eq "" "$(cat "$calls")" "--mem none never calls systemd-run" || return 1
    assert_not_contains "$out" "uncapped" "an explicit opt-out is not warned about" || return 1
    assert_file_contains "$log" "free" "job runs" || return 1
}
run_test "--mem none runs the job uncapped, silently" test_mem_none_runs_uncapped

test_mem_unavailable_falls_back_with_warning() {
    local session="tl-mem-nosd-$$" log="$TEST_TMPDIR/mem-nosd.log" out rc=0 bad="$TEST_TMPDIR/badsd"
    mkdir -p "$bad"; printf '#!/usr/bin/env bash\necho "Failed to connect to bus" >&2\nexit 1\n' > "$bad/systemd-run"; chmod +x "$bad/systemd-run"
    out=$(TMUX_LAUNCH_SYSTEMD_RUN="$bad/systemd-run" bash "$TMUX_LAUNCH" "$session" "mem" --log "$log" "echo still-ran; sleep 3" 2>&1) || rc=$?
    _wait_exit_code "$log"; kill_session "$session"
    assert_eq "0" "$rc" "no user systemd must not fail the launch" || return 1
    assert_contains "$out" "uncapped" "the fallback is warned about" || return 1
    assert_file_contains "$log" "still-ran" "the job runs anyway" || return 1
}
run_test "no working user systemd: job runs uncapped with a warning" test_mem_unavailable_falls_back_with_warning

test_mem_controller_not_delegated_warns() {
    # systemd-run --user can succeed while the user manager has no memory controller,
    # and then MemoryMax is silently not enforced. That must read as uncapped, not capped.
    local session="tl-mem-nodel-$$" log="$TEST_TMPDIR/mem-nodel.log" out sd ctl="$TEST_TMPDIR/controllers-nodel"
    sd=$(_shim nodel); echo "cpu io pids" > "$ctl"
    out=$(TMUX_LAUNCH_SYSTEMD_RUN="$sd" TMUX_LAUNCH_CGROUP_CONTROLLERS="$ctl" \
          bash "$TMUX_LAUNCH" "$session" "mem" --mem 1G --log "$log" "sleep 3" 2>&1) || true
    kill_session "$session"
    assert_contains "$out" "uncapped" "an undelegated memory controller is reported" || return 1
    assert_file_contains "${log}.meta" "memory_cap: none" "meta does not claim a cap" || return 1
}
run_test "memory controller not delegated: reported as uncapped" test_mem_controller_not_delegated_warns

test_mem_invalid_value_rejected() {
    local rc=0 out
    out=$(bash "$TMUX_LAUNCH" "tl-mem-bad-$$" "mem" --mem lots "true" 2>&1) || rc=$?
    assert_eq "2" "$rc" "an unparseable --mem exits 2" || return 1
    assert_contains "$out" "--mem" "message names the flag" || return 1
}
run_test "invalid --mem value is rejected" test_mem_invalid_value_rejected

test_mem_quoting_survives() {
    # The job command is re-quoted into systemd-run's argv; quotes and $ must survive.
    local session="tl-mem-q-$$" log="$TEST_TMPDIR/mem-q.log"
    bash "$TMUX_LAUNCH" "$session" "mem" --mem 1G --log "$log" "x='a b'; echo \"<\$x>\" 'c\$d'" >/dev/null 2>&1
    _wait_exit_code "$log"; kill_session "$session"
    assert_file_contains "$log" "<a b> c\\\$d" "quoting and variables survive the wrapper" || return 1
}
run_test "job command quoting survives the cgroup wrapper" test_mem_quoting_survives

test_mem_real_cgroup_kills_runaway() {
    # Product test on a box with a working user systemd: a job that outgrows its cap dies,
    # the launcher survives. Skipped where systemd-run --user does not work.
    local real; real=$(command -v -p systemd-run 2>/dev/null || true)
    [[ -z "$real" ]] && real=$(PATH=/usr/bin:/bin command -v systemd-run 2>/dev/null || true)
    if [[ -z "$real" ]] || ! timeout 10 "$real" --user --scope -q -p MemoryMax=64M -- true 2>/dev/null; then
        skip_test "real cgroup cap" "systemd-run --user not usable here"; return 0
    fi
    local session="tl-mem-real-$$" log="$TEST_TMPDIR/mem-real.log"
    TMUX_LAUNCH_SYSTEMD_RUN="$real" bash "$TMUX_LAUNCH" "$session" "mem" --mem 64M --log "$log" \
        "python3 -c 'b=[bytearray(16*1024*1024) for _ in range(40)]; print(\"survived\")'" >/dev/null 2>&1
    _wait_exit_code "$log"; kill_session "$session"
    echo "    measured: $(grep -E 'EXIT_CODE|survived|Killed' "$log" | tr '\n' ' ')"
    assert_file_contains "$log" "EXIT_CODE:" "the job must have actually run to an exit (not vacuous)" || return 1
    assert_file_contains "${log}.meta" "memory_cap: 64M" "the applied cap is recorded in the .meta sidecar" || return 1
    assert_not_contains "$(cat "$log")" "survived" "a 640 MB allocation under a 64M cap must be killed" || return 1
    assert_not_contains "$(cat "$log")" "EXIT_CODE: 0" "the killed job reports a non-zero exit" || return 1
}
run_test "real user cgroup: a job over its cap is killed" test_mem_real_cgroup_kills_runaway

# ── Summary ─────────────────────────────────────────────────────────────────

suite_summary
