#!/usr/bin/env bash
# Tests for setup/tests/lib-afd-test-guard.sh — the machine-wide lock + free-port guard every test that
# starts a real AFD server goes through (CFG-1003 review). Each case sources the library in a subshell
# with a PRIVATE lock file and a private port range (ports the OS just handed out, far from the real
# guarded range 19870-19939), so a real AFD run on this machine can neither block nor be blocked by it.
# The servers are a tiny node stand-in; one case starts the real afd/server/index.js and skips where it
# cannot (template tree, no node_modules).
source "$(dirname "$0")/test-helpers.sh"

GUARD_LIB="$REPO_ROOT/setup/tests/lib-afd-test-guard.sh"

suite_header "lib-afd-test-guard.sh: AFD test lock, free guarded port, loopback test servers"

# _guard WAIT RANGE — this subshell's own copy of the guard: private lock file, wait, port range
_guard() {
    export RUN_AFD_LOCK="$TEST_TMPDIR/afd.lock" RUN_AFD_LOCK_WAIT="$1" RUN_AFD_PORTS="$2"
    # shellcheck source=/dev/null
    source "$GUARD_LIB"
}

# free_port — a loopback port nothing listens on right now (the OS picks it)
free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# hold_port SECONDS — a foreign listener (not under the lock) on a fresh port; sets HELD_PORT, HOLDER_PID
hold_port() {
    local f="$TEST_TMPDIR/held-port"
    python3 -c 'import os, socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[2] + ".t", "w").write(str(s.getsockname()[1])); os.replace(sys.argv[2] + ".t", sys.argv[2])
time.sleep(float(sys.argv[1]))' "$1" "$f" &
    HOLDER_PID=$!
    for _ in $(seq 1 100); do [[ -s "$f" ]] && break; sleep 0.05; done
    HELD_PORT=$(cat "$f")
}

# hold_lock FILE — another process holding the AFD test lock; sets LOCK_HOLDER_PID
hold_lock() {
    local ready="$TEST_TMPDIR/lock-held"
    python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(60)' \
        "$1" "$ready" &
    LOCK_HOLDER_PID=$!
    for _ in $(seq 1 100); do [[ -e "$ready" ]] && break; sleep 0.05; done
}

# lock_is_free FILE — no one holds FILE's flock right now
lock_is_free() {
    python3 -c 'import fcntl, sys
f = open(sys.argv[1], "a")
try: fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError: sys.exit(1)' "$1"
}

# fake_server — a stand-in AFD server: honours AFD_PORT and AFD_BIND_HOST like index.js, answers every
# request, and writes the bind host it was given to $FAKE_ENV_OUT
fake_server() {
    cat > "$TEST_TMPDIR/fake-afd.js" << 'EOF'
const http = require("http"), fs = require("fs");
const e = process.env;
if (e.FAKE_ENV_OUT) fs.writeFileSync(e.FAKE_ENV_OUT, "bind=" + (e.AFD_BIND_HOST || "") + " tg=" + (e.AFD_TELEGRAM_BOT_TOKEN || "unset") + " tgapi=" + (e.AFD_TELEGRAM_API || "unset") + "\n");
const s = http.createServer((q, r) => r.end("ok"));
if (process.env.AFD_BIND_HOST) s.listen(Number(process.env.AFD_PORT), process.env.AFD_BIND_HOST);
else s.listen(Number(process.env.AFD_PORT));
EOF
    echo "$TEST_TMPDIR/fake-afd.js"
}

# listen_addrs PORT — the local addresses of LISTEN sockets on PORT, from /proc/net/tcp{,6} (hex)
listen_addrs() {
    python3 -c 'import sys
port, out = int(sys.argv[1]), []
for f in ("/proc/net/tcp", "/proc/net/tcp6"):
    try: rows = open(f).read().splitlines()[1:]
    except OSError: continue
    for r in rows:
        c = r.split(); addr, hp = c[1].split(":")
        if c[3] == "0A" and int(hp, 16) == port: out.append(addr)
print(" ".join(sorted(out)))' "$1"
}

test_lock_taken_and_released() {
    (
        _guard 5 "1-1"
        AFD_GUARD_OWNER="probe-run" afd_guard_lock_take
        assert_eq "0" "$?" "a free lock is taken"
        assert_eq "held" "$(lock_is_free "$RUN_AFD_LOCK" && echo free || echo held)" "another process sees it held"
        assert_contains "$(cat "$RUN_AFD_LOCK")" "probe-run" "the lock file names its holder"
        afd_guard_lock_release
        assert_eq "free" "$(lock_is_free "$RUN_AFD_LOCK" && echo free || echo held)" "released, it is free again"
    )
}

test_lock_timeout_says_timeout() {
    (
        _guard 1 "1-1"
        hold_lock "$RUN_AFD_LOCK"
        local rc=0; afd_guard_lock_take >/dev/null || rc=$?
        kill "$LOCK_HOLDER_PID" 2>/dev/null; wait "$LOCK_HOLDER_PID" 2>/dev/null
        echo "    measured: rc $rc, why '$AFD_GUARD_WHY'"
        assert_eq "1" "$rc" "a lock held elsewhere past the wait is not taken"
        assert_contains "$AFD_GUARD_WHY" "was not free within 1s" "the cause is the timeout"
    )
}

test_flock_missing_says_so() {
    (
        _guard 1 "1-1"
        local nobin="$TEST_TMPDIR/no-flock-bin" rc=0
        mkdir -p "$nobin"
        PATH="$nobin" afd_guard_lock_take >/dev/null || rc=$?
        echo "    measured: rc $rc, why '$AFD_GUARD_WHY'"
        assert_eq "1" "$rc" "no flock → the lock is not taken"
        assert_contains "$AFD_GUARD_WHY" "flock is not installed" "the cause is the missing flock"
        assert_not_contains "$AFD_GUARD_WHY" "not free within" "it is not reported as a timeout"
    )
}

test_unopenable_lock_says_so() {
    (
        _guard 1 "1-1"
        RUN_AFD_LOCK="$TEST_TMPDIR/no-such-dir/afd.lock"; AFD_GUARD_LOCK="$RUN_AFD_LOCK"
        local rc=0; afd_guard_lock_take >/dev/null || rc=$?
        echo "    measured: rc $rc, why '$AFD_GUARD_WHY'"
        assert_eq "1" "$rc" "an unopenable lock file → the lock is not taken"
        assert_contains "$AFD_GUARD_WHY" "cannot be opened" "the cause is the lock file"
        assert_not_contains "$AFD_GUARD_WHY" "not free within" "it is not reported as a timeout"
    )
}

test_free_port_prefers_then_skips_busy() {
    (
        hold_port 30
        _guard 5 "$HELD_PORT-$((HELD_PORT + 5))"
        afd_guard_free_port "$((HELD_PORT + 3))"
        assert_eq "$((HELD_PORT + 3))" "$AFD_GUARD_PORT" "a free preferred port is used"
        afd_guard_free_port "$HELD_PORT"
        local got=$AFD_GUARD_PORT
        kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null
        echo "    measured: preferred $HELD_PORT is held, got $got"
        assert_neq "$HELD_PORT" "$got" "a preferred port something answers on is not used"
        local inrange=out; (( got > HELD_PORT && got <= HELD_PORT + 5 )) && inrange=in
        assert_eq "in" "$inrange" "the port it picks instead lies inside the guarded range"
    )
}

test_free_port_all_busy_fails() {
    (
        hold_port 30
        _guard 5 "$HELD_PORT-$HELD_PORT"
        local rc=0; afd_guard_free_port "$HELD_PORT" || rc=$?
        kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null
        assert_eq "1" "$rc" "every guarded port answers → no port"
        assert_contains "$AFD_GUARD_WHY" "already answers" "and says so"
    )
}

test_server_loopback_lock_held_not_inherited() {
    (
        local p; p=$(free_port)
        _guard 5 "$p-$((p + 3))"
        local js; js=$(fake_server)
        export AFD_TELEGRAM_BOT_TOKEN=live-bot-token   # a caller's exported credential must not reach it
        afd_test_server "$js" "$TEST_TMPDIR/server.log" "$p" FAKE_ENV_OUT="$TEST_TMPDIR/env" \
            || { echo "    start failed: $AFD_GUARD_WHY"; return 1; }
        local pid=$AFD_TEST_SERVER_PID port=$AFD_TEST_PORT fds held answer
        fds=$(ls -l "/proc/$pid/fd" 2>/dev/null | grep -c "$RUN_AFD_LOCK" || true)
        held=$(lock_is_free "$RUN_AFD_LOCK" && echo free || echo held)
        answer=$(curl -s -m 2 "http://127.0.0.1:$port/health")
        echo "    measured: port $port, $(cat "$TEST_TMPDIR/env"), lock $held, server lock fds $fds"
        assert_eq "ok" "$answer" "the server answers on AFD_TEST_PORT"
        assert_eq "bind=127.0.0.1 tg=unset tgapi=http://[::1]:9" "$(cat "$TEST_TMPDIR/env")" \
            "it was told to bind loopback only, got no Telegram token, and a dead Telegram API"
        assert_eq "held" "$held" "the lock is held while the server runs"
        assert_eq "0" "$fds" "the server does not hold the lock fd (a leaked server cannot hold the lock)"
        afd_test_server_stop
        assert_eq "gone" "$(kill -0 "$pid" 2>/dev/null && echo alive || echo gone)" "stop ends the server"
        assert_eq "free" "$(lock_is_free "$RUN_AFD_LOCK" && echo free || echo held)" "and gives the lock back"
    )
}

test_foreign_listener_on_preferred_port() {
    # The reported collision: test-lease-run.sh started its server on a fixed 19883 and died with
    # EADDRINUSE when something already listened there
    (
        hold_port 30
        _guard 5 "$HELD_PORT-$((HELD_PORT + 5))"
        local js rc=0; js=$(fake_server)
        afd_test_server "$js" "$TEST_TMPDIR/server.log" "$HELD_PORT" || rc=$?
        local port=$AFD_TEST_PORT answer; answer=$(curl -s -m 2 "http://127.0.0.1:$port/")
        afd_test_server_stop
        kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null
        echo "    measured: rc $rc, held $HELD_PORT, server on $port, log '$(cat "$TEST_TMPDIR/server.log")'"
        assert_eq "0" "$rc" "the server starts although its preferred port is taken"
        assert_neq "$HELD_PORT" "$port" "on another guarded port"
        assert_eq "ok" "$answer" "and it is our server that answers there"
        assert_not_contains "$(cat "$TEST_TMPDIR/server.log")" "EADDRINUSE" "no EADDRINUSE"
    )
}

test_overlapping_servers_take_turns() {
    # Two suites in overlapping runs, ONE guarded port: without the lock the second gets EADDRINUSE
    local p js; p=$(free_port); js=$(fake_server)
    _turn() {   # NAME — one suite: start, hold the port for 1 s, stop; logs its steps
        _guard 20 "$p-$p"
        afd_test_server "$js" "$TEST_TMPDIR/$1.log" "$p" || { echo "$1 FAILED $AFD_GUARD_WHY" >> "$TEST_TMPDIR/seq"; exit 1; }
        echo "$1 up" >> "$TEST_TMPDIR/seq"; sleep 1; echo "$1 down" >> "$TEST_TMPDIR/seq"
        afd_test_server_stop
    }
    local r1=0 r2=0 p1 p2 seq
    ( _turn a >/dev/null ) & p1=$!
    ( _turn b >/dev/null ) & p2=$!
    wait "$p1" || r1=$?
    wait "$p2" || r2=$?
    seq=$(awk '{print $2}' "$TEST_TMPDIR/seq" | tr '\n' ' ')
    echo "    measured: rc $r1 $r2, sequence: $(tr '\n' ',' < "$TEST_TMPDIR/seq")"
    assert_eq "0 0" "$r1 $r2" "both suites get the port"
    assert_eq "up down up down " "$seq" "one at a time: the second waits for the first to stop"
}

test_real_afd_server_is_loopback_only() {
    local js="$REPO_ROOT/afd/server/index.js"
    (
        local p; p=$(free_port)
        _guard 30 "$p-$((p + 3))"
        afd_test_server "$js" "$TEST_TMPDIR/server.log" "$p" AFD_TOKEN=guard-test AFD_DB_PATH="$TEST_TMPDIR/afd.db" \
            AFD_NOTIFY=false AFD_TELEGRAM_API="http://[::1]:9" \
            || { echo "    start failed: $AFD_GUARD_WHY"; return 1; }
        local addrs; addrs=$(listen_addrs "$AFD_TEST_PORT")
        afd_test_server_stop
        echo "    measured: LISTEN on port $AFD_TEST_PORT bound to [$addrs] (0100007F = 127.0.0.1)"
        assert_eq "0100007F" "$addrs" "the real AFD test server listens on 127.0.0.1 only, not on every interface"
    )
}

real_server_usable() {
    [[ -f "$REPO_ROOT/afd/server/index.js" && -r /proc/net/tcp ]] || return 1
    env -i PATH="$PATH" node -e 'new (require(process.argv[1]))(":memory:").close()' \
        "$REPO_ROOT/afd/server/node_modules/better-sqlite3" >/dev/null 2>&1
}

run_test "the lock is taken, names its holder, and is released" test_lock_taken_and_released
run_test "a lock held past the wait reports a timeout" test_lock_timeout_says_timeout
run_test "flock missing is reported as such, not as a timeout" test_flock_missing_says_so
run_test "an unopenable lock file is reported as such, not as a timeout" test_unopenable_lock_says_so
if command -v node >/dev/null 2>&1; then
    run_test "free port: the preferred one when free, another when it answers" test_free_port_prefers_then_skips_busy
    run_test "free port: every guarded port answering is a failure" test_free_port_all_busy_fails
    run_test "a test server: loopback bind, lock held while it runs, lock fd not inherited" test_server_loopback_lock_held_not_inherited
    run_test "a foreign listener on the preferred port: another port, no EADDRINUSE" test_foreign_listener_on_preferred_port
    run_test "overlapping test servers on one guarded port take turns" test_overlapping_servers_take_turns
    if real_server_usable; then
        run_test "the real AFD server started for a test listens on 127.0.0.1 only" test_real_afd_server_is_loopback_only
    else
        skip_test "real AFD test server is loopback-only" "no afd/server with a loadable better-sqlite3 here, or no /proc/net/tcp"
    fi
else
    skip_test "free port + test server cases" "node not on PATH — the port probe and the servers need it"
fi

suite_summary
