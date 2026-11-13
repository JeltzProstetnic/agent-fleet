#!/usr/bin/env bash
# Test runner — discovers and runs the repo's test suites:
#   setup/tests/test-*.sh                  bash
#   afd/tests/test-*.sh, afd/tests/test-*.js   bash / node (CFG-1003: before it, the full suite never
#       ran afd/tests/, and an AFD server change broke two AFD deploy proofs while run.sh said 257/258)
# Usage: bash setup/tests/run.sh [pattern] [--e2e] [--no-afd]
#   pattern:  optional substring filter. Setup suites match on their file name (e.g. "rotate" matches
#             test-rotate*.sh); AFD suites match on "afd/<file>", so "afd/" selects exactly the AFD suites.
#             A run that selects no suite FAILS (exit 1); an unknown option or a second pattern exits 2.
#   --e2e:    include E2E tests (test-e2e-*.sh) — these spawn real Claude Code sessions
#             and consume API credits. Excluded by default. Use only in VM/controlled environments.
#   --no-afd: skip the AFD suites, saying so. Without it, AFD suites that cannot run here (node missing
#             or older than 18, afd/server/node_modules missing or not loading) FAIL the run once as
#             "afd-deps" — a silent skip is exactly how AFD breakage went unnoticed. The message names
#             the fix as one command (npm ci --prefix <this tree>/afd/server). A linked git worktree
#             without an install borrows the main worktree's.
# AFD-phase knobs, never passed to an AFD suite (lib-afd-test-guard.sh reads the first three, and so do
# the setup suites that start their own AFD server through it — one lock for all of them):
#   RUN_AFD_LOCK / RUN_AFD_LOCK_WAIT  machine-wide lock serialising AFD suites and test servers across
#                                     overlapping runs (default /tmp/afd-test-ports.lock, wait 1800 s;
#                                     after one timeout the remaining AFD suites fail at once)
#   RUN_AFD_PORTS / RUN_AFD_PORT_WAIT loopback ports the AFD suites bind, LO-HI; a suite runs only when
#                                     nothing answers on any of them (default 19870-19939, wait 10 s)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AFD_DIR="$REPO_ROOT/afd"
# shellcheck source=lib-afd-test-guard.sh
source "$SCRIPT_DIR/lib-afd-test-guard.sh"
AFD_GUARD_OWNER="$REPO_ROOT"

# AFD suites that are NOT hermetic and therefore never run here ("file|reason", printed when the
# pattern would select them). Every other AFD suite was read for CFG-1003 and talks only to loopback
# servers, mock Telegram/ntfy endpoints and fake ssh/scp/systemctl on PATH.
AFD_EXCLUDED=(
    "test-cc-invoke.sh|not hermetic: the gate in cc-invoke.sh makes a real ssh call and an HTTP call to another LAN host, neither faked by the suite (ssh reads ~/.ssh from the passwd entry, not \$HOME), and it writes shared files under /tmp — making it hermetic is tracked as CFG-379"
)
# Live-service guard for AFD suites. Each suite starts from an EMPTY environment plus the allowlist
# below, never a denylist: caller-exported test knobs got through one (AFD_SERVER_DIR=<other tree> made
# the suites test another tree's server, and the gate went green on a broken one). So no inherited
# Telegram/ntfy credential, AFD token, NODE_OPTIONS or FORCE_COLOR reaches a suite. FORCE_COLOR
# mattered: Claude Code's Bash exports FORCE_COLOR=1, and with it node colours console.log values
# and — next to NO_COLOR=1 — warns on stderr, which broke the suites that parse `afd messages 2>&1`.
# On top: AFD_URL and AFD_TELEGRAM_API at a dead loopback port (an UNSET AFD_URL falls back to the
# live daemon in client/afd and lib/afd-lib.sh) and a throwaway HOME, so the real ~/.afd-env (live
# URL + token) can neither be read nor written. The dead port is on ::1, not 127.0.0.1: under WSL
# mirrored networking a connect to a closed 127.0.0.1 port HANGS instead of being refused (measured
# 2026-11-13), so a stray call to 127.0.0.1:9 hung the gate; ::1 refuses at once (fails at once where
# IPv6 is off). AFD_BIND_HOST=127.0.0.1 keeps every server a suite starts off the LAN.
AFD_ENV_KEEP=(PATH TMPDIR LANG LC_ALL LC_CTYPE TZ USER LOGNAME TERM)
AFD_DEAD_URL="http://[::1]:9"
AFD_MIN_NODE=18   # the AFD server calls the global fetch (notify.js, telegram.js)
# Overlapping runs share the suites' fixed loopback ports and tokens (several worktrees at once is the
# workflow harness's normal mode). A server already on 19879 answered this run's /health polls, and a
# suite that only polls /health passed against it — a broken AFD server was reported green. So every
# AFD suite runs under one machine-wide lock (lib-afd-test-guard.sh), and only once nothing answers on
# the guarded ports.
AFD_PORT_WAIT="${RUN_AFD_PORT_WAIT:-10}"
AFD_LOCK_FAILED=""   # why the lock could not be taken; set once, then the remaining AFD suites fail at once

# Colors
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BOLD='' RESET=''
fi

# usage_error MESSAGE — a run that cannot mean what it says exits 2 before running anything
usage_error() {
    printf "%s\nUsage: bash setup/tests/run.sh [pattern] [--e2e] [--no-afd]\n" "$1" >&2
    exit 2
}

PATTERN=""
INCLUDE_E2E=false
INCLUDE_AFD=true
for arg in "$@"; do
    case "$arg" in
        --e2e) INCLUDE_E2E=true ;;
        --no-afd) INCLUDE_AFD=false ;;
        -*) usage_error "unknown option '$arg'" ;;
        *) [[ -z "$PATTERN" ]] || usage_error "one pattern only (got '$PATTERN' and '$arg')"
           PATTERN="$arg" ;;
    esac
done
if [[ ! "$AFD_GUARD_PORTS" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] \
   || (( 10#${BASH_REMATCH[1]} > 10#${BASH_REMATCH[2]} || 10#${BASH_REMATCH[2]} > 65535 )); then
    usage_error "RUN_AFD_PORTS must be LO-HI with LO <= HI <= 65535 (got '$AFD_GUARD_PORTS')"
fi
TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
FAILED_NAMES=()
EXCLUDED_COUNT=0
SETUP_FILES=()
AFD_FILES=()

# selected NAME — no pattern, or NAME contains it
selected() {
    [[ -z "$PATTERN" || "$1" == *"$PATTERN"* ]]
}

discover_setup() {
    local f b
    for f in "$SCRIPT_DIR"/test-*.sh; do
        [[ -f "$f" ]] || continue
        b="$(basename "$f")"
        # Skip E2E tests unless --e2e flag is passed (they spawn real Claude sessions)
        [[ "$INCLUDE_E2E" == "false" && "$b" == test-e2e-* ]] && continue
        selected "$b" || continue
        SETUP_FILES+=("$f")
    done
}

# afd_exclusion_reason FILE — the stated reason FILE is excluded, empty when it is not
afd_exclusion_reason() {
    local e
    for e in "${AFD_EXCLUDED[@]}"; do
        if [[ "${e%%|*}" == "$1" ]]; then printf '%s' "${e#*|}"; return 0; fi
    done
}

discover_afd() {
    local f b reason
    for f in "$AFD_DIR"/tests/test-*.sh "$AFD_DIR"/tests/test-*.js; do
        [[ -f "$f" ]] || continue
        b="$(basename "$f")"
        selected "afd/$b" || continue
        reason="$(afd_exclusion_reason "$b")"
        if [[ -n "$reason" ]]; then
            printf "${YELLOW}EXCLUDED afd/%s — %s${RESET}\n" "$b" "$reason"
            ((EXCLUDED_COUNT++)) || true
            continue
        fi
        AFD_FILES+=("$f")
    done
}

# fail_suite NAME — count NAME as a failed suite
fail_suite() {
    ((TOTAL_SUITES++)) || true
    ((FAILED_SUITES++)) || true
    FAILED_NAMES+=("$1")
}

# afd_deps_problem — why the AFD suites cannot run on this machine; prints nothing when they can.
# node must be on PATH and >= AFD_MIN_NODE, and every afd/server dependency installed AND loadable:
# a native binding built for another Node ABI passes a presence check and then fails some 20 suites
# one by one. better-sqlite3 binds only in new Database(), so it is opened in memory. stderr is
# discarded (a failing node falls through to the echo). The runner's own node calls go through
# afd_guard_node (lib-afd-test-guard.sh): the caller's PATH and nothing else.
afd_deps_problem() {
    local pkg="$AFD_DIR/server/package.json" v
    if ! command -v node >/dev/null 2>&1; then echo "node is not on PATH"; return 0; fi
    v="$(afd_guard_node --version 2>/dev/null)" || v=""
    if [[ ! "$v" =~ ^v([0-9]+)\. ]]; then echo "could not read the node version ('$v')"; return 0; fi
    if (( BASH_REMATCH[1] < AFD_MIN_NODE )); then
        echo "node $v is older than $AFD_MIN_NODE (the AFD server uses the global fetch)"; return 0
    fi
    [[ -f "$pkg" ]] || return 0
    if [[ ! -d "$AFD_DIR/server/node_modules" ]]; then echo "afd/server/node_modules is not installed"; return 0; fi
    afd_guard_node -e '
const fs = require("fs"), path = require("path");
const [pkg, nm] = process.argv.slice(1);
const deps = Object.keys(JSON.parse(fs.readFileSync(pkg, "utf8")).dependencies || {});
const missing = deps.filter(d => !fs.existsSync(path.join(nm, d, "package.json")));
if (missing.length) { console.log("missing from afd/server/node_modules: " + missing.join(", ")); process.exit(0); }
for (const d of deps) {
  try {
    const m = require(path.join(nm, d));
    if (d === "better-sqlite3") new m(":memory:").close();
  } catch (e) {
    if (e.code === "ERR_REQUIRE_ESM") continue;
    console.log(d + " does not load: " + String(e.message).split("\n")[0]);
    process.exit(0);
  }
}
' "$pkg" "$AFD_DIR/server/node_modules" 2>/dev/null || echo "could not read $pkg"
}

# afd_borrow_main_install — afd/server/node_modules is gitignored, so a linked git worktree never has
# one: link the main worktree's install, when both trees have the same package-lock.json (or
# package.json, without a lockfile). Prints what it did, or why it did not.
afd_borrow_main_install() {
    local nm="$AFD_DIR/server/node_modules" common main lock=package-lock.json
    [[ -e "$nm" || -L "$nm" ]] && return 0
    common="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)" || return 0
    [[ "$common" == /* ]] || common="$REPO_ROOT/$common"
    [[ "$(basename "$common")" == .git ]] || return 0
    main="$(cd "$(dirname "$common")" && pwd -P)"
    [[ "$main" != "$(cd "$REPO_ROOT" && pwd -P)" && -d "$main/afd/server/node_modules" ]] || return 0
    [[ -f "$AFD_DIR/server/$lock" ]] || lock=package.json
    if ! cmp -s "$AFD_DIR/server/$lock" "$main/afd/server/$lock"; then
        printf "${YELLOW}not borrowing %s/afd/server/node_modules: its %s differs from this worktree's${RESET}\n" "$main" "$lock"
        return 0
    fi
    ln -s "$main/afd/server/node_modules" "$nm" || return 0
    printf "${YELLOW}linked afd/server/node_modules -> %s/afd/server/node_modules (git worktree without its own install)${RESET}\n" "$main"
}

# check_afd_deps — turns missing AFD dependencies into ONE failure ("afd-deps") instead of a run
# of identical ERR_MODULE_NOT_FOUND failures, or a silent skip
check_afd_deps() {
    [[ ${#AFD_FILES[@]} -gt 0 ]] || return 0
    local problem fix
    afd_borrow_main_install || true
    problem="$(afd_deps_problem)"
    [[ -z "$problem" ]] && return 0
    # the fix as ONE command that works from any directory; node itself is the platform's to install
    fix="npm ci --prefix $(printf '%q' "$AFD_DIR/server")"
    [[ "$problem" == node* || "$problem" == *"node version"* ]] && fix="install Node.js >= $AFD_MIN_NODE and put it on PATH"
    printf "${RED}AFD suites NOT run (%d): %s — fix: %s" "${#AFD_FILES[@]}" "$problem" "$fix"
    printf " (or pass --no-afd to skip them on purpose)${RESET}\n"
    fail_suite "afd-deps"
    AFD_FILES=()
}

# afd_ports_taken — waits up to AFD_PORT_WAIT s for the guarded ports to be free (the previous suite's
# server may still be exiting); prints the ones still taken, nothing once all are free. The probe
# (afd_guard_busy_ports) connects to each port with a 1 s bound.
afd_ports_taken() {
    local busy deadline=$((SECONDS + AFD_PORT_WAIT))
    while :; do
        busy="$(afd_guard_busy_ports)" || busy="(the port probe failed)"
        [[ -z "$busy" || $SECONDS -ge $deadline ]] && break
        sleep 0.5
    done
    printf '%s' "$busy"
}

printf "${BOLD}cfg-agent-fleet test runner${RESET}\n"
printf "Repo: %s\n\n" "$REPO_ROOT"

discover_setup
if [[ "$INCLUDE_AFD" == "true" ]]; then
    discover_afd
    check_afd_deps
else
    printf "${YELLOW}AFD suites skipped: --no-afd${RESET}\n"
fi

# Running nothing is not a pass: a mistyped pattern, or one that selects only an excluded suite,
# used to print a notice and exit 0 — a green gate that tested nothing.
if [[ ${#SETUP_FILES[@]} -eq 0 && ${#AFD_FILES[@]} -eq 0 && $TOTAL_SUITES -eq 0 ]]; then
    if [[ $EXCLUDED_COUNT -gt 0 ]]; then
        printf "${RED}No test suites ran: only excluded suites match '%s' (see EXCLUDED above)${RESET}\n" "$PATTERN"
    elif [[ -n "$PATTERN" ]]; then
        printf "${RED}No test suites ran: none matches '%s'${RESET}\n" "$PATTERN"
    else
        printf "${RED}No test suites ran: no test files found${RESET}\n"
    fi
    exit 1
fi

printf "Found %d test suite(s) (%d setup, %d afd)\n\n" \
    "$(( ${#SETUP_FILES[@]} + ${#AFD_FILES[@]} ))" "${#SETUP_FILES[@]}" "${#AFD_FILES[@]}"

# run_suite NAME CMD... — runs one suite and counts its verdict
run_suite() {
    local name="$1"; shift

    # Run in subshell to prevent env var leakage (test exports contaminated parent session).
    # stdin is /dev/null (CFG-474): a suite that inherits the caller's terminal and reads it
    # blocks forever, and only when a human runs the gate — every TTY-less runner sees EOF and
    # passes. That asymmetry cost this gate two separate indefinite hangs. Tests that need input
    # still pipe it into the specific command they are exercising.
    #
    # setsid (CFG-670) is the other half, and the third instance of that same asymmetry.
    # Closing stdin does NOT stop a `read -r x </dev/tty` — opening /dev/tty reaches the
    # CONTROLLING TERMINAL directly and ignores stdin entirely. afleet.sh prompts exactly that
    # way, by design, because its real caller is a human at a terminal. So the gate hung again
    # on 2026-09-21, this time launched through tmux-launch.sh, which CLAUDE.md MANDATES for
    # background commands: an empty log and a live tmux session, indistinguishable from a
    # long-running suite. A Claude Code Bash call has no controlling terminal, so the same
    # suite passed 166/166 and could not see the hang.
    # setsid puts each suite in a new session with NO controlling terminal, so opening
    # /dev/tty fails and the code takes its EOF path — the behaviour every runner already had,
    # now including the ones that own a terminal. --wait propagates the child's exit status.
    # The AFD test lock's fd ($AFD_GUARD_FD, once open) is closed first: a server a suite leaks must
    # not hold the lock.
    if ( if [[ -n "$AFD_GUARD_FD" ]]; then exec {AFD_GUARD_FD}>&-; fi; exec setsid --wait "$@" </dev/null ); then
        ((TOTAL_SUITES++)) || true
        ((PASSED_SUITES++)) || true
    else
        fail_suite "$name"
    fi
}

# afd_suite_env HOME — AFD_ENV: `env -i`, the allowlisted caller variables, then the guard values
afd_suite_env() {
    local v
    AFD_ENV=(env -i)
    for v in "${AFD_ENV_KEEP[@]}"; do
        if [[ -n "${!v+set}" ]]; then AFD_ENV+=("$v=${!v}"); fi
    done
    AFD_ENV+=(HOME="$1" AFD_URL="$AFD_DEAD_URL" AFD_TELEGRAM_API="$AFD_DEAD_URL" AFD_BIND_HOST=127.0.0.1)
}

# afd_suite_locked — the AFD test lock, or "NOT run" with its cause (no flock, lock file not openable,
# timeout). The first failure is remembered: every later suite fails at once instead of waiting
# RUN_AFD_LOCK_WAIT again (default 1800 s each).
afd_suite_locked() {
    if [[ -n "$AFD_LOCK_FAILED" ]]; then
        printf "${RED}NOT run: %s — not waited for again in this run${RESET}\n" "$AFD_LOCK_FAILED"
        return 1
    fi
    afd_guard_lock_take && return 0
    AFD_LOCK_FAILED="$AFD_GUARD_WHY"
    printf "${RED}NOT run: %s${RESET}\n" "$AFD_LOCK_FAILED"
    return 1
}

# run_afd_suite FILE — bash or node by extension, holding the AFD test lock, only once nothing answers
# on the guarded ports, in the allowlisted environment with a throwaway HOME removed afterwards
run_afd_suite() {
    local f="$1" b sandbox runner=bash busy
    b="$(basename "$f")"
    [[ "$f" == *.js ]] && runner=node
    printf "\n${BOLD}── afd/%s${RESET}\n" "$b"
    if ! afd_suite_locked; then
        fail_suite "afd/$b"
        return 0
    fi
    busy="$(afd_ports_taken)"
    if [[ -n "$busy" ]]; then
        printf "${RED}NOT run: something already answers on loopback port(s) %s, and it would answer this suite in place of its own server${RESET}\n" "$busy"
        fail_suite "afd/$b"
    else
        sandbox="$(mktemp -d "${TMPDIR:-/tmp}/afd-suite-home.XXXXXX")"
        afd_suite_env "$sandbox"
        run_suite "afd/$b" "${AFD_ENV[@]}" "$runner" "$f"
        rm -rf "$sandbox"
    fi
    afd_guard_lock_release
}

for test_file in ${SETUP_FILES[@]+"${SETUP_FILES[@]}"}; do
    run_suite "$(basename "$test_file" .sh)" bash "$test_file"
done
for test_file in ${AFD_FILES[@]+"${AFD_FILES[@]}"}; do
    run_afd_suite "$test_file"
done

# Final summary
printf "\n${BOLD}════════════════════════════════════${RESET}\n"
printf "${BOLD}Test Suites: %d total${RESET}\n" "$TOTAL_SUITES"
printf "  ${GREEN}Passed: %d${RESET}\n" "$PASSED_SUITES"
if [[ $EXCLUDED_COUNT -gt 0 ]]; then
    printf "  ${YELLOW}Excluded (not hermetic, see EXCLUDED above): %d${RESET}\n" "$EXCLUDED_COUNT"
fi
if [[ $FAILED_SUITES -gt 0 ]]; then
    printf "  ${RED}Failed: %d${RESET}\n" "$FAILED_SUITES"
    for name in "${FAILED_NAMES[@]}"; do
        printf "    ${RED}- %s${RESET}\n" "$name"
    done
    exit 1
fi
printf "\n${GREEN}All suites passed.${RESET}\n"
