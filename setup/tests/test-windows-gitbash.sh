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
    mkdir -p "$r/global/hooks/checks" "$r/sync-lib" "$r/setup/scripts" "$r/setup/tests"
    cp "$REPO_ROOT/global/hooks/lib-portable.sh" "$r/global/hooks/"
    cp "$REPO_ROOT/global/hooks/checks/04-auto-fix.sh" "$r/global/hooks/checks/"
    cp "$REPO_ROOT/sync-lib/common.sh" "$REPO_ROOT/sync-lib/setup.sh" "$r/sync-lib/"
    cp "$REPO_ROOT/setup/lib.sh" "$r/setup/"
    cp "$REPO_ROOT/setup/scripts/cc-install-invariants.sh" "$r/setup/scripts/"
    cp "$REPO_ROOT/setup/tests/lib-cc-install-fixture.sh" "$r/setup/tests/"
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
deploy_project_rules() { :; }; deploy_aliases() { :; }; deploy_afleet() { :; }; deploy_repro() { :; }; deploy_afx() { :; }
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
    assert_contains "$out" "Python:" "setup states which Python it found (CFG-1087 slice 2: python3 may be the Store stub)" || return 1
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

# ── 7. Python resolution on the metal (slice 2) ─────────────────────────────────────────────
# `python3` on Git Bash may be the Microsoft Store redirector, which EXITS 0 with "Python was not
# found…" (measured 2026-11-25). The helper must judge by the banner and state what it found.
test_python_resolution_real() {
    _stage_repo
    cat > "$WT/t7.sh" <<'EOF'
#!/usr/bin/env bash
source "$HOME/repo/global/hooks/lib-portable.sh"
raw=$(python3 --version 2>&1 </dev/null | head -1); echo "raw_python3=[$raw]"
py=$(_fleet_python); echo "fleet_python=[$py] rc=$?"
echo "report=$(_python_report)"
echo "run=$(_python3 -c 'print(6*7)' 2>&1 </dev/null | tail -1)"
_python3 -c 'import sys; sys.exit(0)' </dev/null >/dev/null 2>&1; echo "run_rc=$?"
EOF
    local out py report
    out=$(_gb t7.sh)
    echo "$out" | sed 's/^/    | /'
    py=$(echo "$out" | sed -n 's/^fleet_python=\[\(.*\)\] rc=.*/\1/p')
    report=$(echo "$out" | sed -n 's/^report=//p')
    assert_contains "$report" "python3" "the report says what python3 itself turned out to be" || return 1
    if [[ -z "$py" ]]; then
        assert_contains "$out" "fleet_python=[] rc=1" "no usable Python → rc 1" || return 1
        [[ "$report" == none* ]] || { echo "    report should start with 'none' (got '$report')"; return 1; }
        assert_contains "$out" "run_rc=127" "_python3 fails like a missing python3"
        echo "    (no usable Python on this host — resolution stated it)"; return 0
    fi
    [[ "$report" == "$py — "* ]] || { echo "    report must name the chosen command first (got '$report')"; return 1; }
    assert_contains "$out" "run=42" "the resolved interpreter runs code" || return 1
    assert_contains "$out" "run_rc=0" "_python3 passes the exit status through"
}
_win_case "Python resolution: the Store stub is seen through, a real interpreter runs, the report says which" test_python_resolution_real

# ── 8. check 4.8b (~/.mcp.json) through the link helpers on the metal (slice 2) ─────────────
test_mcp_link_autofix_real() {
    _stage_repo
    {
        cat <<'EOF'
#!/usr/bin/env bash
source "$HOME/repo/global/hooks/lib-portable.sh"
CC_MIRROR_DIR="$HOME/.cc-mirror/mclaude"; mkdir -p "$CC_MIRROR_DIR/config"
printf '{"mcpServers": {"fixture-server": {"command": "true"}}}\n' > "$CC_MIRROR_DIR/config/.mcp.json"
WARNINGS=""
_can_symlink || true; echo "mode=$_SYMLINK_MODE"
EOF
        echo 'run_48b() {'
        sed -n '/^# Check 4.8b/,/^# Check 4.8:/p' "$REPO_ROOT/global/hooks/checks/04-auto-fix.sh" | sed '$d'
        echo '}'
        cat <<'EOF'
run_48b
echo "pass1: exists=$([ -e "$HOME/.mcp.json" ] && echo y || echo n) link=$([ -L "$HOME/.mcp.json" ] && echo y || echo n) checked=$(_check_linked "$HOME/.mcp.json" && echo y || echo n) servers=$(grep -c fixture-server "$HOME/.mcp.json") warnings=[$WARNINGS]"
run_48b
echo "pass2: exists=$([ -e "$HOME/.mcp.json" ] && echo y || echo n) warnings=[$WARNINGS]"
EOF
    } > "$WT/t8.sh"
    local out mode
    out=$(_gb t8.sh)
    echo "$out" | sed 's/^/    | /'
    mode=$(echo "$out" | sed -n 's/^mode=//p')
    assert_contains "$out" "pass1: exists=y" "~/.mcp.json created" || return 1
    local p1; p1=$(echo "$out" | grep '^pass1: ')
    assert_contains "$p1" "checked=y" "accepted by _check_linked in mode $mode" || return 1
    assert_contains "$p1" "servers=1" "carries the canonical content" || return 1
    assert_contains "$p1" "warnings=[]" "no warning" || return 1
    case "$mode" in
        symlink) assert_contains "$p1" "link=y" "symlink mode: a real link" || return 1 ;;
        junction|copy) assert_contains "$p1" "link=n" "$mode mode: a file copy" || return 1 ;;
        *) echo "    unknown mode '$mode'"; return 1 ;;
    esac
    assert_contains "$out" "pass2: exists=y warnings=[]" "second run is idempotent and quiet"
}
_win_case "check 4.8b: ~/.mcp.json is created through the link helpers, consistent with the mode" test_mcp_link_autofix_real

# ── 9. .cmd launcher found by the real cc-install-invariants.sh (slice 2) ───────────────────
test_cmd_launcher_invariants_real() {
    _stage_repo
    cat > "$WT/t9.sh" <<'EOF'
#!/usr/bin/env bash
source "$HOME/repo/global/hooks/lib-portable.sh"
source "$HOME/repo/setup/tests/lib-cc-install-fixture.sh"
MIRROR="$HOME/.cc-mirror/mclaude"
make_cc_mirror_fixture "$MIRROR" "$(_cc_launcher_path)" 2.1.280 '^2.1.280' false
mkdir -p "$HOME/template"
printf '{\n  "env": {\n    "DISABLE_AUTOUPDATER": "1"\n  },\n  "hooks": {}\n}\n' > "$HOME/template/settings.json"
echo "launcher_path=$(_cc_launcher_path)"
echo "launcher_find=$(_cc_launcher_find)"
echo "local_bin_mclaude_exists=$([ -e "$HOME/.local/bin/mclaude" ] && echo y || echo n)"
CC_MIRROR_DIR="$MIRROR" CC_INSTALL_SNAPSHOT="$HOME/snap" CC_SETTINGS_TEMPLATE="$HOME/template/settings.json" CC_VAULT_MANAGE= \
  bash "$HOME/repo/setup/scripts/cc-install-invariants.sh" 2>&1 | sed 's/^/inv: /'
echo "inv_rc=${PIPESTATUS[0]}"
EOF
    local out
    out=$(_gb t9.sh)
    echo "$out" | sed 's/^/    | /'
    local found; found=$(echo "$out" | sed -n 's/^launcher_find=//p')
    [[ "$found" == */.cc-mirror/bin/mclaude.cmd ]] || { echo "    _cc_launcher_find did not return the .cmd (got '$found')"; return 1; }
    assert_contains "$out" "local_bin_mclaude_exists=n" "nothing at the Linux location" || return 1
    assert_not_contains "$out" "inv: FAIL: LAUNCHER" "the real invariants script does not call the .cmd missing" || return 1
    assert_contains "$out" "inv: INFO: launcher is a Windows .cmd" "and says why it did not parse an exec line" || return 1
    local result; result=$(echo "$out" | grep '^inv: RESULT:')
    assert_contains "$result" "launcher=$found" "RESULT names the .cmd it used"
}
_win_case "cc-install-invariants.sh finds ~/.cc-mirror/bin/mclaude.cmd and reports it (no false LAUNCHER FAIL)" test_cmd_launcher_invariants_real

# ── 11. installer prerequisites on the metal (slice 3) ─────────────────────────────────────
# Decision 2026-11-20: admin rights and the PowerShell rights the fleet needs are prerequisites — checked
# and stated, never worked around. This host runs the probe NOT elevated with an effective policy of Restricted
# (measured 2026-11-25: every scope Undefined), so the real check must report both as missing and
# stop with exit 3. The assertions are written against what the check itself measured, so the
# suite also passes on an elevated host with RemoteSigned.
test_prerequisites_real() {
    _stage_repo
    cp "$REPO_ROOT/setup/preflight.sh" "$WT/repo/setup/"
    cat > "$WT/t11.sh" <<'EOF'
#!/usr/bin/env bash
bash "$HOME/repo/setup/preflight.sh" --prerequisites-only --no-color; echo "prereq_rc=$?"
echo "raw_net_session_rc=$(net session >/dev/null 2>&1; echo $?)"
EOF
    local out rc summary elevated policy
    out=$(_gb t11.sh)
    echo "$out" | sed 's/^/    | /'
    rc=$(echo "$out" | sed -n 's/^prereq_rc=//p')
    summary=$(echo "$out" | grep 'PREREQ: ' | tail -1)
    [[ -n "$summary" ]] || { echo "    no PREREQ summary line"; return 1; }
    elevated=$(echo "$summary" | sed -n 's/.*elevated=\([a-z]*\).*/\1/p')
    policy=$(echo "$summary" | sed -n 's/.*policy=\([A-Za-z]*\).*/\1/p')
    echo "    measured on this host: elevated=$elevated effective policy=$policy rc=$rc"
    local s
    for s in MachinePolicy UserPolicy Process CurrentUser LocalMachine; do
        assert_contains "$out" "ExecutionPolicy $s = " "scope $s is stated" || return 1
    done
    local want_rc=0 want_result=ok
    if [[ "$elevated" == no ]]; then
        assert_contains "$out" "[FAIL] Administrator rights" "not elevated → stated as missing" || return 1
        assert_contains "$out" "Run as administrator" "with the one thing to do" || return 1
        want_rc=3; want_result=missing
    else
        assert_contains "$out" "[PASS] Administrator rights" "" || return 1
    fi
    case "$policy" in
        RemoteSigned|Unrestricted|Bypass) assert_contains "$out" "[PASS] PowerShell execution policy" "" || return 1 ;;
        *)  assert_contains "$out" "[FAIL] PowerShell execution policy" "effective $policy → stated as missing" || return 1
            assert_contains_any "$out" "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned" "Group Policy" || return 1
            want_rc=3; want_result=missing ;;
    esac
    assert_eq "$want_rc" "$rc" "exit code matches what was measured (elevated=$elevated, policy=$policy)" || return 1
    assert_contains "$summary" "result=$want_result" "" || return 1
    # consistency with the raw probe the check builds on
    local raw; raw=$(echo "$out" | sed -n 's/^raw_net_session_rc=//p')
    if [[ "$raw" == 0 ]]; then assert_eq "yes" "$elevated" "net session succeeded, so the check must say elevated"; fi
    assert_not_contains "$out" "--- Commands ---" "only the prerequisites ran"
}
_win_case "installer prerequisites (admin + execution policy) are measured, stated per scope, and stop with exit 3 when missing" test_prerequisites_real

# ── 12. a ported hook runs on the metal (slice 3: _python3 in hooks) ────────────────────────
# compound-cd-warn.sh must BLOCK a `cd x && cmd`. With a bare python3 it silently exited 0 on this
# host, because python3 is the Store redirector (exit 0, no JSON parsed → empty command).
test_ported_hook_real() {
    _stage_repo
    cp "$REPO_ROOT/global/hooks/compound-cd-warn.sh" "$REPO_ROOT/global/hooks/lib-hook-stdin.sh" "$WT/repo/global/hooks/"
    cat > "$WT/t12.sh" <<'EOF'
#!/usr/bin/env bash
H="$HOME/repo/global/hooks"
echo "raw_python3=[$(python3 --version 2>&1 </dev/null | head -1)]"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"cd /tmp && ls"}}' | bash "$H/compound-cd-warn.sh" >/dev/null 2>"$HOME/err.txt"; echo "compound_rc=$?"
echo "compound_err=$(head -c 80 "$HOME/err.txt")"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls /tmp"}}' | bash "$H/compound-cd-warn.sh" >/dev/null 2>&1; echo "plain_rc=$?"
source "$H/lib-hook-stdin.sh"
echo "session_id=$(printf '%s' '{"session_id":"abc-123","prompt":"hi"}' | read_cc_session_id)"
EOF
    local out
    out=$(_gb t12.sh)
    echo "$out" | sed 's/^/    | /'
    assert_contains "$out" "compound_rc=2" 'compound-cd-warn blocks "cd … && …" under Git Bash (python resolved past the Store stub)' || return 1
    assert_contains "$out" "compound_err=compound-cd-warn" "and says why" || return 1
    assert_contains "$out" "plain_rc=0" "a plain command passes" || return 1
    assert_contains "$out" "session_id=abc-123" "lib-hook-stdin parses the session id through the resolved Python"
}
_win_case "a ported hook (compound-cd-warn) and lib-hook-stdin work under Git Bash with the Store stub on PATH" test_ported_hook_real

# ── 13. afx dispatcher on the metal (CFG-1093 / CFG-1087 slice) ─────────────────────────────
# The dispatcher resolves verbs, a .py verb gets native C:/ paths, --install writes afx.cmd, and that shim
# runs from cmd.exe with the verb's exit code — a bare `bash` there would be the WSL launcher.
test_afx_real() {
    _stage_repo
    cp "$REPO_ROOT/global/hooks/lib-detect-repo.sh" "$WT/repo/global/hooks/"
    cp "$REPO_ROOT/setup/scripts/afx.sh" "$WT/repo/setup/scripts/"
    printf '#!/usr/bin/env bash\necho SYNC\n' > "$WT/repo/sync.sh"
    printf '#!/usr/bin/env bash\nfor a in "$@"; do echo "ARG[$a]"; done\n' > "$WT/repo/setup/scripts/hello.sh"
    printf '#!/usr/bin/env bash\nexit 7\n' > "$WT/repo/setup/scripts/rc7.sh"
    printf 'import sys, os\nprint("PYARGS=" + "|".join(sys.argv[1:]))\nprint("PYEXISTS=" + str(os.path.exists(sys.argv[1])))\n' > "$WT/repo/setup/scripts/pyecho.py"
    cat > "$WT/t13.sh" <<'EOF'
#!/usr/bin/env bash
A="$HOME/repo/setup/scripts/afx.sh"
echo "which=$(bash "$A" --which hello)"
echo "hello=$(bash "$A" hello 'a b' | tr '\n' ' ')"
bash "$A" rc7; echo "rc7=$?"
bash "$A" nosuch >/dev/null 2>&1; echo "unknown_rc=$?"
bash "$A" pyecho "$HOME/repo/sync.sh" "--f=$HOME/x" plain </dev/null 2>&1 | tr -d '\r'
bash "$A" --install "$HOME/bin" 2>&1
echo "install_rc=$?"
echo "cmd_exists=$([ -f "$HOME/bin/afx.cmd" ] && echo y || echo n) afx_exists=$([ -f "$HOME/bin/afx" ] && echo y || echo n)"
echo "shim=$(tr -d '\r' < "$HOME/bin/afx.cmd" | grep -v '^REM\|^@echo' | head -1)"
SHIM="$(cygpath -w "$HOME/bin/afx.cmd")"
echo "via_cmd=$(cmd.exe //c "$SHIM" hello x </dev/null 2>&1 | tr -d '\r' | tr '\n' ' ')"
cmd.exe //c "$SHIM" rc7 </dev/null >/dev/null 2>&1; echo "cmd_rc7=$?"
EOF
    local out
    out=$(_gb t13.sh)
    echo "$out" | sed 's/^/    | /'
    assert_contains "$out" "setup/scripts/hello.sh" "--which resolves inside the repo afx lives in" || return 1
    assert_contains "$out" "hello=ARG[a b]" "a .sh verb runs with its args" || return 1
    assert_contains "$out" "rc7=7" "exit code passes through" || return 1
    assert_contains "$out" "unknown_rc=2" "unknown verb exits 2" || return 1
    if [[ "$out" == *"no usable Python 3"* ]]; then
        echo "    (no usable Python on this host — afx said so)"
    else
        assert_contains "$out" "PYARGS=C:/" "the .py verb's absolute path arrives native (C:/…)" || return 1
        assert_contains "$out" "|--f=C:/" "--opt=/abs values arrive native" || return 1
        assert_contains "$out" "|plain" "plain words untouched" || return 1
        assert_contains "$out" "PYEXISTS=True" "the native Python can open the converted path" || return 1
    fi
    assert_contains "$out" "install_rc=0" "--install succeeds" || return 1
    assert_contains "$out" "cmd_exists=y afx_exists=y" "afx and afx.cmd placed" || return 1
    assert_contains "$out" 'shim="' "the shim calls an absolute bash.exe" || return 1
    assert_contains "$out" "Git" "…the Git for Windows one, not the WSL alias" || return 1
    assert_contains "$out" "via_cmd=ARG[x]" "afx.cmd runs a verb from cmd.exe" || return 1
    assert_contains "$out" "cmd_rc7=7" "and returns the verb's exit code"
}
_win_case "afx: verbs dispatch, .py gets native paths, afx.cmd runs from cmd.exe with the exit code (CFG-1093)" test_afx_real

# ── 10. nothing left behind outside the throwaway dir ───────────────────────────────────────
test_throwaway_only() {
    [[ -d "$WT" ]] || { echo "    throwaway dir missing"; return 1; }
    local n
    n=$(ls -d "$WIN_TEMP_ROOT"/fleet-win-test-* 2>/dev/null | grep -v -x "$WT" | wc -l)
    assert_eq "0" "$n" "no other fleet-win-test-* dirs left behind (found $n)"
}
_win_case "every Windows-side write stayed inside the throwaway HOME" test_throwaway_only

suite_summary
