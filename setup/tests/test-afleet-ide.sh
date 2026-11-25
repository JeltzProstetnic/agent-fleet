#!/usr/bin/env bash
# Tests for setup/scripts/afleet-ide.sh — "IDE terminal" mode (CFG-991 step 1).
#
# Hermetic: no IDE is installed or started. A fake IDE is a lock file of the shape the
# Claude Code IDE extensions write (`<lock dir>/<port>.lock`, JSON) plus a python3
# WebSocket stub listening on that port, so discovery under a non-default
# CLAUDE_CONFIG_DIR and under the WSL lock-dir path is proven without an editor.
# The 07c session-lock role for `af` nested in an IDE terminal runs the REAL check under
# a REAL process tree (IDE-shaped ancestors made with `exec -a`, a fake CC matched by
# _CC_PROC_RE), the technique of test-07b-nested-role.sh.
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/afleet-ide.sh"
LOCK_LIB="$REPO_ROOT/setup/scripts/session-lock.sh"
HOOK_07C="$REPO_ROOT/global/hooks/checks/07c-session-lock.sh"

suite_header "afleet-ide.sh (IDE terminal mode, CFG-991 step 1)"

# ── Harness ──────────────────────────────────────────────────────────────────

# Source the lib in a subshell with a controlled environment and run one function.
# Every AFLEET_IDE_* override is a test seam; none of them leaves this sandbox.
ide() {   # <function> [args] — env: CFG (config dir), WSL (0|1), WINUSERS, WINMNT
    (
        export NO_COLOR=1
        export AFLEET_IDE_CONFIG_DIR="${CFG:-$HOME/.cc/config}"
        export AFLEET_IDE_WSL="${WSL:-0}"
        export AFLEET_IDE_WIN_USERS="${WINUSERS:-$HOME/none/Users}"
        export AFLEET_IDE_WIN_MNT="${WINMNT:-$HOME/none}"
        unset TERM_PROGRAM TERMINAL_EMULATOR USERPROFILE
        [[ -n "${TP:-}" ]] && export TERM_PROGRAM="$TP"
        [[ -n "${TE:-}" ]] && export TERMINAL_EMULATOR="$TE"
        [[ -n "${UP:-}" ]] && export USERPROFILE="$UP"
        source "$SCRIPT"
        "$@"
    )
}

# A lock file as the IDE extensions write it. Args: <dir> <port> <ideName> <token> <windows 0|1> <folder>...
_mk_lock() {
    local dir="$1" port="$2" name="$3" token="$4" win="$5"; shift 5
    local folders="" f
    for f in "$@"; do folders="${folders:+$folders,}$(printf '%s' "$f" | jq -R .)"; done
    mkdir -p "$dir"
    printf '{"pid": 4242, "workspaceFolders": [%s], "ideName": "%s", "transport": "ws", "runningInWindows": %s, "authToken": "%s"}\n' \
        "$folders" "$name" "$([[ "$win" == 1 ]] && echo true || echo false)" "$token" > "$dir/$port.lock"
}

# python3 WebSocket stub: answers the handshake with 101 when the auth header carries the
# token, 401 otherwise, and appends every request it sees to a capture file. Prints the port
# it chose into a file so the lock file can name it. Dies with the test (killed below).
_start_ws_stub() {   # <token> <portfile> <capture> — sets STUB_PID, STUB_PORT
    cat > "$TEST_TMPDIR/ws-stub.py" << 'PY'
import base64, hashlib, os, socket, sys
token, portfile, capture = sys.argv[1], sys.argv[2], sys.argv[3]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 0)); s.listen(5)
open(portfile, 'w').write(str(s.getsockname()[1]))
s.settimeout(60)
while True:
    try:
        c, _ = s.accept()
    except socket.timeout:
        break
    c.settimeout(3); data = b''
    try:
        while b'\r\n\r\n' not in data:
            chunk = c.recv(4096)
            if not chunk:
                break
            data += chunk
    except socket.timeout:
        pass
    text = data.decode('latin1')
    with open(capture, 'a') as f:
        f.write(text + '\n=====\n')
    h = {}
    for line in text.split('\r\n')[1:]:
        if ':' in line:
            k, v = line.split(':', 1); h[k.strip().lower()] = v.strip()
    if h.get('upgrade', '').lower() == 'websocket' and h.get('x-claude-code-ide-authorization') == token:
        acc = base64.b64encode(hashlib.sha1((h.get('sec-websocket-key', '') + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        c.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n' % acc).encode())
    else:
        c.sendall(b'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n')
    c.close()
PY
    rm -f "$2"
    python3 "$TEST_TMPDIR/ws-stub.py" "$1" "$2" "$3" </dev/null >/dev/null 2>&1 &
    STUB_PID=$!
    local i; for i in $(seq 1 50); do [[ -s "$2" ]] && break; sleep 0.1; done
    STUB_PORT=$(cat "$2" 2>/dev/null)
    [[ -n "$STUB_PORT" ]]
}
_stop_ws_stub() { kill "${STUB_PID:-}" 2>/dev/null || true; wait "${STUB_PID:-}" 2>/dev/null || true; }

# A port nobody listens on: bind-and-release through python3, so the probe gets a refusal.
_free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

_HAVE_PY=0; command -v python3 >/dev/null 2>&1 && _HAVE_PY=1

# ── Basic ────────────────────────────────────────────────────────────────────

test_script_exists_and_parses() {
    assert_file_exists "$SCRIPT" || return 1
    bash -n "$SCRIPT" || { echo "FAIL: afleet-ide.sh does not parse"; return 1; }
    assert_file_contains "$SCRIPT" '#!/usr/bin/env bash'
}
run_test "afleet-ide.sh exists and parses" test_script_exists_and_parses

test_cli_usage() {
    local out rc=0
    out=$(bash "$SCRIPT" --help 2>&1) || rc=$?
    assert_contains "$out" "status" "usage names the status verb" || return 1
    assert_contains "$out" "autoconnect" "usage names the autoconnect verb" || return 1
    out=$(bash "$SCRIPT" bogus 2>&1) || rc=$?
    assert_eq "2" "$rc" "an unknown verb exits 2"
}
run_test "CLI: --help lists the verbs, an unknown verb exits 2" test_cli_usage

# ── Lock-dir search path (mirrors the Claude Code binary's list, research §2) ──

test_lock_dirs_non_default_config_dir() {
    local out
    out=$(CFG="$HOME/mirror/config" ide afleet_ide_lock_dirs)
    assert_eq "$HOME/mirror/config/ide"$'\n'"$HOME/.claude/ide" "$out" \
        "a non-default config dir is searched first, then ~/.claude/ide where an IDE without the variable writes"
}
run_test "lock dirs: non-default CLAUDE_CONFIG_DIR/ide first, then ~/.claude/ide" test_lock_dirs_non_default_config_dir

test_lock_dirs_default_config_dir_is_single() {
    local out
    out=$(CFG="$HOME/.claude" ide afleet_ide_lock_dirs)
    assert_eq "$HOME/.claude/ide" "$out" "with the default config dir there is one lock dir, listed once"
}
run_test "lock dirs: the default ~/.claude gives exactly one dir, not a duplicate" test_lock_dirs_default_config_dir_is_single

test_lock_dirs_wsl_adds_windows_profiles() {
    local users="$TEST_TMPDIR/mnt/c/Users"
    mkdir -p "$users/acme/.claude/ide" "$users/home/.claude/ide" "$users/garden"   # garden: no ide dir
    local out
    out=$(CFG="$HOME/mirror/config" WSL=1 WINUSERS="$users" WINMNT="$TEST_TMPDIR/mnt" UP='C:\Users\acme' ide afleet_ide_lock_dirs)
    assert_eq "$HOME/mirror/config/ide"$'\n'"$HOME/.claude/ide"$'\n'"$users/acme/.claude/ide"$'\n'"$users/home/.claude/ide" "$out" \
        "WSL adds the Windows profiles' .claude/ide (USERPROFILE translated and de-duplicated; a profile without one is skipped)"
}
run_test "lock dirs: on WSL the Windows-side profiles are searched too, once each" test_lock_dirs_wsl_adds_windows_profiles

test_lock_dirs_not_wsl_has_no_windows_dirs() {
    local users="$TEST_TMPDIR/mnt/c/Users"; mkdir -p "$users/acme/.claude/ide"
    local out
    out=$(CFG="$HOME/mirror/config" WSL=0 WINUSERS="$users" ide afleet_ide_lock_dirs)
    assert_not_contains "$out" "Users" "outside WSL no Windows profile dir is searched"
}
run_test "lock dirs: outside WSL the Windows profiles are not searched" test_lock_dirs_not_wsl_has_no_windows_dirs

test_win2wsl_translation() {
    assert_eq "$TEST_TMPDIR/mnt/c/Users/acme/proj" "$(WINMNT="$TEST_TMPDIR/mnt" ide _afleet_ide_win2wsl 'C:\Users\acme\proj')" "backslash drive path" || return 1
    assert_eq "$TEST_TMPDIR/mnt/d/src/x" "$(WINMNT="$TEST_TMPDIR/mnt" ide _afleet_ide_win2wsl 'D:/src/x/')" "forward-slash drive path, trailing slash dropped" || return 1
    assert_eq "/home/garden/proj" "$(ide _afleet_ide_win2wsl '/home/garden/proj')" "a Linux path passes through"
}
run_test "Windows path → WSL path translation (drive letter, both slash styles, passthrough)" test_win2wsl_translation

# ── IDE terminal detection ───────────────────────────────────────────────────

test_terminal_detection() {
    assert_eq "vscode" "$(TP=vscode ide afleet_ide_terminal)" "TERM_PROGRAM=vscode" || return 1
    assert_eq "jetbrains" "$(TE=JetBrains-JediTerm ide afleet_ide_terminal)" "TERMINAL_EMULATOR=JetBrains-JediTerm" || return 1
    local rc=0; ide afleet_ide_terminal >/dev/null || rc=$?
    assert_eq "1" "$rc" "a plain terminal is rc 1 with no output"
}
run_test "IDE terminal detected from TERM_PROGRAM / TERMINAL_EMULATOR, plain terminal rc 1" test_terminal_detection

# ── Discovery with a fake lock file and a WebSocket stub ─────────────────────

test_fake_ide_live_under_non_default_config_dir() {
    [[ $_HAVE_PY == 1 ]] || { echo "python3 missing — cannot run the WebSocket stub"; return 1; }
    local cfg="$HOME/mirror/config" token="tok-$RANDOM-$RANDOM-secret" cap="$TEST_TMPDIR/cap.txt"
    _start_ws_stub "$token" "$TEST_TMPDIR/port" "$cap" || { echo "stub did not start"; return 1; }
    mkdir -p "$HOME/acme-proj"
    _mk_lock "$cfg/ide" "$STUB_PORT" "Visual Studio Code" "$token" 0 "$HOME/acme-proj"
    local out
    out=$(CFG="$cfg" ide afleet_ide_list "$HOME/acme-proj")
    _stop_ws_stub
    assert_contains "$out" "$STUB_PORT"$'\t'"Visual Studio Code"$'\t'"live"$'\t'"yes" "found, live, and the cwd matches its workspace (measured: '$out')" || return 1
    assert_not_contains "$out" "$token" "the auth token is never printed" || return 1
    assert_file_contains "$cap" "Upgrade: websocket" "the probe is a WebSocket handshake" || return 1
    assert_file_contains "$cap" "X-Claude-Code-Ide-Authorization: $token" "the probe presents the lock file's token, as the CLI does"
}
run_test "fake IDE (lock + WebSocket stub) under a non-default CLAUDE_CONFIG_DIR: live, workspace match, token kept off the output" test_fake_ide_live_under_non_default_config_dir

test_fake_ide_in_home_claude_found_too() {
    [[ $_HAVE_PY == 1 ]] || { echo "python3 missing"; return 1; }
    local token="tok-$RANDOM-home"
    _start_ws_stub "$token" "$TEST_TMPDIR/port" "$TEST_TMPDIR/cap.txt" || return 1
    mkdir -p "$HOME/garden"
    _mk_lock "$HOME/.claude/ide" "$STUB_PORT" "IntelliJ IDEA" "$token" 0 "$HOME/garden"
    local out
    out=$(CFG="$HOME/mirror/config" ide afleet_ide_list "$HOME/garden/sub")
    _stop_ws_stub
    assert_contains "$out" "IntelliJ IDEA"$'\t'"live"$'\t'"yes" "an IDE that wrote to ~/.claude/ide (no CLAUDE_CONFIG_DIR in its env) is found; a subfolder of the workspace matches"
}
run_test "fake IDE whose lock sits in ~/.claude/ide is found under a non-default config dir; subfolder matches" test_fake_ide_in_home_claude_found_too

test_stale_lock_reported() {
    [[ $_HAVE_PY == 1 ]] || { echo "python3 missing"; return 1; }
    local port; port=$(_free_port)
    _mk_lock "$HOME/mirror/config/ide" "$port" "Visual Studio Code" "tok-stale" 0 "$HOME/acme-proj"
    local out
    out=$(CFG="$HOME/mirror/config" ide afleet_ide_list "$HOME/acme-proj")
    assert_contains "$out" "$port"$'\t'"Visual Studio Code"$'\t'"stale" "a lock whose port has no listener is stale (IDE closed)"
}
run_test "a lock file with nothing listening on its port is reported stale" test_stale_lock_reported

test_wsl_windows_ide_lock_found_and_matched() {
    [[ $_HAVE_PY == 1 ]] || { echo "python3 missing"; return 1; }
    local mnt="$TEST_TMPDIR/mnt" users="$TEST_TMPDIR/mnt/c/Users" token="tok-win-$RANDOM"
    mkdir -p "$users/acme/proj/src"
    _start_ws_stub "$token" "$TEST_TMPDIR/port" "$TEST_TMPDIR/cap.txt" || return 1
    _mk_lock "$users/acme/.claude/ide" "$STUB_PORT" "Visual Studio Code" "$token" 1 'C:\Users\acme\proj'
    local out
    out=$(CFG="$HOME/mirror/config" WSL=1 WINUSERS="$users" WINMNT="$mnt" ide afleet_ide_list "$users/acme/proj/src")
    _stop_ws_stub
    assert_contains "$out" "Visual Studio Code"$'\t'"live"$'\t'"yes" "a Windows-side IDE's lock (runningInWindows, C:\\ workspace) is found from WSL and its folder matched after translation (measured: '$out')" || return 1
    assert_contains "$out" "$users/acme/.claude/ide/$STUB_PORT.lock" "the lock file path is reported"
}
run_test "WSL: a Windows-side IDE lock under /mnt/c/Users/<profile>/.claude/ide is found and its C:\\ workspace matched" test_wsl_windows_ide_lock_found_and_matched

test_no_lock_dirs_at_all_is_empty_not_error() {
    local out rc=0
    out=$(CFG="$HOME/mirror/config" ide afleet_ide_list "$HOME") || rc=$?
    assert_eq "" "$out" "no lock dir anywhere → empty list" || return 1
    assert_eq "0" "$rc" "and no error"
}
run_test "no lock directory exists: empty list, rc 0" test_no_lock_dirs_at_all_is_empty_not_error

# ── Preflight verdict for `af --ide` ─────────────────────────────────────────

test_preflight_none_found_names_dirs() {
    local out rc=0
    out=$(CFG="$HOME/mirror/config" ide afleet_ide_preflight "$HOME/acme-proj" 2>&1) || rc=$?
    assert_eq "1" "$rc" "no IDE → rc 1" || return 1
    assert_contains "$out" "$HOME/mirror/config/ide" "names the first lock dir searched" || return 1
    assert_contains "$out" "$HOME/.claude/ide" "names the second lock dir searched" || return 1
    assert_contains "$out" "/ide" "points at the in-session /ide command"
}
run_test "preflight: no IDE found → rc 1 and the searched lock dirs are named" test_preflight_none_found_names_dirs

test_preflight_exactly_one_live_match() {
    [[ $_HAVE_PY == 1 ]] || { echo "python3 missing"; return 1; }
    local token="tok-one"
    _start_ws_stub "$token" "$TEST_TMPDIR/port" "$TEST_TMPDIR/cap.txt" || return 1
    mkdir -p "$HOME/acme-proj"
    _mk_lock "$HOME/mirror/config/ide" "$STUB_PORT" "Visual Studio Code" "$token" 0 "$HOME/acme-proj"
    _mk_lock "$HOME/mirror/config/ide" "$(_free_port)" "IntelliJ IDEA" "tok-x" 0 "$HOME/garden"   # stale, other folder
    local out rc=0
    out=$(CFG="$HOME/mirror/config" ide afleet_ide_preflight "$HOME/acme-proj" 2>&1) || rc=$?
    _stop_ws_stub
    assert_eq "0" "$rc" "exactly one live IDE with this folder open → rc 0 (measured output: '$out')" || return 1
    assert_contains "$out" "Visual Studio Code" "names the IDE that will be connected"
}
run_test "preflight: exactly one live matching IDE → rc 0, named" test_preflight_exactly_one_live_match

test_preflight_two_live_matches_is_ambiguous() {
    [[ $_HAVE_PY == 1 ]] || { echo "python3 missing"; return 1; }
    local token="tok-two" p2
    _start_ws_stub "$token" "$TEST_TMPDIR/port" "$TEST_TMPDIR/cap.txt" || return 1
    mkdir -p "$HOME/acme-proj"
    _mk_lock "$HOME/mirror/config/ide" "$STUB_PORT" "Visual Studio Code" "$token" 0 "$HOME/acme-proj"
    # a second live IDE on the same folder: the same stub port is enough for the probe — a
    # second lock file under the other search dir names it (the CLI dedups by lock file, not port)
    _mk_lock "$HOME/.claude/ide" "$STUB_PORT" "Cursor" "$token" 0 "$HOME/acme-proj"
    local out rc=0
    out=$(CFG="$HOME/mirror/config" ide afleet_ide_preflight "$HOME/acme-proj" 2>&1) || rc=$?
    _stop_ws_stub
    assert_eq "2" "$rc" "two live IDEs with this folder → rc 2 (--ide needs exactly one)" || return 1
    assert_contains "$out" "/ide" "tells the user /ide picks one"
}
run_test "preflight: two live matching IDEs → rc 2 (ambiguous for --ide), /ide suggested" test_preflight_two_live_matches_is_ambiguous

# ── autoConnectIde (opt-in, global config) ───────────────────────────────────

test_claude_json_path_follows_config_dir() {
    assert_eq "$HOME/mirror/config/.claude.json" "$(CFG="$HOME/mirror/config" ide afleet_ide_claude_json)" "non-default config dir → <dir>/.claude.json" || return 1
    assert_eq "$HOME/.claude.json" "$(CFG="$HOME/.claude" ide afleet_ide_claude_json)" "default config dir → ~/.claude.json (the CLI's global config lives beside ~/.claude, not inside it)"
}
run_test "the global config file is <config dir>/.claude.json, or ~/.claude.json for the default dir" test_claude_json_path_follows_config_dir

test_autoconnect_unset_by_default_and_opt_in() {
    local cj="$HOME/mirror/config/.claude.json" out
    mkdir -p "$(dirname "$cj")"; echo '{"theme": "dark", "projects": {"/x": {"hasTrustDialogAccepted": true}}}' > "$cj"
    out=$(CFG="$HOME/mirror/config" ide afleet_ide_autoconnect)
    assert_contains "$out" "unset" "nothing written until the user asks" || return 1
    CFG="$HOME/mirror/config" ide afleet_ide_autoconnect on >/dev/null || return 1
    assert_eq "true" "$(jq -r .autoConnectIde "$cj")" "on → autoConnectIde true" || return 1
    assert_eq "dark" "$(jq -r .theme "$cj")" "other keys survive" || return 1
    assert_eq "true" "$(jq -r '.projects["/x"].hasTrustDialogAccepted' "$cj")" "nested keys survive" || return 1
    CFG="$HOME/mirror/config" ide afleet_ide_autoconnect off >/dev/null || return 1
    assert_eq "false" "$(jq -r .autoConnectIde "$cj")" "off → false" || return 1
    out=$(CFG="$HOME/mirror/config" ide afleet_ide_autoconnect)
    assert_contains "$out" "false" "status reads the written value"
}
run_test "autoconnect: unset until asked; on/off write autoConnectIde and keep every other key" test_autoconnect_unset_by_default_and_opt_in

test_autoconnect_creates_missing_file_and_refuses_bad_json() {
    local cj="$HOME/mirror/config/.claude.json" rc=0
    CFG="$HOME/mirror/config" ide afleet_ide_autoconnect on >/dev/null || return 1
    assert_eq "true" "$(jq -r .autoConnectIde "$cj")" "a missing global config is created with just this key" || return 1
    printf '{not json' > "$cj"
    CFG="$HOME/mirror/config" ide afleet_ide_autoconnect on >/dev/null 2>&1 || rc=$?
    assert_neq "0" "$rc" "an unparseable file is refused" || return 1
    assert_eq "{not json" "$(cat "$cj")" "and left untouched"
}
run_test "autoconnect: creates a missing .claude.json, refuses to touch an unparseable one" test_autoconnect_creates_missing_file_and_refuses_bad_json

test_autoconnect_rejects_other_values() {
    local rc=0
    CFG="$HOME/mirror/config" ide afleet_ide_autoconnect maybe >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "only on|off are accepted"
}
run_test "autoconnect: a value other than on/off exits 2" test_autoconnect_rejects_other_values

# ── status (human output) ────────────────────────────────────────────────────

test_status_output_shape() {
    local out
    out=$(CFG="$HOME/mirror/config" TP=vscode ide afleet_ide_status "$HOME/acme-proj")
    assert_contains "$out" "vscode" "names the detected IDE terminal" || return 1
    assert_contains "$out" "$HOME/mirror/config/ide" "lists the lock dirs" || return 1
    assert_contains "$out" "autoConnectIde" "reports the opt-in state" || return 1
    assert_contains "$out" "af --ide" "and how to connect"
}
run_test "status: terminal, lock dirs, autoConnectIde state and the connect commands" test_status_output_shape

# ── 07c session-lock role when `af` runs nested in an IDE terminal ───────────
# The one trap the research named (§5 row 1): an IDE's processes sit ABOVE the launcher.
# check_lock proves ownership by walking from CC up to the lock's pid (the af shell) with
# no other CC in between — IDE processes must neither read as a CC nor break that walk.

_FAKE_CC_RE='(^|/)fakecc-(term|panel)([[:space:]]|$)'

_mk_ide_tree() {
    # IDE main process → pty host → the user's shell → `af` (writes the lock, runs CC as a
    # child) → CC. argv[0] carries an IDE-shaped name; the real tree's cmdlines look alike.
    cat > "$TEST_TMPDIR/ide-main.sh" << 'EOF'
#!/usr/bin/env bash
exec -a /usr/share/code/code bash -c 'bash "$@"; rc=$?; exit $rc' _ "$@"
EOF
    # `--type=ptyHost` is there for the cmdline only; the inner shell drops it before running.
    cat > "$TEST_TMPDIR/ide-pty.sh" << 'EOF'
#!/usr/bin/env bash
exec -a /usr/share/code/code bash -c 'shift; bash "$@"; rc=$?; exit $rc' _ --type=ptyHost "$@"
EOF
    cat > "$TEST_TMPDIR/fakecc-term.sh" << 'EOF'
#!/usr/bin/env bash
exec -a fakecc-term bash -c 'bash "$@"; rc=$?; exit $rc' _ "$@"
EOF
    # af shape (CFG-672): the launcher writes the lock with its own pid and runs CC as a child.
    cat > "$TEST_TMPDIR/af-shell.sh" << EOF
#!/usr/bin/env bash
source "$LOCK_LIB"
[[ -n "\$2" ]] && _write_lock "\$1/.claude/.session-lock" "\$2" "" "\$\$"
shift 2
bash "\$@"; rc=\$?; exit \$rc
EOF
    cat > "$TEST_TMPDIR/run07c.sh" << EOF
#!/usr/bin/env bash
export _FORCE_WSL=0
export CONFIG_REPO="$TEST_TMPDIR/cr" PROJECT_DIR="$TEST_TMPDIR/proj"
WARNINGS="" INBOX_MSG=""
cd "$TEST_TMPDIR/proj"
source "$HOOK_07C"
printf 'WARNINGS=%s\n' "\$WARNINGS" > "$TEST_TMPDIR/warnings.txt"
EOF
    mkdir -p "$TEST_TMPDIR/cr/setup/scripts" "$TEST_TMPDIR/proj/.claude"
    cp "$LOCK_LIB" "$TEST_TMPDIR/cr/setup/scripts/session-lock.sh"
}

# ide-main → pty → af-shell(<afleet-id or "">) → fakecc-term → run07c, with TERM_PROGRAM=vscode
_run_in_ide_terminal() {   # <afleet-id or ""> — env for the CC: CC_SESSION_ID etc. from caller
    TERM_PROGRAM=vscode _CC_PROC_RE="$_FAKE_CC_RE" bash "$TEST_TMPDIR/ide-main.sh" "$TEST_TMPDIR/ide-pty.sh" \
        "$TEST_TMPDIR/af-shell.sh" "$TEST_TMPDIR/proj" "$1" "$TEST_TMPDIR/fakecc-term.sh" "$TEST_TMPDIR/run07c.sh" \
        >/dev/null 2>"$TEST_TMPDIR/tree.err" || true
}
_tree_err() { cat "$TEST_TMPDIR/tree.err" 2>/dev/null | head -5; }

_spawn_panel_cc() {   # a detached fake CC cwd'd in the project (an IDE panel's bundled CLI); echoes pid
    local pf="$TEST_TMPDIR/panel.pid" i; rm -f "$pf"
    ( cd "$TEST_TMPDIR/proj" && setsid bash -c 'echo $$ > "$0"; exec -a fakecc-panel sleep 60' "$pf" ) </dev/null >/dev/null 2>&1 &
    for i in $(seq 1 50); do
        [[ -s "$pf" ]] && tr '\0' ' ' < "/proc/$(cat "$pf")/cmdline" 2>/dev/null | grep -q '^fakecc-panel' && { cat "$pf"; return 0; }
        sleep 0.1
    done
    return 1
}

test_af_in_ide_terminal_is_leader() {
    [[ -d /proc ]] || { echo "needs /proc"; return 1; }
    _mk_ide_tree
    AFLEET_SESSION_ID=af-ide CC_SESSION_ID=cc-term _run_in_ide_terminal af-ide
    local marker="$TEST_TMPDIR/proj/.claude/.session-role.cc-term" role
    assert_file_exists "$marker" "07c wrote a role marker for the terminal session ($(_tree_err))" || return 1
    role=$(tr -d '[:space:]' < "$marker")
    assert_eq "leader" "$role" "af nested in an IDE terminal keeps the lead: IDE ancestors are not CCs and do not break the ancestry proof (measured role: '$role')" || return 1
    assert_file_contains "$TEST_TMPDIR/proj/.claude/.session-lock" '"cc-term"' "07c stamped its own lock with the session's cc id" || return 1
    assert_file_not_contains "$TEST_TMPDIR/warnings.txt" "SESSION_LOCKED" "no follower warning"
}
run_test "07c: af nested in an IDE terminal (IDE processes above the launcher) is classified leader" test_af_in_ide_terminal_is_leader

test_af_in_ide_terminal_with_panel_cli_live_is_follower() {
    [[ -d /proc ]] || { echo "needs /proc"; return 1; }
    _mk_ide_tree
    # The IDE's own panel session already holds the project: its lock is bound to its cc id, its
    # recorded pid is the ephemeral hook (dead), and its bundled CLI is live in the folder.
    true & local dpid=$!; wait "$dpid" 2>/dev/null || true
    ( source "$LOCK_LIB"; _write_lock "$TEST_TMPDIR/proj/.claude/.session-lock" "" "cc-panel" "$dpid" )
    local panel; panel=$(_spawn_panel_cc) || { echo "could not spawn the panel CC"; return 1; }
    ( unset AFLEET_SESSION_ID; CC_SESSION_ID=cc-term CLAUDE_CODE_SESSION_ID=cc-term _run_in_ide_terminal '' )
    kill "$panel" 2>/dev/null || true
    local marker="$TEST_TMPDIR/proj/.claude/.session-role.cc-term" role
    assert_file_exists "$marker" "07c wrote a role marker ($(_tree_err))" || return 1
    role=$(tr -d '[:space:]' < "$marker")
    assert_eq "follower" "$role" "with the IDE panel's own Claude live in the same folder, the terminal af session is a follower (two sessions, one project) (measured role: '$role')" || return 1
    assert_file_contains "$TEST_TMPDIR/proj/.claude/.session-lock" '"cc-panel"' "the panel's lock stays bound to the panel" || return 1
    assert_file_contains "$TEST_TMPDIR/warnings.txt" "SESSION_LOCKED" "and the follower warning fires"
}
run_test "07c: af in an IDE terminal while the IDE panel's own Claude is live in the folder → follower, panel lock untouched" test_af_in_ide_terminal_with_panel_cli_live_is_follower

test_default_cc_matcher_vs_ide_process_names() {
    # The DEFAULT matcher against the cmdlines real IDE trees show. No IDE process may read as
    # a CC; the extension's bundled CLI (a real CC) must.
    # (`ide_cmd`, not `cmd`: _pid_is_cc declares a local `cmd` that would shadow the fixture.)
    local ide_cmd rc
    for ide_cmd in '/usr/share/code/code --type=ptyHost --logsPath /home/home/.config/Code/logs' \
               '/usr/share/code/code --type=extensionHost --transformURIs' \
               '/home/home/.vscode-server/bin/0123abcd/node /home/home/.vscode-server/bin/0123abcd/out/bootstrap-fork --type=ptyHost' \
               '/opt/idea/jbr/bin/java -classpath /opt/idea/lib/platform-loader.jar com.intellij.idea.Main' \
               '/usr/share/code/code /home/home/.vscode/extensions/anthropic.claude-code-2.1.300-linux-x64/dist/extension.js' \
               'bash /home/home/.local/bin/mclaude'; do
        rc=0; ( source "$LOCK_LIB"; _pid_cmdline() { printf '%s' "$ide_cmd"; }; _pid_is_cc 1 ) || rc=$?
        assert_eq "1" "$rc" "not a CC: $ide_cmd" || return 1
    done
    ide_cmd='/home/home/.vscode/extensions/anthropic.claude-code-2.1.300-linux-x64/resources/native-binary/claude'
    rc=0; ( source "$LOCK_LIB"; _pid_cmdline() { printf '%s' "$ide_cmd"; }; _pid_is_cc 1 ) || rc=$?
    assert_eq "0" "$rc" "the extension's bundled CLI IS a CC: $ide_cmd"
}
run_test "default _CC_PROC_RE: IDE hosts (VS Code, Remote-WSL server, JetBrains) are not CCs; the extension's bundled CLI is" test_default_cc_matcher_vs_ide_process_names

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
