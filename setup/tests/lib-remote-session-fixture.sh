#!/usr/bin/env bash
# lib-remote-session-fixture.sh — fixtures shared by test-remote-session.sh, test-remote-session-submit.sh,
# test-remote-session-submit-lib.sh, test-remote-session-gate.sh and test-shutdown-follow.sh
# (CFG-878 / 1001 / 1004 / 1006 / 1028 / 1043). Source it after test-helpers.sh.
#   a_*  Layer A: fixture /proc — real sleepers with a faked /proc entry and a session record
#   t_*  real Claude Code JSONL transcript lines
#   r_*  relaunch / start: a fixture launcher (RS_LAUNCH) and main() run with typing stubbed
#   b_*  Layer B: a fake `claude` (a bash copy) under script(1) on its own pty, typed into by the
#        root injector; it records each submitted prompt in its transcript, as CC does
#   n_*  the shipped layer staged WITHOUT the care machinery beside it (what a deployment without
#        session caretaking runs)
# No real Claude Code session is ever touched: every "claude" here is spawned by the tests and
# killed by recorded PID. The driver (remote-session.sh, RS) and remote-exit.sh (EXIT_SH) are not
# part of every deployment: a test that drives them checks they exist first and skips otherwise.

LIB="$REPO_ROOT/setup/scripts/remote-session-lib.sh"
RS="$REPO_ROOT/setup/scripts/remote-session.sh"
EXIT_SH="$REPO_ROOT/setup/scripts/remote-exit.sh"
INJ="$REPO_ROOT/setup/scripts/tty-inject.py"

# ── Layer A: fixture /proc ────────────────────────────────────────────────────
APIDS=()
a_setup() {
    PROC="$TEST_TMPDIR/proc"; CC="$TEST_TMPDIR/cc"; BIN="$TEST_TMPDIR/bin"
    # A test that sets up twice must not inherit the first half's fake /proc: a dead fixture pid
    # still "reads" its pts there, and the tty-sharer guard then refuses the second half's target.
    rm -rf "$PROC" "$CC"
    mkdir -p "$PROC" "$CC/sessions" "$BIN"
    : > "$BIN/claude"
    APIDS=()
    export RS_PROC="$PROC" RS_CC_DIR="$CC" RS_WSL=0 RS_QDBUS="/bin/true"
    source "$LIB"
}
a_teardown() {
    local p; for p in "${APIDS[@]}"; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
    # Do not let the fixture overrides leak into Layer B's real-/proc subprocess (they did,
    # and rs_script_log then read a dead fixture dir instead of /proc).
    unset RS_PROC RS_CC_DIR RS_WSL RS_QDBUS RS_INJECT
}

# a_fake_proc <pid> <comm> <ppid> <tty> <exe-basename> [cwd]
a_fake_proc() {
    local d="$PROC/$1"; mkdir -p "$d/fd"
    echo "$2" > "$d/comm"
    echo "$1 ($2) S $3 0 0" > "$d/stat"
    ln -sf "$4" "$d/fd/0"
    ln -sf "$BIN/$5" "$d/exe"
    ln -sf "${6:-/home/user/none}" "$d/cwd"
    [[ -f "$BIN/$5" ]] || : > "$BIN/$5"
}
# a_spawn <comm> <tty> <cwd> <exe-basename> [ppid] — real sleeper + fake /proc + session json
a_spawn() {
    sleep 300 >/dev/null 2>&1 & local pid=$!; APIDS+=("$pid")
    a_fake_proc "$pid" "$1" "${5:-1}" "$2" "$4" "$3"
    printf '{"pid":%s,"sessionId":"sid-%s","cwd":"%s","status":"idle"}\n' "$pid" "$pid" "$3" \
        > "$CC/sessions/$pid.json"
    echo "$pid"
}
# a_spawn_in <config-dir> <comm> <tty> <cwd> <exe-basename> — a_spawn whose session record sits ONLY in <config-dir>,
# the CLAUDE_CONFIG_DIR its environ names (an `af --account` claude-swap profile, or the mclaude mirror seen from one),
# with a claude binary as argv0 — the shape every real session has (CFG-1032).
a_spawn_in() {
    local p; p=$(a_spawn "$2" "$3" "$4" "$5"); mkdir -p "$1/sessions"
    [[ "$1" == "$CC" ]] || mv "$CC/sessions/$p.json" "$1/sessions/$p.json"
    printf '%s\0' "$BIN/$5" > "$PROC/$p/cmdline"; printf 'PWD=%s\0CLAUDE_CONFIG_DIR=%s\0' "$4" "$1" > "$PROC/$p/environ"
    echo "$p"
}

# a_root_stub <path> — a fake root-exec prefix for RS_INJECT under RS_WSL=1: it answers tty-probe.py
# (inspect / sharers) from the fixture /proc and appends every other call — an injection — to
# <path>.calls. A dry-run canary that can fire: the WSL typing path calls it (unlike a word-split
# "/bin/sh -c '...'" string, which dies on a syntax error before writing anything).
a_root_stub() {
    cat > "$1" << 'EOF'
#!/usr/bin/env bash
if [[ "${1##*/}" == tty-probe.py ]]; then
  case "$2" in
    inspect) d="$RS_PROC/$3"; [[ -d "$d" ]] && kill -0 "$3" 2>/dev/null && printf 'alive=1\ntty=%s\nexe=%s\ncwd=%s\ncomm=%s\n' \
               "$(readlink "$d/fd/0")" "$(basename "$(readlink "$d/exe")")" "$(readlink "$d/cwd")" "$(cat "$d/comm")" ;;
    sharers) for d in "$RS_PROC"/[0-9]*; do [[ "$(readlink "$d/fd/0")" == "$3" ]] && echo "${d##*/} $(cat "$d/comm")"; done ;;
  esac
else echo "$*" >> "$0.calls"; fi
exit 0
EOF
    chmod +x "$1"
}

# s_wsl_stub <path> — RS_INJECT for RS_WSL=1 with the default probe/injector paths: answers the probe
# from the fixture /proc and logs each root call in order to $S_SEQ ("probe <verb>" / "inject <args>").
# The "session" keeps an input box ($S_BOX): a --clear empties it, a text joins it, an Enter alone
# records a non-empty box as a user prompt in $S_TR — unless S_NOREC=1 (the Enter is lost).
s_wsl_stub() {
    cat > "$1" << 'EOF'
#!/usr/bin/env bash
if [[ "${1##*/}" == tty-probe.py ]]; then
  echo "probe $2" >> "$S_SEQ"; d="$RS_PROC/$3"
  case "$2" in
    inspect) [[ -d "$d" ]] && kill -0 "$3" 2>/dev/null && printf 'alive=1\ntty=%s\nexe=%s\ncwd=%s\ncomm=%s\n' \
               "$(readlink "$d/fd/0")" "$(basename "$(readlink "$d/exe")")" "$(readlink "$d/cwd")" "$(cat "$d/comm")" ;;
    sharers) for d in "$RS_PROC"/[0-9]*; do [[ "$(readlink "$d/fd/0")" == "$3" ]] && echo "${d##*/} $(cat "$d/comm")"; done ;;
  esac
  exit 0
fi
shift; echo "inject $*" >> "$S_SEQ"; pos=(); clear=0
while (( $# )); do case "$1" in --expect-pid) shift ;; --clear) clear=1; shift ;; --no-cr) ;; *) pos+=("$1") ;; esac; shift; done
if (( clear )); then : > "$S_BOX"
elif (( ${#pos[@]} > 1 )); then printf '%s' "${pos[1]}" >> "$S_BOX"
elif [[ -s "$S_BOX" ]]; then
  [[ -n "${S_NOREC:-}" ]] || python3 -c 'import json,sys;print(json.dumps({"type":"user","message":{"role":"user","content":open(sys.argv[1]).read()}}))' "$S_BOX" >> "$S_TR"
  : > "$S_BOX"
fi
exit 0
EOF
    chmod +x "$1"
}

# s_guard_gaps <seq> — for each dialog-guard read ("guard") in a s_wsl_stub sequence log, the root
# probes made before the next injection: one line per guard read that was followed by a key,
# "<probes>". 0 everywhere = every key went in right after its guard read (CFG-1006 review, finding 3).
s_guard_gaps() {
    awk '/^guard/ { g = 1; n = 0; next } /^probe/ { if (g) n++; next } /^inject/ { if (g) print n; g = 0 }' "$1"
}

# ── transcripts: real CC JSONL shapes ─────────────────────────────────────────
t_text()   { printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":%s}]}}\n' \
                 "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")" >> "$1"; }
t_tool()   { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}\n' >> "$1"; }
t_result() { printf '{"type":"user","message":{"content":[{"type":"tool_result","content":%s}]}}\n' \
                 "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")" >> "$1"; }
t_end()    { printf '{"type":"system","subtype":"turn_duration","durationMs":1000}\n' >> "$1"; }
t_size()   { stat -c %s "$1" 2>/dev/null || echo 0; }
t_json()   { python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1"; }
t_user()   { printf '{"type":"user","message":{"role":"user","content":%s}}\n' "$(t_json "$2")" >> "$1"; }
t_blocks() { printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":%s}]}}\n' "$(t_json "$2")" >> "$1"; }
t_meta()   { printf '{"type":"user","isMeta":true,"message":{"role":"user","content":%s}}\n' "$(t_json "$2")" >> "$1"; }
t_queued() { printf '{"type":"queue-operation","operation":"enqueue","content":%s}\n' "$(t_json "$2")" >> "$1"; }
t_qop()    { printf '{"type":"queue-operation","operation":"%s","content":%s}\n' "$2" "$(t_json "$3")" >> "$1"; }

# ── rs_submit_line with the keystrokes stubbed (Layer A) ──────────────────────
# s_submit <text> — rs_submit_line into the fixture session S_PID: each key burst is logged to S_KEYS
# ("clear" / "text:<t>" / "enter"); the S_ON-th Enter makes the session record the prompt in its
# transcript S_TR (created then, like a new CC session's first prompt) — as an enqueue with S_QUEUE=1,
# prefixed by S_MERGE (what sat in the input box). S_DIALOG_ON_TYPE=1: a dialog comes up while the text
# is typed; S_DIALOG_ON_CLEAR=<n>: one comes up during the n-th clear (after any check made before it).
# S_TYPE_RC / S_ENTER_RC: rs_type_text's / rs_press_enter's rc; S_CLEAR_FAIL_ON=<n>: the n-th
# clear fails; S_LATE_ON_CLEAR=<n>: the prompt lands in the transcript at the n-th clear (a late Enter).
# Echoes "<rc> <Enter presses>"; RS_SUBMIT_STATE goes to $TEST_TMPDIR/state, stderr to $TEST_TMPDIR/err.
s_setup() {
    a_setup; export RS_POLL=0.1 RS_KEY_GAP=0 RS_SUBMIT_WAIT=1 RS_DIALOG_WAIT=1 RS_SUBMIT_FIRST_WAIT=2
    S_PID=$(a_spawn claude /dev/pts/40 /home/user/x claude)
    mkdir -p "$CC/projects/-x"; S_TR="$CC/projects/-x/sid-$S_PID.jsonl"; S_KEYS="$TEST_TMPDIR/keys"; : > "$S_KEYS"
}
s_record() { if [[ -n "${S_QUEUE:-}" ]]; then t_queued "$S_TR" "${S_MERGE:-}$1"; else t_user "$S_TR" "${S_MERGE:-}$1"; fi; }
s_submit() {
    ( rs_clear_input() { echo clear >> "$S_KEYS"; local n; n=$(grep -c '^clear$' "$S_KEYS")
          [[ "$n" == "${S_LATE_ON_CLEAR:-0}" ]] && t_user "$S_TR" "$S_TEXT"
          [[ "$n" == "${S_DIALOG_ON_CLEAR:-0}" ]] && s_status waiting
          [[ "$n" == "${S_CLEAR_FAIL_ON:-0}" ]] && return 3; return 0; }
      rs_type_text()   { echo "text:$2" >> "$S_KEYS"; [[ -n "${S_DIALOG_ON_TYPE:-}" ]] && s_status waiting; return "${S_TYPE_RC:-0}"; }
      rs_press_enter() { echo enter >> "$S_KEYS"
          [[ "$(grep -c '^enter$' "$S_KEYS")" == "${S_ON:-0}" ]] && s_record "$S_TEXT"; return "${S_ENTER_RC:-0}"; }
      S_TEXT="$1"; rs_submit_line "$S_PID" "$1" 2>"$TEST_TMPDIR/err"; echo "$? $RS_SUBMIT_TRIES"
      echo "${RS_SUBMIT_STATE:-}" > "$TEST_TMPDIR/state" )
}
s_status()   { printf '{"pid":%s,"sessionId":"sid-%s","status":"%s"}\n' "$S_PID" "$S_PID" "$1" > "$CC/sessions/$S_PID.json"; }
s_keys()     { paste -sd'|' "$S_KEYS"; }
s_teardown() { unset RS_POLL RS_KEY_GAP RS_SUBMIT_WAIT RS_DIALOG_WAIT RS_SUBMIT_FIRST_WAIT; a_teardown; }

# ── relaunch / start (Layer A) ────────────────────────────────────────────────
# RS_LAUNCH plays the new terminal: R_SPAWN=1 starts a fake claude in the given dir whose
# CLAUDE_CONFIG_DIR is a separate profile dir (an --account session records itself there, not in
# RS_CC_DIR), with record status R_STATUS (default idle). R_NOREC=1: it writes NO session record, as
# Claude Code does while a startup dialog is up (CFG-1022); R_SCREEN=<file>: it runs under a fake
# script(1) parent whose log is <file> — what rs_screen_text reads for an af session; R_PTS: its tty
# (default /dev/pts/41 — two fakes on one pts trip the tty-sharer guard, as they should).
r_setup() {
    a_setup
    export RS_POLL=0.1 R_BIN="$BIN" R_LOG="$TEST_TMPDIR/launch.log" R_NEW="$TEST_TMPDIR/newpid" R_TYPED="$TEST_TMPDIR/typed"
    export R_PROFILE="$TEST_TMPDIR/profile" RS_REGISTRY="$TEST_TMPDIR/registry.md" RS_ACCOUNT_CHECK="$TEST_TMPDIR/acct" RS_LAUNCH="$TEST_TMPDIR/launch"
    export R_SUBMITTED="$TEST_TMPDIR/submitted" R_CLEARED="$TEST_TMPDIR/cleared" RS_KEY_GAP=0
    rm -rf "$R_PROFILE"; rm -f "$R_LOG" "$R_NEW" "$R_NEW.extra" "$R_SUBMITTED" "$R_CLEARED" "$R_TYPED.box"   # a second r_setup in one test starts clean
    printf '| Project | Pri | Parent | Path |\n|---|---|---|---|\n| demo-app | P2 | — | `/home/user/demo` |\n' > "$RS_REGISTRY"
    printf '#!/usr/bin/env bash\ncase "$1" in ultra|max) echo "num=1 email=x alias=$1";; *) echo "num= email= alias=";; esac\n' > "$RS_ACCOUNT_CHECK"
    cat > "$RS_LAUNCH" << 'EOF'
#!/usr/bin/env bash
echo "$1|$2" >> "$R_LOG"
[[ "${R_SPAWN:-}" == 1 ]] || exit 0
s=1
if [[ -n "${R_SCREEN:-}" ]]; then
  sleep 300 >/dev/null 2>&1 </dev/null & s=$!; mkdir -p "$RS_PROC/$s"; echo "$s" >> "$R_NEW.extra"
  echo script > "$RS_PROC/$s/comm"; echo "$s (script) S 1 0 0" > "$RS_PROC/$s/stat"
  printf 'script\0-q\0-f\0-c\0af\0%s\0' "$R_SCREEN" > "$RS_PROC/$s/cmdline"
fi
sleep 300 >/dev/null 2>&1 </dev/null & p=$!; d="$RS_PROC/$p"; mkdir -p "$d/fd" "$R_PROFILE/sessions"
echo claude > "$d/comm"; echo "$p (claude) S $s 0 0" > "$d/stat"
ln -s "${R_PTS:-/dev/pts/41}" "$d/fd/0"; ln -s "$R_BIN/claude" "$d/exe"; ln -s "$1" "$d/cwd"
printf '%s\0' "$R_BIN/claude" > "$d/cmdline"; printf 'PWD=%s\0CLAUDE_CONFIG_DIR=%s\0' "$1" "$R_PROFILE" > "$d/environ"
[[ -n "${R_NOREC:-}" ]] || printf '{"pid":%s,"sessionId":"sid-new","cwd":"%s","status":"%s"}\n' "$p" "$1" "${R_STATUS:-idle}" > "$R_PROFILE/sessions/$p.json"
echo "$p" > "$R_NEW"
EOF
    chmod +x "$RS_LAUNCH" "$RS_ACCOUNT_CHECK"; : > "$R_TYPED"
}
r_old() {  # [dir] → pid of a session there (default /home/user/demo), with a transcript (end-exit needs one, CFG-1001)
    local dir="${1:-/home/user/demo}" p; p=$(a_spawn claude /dev/pts/40 "$dir" claude)
    printf '%s\0' "$BIN/claude" > "$PROC/$p/cmdline"; printf 'PWD=%s\0' "$dir" > "$PROC/$p/environ"
    mkdir -p "$CC/projects/-p"; : > "$CC/projects/-p/sid-$p.jsonl"
    echo "$p"
}
# r_run <args> — main in a sourced subshell: every typed or submitted line is logged to R_TYPED as
# "<pid> <text>" (submitted ones also to R_SUBMITTED, input-line clears to R_CLEARED); a line goes in as
# its text (rs_type_text) and then a separate Enter (rs_press_enter) — the Enter of /exit kills its pid;
# rs_type_line (text + Enter in one burst) is NOT stubbed, so a caller that still used it fails here.
# R_END_FAIL=1 → no "Shutdown complete"; R_SUBMIT_RC=<n> → rs_submit_line fails with <n>;
# R_DIALOG_AFTER=<line> → entering that line brings up a dialog (the session's record turns "waiting");
# R_CLEAR_REC=<record file> → entering /clear starts a fresh session there (new sessionId, status idle).
# The typing gate (CFG-1028): a run here is the user's order — `--ordered` is appended, so the mechanics under test
# are reached outside a care shift; R_GATE=1 leaves it off (test-remote-session-gate.sh tests the gate itself).
# R_START_PID=<pid> → the shell that "launched" the script (rs_caller_pid walks up from it; default 1: no claude).
r_run() {
    ( source "$RS"
      local gate=(); [[ -n "${R_GATE:-}" ]] || gate=(--ordered "fixture: the user's order (R_GATE=1 tests the gate)")
      rs_clear_input() { echo "$1 clear" >> "$R_CLEARED"; return 0; }
      rs_type_text() { echo "$1 $2" >> "$R_TYPED"; printf '%s' "$2" > "$R_TYPED.box"; return 0; }
      rs_press_enter() { local l; l=$(cat "$R_TYPED.box" 2>/dev/null); : > "$R_TYPED.box"
          [[ "$l" == /exit ]] && kill "$1" 2>/dev/null
          [[ "$l" == /clear && -n "${R_CLEAR_REC:-}" ]] && python3 -c 'import json,sys
d = json.load(open(sys.argv[1])); d.update(sessionId="sid-cleared", status="idle"); json.dump(d, open(sys.argv[1], "w"))' "$R_CLEAR_REC"
          [[ -n "$l" && "$l" == "${R_DIALOG_AFTER:-}" ]] && r_status "$1" waiting; return 0; }
      rs_submit_line() { echo "$1 $2" >> "$R_TYPED"; echo "$1 $2" >> "$R_SUBMITTED"
          RS_SUBMIT_TRIES=3; RS_REASON="typed but NOT submitted into pid $1 (stub)"; return "${R_SUBMIT_RC:-0}"; }
      rs_wait_shutdown() { [[ -z "${R_END_FAIL:-}" ]]; }
      RS_START_PID="${R_START_PID:-1}" main "$@" "${gate[@]}" )
}
# r_status <pid> <status> — rewrite the fixture session record of <pid> (RS_CC_DIR) with that status
r_status() {
    local f="$CC/sessions/$1.json"
    python3 -c 'import json,sys
d = json.load(open(sys.argv[1])); d["status"] = sys.argv[2]; json.dump(d, open(sys.argv[1], "w"))' "$f" "$2"
}
r_teardown() {
    [[ -s "$R_NEW" ]] && kill "$(cat "$R_NEW")" 2>/dev/null
    [[ -s "$R_NEW.extra" ]] && kill $(cat "$R_NEW.extra") 2>/dev/null
    local p; for p in "$@"; do kill "$p" 2>/dev/null; done
    unset RS_POLL R_BIN R_LOG R_NEW R_TYPED R_PROFILE RS_REGISTRY RS_ACCOUNT_CHECK RS_LAUNCH R_SPAWN R_STATUS R_END_FAIL
    unset R_SUBMITTED R_SUBMIT_RC R_CLEARED R_DIALOG_AFTER RS_KEY_GAP R_NOREC R_SCREEN R_GATE R_START_PID
    a_teardown
}

# ── Claude Code dialogs as af's script(1) log records them (CC 2.1.280, measured 2026-11-14) ──────────────
# The space between two words is a cursor move (ESC[<n>G), not a space, and lines end \r\r\n — so a plain grep
# for "one you trust" finds nothing in a real log. d_* print such screens for rs_screen_dialog.
d_words() { local col=2 w out=""; for w in "$@"; do out+=$'\e['"${col}G$w"; col=$(( col + ${#w} + 1 )); done; printf '%s\r\r\n' "$out"; }
d_guide() { d_words Enter to confirm · Esc to cancel; }
d_trust() {
    printf '\e[2G\e[38;2;255;193;7m\e[1mAccessing\e[12Gworkspace:\e[22m\e[39m\r\r\n'; d_words /home/user/proj
    d_words Quick safety check: Is this a project you created or one you "trust?" "(Like" your own code,
    printf '\e[2G\e]8;id=zx;https://code.claude.com/docs/en/security\e\\Security guide\e]8;;\e\\\r\r\n'
    d_words ❯ No, exit; d_words Yes, I trust this folder; d_guide
}
d_imports() {
    d_words Allow external CLAUDE.md file "imports?"; d_words "This project's" CLAUDE.md imports files outside the working directory.
    d_words External imports:; d_words /home/user/.claude/foundation/user-profile.md
    d_words ❯ No, disable external imports; d_words Yes, allow external imports; d_guide
}
d_mcp()      { d_words New MCP server found in this project: github; d_words ❯ Use this MCP server; d_guide; }
d_mcp_many() { d_words 3 new MCP servers found in this project; d_words Select any you wish to enable.; d_guide; }
d_selector() { d_words Choose the text style that looks best with your terminal; d_words ❯ 1. Dark mode; d_guide; }
d_prompt()   { d_words Claude Code v2.1.280; d_words ❯ startup; d_words "?" for shortcuts; }
# d_repl: what 2.1.280 draws once a startup dialog is answered (banner, prompt box, mode line) — real log, 2026-11-14.
d_repl() {
    d_words ▐▛███▜▌ Claude Code v2.1.280; d_words ▝▜█████▛▘ Opus 5.5 "(1M" "context)" with xhigh effort · Claude Max
    d_words ~/project; d_words ────────────────────────; d_words ❯; d_words ⏵⏵ auto mode on "(shift+tab" to "cycle)"
}
d_trust_redraw() { d_words No, exit; d_words ❯ Yes, I trust this folder; }   # a human moved the selection
d_filler()   { local i; for (( i = 0; i < $1; i++ )); do d_words lorem ipsum dolor sit amet consectetur; done; }

# ── N: the shipped layer without the care machinery ───────────────────────────
# n_stage_layer — copy the layer that ships to every fleet (the remote-session libs, the shutdown-follow
# watcher, the injector and the probe) into $TEST_TMPDIR/nolib/setup/scripts/ with NO global/hooks/ beside
# it. Sourced from there, with HOME sandboxed, the libs find no lib-care.sh — neither at
# "$RS_LIB_DIR/../../global/hooks/" nor at "$HOME/.claude/hooks/" — and read the care line by themselves:
# the path a deployment without session caretaking runs. Sets N_LIB and N_WATCHER.
n_stage_layer() {
    local d="$TEST_TMPDIR/nolib/setup/scripts" f
    mkdir -p "$d"
    for f in remote-session-lib.sh remote-session-gate-lib.sh remote-session-follow-lib.sh \
             remote-session-submit-lib.sh shutdown-follow.sh tty-inject.py tty-probe.py; do
        cp "$REPO_ROOT/setup/scripts/$f" "$d/$f"
    done
    N_LIB="$d/remote-session-lib.sh" N_WATCHER="$d/shutdown-follow.sh"
}
# n_run_if "<name>" <fn> <file>... — run_test when every <file> exists here, else skip_test naming the
# first missing one (the driver, remote-exit.sh, swap.sh and lib-care.sh are not part of every deployment)
n_run_if() {
    local name="$1" fn="$2" f; shift 2
    for f in "$@"; do
        [[ -f "$f" ]] || { skip_test "$name" "${f##*/} is not shipped here (personal-only); nothing to drive"; return 0; }
    done
    run_test "$name" "$fn"
}

# ── Layer B: real ptys + root injector ────────────────────────────────────────
HAVE_ROOT=0; ROOT_WHY="not WSL (no wsl.exe -u root path)"
if rs_is_wsl 2>/dev/null || [[ -e /proc/sys/fs/binfmt_misc/WSLInterop || -n "${WSL_DISTRO_NAME:-}" ]]; then
    if env -C /mnt/c wsl.exe -u root -e true >/dev/null 2>&1; then HAVE_ROOT=1
    else ROOT_WHY="wsl.exe -u root not reachable"; fi
fi
ROOT_INJECT="env -C /mnt/c wsl.exe -u root -e python3"

BPIDS=()
# b_fake_write <dir> — <dir>/claude (a bash copy), <dir>/fake.sh (the fake session it runs) and
# <dir>/keys.py (its keyboard, a child of the fake, so it is no stranger on the tty):
#   fake.sh <recv>   writes $CC_DIR/sessions/$$.json and its transcript
#   $CC_DIR/projects/-fake/<sessionId>.jsonl (FAKE_LAZY_TR=1: not created until the first prompt, as
#   for a brand-new CC session), and acts on every prompt keys.py submits.
#   keys.py <recv>   reads the pty RAW and tokenizes each read as Claude Code 2.1.280 does (bin/claude.exe
#   offset 191421218, `a<32&&(u.length<64||a===BS)`): a control byte is a key of its own ONLY in a read
#   of fewer than 64 bytes; a read of 64+ bytes is ONE text token whose control bytes do not act (the
#   fake drops them). It reads FAKE_SETTLE (0.02) s after input arrives, so a burst written within that
#   window is one read — as a busy CC reads it. The INPUT BOX: text joins it (text left there by a
#   swallowed Enter merges with what is typed next), Ctrl+U empties it, Ctrl+K and other keys edit
#   nothing, and Enter (CR) logs the text typed since the last Enter to <recv> and submits a non-empty
#   box: a user record in the transcript (CFG-1006). <recv>.swallow: the first prompt's Enter is eaten
#   (the next Enter submits it); <recv>.stuck: every Enter is eaten while the file exists (the box keeps
#   its text); <recv>.nosubmit: nothing is ever submitted.
b_fake_write() {
    local dir="$1"; mkdir -p "$dir"
    cp /bin/bash "$dir/claude"
    b_keys_write "$dir/keys.py"
    cat > "$dir/fake.sh" <<'FAKE'
out="$1"
json="${CC_DIR:+$CC_DIR/sessions/$$.json}"
[[ -n "$json" ]] && printf '{"pid":%s,"sessionId":"sid-init","status":"idle"}\n' "$$" > "$json"
newsid() { python3 - "$json" <<'PY'
import json,sys,uuid
p=sys.argv[1]
try: d=json.load(open(p))
except Exception: d={}
d["sessionId"]="sid-"+uuid.uuid4().hex[:8]; d["status"]="idle"
json.dump(d,open(p,"w"))
PY
}
# transcript of the CURRENT session id (CFG-1001: completion is read from it, not the screen)
tr_path() { [[ -n "$json" ]] || return 1; mkdir -p "$CC_DIR/projects/-fake"
  echo "$CC_DIR/projects/-fake/$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sessionId"])' "$json").jsonl"; }
done_turn() { local t; t=$(tr_path) || return 0
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Shutdown complete. Next: %s"}]}}\n{"type":"system","subtype":"turn_duration"}\n' "$1" >> "$t"; }
user_msg() { local t; t=$(tr_path) || return 0
  python3 -c 'import json,sys;print(json.dumps({"type":"user","message":{"role":"user","content":sys.argv[1]}}))' "$1" >> "$t"; }
[[ -n "${FAKE_LAZY_TR:-}" ]] || { t0=$(tr_path) && : > "$t0"; }
while IFS= read -r -u 3 line; do   # one line per prompt keys.py submitted (on fd 3: fd 0 stays the pty)
  user_msg "$line"
  case "$line" in
    end)     [[ -f "$out.ignore" ]] || { echo "Shutdown complete. Next: /exit"; done_turn /exit; } ;;
    cls)     [[ -f "$out.ignore" ]] || { echo "Shutdown complete. Next: /clear"; done_turn /clear; } ;;
    /clear)  echo "__SESSIONSTART__ fresh"; [[ -n "$json" ]] && newsid ;;
    startup) echo "__STARTUP__ running" ;;
    /exit)   echo "__EXIT__"; exit 0 ;;
  esac
done 3< <(python3 "${0%/*}/keys.py" "$out")
FAKE
}

# b_keys_write <path> — the fake session's keyboard (see b_fake_write): raw reads, CC's 64-byte rule.
b_keys_write() {
    cat > "$1" <<'KEYS'
import os, select, sys, termios, time
out, settle = sys.argv[1], float(os.environ.get("FAKE_SETTLE", "0.02"))
a = termios.tcgetattr(0)
a[0] &= ~(termios.ICRNL | termios.INLCR | termios.IGNCR | termios.IXON)
a[3] &= ~(termios.ICANON | termios.ECHO | termios.ISIG | termios.IEXTEN)
a[6][termios.VMIN], a[6][termios.VTIME] = 1, 0
termios.tcsetattr(0, termios.TCSANOW, a)
open(out + ".ready", "w").close()
def tokens(chunk):   # CC 2.1.280: control bytes act only in a read of < 64 bytes
    if len(chunk) >= 64: return [("text", chunk)]
    toks, run = [], b""
    for b in chunk:
        if b < 32:
            if run: toks.append(("text", run)); run = b""
            toks.append(("key", b))
        else: run += bytes([b])
    return toks + ([("text", run)] if run else [])
box = seen = ""
def enter():
    global box, seen
    with open(out, "a") as f: f.write(seen + "\n")
    line, box, seen = box, "", ""
    if not line: return
    if os.path.exists(out + ".swallow"): os.remove(out + ".swallow"); box = line; return
    if os.path.exists(out + ".stuck"): box = line; return
    if os.path.exists(out + ".nosubmit"): return
    print(line, flush=True)
while True:
    try:
        select.select([0], [], []); time.sleep(settle); chunk = os.read(0, 65536)
        if not chunk: break
        for kind, v in tokens(chunk):
            if kind == "text":
                t = bytes(b for b in v if b >= 32 and b != 127).decode("utf-8", "replace"); box += t; seen += t
            elif v == 0x15: box = ""
            elif v == 0x0D: enter()
    except (OSError, BrokenPipeError): break
KEYS
}

# b_spawn <name> <cc-dir> — a fake claude reading its own pts under script(1).
# Sets B_CLA / B_LOG / B_RECV / B_TTY. Records pids for teardown.
b_spawn() {
    local name="$1" cc="$2"; local dir="$TEST_TMPDIR/$name"
    mkdir -p "$dir/sessions"
    b_fake_write "$dir"
    local recv="$dir/recv.txt" log="$dir/session.log" fifo="$dir/fifo"
    mkfifo "$fifo"
    CC_DIR="$cc" setsid bash -c "exec script -q -f -e -c '$dir/claude $dir/fake.sh $recv' '$log'" <>"$fifo" >/dev/null 2>&1 &
    BPIDS+=("$!")
    local i; for i in $(seq 1 80); do [[ -f "$recv.ready" ]] && break; sleep 0.1; done
    local p=""
    for pp in "$cc"/sessions/*.json; do [[ -f "$pp" ]] || continue; local cand; cand=$(basename "$pp" .json)
        [[ "$(basename "$(readlink /proc/$cand/exe 2>/dev/null)" 2>/dev/null)" == claude ]] \
            && grep -qa "$dir/fake.sh" "/proc/$cand/cmdline" 2>/dev/null && { p="$cand"; break; }
    done
    B_CLA="$p"; B_LOG="$log"; B_RECV="$recv"; B_TTY=$(readlink "/proc/$p/fd/0" 2>/dev/null)
    BPIDS+=("$p")
}
b_teardown() { local p; for p in "${BPIDS[@]}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
    for p in "${BPIDS[@]}"; do [[ -n "$p" ]] && wait "$p" 2>/dev/null || true; done; BPIDS=(); }

b_env() { echo "RS_WSL=1 RS_CC_DIR=$1 RS_QDBUS=/bin/true RS_POLL=0.3 RS_INJECT=$ROOT_INJECT RS_START_PID=1"; }
B_RS_ENV=(RS_PROC=/proc RS_WSL=1 RS_QDBUS=/bin/true RS_TMUX=/bin/false RS_POLL=0.3 "RS_INJECT=$ROOT_INJECT"
          RS_START_PID=1 RS_SUBMIT_WAIT=2)
b_prompts() {  # <transcript> <text> — how many user records carry exactly that text
    python3 -c 'import json,sys
n = 0
try:
    for l in open(sys.argv[1]):
        d = json.loads(l)
        if d.get("type") == "user" and (d.get("message") or {}).get("content") == sys.argv[2]: n += 1
except OSError: pass
print(n)' "$1" "$2"
}
b_prompts_holding() {  # <transcript> <text> — how many user records CONTAIN that text
    python3 -c 'import json,sys
n = 0
try:
    for l in open(sys.argv[1]):
        d = json.loads(l); c = (d.get("message") or {}).get("content")
        if d.get("type") == "user" and isinstance(c, str) and sys.argv[2] in c: n += 1
except OSError: pass
print(n)' "$1" "$2"
}
