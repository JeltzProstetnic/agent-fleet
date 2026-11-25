#!/usr/bin/env bash
# Tests for portable symlink helpers (CFG-335)
# Tests both symlink mode (default on Linux) and copy-fallback mode (MINGW64)
source "$(dirname "$0")/test-helpers.sh"

SYNC_LIB_DIR="$REPO_ROOT/sync-lib"

suite_header "Portable Symlink Helpers (CFG-335)"

# Helper to source common.sh with required variables in current shell
_init_common() {
    SCRIPT_DIR="$REPO_ROOT"
    GLOBAL_DIR="$REPO_ROOT/global"
    PROJECTS_DIR="$REPO_ROOT/setup/projects"
    CLAUDE_HOME="$TEST_TMPDIR/.claude"
    PLATFORM="${1:-linux}"
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
    log_info() { :; }
    log_warn() { :; }
    log_error() { :; }
    _SYMLINK_MODE=""  # reset cache
    source "$SYNC_LIB_DIR/common.sh"
}

# ── _can_symlink ─────────────────────────────────────────────────────────────

test_can_symlink_on_linux() {
    _init_common "linux"
    _can_symlink
    assert_eq "symlink" "$_SYMLINK_MODE"
}
run_test "_can_symlink returns true on Linux" test_can_symlink_on_linux

test_can_symlink_caches_result() {
    _init_common "linux"
    _can_symlink
    local first="$_SYMLINK_MODE"
    _can_symlink
    assert_eq "$first" "$_SYMLINK_MODE"
}
run_test "_can_symlink caches result across calls" test_can_symlink_caches_result

test_can_symlink_copy_mode_forced() {
    _init_common "windows"
    _SYMLINK_MODE="copy"  # force copy mode (as MINGW64 would)
    local rc=0
    _can_symlink || rc=$?
    assert_eq "copy" "$_SYMLINK_MODE"
    assert_neq "0" "0$rc" "should return non-zero in copy mode"
}
run_test "_can_symlink returns false in forced copy mode" test_can_symlink_copy_mode_forced

# ── _link_file ───────────────────────────────────────────────────────────────

test_link_file_creates_symlink() {
    _init_common "linux"
    echo "hello" > "$TEST_TMPDIR/source.txt"
    _link_file "$TEST_TMPDIR/source.txt" "$TEST_TMPDIR/target.txt"
    assert_file_exists "$TEST_TMPDIR/target.txt"
    # On Linux, should be a real symlink
    local is_link="no"
    [ -L "$TEST_TMPDIR/target.txt" ] && is_link="yes"
    assert_eq "yes" "$is_link" "target should be a symlink"
    assert_eq "hello" "$(cat "$TEST_TMPDIR/target.txt")"
}
run_test "_link_file creates symlink on Linux" test_link_file_creates_symlink

test_link_file_creates_copy_in_copy_mode() {
    _init_common "windows"
    _SYMLINK_MODE="copy"
    echo "hello" > "$TEST_TMPDIR/source.txt"
    _link_file "$TEST_TMPDIR/source.txt" "$TEST_TMPDIR/target.txt"
    assert_file_exists "$TEST_TMPDIR/target.txt"
    # Should NOT be a symlink
    local is_link="no"
    [ -L "$TEST_TMPDIR/target.txt" ] && is_link="yes"
    assert_eq "no" "$is_link" "target should NOT be a symlink in copy mode"
    assert_eq "hello" "$(cat "$TEST_TMPDIR/target.txt")"
}
run_test "_link_file creates copy in copy mode" test_link_file_creates_copy_in_copy_mode

test_link_file_overwrites_existing() {
    _init_common "linux"
    echo "old" > "$TEST_TMPDIR/target.txt"
    echo "new" > "$TEST_TMPDIR/source.txt"
    _link_file "$TEST_TMPDIR/source.txt" "$TEST_TMPDIR/target.txt"
    assert_eq "new" "$(cat "$TEST_TMPDIR/target.txt")"
}
run_test "_link_file overwrites existing file" test_link_file_overwrites_existing

# ── _link_dir ────────────────────────────────────────────────────────────────

test_link_dir_creates_symlink() {
    _init_common "linux"
    mkdir -p "$TEST_TMPDIR/srcdir"
    echo "content" > "$TEST_TMPDIR/srcdir/file.txt"
    _link_dir "$TEST_TMPDIR/srcdir" "$TEST_TMPDIR/dstdir"
    local is_link="no"
    [ -L "$TEST_TMPDIR/dstdir" ] && is_link="yes"
    assert_eq "yes" "$is_link" "target should be a symlink"
    assert_eq "content" "$(cat "$TEST_TMPDIR/dstdir/file.txt")"
}
run_test "_link_dir creates dir symlink on Linux" test_link_dir_creates_symlink

test_link_dir_creates_copy_in_copy_mode() {
    _init_common "windows"
    _SYMLINK_MODE="copy"
    mkdir -p "$TEST_TMPDIR/srcdir"
    echo "content" > "$TEST_TMPDIR/srcdir/file.txt"
    _link_dir "$TEST_TMPDIR/srcdir" "$TEST_TMPDIR/dstdir"
    assert_dir_exists "$TEST_TMPDIR/dstdir"
    local is_link="no"
    [ -L "$TEST_TMPDIR/dstdir" ] && is_link="yes"
    assert_eq "no" "$is_link" "target should NOT be a symlink in copy mode"
    assert_eq "content" "$(cat "$TEST_TMPDIR/dstdir/file.txt")"
}
run_test "_link_dir creates copy in copy mode" test_link_dir_creates_copy_in_copy_mode

test_link_dir_replaces_existing_symlink() {
    _init_common "linux"
    mkdir -p "$TEST_TMPDIR/old" "$TEST_TMPDIR/new"
    echo "new" > "$TEST_TMPDIR/new/file.txt"
    ln -sfn "$TEST_TMPDIR/old" "$TEST_TMPDIR/target"
    _link_dir "$TEST_TMPDIR/new" "$TEST_TMPDIR/target"
    assert_eq "new" "$(cat "$TEST_TMPDIR/target/file.txt")"
}
run_test "_link_dir replaces existing symlink" test_link_dir_replaces_existing_symlink

# ── _check_linked ────────────────────────────────────────────────────────────

test_check_linked_symlink_mode() {
    _init_common "linux"
    echo "x" > "$TEST_TMPDIR/source"
    ln -sf "$TEST_TMPDIR/source" "$TEST_TMPDIR/link"
    # Symlink should pass
    local rc=0
    _check_linked "$TEST_TMPDIR/link" || rc=$?
    assert_eq "0" "$rc" "symlink should pass"
    # Missing should fail
    rc=0
    _check_linked "$TEST_TMPDIR/nonexistent" || rc=$?
    assert_neq "0" "0$rc" "missing should fail"
    # Regular file is NOT a link in symlink mode
    rc=0
    _check_linked "$TEST_TMPDIR/source" || rc=$?
    assert_neq "0" "0$rc" "regular file should fail in symlink mode"
}
run_test "_check_linked detects symlinks in symlink mode" test_check_linked_symlink_mode

test_check_linked_copy_mode() {
    _init_common "windows"
    _SYMLINK_MODE="copy"
    echo "x" > "$TEST_TMPDIR/file"
    # Regular file should pass in copy mode
    local rc=0
    _check_linked "$TEST_TMPDIR/file" || rc=$?
    assert_eq "0" "$rc" "regular file should pass in copy mode"
    # Missing should fail
    rc=0
    _check_linked "$TEST_TMPDIR/nonexistent" || rc=$?
    assert_neq "0" "0$rc" "missing should fail"
}
run_test "_check_linked accepts regular files in copy mode" test_check_linked_copy_mode

# ── _check_linked_valid ──────────────────────────────────────────────────────

test_check_linked_valid_good_symlink() {
    _init_common "linux"
    echo "x" > "$TEST_TMPDIR/source"
    ln -sf "$TEST_TMPDIR/source" "$TEST_TMPDIR/link"
    local rc=0
    _check_linked_valid "$TEST_TMPDIR/link" || rc=$?
    assert_eq "0" "$rc" "valid symlink should pass"
}
run_test "_check_linked_valid passes for valid symlink" test_check_linked_valid_good_symlink

test_check_linked_valid_broken_symlink() {
    _init_common "linux"
    ln -sf "$TEST_TMPDIR/nonexistent" "$TEST_TMPDIR/broken"
    local rc=0
    _check_linked_valid "$TEST_TMPDIR/broken" || rc=$?
    assert_neq "0" "0$rc" "broken symlink should fail"
}
run_test "_check_linked_valid fails for broken symlink" test_check_linked_valid_broken_symlink

test_check_linked_valid_copy_mode() {
    _init_common "windows"
    _SYMLINK_MODE="copy"
    echo "x" > "$TEST_TMPDIR/file"
    local rc=0
    _check_linked_valid "$TEST_TMPDIR/file" || rc=$?
    assert_eq "0" "$rc" "existing file passes in copy mode"
    rc=0
    _check_linked_valid "$TEST_TMPDIR/missing" || rc=$?
    assert_neq "0" "0$rc" "missing file fails"
}
run_test "_check_linked_valid works in copy mode" test_check_linked_valid_copy_mode

# ── Integration: source files use helpers (regression guards) ────────────────

test_setup_uses_link_helpers() {
    assert_file_contains "$SYNC_LIB_DIR/setup.sh" "_link_file"
    assert_file_contains "$SYNC_LIB_DIR/setup.sh" "_link_dir"
}
run_test "sync-lib/setup.sh uses portable link helpers" test_setup_uses_link_helpers

test_verify_uses_check_helpers() {
    assert_file_contains "$SYNC_LIB_DIR/setup.sh" "_check_linked"
}
run_test "verify_setup uses _check_linked" test_verify_uses_check_helpers

test_deploy_afleet_uses_helpers() {
    local has_helper="no"
    grep -q '_link_file\|_check_linked' "$SYNC_LIB_DIR/deploy.sh" && has_helper="yes"
    assert_eq "yes" "$has_helper" "deploy.sh should use link helpers"
}
run_test "deploy_afleet uses portable helpers" test_deploy_afleet_uses_helpers

test_no_bare_ln_in_sync_lib() {
    # No bare 'ln -s' should remain in setup.sh or deploy.sh (except comments)
    local bare_ln
    bare_ln=$(grep -n 'ln -s' "$SYNC_LIB_DIR/setup.sh" "$SYNC_LIB_DIR/deploy.sh" 2>/dev/null \
        | grep -v '^\s*#' | grep -v ':#' || true)
    assert_eq "" "$bare_ln" "no bare ln -s should remain in sync-lib"
}
run_test "no bare ln -s in sync-lib setup/deploy" test_no_bare_ln_in_sync_lib

# ── CFG-1087 slice 1 (CFG-335): one definition, three modes, a stated choice ─────────────
# The helpers live in global/hooks/lib-portable.sh (the portability library every hook, setup/lib.sh
# and sync-lib source — one definition) and pick, on native Windows bash (MSYS2/Cygwin/Git Bash),
# the best mode the host actually allows: native symlinks (MSYS=winsymlinks:nativestrict, needs
# Developer Mode or elevation) → NTFS junctions for directories + copies for files (no rights
# needed) → plain copies. Measured 2026-11-25 on Git for Windows 2.55: `ln -s` silently copies,
# nativestrict is refused without rights, `mklink /J` works and bash reports the junction as a symlink.

LIB_PORTABLE="$REPO_ROOT/global/hooks/lib-portable.sh"

# PATH stubs standing in for the Git for Windows binaries `ln`, `cmd` (mklink) and `cygpath`.
#   ln_mode:  native  — `ln -s` makes a real link only under MSYS=winsymlinks:nativestrict, else a COPY
#             refused — `ln -s` fails ("Operation not permitted"), as without Developer Mode/elevation
#             copy    — `ln -s` silently copies whatever MSYS says (the GH#2 host)
#   cmd_mode: junction — `cmd //c mklink //J DST SRC` links DST → SRC (stands in for an NTFS junction)
#             refused  — mklink fails
_make_win_stubs() {
    local ln_mode="$1" cmd_mode="$2" bin="$TEST_TMPDIR/winstub"
    mkdir -p "$bin"
    cat > "$bin/ln" <<'STUB'
#!/usr/bin/env bash
mode="$(cat "$(dirname "$0")/.ln_mode")"
if [[ "$1" == -s* ]]; then
    case "$mode" in
        native)  [[ "${MSYS:-}" == winsymlinks:nativestrict ]] && exec /bin/ln "$@"
                 cp -r "${@: -2:1}" "${@: -1}"; exit 0 ;;
        refused) echo "ln: failed to create symbolic link: Operation not permitted" >&2; exit 1 ;;
        copy)    cp -r "${@: -2:1}" "${@: -1}"; exit 0 ;;
    esac
fi
exec /bin/ln "$@"
STUB
    cat > "$bin/cmd" <<'STUB'
#!/usr/bin/env bash
mode="$(cat "$(dirname "$0")/.cmd_mode")"
# expected call: //c mklink //J <dst> <src>
[[ "$mode" == junction && "$2" == mklink && "$3" == *J ]] || exit 1
/bin/ln -s "$5" "$4"
STUB
    printf '#!/usr/bin/env bash\n[[ "$1" == -w || "$1" == -m ]] && { echo "$2"; exit 0; }\necho "$1"\n' > "$bin/cygpath"
    chmod +x "$bin/ln" "$bin/cmd" "$bin/cygpath"
    echo "$ln_mode" > "$bin/.ln_mode"
    echo "$cmd_mode" > "$bin/.cmd_mode"
    echo "$bin"
}

# _win_probe <ln_mode> <cmd_mode> <body> — run <body> with the stubs first on PATH, PLATFORM=windows
# and a fresh (uncached) probe, in a subshell; prints the body's output.
_win_probe() {
    local bin
    bin=$(_make_win_stubs "$1" "$2")
    shift 2
    ( PATH="$bin:/usr/bin:/bin"; _init_common "windows"; eval "$*" )
}

test_helpers_defined_by_lib_portable_alone() {
    local n
    n=$(bash -c "source '$LIB_PORTABLE'; declare -F _can_symlink _link_file _link_dir _check_linked _check_linked_valid _link_mode _link_mode_report _is_native_windows 2>/dev/null | wc -l")
    assert_eq "8" "$n" "lib-portable.sh alone defines all 8 link helpers (defined: $n)"
}
run_test "lib-portable.sh (propagating file) defines the link helpers by itself" test_helpers_defined_by_lib_portable_alone

test_common_sh_has_no_second_definition() {
    local n
    n=$(grep -c -E '^_(can_symlink|link_file|link_dir|check_linked|check_linked_valid)\(\)' "$SYNC_LIB_DIR/common.sh" || true)
    assert_eq "0" "$n" "common.sh carries no second copy of the helpers (found $n definitions)"
}
run_test "common.sh carries no second copy of the helpers" test_common_sh_has_no_second_definition

test_native_symlinks_under_nativestrict() {
    local out
    out=$(_win_probe native refused '
        echo hi > "$TEST_TMPDIR/s.txt"; mkdir -p "$TEST_TMPDIR/sd"
        _can_symlink || true; echo "mode=$_SYMLINK_MODE"
        _link_file "$TEST_TMPDIR/s.txt" "$TEST_TMPDIR/d.txt"; [ -L "$TEST_TMPDIR/d.txt" ] && echo file-link || echo file-copy
        _link_dir "$TEST_TMPDIR/sd" "$TEST_TMPDIR/dd"; [ -L "$TEST_TMPDIR/dd" ] && echo dir-link || echo dir-copy
        echo "report=$(_link_mode_report)"')
    assert_contains "$out" "mode=symlink" "nativestrict ln succeeds → symlink mode (got: $out)" || return 1
    assert_contains "$out" "file-link" "_link_file made a real link" || return 1
    assert_contains "$out" "dir-link" "_link_dir made a real link" || return 1
    assert_contains "$out" "report=symlink" "the report names the mode"
}
run_test "windows: native symlinks when MSYS=winsymlinks:nativestrict ln works (Developer Mode / elevated)" test_native_symlinks_under_nativestrict

test_junction_mode_when_symlinks_refused() {
    local out
    out=$(_win_probe refused junction '
        echo hi > "$TEST_TMPDIR/s.txt"; mkdir -p "$TEST_TMPDIR/sd"; echo c > "$TEST_TMPDIR/sd/f"
        _can_symlink || true; echo "mode=$_SYMLINK_MODE"
        _link_file "$TEST_TMPDIR/s.txt" "$TEST_TMPDIR/d.txt"; [ -L "$TEST_TMPDIR/d.txt" ] && echo file-link || echo file-copy
        _link_dir "$TEST_TMPDIR/sd" "$TEST_TMPDIR/dd"; [ -L "$TEST_TMPDIR/dd" ] && echo dir-junction || echo dir-copy
        echo "content=$(cat "$TEST_TMPDIR/dd/f")"
        _check_linked "$TEST_TMPDIR/d.txt" && echo file-checked
        _check_linked "$TEST_TMPDIR/dd" && echo dir-checked
        _check_linked_valid "$TEST_TMPDIR/dd" && echo dir-valid
        mkdir -p "$TEST_TMPDIR/plain"; _check_linked "$TEST_TMPDIR/plain" || echo plain-dir-not-linked
        _link_dir "$TEST_TMPDIR/sd" "$TEST_TMPDIR/dd" && echo relink-ok
        echo "report=$(_link_mode_report)"')
    assert_contains "$out" "mode=junction" "symlinks refused + mklink /J works → junction mode (got: $out)" || return 1
    assert_contains "$out" "file-copy" "files are copied in junction mode" || return 1
    assert_contains "$out" "dir-junction" "directories become junctions" || return 1
    assert_contains "$out" "content=c" "the junction reads the source content" || return 1
    assert_contains "$out" "file-checked" "_check_linked accepts the copied file" || return 1
    assert_contains "$out" "dir-checked" "_check_linked accepts the junction" || return 1
    assert_contains "$out" "dir-valid" "_check_linked_valid accepts the junction" || return 1
    assert_contains "$out" "plain-dir-not-linked" "a real directory does not pass as linked" || return 1
    assert_contains "$out" "relink-ok" "re-linking over an existing junction succeeds (second setup run)" || return 1
    assert_contains "$out" "report=junction" "the report names the mode"
}
run_test "windows: junction mode when symlinks are refused but mklink /J works (no rights needed)" test_junction_mode_when_symlinks_refused

test_copy_mode_when_nothing_works() {
    local out
    out=$(_win_probe copy refused '
        echo hi > "$TEST_TMPDIR/s.txt"
        _can_symlink || true; echo "mode=$_SYMLINK_MODE"
        _link_file "$TEST_TMPDIR/s.txt" "$TEST_TMPDIR/d.txt"; [ -L "$TEST_TMPDIR/d.txt" ] && echo file-link || echo "file-copy=$(cat "$TEST_TMPDIR/d.txt")"
        r=$(_link_mode_report); echo "report=$r"; echo "reportlen=${#r}"')
    assert_contains "$out" "mode=copy" "a silently copying ln and no mklink → copy mode (got: $out)" || return 1
    assert_contains "$out" "file-copy=hi" "_link_file copied the content" || return 1
    assert_contains "$out" "report=copy" "the report names the mode" || return 1
    local len
    len=$(echo "$out" | sed -n 's/^reportlen=//p')
    [[ "${len:-0}" -gt 20 ]] || { echo "    report carries no reason (length ${len:-0})"; return 1; }
}
run_test "windows: copy mode when ln copies silently and mklink is unavailable — and the report says why" test_copy_mode_when_nothing_works

test_linux_mode_and_report_unchanged() {
    _init_common "linux"
    assert_eq "symlink" "$(_link_mode)" "_link_mode on Linux" || return 1
    assert_contains "$(_link_mode_report)" "symlink" "report on Linux names symlink mode"
}
run_test "linux: _link_mode is symlink and the report says so (no probe, behaviour unchanged)" test_linux_mode_and_report_unchanged

# ── common.sh without lib-portable.sh (a stripped sync.sh copy) ──────────────
# Loading must still succeed, so commands that never link (template-push, status) keep working;
# the loud error belongs to the first link call, which must fail with a non-zero status.
test_missing_lib_portable_fails_at_link_not_at_load() {
    local stripped="$TEST_TMPDIR/stripped"
    mkdir -p "$stripped/sync-lib"
    cp "$SYNC_LIB_DIR/common.sh" "$stripped/sync-lib/common.sh"
    local out rc
    out=$(SCRIPT_DIR="$stripped" GLOBAL_DIR="$stripped/global" bash -c '
        source "$1/sync-lib/common.sh" || { echo "LOAD_FAILED"; exit 7; }
        echo "LOADED"
        _link_file /etc/hostname "$2/x" 2>&1; echo "link_rc=$?"
    ' _ "$stripped" "$TEST_TMPDIR" 2>&1); rc=$?
    assert_eq "0" "$rc" "sourcing common.sh succeeds without lib-portable.sh"
    assert_contains "$out" "LOADED" "commands that do not link keep working"
    assert_contains "$out" "lib-portable.sh" "the link call names the missing library"
    assert_contains "$out" "link_rc=1" "the link call fails with status 1"
    assert_file_not_exists "$TEST_TMPDIR/x" "nothing is linked or copied"
}
run_test "common.sh without lib-portable.sh: loads, and the first link call fails loudly" test_missing_lib_portable_fails_at_link_not_at_load

suite_summary
