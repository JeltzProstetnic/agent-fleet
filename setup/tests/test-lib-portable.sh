#!/usr/bin/env bash
# test-lib-portable.sh — Tests for portable wrappers (_sed_i, _readlink_f, _stat_mtime, _stat_size)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

NO_COLOR=true source "$REPO_ROOT/setup/lib.sh"

PASS=0 FAIL=0
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

# === _sed_i ===
echo "=== _sed_i ==="

echo "hello world" > "$TEST_TMPDIR/sed-test.txt"
_sed_i 's/hello/goodbye/' "$TEST_TMPDIR/sed-test.txt"
assert_eq "replaces text in-place" "goodbye world" "$(cat "$TEST_TMPDIR/sed-test.txt")"

printf 'line1\nline2\nline3\n' > "$TEST_TMPDIR/sed-multi.txt"
_sed_i '/line2/d' "$TEST_TMPDIR/sed-multi.txt"
assert_eq "deletes matching line" "2" "$(wc -l < "$TEST_TMPDIR/sed-multi.txt" | tr -d ' ')"

echo "aaa bbb aaa" > "$TEST_TMPDIR/sed-expr.txt"
_sed_i -e 's/aaa/xxx/g' "$TEST_TMPDIR/sed-expr.txt"
assert_eq "handles -e flag" "xxx bbb xxx" "$(cat "$TEST_TMPDIR/sed-expr.txt")"

# === _readlink_f ===
echo "=== _readlink_f ==="

echo "target" > "$TEST_TMPDIR/real-file.txt"
ln -sf "$TEST_TMPDIR/real-file.txt" "$TEST_TMPDIR/symlink.txt"
result=$(_readlink_f "$TEST_TMPDIR/symlink.txt")
assert_eq "resolves symlink" "$TEST_TMPDIR/real-file.txt" "$result"

result=$(_readlink_f "$TEST_TMPDIR/real-file.txt")
assert_eq "resolves regular file" "$TEST_TMPDIR/real-file.txt" "$result"

ln -sf "$TEST_TMPDIR/symlink.txt" "$TEST_TMPDIR/chain.txt"
result=$(_readlink_f "$TEST_TMPDIR/chain.txt")
assert_eq "resolves chained symlinks" "$TEST_TMPDIR/real-file.txt" "$result"

# Relative path test
pushd "$TEST_TMPDIR" > /dev/null
result=$(_readlink_f "symlink.txt")
assert_eq "resolves relative symlink" "$TEST_TMPDIR/real-file.txt" "$result"
popd > /dev/null

# === _stat_mtime ===
echo "=== _stat_mtime ==="

touch "$TEST_TMPDIR/mtime-test.txt"
mtime=$(_stat_mtime "$TEST_TMPDIR/mtime-test.txt")
assert_eq "returns epoch seconds (numeric)" "true" "$([[ "$mtime" =~ ^[0-9]+$ ]] && echo true || echo false)"
now=$(date +%s)
diff=$(( now - mtime ))
assert_eq "mtime within 5s of now" "true" "$([[ $diff -ge 0 && $diff -lt 5 ]] && echo true || echo false)"

# === _stat_size ===
echo "=== _stat_size ==="

printf '12345' > "$TEST_TMPDIR/size-test.txt"
size=$(_stat_size "$TEST_TMPDIR/size-test.txt")
assert_eq "returns correct file size" "5" "$size"

: > "$TEST_TMPDIR/empty.txt"
size=$(_stat_size "$TEST_TMPDIR/empty.txt")
assert_eq "empty file is 0 bytes" "0" "$size"

# === _timeout (GH agent-fleet#5) ===
# macOS ships no GNU `timeout`, so every `timeout N cmd … || true` exited 127 and the
# `|| true` hid it — afleet's git sync silently never ran. `_timeout` must behave like
# GNU timeout (status passthrough, 124 on expiry) on every backend it may fall back to.
echo "=== _timeout ==="

_to_rc() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }

# Run "$@" (in a subshell) for at most <secs>. Prints the rc, or "hung" when it had to be
# killed. Needs no timeout binary — this file tests the thing that replaces one.
_bounded_rc() {
    local secs="$1"; shift
    local f; f=$(mktemp "$TEST_TMPDIR/bounded.XXXXXX")
    ( rc=0; "$@" >/dev/null 2>&1 </dev/null || rc=$?; echo "$rc" > "$f" ) &
    local pid=$! i=0
    while [[ ! -s "$f" ]] && (( i < secs * 10 )); do sleep 0.1; i=$((i + 1)); done
    if [[ -s "$f" ]]; then wait "$pid" 2>/dev/null; cat "$f"
    else pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null; echo hung; fi
}
_bounded_out() {  # <secs> <cmd…> → the command's stdout, or nothing when it had to be killed
    local secs="$1"; shift
    local f; f=$(mktemp "$TEST_TMPDIR/bounded.XXXXXX")
    ( "$@" > "$f.out" 2>&1; echo done > "$f" ) &
    local pid=$! i=0
    while [[ ! -s "$f" ]] && (( i < secs * 10 )); do sleep 0.1; i=$((i + 1)); done
    if [[ -s "$f" ]]; then wait "$pid" 2>/dev/null; tr -d '\r' < "$f.out"
    else pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null; fi
}

for impl in auto perl bash; do
    if [[ "$impl" == "perl" ]] && ! command -v perl >/dev/null 2>&1; then
        echo "  SKIP: $impl backend (perl not installed)"; continue
    fi
    if [[ "$impl" == "auto" ]]; then unset _PORTABLE_TIMEOUT_IMPL; else export _PORTABLE_TIMEOUT_IMPL="$impl"; fi

    assert_eq "[$impl] _timeout is defined" "function" "$(type -t _timeout 2>/dev/null || echo missing)"
    assert_eq "[$impl] passes through exit 0" "0" "$(_to_rc _timeout 5 true)"
    assert_eq "[$impl] passes through a non-zero exit" "3" "$(_to_rc _timeout 5 sh -c 'exit 3')"
    assert_eq "[$impl] missing command is 127" "127" "$(_to_rc _timeout 5 no-such-cmd-xyz)"
    assert_eq "[$impl] passes stdout through" "hi" "$(_timeout 5 echo hi 2>/dev/null || true)"
    assert_eq "[$impl] passes piped stdin through" "piped" "$(echo piped | _timeout 3 cat 2>/dev/null || true)"

    t0=$(date +%s)
    rc=$(_to_rc _timeout 1 sleep 20)
    el=$(( $(date +%s) - t0 ))
    assert_eq "[$impl] expiry returns 124" "124" "$rc"
    assert_eq "[$impl] expiry actually bounds the run (<5s, took ${el}s)" "true" "$([[ $el -lt 5 ]] && echo true || echo false)"

    # A fast command inside $(…) must not wait for the watchdog to run out.
    t0=$(date +%s)
    out=$(_timeout 15 echo quick 2>/dev/null || true)
    el=$(( $(date +%s) - t0 ))
    assert_eq "[$impl] fast command returns output" "quick" "$out"
    assert_eq "[$impl] fast command in \$(…) returns promptly (<5s, took ${el}s)" "true" "$([[ $el -lt 5 ]] && echo true || echo false)"

    # A STOPPED command must still be bounded. git/ssh asking for a passphrase, a host key
    # or an https username on /dev/tty from a background process group get SIGTTIN and
    # stop; a stopped process keeps a TERM pending forever. GNU timeout sends TERM then
    # CONT; a backend that sends only TERM hangs the afleet launcher with nothing on screen.
    # kill -STOP is the same state without needing a terminal. Bounded from outside so a
    # regression fails instead of hanging the suite.
    rc=$(_bounded_rc 12 _timeout 2 sh -c 'kill -STOP $$; sleep 30')
    assert_eq "[$impl] a stopped command is still killed at expiry (124, not a hang)" "124" "$rc"

    # GNU timeout's duration suffixes: 1m is sixty seconds, not one.
    assert_eq "[$impl] duration suffix: _timeout 1m does not expire after 1s" "0" "$(_to_rc _timeout 1m sleep 2)"
done
unset _PORTABLE_TIMEOUT_IMPL

# The real trigger: the command reads the controlling terminal (a credential prompt).
# script(1) gives the run a pty, like an interactive afleet launch. util-linux only.
echo "=== _timeout with a controlling terminal ==="
if command -v perl >/dev/null 2>&1 && script -qec true /dev/null </dev/null >/dev/null 2>&1; then
    for impl in perl bash; do
        out=$(_bounded_out 20 script -qec "bash -c 'source \"$REPO_ROOT/global/hooks/lib-portable.sh\"; _PORTABLE_TIMEOUT_IMPL=$impl _timeout 2 bash -c \"read -r x </dev/tty\"; echo inner_rc=\$?'" /dev/null </dev/null)
        case "$out" in *inner_rc=*) out="returned" ;; *) out="hung" ;; esac
        assert_eq "[$impl] a /dev/tty read under a pty returns at expiry instead of hanging" "returned" "$out"
    done
else
    echo "  SKIP: needs perl and util-linux script(1)"
fi

# === native Windows helpers (CFG-335 launcher path, CFG-336 native paths; CFG-1087 slice 1) ===
# Git for Windows bash: OSTYPE is `msys` (older) or `cygwin` (2.55 measured 2026-11-25); native
# Windows programs (Python, node) do not understand /c/Users/... — `cygpath -m` gives C:/Users/...;
# cc-mirror writes the launcher to ~/.cc-mirror/bin/<variant>.cmd there, ~/.local/bin/<variant> elsewhere.
echo "=== native Windows helpers (CFG-335, CFG-336) ==="

mkdir -p "$TEST_TMPDIR/fakebin"
printf '#!/usr/bin/env bash\n[ "$1" = -m ] && { echo "C:/conv$2"; exit 0; }\nexit 2\n' > "$TEST_TMPDIR/fakebin/cygpath"
chmod +x "$TEST_TMPDIR/fakebin/cygpath"
_np() { ( OSTYPE="$1"; PATH="$TEST_TMPDIR/fakebin:$PATH"; _to_native_path "$2" ); }

assert_eq "_to_native_path is a no-op on Linux" "/tmp/a b/c.json" "$(_np linux-gnu '/tmp/a b/c.json')"
assert_eq "_to_native_path converts through cygpath -m on msys" "C:/conv/tmp/a b/c.json" "$(_np msys '/tmp/a b/c.json')"
assert_eq "_to_native_path converts on cygwin too (Git for Windows 2.55 reports OSTYPE=cygwin)" "C:/conv/x" "$(_np cygwin /x)"
assert_eq "_to_native_path without cygpath returns the input" "/x" "$( OSTYPE=msys; PATH=/nonexistent; _to_native_path /x )"

assert_eq "_is_native_windows: false on linux-gnu" "1" "$( OSTYPE=linux-gnu; unset PLATFORM; _to_rc _is_native_windows )"
assert_eq "_is_native_windows: true on msys" "0" "$( OSTYPE=msys; _to_rc _is_native_windows )"
assert_eq "_is_native_windows: true on cygwin" "0" "$( OSTYPE=cygwin; _to_rc _is_native_windows )"
assert_eq "_is_native_windows: sync.sh's PLATFORM=windows counts too" "0" "$( OSTYPE=linux-gnu; PLATFORM=windows; _to_rc _is_native_windows )"
assert_eq "_is_native_windows: WSL is not native Windows" "1" "$( OSTYPE=linux-gnu; PLATFORM=wsl; _to_rc _is_native_windows )"

assert_eq "_cc_launcher_path: Linux/macOS/WSL default" "$HOME/.local/bin/mclaude" "$( OSTYPE=linux-gnu; unset PLATFORM; _cc_launcher_path )"
assert_eq "_cc_launcher_path: Git Bash .cmd launcher" "$HOME/.cc-mirror/bin/mclaude.cmd" "$( OSTYPE=msys; _cc_launcher_path )"
assert_eq "_cc_launcher_path: variant argument" "$HOME/.cc-mirror/bin/xclaude.cmd" "$( OSTYPE=cygwin; _cc_launcher_path xclaude )"

_h="$TEST_TMPDIR/launcher-home"; mkdir -p "$_h/.local/bin" "$_h/.cc-mirror/bin"
assert_eq "_cc_launcher_find: nothing installed → rc 1" "1" "$( HOME="$_h"; OSTYPE=msys; _to_rc _cc_launcher_find )"
touch "$_h/.local/bin/mclaude"
assert_eq "_cc_launcher_find: accepts the other platform's location" "$_h/.local/bin/mclaude" "$( HOME="$_h"; OSTYPE=msys; _cc_launcher_find )"
touch "$_h/.cc-mirror/bin/mclaude.cmd"
assert_eq "_cc_launcher_find: the platform default wins when both exist" "$_h/.cc-mirror/bin/mclaude.cmd" "$( HOME="$_h"; OSTYPE=msys; _cc_launcher_find )"
assert_eq "_cc_launcher_find: Linux default" "$_h/.local/bin/mclaude" "$( HOME="$_h"; OSTYPE=linux-gnu; unset PLATFORM; _cc_launcher_find )"

# === Python resolution (CFG-1087 slice 2) ===
# Git for Windows: `python3` is often only the Microsoft Store redirector, which prints "Python was
# not found; run without arguments to install from the Microsoft Store…" and EXITS 0 (measured
# 2026-11-25), so `command -v python3` passes and every call fails. The helper probes python3, python,
# `py -3` by their --version banner and states what it found. Off native Windows it returns python3
# WITHOUT probing — Linux/macOS/WSL behaviour is byte-for-byte unchanged.
echo "=== Python resolution: _fleet_python / _python3 / _python_report (CFG-1087) ==="

_PYSTUB="$TEST_TMPDIR/pystub"; mkdir -p "$_PYSTUB/store" "$_PYSTUB/py" "$_PYSTUB/none" "$_PYSTUB/recorder"
# the Store redirector shape: message on stdout, exit 0
printf '#!/usr/bin/env bash\necho "Python was not found; run without arguments to install from the Microsoft Store, or disable this shortcut from Settings > Apps > Advanced app settings > App execution aliases."\nexit 0\n' > "$_PYSTUB/store/python3"
# a real `python` beside it
printf '#!/usr/bin/env bash\n[ "$1" = --version ] && { echo "Python 3.11.9"; exit 0; }\necho "python-stub ran: $*"\n' > "$_PYSTUB/store/python"
# only the `py` launcher answers, and only to -3
cp "$_PYSTUB/store/python3" "$_PYSTUB/py/python3"; cp "$_PYSTUB/store/python3" "$_PYSTUB/py/python"
printf '#!/usr/bin/env bash\n[ "$1" = -3 ] && [ "$2" = --version ] && { echo "Python 3.12.1"; exit 0; }\n[ "$1" = -3 ] && { shift; echo "py-stub ran: $*"; exit 0; }\nexit 103\n' > "$_PYSTUB/py/py"
# nothing usable: python3 and python are redirectors, py is the launcher with no Python behind it
# (all three stubbed, so the host's own interpreters cannot answer through PATH)
cp "$_PYSTUB/store/python3" "$_PYSTUB/none/python3"; cp "$_PYSTUB/store/python3" "$_PYSTUB/none/python"
printf '#!/usr/bin/env bash\nexit 103\n' > "$_PYSTUB/none/py"
# a recorder: every --version probe leaves a line in $_PYSTUB/probes
printf '#!/usr/bin/env bash\necho "python3 $*" >> "%s/probes"\nexec /usr/bin/env python3 "$@"\n' "$_PYSTUB" > "$_PYSTUB/recorder/python3"
chmod +x "$_PYSTUB"/*/*

# Fresh resolution in a subshell: <OSTYPE> <stub dir> <cmd…>
_pyrun() { ( OSTYPE="$1"; unset PLATFORM; PATH="$2:$PATH"; _FLEET_PYTHON=""; _FLEET_PYTHON_WHY=""; shift 2; "$@" ); }

assert_eq "_fleet_python is defined" "function" "$(type -t _fleet_python 2>/dev/null || echo missing)"
assert_eq "_python3 is defined" "function" "$(type -t _python3 2>/dev/null || echo missing)"
assert_eq "_python_report is defined" "function" "$(type -t _python_report 2>/dev/null || echo missing)"

rm -f "$_PYSTUB/probes"
assert_eq "Linux: _fleet_python is python3" "python3" "$(_pyrun linux-gnu "$_PYSTUB/recorder" _fleet_python)"
assert_eq "Linux: no probe ran (byte-for-byte unchanged)" "0" "$(wc -l < "$_PYSTUB/probes" 2>/dev/null | tr -d ' ' || echo 0)"
assert_eq "Linux: _python3 runs the real interpreter" "42" "$(_pyrun linux-gnu /nonexistent _python3 -c 'print(6*7)')"
assert_eq "Linux: _python3 passes stdin" "hi" "$(echo hi | _pyrun linux-gnu /nonexistent _python3 -c 'import sys; print(sys.stdin.read().strip())')"
case "$(_pyrun linux-gnu /nonexistent _python_report)" in
    python3*unprobed*) assert_eq "Linux: report says python3, unprobed" "ok" "ok" ;;
    *) assert_eq "Linux: report says python3, unprobed" "python3 … unprobed" "$(_pyrun linux-gnu /nonexistent _python_report)" ;;
esac
assert_eq "WSL (PLATFORM=wsl) is not probed either" "python3" "$( OSTYPE=linux-gnu; PLATFORM=wsl; PATH="$_PYSTUB/store:$PATH"; _FLEET_PYTHON=""; _fleet_python )"

assert_eq "Windows (cygwin): the Store redirector is rejected although it exits 0; python wins" "python" "$(_pyrun cygwin "$_PYSTUB/store" _fleet_python)"
assert_eq "Windows (msys spelling) probes too" "python" "$(_pyrun msys "$_PYSTUB/store" _fleet_python)"
assert_eq "Windows: _python3 runs the resolved interpreter with its args" "python-stub ran: -c print(1)" "$(_pyrun cygwin "$_PYSTUB/store" _python3 -c 'print(1)')"
_rep=$(_pyrun cygwin "$_PYSTUB/store" _python_report)
assert_eq "Windows: report names the chosen command first" "python — " "${_rep:0:9}"
case "$_rep" in *"python3"*"Python was not found"*) assert_eq "Windows: report says why python3 was rejected" "ok" "ok" ;; *) assert_eq "Windows: report says why python3 was rejected" "…python3 … Python was not found…" "$_rep" ;; esac
case "$_rep" in *'python answers "Python 3.11.9"'*) assert_eq "Windows: report quotes the winner's banner" "ok" "ok" ;; *) assert_eq "Windows: report quotes the winner's banner" '…python answers "Python 3.11.9"…' "$_rep" ;; esac

assert_eq "Windows: python3 and python unusable → py -3" "py -3" "$(_pyrun cygwin "$_PYSTUB/py" _fleet_python)"
assert_eq "Windows: _python3 through the py launcher keeps the args" "py-stub ran: -c print(2)" "$(_pyrun cygwin "$_PYSTUB/py" _python3 -c 'print(2)')"

assert_eq "Windows: nothing usable → _fleet_python rc 1" "1" "$(_pyrun cygwin "$_PYSTUB/none" _to_rc _fleet_python)"
assert_eq "Windows: nothing usable → _fleet_python prints nothing" "" "$(_pyrun cygwin "$_PYSTUB/none" _fleet_python 2>/dev/null)"
assert_eq "Windows: nothing usable → _python3 rc 127 (as a missing python3 would)" "127" "$(_pyrun cygwin "$_PYSTUB/none" _to_rc _python3 -c 'print(3)')"
_rep=$(_pyrun cygwin "$_PYSTUB/none" _python_report)
assert_eq "Windows: nothing usable → report starts with none" "none — " "${_rep:0:7}"

# two _fleet_python calls + one _python3 run: the probe hits the stub once, the run itself is the second hit
assert_eq "the result is cached: two resolutions and one run invoke the interpreter twice, not three times" "2" "$( OSTYPE=cygwin; unset PLATFORM; PATH="$_PYSTUB/store:$PATH"; _FLEET_PYTHON=""; _FLEET_PYTHON_WHY=""; printf '#!/usr/bin/env bash\necho probed >> "%s/count"\necho "Python 3.9.0"\n' "$_PYSTUB" > "$_PYSTUB/store/python3"; rm -f "$_PYSTUB/count"; _fleet_python >/dev/null; _fleet_python >/dev/null; _python3 --version >/dev/null; wc -l < "$_PYSTUB/count" | tr -d ' ' )"
cp "$_PYSTUB/none/python3" "$_PYSTUB/store/python3"
assert_eq "a pre-set _FLEET_PYTHON is honoured without probing" "python" "$( OSTYPE=cygwin; PATH="$_PYSTUB/none:$PATH"; _FLEET_PYTHON=python; _fleet_python )"

# _have_python3 replaces the hooks' `command -v python3` guards (CFG-1087 slice 3). Off native
# Windows it IS `command -v python3` — same verdict, no probe — so a Linux box without python3
# still takes the hooks' grep/sed fallbacks exactly as before. On Git Bash `command -v python3`
# is true for the Store redirector, so there the probe's verdict decides.
echo "=== _have_python3 (the guard) ==="
assert_eq "_have_python3 is defined" "function" "$(type -t _have_python3 2>/dev/null || echo missing)"
rm -f "$_PYSTUB/probes"
assert_eq "Linux: true when python3 is on PATH" "0" "$(_pyrun linux-gnu "$_PYSTUB/recorder" _to_rc _have_python3)"
assert_eq "Linux: no probe ran — it is command -v" "0" "$(wc -l < "$_PYSTUB/probes" 2>/dev/null | tr -d ' ' || echo 0)"
assert_eq "Linux: false when nothing on PATH is called python3" "1" "$( OSTYPE=linux-gnu; unset PLATFORM; PATH="$_PYSTUB/none-at-all"; _FLEET_PYTHON=""; _to_rc _have_python3 )"
assert_eq "Linux: the Store-shaped stub counts as present (command -v semantics, unchanged)" "0" "$( OSTYPE=linux-gnu; unset PLATFORM; PATH="$_PYSTUB/none"; _FLEET_PYTHON=""; _to_rc _have_python3 )"
assert_eq "Windows: true when the probe finds an interpreter (python behind the redirector)" "0" "$(_pyrun cygwin "$_PYSTUB/store" _to_rc _have_python3)"
assert_eq "Windows: false when python3/python/py are all unusable although command -v python3 is true" "1" "$(_pyrun cygwin "$_PYSTUB/none" _to_rc _have_python3)"

# The ported call sites: no bare `python3 …` invocation may remain in these files (comments and
# apt/brew package names aside) — on Git Bash a bare one hits the Store redirector.
# Slice 3 adds the hook files: every hook and hook library that runs Python. A `python3 ~/…` inside
# an INBOX_MSG string is an instruction handed to the model, not a call, and is excused.
echo "=== no bare python3 left in the ported call sites ==="
for _f in global/hooks/config-check.sh global/hooks/checks/04-auto-fix.sh sync-lib/setup.sh sync-lib/deploy.sh \
          sync-lib/pre-deploy.sh setup/scripts/afleet.sh setup/scripts/afleet-recover.sh \
          setup/scripts/cc-install-invariants.sh setup/scripts/cc-update.sh \
          setup/scripts/install-voltagent.sh setup/scripts/install-skill-collections.sh \
          global/hooks/afd-idle-wake.sh global/hooks/afd-relay.sh global/hooks/afk-deactivate.sh \
          global/hooks/auto-lint.sh global/hooks/checks/06b-lock-knowledge.sh global/hooks/checks/07-environment.sh \
          global/hooks/checks/07b-platform-env.sh global/hooks/checks/21-fleet-issues.sh \
          global/hooks/checks/27-unscoped-kill.sh global/hooks/checks/28-azure-ai.sh global/hooks/checks/29-life-awaiting.sh \
          global/hooks/cloud-publish-guard.sh global/hooks/cloud-routine-guard.sh global/hooks/commit-verify.sh \
          global/hooks/compound-cd-warn.sh global/hooks/context-budget.sh global/hooks/credential-read-guard.sh \
          global/hooks/critical-edit-notify.sh global/hooks/email-file-guard.sh global/hooks/kill-guard.sh \
          global/hooks/lib-afd-ask.sh global/hooks/lib-afd-asked.sh global/hooks/lib-afd-forward.sh \
          global/hooks/lib-afd-msg.sh global/hooks/lib-afd-pool.sh global/hooks/lib-afd-scan.sh \
          global/hooks/lib-commit-message-strip.sh global/hooks/lib-commit-scan.sh global/hooks/lib-hook-stdin.sh \
          global/hooks/lib-prose-strip.sh global/hooks/lib-recipient-comms.sh global/hooks/lib-rule-removal.sh \
          global/hooks/lib-secret-detect.sh global/hooks/pkill-guard.sh global/hooks/playwright-value-guard.sh \
          global/hooks/rule-removal-guard.sh global/hooks/secret-commit-guard.sh global/hooks/sent-recently.sh \
          global/hooks/shutdown-follow.sh global/hooks/tool-install-detect.sh global/hooks/vault-read-guard.sh; do
    # `command -v python3` is NOT excused: it is true on Git Bash (the redirector exists) and is the guard that lets the broken call through.
    # Excused: whole-line and trailing comments (a ` # …` tail without quotes), and plain `echo "…"` messages that name python3.
    _bare=$(grep -nE '(^|[^_A-Za-z0-9./"-])python3( |$|\))' "$REPO_ROOT/$_f" \
            | sed -E "s/[[:space:]]#[^\"']*\$//" | grep -E '(^|[^_A-Za-z0-9./"-])python3( |$|\))' \
            | grep -vE '^[0-9]+:[[:space:]]*#' \
            | grep -vE '_python3|_fleet_python|"python3"|^[0-9]+:[[:space:]]*python3$|INBOX_MSG=.*python3 ~/|^[0-9]+:[[:space:]]*echo "[^$]*$' || true)
    assert_eq "no bare python3 call in $_f" "" "$_bare"
done

# Every hook that runs Python must reach _python3 even where lib-portable.sh is not beside it (a
# fixture hooks dir, a partial deploy): it either sources lib-portable.sh itself, is a checks/ module
# (config-check.sh loads the lib before sourcing it), or defines the Linux fallback.
echo "=== every ported hook can resolve _python3 ==="
for _f in "$REPO_ROOT"/global/hooks/*.sh "$REPO_ROOT"/global/hooks/checks/*.sh; do
    grep -qE '(^|[^_A-Za-z])_python3|_have_python3|_fleet_python' "$_f" || continue
    [[ "$(basename "$_f")" == lib-portable.sh ]] && continue
    if grep -qE 'lib-portable\.sh' "$_f" || grep -qE '_python3\(\) \{ python3 "\$@"; \}' "$_f" || [[ "$_f" == */hooks/checks/* ]]; then
        _ok=yes
    else
        _ok="no source of lib-portable.sh and no fallback"
    fi
    assert_eq "${_f#"$REPO_ROOT/"} reaches _python3" "yes" "$_ok"
done

# === lib-portable.sh standalone ===
echo "=== lib-portable.sh standalone ==="

# Verify hooks version loads independently (clean bash — no inherited readonly)
echo "standalone" > "$TEST_TMPDIR/standalone.txt"
bash -c "source '$REPO_ROOT/global/hooks/lib-portable.sh'; _sed_i 's/standalone/works/' '$TEST_TMPDIR/standalone.txt'"
assert_eq "hooks version works standalone" "works" "$(cat "$TEST_TMPDIR/standalone.txt")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
