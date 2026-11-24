#!/usr/bin/env bash
# remote-session-lib.sh — resolve, guard and drive ONE other Claude Code session (CFG-878).
#
# Sourced by remote-session.sh (the standalone driver) and by remote-poweroff.sh (for its
# WSL input path). All functions are rs_-prefixed and side-effect free except the injectors.
# Input reaches the target three ways, tried in this order per call:
#   1. its tmux pane   (TMUX_PANE in the target's environ) — unchanged from remote-poweroff
#   2. its Konsole tab (KDE D-Bus)                          — unchanged from remote-poweroff
#   3. WSL: its own /dev/pts/<n>, via tty-inject.py run as root (wsl.exe -u root), because
#      `af` wraps claude in script(1) in a Windows Terminal tab — no pane, no Konsole tab.
# Screen reads mirror the same three: tmux capture-pane / Konsole getAllDisplayedText / the
# session's script(1) log (every byte the session printed). The caller NEVER signals a
# claude; a session ends only by `/exit` typed into it. A PROMPT (an order, `startup`) goes in
# through rs_submit_line (remote-session-submit-lib.sh, sourced at the end), which clears the input
# line, types the text and the Enter separately and confirms from the session's transcript that it
# was submitted (CFG-1006).
#
# Session records: each claude records itself in ITS OWN config dir (CLAUDE_CONFIG_DIR in its environ: the mclaude
# mirror, or an `af --account` claude-swap profile), so every record, status and transcript of a target is read from
# that dir; RS_CC_DIR (the caller's) is the fallback and the one dir whose records are listed (CFG-1032).
#
# Typing into ANOTHER session passes the typing gate first (CFG-1028, remote-session-gate-lib.sh, called from
# rs_safety_check): an active care shift typed by the caretaker, or the user's words passed as --ordered; a
# session typing into itself is exempt.
#
# Overridable for tests (never in production): RS_PROC, RS_CC_DIR, RS_WSL (1/0 force),
# RS_INJECT (the root-exec prefix before the injector path), RS_TMUX, RS_QDBUS, RS_KEY_GAP,
# RS_SUBMIT_WAIT, RS_DIALOG_GRACE, RS_DIALOG_SPAN; RS_CLEAR_PRESSES, RS_CLEAR_BATCH, RS_CLEAR_GAP,
# RS_DIALOG_WAIT (the submit lib); RS_GATE_LOG, RS_GATE_WHAT, CARE_FILE (the gate lib).

RS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RS_PROC="${RS_PROC:-/proc}"
RS_CC_DIR="${RS_CC_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
RS_INJECTOR="${RS_INJECTOR:-$RS_LIB_DIR/tty-inject.py}"
RS_PROBE="${RS_PROBE:-$RS_LIB_DIR/tty-probe.py}"
RS_INJECT="${RS_INJECT:-env -C /mnt/c wsl.exe -u root -e python3}"
RS_TMUX="${RS_TMUX:-tmux}"
RS_BG_PATTERN="${RS_BG_PATTERN:-Background work is running}"
RS_POLL="${RS_POLL:-2}"
RS_KEY_GAP="${RS_KEY_GAP:-1}"          # seconds between a prompt's text and its Enter (CFG-1006)
RS_SUBMIT_WAIT="${RS_SUBMIT_WAIT:-8}"  # seconds to wait for the transcript after each Enter
if [[ -n "${RS_QDBUS:-}" ]]; then RS_QDBUS="$RS_QDBUS"
elif command -v qdbus >/dev/null 2>&1; then RS_QDBUS=qdbus
else RS_QDBUS=/usr/lib64/qt6/bin/qdbus; fi
RS_CLAUDE_EXES=("claude" "claude.exe")
RS_REASON=""           # last refusal reason, set by rs_resolve / rs_safety_check
RS_RESOLVED=""         # the pid rs_resolve resolved (also on its stdout)
RS_BG_DIALOG=0         # set by rs_wait_gone when CC's background-work selector appeared

# ── /proc primitives ─────────────────────────────────────────────────────────
# /proc/<pid>/{stat,comm,cmdline} are world-readable even for another session, so ppid/comm
# and the ancestry walks work unprivileged. But fd/0, exe and cwd are ptrace-gated: under
# yama ptrace_scope=1 a process that is NOT an ancestor of the target (one project's session
# reaching another's, say) cannot read them. rs_inspect reads those through the root probe on
# WSL (CFG-878).
rs_ppid()  { local s; s=$(cat "$RS_PROC/$1/stat" 2>/dev/null) || return 1; s="${s##*) }"; set -- $s; echo "$2"; }
rs_comm()  { cat "$RS_PROC/$1/comm" 2>/dev/null; }
rs_alive() { kill -0 "$1" 2>/dev/null; }

rs_is_wsl() {
    case "${RS_WSL:-}" in 1) return 0 ;; 0) return 1 ;; esac
    [[ -e /proc/sys/fs/binfmt_misc/WSLInterop || -n "${WSL_DISTRO_NAME:-}" ]]
}

# rs_inspect <pid> — echo "tty|exe|cwd|comm|alive". On WSL via the root probe (so a
# non-ancestor target is readable); off WSL by direct readlink (fixtures, ancestor targets).
rs_inspect() {
    local pid="$1" tty="" exe="" cwd="" comm="" alive=0 out e
    if rs_is_wsl; then
        out=$($RS_INJECT "$RS_PROBE" inspect "$pid" 2>/dev/null)
        alive=$(sed -n 's/^alive=//p' <<<"$out"); [[ -z "$alive" ]] && alive=0
        tty=$(sed -n 's/^tty=//p' <<<"$out"); exe=$(sed -n 's/^exe=//p' <<<"$out")
        cwd=$(sed -n 's/^cwd=//p' <<<"$out"); comm=$(sed -n 's/^comm=//p' <<<"$out")
    else
        rs_alive "$pid" && alive=1
        tty=$(readlink "$RS_PROC/$pid/fd/0" 2>/dev/null)
        e=$(readlink "$RS_PROC/$pid/exe" 2>/dev/null); e="${e% (deleted)}"; [[ -n "$e" ]] && exe=$(basename "$e")
        cwd=$(readlink "$RS_PROC/$pid/cwd" 2>/dev/null); comm=$(rs_comm "$pid")
    fi
    printf '%s|%s|%s|%s|%s' "$tty" "$exe" "$cwd" "$comm" "$alive"
}

rs_tty()      { local r; r=$(rs_inspect "$1"); IFS='|' read -r r _ <<<"$r"; echo "$r"; }
rs_exe_base() { local r; r=$(rs_inspect "$1"); IFS='|' read -r _ r _ <<<"$r"; echo "$r"; }
rs_cwd()      { local r t e c; r=$(rs_inspect "$1"); IFS='|' read -r t e c _ <<<"$r"; echo "$c"; }
rs_is_claude() {
    local b; b=$(rs_exe_base "$1")
    local x; for x in "${RS_CLAUDE_EXES[@]}"; do [[ "$b" == "$x" ]] && return 0; done
    return 1
}

# rs_tty_sharers <tty> — "<pid> <comm>" per process whose fd 0 is <tty> (root probe on WSL,
# so another session's fd table is visible; direct /proc scan off WSL).
rs_tty_sharers() {
    local tty="$1" q
    if rs_is_wsl; then
        $RS_INJECT "$RS_PROBE" sharers "$tty" 2>/dev/null
    else
        for q in "$RS_PROC"/[0-9]*; do
            [[ "$(readlink "$q/fd/0" 2>/dev/null)" == "$tty" ]] && echo "${q##*/} $(rs_comm "${q##*/}")"
        done
    fi
}

# rs_ancestors <pid> — " pid ppid ... " up to init
rs_ancestors() {
    local p="$1" out=" " i
    for i in $(seq 1 32); do
        [[ -z "$p" || "$p" -le 1 ]] && break
        out+="$p "; p=$(rs_ppid "$p") || break
    done
    echo "$out"
}

# rs_descendants <pid> — " pid child grandchild ... " (the subtree rooted at pid)
rs_descendants() {
    local root="$1" set=" $1 " changed=1 d pid pp
    while (( changed )); do
        changed=0
        for d in "$RS_PROC"/[0-9]*; do
            pid="${d#$RS_PROC/}"; [[ "$set" == *" $pid "* ]] && continue
            pp=$(rs_ppid "$pid") || continue
            if [[ "$set" == *" $pp "* ]]; then set+="$pid "; changed=1; fi
        done
    done
    echo "$set"
}

# rs_script_log <pid> — the script(1) log of the session: walk ancestors to the nearest
# `script` process, echo the last argument of its cmdline (the log path). Return 1 if none.
rs_script_log() {
    local p i last
    for p in $(rs_ancestors "$1"); do
        [[ "$(rs_comm "$p")" == script ]] || continue
        last=""
        while IFS= read -r -d '' a; do last="$a"; done < "$RS_PROC/$p/cmdline"
        [[ -n "$last" ]] && { echo "$last"; return 0; }
    done
    return 1
}

# ── CC session registry ──────────────────────────────────────────────────────
# A claude records itself in ITS OWN config dir (rs_cc_dir_of): the mclaude mirror's sessions in the mirror, an
# `af --account` session's in its claude-swap profile. So a pid's record is read from that dir, never the caller's.
rs_session_field() {  # <pid> <field> [config-dir, default: the pid's own, rs_cc_dir_of]
    python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception: pass' "${3:-$(rs_cc_dir_of "$1")}/sessions/$1.json" "$2" 2>/dev/null
}

# rs_record_current <pid> — 0 when the record in its own config dir is THIS process's and interactive (care-watch.sh's
# rule): a procStart that is not the pid's start time belongs to an earlier process with that pid; a non-interactive
# kind (bg) has no terminal to type into.
rs_record_current() {
    local js="" ps st=() s
    { IFS= read -r -d '' js < "$(rs_cc_dir_of "$1")/sessions/$1.json"; } 2>/dev/null
    [[ -n "$js" ]] || return 1
    [[ "$js" =~ \"kind\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" && "${BASH_REMATCH[1]}" != interactive ]] && return 1
    [[ "$js" =~ \"procStart\"[[:space:]]*:[[:space:]]*\"?([0-9]+) ]] || return 0
    ps="${BASH_REMATCH[1]}"; s=$(cat "$RS_PROC/$1/stat" 2>/dev/null); s="${s##*) }"; read -r -a st <<<"$s"
    [[ "${st[19]-}" == "$ps" ]]   # stat field 22: start time, what procStart holds
}

# rs_live_claudes — live pids with a current session record (rs_record_current), each once, from every config dir a
# session records itself in (CFG-1032): RS_CC_DIR's records, plus every claude (argv0) whose record sits in its own
# dir — care-watch.sh's discovery (CFG-994). Claude-ness is confirmed later by rs_safety_check (exe, read as root).
rs_live_claudes() {
    local f p d cand=" "
    for f in "$RS_CC_DIR"/sessions/*.json; do p="${f##*/}"; p="${p%.json}"; [[ "$p" =~ ^[0-9]+$ ]] && cand+="$p "; done
    for d in "$RS_PROC"/[0-9]*; do
        p="${d##*/}"; [[ "$cand" == *" $p "* ]] || ! rs_argv0_claude "$p" || cand+="$p "
    done
    for p in $cand; do rs_alive "$p" && rs_record_current "$p" && echo "$p"; done
}

# rs_resolve <project|pid> — RS_RESOLVED + stdout = the target claude pid; else RS_REASON + return 2. Call it in the
# CURRENT shell when the reason matters (inside $(...) RS_REASON is lost). A number is taken as a pid; anything else
# matches live sessions by working directory (each record's cwd, so no ptrace-gated read); 0 or >1 is refused by name.
rs_resolve() {
    local want="$1" p cwd hits=() names=()
    RS_REASON="" RS_RESOLVED=""
    if [[ "$want" =~ ^[0-9]+$ ]]; then RS_RESOLVED="$want"; echo "$want"; return 0; fi
    for p in $(rs_live_claudes); do
        cwd=$(rs_session_field "$p" cwd)
        [[ -z "$cwd" ]] && cwd=$(rs_cwd "$p")
        if [[ "$(basename "$cwd")" == "$want" || "$cwd" == "$HOME/$want" ]]; then
            hits+=("$p"); names+=("$p@$cwd")
        fi
    done
    if (( ${#hits[@]} == 0 )); then RS_REASON="no live claude session has project '$want'"; return 2; fi
    if (( ${#hits[@]} > 1 )); then
        RS_REASON="project '$want' matches ${#hits[@]} live sessions (${names[*]}) — pass a pid"; return 2
    fi
    RS_RESOLVED="${hits[0]}"; echo "${hits[0]}"
}

# rs_safety_check <pid> <caller_pid> <allow_self 0|1> [ordered words] [caretaker marker] — every refusal names its
# reason in RS_REASON and returns 3. Passes only when it is safe AND allowed to type into exactly this session:
# a session typing into ITSELF (pid == caller, allow_self) is exempt from the typing gate (Q-TYPE-SELF); any
# other target passes the gate (rs_typing_allowed, remote-session-gate-lib.sh: an active care shift typed by
# the caretaker, or the user's words) before the tty is looked at (CFG-1028).
rs_safety_check() {
    local pid="$1" caller="$2" allow_self="$3" ordered="${4:-}" marker="${5:-}"
    local tty exe cwd comm alive desc qt qcomm isclaude=0 x
    RS_REASON=""; rs_gate_arm ""   # no key into anyone until this check passes (CFG-1083 F1)
    IFS='|' read -r tty exe cwd comm alive < <(rs_inspect "$pid")
    [[ "$alive" == 1 ]] || { RS_REASON="pid $pid is not alive"; return 3; }
    for x in "${RS_CLAUDE_EXES[@]}"; do [[ "$exe" == "$x" ]] && isclaude=1; done
    (( isclaude )) || { RS_REASON="pid $pid is not a Claude Code session (exe: ${exe:-unreadable})"; return 3; }
    [[ "$tty" =~ ^/dev/pts/[0-9]+$ ]] || { RS_REASON="pid $pid has no /dev/pts tty (tty: ${tty:-none})"; return 3; }
    if [[ "$pid" == "$caller" ]]; then
        [[ "$allow_self" == 1 ]] || { RS_REASON="pid $pid is the calling session — pass --self to drive your own session"; return 3; }
    else
        rs_typing_allowed "pid $pid" "$caller" "$ordered" "$marker" || return 3
    fi
    desc=$(rs_descendants "$pid")
    while read -r qt qcomm; do
        [[ -z "$qt" || "$qt" == "$pid" ]] && continue
        [[ "$desc" == *" $qt "* ]] && continue
        RS_REASON="pid $pid shares its tty $tty with pid $qt ($qcomm) — injection would reach it too"
        return 3
    done < <(rs_tty_sharers "$tty")
    rs_gate_arm "$pid"   # the key primitives type into this pid, and into no other
    return 0
}

# rs_caller_pid — nearest claude at or above the shell that launched us (RS_START_PID/PPID)
rs_caller_pid() {
    local p="${RS_START_PID:-$PPID}" i
    for i in $(seq 1 32); do
        [[ -z "$p" || "$p" -le 1 ]] && return 1
        rs_is_claude "$p" && { echo "$p"; return 0; }
        p=$(rs_ppid "$p") || return 1
    done
    return 1
}

# ── input dispatch (tmux pane → Konsole tab → WSL inject) ─────────────────────
# rs_script_ancestor_pid <pid> — nearest `script` ancestor (af layers claude under script).
rs_script_ancestor_pid() {
    local p
    for p in $(rs_ancestors "$1"); do
        [[ "$p" == "$1" ]] && continue
        [[ "$(rs_comm "$p")" == script ]] && { echo "$p"; return 0; }
    done
    return 1
}

# rs_tmux_pane <pid> — the pane that PROVABLY drives the target, else nothing. The target's
# TMUX_PANE in its environ is only a hint: a claude spawned inside a tmux job (or any process
# that inherited TMUX_PANE) carries a pane that drives the job, NOT itself — typing there is
# the wrong-session hazard. A pane counts only when its `pane_tty` is the target's own tty, or
# the tty of the target's nearest `script` ancestor (af's layering). No TMUX server / no match
# → empty, and the caller falls through to Konsole / the WSL injector.
rs_tmux_pane() {
    local pid="$1" pane ptty ttty sp
    pane=$(tr '\0' '\n' 2>/dev/null < "$RS_PROC/$pid/environ" | sed -n 's/^TMUX_PANE=//p' | head -1)
    [[ -n "$pane" ]] || return 1
    ptty=$("$RS_TMUX" display -p -t "$pane" '#{pane_tty}' 2>/dev/null)
    [[ -n "$ptty" ]] || return 1
    ttty=$(rs_tty "$pid")
    [[ -n "$ttty" && "$ptty" == "$ttty" ]] && { echo "$pane"; return 0; }
    sp=$(rs_script_ancestor_pid "$pid") || return 1
    [[ "$ptty" == "$(rs_tty "$sp")" ]] && { echo "$pane"; return 0; }
    return 1
}

# rs_konsole_target <pid> — "<service> <session path>" of the Konsole tab driving <pid>, else 1. The Konsole services
# are listed BEFORE the tty is read: on WSL there is no Konsole, and rs_tty there is a `wsl.exe -u root` probe
# (~140 ms) that a screen read every poll would pay for nothing (CFG-1022 N2).
rs_konsole_target() {
    local tty anc svc path spid svcs
    svcs=$("$RS_QDBUS" 2>/dev/null | grep -o 'org\.kde\.konsole-[0-9]*') || return 1
    tty=$(rs_tty "$1"); anc=$(rs_ancestors "$1")
    for svc in $svcs; do
        for path in $("$RS_QDBUS" "$svc" 2>/dev/null | grep -E '^/Sessions/[0-9]+$'); do
            spid=$("$RS_QDBUS" "$svc" "$path" org.kde.konsole.Session.processId 2>/dev/null)
            [[ -n "$spid" && "$spid" != 0 ]] || continue
            if [[ "$anc" == *" $spid "* ]] || [[ -n "$tty" && "$(rs_tty "$spid")" == "$tty" ]]; then
                echo "$svc $path"; return 0
            fi
        done
    done
    return 1
}

# rs_inject_wsl <pid> [text [--no-cr]] — root TIOCSTI into the session's own pts. With text:
# type text + Enter (--no-cr: the text alone); without: Enter alone. --expect-pid re-verifies
# the pid owns the pts.
rs_inject_wsl() {
    rs_gate_armed "$1" || return 3   # CFG-1083 F1: no key into a pid the gate was not passed for
    local pid="$1" tty cr=(); tty=$(rs_tty "$pid")
    [[ "$tty" =~ ^/dev/pts/[0-9]+$ ]] || return 3
    [[ "${3:-}" == --no-cr ]] && cr=(--no-cr)
    if [[ $# -ge 2 ]]; then
        $RS_INJECT "$RS_INJECTOR" --expect-pid "$pid" "$tty" "$2" "${cr[@]}"
    else
        $RS_INJECT "$RS_INJECTOR" --expect-pid "$pid" "$tty"
    fi
}

# rs_type_line <pid> <text> — type text then Enter into the target's terminal. Stamped before the keys
# (rs_stamp_typed); a write that fails takes its stamp back (rs_unstamp).
rs_type_line() {
    rs_gate_armed "$1" || return 3   # CFG-1083 F1
    local rc; rs_stamp_typed "$1" "$2"
    rs_type_line_keys "$1" "$2"; rc=$?
    (( rc )) && rs_unstamp "$1"
    return "$rc"
}
rs_type_line_keys() {
    local pane tgt
    pane=$(rs_tmux_pane "$1")
    if [[ -n "$pane" ]]; then
        "$RS_TMUX" send-keys -t "$pane" -l "$2" && sleep 1 && "$RS_TMUX" send-keys -t "$pane" Enter
        return
    fi
    if tgt=$(rs_konsole_target "$1"); then
        set -- "$1" "$2" $tgt
        "$RS_QDBUS" "$3" "$4" org.kde.konsole.Session.sendText "$2" >/dev/null \
            && sleep 1 && "$RS_QDBUS" "$3" "$4" org.kde.konsole.Session.sendText $'\r' >/dev/null
        return
    fi
    rs_is_wsl && { rs_inject_wsl "$1" "$2"; return; }
    return 3
}

# rs_input_target <pid> — how keys reach <pid>, by the dispatch above: "tmux <pane>", "konsole <service>
# <path>" or "wsl <tty>"; "none" and 3 when there is none. Read-only. A caller that guards its keys with a
# dialog-status read resolves this ONCE, before the read, and hands it to rs_type_text / rs_press_enter /
# rs_clear_input — so the read and the key are one step apart: on WSL every lookup is a ~0.12 s root exec,
# and two of them used to sit between the guard and the key (CFG-1006 review).
rs_input_target() {
    local pane tgt tty
    pane=$(rs_tmux_pane "$1")
    if [[ -n "$pane" ]]; then echo "tmux $pane"; return 0; fi
    if tgt=$(rs_konsole_target "$1"); then echo "konsole $tgt"; return 0; fi
    if rs_is_wsl; then
        tty=$(rs_tty "$1"); [[ "$tty" =~ ^/dev/pts/[0-9]+$ ]] && { echo "wsl $tty"; return 0; }
    fi
    echo none; return 3
}

# rs_type_text <pid> <text> [target] — the text WITHOUT Enter, to [target] (rs_input_target; resolved here
# when absent): tmux send-keys -l / Konsole sendText / WSL tty-inject.py --no-cr. 3 no input target. The
# line is stamped first (rs_stamp_typed): a prompt we typed never arms the shutdown-follow watcher; a
# write that fails takes the stamp back (rs_unstamp).
rs_type_text() {
    rs_gate_armed "$1" || return 3   # CFG-1083 F1: the gate's pass (rs_safety_check) is the one way to a key
    local t rc=0; rs_stamp_typed "$1" "$2"; t="${3:-$(rs_input_target "$1")}"; set -- "$1" "$2" $t
    if [[ "$3" == wsl ]] || rs_alive "$1"; then   # a pre-resolved pane/tab outlives its claude
        case "$3" in
            tmux)    "$RS_TMUX" send-keys -t "$4" -l "$2" || rc=$? ;;
            konsole) "$RS_QDBUS" "$4" "$5" org.kde.konsole.Session.sendText "$2" >/dev/null || rc=$? ;;
            wsl)     $RS_INJECT "$RS_INJECTOR" --expect-pid "$1" "$4" "$2" --no-cr || rc=$? ;;
            *)       rc=3 ;;
        esac
    else rc=3; fi
    (( rc )) && rs_unstamp "$1"
    return "$rc"
}

# rs_press_enter <pid> [target] — Enter alone, a write of its own (answers a CC selector at its default
# option); [target] as for rs_type_text. 3 no input target.
rs_press_enter() {
    rs_gate_armed "$1" || return 3   # CFG-1083 F1
    local t; t="${2:-$(rs_input_target "$1")}"; set -- "$1" $t
    [[ "$2" == wsl ]] || rs_alive "$1" || return 3
    case "$2" in
        tmux)    "$RS_TMUX" send-keys -t "$3" Enter ;;
        konsole) "$RS_QDBUS" "$3" "$4" org.kde.konsole.Session.sendText $'\r' >/dev/null ;;
        wsl)     $RS_INJECT "$RS_INJECTOR" --expect-pid "$1" "$3" ;;
        *)       return 3 ;;
    esac
}

# rs_log_offset <pid> — byte size of the session's script log now (0 if none)
rs_log_offset() { local f; f=$(rs_script_log "$1") && stat -c %s "$f" 2>/dev/null || echo 0; }

# rs_screen_text <pid> [offset] — what the session has shown (tmux pane / Konsole / since
# offset in its script log). Used to spot CC's background-work selector and shutdown lines.
rs_screen_text() {
    local pane tgt f
    pane=$(rs_tmux_pane "$1")
    if [[ -n "$pane" ]]; then "$RS_TMUX" capture-pane -p -t "$pane" 2>/dev/null; return; fi
    if tgt=$(rs_konsole_target "$1"); then
        set -- $tgt; "$RS_QDBUS" "$1" "$2" org.kde.konsole.Session.getAllDisplayedText 2>/dev/null; return
    fi
    f=$(rs_script_log "$1") || return 1
    if [[ -n "${2:-}" ]]; then tail -c +"$(( $2 + 1 ))" "$f" 2>/dev/null; else tail -c 20000 "$f" 2>/dev/null; fi
}

# ── waiters (shared limits with remote-poweroff) ─────────────────────────────
# rs_wait_gone <pid> <seconds> — wait for pid to die, answering CC's "Background work is
# running" selector with its default "Exit and stop tasks" (the shutdown already ran).
rs_wait_gone() {
    local end=$(( SECONDS + $2 )) answered=0
    RS_BG_DIALOG=0
    while rs_alive "$1"; do
        if rs_screen_text "$1" | grep -q "$RS_BG_PATTERN"; then
            RS_BG_DIALOG=1
            if (( answered < 3 )); then answered=$((answered + 1)); rs_press_enter "$1" || true; fi
        fi
        (( SECONDS >= end )) && return 1
        sleep "$RS_POLL"
    done
}

# rs_transcript_of <pid> — the session's transcript: its id from sessions/<pid>.json in its OWN
# config dir, the file under that dir's projects/ or the default dir's (cswap profiles share it).
rs_transcript_of() {
    local cc sid f; cc=$(rs_cc_dir_of "$1"); sid=$(rs_session_field "$1" sessionId "$cc")
    [[ -n "$sid" ]] || return 1
    for f in "$cc"/projects/*/"$sid".jsonl "$RS_CC_DIR"/projects/*/"$sid".jsonl; do
        [[ -f "$f" ]] && { echo "$f"; return 0; }
    done
    return 1
}

# rs_shutdown_reported <transcript> <offset> — 0 when, after byte <offset>, the LAST turn that ENDED
# (system/turn_duration) has, in its final assistant text, a line starting with "Shutdown complete"
# (CFG-1001). Tool output, a quoted phrase — also one inside a ``` fence or on a `>` blockquote line —, or
# the phrase followed by more work never count; nor does a completion written before the offset, nor one
# followed by a later turn (a prompt after the shutdown voided it). Screen text never decides. The judge is
# RS_SHUTDOWN_PY (remote-session-follow-lib.sh), shared with the shutdown-follow watcher's rs_shutdown_turn.
rs_shutdown_reported() {
    [[ -f "$1" ]] || return 1
    tail -c +"$(( $2 + 1 ))" "$1" 2>/dev/null | RS_SHUTDOWN_MODE=last python3 -c "$RS_SHUTDOWN_PY"
}

# rs_wait_shutdown <pid> <transcript> <offset> <seconds> — wait until rs_shutdown_reported and
# the session's own record is not busy. pid dying first counts as done (0); timeout 1.
rs_wait_shutdown() {
    local end=$(( SECONDS + $4 )) cc; cc=$(rs_cc_dir_of "$1")
    until rs_shutdown_reported "$2" "$3" && [[ "$(rs_session_field "$1" status "$cc")" != busy ]]; do
        rs_alive "$1" || return 0
        (( SECONDS >= end )) && return 1
        sleep "$RS_POLL"
    done
}

# ── relaunch: finding the NEW session and its prompt ─────────────────────────
# cmdline and environ of another session are readable as the same user (cwd/exe are not), so
# discovery needs no root. A claude records itself in ITS OWN config dir: an `af --account`
# session (cswap session mode) writes <profile>/sessions/<pid>.json, not RS_CC_DIR.
rs_env_var() { tr '\0' '\n' 2>/dev/null < "$RS_PROC/$1/environ" | sed -n "s/^$2=//p" | head -1; }
rs_cc_dir_of() { local c; c=$(rs_env_var "$1" CLAUDE_CONFIG_DIR); echo "${c:-$RS_CC_DIR}"; }

# rs_argv0_claude <pid> — 0 when its argv[0] is a claude binary (from the world-readable cmdline: no root needed)
rs_argv0_claude() {
    local a0="" x; { IFS= read -r -d '' a0 < "$RS_PROC/$1/cmdline"; } 2>/dev/null
    for x in "${RS_CLAUDE_EXES[@]}"; do [[ -n "$a0" && "${a0##*/}" == "$x" ]] && return 0; done
    return 1
}

# rs_claude_pids_in <dir> — live pids whose argv[0] is a claude binary and whose PWD is <dir>
rs_claude_pids_in() {
    local d w
    for d in "$RS_PROC"/[0-9]*; do
        rs_argv0_claude "${d##*/}" || continue
        w=$(rs_env_var "${d##*/}" PWD)
        [[ -n "$w" ]] && [[ "$w" == "$1" || "$(readlink -f "$w")" == "$1" ]] && rs_alive "${d##*/}" && echo "${d##*/}"
    done
}

# rs_wait_new_claude <dir> "<known pids>" <seconds> — RS_NEW_PID = the ONE claude that appeared in <dir>,
# not in <known pids>, with a session record (a cswap auth probe is a claude too but records nothing). 3 as soon as a
# record-less new claude has shown the same Claude Code dialog for RS_DIALOG_GRACE seconds (default 10; CFG-1022 F4):
# it writes no record until a human answers it, so waiting out <seconds> only delays the report. RS_STUCK_PID +
# RS_STUCK_DIALOG name it (rs_stuck_claude). The grace restarts whenever that screen changes (a human moving the
# selection); an answered dialog is no longer up (rs_screen_dialog), so it never ends the wait (re-review N1).
rs_wait_new_claude() {
    local end=$(( SECONDS + $3 )) p new seen="" since=0
    RS_NEW_PID=""
    while :; do
        new=()
        for p in $(rs_claude_pids_in "$1"); do
            [[ "$2 " == *" $p "* ]] && continue
            [[ -f "$(rs_cc_dir_of "$p")/sessions/$p.json" ]] && new+=("$p")
        done
        (( ${#new[@]} == 1 )) && { RS_NEW_PID="${new[0]}"; return 0; }
        (( ${#new[@]} > 1 )) && { RS_REASON="${#new[@]} new claude sessions appeared in $1 (${new[*]}) — not choosing"; return 2; }
        if rs_stuck_claude "$1" "$2"; then
            [[ "$seen" == "$RS_STUCK_PID $RS_STUCK_DIALOG $RS_STUCK_SIZE" ]] \
                || { seen="$RS_STUCK_PID $RS_STUCK_DIALOG $RS_STUCK_SIZE"; since=$SECONDS; }
            (( SECONDS - since >= ${RS_DIALOG_GRACE:-10} )) && return 3
        else seen=""; fi
        (( SECONDS >= end )) && return 1
        sleep "$RS_POLL"
    done
}

# rs_screen_dialog <pid> [size] — the Claude Code dialog that is UP on <pid>'s screen (rs_screen_text), by name:
# folder-trust, external-imports, mcp-server, or selector (any other option list, by its "Enter to confirm · Esc to
# cancel" guide); nothing and 1 when none (CFG-1022). [size]: "<name> <screen length>", for a caller that must see the
# screen change. A script(1) log is raw terminal output, and Claude Code 2.1.280 draws the space between two words as
# a cursor move (ESC[<n>G), so every escape sequence reads as a space; box and block drawing is dropped. The last
# named dialog drawn wins; a guide more than RS_DIALOG_SPAN characters after it belongs to a dialog with no name here.
# UP means the dialog is still the screen's trailing content (re-review N1): an ANSWERED dialog stays in the log tail,
# but what follows it — the prompt, the banner — is new text, while a human moving the selection only redraws the
# dialog's own words. More than RS_DIALOG_SLACK characters of words not in the dialog after its guide: not up.
rs_screen_dialog() {
    rs_screen_text "$1" 2>/dev/null | RS_DIALOG_SPAN="${RS_DIALOG_SPAN:-3000}" RS_DIALOG_SLACK="${RS_DIALOG_SLACK:-16}" \
        RS_DIALOG_SIZE="${2:-}" python3 -c 'import os,re,sys
t = sys.stdin.buffer.read().decode("utf-8", "replace")
t = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[()*+].|\x1b.|[\x00-\x1f\x7f]|[\N{BOX DRAWINGS LIGHT HORIZONTAL}-\N{QUADRANT UPPER RIGHT AND LOWER LEFT AND LOWER RIGHT}]", " ", t)
t = re.sub(r"\s+", " ", t)
span, slack = int(os.environ["RS_DIALOG_SPAN"]), int(os.environ["RS_DIALOG_SLACK"])
named = [("folder-trust", r"Is this a project you created or one you trust|Yes, I trust this folder"),
         ("external-imports", r"Allow external CLAUDE\.md file imports"),
         ("mcp-server", r"MCP servers? found in this project")]
n = max(((m.start(), m.end(), k) for k, p in named for m in re.finditer(p, t)), default=None)
g = max(((m.start(), m.end()) for m in re.finditer(r"Enter to confirm|Esc to cancel", t)), default=None)
if g and (n is None or n[0] <= g[1]):
    own = set(t[max(0, g[0] - span):g[1]].split())
    foreign, name = sum(len(w) for w in t[g[1]:].split() if w not in own), (n[2] if n and g[0] - n[1] <= span else "selector")
elif n:
    foreign, name = (0 if len(t) - n[1] <= span else slack + 1), n[2]
else:
    sys.exit(1)
if foreign > slack: sys.exit(1)
print(name, len(t)) if os.environ["RS_DIALOG_SIZE"] else print(name)'
}

# rs_stuck_claude <dir> "<known pids>" — a claude in <dir>, not in <known pids>, that keeps NO session record (Claude
# Code writes it once its prompt is up, so a startup dialog — folder trust, external imports — leaves none) and whose
# screen shows a dialog that is up: RS_STUCK_PID + RS_STUCK_DIALOG (rs_screen_dialog's name) + RS_STUCK_SIZE (its
# screen's length), 0; 1 when there is none. Read-only, and no root probe (N2: rs_screen_text reads the script(1) log).
# A claude with another claude above it (a hook's or a tool's `claude -p`) is that session's child, never a session of
# its own: skipped (F7). RS_NORECORD = " <pid> ..." of every other record-less claude seen there, dialog or not.
rs_stuck_claude() {
    local p d; RS_STUCK_PID="" RS_STUCK_DIALOG="" RS_STUCK_SIZE="" RS_NORECORD=" "
    for p in $(rs_claude_pids_in "$1"); do
        [[ "$2 " == *" $p "* || -f "$(rs_cc_dir_of "$p")/sessions/$p.json" ]] && continue
        rs_claude_ancestor "$p" && continue
        RS_NORECORD+="$p "
        if [[ -z "$RS_STUCK_PID" ]] && d=$(rs_screen_dialog "$p" size); then
            RS_STUCK_PID="$p" RS_STUCK_DIALOG="${d%% *}" RS_STUCK_SIZE="${d##* }"
        fi
    done
    [[ -n "$RS_STUCK_PID" ]]
}

# rs_claude_ancestor <pid> — 0 when a process above <pid> runs a claude binary (rs_argv0_claude)
rs_claude_ancestor() {
    local a
    for a in $(rs_ancestors "$1"); do [[ "$a" != "$1" ]] && rs_argv0_claude "$a" && return 0; done
    return 1
}

# rs_wait_prompt <pid> <seconds> — a NEW session is at its prompt: its record (own config dir) has a
# sessionId and status "idle". CC derives status from the REPL ("busy" loading/querying, "waiting" while
# a dialog or elicitation is up, else "idle"); a fresh record has none before the REPL mounts, so this
# needs "idle", not rs_wait_cleared's "not busy" (Enter would answer a dialog). RS_LAST_STATUS = last seen.
rs_wait_prompt() {
    local end=$(( SECONDS + $2 )) cc sid
    cc=$(rs_cc_dir_of "$1"); RS_LAST_STATUS=""
    while rs_alive "$1"; do
        sid=$(rs_session_field "$1" sessionId "$cc"); RS_LAST_STATUS=$(rs_session_field "$1" status "$cc")
        [[ -n "$sid" && "$RS_LAST_STATUS" == idle ]] && return 0
        (( SECONDS >= end )) && return 1
        sleep "$RS_POLL"
    done
    RS_LAST_STATUS="${RS_LAST_STATUS:-none} (pid exited)"; return 1
}

# rs_wait_cleared <pid> <old-sessionId> <seconds> — after /clear the pid stays but a fresh
# SessionStart runs: sessions/<pid>.json in its OWN config dir gets a new sessionId (CFG-1032: read from
# the caller's dir, a cswap-profile session's /clear was never seen). Done when it differs and the
# session is not busy. pid dying is a failure here (1); timeout 1.
rs_wait_cleared() {
    local end=$(( SECONDS + $3 )) sid cc; cc=$(rs_cc_dir_of "$1")
    while rs_alive "$1"; do
        sid=$(rs_session_field "$1" sessionId "$cc")
        [[ -n "$sid" && "$sid" != "$2" && "$(rs_session_field "$1" status "$cc")" != busy ]] && return 0
        (( SECONDS >= end )) && return 1
        sleep "$RS_POLL"
    done
    return 1
}

# ── the typing gate (CFG-1028): care shift or the user's explicit order only ──
# rs_typing_allowed, rs_care_caretaker, rs_care_read, rs_gate_log:
# shellcheck source=remote-session-gate-lib.sh
source "$RS_LIB_DIR/remote-session-gate-lib.sh"
# ── the typing stamp + the shutdown turn's Next: hint (CFG-1043/1044) ────────
# rs_stamp_typed, rs_unstamp, rs_shutdown_next:
# shellcheck source=remote-session-follow-lib.sh
source "$RS_LIB_DIR/remote-session-follow-lib.sh"
# ── submission: typed is not sent (CFG-1006) ─────────────────────────────────
# rs_submit_line, rs_clear_input, rs_dialog_up, rs_prompt_state, rs_wait_submitted:
# shellcheck source=remote-session-submit-lib.sh
source "$RS_LIB_DIR/remote-session-submit-lib.sh"
