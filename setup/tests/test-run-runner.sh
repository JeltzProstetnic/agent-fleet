#!/usr/bin/env bash
# Tests for setup/tests/run.sh — the suite runner (CFG-1003: it must also run afd/tests/).
# Every case runs a COPY of the real run.sh inside a fake repo tree under $TEST_TMPDIR, so the
# runner resolves its setup/tests and afd/tests from that tree: fake suites only, no real AFD
# test, no server, no network. A fake suite leaves a marker file named after itself, so "was it
# run" is read from the filesystem rather than from the runner's own output.
# Each tree gets a private AFD lock file and guarded port (mk_tree), so a real AFD run elsewhere on
# the machine can neither block these cases nor be blocked by them. Two cases read the REAL afd/tests
# (the guarded port range covers its ports; its .js suites are ES modules by declaration).
source "$(dirname "$0")/test-helpers.sh"

RUNNER_SRC="$REPO_ROOT/setup/tests/run.sh"

suite_header "run.sh: setup + afd suites, filters, exclusions, live-service guard"

# mk_sh PATH RC — a bash suite that leaves a marker and exits RC
mk_sh() {
    printf '#!/usr/bin/env bash\ntouch "%s/$(basename "$0")"\nexit %s\n' "$MARKS" "$2" > "$1"
}
# mk_js PATH RC — a node suite that leaves a marker and exits RC
mk_js() {
    printf "require('fs').writeFileSync(%s + '/' + require('path').basename(__filename), '');\nprocess.exit(%s);\n" \
        "'$MARKS'" "$2" > "$1"
}

# mk_tree — fake repo: run.sh, setup suites (one e2e), afd suites (.sh, .js, the excluded
# test-cc-invoke.sh), afd/server/package.json with one dependency that is installed and loads.
# The AFD lock and the guarded port range are private to the test (RUN_AFD_LOCK / RUN_AFD_PORTS),
# so a real run of the AFD suites elsewhere on the machine can neither block nor fail this one.
mk_tree() {
    R="$TEST_TMPDIR/repo"
    MARKS="$TEST_TMPDIR/marks"
    mkdir -p "$R/setup/tests" "$R/afd/tests" "$R/afd/server/node_modules/fakedep" "$MARKS"
    cp "$RUNNER_SRC" "$R/setup/tests/run.sh"
    cp "$REPO_ROOT/setup/tests/lib-afd-test-guard.sh" "$R/setup/tests/"
    printf '{"name":"fake-afd","dependencies":{"fakedep":"^1.0.0"}}\n' > "$R/afd/server/package.json"
    echo '{}' > "$R/afd/server/node_modules/fakedep/package.json"
    echo 'module.exports = {};' > "$R/afd/server/node_modules/fakedep/index.js"
    mk_sh "$R/setup/tests/test-alpha.sh" 0
    mk_sh "$R/setup/tests/test-e2e-gamma.sh" 0
    mk_sh "$R/afd/tests/test-afd-okay.sh" 0
    mk_js "$R/afd/tests/test-afd-okay.js" 0
    mk_sh "$R/afd/tests/test-cc-invoke.sh" 0
    local p; p=$(free_port)
    export RUN_AFD_LOCK="$TEST_TMPDIR/afd-test-ports.lock" RUN_AFD_PORTS="$p-$p"
}

# free_port — a loopback port nothing listens on right now (the OS picks it)
free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# hold_port SECONDS — a listener on a fresh loopback port for SECONDS: stands in for another
# run's AFD server. Sets HELD_PORT and HOLDER_PID.
hold_port() {
    local f="$TEST_TMPDIR/held-port"
    rm -f "$f"
    python3 -c 'import os, socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[2] + ".t", "w").write(str(s.getsockname()[1])); os.replace(sys.argv[2] + ".t", sys.argv[2])
time.sleep(float(sys.argv[1]))' "$1" "$f" &
    HOLDER_PID=$!
    for _ in $(seq 1 100); do [[ -s "$f" ]] && break; sleep 0.05; done
    HELD_PORT=$(cat "$f")
}

# hold_lock FILE — another run holding the AFD test lock (one process; LOCK_HOLDER_PID)
hold_lock() {
    local ready="$TEST_TMPDIR/lock-held"
    python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(60)' \
        "$1" "$ready" &
    LOCK_HOLDER_PID=$!
    for _ in $(seq 1 100); do [[ -e "$ready" ]] && break; sleep 0.05; done
}

# path_without_node — one PATH dir with the tools run.sh and the fake suites use, but no node
path_without_node() {
    local d="$TEST_TMPDIR/no-node-bin" t
    mkdir -p "$d"
    for t in bash env setsid mktemp rm basename dirname flock git ln cmp cat sleep touch; do
        ln -s "$(command -v "$t")" "$d/$t"
    done
    echo "$d"
}

# path_without_flock — one PATH dir with node and the tools run.sh and the fake suites use, but no flock
path_without_flock() {
    local d="$TEST_TMPDIR/no-flock-bin" t
    mkdir -p "$d"
    for t in bash env setsid mktemp rm basename dirname node git ln cmp cat sleep touch; do
        ln -s "$(command -v "$t")" "$d/$t"
    done
    echo "$d"
}

# node_reporting_version VERSION — a PATH dir whose node claims VERSION and otherwise is the real one
node_reporting_version() {
    local d="$TEST_TMPDIR/old-node-bin" real
    real=$(command -v node)
    mkdir -p "$d"
    printf '#!/usr/bin/env bash\n[[ "$1" == --version ]] && { echo %s; exit 0; }\nexec "%s" "$@"\n' "$1" "$real" > "$d/node"
    chmod +x "$d/node"
    echo "$d"
}

# run_runner [args...] — runs the copied runner; sets OUT and RC
run_runner() {
    RC=0
    OUT=$(NO_COLOR=1 bash "$R/setup/tests/run.sh" "$@" </dev/null 2>&1) || RC=$?
}

ran() { [[ -e "$MARKS/$1" ]] && echo yes || echo no; }

need_node() {
    command -v node >/dev/null 2>&1
}

test_default_runs_setup_and_afd() {
    mk_tree
    run_runner
    assert_eq "0" "$RC" "all suites pass → exit 0 (output: $OUT)"
    assert_eq "yes" "$(ran test-alpha.sh)" "setup suite ran"
    assert_eq "yes" "$(ran test-afd-okay.sh)" "afd .sh suite ran"
    assert_eq "yes" "$(ran test-afd-okay.js)" "afd .js suite ran (with node)"
    assert_eq "no" "$(ran test-e2e-gamma.sh)" "e2e suite stays excluded by default"
    assert_contains "$OUT" "Test Suites: 3 total" "summary counts setup + afd suites"
    assert_contains "$OUT" "afd/test-afd-okay.js" "afd suites are named afd/<file>"
}

test_failing_afd_sh_fails_the_run() {
    mk_tree
    mk_sh "$R/afd/tests/test-afd-broken.sh" 1
    run_runner
    assert_eq "1" "$RC" "a failing afd .sh suite → exit 1"
    assert_contains "$OUT" "Failed: 1" "one failure counted"
    assert_contains "$OUT" "- afd/test-afd-broken.sh" "the failing afd suite is listed by name"
}

test_failing_afd_js_fails_the_run() {
    mk_tree
    mk_js "$R/afd/tests/test-afd-broken.js" 3
    run_runner
    assert_eq "1" "$RC" "a failing afd .js suite (node exit 3) → exit 1"
    assert_eq "yes" "$(ran test-afd-broken.js)" "the failing js suite did run"
    assert_contains "$OUT" "- afd/test-afd-broken.js" "the failing js suite is listed by name"
}

test_setup_failure_still_reported() {
    mk_tree
    mk_sh "$R/setup/tests/test-beta.sh" 1
    run_runner
    assert_eq "1" "$RC" "a failing setup suite → exit 1"
    assert_contains "$OUT" "- test-beta" "setup suites keep their bare name in the failed list"
}

test_pattern_filters_afd_suites() {
    mk_tree
    run_runner okay
    assert_eq "0" "$RC" "pattern run passes"
    assert_eq "yes" "$(ran test-afd-okay.sh)" "matching afd .sh suite ran"
    assert_eq "yes" "$(ran test-afd-okay.js)" "matching afd .js suite ran"
    assert_eq "no" "$(ran test-alpha.sh)" "non-matching setup suite skipped"
    assert_contains "$OUT" "Test Suites: 2 total" "only the two matching suites counted"
    rm -f "$MARKS"/*
    run_runner alpha
    assert_eq "yes" "$(ran test-alpha.sh)" "matching setup suite ran"
    assert_eq "no" "$(ran test-afd-okay.sh)" "non-matching afd .sh suite skipped"
    assert_eq "no" "$(ran test-afd-okay.js)" "non-matching afd .js suite skipped"
    assert_contains "$OUT" "Test Suites: 1 total" "only the matching setup suite counted"
}

test_pattern_afd_prefix_selects_only_afd() {
    mk_tree
    run_runner afd/
    assert_eq "0" "$RC" "afd/ run passes"
    assert_eq "no" "$(ran test-alpha.sh)" "setup suite not selected by afd/"
    assert_eq "yes" "$(ran test-afd-okay.sh)" "afd .sh suite selected by afd/"
    assert_contains "$OUT" "Test Suites: 2 total" "afd/ selects exactly the afd suites"
}

test_excluded_suite_never_runs_and_is_printed() {
    mk_tree
    run_runner
    assert_eq "no" "$(ran test-cc-invoke.sh)" "the non-hermetic suite is never run"
    assert_contains "$OUT" "EXCLUDED afd/test-cc-invoke.sh" "the exclusion is printed"
    assert_contains "$OUT" "ssh" "the exclusion states its reason (a real ssh)"
    rm -f "$MARKS"/*
    run_runner cc-invoke
    assert_eq "no" "$(ran test-cc-invoke.sh)" "naming it in the pattern does not run it"
    assert_contains "$OUT" "EXCLUDED afd/test-cc-invoke.sh" "the exclusion is printed for a matching pattern too"
    rm -f "$MARKS"/*
    run_runner alpha
    assert_not_contains "$OUT" "EXCLUDED" "no exclusion line when the pattern does not select it"
}

test_afd_suites_get_no_live_credentials() {
    mk_tree
    printf '#!/usr/bin/env bash\n{ for v in AFD_TELEGRAM_BOT_TOKEN AFD_TELEGRAM_ELSA_TOKEN AFD_TELEGRAM_CHAT_ID AFD_NTFY_URL AFD_TOKEN AFD_URL AFD_TELEGRAM_API AFD_BIND_HOST; do echo "$v=${!v-unset}"; done\n  echo "HOME=$HOME"; [[ -e "$HOME/.afd-env" ]] && echo ENVFILE=visible || echo ENVFILE=hidden; } > "%s/env"\n' \
        "$MARKS" > "$R/afd/tests/test-afd-envprobe.sh"
    echo "AFD_URL=https://live.example.invalid" > "$HOME/.afd-env"
    RC=0
    OUT=$(NO_COLOR=1 AFD_TELEGRAM_BOT_TOKEN=live-bartl AFD_TELEGRAM_ELSA_TOKEN=live-elsa AFD_TELEGRAM_CHAT_ID=4242 \
        AFD_NTFY_URL=https://ntfy.example.invalid AFD_TOKEN=live-token AFD_URL=https://live.example.invalid \
        bash "$R/setup/tests/run.sh" envprobe </dev/null 2>&1) || RC=$?
    local env_seen; env_seen=$(cat "$MARKS/env" 2>/dev/null)
    assert_eq "0" "$RC" "probe run passes (output: $OUT)"
    assert_contains "$env_seen" "AFD_TELEGRAM_BOT_TOKEN=unset" "main bot token scrubbed"
    assert_contains "$env_seen" "AFD_TELEGRAM_ELSA_TOKEN=unset" "second bot token scrubbed"
    assert_contains "$env_seen" "AFD_TELEGRAM_CHAT_ID=unset" "Telegram chat id scrubbed"
    assert_contains "$env_seen" "AFD_NTFY_URL=unset" "ntfy URL scrubbed"
    assert_contains "$env_seen" "AFD_TOKEN=unset" "live AFD token scrubbed"
    assert_contains "$env_seen" "AFD_URL=http://[::1]:9" "AFD_URL points at a dead loopback port, not the live default"
    assert_contains "$env_seen" "AFD_TELEGRAM_API=http://[::1]:9" "Telegram API points at a dead loopback port"
    assert_contains "$env_seen" "AFD_BIND_HOST=127.0.0.1" "a server the suite starts listens on loopback only"
    assert_contains "$env_seen" "ENVFILE=hidden" "the caller's ~/.afd-env is not visible"
    local probe_home; probe_home=$(sed -n 's/^HOME=//p' "$MARKS/env")
    assert_neq "$HOME" "$probe_home" "afd suites run with a sandbox HOME"
    assert_eq "gone" "$([[ -n "$probe_home" && ! -e "$probe_home" ]] && echo gone || echo "left:$probe_home")" \
        "the sandbox HOME is removed after the suite"
}

test_afd_node_output_stays_clean_under_no_color() {
    # Claude Code's Bash exports FORCE_COLOR=1; with the documented `NO_COLOR=1 bash run.sh` node then
    # prints "Warning: The 'NO_COLOR' env is ignored ..." on stderr, and AFD suites that parse
    # `afd messages 2>&1` as JSON lines failed on it (test-afd-client.sh, test-afd-reply-to.sh).
    mk_tree
    printf '#!/usr/bin/env bash\nout=$(node -e "console.log(42)" 2>&1)\necho "$out" > "%s/node-out"\n[[ "$out" == 42 ]]\n' \
        "$MARKS" > "$R/afd/tests/test-afd-nodeclean.sh"
    RC=0
    OUT=$(NO_COLOR=1 FORCE_COLOR=1 bash "$R/setup/tests/run.sh" nodeclean </dev/null 2>&1) || RC=$?
    assert_eq "42" "$(cat "$MARKS/node-out" 2>/dev/null)" "node prints only its output inside an afd suite"
    assert_eq "0" "$RC" "the suite passes under NO_COLOR=1 + FORCE_COLOR=1"
}

test_missing_afd_deps_fails_loudly() {
    mk_tree
    rm -rf "$R/afd/server/node_modules/fakedep"
    run_runner
    assert_eq "1" "$RC" "afd deps missing → exit 1, never a silent green"
    assert_eq "no" "$(ran test-afd-okay.sh)" "afd suites are not run without their deps"
    assert_eq "yes" "$(ran test-alpha.sh)" "setup suites still run"
    assert_contains "$OUT" "fakedep" "the missing dependency is named"
    assert_contains "$OUT" "fix: npm ci --prefix $R/afd/server" "the fix is printed as one exact command"
    assert_contains "$OUT" "- afd-deps" "the gap is listed as a failure"
}

test_afd_deps_check_clean_under_force_color() {
    # The deps check is itself a node call made by the runner, outside any afd suite's scrub: under
    # Claude Code's FORCE_COLOR=1 plus NO_COLOR=1, its captured 2>&1 swallowed node's NO_COLOR warning
    # into the "missing deps" line (seen on the real tree 2026-11-13, CFG-1003).
    mk_tree
    RC=0
    OUT=$(NO_COLOR=1 FORCE_COLOR=1 bash "$R/setup/tests/run.sh" </dev/null 2>&1) || RC=$?
    assert_eq "0" "$RC" "deps installed + FORCE_COLOR=1 → no afd-deps failure (output: $OUT)"
    assert_not_contains "$OUT" "afd-deps" "no deps gap reported when the deps are there"
    rm -rf "$R/afd/server/node_modules/fakedep"
    RC=0
    OUT=$(NO_COLOR=1 FORCE_COLOR=1 bash "$R/setup/tests/run.sh" </dev/null 2>&1) || RC=$?
    assert_eq "1" "$RC" "deps missing + FORCE_COLOR=1 → exit 1"
    assert_contains "$OUT" "missing from afd/server/node_modules: fakedep — fix: npm ci --prefix $R/afd/server" \
        "the deps gap is one clean line"
    assert_not_contains "$OUT" "env is ignored" "no node warning leaks into the runner's own output"
}

test_no_afd_flag_skips_afd_explicitly() {
    mk_tree
    rm -rf "$R/afd/server/node_modules/fakedep"
    run_runner --no-afd
    assert_eq "0" "$RC" "--no-afd with missing deps → exit 0"
    assert_eq "no" "$(ran test-afd-okay.sh)" "no afd suite runs under --no-afd"
    assert_eq "yes" "$(ran test-alpha.sh)" "setup suites still run"
    assert_contains "$OUT" "--no-afd" "the skip is printed with its cause"
}

test_e2e_flag_still_works() {
    mk_tree
    run_runner --e2e
    assert_eq "yes" "$(ran test-e2e-gamma.sh)" "--e2e includes e2e suites"
    rm -f "$MARKS"/*
    run_runner gamma --e2e
    assert_eq "yes" "$(ran test-e2e-gamma.sh)" "pattern + --e2e selects the e2e suite"
    assert_eq "no" "$(ran test-afd-okay.sh)" "pattern + --e2e still filters afd suites"
    assert_contains "$OUT" "Test Suites: 1 total" "exactly one suite under gamma --e2e"
}

# ── Review fixes (CFG-1003): overlapping runs, env allowlist, worktrees, empty runs, deps ──────────

test_foreign_listener_blocks_afd_suites() {
    # Another run's AFD server on a test port answers this run's /health polls: suites that only
    # poll /health then passed against IT, so a broken AFD server was reported green.
    mk_tree
    hold_port 30
    RUN_AFD_PORTS="$HELD_PORT-$HELD_PORT" RUN_AFD_PORT_WAIT=1 run_runner okay
    kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null
    assert_eq "1" "$RC" "a listener already on a test port → exit 1, never green (output: $OUT)"
    assert_eq "no" "$(ran test-afd-okay.sh)" "the afd .sh suite is not run against a foreign server"
    assert_eq "no" "$(ran test-afd-okay.js)" "the afd .js suite is not run either"
    assert_contains "$OUT" "$HELD_PORT" "the busy port is named"
    assert_contains "$OUT" "- afd/test-afd-okay.sh" "the suite is listed as failed"
}

test_port_freed_within_wait_runs_suite() {
    # The previous suite's server may still be exiting: a port that frees up within the wait is fine
    mk_tree
    hold_port 1
    RUN_AFD_PORTS="$HELD_PORT-$HELD_PORT" RUN_AFD_PORT_WAIT=15 run_runner okay
    wait "$HOLDER_PID" 2>/dev/null
    assert_eq "0" "$RC" "a port that frees within RUN_AFD_PORT_WAIT → the suites run (output: $OUT)"
    assert_eq "yes" "$(ran test-afd-okay.sh)" "afd .sh suite ran once the port was free"
    assert_eq "yes" "$(ran test-afd-okay.js)" "afd .js suite ran once the port was free"
}

test_afd_lock_held_elsewhere_fails_loudly() {
    mk_tree
    hold_lock "$RUN_AFD_LOCK"
    RUN_AFD_LOCK_WAIT=1 run_runner
    kill "$LOCK_HOLDER_PID" 2>/dev/null; wait "$LOCK_HOLDER_PID" 2>/dev/null
    assert_eq "1" "$RC" "AFD test lock not free within RUN_AFD_LOCK_WAIT → exit 1 (output: $OUT)"
    assert_eq "no" "$(ran test-afd-okay.sh)" "no afd suite runs without the lock"
    assert_eq "yes" "$(ran test-alpha.sh)" "setup suites still run"
    assert_contains "$OUT" "lock" "the lock is named as the cause"
    assert_contains "$OUT" "- afd/test-afd-okay.sh" "the suite is listed as failed"
}

test_suite_runs_under_lock_without_inheriting_it() {
    mk_tree
    printf '#!/usr/bin/env bash\n{ flock -n "%s" true && echo lock=free || echo lock=held\nfor fd in /proc/$$/fd/*; do [[ "$(readlink "$fd")" == "%s" ]] && echo fd=inherited; done; } > "%s/lockprobe"\nexit 0\n' \
        "$RUN_AFD_LOCK" "$RUN_AFD_LOCK" "$MARKS" > "$R/afd/tests/test-afd-lockprobe.sh"
    run_runner lockprobe
    local seen; seen=$(cat "$MARKS/lockprobe" 2>/dev/null)
    assert_eq "0" "$RC" "probe run passes (output: $OUT)"
    assert_contains "$seen" "lock=held" "the AFD test lock is held while an afd suite runs"
    assert_not_contains "$seen" "fd=inherited" "the suite (and any server it leaks) does not inherit the lock"
}

test_overlapping_runs_take_turns() {
    mk_tree
    printf '#!/usr/bin/env bash\necho "start $$" >> "%s/seq"\nsleep 1\necho "end $$" >> "%s/seq"\n' \
        "$MARKS" "$MARKS" > "$R/afd/tests/test-afd-turns.sh"
    local r1=0 r2=0 p1 p2 seq
    NO_COLOR=1 bash "$R/setup/tests/run.sh" turns >"$TEST_TMPDIR/o1" 2>&1 </dev/null & p1=$!
    NO_COLOR=1 bash "$R/setup/tests/run.sh" turns >"$TEST_TMPDIR/o2" 2>&1 </dev/null & p2=$!
    wait "$p1" || r1=$?
    wait "$p2" || r2=$?
    seq=$(cut -d' ' -f1 "$MARKS/seq" | tr '\n' ' ')
    assert_eq "start end start end " "$seq" "two overlapping runs never run their afd suites at the same time"
    assert_eq "0 0" "$r1 $r2" "both overlapping runs pass"
}

test_afd_suites_get_an_allowlisted_env() {
    # A denylist let caller-exported test knobs through: AFD_SERVER_DIR=<other tree> made the suites
    # test another tree's server and the gate went green on a broken one.
    mk_tree
    printf '#!/usr/bin/env bash\n{ for v in AFD_SERVER_DIR AFD_DB_PATH AFD_NOTIFY AFD_TEST_PORT_BASE NODE_OPTIONS CFG1003_PROBE LANG; do echo "$v=${!v-unset}"; done; echo "PATH=$PATH"; } > "%s/env2"\n' \
        "$MARKS" > "$R/afd/tests/test-afd-envallow.sh"
    RC=0
    OUT=$(NO_COLOR=1 LANG=C.UTF-8 AFD_SERVER_DIR=/elsewhere/afd/server AFD_DB_PATH=/elsewhere/f.db AFD_NOTIFY=true \
        AFD_TEST_PORT_BASE=19000 NODE_OPTIONS="--require $TEST_TMPDIR/no-such-preload.js" CFG1003_PROBE=leak \
        bash "$R/setup/tests/run.sh" envallow </dev/null 2>&1) || RC=$?
    local seen; seen=$(cat "$MARKS/env2" 2>/dev/null)
    assert_eq "0" "$RC" "the runner's own node calls ignore the caller's NODE_OPTIONS (output: $OUT)"
    assert_contains "$seen" "AFD_SERVER_DIR=unset" "AFD_SERVER_DIR does not reach the suite"
    assert_contains "$seen" "AFD_DB_PATH=unset" "AFD_DB_PATH does not reach the suite"
    assert_contains "$seen" "AFD_NOTIFY=unset" "AFD_NOTIFY does not reach the suite"
    assert_contains "$seen" "AFD_TEST_PORT_BASE=unset" "AFD_TEST_PORT_BASE does not reach the suite"
    assert_contains "$seen" "NODE_OPTIONS=unset" "NODE_OPTIONS does not reach the suite"
    assert_contains "$seen" "CFG1003_PROBE=unset" "an arbitrary caller variable does not reach the suite"
    assert_contains "$seen" "LANG=C.UTF-8" "LANG is passed through"
    assert_contains "$seen" "PATH=$PATH" "PATH is passed through"
}

# mk_worktree_pair — $R becomes the main worktree of a real git repo (its afd/server/node_modules
# installed, gitignored), $WT a linked worktree of it, which therefore has no node_modules
mk_worktree_pair() {
    mk_tree
    if [[ -f "$REPO_ROOT/afd/.gitignore" ]]; then cp "$REPO_ROOT/afd/.gitignore" "$R/afd/.gitignore"
    else echo 'node_modules' > "$R/afd/.gitignore"; fi
    echo '{"lockfileVersion":3}' > "$R/afd/server/package-lock.json"
    git -C "$R" init -q -b main
    git -C "$R" add -A
    git -C "$R" commit -qm fixture
    WT="$TEST_TMPDIR/wt"
    git -C "$R" worktree add -q "$WT" 2>/dev/null
}

test_worktree_borrows_main_node_modules() {
    mk_worktree_pair
    assert_eq "absent" "$([[ -e "$WT/afd/server/node_modules" ]] && echo present || echo absent)" \
        "a fresh linked worktree has no afd/server/node_modules (gitignored)"
    RC=0
    OUT=$(NO_COLOR=1 bash "$WT/setup/tests/run.sh" okay </dev/null 2>&1) || RC=$?
    assert_eq "0" "$RC" "a worktree run passes on the main worktree's install (output: $OUT)"
    assert_eq "yes" "$(ran test-afd-okay.sh)" "afd suites ran in the worktree"
    assert_eq "$R/afd/server/node_modules" "$(readlink "$WT/afd/server/node_modules")" \
        "the worktree links the main worktree's afd/server/node_modules"
    assert_contains "$OUT" "linked afd/server/node_modules" "the link is announced"
    assert_eq "" "$(git -C "$WT" status --porcelain)" "the link is gitignored: the worktree stays clean"
}

test_worktree_with_other_lockfile_does_not_borrow() {
    mk_worktree_pair
    echo '{"lockfileVersion":3,"changed":true}' > "$WT/afd/server/package-lock.json"
    RC=0
    OUT=$(NO_COLOR=1 bash "$WT/setup/tests/run.sh" okay </dev/null 2>&1) || RC=$?
    assert_eq "1" "$RC" "different dependencies → no borrowing, afd-deps fails (output: $OUT)"
    assert_eq "absent" "$([[ -e "$WT/afd/server/node_modules" ]] && echo present || echo absent)" \
        "no link to an install made for another package-lock.json"
    assert_contains "$OUT" "package-lock.json" "the reason names the lockfile"
    assert_contains "$OUT" "- afd-deps" "the gap is listed as a failure"
}

test_unknown_option_is_rejected() {
    mk_tree
    run_runner --skip-afd
    assert_eq "2" "$RC" "a mistyped option exits 2 instead of becoming the pattern (output: $OUT)"
    assert_contains "$OUT" "unknown option '--skip-afd'" "the bad option is named"
    assert_eq "no" "$(ran test-alpha.sh)" "nothing runs on a usage error"
}

test_second_pattern_is_rejected() {
    mk_tree
    run_runner alpha okay
    assert_eq "2" "$RC" "two patterns exit 2 instead of silently keeping the last (output: $OUT)"
    assert_eq "no" "$(ran test-alpha.sh)" "nothing runs on a usage error"
}

test_pattern_matching_nothing_fails() {
    mk_tree
    run_runner nosuchsuite
    assert_eq "1" "$RC" "a pattern that selects no suite → exit 1, a run of nothing is not green (output: $OUT)"
    assert_contains "$OUT" "nosuchsuite" "the pattern is named"
}

test_only_excluded_suite_selected_fails() {
    mk_tree
    run_runner cc-invoke
    assert_eq "1" "$RC" "only an excluded suite matched → exit 1 (output: $OUT)"
    assert_eq "no" "$(ran test-cc-invoke.sh)" "the excluded suite still does not run"
    assert_contains "$OUT" "only excluded" "the run says it ran nothing because of the exclusion"
}

test_exclusion_text_cites_backlog_and_no_personal_hosts() {
    mk_tree
    run_runner cc-invoke
    local line; line=$(grep 'EXCLUDED' <<<"$OUT")
    assert_contains "$line" "CFG-379" "the exclusion cites the item that tracks making it hermetic"
    assert_eq "" "$(grep -ioE '\bnuc\b|deck|elsa' <<<"$line")" "the exclusion names no personal host or persona"
}

test_setup_failure_reported_without_node() {
    mk_tree
    mk_sh "$R/setup/tests/test-beta.sh" 1
    run_runner beta
    assert_eq "1" "$RC" "a failing setup suite → exit 1 (pattern selects no afd suite, so no node needed)"
    assert_contains "$OUT" "- test-beta" "the failing setup suite is listed"
    rm -f "$MARKS"/*
    run_runner gamma --e2e
    assert_eq "yes" "$(ran test-e2e-gamma.sh)" "--e2e with a pattern runs the e2e suite without node"
}

test_node_missing_fails_as_afd_deps() {
    mk_tree
    local nobin; nobin=$(path_without_node)
    RC=0
    OUT=$(PATH="$nobin" NO_COLOR=1 "$BASH" "$R/setup/tests/run.sh" </dev/null 2>&1) || RC=$?
    assert_eq "1" "$RC" "no node on PATH with afd suites selected → exit 1 (output: $OUT)"
    assert_contains "$OUT" "node is not on PATH" "the cause is printed"
    assert_contains "$OUT" "- afd-deps" "one afd-deps failure"
    assert_eq "yes" "$(ran test-alpha.sh)" "setup suites still run"
    assert_eq "no" "$(ran test-afd-okay.sh)" "no afd suite runs"
}

test_unreadable_package_json_fails_as_afd_deps() {
    mk_tree
    echo '{' > "$R/afd/server/package.json"
    run_runner okay
    assert_eq "1" "$RC" "a package.json node cannot parse → exit 1 (output: $OUT)"
    assert_contains "$OUT" "could not read" "the cause is printed"
    assert_contains "$OUT" "- afd-deps" "one afd-deps failure"
    assert_eq "no" "$(ran test-afd-okay.sh)" "no afd suite runs"
}

test_dependency_that_does_not_load_fails_once() {
    # An installed but unloadable dependency (native binding built for another Node ABI) used to
    # pass the presence check and then fail ~20 suites one by one
    mk_tree
    echo 'throw new Error("was compiled against a different Node.js version using NODE_MODULE_VERSION 115");' \
        > "$R/afd/server/node_modules/fakedep/index.js"
    run_runner okay
    assert_eq "1" "$RC" "an unloadable dependency → exit 1 (output: $OUT)"
    assert_contains "$OUT" "fakedep does not load" "the dependency is named"
    assert_contains "$OUT" "NODE_MODULE_VERSION 115" "node's reason is printed"
    assert_contains "$OUT" "- afd-deps" "one afd-deps failure"
    assert_eq "no" "$(ran test-afd-okay.sh)" "no afd suite runs"
}

test_better_sqlite3_binding_is_opened() {
    # better-sqlite3 loads its native binding lazily, in new Database(): requiring it is not enough
    mk_tree
    printf '{"name":"fake-afd","dependencies":{"better-sqlite3":"^11.0.0"}}\n' > "$R/afd/server/package.json"
    mkdir -p "$R/afd/server/node_modules/better-sqlite3"
    echo '{"main":"lib.js"}' > "$R/afd/server/node_modules/better-sqlite3/package.json"
    echo 'module.exports = function Database() { throw new Error("NODE_MODULE_VERSION 127 required, this is 115"); };' \
        > "$R/afd/server/node_modules/better-sqlite3/lib.js"
    run_runner okay
    assert_eq "1" "$RC" "better-sqlite3 whose binding fails → exit 1 (output: $OUT)"
    assert_contains "$OUT" "better-sqlite3 does not load: NODE_MODULE_VERSION 127 required" "the binding failure is printed"
    echo 'module.exports = function Database() { return { close() {} }; };' \
        > "$R/afd/server/node_modules/better-sqlite3/lib.js"
    rm -f "$MARKS"/*
    run_runner okay
    assert_eq "0" "$RC" "a binding that opens → the suites run (output: $OUT)"
    assert_eq "yes" "$(ran test-afd-okay.sh)" "afd suite ran"
}

test_node_older_than_18_fails_once() {
    mk_tree
    local oldbin; oldbin=$(node_reporting_version v16.20.2)
    RC=0
    OUT=$(PATH="$oldbin:$PATH" NO_COLOR=1 bash "$R/setup/tests/run.sh" okay </dev/null 2>&1) || RC=$?
    assert_eq "1" "$RC" "node 16 → exit 1 (output: $OUT)"
    assert_contains "$OUT" "node v16.20.2 is older than 18" "the version gap is printed"
    assert_contains "$OUT" "- afd-deps" "one afd-deps failure"
    assert_eq "no" "$(ran test-afd-okay.sh)" "no afd suite runs"
}

test_real_afd_js_suites_declare_esm() {
    # The .js suites use `import` with no "type":"module" above them, so they ran only through
    # Node's module-syntax detection (>= 22.7 / 20.19). Parse them with detection switched off.
    local f bad=""
    if ! node --no-experimental-detect-module -e 0 >/dev/null 2>&1; then
        echo "    (this node has no --no-experimental-detect-module; nothing to compare)"; return 0
    fi
    for f in "$REPO_ROOT"/afd/tests/test-*.js; do
        [[ -f "$f" ]] || continue
        node --no-experimental-detect-module --check "$f" >/dev/null 2>&1 || bad+=" $(basename "$f")"
    done
    assert_eq "" "$bad" "every afd .js suite parses as an ES module without syntax detection"
}

test_runner_port_range_covers_afd_suite_ports() {
    local range lo hi p outside=""
    # the default lives in lib-afd-test-guard.sh, which run.sh sources
    range=$(grep -ohE 'RUN_AFD_PORTS:-[0-9]+-[0-9]+' "$REPO_ROOT/setup/tests/lib-afd-test-guard.sh" | head -1)
    range=${range#RUN_AFD_PORTS:-}
    assert_neq "" "$range" "the guard declares a default guarded port range"
    lo=${range%-*}; hi=${range#*-}
    for p in $(grep -ohE '\b19[0-9]{3}\b' "$REPO_ROOT"/afd/tests/*.sh "$REPO_ROOT"/afd/tests/*.js \
                 "$REPO_ROOT"/setup/tests/test-lease-run.sh "$REPO_ROOT"/setup/tests/test-tmux-launch*.sh | sort -un); do
        (( p >= lo && p <= hi )) || outside+=" $p"
    done
    assert_eq "" "$outside" "every 19xxx port in afd/tests and the AFD-server setup suites lies inside the guarded range $range"
}

# ── Second review (CFG-1003): lock causes, fail-fast, dead URL, bounded probes, loopback, deps text ─

test_lock_timeout_fails_the_rest_fast() {
    # After one lock timeout every further AFD suite waited the full RUN_AFD_LOCK_WAIT again (1800 s each)
    mk_tree
    hold_lock "$RUN_AFD_LOCK"
    local t0 ms waits; t0=$(date +%s%N)
    RUN_AFD_LOCK_WAIT=4 run_runner okay
    ms=$(( ($(date +%s%N) - t0) / 1000000 ))
    kill "$LOCK_HOLDER_PID" 2>/dev/null; wait "$LOCK_HOLDER_PID" 2>/dev/null
    waits=$(grep -c "waiting up to" <<<"$OUT" || true)
    echo "    measured: ${ms} ms for two afd suites, ${waits} lock wait(s)"
    assert_eq "1" "$RC" "lock not free → exit 1 (output: $OUT)"
    assert_eq "1" "$waits" "the lock is waited for once per run, not once per suite"
    assert_contains "$OUT" "was not free within 4s" "the first suite names the timeout"
    assert_contains "$OUT" "not waited for again" "the next suite fails at once, saying why"
    assert_contains "$OUT" "- afd/test-afd-okay.js" "both suites are listed as failed"
    assert_eq "fast" "$( (( ms < 7000 )) && echo fast || echo "slow: $ms ms")" "one wait (4 s), not two (8 s)"
}

test_lock_causes_are_distinct() {
    mk_tree
    local nobin; nobin=$(path_without_flock)
    RC=0
    OUT=$(PATH="$nobin" NO_COLOR=1 "$BASH" "$R/setup/tests/run.sh" okay </dev/null 2>&1) || RC=$?
    echo "    measured (no flock): $(grep -m1 'NOT run' <<<"$OUT")"
    assert_eq "1" "$RC" "no flock → exit 1 (output: $OUT)"
    assert_contains "$OUT" "flock is not installed" "a missing flock is named as such"
    assert_not_contains "$OUT" "not free within" "and is not reported as a lock timeout"
    assert_eq "no" "$(ran test-afd-okay.sh)" "no afd suite runs without the lock"
    RUN_AFD_LOCK="$TEST_TMPDIR/no-such-dir/afd.lock" run_runner okay
    echo "    measured (unopenable): $(grep -m1 'NOT run' <<<"$OUT")"
    assert_eq "1" "$RC" "an unopenable lock file → exit 1"
    assert_contains "$OUT" "cannot be opened" "an unopenable lock file is named as such"
    assert_not_contains "$OUT" "not free within" "and is not reported as a lock timeout"
}

test_dead_afd_url_refuses_fast() {
    # AFD_URL / AFD_TELEGRAM_API point at a dead port so no suite reaches the live daemon. Under WSL
    # mirrored networking a connect to a closed 127.0.0.1 port HANGS instead of being refused (measured
    # 2026-11-13: curl to 127.0.0.1:9 still connecting after 8 s), so a stray call hung the gate.
    mk_tree
    printf '#!/usr/bin/env bash\nfor u in "$AFD_URL" "$AFD_TELEGRAM_API"; do t=$(date +%%s%%N); curl -s -m 8 -o /dev/null "$u/health"; rc=$?; echo "$rc $(( ($(date +%%s%%N) - t) / 1000000 ))"; done > "%s/dead"\n' \
        "$MARKS" > "$R/afd/tests/test-afd-deadprobe.sh"
    run_runner deadprobe
    local seen fast; seen=$(cat "$MARKS/dead" 2>/dev/null)
    fast=$(awk '$1 != 0 && $1 != 28 && $2 < 3000 {n++} END {print n + 0}' <<<"$seen")
    echo "    measured (curl rc, ms): $(tr '\n' ';' <<<"$seen")"
    assert_eq "0" "$RC" "probe run passes (output: $OUT)"
    assert_eq "2" "$fast" "both dead URLs fail at once (refused, not a timeout)"
}

test_missing_node_modules_names_install_command() {
    # A default run on a machine without afd/server/node_modules stays a failure, and says exactly
    # which one command installs them
    mk_tree
    rm -rf "$R/afd/server/node_modules"
    run_runner okay
    assert_eq "1" "$RC" "no node_modules → exit 1, never a silent skip (output: $OUT)"
    assert_contains "$OUT" "afd/server/node_modules is not installed" "the gap is named"
    assert_contains "$OUT" "fix: npm ci --prefix $R/afd/server" "the one-line install command, with this tree's path"
    assert_contains "$OUT" "- afd-deps" "listed as a failure"
}

# _unbounded_curls FILE... — "file:line" of every curl invocation (curl followed by an option) that
# carries neither -m/--max-time nor a `timeout` wrapper
_unbounded_curls() {
    local f
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        awk -v f="$(basename "$f")" '/^[[:space:]]*#/ {next}
            /(^|[^[:alnum:]_.\/-])curl[[:space:]]+-/ && !/(-m [0-9]|--max-time|timeout [0-9])/ {printf " %s:%d", f, FNR}' "$f"
    done
}

test_real_suites_bound_every_curl() {
    local bad f files=()
    for f in "$REPO_ROOT"/afd/tests/test-*.sh; do [[ "$(basename "$f")" == test-cc-invoke.sh ]] || files+=("$f"); done
    files+=("$REPO_ROOT"/setup/tests/test-lease-run.sh "$REPO_ROOT"/setup/tests/test-tmux-launch*.sh "$REPO_ROOT"/setup/tests/lib-afd-test-guard.sh)
    bad=$(_unbounded_curls "${files[@]}")
    assert_eq "" "$bad" "every curl in the AFD suites and the AFD-server setup suites is bounded (-m): a connect to a closed 127.0.0.1 port hangs on WSL"
}

test_real_suites_start_servers_on_loopback() {
    # Every repo-layout AFD server a suite starts is told AFD_BIND_HOST=127.0.0.1 (the live-layout
    # fixtures the deploy proofs run predate the variable and ignore it)
    local bad
    bad=$(awk '/^[[:space:]]*#/ {next}
        /AFD_PORT=[^ ]/ && !/printf/ {buf = $0; ln = FNR; while (buf ~ /\\$/ && (getline nxt) > 0) buf = buf nxt
            if (buf ~ /node / && buf !~ /AFD_BIND_HOST=127\.0\.0\.1/) printf " %s:%d", FILENAME, ln}' \
        "$REPO_ROOT"/afd/tests/test-*.sh)
    assert_eq "" "${bad//$REPO_ROOT\//}" "every AFD server start in afd/tests sets AFD_BIND_HOST=127.0.0.1"
}

# Run without node: these select no afd suite, or simulate node's absence themselves
run_test "a mistyped option is rejected, not taken as the pattern" test_unknown_option_is_rejected
run_test "a second pattern is rejected" test_second_pattern_is_rejected
run_test "a pattern that selects nothing fails" test_pattern_matching_nothing_fails
run_test "only the excluded suite selected fails, saying so" test_only_excluded_suite_selected_fails
run_test "the exclusion cites CFG-379 and names no personal host" test_exclusion_text_cites_backlog_and_no_personal_hosts
run_test "setup failures and --e2e work without node" test_setup_failure_reported_without_node
run_test "--no-afd skips afd suites explicitly" test_no_afd_flag_skips_afd_explicitly
run_test "node missing from PATH fails once as afd-deps" test_node_missing_fails_as_afd_deps
if [[ -d "$REPO_ROOT/afd/tests" ]]; then
    run_test "the guarded port range covers every port the afd suites use" test_runner_port_range_covers_afd_suite_ports
    run_test "every curl in the AFD suites and AFD-server setup suites is bounded by -m" test_real_suites_bound_every_curl
    run_test "every AFD server start in afd/tests binds loopback only" test_real_suites_start_servers_on_loopback
else
    skip_test "guarded port range, bounded curls, loopback servers in afd/tests" "no afd/tests in this tree"
fi

if need_node; then
    run_test "default run: setup + afd .sh + afd .js, e2e excluded" test_default_runs_setup_and_afd
    run_test "a failing afd .sh suite fails the run" test_failing_afd_sh_fails_the_run
    run_test "a failing afd .js suite fails the run" test_failing_afd_js_fails_the_run
    run_test "a failing setup suite is still reported" test_setup_failure_still_reported
    run_test "the pattern filters afd suites too" test_pattern_filters_afd_suites
    run_test "pattern afd/ selects only afd suites" test_pattern_afd_prefix_selects_only_afd
    run_test "test-cc-invoke.sh is excluded, with its reason printed" test_excluded_suite_never_runs_and_is_printed
    run_test "afd suites get no live credentials and a sandbox HOME" test_afd_suites_get_no_live_credentials
    run_test "node output in afd suites stays clean under NO_COLOR + FORCE_COLOR" test_afd_node_output_stays_clean_under_no_color
    run_test "missing afd deps fail the run loudly" test_missing_afd_deps_fails_loudly
    run_test "the deps check stays clean under FORCE_COLOR + NO_COLOR" test_afd_deps_check_clean_under_force_color
    run_test "--e2e still works alongside afd suites" test_e2e_flag_still_works
    run_test "a listener already on a test port fails the afd suites, never green" test_foreign_listener_blocks_afd_suites
    run_test "a test port that frees within the wait lets the suites run" test_port_freed_within_wait_runs_suite
    run_test "the AFD test lock held elsewhere fails the afd suites loudly" test_afd_lock_held_elsewhere_fails_loudly
    run_test "an afd suite runs under the lock without inheriting it" test_suite_runs_under_lock_without_inheriting_it
    run_test "two overlapping runs take turns on the afd suites" test_overlapping_runs_take_turns
    run_test "afd suites get an allowlisted environment only" test_afd_suites_get_an_allowlisted_env
    run_test "an unparseable package.json fails once as afd-deps" test_unreadable_package_json_fails_as_afd_deps
    run_test "a dependency that does not load fails once as afd-deps" test_dependency_that_does_not_load_fails_once
    run_test "better-sqlite3's native binding is opened, not just required" test_better_sqlite3_binding_is_opened
    run_test "node older than 18 fails once as afd-deps" test_node_older_than_18_fails_once
    run_test "after one lock timeout the remaining afd suites fail at once" test_lock_timeout_fails_the_rest_fast
    run_test "flock missing and an unopenable lock file are reported as such" test_lock_causes_are_distinct
    run_test "the dead AFD_URL / AFD_TELEGRAM_API refuse at once instead of hanging" test_dead_afd_url_refuses_fast
    run_test "no afd/server/node_modules: afd-deps names the exact install command" test_missing_node_modules_names_install_command
    if git --version >/dev/null 2>&1; then
        run_test "a git worktree borrows the main worktree's afd node_modules" test_worktree_borrows_main_node_modules
        run_test "a worktree with another package-lock.json does not borrow" test_worktree_with_other_lockfile_does_not_borrow
    else
        skip_test "worktree node_modules fallback" "git not on PATH"
    fi
    if [[ -d "$REPO_ROOT/afd/tests" ]]; then
        run_test "the real afd .js suites are ES modules by declaration" test_real_afd_js_suites_declare_esm
    else
        skip_test "afd .js suites declare ESM" "no afd/tests in this tree"
    fi
else
    skip_test "run.sh afd-phase tests" "node not on PATH — the afd .js suites, the deps check and the port probe need it"
fi

suite_summary
