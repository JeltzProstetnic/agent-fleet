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

# === lib-portable.sh standalone ===
echo "=== lib-portable.sh standalone ==="

# Verify hooks version loads independently (clean bash — no inherited readonly)
echo "standalone" > "$TEST_TMPDIR/standalone.txt"
bash -c "source '$REPO_ROOT/global/hooks/lib-portable.sh'; _sed_i 's/standalone/works/' '$TEST_TMPDIR/standalone.txt'"
assert_eq "hooks version works standalone" "works" "$(cat "$TEST_TMPDIR/standalone.txt")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
