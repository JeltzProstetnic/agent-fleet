#!/usr/bin/env bash
# CFG-468 — session-lock MUTEX FAILURE regression tests.
#
# Root cause: the mutex's only liveness signal was a single recorded PID checked
# with kill -0. That PID is frequently the EPHEMERAL SessionStart hook process,
# so the lock "goes stale" seconds after it is written and the next session
# cleans it and becomes a SECOND leader — while the first session is still live.
# Nothing ever checked for an actually-live Claude Code process in the project.
#
# These tests drive the fix: liveness must be keyed on a live CC process cwd'd in
# the project (independent of the recorded PID), and it must FAIL OPEN so a solo
# session is NEVER blocked. A fake "CC" process is simulated via _CC_PROC_RE
# (cmdline regex) so the tests are deterministic; _CC_SELF_PID injects the
# session's own pid to exclude.
source "$(dirname "$0")/test-helpers.sh"

LOCK_LIB="$REPO_ROOT/setup/scripts/session-lock.sh"
suite_header "session-lock liveness / double-leader mutex (CFG-468)"

# Spawn a process whose cmdline matches _CC_PROC_RE=sleep and whose cwd == $1.
# Echoes its pid. Caller must kill it. Child fds are redirected to /dev/null so
# it does NOT hold the command-substitution pipe open (that would block $(...)
# until the sleep exits); then poll until it has really exec'd with cwd==dir.
#
# NOTE (CFG-468 descendant exclusion): this spawns a DIRECT CHILD of the test
# shell, so relative to self=$$ it is a DESCENDANT, not a foreign session. That
# is exactly the shape of the real defect (CC spawns a child for the Bash tool
# call that runs rotate-session.sh, and the guard counted it as a rival). Use
# _spawn_foreign_cc when a test needs a genuinely foreign live session.
_spawn_fake_cc() {
    local dir="$1"
    ( cd "$dir" && exec sleep 20 ) </dev/null >/dev/null 2>&1 &
    local pid=$! i real
    real="$(realpath "$dir" 2>/dev/null || echo "$dir")"
    for i in $(seq 1 20); do
        if [[ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" == "$real" ]] \
           && grep -qa sleep "/proc/$pid/cmdline" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
    echo "$pid"
}

# Same, but detached via setsid so the process is reparented away from the test
# shell — i.e. genuinely NOT a descendant of $$, which is what "a rival session"
# actually looks like. Echoes the pid of the spawned sleep (found by cwd match,
# because setsid forks and $! is the setsid wrapper, not the sleep).
_spawn_foreign_cc() {
    local dir="$1" real i p
    real="$(realpath "$dir" 2>/dev/null || echo "$dir")"
    setsid sh -c "cd '$dir' && exec sleep 20" </dev/null >/dev/null 2>&1 &
    for i in $(seq 1 30); do
        for p in $(pgrep -x sleep 2>/dev/null); do
            if [[ "$(readlink "/proc/$p/cwd" 2>/dev/null)" == "$real" ]]; then
                echo "$p"; return 0
            fi
        done
        sleep 0.1
    done
    return 1
}

# ── check_lock: dead recorded PID + live foreign CC ⇒ LOCKED (rc 2) ──────────
test_checklock_deadpid_livecc_is_locked() {
    source "$LOCK_LIB"
    local D="$TEST_TMPDIR/cl1"; mkdir -p "$D/.claude"
    local host; host="$(hostname 2>/dev/null || cat /etc/hostname)"
    # Lock records a DEAD pid (the ephemeral-hook bug), on THIS machine.
    printf '{"machine":"%s","pid":999999,"sessionId":"inc","timestamp":"2026-07-24T00:00:00Z","user":"x","ccSessionId":"cc-inc"}\n' "$host" > "$D/.claude/.session-lock"
    local fake; fake="$(_spawn_foreign_cc "$D")"
    _CC_PROC_RE='sleep'
    check_lock "$D" "$$"; local rc=$?   # self=$$ (not the fake) → fake is a foreign live CC
    kill "$fake" 2>/dev/null
    assert_eq "2" "$rc" "dead recorded pid but a live CC in the project ⇒ locked (rc 2)"
}
run_test "check_lock: dead pid + live foreign CC ⇒ locked" test_checklock_deadpid_livecc_is_locked

# ── check_lock must NOT delete the lock when a live foreign CC is present ─────
test_checklock_deadpid_livecc_preserves_lock() {
    source "$LOCK_LIB"
    local D="$TEST_TMPDIR/cl2"; mkdir -p "$D/.claude"
    local host; host="$(hostname 2>/dev/null || cat /etc/hostname)"
    printf '{"machine":"%s","pid":999999,"sessionId":"inc","timestamp":"2026-07-24T00:00:00Z","user":"x","ccSessionId":"cc-inc"}\n' "$host" > "$D/.claude/.session-lock"
    local fake; fake="$(_spawn_foreign_cc "$D")"
    _CC_PROC_RE='sleep'
    check_lock "$D" "$$" >/dev/null 2>&1
    kill "$fake" 2>/dev/null
    assert_eq "yes" "$([ -f "$D/.claude/.session-lock" ] && echo yes || echo no)" "live-session lock is NOT auto-cleaned"
}
run_test "check_lock: does not clean a live session's lock" test_checklock_deadpid_livecc_preserves_lock

# ── FAIL-OPEN regression: solo session (no foreign CC) ⇒ free (rc 0) ──────────
test_checklock_solo_is_free() {
    source "$LOCK_LIB"
    local D="$TEST_TMPDIR/cl3"; mkdir -p "$D/.claude"
    local host; host="$(hostname 2>/dev/null || cat /etc/hostname)"
    printf '{"machine":"%s","pid":999999,"sessionId":"old","timestamp":"2026-07-24T00:00:00Z","user":"x","ccSessionId":"cc-old"}\n' "$host" > "$D/.claude/.session-lock"
    _CC_PROC_RE='sleep'   # no fake spawned → no live CC in project
    check_lock "$D" "$$"; local rc=$?
    assert_eq "0" "$rc" "dead pid + NO live CC ⇒ genuinely stale, free (rc 0)"
}
run_test "check_lock: solo dead-pid lock ⇒ free (fail-open)" test_checklock_solo_is_free

# ── LOCKOUT-SAFETY: unresolvable self ⇒ never self-block (rc 0), even with CC ─
test_checklock_unresolvable_self_fails_open() {
    source "$LOCK_LIB"
    local D="$TEST_TMPDIR/cl4"; mkdir -p "$D/.claude"
    local host; host="$(hostname 2>/dev/null || cat /etc/hostname)"
    printf '{"machine":"%s","pid":999999,"sessionId":"x","timestamp":"2026-07-24T00:00:00Z","user":"x","ccSessionId":"cc-x"}\n' "$host" > "$D/.claude/.session-lock"
    local fake; fake="$(_spawn_foreign_cc "$D")"
    _CC_PROC_RE='sleep'
    check_lock "$D" ""; local rc=$?   # empty self ⇒ cannot distinguish self from other ⇒ fail OPEN
    kill "$fake" 2>/dev/null
    assert_eq "0" "$rc" "empty self-pid ⇒ fail open, never self-block (rc 0)"
}
run_test "check_lock: unresolvable self ⇒ fail open (no lockout)" test_checklock_unresolvable_self_fails_open

# ── acquire_lock: refuse to steal a stale lock when a live CC is in project ───
test_acquire_refuses_when_live_cc_present() {
    source "$LOCK_LIB"
    local D="$TEST_TMPDIR/aq1"; mkdir -p "$D/.claude"
    local host; host="$(hostname 2>/dev/null || cat /etc/hostname)"
    printf '{"machine":"%s","pid":999999,"sessionId":"inc","timestamp":"2026-07-24T00:00:00Z","user":"x","ccSessionId":"cc-inc"}\n' "$host" > "$D/.claude/.session-lock"
    local fake; fake="$(_spawn_foreign_cc "$D")"
    _CC_PROC_RE='sleep'
    acquire_lock "$D" "newsess" "" "$$" >/dev/null 2>&1; local rc=$?   # self=$$ (afleet pre-launch style)
    kill "$fake" 2>/dev/null
    assert_eq "1" "$rc" "acquire refuses to steal a stale lock while a live CC is in the project"
}
run_test "acquire_lock: refuses while a live foreign CC is active" test_acquire_refuses_when_live_cc_present

# ── acquire_lock: solo (no foreign CC) still acquires (fail-open regression) ──
test_acquire_solo_succeeds() {
    source "$LOCK_LIB"
    local D="$TEST_TMPDIR/aq2"; mkdir -p "$D/.claude"
    _CC_PROC_RE='sleep'   # no fake → solo
    acquire_lock "$D" "solosess" "" "$$" >/dev/null 2>&1; local rc=$?
    assert_eq "0" "$rc" "solo acquire succeeds (never blocked)"
}
run_test "acquire_lock: solo still acquires" test_acquire_solo_succeeds

# ── CFG-468 residual: DESCENDANT EXCLUSION ────────────────────────────────────
# _project_has_live_cc excluded only the exact self pid and never walked the
# process tree, so a session's OWN child tripped its OWN guard. This is not
# hypothetical: every leader shutdown invokes rotate-session.sh through a Bash
# tool call, CC spawns a child for that call, and the child is a CC process
# cwd'd in the project (observed 2026-08-07: pid 3113046, ppid = the session's
# own CC pid, age 0s). The guard was therefore self-tripping BY CONSTRUCTION,
# which is why --owner-verified read as always-required — a bypass habit trained
# by a guard that was never protecting anything.
#
# Stubbed tree used below (no real processes, so the walk itself is asserted):
#   100 leader-CC → 200 bash-tool-call → 300 child-CC     (300 is 100's grandchild)
#   900 rival-CC  → parent 1                              (genuinely foreign)
_cfg468_stub_tree() {
    _ppid_of()      { case "$1" in 300) echo 200;; 200) echo 100;; 100) echo 1;; 900) echo 1;; *) echo "";; esac; }
    _pid_is_cc()    { case "$1" in 100|300|900) return 0;; *) return 1;; esac; }
    _pid_cwd()      { case "$1" in 100|300|900) echo "$_STUB_DIR";; *) return 1;; esac; }
}

# Enumerate a fixed pid set instead of /proc, so the stub tree is the whole world.
_cfg468_stub_scan() { _enumerate_pids() { printf '%s\n' 100 200 300 900; }; }

test_cfg468_direct_child_not_a_competitor() {
    source "$LOCK_LIB"; _cfg468_stub_tree; _cfg468_stub_scan
    local _STUB_DIR="$TEST_TMPDIR/d1"; mkdir -p "$_STUB_DIR"
    _ppid_of() { case "$1" in 300) echo 100;; 100) echo 1;; 900) echo 1;; *) echo "";; esac; }
    _enumerate_pids() { printf '%s\n' 100 300; }   # only self and its direct child
    local rc=0; _project_has_live_cc "$_STUB_DIR" 100 || rc=$?
    assert_eq "1" "$rc" "self's DIRECT child CC is not a competitor"
}
run_test "CFG-468: direct child of self is excluded" test_cfg468_direct_child_not_a_competitor

test_cfg468_grandchild_not_a_competitor() {
    source "$LOCK_LIB"; _cfg468_stub_tree
    local _STUB_DIR="$TEST_TMPDIR/d2"; mkdir -p "$_STUB_DIR"
    _enumerate_pids() { printf '%s\n' 100 200 300; }   # self, its bash child, its CC grandchild
    local rc=0; _project_has_live_cc "$_STUB_DIR" 100 || rc=$?
    assert_eq "1" "$rc" "self's GRANDCHILD CC (via the Bash tool call) is not a competitor"
}
run_test "CFG-468: grandchild of self is excluded" test_cfg468_grandchild_not_a_competitor

test_cfg468_foreign_still_detected() {
    source "$LOCK_LIB"; _cfg468_stub_tree
    local _STUB_DIR="$TEST_TMPDIR/d3"; mkdir -p "$_STUB_DIR"
    _enumerate_pids() { printf '%s\n' 100 200 300 900; }   # 900 is NOT under 100
    local rc=0; _project_has_live_cc "$_STUB_DIR" 100 || rc=$?
    assert_eq "0" "$rc" "a rival CC that is not a descendant is STILL detected"
}
run_test "CFG-468: non-descendant rival still detected" test_cfg468_foreign_still_detected

test_cfg468_ppid_cycle_terminates() {
    source "$LOCK_LIB"
    local _STUB_DIR="$TEST_TMPDIR/d4"; mkdir -p "$_STUB_DIR"
    # A corrupt/racing ppid readout that cycles must not hang the walk.
    _ppid_of()       { case "$1" in 300) echo 400;; 400) echo 300;; *) echo "";; esac; }
    _pid_is_cc()     { case "$1" in 300) return 0;; *) return 1;; esac; }
    _pid_cwd()       { echo "$_STUB_DIR"; }
    _enumerate_pids() { printf '%s\n' 300; }
    local rc=0
    timeout 10 bash -c 'true' >/dev/null 2>&1   # sanity: timeout available
    _project_has_live_cc "$_STUB_DIR" 100 || rc=$?
    assert_eq "0" "$rc" "a ppid cycle terminates and the pid is treated as foreign (fail closed on the mutex, not a hang)"
}
run_test "CFG-468: ppid cycle terminates the ancestry walk" test_cfg468_ppid_cycle_terminates

# ── The live 2026-08-07 failure, end to end, with real processes ──────────────
# No lock file at all + self's own child CC in the project ⇒ must read FREE.
# Before the fix this returned 2 (locked), which is what blocked every leader
# shutdown on the documented bare rotate-session.sh command.
test_cfg468_checklock_own_child_reads_free() {
    source "$LOCK_LIB"
    local D="$TEST_TMPDIR/oc1"; mkdir -p "$D/.claude"   # no lock file written
    # Spawn INLINE, not via $(...): a command substitution's subshell exits
    # immediately, which orphans the background job and gets it reparented away
    # from this shell — it would then no longer be a descendant, and the test
    # would silently stop testing what it claims to.
    ( cd "$D" && exec sleep 20 ) </dev/null >/dev/null 2>&1 &
    local fake=$! i real rc
    real="$(realpath "$D" 2>/dev/null || echo "$D")"
    for i in $(seq 1 20); do
        [[ "$(readlink "/proc/$fake/cwd" 2>/dev/null)" == "$real" ]] && break
        sleep 0.1
    done
    # Guard the premise itself: if it is not really our child, the assertion below
    # would pass for the wrong reason.
    assert_eq "$BASHPID" "$(awk '{print $4}' "/proc/$fake/stat" 2>/dev/null)" \
        "premise: the spawned CC really is a direct child of this shell" || { kill "$fake" 2>/dev/null; return 1; }
    _CC_PROC_RE='sleep'
    check_lock "$D" "$BASHPID"; rc=$?
    kill "$fake" 2>/dev/null
    assert_eq "0" "$rc" "no lock + only self's own child in the project ⇒ free (rc 0)"
}
run_test "CFG-468: check_lock ignores self's own child (live repro)" test_cfg468_checklock_own_child_reads_free
