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

# === lib-portable.sh standalone ===
echo "=== lib-portable.sh standalone ==="

# Verify hooks version loads independently (clean bash — no inherited readonly)
echo "standalone" > "$TEST_TMPDIR/standalone.txt"
bash -c "source '$REPO_ROOT/global/hooks/lib-portable.sh'; _sed_i 's/standalone/works/' '$TEST_TMPDIR/standalone.txt'"
assert_eq "hooks version works standalone" "works" "$(cat "$TEST_TMPDIR/standalone.txt")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
