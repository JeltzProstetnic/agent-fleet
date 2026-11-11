#!/usr/bin/env bash
# Tests for global/hooks/dev-browser-close.sh — SessionEnd: close the dev browser this session opened.
#
# Owner's order (lrn, 2026-11-11): "no session ever closed ANY dev browser tab when finished with
# it. that must change … latest at shutdown, each session must close each dev browser tab it
# opened. not the normal google chrome tabs though". Hook at session end only — no sweep at start.
#
# Every case runs against a FIXTURE /proc tree (DBC_PROC_ROOT) and a recording kill mock
# (DBC_KILL_CMD): the hook never sees, signals or inspects a real process here. The fixtures mirror
# the measured shape of the real tree (WSL, 2026-11-11): claude.exe → `npm exec @playwright/mcp` →
# `sh -c playwright-mcp` → node playwright-mcp → /opt/google/chrome/chrome …
# --user-data-dir=$HOME/.cache/ms-playwright-mcp/mcp-chrome-<hash> (the browser MAIN process, no
# --type=) → helpers carrying --type=zygote|renderer|utility|gpu-process.
source "$(dirname "$0")/test-helpers.sh"

suite_header "dev-browser-close.sh (SessionEnd: close this session's dev browser)"

HOOK="$REPO_ROOT/global/hooks/dev-browser-close.sh"
SETTINGS="$REPO_ROOT/setup/config/settings.json"
CLAUDE_EXE="/opt/fixture/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
CHROME="/opt/google/chrome/chrome"

# ── Fixture builders ──────────────────────────────────────────────────────────

# fixture_init — fresh /proc root and kill mock under the sandboxed HOME; init as pid 1.
fixture_init() {
    PROC="$TEST_TMPDIR/proc"; KILL_LOG="$TEST_TMPDIR/kill.log"; KILL_MOCK="$TEST_TMPDIR/kill"
    MCP_ROOT="$HOME/.cache/ms-playwright-mcp"
    LOG_FILE="$HOME/.claude/logs/dev-browser-close.log"
    mkdir -p "$PROC"; : > "$KILL_LOG"
    cat > "$KILL_MOCK" <<'MOCK'
#!/usr/bin/env bash
# Recording kill: -0 = liveness of the fixture entry; -TERM removes the entry unless the pid is in
# DBC_TEST_IGNORE_TERM (a browser that ignores SIGTERM); -KILL always removes it.
printf '%s\n' "$*" >> "$DBC_TEST_KILL_LOG"
sig="$1"; pid="$2"; d="$DBC_PROC_ROOT/$pid"
case "$sig" in
    -0)        [ -d "$d" ] ;;
    -TERM|-15) [ -d "$d" ] || exit 1
               case " ${DBC_TEST_IGNORE_TERM:-} " in *" $pid "*) ;; *) rm -rf "$d" ;; esac ;;
    -KILL|-9)  [ -d "$d" ] || exit 1; rm -rf "$d" ;;
    *)         exit 1 ;;
esac
MOCK
    chmod +x "$KILL_MOCK"
    mkproc 1 0 /sbin/init /sbin/init
}

# mkproc <pid> <ppid> <exe> <argv...> — one /proc entry: stat (comm = exe basename), NUL-separated
# cmdline, exe symlink.
mkproc() {
    local pid="$1" ppid="$2" exe="$3"; shift 3
    local d="$PROC/$pid"; mkdir -p "$d"
    printf '%s (%s) S %s 1 1 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 0 0 0\n' \
        "$pid" "${exe##*/}" "$ppid" > "$d/stat"
    printf '%s\0' "$@" > "$d/cmdline"
    ln -sfn "$exe" "$d/exe"
}

# prof_hash <project root> — the Playwright MCP profile suffix: the first 7 hex digits of
# sha256(<path>). Verified 2026-11-11 against a live session: readlink of the claude process's cwd
# hashes to the hash in its browser's --user-data-dir; the same path with a trailing slash does not.
prof_hash() { printf '%s' "$1" | sha256sum | cut -c1-7; }

# mk_session <claude_pid> <claude_ppid> [cwd] — claude (cwd symlink, default /home/u/proj) →
# npm exec → sh -c → node playwright-mcp. Echoes the node pid (the browser's parent).
mk_session() {
    local c="$1"
    mkproc "$c" "$2" "$CLAUDE_EXE" "$CLAUDE_EXE"
    ln -sfn "${3:-/home/u/proj}" "$PROC/$c/cwd"
    mkproc "$((c+1))" "$c" /usr/bin/node npm exec @playwright/mcp
    mkproc "$((c+2))" "$((c+1))" /usr/bin/sh sh -c playwright-mcp
    mkproc "$((c+3))" "$((c+2))" /usr/bin/node node /home/u/.npm/_npx/abc/node_modules/.bin/playwright-mcp
    echo "$((c+3))"
}

# mk_browser <main_pid> <ppid> <hash> — a dev browser: MAIN process on the MCP profile, plus the
# helpers (main+1 zygote, main+2 renderer under the zygote, main+3 utility) that die with it.
mk_browser() {
    local m="$1" prof="$MCP_ROOT/mcp-chrome-$3"
    mkproc "$m" "$2" "$CHROME" "$CHROME" --disable-field-trial-config --user-data-dir="$prof" \
        --remote-debugging-pipe about:blank
    mkproc "$((m+1))" "$m" "$CHROME" "$CHROME" --type=zygote --user-data-dir="$prof"
    mkproc "$((m+2))" "$((m+1))" "$CHROME" "$CHROME" --type=renderer --user-data-dir="$prof"
    mkproc "$((m+3))" "$m" "$CHROME" "$CHROME" --type=utility \
        --utility-sub-type=network.mojom.NetworkService --user-data-dir="$prof"
}

# mk_hook_shells <ppid> <base_pid> — the hook's own shells as CC spawns them: `sh -c` → safe-run
# bash → hook bash. Echoes the pid a real run starts from ($PPID of the hook = safe-run's shell).
# Their command lines carry `.claude/hooks/` — the substring a sloppy claude matcher would bite on.
mk_hook_shells() {
    local b="$2"
    mkproc "$b" "$1" /usr/bin/sh sh -c "bash ~/.claude/hooks/safe-run.sh dev-browser-close.sh"
    mkproc "$((b+1))" "$b" /usr/bin/bash bash /home/u/.claude/hooks/safe-run.sh dev-browser-close.sh
    mkproc "$((b+2))" "$((b+1))" /usr/bin/bash bash /home/u/.claude/hooks/dev-browser-close.sh
    echo "$((b+1))"
}

# run_hook <start_pid> — runs the hook against the fixture; echoes its exit code.
run_hook() {
    local rc=0
    DBC_PROC_ROOT="$PROC" DBC_KILL_CMD="$KILL_MOCK" DBC_START_PID="$1" \
        DBC_TEST_KILL_LOG="$KILL_LOG" DBC_TEST_IGNORE_TERM="${IGNORE_TERM:-}" \
        bash "$HOOK" >"$TEST_TMPDIR/hook.out" 2>"$TEST_TMPDIR/hook.err" || rc=$?
    echo "$rc"
}

kill_calls() { tr '\n' ';' < "$KILL_LOG"; }

# ── The order itself ──────────────────────────────────────────────────────────

test_closes_own_dev_browser() {
    fixture_init
    local node start rc
    node=$(mk_session 100 1)
    mk_browser 200 "$node" aaaa
    start=$(mk_hook_shells 100 300)
    rc=$(run_hook "$start")
    assert_eq "0" "$rc" "hook exits 0 (stderr: $(cat "$TEST_TMPDIR/hook.err"))"
    assert_file_contains "$KILL_LOG" "^-TERM 200$" "SIGTERM goes to the browser MAIN pid"
    assert_eq "1" "$(grep -c -- '^-TERM ' "$KILL_LOG")" "exactly one SIGTERM — the main process, no helper"
    assert_file_not_contains "$KILL_LOG" "^-KILL" "no SIGKILL when SIGTERM is honoured"
    assert_file_contains "$LOG_FILE" "pid=200 .*mcp-chrome-aaaa.*result=closed" \
        "log line carries pid, profile dir and result"
    printf '    measured: kill calls = %s\n' "$(kill_calls)"
}
run_test "closes this session's dev browser: SIGTERM to the main process, logged" \
    test_closes_own_dev_browser

test_leaves_other_sessions_browser_alone() {
    fixture_init
    local mine theirs start rc
    mine=$(mk_session 100 1)
    theirs=$(mk_session 400 1)
    mk_browser 200 "$mine" aaaa
    mk_browser 500 "$theirs" bbbb
    start=$(mk_hook_shells 100 300)
    rc=$(run_hook "$start")
    assert_eq "0" "$rc" "hook exits 0"
    assert_file_contains "$KILL_LOG" "^-TERM 200$" "own browser is closed"
    assert_file_not_contains "$KILL_LOG" " 500$" "the other session's browser gets no signal at all"
    assert_dir_exists "$PROC/500" "the other session's browser is still there"
    printf '    measured: kill calls = %s\n' "$(kill_calls)"
}
run_test "leaves another session's dev browser alone" test_leaves_other_sessions_browser_alone

test_leaves_chrome_without_mcp_profile_alone() {
    fixture_init
    local node start rc
    node=$(mk_session 100 1)
    # A Chrome on the owner's own profile and one with no profile flag, both descendants.
    mkproc 200 "$node" "$CHROME" "$CHROME" --user-data-dir="$HOME/.config/google-chrome" https://x
    mkproc 210 "$node" "$CHROME" "$CHROME" --headless=new --dump-dom https://x
    # And a profile that merely CONTAINS the root name elsewhere in the path.
    mkproc 220 "$node" "$CHROME" "$CHROME" --user-data-dir="$HOME/other/ms-playwright-mcp/mcp-chrome-x"
    start=$(mk_hook_shells 100 300)
    rc=$(run_hook "$start")
    assert_eq "0" "$rc" "hook exits 0"
    assert_eq "0" "$(wc -l < "$KILL_LOG" | tr -d ' ')" "no signal sent (kill log: $(kill_calls))"
    assert_file_contains "$LOG_FILE" "no dev browser" "log says nothing was found"
}
run_test "leaves a Chrome without an ms-playwright-mcp profile alone" \
    test_leaves_chrome_without_mcp_profile_alone

test_ignores_helper_processes() {
    fixture_init
    local node start rc prof
    node=$(mk_session 100 1)
    prof="$MCP_ROOT/mcp-chrome-cccc"
    # Helpers only (the main already gone): every one carries --type= and the MCP profile.
    mkproc 201 "$node" "$CHROME" "$CHROME" --type=zygote --user-data-dir="$prof"
    mkproc 202 201 "$CHROME" "$CHROME" --type=renderer --user-data-dir="$prof"
    mkproc 203 "$node" "$CHROME" "$CHROME" --type=gpu-process --user-data-dir="$prof"
    start=$(mk_hook_shells 100 300)
    rc=$(run_hook "$start")
    assert_eq "0" "$rc" "hook exits 0"
    assert_eq "0" "$(wc -l < "$KILL_LOG" | tr -d ' ')" "helpers get no signal (kill log: $(kill_calls))"
}
run_test "ignores Chrome helper processes (--type=)" test_ignores_helper_processes

test_no_claude_ancestor() {
    fixture_init
    local start rc
    mkproc 50 1 /usr/bin/bash -bash                       # a terminal shell, not claude
    mk_browser 200 50 dddd                                 # a dev browser under it
    start=$(mk_hook_shells 50 300)
    rc=$(run_hook "$start")
    assert_eq "0" "$rc" "hook exits 0"
    assert_eq "0" "$(wc -l < "$KILL_LOG" | tr -d ' ')" "nothing is signalled without a claude ancestor"
    assert_file_contains "$LOG_FILE" "no claude ancestor" "log says why"
}
run_test "no claude ancestor: no kill, exit 0" test_no_claude_ancestor

test_no_browser_is_a_noop() {
    fixture_init
    local start rc
    mk_session 100 1 >/dev/null
    start=$(mk_hook_shells 100 300)
    rc=$(run_hook "$start")
    assert_eq "0" "$rc" "hook exits 0"
    assert_eq "0" "$(wc -l < "$KILL_LOG" | tr -d ' ')" "no signal sent"
    assert_file_contains "$LOG_FILE" "claude=100 .*no dev browser" "log names the claude pid and the no-op"
}
run_test "no browser: no-op, exit 0" test_no_browser_is_a_noop

test_vanished_or_unreadable_proc_entries() {
    fixture_init
    local start rc node
    # (a) the ancestor chain breaks: the hook shells hang under pid 999, which has no /proc entry.
    start=$(mk_hook_shells 999 300)
    rc=$(run_hook "$start")
    assert_eq "0" "$rc" "vanished ancestor: exit 0 (stderr: $(cat "$TEST_TMPDIR/hook.err"))"
    assert_eq "0" "$(wc -l < "$KILL_LOG" | tr -d ' ')" "vanished ancestor: nothing signalled"
    # (b) descendants with a stat but no cmdline, or an unreadable one, must not abort the scan.
    fixture_init
    node=$(mk_session 100 1)
    mk_browser 200 "$node" eeee
    mkdir -p "$PROC/250"; cp "$PROC/200/stat" "$PROC/250/stat"      # stat only, cmdline vanished
    mkproc 260 "$node" "$CHROME" "$CHROME" --user-data-dir="$MCP_ROOT/mcp-chrome-ffff"
    chmod 000 "$PROC/260/cmdline"
    start=$(mk_hook_shells 100 300)
    rc=$(run_hook "$start")
    chmod 644 "$PROC/260/cmdline" 2>/dev/null || true
    assert_eq "0" "$rc" "unreadable descendant: exit 0 (stderr: $(cat "$TEST_TMPDIR/hook.err"))"
    assert_file_contains "$KILL_LOG" "^-TERM 200$" "the readable browser is still closed"
    assert_file_not_contains "$KILL_LOG" " 260$" "an unreadable cmdline is never treated as a match"
    # A failed `< file` redirection is reported by the SHELL before a trailing 2>/dev/null applies;
    # measured on the real /proc (pids exiting mid-scan) as "line N: /proc/<pid>/cmdline: No such
    # file or directory" on the hook's stderr. Vanished entries must be silent.
    assert_eq "" "$(cat "$TEST_TMPDIR/hook.err")" "vanished/unreadable entries leave stderr empty"
}
run_test "vanished /proc entry mid-walk and unreadable entries: exit 0" \
    test_vanished_or_unreadable_proc_entries

test_sigkill_fallback_when_sigterm_ignored() {
    fixture_init
    local node start rc t0 t1
    node=$(mk_session 100 1)
    mk_browser 200 "$node" gggg
    start=$(mk_hook_shells 100 300)
    t0=$(date +%s%N)
    rc=$(IGNORE_TERM=200 run_hook "$start")
    t1=$(date +%s%N)
    assert_eq "0" "$rc" "hook exits 0"
    assert_eq "-TERM 200" "$(grep -- ' 200$' "$KILL_LOG" | grep -v -- '^-0' | head -1)" "SIGTERM first"
    assert_file_contains "$KILL_LOG" "^-KILL 200$" "SIGKILL follows when SIGTERM is ignored"
    assert_file_contains "$LOG_FILE" "pid=200 .*result=killed-with-sigkill" "log records the escalation"
    assert_dir_exists "$PROC/100" "claude itself is untouched"
    local ms=$(( (t1 - t0) / 1000000 ))
    [[ "$ms" -ge 2500 && "$ms" -lt 8000 ]] || { printf '    wait outside 2.5-8 s: %s ms\n' "$ms"; return 1; }
    printf '    measured: SIGTERM→SIGKILL after %s ms; kill calls = %s\n' "$ms" "$(kill_calls)"
}
run_test "SIGKILL fallback when SIGTERM is ignored, within the time budget" \
    test_sigkill_fallback_when_sigterm_ignored

test_never_matches_its_own_shell() {
    fixture_init
    local start rc
    mkproc 50 1 /usr/bin/bash -bash
    start=$(mk_hook_shells 50 300)                      # shells named …/.claude/hooks/…
    mk_browser 200 "$start" hhhh                        # a browser "under" the safe-run shell
    rc=$(run_hook "$start")
    assert_eq "0" "$rc" "hook exits 0"
    assert_eq "0" "$(wc -l < "$KILL_LOG" | tr -d ' ')" \
        "a shell whose argv carries .claude/hooks/ is not mistaken for claude (kill log: $(kill_calls))"
    assert_file_contains "$LOG_FILE" "no claude ancestor" "log says no claude ancestor"
}
run_test "never matches its own shell as the claude process" test_never_matches_its_own_shell

test_other_claude_binaries_match() {
    fixture_init
    local start rc
    # npm CLI form: node …/@anthropic-ai/claude-code/cli.js
    mkproc 100 1 /usr/bin/node node /home/u/.npm-global/lib/node_modules/@anthropic-ai/claude-code/cli.js
    mkproc 101 100 /usr/bin/node node /home/u/.npm/_npx/abc/node_modules/.bin/playwright-mcp
    mk_browser 200 101 iiii
    start=$(mk_hook_shells 100 300)
    rc=$(run_hook "$start")
    assert_eq "0" "$rc" "cli.js form: exit 0"
    assert_file_contains "$KILL_LOG" "^-TERM 200$" "cli.js form is recognised as claude"
    # native binary installed as plain `claude`
    fixture_init
    mkproc 100 1 /home/u/.local/bin/claude claude
    mkproc 101 100 /usr/bin/node node /home/u/.npm/_npx/abc/node_modules/.bin/playwright-mcp
    mk_browser 200 101 jjjj
    start=$(mk_hook_shells 100 300)
    rc=$(run_hook "$start")
    assert_eq "0" "$rc" "plain claude: exit 0"
    assert_file_contains "$KILL_LOG" "^-TERM 200$" "a binary named claude is recognised"
}
run_test "the npm cli.js and a plain 'claude' binary are recognised as the session process" \
    test_other_claude_binaries_match

test_stat_comm_with_spaces_and_parens() {
    fixture_init
    local node start rc
    node=$(mk_session 100 1)
    mk_browser 200 "$node" kkkk
    start=$(mk_hook_shells 100 300)
    # comm fields may contain spaces and ')' — the ppid must still be read from after the LAST ')'.
    printf '300 (sh) x (y) S 100 1 1 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 0 0 0\n' > "$PROC/300/stat"
    printf '200 (chrome (x)) S %s 1 1 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 0 0 0\n' "$node" > "$PROC/200/stat"
    rc=$(run_hook "$start")
    assert_eq "0" "$rc" "hook exits 0"
    assert_file_contains "$KILL_LOG" "^-TERM 200$" "walk survives a comm with spaces and parentheses"
}
run_test "stat comm with spaces and parentheses is parsed correctly" \
    test_stat_comm_with_spaces_and_parens

test_unwritable_log_never_blocks() {
    fixture_init
    local node start rc
    node=$(mk_session 100 1)
    mk_browser 200 "$node" llll
    start=$(mk_hook_shells 100 300)
    mkdir -p "$HOME/.claude"; : > "$HOME/.claude/logs"        # a FILE where the log dir should be
    rc=$(run_hook "$start")
    assert_eq "0" "$rc" "hook exits 0 even when it cannot log (stderr: $(cat "$TEST_TMPDIR/hook.err"))"
    assert_file_contains "$KILL_LOG" "^-TERM 200$" "the browser is still closed"
}
run_test "an unwritable log never blocks the close or the exit" test_unwritable_log_never_blocks

# ── Second qualifier: this project's profile, even when reparented ───────────
# If the MCP server dies before SessionEnd hooks run, the browser is reparented and is no longer a
# descendant. Its profile still names the project: mcp-chrome-<sha256(claude cwd)[:7]>.

test_reparented_browser_with_own_profile_is_closed() {
    fixture_init
    local start rc h
    mk_session 100 1 /home/u/proj >/dev/null
    h=$(prof_hash /home/u/proj)
    mk_browser 200 1 "$h"                                  # reparented to init, no MCP parent left
    start=$(mk_hook_shells 100 300)
    rc=$(run_hook "$start")
    assert_eq "0" "$rc" "hook exits 0 (stderr: $(cat "$TEST_TMPDIR/hook.err"))"
    assert_file_contains "$KILL_LOG" "^-TERM 200$" "a reparented browser on this project's profile is closed"
    assert_file_contains "$LOG_FILE" "pid=200 .*mcp-chrome-$h.*result=closed" "log names the profile"
    printf '    measured: profile hash %s; kill calls = %s\n' "$h" "$(kill_calls)"
}
run_test "reparented Chrome with this project's profile (no MCP parent) is closed" \
    test_reparented_browser_with_own_profile_is_closed

test_trailing_slash_hash_does_not_match() {
    fixture_init
    local start rc
    mk_session 100 1 /home/u/proj >/dev/null
    mk_browser 200 1 "$(prof_hash /home/u/proj/)"           # hash of the path WITH a trailing slash
    start=$(mk_hook_shells 100 300)
    rc=$(run_hook "$start")
    assert_eq "0" "$rc" "hook exits 0"
    assert_eq "0" "$(wc -l < "$KILL_LOG" | tr -d ' ')" \
        "the cwd is hashed exactly as reported, no trailing slash (kill log: $(kill_calls))"
    assert_file_contains "$LOG_FILE" "no dev browser" "nothing qualifies"
}
run_test "a profile hashed from the cwd WITH a trailing slash is not this session's" \
    test_trailing_slash_hash_does_not_match

test_same_project_other_live_session_keeps_its_browser() {
    fixture_init
    local theirs start rc h
    h=$(prof_hash /home/u/proj)
    mk_session 100 1 /home/u/proj >/dev/null               # ours, no browser
    theirs=$(mk_session 400 1 /home/u/proj)                # another live session, same project
    mk_browser 500 "$theirs" "$h"                          # its browser carries OUR profile hash
    start=$(mk_hook_shells 100 300)
    rc=$(run_hook "$start")
    assert_eq "0" "$rc" "hook exits 0"
    assert_eq "0" "$(wc -l < "$KILL_LOG" | tr -d ' ')" \
        "a browser under a different live claude is never touched (kill log: $(kill_calls))"
    assert_dir_exists "$PROC/500" "the other session's browser is still there"
}
run_test "Chrome with this project's profile under another live claude is left alone" \
    test_same_project_other_live_session_keeps_its_browser

test_reparented_browser_of_another_project_is_left_alone() {
    fixture_init
    local start rc
    mk_session 100 1 /home/u/proj >/dev/null
    mk_browser 200 1 "$(prof_hash /home/u/other-project)"  # reparented, another project's profile
    start=$(mk_hook_shells 100 300)
    rc=$(run_hook "$start")
    assert_eq "0" "$rc" "hook exits 0"
    assert_eq "0" "$(wc -l < "$KILL_LOG" | tr -d ' ')" \
        "another project's orphaned browser is not ours to close (kill log: $(kill_calls))"
    assert_dir_exists "$PROC/200" "it is still there"
}
run_test "reparented Chrome with another project's profile is left alone" \
    test_reparented_browser_of_another_project_is_left_alone

test_unreadable_cwd_disables_only_the_profile_qualifier() {
    fixture_init
    local node start rc
    node=$(mk_session 100 1 /home/u/proj)
    rm -f "$PROC/100/cwd"                                  # cwd unreadable: no project hash
    mk_browser 200 "$node" aaaa                            # still a descendant → closed
    mk_browser 210 1 "$(prof_hash /home/u/proj)"           # reparented: cannot be attributed now
    start=$(mk_hook_shells 100 300)
    rc=$(run_hook "$start")
    assert_eq "0" "$rc" "hook exits 0 (stderr: $(cat "$TEST_TMPDIR/hook.err"))"
    assert_file_contains "$KILL_LOG" "^-TERM 200$" "the descendant is still closed"
    assert_file_not_contains "$KILL_LOG" " 210$" "without a cwd no reparented browser is claimed"
}
run_test "an unreadable claude cwd disables only the profile qualifier" \
    test_unreadable_cwd_disables_only_the_profile_qualifier

# ── Registration and size ─────────────────────────────────────────────────────

test_registered_under_session_end() {
    local info
    info=$(python3 - "$SETTINGS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
hooks = [h for g in d["hooks"]["SessionEnd"] for h in g["hooks"] if h.get("type") == "command"]
ours = [i for i, h in enumerate(hooks) if "dev-browser-close.sh" in h["command"]]
sync = [i for i, h in enumerate(hooks) if "config-auto-sync.sh" in h["command"]]
budget = int(d.get("env", {}).get("CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS", "0"))
cmd = hooks[ours[0]]["command"] if ours else ""
timeout = hooks[ours[0]].get("timeout", 600) if ours else 0
print(f"ours={ours} sync={sync} timeout_s={timeout} budget_ms={budget} cmd={cmd}")
PY
)
    assert_contains "$info" "cmd=bash ~/.claude/hooks/safe-run.sh dev-browser-close.sh" \
        "registered via safe-run.sh ($info)"
    assert_contains "$info" "ours=[0] sync=[1]" "runs ahead of config-auto-sync.sh ($info)"
    local t b
    t=$(printf '%s' "$info" | sed -E 's/.*timeout_s=([0-9]+).*/\1/')
    b=$(printf '%s' "$info" | sed -E 's/.*budget_ms=([0-9]+).*/\1/')
    [[ $((t * 1000)) -le $((b / 4)) ]] || { printf '    timeout %ss is not well inside the %sms SessionEnd budget\n' "$t" "$b"; return 1; }
    printf '    measured: %s\n' "$info"
}
run_test "registered under SessionEnd through safe-run.sh, before config-auto-sync.sh, with a bounded timeout" \
    test_registered_under_session_end

test_hook_size() {
    local lines longest
    assert_file_exists "$HOOK" "the hook exists" || return 1
    lines=$(wc -l < "$HOOK" | tr -d ' ')
    longest=$(awk '/^[a-z_]+\(\) \{/ { n = 0; infn = 1 } infn { n++ } /^\}/ && infn { if (n > max) max = n; infn = 0 } END { print max + 0 }' "$HOOK")
    [[ "$lines" -le 100 ]] || { printf '    hook is %s lines (limit 100)\n' "$lines"; return 1; }
    [[ "$longest" -le 50 ]] || { printf '    longest function is %s lines (limit 50)\n' "$longest"; return 1; }
    printf '    measured: %s lines, longest function %s lines\n' "$lines" "$longest"
}
run_test "hook stays within 100 lines and functions within 50" test_hook_size

suite_summary
