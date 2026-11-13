#!/usr/bin/env bash
# lib-afd-test-guard.sh — the one machine-wide guard for every test that starts a real AFD server on a
# loopback test port (CFG-1003). `lib-*`, so run.sh does not execute it. Sourced by:
#   run.sh — takes the lock around each afd/tests suite and checks the guarded ports are quiet;
#   the setup suites that start their own server (test-lease-run.sh, test-tmux-launch*.sh) — through
#   afd_test_server: the lock for the server's lifetime, a free guarded port, loopback-only binding.
# Why one lock for both: overlapping runs (several worktrees at once is the workflow harness's normal
# mode) share the suites' ports. A server already on 19879 answered another run's /health polls and
# greened a broken AFD server, and the setup suites started servers on 19883/19884 outside the lock —
# EADDRINUSE when two runs met.
# Knobs (run.sh documents the same ones): RUN_AFD_LOCK (default /tmp/afd-test-ports.lock),
# RUN_AFD_LOCK_WAIT (seconds, default 1800), RUN_AFD_PORTS (LO-HI, default 19870-19939).

AFD_GUARD_LOCK="${RUN_AFD_LOCK:-/tmp/afd-test-ports.lock}"
AFD_GUARD_LOCK_WAIT="${RUN_AFD_LOCK_WAIT:-1800}"
AFD_GUARD_PORTS="${RUN_AFD_PORTS:-19870-19939}"
AFD_GUARD_FD="" AFD_GUARD_WHY="" AFD_GUARD_PORT="" AFD_TEST_PORT="" AFD_TEST_SERVER_PID=""

# afd_guard_node ARGS... — node with the caller's PATH and nothing else: no NODE_OPTIONS, and no
# FORCE_COLOR (under FORCE_COLOR=1 + NO_COLOR=1 node warns on stderr)
afd_guard_node() {
    env -i PATH="$PATH" node "$@"
}

# afd_guard_lock_take — the AFD test lock on $AFD_GUARD_FD (opened on first use), waiting up to
# AFD_GUARD_LOCK_WAIT s. 0 when held. Otherwise 1, and AFD_GUARD_WHY names the cause — flock missing,
# the lock file not openable, or a real timeout — so no caller reports one as another.
afd_guard_lock_take() {
    AFD_GUARD_WHY=""
    if [[ -z "$AFD_GUARD_FD" ]]; then
        if ! command -v flock >/dev/null 2>&1; then
            AFD_GUARD_WHY="flock is not installed (it ships with util-linux), so the AFD test lock $AFD_GUARD_LOCK cannot be taken"
            return 1
        fi
        if ! { exec {AFD_GUARD_FD}>>"$AFD_GUARD_LOCK"; } 2>/dev/null; then
            AFD_GUARD_FD=""
            AFD_GUARD_WHY="the AFD test lock file $AFD_GUARD_LOCK cannot be opened for writing"
            return 1
        fi
    fi
    if ! flock -n "$AFD_GUARD_FD"; then
        printf "${YELLOW:-}waiting up to %ss for the AFD test lock %s, held by: %s${RESET:-}\n" \
            "$AFD_GUARD_LOCK_WAIT" "$AFD_GUARD_LOCK" "$(cat "$AFD_GUARD_LOCK" 2>/dev/null || true)"
        if ! flock -w "$AFD_GUARD_LOCK_WAIT" "$AFD_GUARD_FD"; then
            AFD_GUARD_WHY="the AFD test lock $AFD_GUARD_LOCK was not free within ${AFD_GUARD_LOCK_WAIT}s (another run's AFD suites or test servers?)"
            return 1
        fi
    fi
    { printf 'pid %s, %s\n' "$$" "${AFD_GUARD_OWNER:-$0}" > "$AFD_GUARD_LOCK"; } 2>/dev/null || true
}

# afd_guard_lock_release — gives the lock back; the fd stays open for the next take
afd_guard_lock_release() {
    [[ -z "$AFD_GUARD_FD" ]] || flock -u "$AFD_GUARD_FD" 2>/dev/null || true
}

# afd_guard_busy_ports [LO HI] — the ports of LO..HI (default: the guarded range) on which something
# accepts a loopback connection, space-separated. A connect probe, not a socket table: under WSL
# mirrored networking a Windows-side listener answers 127.0.0.1 without appearing in /proc/net/tcp.
# One node process probes the range in parallel, each probe bounded (a connect to a closed 127.0.0.1
# port hangs on WSL instead of being refused).
afd_guard_busy_ports() {
    afd_guard_node -e '
const net = require("net");
const [lo, hi] = process.argv.slice(1).map(Number);
const busy = [];
let left = hi - lo + 1;
for (let p = lo; p <= hi; p++) {
  const s = net.connect({ host: "127.0.0.1", port: p });
  let over = false;
  const end = (open) => {
    if (over) return;
    over = true;
    s.destroy();
    if (open) busy.push(p);
    if (--left === 0) console.log(busy.sort((a, b) => a - b).join(" "));
  };
  s.setTimeout(1000, () => end(false));
  s.on("connect", () => end(true));
  s.on("error", () => end(false));
}
' "${1:-${AFD_GUARD_PORTS%-*}}" "${2:-${AFD_GUARD_PORTS#*-}}"
}

# afd_guard_free_port [PREFERRED] — for a caller holding the lock: sets AFD_GUARD_PORT to PREFERRED when
# it lies in the guarded range and nothing answers on it, else to the lowest free port of the range.
# 1 + AFD_GUARD_WHY when the probe fails or every guarded port answers.
afd_guard_free_port() {
    local pref="${1:-}" lo="${AFD_GUARD_PORTS%-*}" hi="${AFD_GUARD_PORTS#*-}" busy p
    AFD_GUARD_PORT=""
    if ! busy=$(afd_guard_busy_ports "$lo" "$hi"); then
        AFD_GUARD_WHY="the loopback port probe over $AFD_GUARD_PORTS failed (node)"; return 1
    fi
    busy=" $busy "
    if [[ "$pref" =~ ^[0-9]+$ ]] && (( pref >= lo && pref <= hi )) && [[ "$busy" != *" $pref "* ]]; then
        AFD_GUARD_PORT=$pref; return 0
    fi
    for ((p = lo; p <= hi; p++)); do
        [[ "$busy" == *" $p "* ]] || { AFD_GUARD_PORT=$p; return 0; }
    done
    AFD_GUARD_WHY="every guarded AFD test port ($AFD_GUARD_PORTS) already answers"
    return 1
}

# afd_test_server SERVER_JS LOG PREFERRED_PORT [VAR=VALUE...] — starts an AFD server for a test with
# VAR=VALUE in its environment: under the AFD test lock (held until afd_test_server_stop), on a free
# guarded port (PREFERRED when free), bound to 127.0.0.1 only (AFD_BIND_HOST), and waits up to 30 s
# for /health, each probe bounded by curl -m. The server never sees a Telegram/ntfy credential the
# caller exported, and its Telegram API is a dead port unless VAR=VALUE says otherwise. It does not
# inherit the lock fd, so a server a test leaks cannot hold the lock. Sets AFD_TEST_PORT and
# AFD_TEST_SERVER_PID; 1 + AFD_GUARD_WHY when it could not (the lock is then given back).
afd_test_server() {
    local js="$1" log="$2" pref="$3" i
    shift 3
    afd_guard_lock_take || return 1
    afd_guard_free_port "$pref" || { afd_guard_lock_release; return 1; }
    AFD_TEST_PORT=$AFD_GUARD_PORT
    env -u AFD_TELEGRAM_BOT_TOKEN -u AFD_TELEGRAM_ELSA_TOKEN -u AFD_TELEGRAM_CHAT_ID -u AFD_NTFY_URL \
        AFD_NOTIFY=false AFD_TELEGRAM_API="http://[::1]:9" "$@" AFD_BIND_HOST=127.0.0.1 AFD_PORT="$AFD_TEST_PORT" \
        node "$js" >"$log" 2>&1 {AFD_GUARD_FD}>&- &
    AFD_TEST_SERVER_PID=$!
    for i in $(seq 1 300); do
        if curl -s -m 2 -o /dev/null "http://127.0.0.1:$AFD_TEST_PORT/health"; then
            kill -0 "$AFD_TEST_SERVER_PID" 2>/dev/null && return 0
            break   # something answers, but our server is gone: it lost the port
        fi
        kill -0 "$AFD_TEST_SERVER_PID" 2>/dev/null || break
        sleep 0.1
    done
    AFD_GUARD_WHY="the AFD test server did not come up on 127.0.0.1:$AFD_TEST_PORT: $(tail -3 "$log" 2>/dev/null | tr '\n' ' ')"
    afd_test_server_stop
    return 1
}

# afd_test_server_stop — stops the server afd_test_server started, then gives the lock back
afd_test_server_stop() {
    if [[ -n "$AFD_TEST_SERVER_PID" ]]; then
        kill "$AFD_TEST_SERVER_PID" 2>/dev/null || true
        wait "$AFD_TEST_SERVER_PID" 2>/dev/null || true
    fi
    AFD_TEST_SERVER_PID=""
    afd_guard_lock_release
}
