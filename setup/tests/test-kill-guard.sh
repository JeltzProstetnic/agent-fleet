#!/usr/bin/env bash
# Tests for global/hooks/kill-guard.sh — CFG-694.
#
# The user rejected the behavioural form of this outright ("did you think i would know processes
# by PID?? ridiculous, do better - this is cfg job"), so ownership is proved mechanically:
# same session id, or written down by a fleet launcher at launch.
#
# The guard UNDER-blocks by design. A guard that refuses legal work gets switched off and
# takes its working half with it (CFG-658), so anything it cannot resolve passes.
#
# NOTE: one decisive assert per test — this harness lets only the FINAL assert decide.
source "$(dirname "$0")/test-helpers.sh"

HOOK="$REPO_ROOT/global/hooks/kill-guard.sh"
LIB="$REPO_ROOT/setup/scripts/launch-registry.sh"

suite_header "kill-guard.sh (CFG-694 process ownership)"

_rc() {
    local input rc=0
    input=$(jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}')
    HOOK_STDERR=$(CC_LAUNCH_REGISTRY="$TEST_TMPDIR/reg.tsv" CC_LAUNCH_REGISTRY_LIB="$LIB" \
        printf '%s' "$input" | CC_LAUNCH_REGISTRY="$TEST_TMPDIR/reg.tsv" CC_LAUNCH_REGISTRY_LIB="$LIB" bash "$HOOK" 2>&1) || rc=$?
    printf '%s' "$rc"
}

# A process this session did NOT start and did not register: setsid gives it its own
# session id, which is exactly what somebody else's process looks like.
_foreign_pid() {
    setsid sleep 120 >/dev/null 2>&1 &
    sleep 0.3
    pgrep -n -f 'sleep 120' 2>/dev/null | head -1
}

# ── MUST BLOCK ────────────────────────────────────────────────────────────────

t_blocks_foreign_pid() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || { echo "    could not create a foreign process" >&2; return 1; }
    local rc; rc=$(_rc "kill $pid")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc for an unregistered, foreign-session pid"
    assert_eq "2" "$rc" "killing a process this session cannot prove it started must be refused"
}
run_test "blocks kill of a foreign, unregistered pid" t_blocks_foreign_pid

t_refusal_lists_alternatives() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    _rc "kill -9 $pid" >/dev/null
    kill -9 "$pid" 2>/dev/null
    echo "    measured refusal length: $(printf '%s' "$HOOK_STDERR" | wc -l) lines"
    assert_contains "$HOOK_STDERR" "MAY kill" "the refusal must name what IS allowed, not just say no"
}
run_test "the refusal names the registered alternatives" t_refusal_lists_alternatives

t_blocks_killall_by_name() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    local rc; rc=$(_rc "killall sleep")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc for killall by name"
    assert_eq "2" "$rc" "killall resolves to somebody else's processes and must be refused"
}
run_test "blocks killall by name when it would hit a foreign process" t_blocks_killall_by_name

# ── MUST ALLOW ────────────────────────────────────────────────────────────────

t_allows_registered_pid() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    CC_LAUNCH_REGISTRY="$TEST_TMPDIR/reg.tsv" bash "$LIB" add "$pid" "test-launch" "sleep 120"
    local rc; rc=$(_rc "kill $pid")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc after registering the same pid"
    assert_eq "0" "$rc" "a launcher-registered process is this session's to kill"
}
run_test "allows killing a registered launch" t_allows_registered_pid

t_allows_own_descendant() {
    sleep 60 & local pid=$!
    local rc; rc=$(_rc "kill $pid")
    kill "$pid" 2>/dev/null
    echo "    measured rc=$rc for a pid in this session's own tree"
    assert_eq "0" "$rc" "a process in this session's own tree needs no registry entry"
}
run_test "allows killing its own descendant" t_allows_own_descendant

t_allows_kill_zero_probe() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    local rc; rc=$(_rc "kill -0 $pid")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc for kill -0 (a probe, signals nothing)"
    assert_eq "0" "$rc" "kill -0 kills nothing and must not be refused"
}
run_test "allows kill -0 (liveness probe)" t_allows_kill_zero_probe

t_allows_job_spec() {
    assert_eq "0" "$(_rc 'kill %1')" "a job spec belongs to the caller's own shell"
}
run_test "allows a job spec" t_allows_job_spec

t_allows_unresolvable_variable() {
    assert_eq "0" "$(_rc 'kill $SERVER_PID')" \
        "an unresolved target passes — the guard under-blocks rather than refuse legal work"
}
run_test "allows an unresolvable variable target (under-blocks)" t_allows_unresolvable_variable

t_allows_grep_for_the_word() {
    assert_eq "0" "$(_rc "grep -rn 'killall' docs/")" "searching for the word is not running it"
}
run_test "allows grepping for the word" t_allows_grep_for_the_word

t_allows_unrelated() {
    assert_eq "0" "$(_rc 'ls -la /tmp')" "an unrelated command must pass untouched"
}
run_test "allows an unrelated command" t_allows_unrelated

t_ignores_non_bash() {
    local input rc=0
    input=$(jq -n '{tool_name: "Read", tool_input: {file_path: "/tmp/killall.txt"}}')
    printf '%s' "$input" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "a non-Bash tool must never be inspected"
}
run_test "ignores non-Bash tools" t_ignores_non_bash

# ── CFG-735: prose is not execution (over-block) ──────────────────────────────
# Seen live 2026-09-29: a python heredoc whose string literals only CONTAINED kill-idiom
# text was refused as if it would signal six unrelated host processes — the same class
# pkill-guard fixed in CFG-731, now the same pre-pass (lib-prose-strip.sh). A heredoc body
# handed to a non-shell interpreter, a commit message or an --body string is data: it names
# a kill, it does not send one. Every case here needs a FOREIGN target on the box, so that
# the text would resolve to something refusable if it were scanned as a command.

t_allows_kill_text_in_python_heredoc() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    local cmd
    cmd=$(printf "python3 - <<'PY'\nopen('b.md','a').write('kill -9 %s; killall sleep; pgrep -f x | xargs kill')\nPY" "$pid")
    local rc; rc=$(_rc "$cmd")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc for kill-idiom text inside a python heredoc body"
    assert_eq "0" "$rc" "a python heredoc body is data, not a shell command"
}
run_test "CFG-735: allows kill-idiom text inside a python heredoc body" t_allows_kill_text_in_python_heredoc

t_allows_kill_text_in_node_heredoc() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    local cmd
    cmd=$(printf "node - <<'JS'\nconsole.log('kill %s and killall sleep were refused')\nJS" "$pid")
    local rc; rc=$(_rc "$cmd")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc for kill-idiom text inside a node heredoc body"
    assert_eq "0" "$rc" "any non-shell interpreter's heredoc body is data"
}
run_test "CFG-735: allows kill-idiom text inside a node heredoc body" t_allows_kill_text_in_node_heredoc

t_allows_kill_text_in_commit_message() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    local rc; rc=$(_rc "git -C /tmp/r commit -q -m \"guard: kill $pid and killall sleep were refused\" -m \"trailer\"")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc for kill-idiom text inside a git -m message"
    assert_eq "0" "$rc" "a commit message only quotes the command"
}
run_test "CFG-735: allows kill-idiom text inside a git -m message" t_allows_kill_text_in_commit_message

t_allows_kill_text_in_body_flag() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    local rc; rc=$(_rc 'bash inbox-file.sh --project x --type work --body "never killall sleep in a loop"')
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc for kill-idiom text inside an --body string"
    assert_eq "0" "$rc" "an --body string only quotes the command"
}
run_test "CFG-735: allows kill-idiom text inside an --body string" t_allows_kill_text_in_body_flag

# What the pre-pass must NOT hide: a heredoc fed to a SHELL runs, a kill after a stripped
# message runs, and a kill after a prose heredoc runs.

t_still_blocks_kill_in_bash_heredoc() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    local cmd
    cmd=$(printf "bash <<'EOF'\nkill %s\nEOF" "$pid")
    local rc; rc=$(_rc "$cmd")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc for a real kill inside a heredoc fed to bash"
    assert_eq "2" "$rc" "a heredoc fed to a SHELL is executed and must still be refused"
}
run_test "CFG-735: still blocks a kill inside a heredoc fed to bash" t_still_blocks_kill_in_bash_heredoc

t_still_blocks_killall_in_sh_heredoc() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    local cmd
    cmd=$(printf "sh <<'EOF'\nkillall sleep\nEOF")
    local rc; rc=$(_rc "$cmd")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc for a real killall inside a heredoc fed to sh"
    assert_eq "2" "$rc" "sh is a shell too — its heredoc body runs"
}
run_test "CFG-735: still blocks a killall inside a heredoc fed to sh" t_still_blocks_killall_in_sh_heredoc

t_still_blocks_kill_after_a_message() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    local rc; rc=$(_rc "git commit -m \"x\"; kill $pid")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc for a real kill after a stripped -m message"
    assert_eq "2" "$rc" "stripping the -m string must not hide a real kill after it"
}
run_test "CFG-735: still blocks a real kill that follows a commit message" t_still_blocks_kill_after_a_message

t_still_blocks_killall_after_prose_heredoc() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    local cmd
    cmd=$(printf "python3 - <<'PY'\nprint('hi')\nPY\nkillall sleep")
    local rc; rc=$(_rc "$cmd")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc for a real killall on the line after a python heredoc"
    assert_eq "2" "$rc" "only the heredoc BODY is prose — the line after its terminator runs"
}
run_test "CFG-735: still blocks a killall that follows a python heredoc" t_still_blocks_killall_after_prose_heredoc

# Two real-kill forms the guard could never resolve without running the command. Measured
# on the pre-CFG-735 hook: both rc=0 (CFG-694 under-block, see the header). Pinned so the
# pre-pass is shown not to change their verdict either way.

t_xargs_kill_verdict_unchanged() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    local rc; rc=$(_rc "echo $pid | xargs kill")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc for '… | xargs kill' (pre-CFG-735 verdict: 0, pipe target unresolvable)"
    assert_eq "0" "$rc" "a target that only exists once the pipe runs is unresolved — under-block, as before"
}
run_test "CFG-735: '… | xargs kill' keeps its pre-existing verdict (unresolvable, allowed)" t_xargs_kill_verdict_unchanged

t_kill_pgrep_substitution_verdict_unchanged() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    local rc; rc=$(_rc "kill \$(pgrep -f '[s]leep 120')")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc for 'kill \$(pgrep …)' (pre-CFG-735 verdict: 0, substitution unresolvable)"
    assert_eq "0" "$rc" "a command substitution is unresolved — under-block, as before"
}
run_test "CFG-735: 'kill \$(pgrep …)' keeps its pre-existing verdict (unresolvable, allowed)" t_kill_pgrep_substitution_verdict_unchanged

# A here-string (`<<<`) is not a heredoc: it has no body and no terminator. Read as one, the
# pre-pass would drop every following line up to a terminator that never comes — and a real
# kill on the next line with it (measured on the CFG-731 pass: `wc -c <<< "y"\nkill <pid>`
# reached the scan as `wc -c <<< "y"` alone).

t_still_blocks_kill_after_a_here_string() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    local cmd
    cmd=$(printf "wc -c <<< \"y\"\nkill %s" "$pid")
    local rc; rc=$(_rc "$cmd")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc for a real kill on the line after a <<< here-string"
    assert_eq "2" "$rc" "a here-string has no body to drop — the next line is a command and runs"
}
run_test "CFG-735: still blocks a kill on the line after a <<< here-string" t_still_blocks_kill_after_a_here_string

# Fail-safe direction: when python3 is missing or fails, the RAW command is scanned, so the
# worst case is the old over-block — never a kill that slips through.

_rc_nopy() {   # _rc with python3 shadowed by a stub that fails (exit 127)
    local input rc=0 d="$TEST_TMPDIR/no-python3-bin"
    mkdir -p "$d"
    printf '#!/usr/bin/env bash\necho "bash: python3: command not found" >&2\nexit 127\n' > "$d/python3"
    chmod +x "$d/python3"
    input=$(jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}')
    HOOK_STDERR=$(printf '%s' "$input" | PATH="$d:$PATH" CC_LAUNCH_REGISTRY="$TEST_TMPDIR/reg.tsv" \
        CC_LAUNCH_REGISTRY_LIB="$LIB" bash "$HOOK" 2>&1) || rc=$?
    printf '%s' "$rc"
}

t_without_python3_scans_the_raw_command() {
    local pid; pid=$(_foreign_pid)
    [ -n "$pid" ] || return 1
    local cmd
    cmd=$(printf "python3 - <<'PY'\nopen('b.md','a').write('kill -9 %s; killall sleep')\nPY" "$pid")
    local rc; rc=$(_rc_nopy "$cmd")
    kill -9 "$pid" 2>/dev/null
    echo "    measured rc=$rc for the python-heredoc prose case with python3 unavailable"
    assert_eq "2" "$rc" "no python3 → no pre-pass → the raw command is scanned (over-block is the safe failure)"
}
run_test "CFG-735: without python3 the raw command is scanned (fails safe toward over-block)" t_without_python3_scans_the_raw_command

suite_summary
