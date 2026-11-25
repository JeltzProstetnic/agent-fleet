#!/usr/bin/env bash
# Real checks under Git for Windows bash (MSYS2/Cygwin, "Git Bash") for the native Windows port —
# CFG-1087 slice 1: CFG-335 (link helpers, launcher path) and CFG-336 (native paths, PATH entry).
#
# Runs only where a Git for Windows bash.exe is reachable: WSL on a Windows host (default
# /mnt/c/Program Files/Git/bin/bash.exe, override FLEET_WIN_BASH) or Git Bash itself. Elsewhere
# every case is SKIPPED, never failed. Every Windows-side call runs with HOME, USERPROFILE, TEMP and
# TMP pointed at a throwaway C:\temp\fleet-win-test-<random> directory (FLEET_WIN_TEMP_ROOT
# overrides the C:\temp root) that is deleted at the end — the user's own profile is never touched.
#
# The unit suites (test-symlink-helpers.sh, test-lib-portable.sh, test-install-base.sh,
# test-ensure-local-bin-path.sh) stub the Windows binaries; this suite is the proof on the metal.
source "$(dirname "$0")/test-helpers.sh"

suite_header "Native Windows (Git for Windows bash) — CFG-335 / CFG-336 real checks"

WIN_BASH="${FLEET_WIN_BASH:-/mnt/c/Program Files/Git/bin/bash.exe}"
WIN_TEMP_ROOT="${FLEET_WIN_TEMP_ROOT:-}"
if [[ -z "$WIN_TEMP_ROOT" ]]; then
    for _c in /mnt/c/temp /c/temp; do [[ -d "$_c" ]] && { WIN_TEMP_ROOT="$_c"; break; }; done
fi

WIN_OK=no
WIN_SKIP_REASON=""
if [[ ! -x "$WIN_BASH" ]]; then
    WIN_SKIP_REASON="no Git for Windows bash at $WIN_BASH"
elif [[ -z "$WIN_TEMP_ROOT" || ! -d "$WIN_TEMP_ROOT" || ! -w "$WIN_TEMP_ROOT" ]]; then
    WIN_SKIP_REASON="no writable Windows temp root (C:\\temp) — set FLEET_WIN_TEMP_ROOT"
elif ! command -v wslpath >/dev/null 2>&1 && ! command -v cygpath >/dev/null 2>&1; then
    WIN_SKIP_REASON="neither wslpath nor cygpath available to form a Windows path"
else
    WIN_OK=yes
fi

_winpath() {  # POSIX path → Windows path (C:\...)
    if command -v wslpath >/dev/null 2>&1; then wslpath -w "$1"; else cygpath -w "$1"; fi
}

WT=""      # throwaway HOME, POSIX form (this side)
WT_WIN=""  # the same, Windows form (C:\temp\fleet-win-test-...)
if [[ "$WIN_OK" == yes ]]; then
    WT="$WIN_TEMP_ROOT/fleet-win-test-$RANDOM$RANDOM"
    mkdir -p "$WT/tmp"
    WT_WIN="$(_winpath "$WT")"
    trap 'rm -rf "$WT"' EXIT
fi

# _gb <script-name> [args…] — run $WT/<script-name> inside Git for Windows bash with the throwaway
# HOME/USERPROFILE/TEMP/TMP, from a Windows-drive cwd (a UNC cwd breaks Win32 interop). CRs stripped.
_gb() {
    local script="$1"; shift
    (
        cd "$WIN_TEMP_ROOT" || exit 97
        WSLENV="HOME/w:USERPROFILE/w:TEMP/w:TMP/w:${WSLENV:-}" \
        HOME="$WT_WIN" USERPROFILE="$WT_WIN" TEMP="$WT_WIN\\tmp" TMP="$WT_WIN\\tmp" \
            "$WIN_BASH" "$WT_WIN\\$script" "$@"
    ) 2>&1 | tr -d '\r'
}

# Stage the files under test plus a small global/ fixture into $WT/repo (nothing personal, all deleted).
_stage_repo() {
    local r="$WT/repo"
    mkdir -p "$r/global/hooks" "$r/sync-lib" "$r/setup"
    cp "$REPO_ROOT/global/hooks/lib-portable.sh" "$r/global/hooks/"
    cp "$REPO_ROOT/sync-lib/common.sh" "$REPO_ROOT/sync-lib/setup.sh" "$r/sync-lib/"
    cp "$REPO_ROOT/setup/lib.sh" "$r/setup/"
    echo "# fixture CLAUDE.md" > "$r/global/CLAUDE.md"
    local d
    for d in foundation reference domains knowledge machines; do
        mkdir -p "$r/global/$d"; echo "$d" > "$r/global/$d/a.md"
    done
    printf '#!/usr/bin/env bash\nexit 0\n' > "$r/global/hooks/config-check.sh"
}

_win_case() {  # <name> <fn> — run, or skip with the reason when Windows bash is unavailable
    if [[ "$WIN_OK" == yes ]]; then run_test "$1" "$2"; else skip_test "$1" "$WIN_SKIP_REASON"; fi
}

# ── 1. link helpers on the metal ─────────────────────────────────────────────────────────────
test_link_helpers_real() {
    _stage_repo
    cat > "$WT/t1.sh" <<'EOF'
#!/usr/bin/env bash
source "$HOME/repo/global/hooks/lib-portable.sh"
echo "ostype=$OSTYPE"
echo "native_windows=$(_is_native_windows && echo yes || echo no)"
d="$HOME/t1"; mkdir -p "$d/src d"; echo hello > "$d/src d/f.txt"; echo hello > "$d/src.txt"
_can_symlink || true; echo "mode=$_SYMLINK_MODE"
echo "report=$(_link_mode_report)"
_link_file "$d/src.txt" "$d/dst.txt"
echo "file: exists=$([ -e "$d/dst.txt" ] && echo y || echo n) link=$([ -L "$d/dst.txt" ] && echo y || echo n) content=$(cat "$d/dst.txt") checked=$(_check_linked "$d/dst.txt" && echo y || echo n) valid=$(_check_linked_valid "$d/dst.txt" && echo y || echo n)"
_link_dir "$d/src d" "$d/dst d"
echo "dir: isdir=$([ -d "$d/dst d" ] && echo y || echo n) link=$([ -L "$d/dst d" ] && echo y || echo n) content=$(cat "$d/dst d/f.txt") checked=$(_check_linked "$d/dst d" && echo y || echo n) valid=$(_check_linked_valid "$d/dst d" && echo y || echo n)"
echo hello2 > "$d/src d/f.txt"
_link_dir "$d/src d" "$d/dst d"; echo "relink: rc=$? content=$(cat "$d/dst d/f.txt")"
rm -rf "$d/dst d"; echo "after rm: src_intact=$([ -f "$d/src d/f.txt" ] && echo y || echo n)"
ln -s "$d/src.txt" "$d/raw" 2>/dev/null; echo "raw_ln_s_symlink=$([ -L "$d/raw" ] && echo y || echo n)"
EOF
    local out mode
    out=$(_gb t1.sh)
    echo "$out" | sed 's/^/    | /'
    assert_contains "$out" "native_windows=yes" "_is_native_windows under Git Bash" || return 1
    mode=$(echo "$out" | sed -n 's/^mode=//p')
    case "$mode" in symlink|junction|copy) ;; *) echo "    unknown mode '$mode'"; return 1 ;; esac
    assert_contains "$out" "report=$mode" "the report names the chosen mode" || return 1
    assert_contains "$out" "content=hello checked=y valid=y" "file linked/copied, readable, accepted by the checks" || return 1
    assert_contains "$out" "dir: isdir=y" "directory present" || return 1
    local dir_line; dir_line=$(echo "$out" | grep '^dir: ')
    assert_contains "$dir_line" "content=hello checked=y valid=y" "directory readable and accepted by the checks" || return 1
    # consistency: the mode claimed matches what was created
    case "$mode" in
        symlink)  assert_contains "$out" "file: exists=y link=y" "symlink mode: file is a real link" || return 1
                  assert_contains "$dir_line" "link=y" "symlink mode: dir is a real link" || return 1 ;;
        junction) assert_contains "$out" "file: exists=y link=n" "junction mode: file is a copy" || return 1
                  assert_contains "$dir_line" "link=y" "junction mode: dir is a junction (bash sees a symlink)" || return 1 ;;
        copy)     assert_contains "$out" "file: exists=y link=n" "copy mode: file is a copy" || return 1
                  assert_contains "$dir_line" "link=n" "copy mode: dir is a copy" || return 1 ;;
    esac
    assert_contains "$out" "relink: rc=0 content=hello2" "second run over the existing target succeeds and is current" || return 1
    assert_contains "$out" "after rm: src_intact=y" "removing the deployed dir never touches the source"
}
_win_case "link helpers: mode detected, stated, and consistent with what was created" test_link_helpers_real

# ── 2. sync.sh setup → verify_setup end to end (GH#2: V1–V7 all failed) ─────────────────────
test_cmd_setup_verifies_real() {
    _stage_repo
    cat > "$WT/t2.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$HOME/repo"; GLOBAL_DIR="$SCRIPT_DIR/global"; PROJECTS_DIR="$SCRIPT_DIR/setup/projects"
CLAUDE_HOME="$HOME/.claude"
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then PLATFORM="windows"; else PLATFORM="other:$OSTYPE"; fi
SETUP_VERIFIED_MARKER="$CLAUDE_HOME/.setup-verified"; SETUP_FAILED_MARKER="$CLAUDE_HOME/.setup-failed"
RED=''; GREEN=''; YELLOW=''; NC=''
log_info() { echo "[INFO] $*"; }; log_warn() { echo "[WARN] $*"; }; log_error() { echo "[ERROR] $*"; }
_readlink_f() { readlink -f "$1"; }
source "$SCRIPT_DIR/sync-lib/common.sh"
source "$SCRIPT_DIR/sync-lib/setup.sh"
deploy_hooks() { mkdir -p "$CLAUDE_HOME/hooks"; cp "$GLOBAL_DIR/hooks/config-check.sh" "$CLAUDE_HOME/hooks/"; chmod +x "$CLAUDE_HOME/hooks/config-check.sh"; }
deploy_project_rules() { :; }; deploy_aliases() { :; }; deploy_afleet() { :; }; deploy_repro() { :; }
setup_arm_githooks() { :; }; clean_marketplace_plugins() { :; }; run_provisioning_checks() { :; }
echo "platform=$PLATFORM"
echo "--- run 1"; cmd_setup
echo "--- run 2 (idempotent)"; cmd_setup
echo "claude_md=$(cat "$CLAUDE_HOME/CLAUDE.md")"
echo "foundation=$(cat "$CLAUDE_HOME/foundation/a.md")"
echo "markers: verified=$([ -f "$SETUP_VERIFIED_MARKER" ] && echo y || echo n) failed=$([ -f "$SETUP_FAILED_MARKER" ] && echo y || echo n)"
EOF
    local out
    out=$(_gb t2.sh)
    echo "$out" | sed 's/^/    | /'
    assert_contains "$out" "platform=windows" "sync.sh's platform detection says windows under Git Bash" || return 1
    assert_contains "$out" "Link mode:" "setup states the link mode" || return 1
    assert_eq "2" "$(echo "$out" | grep -c 'Setup verification PASSED')" "verify_setup passes on both runs (V1–V7 were the GH#2 failures)" || return 1
    assert_not_contains "$out" "verification FAILED" "" || return 1
    assert_contains "$out" "claude_md=# fixture CLAUDE.md" "CLAUDE.md deployed and readable" || return 1
    assert_contains "$out" "foundation=foundation" "a knowledge dir deployed and readable" || return 1
    assert_contains "$out" "markers: verified=y failed=n" "verified marker written, failed marker absent"
}
_win_case "sync.sh setup → verify_setup passes twice under Git Bash (GH#2 repro)" test_cmd_setup_verifies_real

# ── 3. native paths for Windows Python (GH#3 issues 1+2) ───────────────────────────────────
test_native_path_real() {
    _stage_repo
    cat > "$WT/t3.sh" <<'EOF'
#!/usr/bin/env bash
source "$HOME/repo/global/hooks/lib-portable.sh"
PY=""
for c in python3 python; do
    v=$("$c" --version 2>&1 </dev/null | head -1)
    case "$v" in Python\ [0-9]*) PY="$c"; break ;; esac
done
echo "py=$PY"
f="$HOME/t3/a b.json"; mkdir -p "$HOME/t3"; echo '{"v": 7}' > "$f"
echo "native=$(_to_native_path "$f")"
[ -n "$PY" ] || exit 0
echo "msys_path=$("$PY" -c "import json; print(json.load(open('$f'))['v'])" 2>&1 </dev/null | tail -1)"
echo "converted=$("$PY" -c "import json; print(json.load(open('$(_to_native_path "$f")'))['v'])" 2>&1 </dev/null | tail -1)"
EOF
    local out py
    out=$(_gb t3.sh)
    echo "$out" | sed 's/^/    | /'
    local native; native=$(echo "$out" | sed -n 's/^native=//p')
    [[ "$native" =~ ^[A-Za-z]:/ ]] || { echo "    _to_native_path did not return a C:/… path (got '$native')"; return 1; }
    py=$(echo "$out" | sed -n 's/^py=//p')
    if [[ -z "$py" ]]; then
        echo "    (no native Windows Python on this host — conversion verified, Python open() not exercised)"
        return 0
    fi
    assert_contains "$out" "converted=7" "native Windows Python opens the converted path"
}
_win_case "_to_native_path yields a path native Windows Python can open (GH#3)" test_native_path_real

# ── 4. ~/.local/bin on PATH for new shells (GH#3 issue 3) ───────────────────────────────────
test_local_bin_path_real() {
    _stage_repo
    cat > "$WT/t4.sh" <<'EOF'
#!/usr/bin/env bash
export NO_COLOR=true
source "$HOME/repo/setup/lib.sh"
rc="$HOME/.bashrc"; : > "$rc"
echo "before_in_path=$(case ":$PATH:" in *":$HOME/.local/bin:"*) echo y ;; *) echo n ;; esac)"
ensure_local_bin_path "$rc"
echo "rc_marker_lines=$(grep -c 'local bin path' "$rc")"
ensure_local_bin_path "$rc"
echo "rc_marker_lines_after_2nd=$(grep -c 'local bin path' "$rc")"
mkdir -p "$HOME/.local/bin"; printf '#!/bin/sh\necho afleet-stub\n' > "$HOME/.local/bin/afleet"; chmod +x "$HOME/.local/bin/afleet"
echo "this_shell_finds=$(command -v afleet 2>/dev/null || echo none)"
echo "login_shell_finds=$(bash -l -c 'command -v afleet' 2>/dev/null | tail -1)"
echo "login_shell_runs=$(bash -l -c 'afleet' 2>/dev/null | tail -1)"
EOF
    local out
    out=$(_gb t4.sh)
    echo "$out" | sed 's/^/    | /'
    assert_contains "$out" "before_in_path=n" "Git Bash does not have ~/.local/bin on PATH by itself (the GH#3 condition)" || return 1
    assert_contains "$out" "rc_marker_lines=1" "block written once" || return 1
    assert_contains "$out" "rc_marker_lines_after_2nd=1" "idempotent" || return 1
    assert_contains "$out" "this_shell_finds=none" "" || return 1
    local found; found=$(echo "$out" | sed -n 's/^login_shell_finds=//p')
    [[ "$found" == */.local/bin/afleet ]] || { echo "    a new login shell does not find afleet (got '$found')"; return 1; }
    assert_contains "$out" "login_shell_runs=afleet-stub" "a new login shell runs afleet"
}
_win_case "ensure_local_bin_path: a new Git Bash login shell finds afleet (GH#3)" test_local_bin_path_real

# ── 5. launcher path + install-base post-creation check (GH#2 step 6) ──────────────────────
test_launcher_and_install_base_real() {
    _stage_repo
    {
        cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$HOME/repo/global/hooks/lib-portable.sh"
echo "launcher=$(_cc_launcher_path)"
TOTAL_STEPS=6; CC_MIRROR_VARIANT=mclaude; CLAUDE_CODE_VERSION=latest; DRY_RUN=false
INSTALLED_STEPS=(); SKIPPED_STEPS=()
log_step() { shift 2; echo "[STEP] $*"; }; log_info() { echo "[INFO] $*"; }; log_warn() { echo "[WARN] $*"; }
log_success() { echo "[OK] $*"; }; log_error() { echo "[ERROR] $*"; }
mkdir -p "$HOME/fakebin"
printf '#!/usr/bin/env bash\nmkdir -p "$HOME/.cc-mirror/bin"\necho stub > "$HOME/.cc-mirror/bin/mclaude.cmd"\n' > "$HOME/fakebin/cc-mirror"
chmod +x "$HOME/fakebin/cc-mirror"
PATH="$HOME/fakebin:$PATH"
EOF
        sed -n '/^create_mclaude_variant()/,/^}/p' "$REPO_ROOT/setup/install-base.sh"
        echo 'create_mclaude_variant; echo "variant_rc=$?"'
    } > "$WT/t5.sh"
    local out
    out=$(_gb t5.sh)
    echo "$out" | sed 's/^/    | /'
    local launcher; launcher=$(echo "$out" | sed -n 's/^launcher=//p')
    [[ "$launcher" == */.cc-mirror/bin/mclaude.cmd ]] || { echo "    launcher path under Git Bash is '$launcher'"; return 1; }
    assert_contains "$out" "variant_rc=0" "create_mclaude_variant accepts the .cmd launcher (GH#2 step 6)" || return 1
    assert_contains "$out" "mclaude launcher created at" "" || return 1
    assert_contains "$out" ".cc-mirror/bin/mclaude.cmd" "the message names the .cmd launcher"
}
_win_case "launcher path is ~/.cc-mirror/bin/mclaude.cmd and install-base accepts it (GH#2)" test_launcher_and_install_base_real

# ── 6. nothing left behind outside the throwaway dir ────────────────────────────────────────
test_throwaway_only() {
    [[ -d "$WT" ]] || { echo "    throwaway dir missing"; return 1; }
    local n
    n=$(ls -d "$WIN_TEMP_ROOT"/fleet-win-test-* 2>/dev/null | grep -v -x "$WT" | wc -l)
    assert_eq "0" "$n" "no other fleet-win-test-* dirs left behind (found $n)"
}
_win_case "every Windows-side write stayed inside the throwaway HOME" test_throwaway_only

suite_summary
