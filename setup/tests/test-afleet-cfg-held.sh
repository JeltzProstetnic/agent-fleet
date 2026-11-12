#!/usr/bin/env bash
# Tests for setup/scripts/afleet-cfg-held.sh and its launcher wiring (CFG-977).
#
# The launcher's pre-launch `sync.sh deploy` copies the config repo's WORKING
# TREE to ~/.claude. While another live session holds that repo the tree is its
# in-progress work (2026-11-12 08:27: another project's launch deployed a live cfg
# session's uncommitted hook edits). The verdict is lib-cfg-held.sh's
# _cfg_held_check_lock, taken from a copy that cannot be mid-edit (HEAD first, the
# deployed copy second), asked as a NON-CC caller, read-only, fail-closed on a lock.
#
# Launcher tests drive the real afleet.sh, or AFLEET_UNDER_TEST (a copy whose
# directory holds its sibling scripts). Every launcher run has a stub mclaude and
# claude first on PATH: no test may ever reach a real Claude Code.
source "$(dirname "$0")/test-helpers.sh"

# AFLEET_CFG_HELD_UNDER_TEST: a copy of the module (e.g. a mutant) instead of the live one.
MOD="${AFLEET_CFG_HELD_UNDER_TEST:-$REPO_ROOT/setup/scripts/afleet-cfg-held.sh}"
LIB="$REPO_ROOT/global/hooks/lib-cfg-held.sh"
REAL_LOCK_LIB="$REPO_ROOT/setup/scripts/session-lock.sh"
AFLEET="${AFLEET_UNDER_TEST:-$REPO_ROOT/setup/scripts/afleet.sh}"
# Without afleet-lib.sh beside it the launcher falls back to exec'ing Claude Code.
if [[ ! -f "$(dirname "$AFLEET")/afleet-lib.sh" ]]; then
    echo "ABORT: $(dirname "$AFLEET") holds no afleet-lib.sh — the launcher under test would fall back to a real Claude Code" >&2
    exit 1
fi

suite_header "afleet-cfg-held.sh (CFG-977: no launch-time deploy of a held config repo)"

_host() { hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || uname -n; }

# A stub session-lock.sh for HEAD: check_lock answers <rc> and records what it saw.
_stub_lock_lib() {   # <rc>
    cat <<EOF
_cc_self_pid() { printf '%s' "\${_CC_SELF_PID-UNSET}"; }
_read_lock() {
    _LOCK_MACHINE=\$(sed -n 's/.*"machine":"\([^"]*\)".*/\1/p' "\$1")
    _LOCK_PID=\$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "\$1")
    [[ -n "\$_LOCK_MACHINE" ]]
}
check_lock() {
    printf 'self=%s ids=%s/%s/%s/%s\n' "\$(_cc_self_pid)" "\${CC_SESSION_ID:-}" "\${CLAUDE_CODE_SESSION_ID:-}" "\${CLAUDE_SESSION_ID:-}" "\${AFLEET_SESSION_ID:-}" >> "$TEST_TMPDIR/check_lock.calls"
    return $1
}
EOF
}

# The real session-lock.sh, with only "which pid is a Claude Code process, and its
# cwd" faked: the pid in $TEST_TMPDIR/fakecc.pid is a live session in <repo>.
_real_lock_lib_with_fake_cc() {   # <repo>
    cat "$REAL_LOCK_LIB"
    cat <<EOF
_FAKE_CC=\$(cat '$TEST_TMPDIR/fakecc.pid' 2>/dev/null)
_pid_is_cc() { [[ "\$1" == "\$_FAKE_CC" ]]; }
_pid_cwd() { if [[ "\$1" == "\$_FAKE_CC" ]]; then printf '%s' '$1'; else readlink "/proc/\$1/cwd" 2>/dev/null; fi; }
EOF
}

# A config repo whose HEAD carries <session-lock.sh body> and lib-cfg-held.sh
# (the real one unless [lib body] is given), with a sync.sh and git-sync-check.sh
# that only record their calls, and a registry with one pullable project (beta).
_mk_cfg() {   # <dir> <session-lock.sh body> [lib-cfg-held.sh body]
    local d="$1"
    mkdir -p "$d/global/hooks" "$d/setup/scripts" "$d/.claude" "$d/cross-project" "$HOME/beta"
    printf '%s\n' "$2" > "$d/setup/scripts/session-lock.sh"
    if [[ -n "${3:-}" ]]; then printf '%s\n' "$3" > "$d/global/hooks/lib-cfg-held.sh"
    else cp "$LIB" "$d/global/hooks/lib-cfg-held.sh"; fi
    printf '#!/usr/bin/env bash\n[[ "${1:-}" == deploy ]] && echo deploy >> "%s/deploy.calls"\nexit 0\n' "$TEST_TMPDIR" > "$d/sync.sh"
    printf '#!/usr/bin/env bash\necho "pull ${*: -1} knob=<${GIT_SYNC_NO_DEPLOY:-}>" >> "%s/pull.calls"\nexit 0\n' "$TEST_TMPDIR" > "$d/setup/scripts/git-sync-check.sh"
    chmod +x "$d/sync.sh" "$d/setup/scripts/git-sync-check.sh"
    printf '# cfg\n' > "$d/CLAUDE.md"
    cat > "$d/registry.md" <<'EOF'
# Project Registry

| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
| alpha | P1 | — | `~/alpha` | `t/alpha` | m1 | code | active | |
| beta | P2 | — | `~/beta` | `t/beta` | m1 | code | active | |
EOF
    git -C "$HOME/beta" init -q -b main
    git -C "$d" init -q -b main
    git -C "$d" add -A
    git -C "$d" commit -q -m "cfg at HEAD"
}

_lock() {   # <dir> <pid> [machine]
    printf '{"machine":"%s","pid":%s,"sessionId":"s-%s","timestamp":"%s","user":"t","ccSessionId":""}\n' \
        "${3:-$(_host)}" "$2" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$1/.claude/.session-lock"
}

# "held=<yes|no> why=<reason> fix=<remedy>" for <dir>, asked from a fresh bash.
_held() {
    bash -c 'source "$1"; if afleet_cfg_held "$2"; then h=yes; else h=no; fi
             printf "held=%s why=%s fix=%s\n" "$h" "$AFLEET_CFG_HELD_WHY" "$AFLEET_CFG_HELD_FIX"' _ "$MOD" "$1"
}

# A pid that is certainly dead: a finished child's.
_dead_pid() { local p; sleep 0 & p=$!; wait "$p" 2>/dev/null; echo "$p"; }
_count() { local n; n=$(grep -c -- "$2" "$1" 2>/dev/null) || true; echo "${n:-0}"; }

# ── The verdict map ───────────────────────────────────────────────────────────

test_live_holder_is_held() {
    local cfg="$TEST_TMPDIR/cfg" out
    _mk_cfg "$cfg" "$(_stub_lock_lib 2)"; _lock "$cfg" 4242
    out=$(_held "$cfg")
    echo "    measured: $out"
    assert_contains "$out" "held=yes" "check_lock 2 (a live session here) ⇒ held" || return 1
    assert_contains "$out" "pid 4242" "the reason names the holder's pid" || return 1
    assert_contains "$out" "fix=" "a live holder needs no remedy" || return 1
    assert_not_contains "$out" "rm -f" "so none is offered"
}
run_test "verdict: check_lock 2 ⇒ held, the reason names the holder, no remedy" test_live_holder_is_held

test_free_is_not_held() {
    local cfg="$TEST_TMPDIR/cfg" out
    _mk_cfg "$cfg" "$(_stub_lock_lib 0)"
    out=$(_held "$cfg")
    echo "    measured: $out"
    assert_contains "$out" "held=no why= fix=" "check_lock 0 (free) ⇒ not held, no reason"
}
run_test "verdict: check_lock 0 ⇒ not held" test_free_is_not_held

test_non_live_reasons_carry_a_runnable_remedy() {
    # S3: every reason but a live holder (2) says how to clear it, as a command
    # that runs — session-lock.sh has no CLI, so force_release is not one.
    local cfg="$TEST_TMPDIR/cfg" rc out
    for rc in 1 3 4 6 7 127; do
        rm -rf "$cfg"; _mk_cfg "$cfg" "$(_stub_lock_lib "$rc")"; _lock "$cfg" 4242 otherbox
        out=$(_held "$cfg")
        echo "    measured rc=$rc: $out"
        assert_contains "$out" "held=yes" "check_lock $rc ⇒ held (fail closed)" || return 1
        assert_contains "$out" "fix=If no session is live there: rm -f $cfg/.claude/.session-lock" "with a runnable remedy" || return 1
        assert_not_contains "$out" "force_release" "never the library function, which has no CLI" || return 1
    done
    assert_contains "$out" "unknown" "an unclassifiable result says the state is unknown"
}
run_test "verdict: check_lock 1/3/4/6/7/127 ⇒ held, each with a runnable rm remedy" test_non_live_reasons_carry_a_runnable_remedy

test_other_machine_names_it() {
    local cfg="$TEST_TMPDIR/cfg" out
    _mk_cfg "$cfg" "$(_stub_lock_lib 3)"; _lock "$cfg" 77 otherbox
    out=$(_held "$cfg")
    assert_contains "$out" "held by a session on otherbox" "check_lock 3 names the machine"
}
run_test "verdict: check_lock 3 names the other machine" test_other_machine_names_it

test_no_check_lock_needs_a_lock_file() {
    local cfg="$TEST_TMPDIR/cfg" without with
    _mk_cfg "$cfg" 'not_check_lock() { :; }'
    without=$(_held "$cfg"); _lock "$cfg" 4242; with=$(_held "$cfg")
    echo "    measured: no lock -> $without; lock -> $with"
    assert_contains "$without" "held=no" "no check_lock at HEAD and no lock ⇒ not held" || return 1
    assert_contains "$with" "held=yes" "no check_lock at HEAD and a lock ⇒ held (fail closed)" || return 1
    assert_contains "$with" "rm -f $cfg/.claude/.session-lock" "with the remedy"
}
run_test "verdict: no usable check_lock ⇒ held only with a lock file" test_no_check_lock_needs_a_lock_file

test_no_library_anywhere_needs_a_lock_file() {
    local cfg="$TEST_TMPDIR/cfg" without with
    _mk_cfg "$cfg" "$(_stub_lock_lib 0)" '# a lib-cfg-held.sh from before CFG-965'
    without=$(_held "$cfg"); _lock "$cfg" 4242; with=$(_held "$cfg")
    echo "    measured: no lock -> $without; lock -> $with"
    assert_contains "$without" "held=no" "no usable library and no lock ⇒ not held" || return 1
    assert_contains "$with" "held=yes" "no usable library and a lock ⇒ held (fail closed)" || return 1
    assert_file_not_exists "$TEST_TMPDIR/check_lock.calls" "no check_lock was consulted without a library"
}
run_test "verdict: no usable lib-cfg-held.sh ⇒ held only with a lock file" test_no_library_anywhere_needs_a_lock_file

# ── Which copy answers ────────────────────────────────────────────────────────

_free_lib='_cfg_held_check_lock() { return 0; }'

test_head_lib_answers_before_deployed_and_tree() {
    local cfg="$TEST_TMPDIR/cfg" out
    _mk_cfg "$cfg" "$(_stub_lock_lib 2)"; _lock "$cfg" 4242
    printf '%s\n' "$_free_lib" > "$cfg/global/hooks/lib-cfg-held.sh"
    mkdir -p "$HOME/.claude/hooks"; printf '%s\n' "$_free_lib" > "$HOME/.claude/hooks/lib-cfg-held.sh"
    out=$(_held "$cfg")
    echo "    measured: $out"
    assert_contains "$out" "held=yes" "HEAD's library answers, not the deployed or working-tree one"
}
run_test "library: HEAD's lib-cfg-held.sh answers before the deployed and working-tree copies" test_head_lib_answers_before_deployed_and_tree

test_deployed_lib_when_head_is_unusable() {
    local cfg="$TEST_TMPDIR/cfg" out
    _mk_cfg "$cfg" "$(_stub_lock_lib 2)" $'x() { :; }\nif then'; _lock "$cfg" 4242
    mkdir -p "$HOME/.claude/hooks"; cp "$LIB" "$HOME/.claude/hooks/lib-cfg-held.sh"
    out=$(_held "$cfg")
    echo "    measured: $out"
    assert_contains "$out" "held=yes" "a broken HEAD library ⇒ the deployed copy answers" || return 1
    assert_file_exists "$TEST_TMPDIR/check_lock.calls" "and HEAD's check_lock was asked through it"
}
run_test "library: a broken HEAD copy falls back to the deployed copy" test_deployed_lib_when_head_is_unusable

test_working_tree_lock_lib_when_repo_has_no_head() {
    # No git history (a template-only deployment): the working tree's
    # session-lock.sh is the only copy there is.
    local cfg="$TEST_TMPDIR/cfg" out
    mkdir -p "$cfg/.claude" "$cfg/setup/scripts" "$HOME/.claude/hooks"
    cp "$LIB" "$HOME/.claude/hooks/lib-cfg-held.sh"
    cp "$REAL_LOCK_LIB" "$cfg/setup/scripts/session-lock.sh"
    _lock "$cfg" "$(_dead_pid)"
    out=$(_held "$cfg")
    echo "    measured: $out"
    assert_contains "$out" "held=no" "a dead holder's lock in a repo without HEAD ⇒ not held" || return 1
    assert_file_exists "$cfg/.claude/.session-lock" "and the read-only probe leaves the lock alone"
}
run_test "library: a repo without HEAD uses its working-tree session-lock.sh" test_working_tree_lock_lib_when_repo_has_no_head

# ── Asked as a non-CC caller ──────────────────────────────────────────────────

test_caller_is_non_cc_without_inherited_ids() {
    local cfg="$TEST_TMPDIR/cfg" pid seen
    _mk_cfg "$cfg" "$(_stub_lock_lib 0)"
    pid=$(CC_SESSION_ID=leak1 CLAUDE_CODE_SESSION_ID=leak2 CLAUDE_SESSION_ID=leak3 AFLEET_SESSION_ID=leak4 \
        bash -c 'source "$1"; afleet_cfg_held "$2" || true; echo $$' _ "$MOD" "$cfg")
    seen=$(cat "$TEST_TMPDIR/check_lock.calls" 2>/dev/null)
    echo "    measured: caller pid=$pid check_lock saw: $seen"
    assert_eq "self=$pid ids=///" "$seen" "check_lock's self is the caller's own pid and no inherited session id reaches it"
}
run_test "non-CC caller: self = the caller's pid, inherited session ids dropped" test_caller_is_non_cc_without_inherited_ids

# ── The real session-lock.sh at HEAD ──────────────────────────────────────────

test_real_lib_live_holder_is_held_and_kept() {
    local cfg="$TEST_TMPDIR/cfg" out holder
    _mk_cfg "$cfg" "$(cat "$REAL_LOCK_LIB")"
    sleep 60 & holder=$!
    _lock "$cfg" "$holder"
    out=$(_held "$cfg")
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
    echo "    measured: $out"
    assert_contains "$out" "held=yes" "a lock whose pid is alive ⇒ held" || return 1
    assert_contains "$out" "pid $holder" "the reason names it" || return 1
    assert_file_exists "$cfg/.claude/.session-lock" "the lock is left in place"
}
run_test "real check_lock: a live holder ⇒ held, lock kept" test_real_lib_live_holder_is_held_and_kept

test_real_lib_crashed_holder_is_free_and_read_only() {
    # S2: check_lock would clean a dead holder's lock; the probe must not. A
    # crashed holder still never suppresses a deploy: the verdict is "free".
    local cfg="$TEST_TMPDIR/cfg" out dead
    _mk_cfg "$cfg" "$(cat "$REAL_LOCK_LIB")"
    dead=$(_dead_pid); _lock "$cfg" "$dead"
    out=$(_held "$cfg")
    echo "    measured: dead pid $dead -> $out lock-left=$([[ -f "$cfg/.claude/.session-lock" ]] && echo yes || echo no)"
    assert_contains "$out" "held=no" "a crashed holder's lock (pid dead, no CC in the repo) ⇒ not held" || return 1
    assert_file_exists "$cfg/.claude/.session-lock" "and the probe deletes nothing"
}
run_test "real check_lock: a crashed holder's stale lock ⇒ not held, lock untouched (read-only)" test_real_lib_crashed_holder_is_free_and_read_only

test_real_lib_scan_runs_for_a_decayed_lock() {
    # The lock's pid is dead but a live Claude Code process is cwd'd in the repo
    # (a direct launch's lock records the dying hook pid, CFG-468). Only a
    # non-empty self makes check_lock scan for it.
    local cfg="$TEST_TMPDIR/cfg" out cc
    sleep 60 & cc=$!
    echo "$cc" > "$TEST_TMPDIR/fakecc.pid"
    _mk_cfg "$cfg" "$(_real_lock_lib_with_fake_cc "$cfg")"
    _lock "$cfg" "$(_dead_pid)"
    out=$(_held "$cfg")
    kill "$cc" 2>/dev/null; wait "$cc" 2>/dev/null || true
    echo "    measured: $out"
    assert_contains "$out" "held=yes" "a live CC in the repo behind a dead-pid lock ⇒ held" || return 1
    assert_file_exists "$cfg/.claude/.session-lock" "and its lock is not deleted"
}
run_test "real check_lock: the liveness scan runs for a dead-pid lock (non-empty self)" test_real_lib_scan_runs_for_a_decayed_lock

test_real_lib_lockless_live_session_is_held() {
    # S1 basis: a live session with NO lock file (config-auto-sync releases the
    # lock in Phase -1 while CC is still alive, during /clear and end).
    local cfg="$TEST_TMPDIR/cfg" out cc
    sleep 60 & cc=$!
    echo "$cc" > "$TEST_TMPDIR/fakecc.pid"
    _mk_cfg "$cfg" "$(_real_lock_lib_with_fake_cc "$cfg")"
    out=$(_held "$cfg")
    kill "$cc" 2>/dev/null; wait "$cc" 2>/dev/null || true
    echo "    measured: $out"
    assert_contains "$out" "held=yes" "a live CC in the repo with no lock file ⇒ held" || return 1
    assert_contains "$out" "no lock file" "and the reason says so"
}
run_test "real check_lock: a live session without a lock file ⇒ held" test_real_lib_lockless_live_session_is_held

_unshare_works() { command -v unshare >/dev/null 2>&1 && unshare --user --pid --map-root-user --fork --mount-proc true 2>/dev/null; }

test_hidden_process_table_never_deletes_a_lock() {
    # S2: in a PID namespace the live holder's pid reads dead and no CC is
    # visible. Whatever the verdict, the holder's lock must survive the probe.
    local cfg="$TEST_TMPDIR/cfg" out holder
    _mk_cfg "$cfg" "$(cat "$REAL_LOCK_LIB")"
    sleep 60 & holder=$!
    _lock "$cfg" "$holder"
    out=$(unshare --user --pid --map-root-user --fork --mount-proc \
        bash -c 'source "$1"; if afleet_cfg_held "$2"; then echo held=yes; else echo held=no; fi' _ "$MOD" "$cfg" 2>&1)
    local left; left=$([[ -f "$cfg/.claude/.session-lock" ]] && echo yes || echo no)
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
    echo "    measured (inside a PID namespace): $out lock-left=$left"
    assert_eq "yes" "$left" "a live holder's lock survives a probe that cannot see its process"
}
if _unshare_works; then
    run_test "read-only: a hidden process table never deletes a live holder's lock" test_hidden_process_table_never_deletes_a_lock
else
    skip_test "read-only: a hidden process table never deletes a live holder's lock" "unshare --user --pid unavailable here"
fi

# ── Shell hygiene ─────────────────────────────────────────────────────────────

test_sourcing_leaves_shell_options_alone() {
    local cfg="$TEST_TMPDIR/cfg" out
    _mk_cfg "$cfg" "$(_stub_lock_lib 2)"; _lock "$cfg" 4242
    out=$(bash -c 'set -euo pipefail; b=$-; source "$1"; s=$-; afleet_cfg_held "$2" || true; c=$-; echo "$b|$s|$c"' _ "$MOD" "$cfg" 2>&1)
    echo "    measured \$- before|after source|after a call: $out"
    local b="${out%%|*}"
    assert_eq "$b|$b|$b" "$out" "\$- is unchanged by sourcing the module and by a call"
}
run_test "module: sourcing it (and a call) leaves \$- unchanged" test_sourcing_leaves_shell_options_alone

test_survives_a_set_e_caller() {
    local cfg="$TEST_TMPDIR/cfg" out
    _mk_cfg "$cfg" "$(_stub_lock_lib 2)"; _lock "$cfg" 4242
    out=$(bash -c 'set -euo pipefail; source "$1"; if afleet_cfg_held "$2"; then echo held; fi; afleet_cfg_held /nonexistent || echo free; echo survived' _ "$MOD" "$cfg" 2>&1)
    echo "    measured: $(echo "$out" | tr '\n' ' ')"
    assert_contains "$out" "held" "held under set -euo pipefail" || return 1
    assert_contains "$out" "survived" "and the caller is not aborted"
}
run_test "module: safe under a set -euo pipefail caller" test_survives_a_set_e_caller

# ── CLI (how the launcher and afleet-recover.sh call it) ──────────────────────

test_cli_held_and_free() {
    local cfg="$TEST_TMPDIR/cfg" held free
    _mk_cfg "$cfg" "$(_stub_lock_lib 3)"; _lock "$cfg" 77 otherbox
    held=$(bash "$MOD" held "$cfg")
    rm -rf "$cfg"; _mk_cfg "$cfg" "$(_stub_lock_lib 0)"
    free=$(bash "$MOD" held "$cfg")
    echo "    measured: held -> $(printf '%s' "$held" | tr '\t' '|'); free -> $free"
    assert_eq "held"$'\t'"held by a session on otherbox"$'\t'"If no session is live there: rm -f $cfg/.claude/.session-lock" "$held" "held ⇒ one line: held, reason, remedy (tab-separated)" || return 1
    assert_eq "free" "$free" "free ⇒ the word free"
}
run_test "CLI: 'held <repo>' prints held<TAB>reason<TAB>remedy or free" test_cli_held_and_free

test_cli_defer_writes_audit_and_prints_note() {
    local cfg="$TEST_TMPDIR/cfg" note log="$HOME/.claude/logs/template-push-deferred.log"
    mkdir -p "$cfg"
    note=$(bash "$MOD" defer "$cfg" gamma "held by a session on otherbox" "If no session is live there: rm -f /x/.claude/.session-lock" "")
    echo "    measured note: $note"
    assert_contains "$note" "cfg is held by a session on otherbox — not deploying its working tree; the holder deploys at its shutdown." "the note names the repo, the holder and what the launcher does" || return 1
    assert_contains "$note" "If no session is live there: rm -f /x/.claude/.session-lock" "and ends with the remedy" || return 1
    assert_eq "1" "$(wc -l < "$log" | tr -d ' ')" "exactly one audit line (measured $(wc -l < "$log" | tr -d ' '))" || return 1
    assert_file_contains "$log" "LAUNCH_DEPLOY_DEFERRED: cfg is held by a session on otherbox" "tagged, with the reason" || return 1
    assert_file_contains "$log" "(launch of gamma)" "and the project being launched"
}
run_test "CLI: 'defer' writes one LAUNCH_DEPLOY_DEFERRED audit line and prints the note" test_cli_defer_writes_audit_and_prints_note

test_cli_defer_note_mentions_a_skipped_pull() {
    local note
    note=$(bash "$MOD" defer "$TEST_TMPDIR/cfg" gamma "held by x" "" 1)
    echo "    measured note: $note"
    assert_contains "$note" "not pulling or deploying its working tree" "a skipped pre-launch pull is named in the same line"
}
run_test "CLI: the note names a skipped pre-launch pull" test_cli_defer_note_mentions_a_skipped_pull

test_audit_log_is_the_shutdown_paths() {
    local mine theirs
    mine=$(grep -o '\.claude/logs/[a-z-]*\.log' "$MOD" | sort -u)
    theirs=$(grep -o '\.claude/logs/[a-z-]*\.log' "$LIB" | sort -u)
    echo "    measured: module=$mine lib=$theirs"
    assert_eq "$theirs" "$mine" "the launcher writes the same audit log as lib-cfg-held.sh" || return 1
    assert_file_not_contains "$MOD" "sync-warnings.log" "and never the drift log SessionStart surfaces"
}
run_test "audit: the log is lib-cfg-held.sh's, never .sync-warnings.log" test_audit_log_is_the_shutdown_paths

# ── The launcher ──────────────────────────────────────────────────────────────

# A stub mclaude and claude, first on PATH and in the sandbox ~/.local/bin, that
# only record a call. Prints the PATH to use.
_stub_cc() {
    local d="$TEST_TMPDIR/stubbin" b
    mkdir -p "$d" "$HOME/.local/bin"
    for b in "$d/mclaude" "$d/claude" "$HOME/.local/bin/mclaude"; do
        printf '#!/usr/bin/env bash\necho "STUB_CC $0 $*" >> "%s/stubcc.calls"\nexit 0\n' "$TEST_TMPDIR" > "$b"
        chmod +x "$b"
    done
    printf '%s' "$d:$PATH"
}

# Source the launcher (AFLEET_SOURCE_ONLY — its pre-picker block runs) against
# <cfg>, then run pre_launch_sync for project alpha. [between] runs in between and
# stands for a picker having been shown. stderr → $TEST_TMPDIR/stderr.
_launch_sync() {   # <cfg> [afleet.sh] [between-function]
    local path; path=$(_stub_cc)
    mkdir -p "$HOME/alpha/.claude"
    ( export CONFIG_REPO="$1" AFLEET_SOURCE_ONLY=1 PATH="$path"
      source "${2:-$AFLEET}"
      TARGET_DIR="$HOME/alpha" TARGET_NAME="alpha"
      steamos_preflight() { return 0; }
      afleet_acquire_session_lock() { return 0; }
      afleet_project_preflight() { :; }
      telegram_inbox_check() { :; }
      start_spinner() { :; }; stop_spinner() { :; }
      if [[ -n "${3:-}" ]]; then "$3"; SHOW_PICKER=true; fi
      pre_launch_sync ) 2> "$TEST_TMPDIR/stderr" >/dev/null
}

test_launch_held_skips_pull_and_deploy() {
    local cfg="$TEST_TMPDIR/cfg" log="$HOME/.claude/logs/template-push-deferred.log"
    _mk_cfg "$cfg" "$(_stub_lock_lib 2)"; _lock "$cfg" 4242
    _launch_sync "$cfg"
    echo "    measured: deploys=$(_count "$TEST_TMPDIR/deploy.calls" deploy) pulls: $(tr '\n' ';' < "$TEST_TMPDIR/pull.calls" 2>/dev/null) note-lines=$(_count "$TEST_TMPDIR/stderr" 'not pulling or deploying')"
    assert_file_not_exists "$TEST_TMPDIR/deploy.calls" "held ⇒ sync.sh deploy is not run" || return 1
    assert_eq "0" "$(_count "$TEST_TMPDIR/pull.calls" "pull $cfg ")" "held ⇒ the pre-picker pull of the config repo is skipped" || return 1
    assert_file_contains "$TEST_TMPDIR/pull.calls" "pull $HOME/beta knob=<config repo held by a live session" "other repos still pull, with CFG-208 auto-deploy switched off" || return 1
    assert_eq "1" "$(_count "$TEST_TMPDIR/stderr" 'not pulling or deploying its working tree')" "one console line" || return 1
    assert_file_contains "$log" "LAUNCH_DEPLOY_DEFERRED:" "one audit line" || return 1
    assert_file_contains "$log" "(launch of alpha)" "naming the launched project" || return 1
    assert_file_not_exists "$TEST_TMPDIR/stubcc.calls" "and no Claude Code was reached"
}
run_test "launcher: held config repo ⇒ no pull, no deploy, one console line, one audit line" test_launch_held_skips_pull_and_deploy

test_launch_free_deploys_once() {
    local cfg="$TEST_TMPDIR/cfg"
    _mk_cfg "$cfg" "$(_stub_lock_lib 0)"
    _launch_sync "$cfg"
    echo "    measured: deploys=$(_count "$TEST_TMPDIR/deploy.calls" deploy) pulls: $(tr '\n' ';' < "$TEST_TMPDIR/pull.calls" 2>/dev/null)"
    assert_eq "1" "$(_count "$TEST_TMPDIR/deploy.calls" deploy)" "not held ⇒ exactly one sync.sh deploy" || return 1
    assert_file_contains "$TEST_TMPDIR/pull.calls" "pull $cfg knob=<afleet deploys after the picker>" "the pre-picker pull runs, its own auto-deploy off (one deploy per launch)" || return 1
    assert_file_contains "$TEST_TMPDIR/pull.calls" "pull $HOME/beta knob=<>" "other repos pull with auto-deploy untouched" || return 1
    assert_eq "0" "$(_count "$TEST_TMPDIR/stderr" 'not deploying')" "no console line" || return 1
    assert_file_not_exists "$HOME/.claude/logs/template-push-deferred.log" "no audit line"
}
run_test "launcher: free config repo ⇒ pull (no auto-deploy) and exactly one deploy" test_launch_free_deploys_once

test_launch_crashed_holder_deploys() {
    local cfg="$TEST_TMPDIR/cfg"
    _mk_cfg "$cfg" "$(cat "$REAL_LOCK_LIB")"
    _lock "$cfg" "$(_dead_pid)"
    _launch_sync "$cfg"
    echo "    measured: deploys=$(_count "$TEST_TMPDIR/deploy.calls" deploy) lock-left=$([[ -f "$cfg/.claude/.session-lock" ]] && echo yes || echo no)"
    assert_eq "1" "$(_count "$TEST_TMPDIR/deploy.calls" deploy)" "a crashed holder's stale lock does not suppress the deploy" || return 1
    assert_file_exists "$cfg/.claude/.session-lock" "and a launch into another project leaves cfg's lock alone"
}
run_test "launcher: a crashed holder's stale lock ⇒ deploys, lock left alone" test_launch_crashed_holder_deploys

test_launch_lockless_live_session_is_held() {
    local cfg="$TEST_TMPDIR/cfg" cc
    sleep 60 & cc=$!
    echo "$cc" > "$TEST_TMPDIR/fakecc.pid"
    _mk_cfg "$cfg" "$(_real_lock_lib_with_fake_cc "$cfg")"
    _launch_sync "$cfg"
    kill "$cc" 2>/dev/null; wait "$cc" 2>/dev/null || true
    echo "    measured: deploys=$(_count "$TEST_TMPDIR/deploy.calls" deploy) cfg-pulls=$(_count "$TEST_TMPDIR/pull.calls" "pull $cfg ")"
    assert_file_not_exists "$TEST_TMPDIR/deploy.calls" "a live session without a lock file ⇒ no deploy" || return 1
    assert_eq "0" "$(_count "$TEST_TMPDIR/pull.calls" "pull $cfg ")" "and no pre-picker pull (S1: asked whether or not a lock file exists)"
}
run_test "launcher: a live session without a lock file ⇒ no pull, no deploy (S1)" test_launch_lockless_live_session_is_held

_lock_appears() { _lock "$TEST_TMPDIR/cfg" 4242; }
test_verdict_reused_without_picker_asked_again_after_one() {
    # N1: one probe per launch when no picker ran; after a picker (minutes may
    # pass) the verdict is asked again, and a holder that appeared meanwhile counts.
    local cfg="$TEST_TMPDIR/cfg" once twice
    _mk_cfg "$cfg" "$(_stub_lock_lib 0)"
    _launch_sync "$cfg"
    once=$(_count "$TEST_TMPDIR/check_lock.calls" self=)
    rm -rf "$cfg" "$TEST_TMPDIR"/*.calls
    _mk_cfg "$cfg" "$(_stub_lock_lib 2)"
    _launch_sync "$cfg" "$AFLEET" _lock_appears
    twice=$(_count "$TEST_TMPDIR/check_lock.calls" self=)
    echo "    measured: probes without picker=$once, with picker=$twice; deploys after picker=$(_count "$TEST_TMPDIR/deploy.calls" deploy)"
    assert_eq "1" "$once" "no picker ⇒ the pre-picker verdict is reused (one probe)" || return 1
    assert_eq "2" "$twice" "picker shown ⇒ asked again" || return 1
    assert_file_not_exists "$TEST_TMPDIR/deploy.calls" "and a holder that appeared during the picker stops the deploy"
}
run_test "launcher: verdict reused without a picker, asked again after one (N1)" test_verdict_reused_without_picker_asked_again_after_one

# A launcher directory: <afleet.sh> plus links to every sibling script; the held
# module left out (omit) or replaced by one whose first line is `exit 3` (exit3).
_mk_launcher_dir() {   # <dest> <afleet.sh> [omit|exit3]
    local f
    mkdir -p "$1"
    for f in "$(dirname "$AFLEET")"/*; do ln -s "$f" "$1/$(basename "$f")"; done
    rm -f "$1/afleet.sh"; cp "$2" "$1/afleet.sh"
    case "${3:-}" in
        omit)  rm -f "$1/afleet-cfg-held.sh" ;;
        exit3) rm -f "$1/afleet-cfg-held.sh"; { echo 'exit 3'; cat "$MOD"; } > "$1/afleet-cfg-held.sh" ;;
    esac
    return 0
}

test_launch_fails_closed_without_a_usable_module() {
    local cfg="$TEST_TMPDIR/cfg" mode locked free
    _mk_cfg "$cfg" "$(_stub_lock_lib 0)"
    for mode in omit exit3; do
        rm -rf "$TEST_TMPDIR/launcher"; _mk_launcher_dir "$TEST_TMPDIR/launcher" "$AFLEET" "$mode"
        _lock "$cfg" 4242; rm -f "$TEST_TMPDIR/deploy.calls"
        _launch_sync "$cfg" "$TEST_TMPDIR/launcher/afleet.sh"
        locked=$(_count "$TEST_TMPDIR/deploy.calls" deploy)
        local note; note=$(cat "$TEST_TMPDIR/stderr")
        rm -f "$cfg/.claude/.session-lock" "$TEST_TMPDIR/deploy.calls"
        _launch_sync "$cfg" "$TEST_TMPDIR/launcher/afleet.sh"
        free=$(_count "$TEST_TMPDIR/deploy.calls" deploy)
        echo "    measured $mode: deploys with lock=$locked without=$free"
        assert_eq "0" "$locked" "module $mode + a lock file ⇒ no deploy (fail closed)" || return 1
        assert_contains "$note" "rm -f $cfg/.claude/.session-lock" "the console line carries the remedy" || return 1
        assert_eq "1" "$free" "module $mode + no lock ⇒ deploy as before" || return 1
    done
}
run_test "launcher: module missing or exiting at its top ⇒ survives, fail closed on a lock file" test_launch_fails_closed_without_a_usable_module

test_doctor_survives_a_module_that_exits() {
    local cfg="$TEST_TMPDIR/cfg" path out rc=0
    _mk_cfg "$cfg" "$(_stub_lock_lib 2)"; _lock "$cfg" 4242
    _mk_launcher_dir "$TEST_TMPDIR/launcher" "$AFLEET" exit3
    path=$(_stub_cc)
    out=$(CONFIG_REPO="$cfg" PATH="$path" timeout 60 bash "$TEST_TMPDIR/launcher/afleet.sh" doctor 2>&1) || rc=$?
    echo "    measured: rc=$rc header=$(grep -c 'Agent Fleet Health Check' <<< "$out") summary=$(grep -c 'Summary:' <<< "$out")"
    assert_neq "3" "$rc" "a module whose first line is 'exit 3' does not end af doctor" || return 1
    assert_contains "$out" "Agent Fleet Health Check" "doctor runs" || return 1
    assert_contains "$out" "Summary:" "to its end"
}
run_test "launcher: a module whose first line is 'exit 3' does not kill af doctor" test_doctor_survives_a_module_that_exits

test_no_pre_picker_work_for_commands_without_a_picker() {
    # S4: transfer, the recovery subcommands and --list show no picker: no probe, no pull.
    local cfg="$TEST_TMPDIR/cfg" path arg
    _mk_cfg "$cfg" "$(_stub_lock_lib 0)"
    path=$(_stub_cc)
    for arg in --list -l; do
        CONFIG_REPO="$cfg" PATH="$path" timeout 60 bash "$AFLEET" "$arg" >/dev/null 2>&1 || true
    done
    CONFIG_REPO="$cfg" PATH="$path" timeout 60 bash "$AFLEET" doctor >/dev/null 2>&1 || true
    echo "    measured: cfg pulls=$(_count "$TEST_TMPDIR/pull.calls" "pull $cfg ") probes=$(_count "$TEST_TMPDIR/check_lock.calls" self=)"
    assert_eq "0" "$(_count "$TEST_TMPDIR/pull.calls" "pull $cfg ")" "--list, -l and doctor pull nothing before dispatch" || return 1
    assert_file_not_exists "$TEST_TMPDIR/check_lock.calls" "and ask no lock question there"
}
run_test "launcher: --list, -l and the recovery subcommands do no pre-picker work (S4)" test_no_pre_picker_work_for_commands_without_a_picker

test_symlinked_launcher_without_readlink_f_finds_the_module() {
    # Old macOS: `readlink -f` is an illegal option. Reached through a symlink, the
    # launcher must still find the module beside its real file, not fail closed.
    local cfg="$TEST_TMPDIR/cfg" path out
    _mk_cfg "$cfg" "$(_stub_lock_lib 2)"; _lock "$cfg" 4242
    _mk_launcher_dir "$TEST_TMPDIR/launcher" "$AFLEET"
    mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/fakebin" "$HOME/alpha/.claude"
    ln -s "$TEST_TMPDIR/launcher/afleet.sh" "$TEST_TMPDIR/bin/afleet"
    printf '#!/bin/sh\n[ "$1" = "-f" ] && { echo "readlink: illegal option -- f" >&2; exit 1; }\nexec /usr/bin/readlink "$@"\n' > "$TEST_TMPDIR/fakebin/readlink"
    chmod +x "$TEST_TMPDIR/fakebin/readlink"
    path=$(_stub_cc)
    out=$(CONFIG_REPO="$cfg" PATH="$TEST_TMPDIR/fakebin:$path" AFLEET_DRY_RUN=1 \
          timeout 60 bash "$TEST_TMPDIR/bin/afleet" --cwd "$HOME/alpha" 2>&1) || true
    echo "    measured: $(grep -o 'cfg is [^—]*' <<< "$out" | head -1)"
    assert_contains "$out" "cfg is held by a live session on this machine (lock pid 4242)" "the module beside the real file answers" || return 1
    assert_not_contains "$out" "afleet-cfg-held.sh unusable" "it is not reported unusable"
}
run_test "launcher: via a symlink with a readlink lacking -f, the module is still found" test_symlinked_launcher_without_readlink_f_finds_the_module

test_launch_into_held_cfg_follower_does_not_deploy() {
    local cfg="$TEST_TMPDIR/cfg" holder out path
    _mk_cfg "$cfg" "$(cat "$REAL_LOCK_LIB")"
    sleep 60 & holder=$!
    _lock "$cfg" "$holder"
    printf 'q\n' > "$TEST_TMPDIR/answer"
    path=$(_stub_cc)
    out=$(CONFIG_REPO="$cfg" PATH="$path" AFLEET_DRY_RUN=1 AFLEET_PROMPT_INPUT="$TEST_TMPDIR/answer" \
          timeout 60 bash "$AFLEET" --cwd "$cfg" 2>&1) || true
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
    echo "    measured: deploys=$(_count "$TEST_TMPDIR/deploy.calls" deploy) prompt=$(grep -c 'Another Claude Code session' <<< "$out")"
    assert_file_not_exists "$TEST_TMPDIR/deploy.calls" "launch into a held config repo ⇒ no deploy" || return 1
    assert_contains "$out" "Another Claude Code session" "the follower prompt still appears" || return 1
    assert_contains "$out" "not pulling or deploying its working tree" "and the console line says why nothing was deployed" || return 1
    assert_file_not_exists "$TEST_TMPDIR/stubcc.calls" "no Claude Code was reached"
}
run_test "launcher: launch into a held config repo (follower) ⇒ no deploy" test_launch_into_held_cfg_follower_does_not_deploy

test_launch_into_free_cfg_owner_deploys() {
    local cfg="$TEST_TMPDIR/cfg" out path
    _mk_cfg "$cfg" "$(cat "$REAL_LOCK_LIB")"
    path=$(_stub_cc)
    out=$(CONFIG_REPO="$cfg" PATH="$path" AFLEET_DRY_RUN=1 timeout 60 bash "$AFLEET" --cwd "$cfg" 2>&1) || true
    echo "    measured: deploys=$(_count "$TEST_TMPDIR/deploy.calls" deploy)"
    assert_eq "1" "$(_count "$TEST_TMPDIR/deploy.calls" deploy)" "the owner's own launch of a free config repo deploys once" || return 1
    assert_contains "$out" "DRY_RUN: would cd to $cfg" "and launches" || return 1
    assert_not_contains "$out" "not deploying" "with no deferral line" || return 1
    assert_file_not_exists "$TEST_TMPDIR/stubcc.calls" "no Claude Code was reached"
}
run_test "launcher: the owner's launch of a free config repo deploys once" test_launch_into_free_cfg_owner_deploys

suite_summary
