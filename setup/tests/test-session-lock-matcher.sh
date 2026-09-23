#!/usr/bin/env bash
# Tests for the DEFAULT _CC_PROC_RE in setup/scripts/session-lock.sh.
#
# agent-fleet GH#7 (CFG-590). The matcher's default assumed the npm layout —
# a `claude-code/` path segment — so on any install invoked as a bare binary
# `_pid_is_cc` returned false for the real, running session. From there the
# whole ownership subsystem is inert and FAILS OPEN: `_cc_self_pid` is empty,
# `_project_has_live_cc` short-circuits on `[[ -n "$exclude_pid" ]] || return 1`,
# and `check_lock` reports every project free. A session mutex that always
# grants, with no error and no failing test.
#
# It had no failing test because test-session-lock.sh stubs `_pid_is_cc`
# outright (line ~378) and never exercises the default pattern — so the suite
# passed on machines where the real matcher could never fire. THAT is the gap
# this file closes: every case below runs against the shipped default, with no
# override anywhere.
source "$(dirname "$0")/test-helpers.sh"

suite_header "session-lock: default _CC_PROC_RE matches real command lines"

LOCK_LIB="$REPO_ROOT/setup/scripts/session-lock.sh"

# The shipped default, read the way the library computes it — with _CC_PROC_RE
# unset, so a value leaking in from the environment cannot mask a regression.
default_proc_re() {
    (
        unset _CC_PROC_RE
        # shellcheck disable=SC1090
        source "$LOCK_LIB" >/dev/null 2>&1
        printf '%s' "$_CC_PROC_RE"
    )
}

# Exactly the expression _pid_is_cc uses.
matches() {
    printf '%s' "$1" | grep -Eq "$(default_proc_re)"
}

assert_cmdline_matches() {
    local cmdline="$1" why="$2"
    if matches "$cmdline"; then
        return 0
    fi
    printf '    ASSERT failed: %s\n      cmdline: %s\n' "$why" "$cmdline"
    return 1
}

assert_cmdline_rejected() {
    local cmdline="$1" why="$2"
    if matches "$cmdline"; then
        printf '    ASSERT failed: %s\n      cmdline: %s\n' "$why" "$cmdline"
        return 1
    fi
    return 0
}

# ── Positive cases: these ARE Claude Code sessions ───────────────────────────

test_npm_layout_still_matches() {
    assert_cmdline_matches \
        "/home/u/.npm-global/lib/node_modules/@anthropic-ai/claude-code/cli.js --model opus" \
        "the npm cli.js layout must keep matching" || return 1
    assert_cmdline_matches \
        "/home/u/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/bin/claude.exe" \
        "the cc-mirror native-binary-under-npm layout must keep matching" || return 1
}
run_test "npm and cc-mirror layouts still match (no regression)" test_npm_layout_still_matches

test_bare_binary_is_recognised() {
    # GH#7: the reported failure. A command line that is a single absolute path
    # ending in /claude, with no claude-code/ segment anywhere.
    assert_cmdline_matches "/home/u/.local/bin/claude" \
        "a bare-binary install IS a Claude Code session — GH#7" || return 1
    assert_cmdline_matches "/usr/local/bin/claude" \
        "a system-wide bare binary IS a Claude Code session" || return 1
    assert_cmdline_matches "/home/u/.claude/local/claude --continue" \
        "a bare binary with arguments IS a Claude Code session" || return 1
}
run_test "GH#7: bare-binary install is recognised as a session" test_bare_binary_is_recognised

# ── Negative cases. Each of these would be worse than the bug if it matched: ──
# a false positive makes the mutex refuse sessions that have no rival at all.

test_does_not_match_the_launcher_wrapper() {
    # `mclaude` ends in "claude" but is NOT the session process — the launcher
    # wraps the real one. Matching it would count one session twice.
    assert_cmdline_rejected \
        "script -q -f -e -c /home/u/.local/bin/mclaude /home/u/proj/docs/terminal-logs/s.log" \
        "the mclaude launcher wrapper must not be mistaken for a session" || return 1
}
run_test "does not match the mclaude launcher wrapper" test_does_not_match_the_launcher_wrapper

test_does_not_match_incidental_claude_paths() {
    assert_cmdline_rejected "socat UNIX-LISTEN:/tmp/claude-http-9.sock,fork" \
        "a socket path that merely mentions claude is not a session" || return 1
    assert_cmdline_rejected "bash /home/u/.claude/hooks/safe-run.sh config-check.sh" \
        "a hook running out of ~/.claude is not a session" || return 1
    assert_cmdline_rejected "bash setup/tests/test-session-lock.sh" \
        "the test suite itself is not a session" || return 1
    assert_cmdline_rejected "vim /home/u/.claude/CLAUDE.md" \
        "editing a fleet file is not a session" || return 1
    assert_cmdline_rejected "git -C /home/u/cfg-agent-fleet commit -m claude" \
        "the word claude in an argument is not a session" || return 1
}
run_test "does not match incidental claude paths or arguments" test_does_not_match_incidental_claude_paths

# ── The live check. This is the one that only fails on a real machine, which ──
# is precisely why the bug survived: it cannot be caught by stubs.

test_live_session_is_self_recognised() {
    local pid found=""
    for pid in $(pgrep -x claude 2>/dev/null; pgrep -x claude.exe 2>/dev/null); do
        found="$pid"; break
    done
    if [ -z "$found" ]; then
        skip_test "no live Claude Code process to test against"
        return 0
    fi
    local cmd
    cmd=$(tr '\0' ' ' < "/proc/$found/cmdline" 2>/dev/null)
    assert_cmdline_matches "$cmd" \
        "the matcher must recognise the Claude Code process actually running on THIS machine"
}
run_test "live: this machine's own running session is recognised" test_live_session_is_self_recognised

suite_summary
