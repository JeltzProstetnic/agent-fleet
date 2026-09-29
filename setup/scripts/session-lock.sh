#!/usr/bin/env bash
# session-lock.sh — PID-based session lock for same-machine protection (CFG-146)
#
# Library of functions for managing session locks. Source this file, then call:
#   acquire_lock <project_dir> [session_id]
#   release_lock <project_dir> [session_id]
#   check_lock <project_dir>
#   lock_info <project_dir>
#   force_release <project_dir>
#   lock_self_unknown [self_pid]   (CFG-592: rc 0 ⇒ own CC unresolvable, others visible)
#
# Lock file: $PROJECT_DIR/.claude/.session-lock (JSON, gitignored)
# Format: {"machine":"hostname","pid":12345,"sessionId":"abc","timestamp":"ISO8601","user":"name"}
#
# Return codes for check_lock:
#   0 = no lock (free) — also returned after stale lock auto-cleanup
#   1 = locked by us (our PID on this machine)
#   2 = locked by another session on this machine (different live PID)
#   3 = locked by another machine (can't verify PID — warn only)
#   4 = cannot determine (CFG-673 / GH#9): the liveness scan sees /proc but NO
#       Claude Code process at all, not even the caller's own, so "no live
#       session" would describe the scan's blindness, not the machine. Seen
#       inside Claude Code's Bash sandbox (its own PID namespace hides every
#       host process while /proc still exists) and with a CC matcher that
#       recognises nothing on this install. The lock, if any, is LEFT IN PLACE.
#       Callers MUST treat 4 as held (fail closed) and report it as unknown,
#       never as free. Owner decision 2026-09-25: "Fail closed: 'unknown'".
#
# Hook integration points (DO NOT modify hooks yet — library must be proven first):
#   SessionStart hook → check_lock → if locked, inject warning into systemMessage
#   SessionEnd hook   → release_lock
#   Statusline hook   → periodic heartbeat (update timestamp in lock file)

# ── Helper: check if PID is alive ──────────────────────────────────────────

_is_pid_alive() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null
}

# ── Liveness: is a real Claude Code session live in this project? (CFG-468) ────
# The mutex must NOT rely solely on the lock file's recorded PID — that PID is
# frequently the EPHEMERAL SessionStart hook process, so the lock decays to
# "stale" seconds after it is written and the next session steals it and becomes
# a second leader. These helpers let check_lock/acquire_lock treat "a live CC
# process is cwd'd in this project" as authoritative, independent of the lock.
#
# Overridable for tests: _CC_PROC_RE (cmdline regex identifying a CC process),
# _CC_SELF_PID (this session's own CC pid to exclude). Empty exclude ⇒ FAIL OPEN
# (report no competitor) so a legitimate solo session is NEVER self-blocked.

# GH#7 / CFG-590: the first alternative alone assumed the npm layout, so on any
# install invoked as a bare binary NOTHING here fired — _pid_is_cc said no to the
# real running session, _cc_self_pid came back empty, _project_has_live_cc
# short-circuited on its own empty-exclude guard, and check_lock reported every
# project free. A mutex that always grants, silently. The second alternative
# anchors on a path-segment boundary and requires the command name to END at
# `claude`, so `mclaude` (the launcher wrapping the real process), `~/.claude/…`
# paths and a stray `claude` in an argument are all still correctly rejected —
# verified against every process running on a live fleet machine, 0 false
# positives in 258. Regression guard: setup/tests/test-session-lock-matcher.sh.
: "${_CC_PROC_RE:=claude-code/(bin/|cli)|(^|/)claude([[:space:]]|$)}"

_pid_cmdline() {
    local pid="$1"
    if [[ -r "/proc/$pid/cmdline" ]]; then
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null
    else
        ps -p "$pid" -o args= 2>/dev/null
    fi
}

_pid_is_cc() {
    local pid="$1" cmd
    cmd="$(_pid_cmdline "$pid")" || return 1
    [[ -n "$cmd" ]] || return 1
    printf '%s' "$cmd" | grep -Eq "$_CC_PROC_RE"
}

_pid_cwd() {
    readlink "/proc/$1/cwd" 2>/dev/null
}

_ppid_of() {
    local pid="$1" st=""
    if [[ -r "/proc/$pid/stat" ]]; then
        # "pid (comm) state ppid …" — comm may contain spaces and ')', so take
        # the fields after the LAST ') ' (a whitespace split read "tmux: server"
        # as ppid 'S'). Builtins only: this runs once per hop of every ancestry
        # walk, i.e. up to 40 times per pid in a /proc scan.
        { read -r st < "/proc/$pid/stat"; } 2>/dev/null || return 0
        st="${st##*) }"          # "state ppid …"
        st="${st#* }"            # "ppid …"
        printf '%s\n' "${st%% *}"
    else
        ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' '
    fi
}

# Walk up from $1 (default $$) to the nearest CC-process ancestor. Echo pid, rc 0;
# rc 1 (no output) if none found — callers then FAIL OPEN.
_cc_ancestor_pid() {
    local pid="${1:-$$}" guard=0
    while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" && $guard -lt 40 ]]; do
        if _pid_is_cc "$pid"; then printf '%s' "$pid"; return 0; fi
        pid="$(_ppid_of "$pid")"
        guard=$((guard + 1))
    done
    return 1
}

# This session's own CC pid to exclude from the scan. Honors _CC_SELF_PID if set
# (even to empty). Empty result ⇒ callers fail OPEN.
_cc_self_pid() {
    if [[ -n "${_CC_SELF_PID+x}" ]]; then printf '%s' "$_CC_SELF_PID"; return 0; fi
    _cc_ancestor_pid "$$" 2>/dev/null || true
}

# ── Ownership by CC-process ancestry (CFG-454) ───────────────────────────────
# The session lock's recorded pid is bound at acquire time and — for the primary
# `af`/afleet flow — is a LIVE ANCESTOR of the owning session's CC process (afleet
# runs mclaude as a child via `script`, so the afleet shell that wrote the lock
# stays an ancestor of CC for the whole session). Ownership is proven by walking UP
# from the parent of the caller's OWN CC process:
#   - reach the lock's pid before any other CC  → we are the owning (outermost) CC;
#   - hit another CC first                       → we are a NESTED CC (not owner);
#   - reach init without either                  → a different session (not owner).
# Overridable in tests via _CC_SELF_PID plus _ppid_of / _pid_is_cc / _is_pid_alive.

# rc 0 iff the caller positively OWNS a lock whose recorded pid is $1 (strict —
# used for release, where a false positive would clobber a live leader). rc 1 when
# not proven, including when the caller's own CC pid is unresolvable.
_cc_owns_lock_pid() {
    local lock_pid="$1"
    [[ -n "$lock_pid" ]] || return 1
    local mycc; mycc="$(_cc_self_pid)" || return 1
    [[ -n "$mycc" ]] || return 1
    # The lock pid is our own CC pid (a launch path that recorded the CC pid).
    [[ "$lock_pid" == "$mycc" ]] && return 0
    local pid guard=0
    pid="$(_ppid_of "$mycc")"
    while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" && $guard -lt 40 ]]; do
        [[ "$pid" == "$lock_pid" ]] && return 0   # reached lock pid, no CC above us → owner
        _pid_is_cc "$pid" && return 1             # another CC above us → we are nested
        pid="$(_ppid_of "$pid")"
        guard=$((guard + 1))
    done
    return 1
}

# rc 0 iff the caller is positively a NESTED CC (another CC sits above its own CC).
# rc 1 if it is the outermost CC or its CC pid is unresolvable. Gates check_lock's
# id-based ownership signals (fail-open: refuse only a proven nested).
_cc_is_nested() {
    local mycc; mycc="$(_cc_self_pid)" || return 1
    [[ -n "$mycc" ]] || return 1
    _cc_ancestor_pid "$(_ppid_of "$mycc")" >/dev/null 2>&1
}

# The caller's own CC session id, or "" (CFG-454). Three sources, in order:
#   CC_SESSION_ID          — config-check.sh reads it from the SessionStart hook's
#                            stdin and exports it for the checks (07b, 06b). It
#                            exists ONLY inside that hook's process tree.
#   CLAUDE_CODE_SESSION_ID — what Claude Code itself puts in the env of every hook
#                            AND tool subprocess it spawns, set per spawn to the
#                            spawning CC's OWN session id (the hook-stdin id), so a
#                            value inherited from a parent CC or a tmux server is
#                            replaced, never passed through. This is the only id a
#                            Bash-tool subprocess — the agent's bare
#                            `rotate-session.sh` at shutdown — has.
#                            Counted ONLY when a CC above the caller resolves: that
#                            CC is what vouches for it. A job in a tmux pane has no
#                            CC above it and carries the tmux SERVER's global env —
#                            the id of whichever CC started the server, even when
#                            another session opened the pane (the CFG-672 class).
#   CLAUDE_SESSION_ID      — legacy name, kept for callers that still set it.
_caller_cc_session_id() {
    if [[ -n "${CC_SESSION_ID:-}" ]]; then
        printf '%s' "$CC_SESSION_ID"; return 0
    fi
    if [[ -n "${CLAUDE_CODE_SESSION_ID:-}" && -n "$(_cc_self_pid)" ]]; then
        printf '%s' "$CLAUDE_CODE_SESSION_ID"; return 0
    fi
    printf '%s' "${CLAUDE_SESSION_ID:-}"
}

# rc 0 iff the lock just read (_read_lock globals) is bound to the caller's own CC
# session: a non-empty ccSessionId equal to _caller_cc_session_id, and the caller
# is not a proven nested CC (a nested CC inherits its parent's environment, so an
# ungated id comparison would reopen the CFG-454 F1 spoof).
_lock_bound_to_caller() {
    local mine; mine="$(_caller_cc_session_id)"
    [[ -n "$_LOCK_CC_SESSION" && -n "$mine" && "$_LOCK_CC_SESSION" == "$mine" ]] || return 1
    ! _cc_is_nested
}

# rc 0 ⇒ a live CC process (other than exclude_pid) has cwd == project_dir.
# FAIL OPEN (rc 1, "no competitor") when exclude_pid is empty (cannot tell self
# from other) or process enumeration is unavailable — never self-block.
# Enumerate every live pid, one per line. Separate from the scan below so tests
# can replace the whole process world deterministically. rc 1 ⇒ enumeration is
# unavailable, and the caller FAILS OPEN.
_enumerate_pids() {
    if [[ -d /proc ]]; then
        for d in /proc/[0-9]*; do printf '%s\n' "${d#/proc/}"; done 2>/dev/null
    elif command -v ps >/dev/null 2>&1; then
        ps -eo pid= 2>/dev/null
    else
        return 1
    fi
}

# rc 0 iff $1 is $2 itself or lies anywhere below $2 in the process tree.
# The walk is bounded (40 hops, same as the ownership helpers) so a corrupt or
# racing ppid readout can never hang the mutex; an unresolved walk simply
# answers "not a descendant", which keeps the guard on its safe side.
_pid_is_descendant_of() {
    local pid="$1" ancestor="$2" guard=0
    [[ -n "$pid" && -n "$ancestor" ]] || return 1
    while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" && $guard -lt 40 ]]; do
        [[ "$pid" == "$ancestor" ]] && return 0
        pid="$(_ppid_of "$pid")"
        guard=$((guard + 1))
    done
    return 1
}

# rc 0 iff at least one Claude Code process is visible to this caller (CFG-673).
# A non-empty self pid counts as a visible CC: _cc_self_pid returns only a pid
# the matcher recognised, and an explicit check_lock self-pid argument is the
# caller naming its own CC. So the full scan runs only when self is unresolvable.
# rc 1 when enumeration is unavailable or finds no CC: the caller is blind (the
# Bash sandbox's PID namespace, or a matcher that recognises nothing here), and
# a scan that found nobody proves nothing about who holds a project.
_cc_visible() {
    local self_pid="${1:-}" pids p
    [[ -n "$self_pid" ]] && return 0
    pids="$(_enumerate_pids)" || return 1
    for p in $pids; do
        _pid_is_cc "$p" && return 0
    done
    return 1
}

_project_has_live_cc() {
    local project_dir="$1" exclude_pid="$2"
    [[ -n "$exclude_pid" ]] || return 1
    local target
    target="$(realpath "$project_dir" 2>/dev/null)" || target="$project_dir"
    local pids p cwd
    pids="$(_enumerate_pids)" || return 1
    for p in $pids; do
        # Exclude self AND self's whole descendant tree (CFG-468). Excluding only
        # the exact pid made the guard self-tripping: rotation runs through a Bash
        # tool call, CC spawns a child for it, and that child is a CC process cwd'd
        # in the project — indistinguishable from a rival unless parentage is checked.
        _pid_is_descendant_of "$p" "$exclude_pid" && continue
        _pid_is_cc "$p" || continue
        cwd="$(_pid_cwd "$p")" || continue
        [[ "$cwd" == "$target" ]] && return 0
    done
    return 1
}

# ── Self-unknown but not blind (CFG-592) ─────────────────────────────────────
# rc 0 iff the caller's own CC pid is UNRESOLVABLE while at least one CC process
# IS visible. That is the one shape check_lock still grants silently: the scan
# is not blind (so rc 4 does not fire), yet _project_has_live_cc fails OPEN on
# its empty exclude without looking (deliberate — a solo session must never
# self-block), so a "no other session here" verdict is unproven: a second
# session already in the project would NOT have been detected. Owner decision
# 2026-09-28 (option 3): keep granting, but a caller that takes the lead on such
# a verdict MUST say so (07b: SESSION_LOCK_SELF_UNKNOWN). Typical causes:
# _CC_PROC_RE matching another install's CC but not this one's (CFG-590/GH#7),
# or an ancestry walk cut short (an ancestor's /proc/<pid>/stat unreadable).
# Optional $1 = the caller's own CC pid; ${1-...} respects an explicitly empty
# argument as "unresolvable", exactly as check_lock's second argument does.
# rc 1: self resolves, or no CC is visible at all (that case is check_lock's 4).
lock_self_unknown() {
    local self_pid="${1-$(_cc_self_pid)}"
    [[ -z "$self_pid" ]] || return 1
    _cc_visible ""
}

# ── Helper: generate a pseudo-random session ID ────────────────────────────

_generate_session_id() {
    # Use /proc/sys/kernel/random/uuid if available, else fall back to date+random
    if [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        printf "%s-%04x" "$(date +%s)" "$RANDOM"
    fi
}

# ── Helper: read lock file and parse JSON fields ───────────────────────────
# Sets global vars: _LOCK_MACHINE, _LOCK_PID, _LOCK_SESSION, _LOCK_TIMESTAMP, _LOCK_USER
# Returns 0 on success, 1 if file missing or invalid JSON

_read_lock() {
    local lockfile="$1"
    _LOCK_MACHINE="" _LOCK_PID="" _LOCK_SESSION="" _LOCK_TIMESTAMP="" _LOCK_USER="" _LOCK_CC_SESSION=""

    [[ -f "$lockfile" ]] || return 1

    local json
    json=$(<"$lockfile")

    local parsed
    if command -v python3 >/dev/null 2>&1; then
        # Parse JSON using python3
        parsed=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get('machine',''))
    print(d.get('pid',''))
    print(d.get('sessionId',''))
    print(d.get('timestamp',''))
    print(d.get('user',''))
    print(d.get('ccSessionId',''))
except:
    sys.exit(1)
" <<< "$json" 2>/dev/null) || return 1
    elif command -v jq >/dev/null 2>&1; then
        # Fallback: parse JSON using jq
        parsed=$(jq -r '[.machine // "", .pid // "", .sessionId // "", .timestamp // "", .user // "", .ccSessionId // ""] | .[]' <<< "$json" 2>/dev/null) || return 1
    else
        # Fallback: pure-bash JSON field extraction (simple flat objects only)
        _json_field() { local v="${json#*\"$1\":}"; v="${v%%[,\}]*}"; v="${v#*\"}"; v="${v%\"*}"; echo "$v"; }
        local pid_raw
        _LOCK_MACHINE=$(_json_field machine)
        pid_raw=$(_json_field pid)
        # pid is a number (unquoted in JSON) — strip whitespace
        pid_raw="${pid_raw// /}"
        _LOCK_PID="$pid_raw"
        _LOCK_SESSION=$(_json_field sessionId)
        _LOCK_TIMESTAMP=$(_json_field timestamp)
        _LOCK_USER=$(_json_field user)
        # ccSessionId may be absent in legacy locks; only trust it if the key is present
        if [[ "$json" == *'"ccSessionId"'* ]]; then
            _LOCK_CC_SESSION=$(_json_field ccSessionId)
        fi
        unset -f _json_field
        # Validate we got at least machine and pid
        [[ -n "$_LOCK_MACHINE" && -n "$_LOCK_PID" ]] || return 1
        return 0
    fi

    # Read parsed lines into variables (python3/jq path)
    {
        read -r _LOCK_MACHINE
        read -r _LOCK_PID
        read -r _LOCK_SESSION
        read -r _LOCK_TIMESTAMP
        read -r _LOCK_USER
        read -r _LOCK_CC_SESSION
    } <<< "$parsed"

    return 0
}

# ── Helper: write lock file ────────────────────────────────────────────────

_write_lock() {
    local lockfile="$1"
    local session_id="$2"
    local cc_session_id="${3:-}"
    local pid_override="${4:-}"

    # CFG-452 F2: session_id / cc_session_id are the only externally-influenced
    # fields spliced into the JSON encoders below (the rest are locally generated).
    # A quote / newline / backslash would 0-byte the lock on encoder failure
    # (mutual-exclusion loss), and pid is interpolated unquoted — so validate and
    # REFUSE unsafe input rather than truncate the live lock. Allowed: [A-Za-z0-9._-] or empty.
    local _idre='^[A-Za-z0-9._-]*$'
    if [[ ! "$session_id" =~ $_idre ]] || [[ ! "$cc_session_id" =~ $_idre ]]; then
        echo "_write_lock: refusing unsafe id (session='${session_id}' cc='${cc_session_id}') — lock left unchanged" >&2
        return 1
    fi
    if [[ -n "$pid_override" && ! "$pid_override" =~ ^[0-9]+$ ]]; then
        echo "_write_lock: refusing non-numeric pid_override '${pid_override}' — lock left unchanged" >&2
        return 1
    fi

    local machine pid user timestamp
    machine="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)"
    if [[ "$machine" == "unknown" ]]; then
        echo "WARNING: hostname could not be resolved — lock will use 'unknown'. Multi-machine lock detection unreliable." >&2
    fi
    # pid_override lets a caller (e.g. stamp_cc_session) preserve the ORIGINAL owner
    # PID instead of clobbering it with the transient $$ of the stamping process.
    pid="${pid_override:-$$}"
    user="$(whoami)"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    mkdir -p "$(dirname "$lockfile")"

    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json
data = {
    'machine': '$machine',
    'pid': $pid,
    'sessionId': '$session_id',
    'timestamp': '$timestamp',
    'user': '$user',
    'ccSessionId': '$cc_session_id'
}
print(json.dumps(data))
" > "$lockfile"
    elif command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg machine "$machine" \
            --argjson pid "$pid" \
            --arg sessionId "$session_id" \
            --arg timestamp "$timestamp" \
            --arg user "$user" \
            --arg ccSessionId "$cc_session_id" \
            '{machine: $machine, pid: $pid, sessionId: $sessionId, timestamp: $timestamp, user: $user, ccSessionId: $ccSessionId}' \
            > "$lockfile"
    else
        # Fallback: pure-bash JSON construction (simple flat object, no escaping needed
        # for the controlled values we produce — hostname, PID, date, whoami)
        printf '{"machine":"%s","pid":%s,"sessionId":"%s","timestamp":"%s","user":"%s","ccSessionId":"%s"}\n' \
            "$machine" "$pid" "$session_id" "$timestamp" "$user" "$cc_session_id" > "$lockfile"
    fi
}

# ── acquire_lock ────────────────────────────────────────────────────────────
# Create lock file. If lock exists and PID alive on this machine, return error.
# If lock exists but PID dead (stale) or corrupt, auto-clean and acquire.
# session_id is optional (generates UUID-like if not provided).
# Returns: 0 = acquired, 1 = lock held by another live session

acquire_lock() {
    local project_dir="$1"
    local session_id="${2:-$(_generate_session_id)}"
    local cc_session_id="${3:-}"
    # self_pid = pid to exclude from the liveness scan. afleet pre-launch passes
    # its own (non-CC) pid so the scan RUNS and finds an incumbent; the hook
    # resolves its CC pid. ${4-...} respects an explicitly-passed empty string.
    local self_pid="${4-$(_cc_self_pid)}"
    local lockfile="$project_dir/.claude/.session-lock"
    local lockdir="$project_dir/.claude/.session-lock.d"

    # Ensure .claude/ dir exists
    mkdir -p "$(dirname "$lockfile")" 2>/dev/null || true

    # If lock file exists, check ownership before attempting acquire
    if [[ -f "$lockfile" ]]; then
        if ! _read_lock "$lockfile"; then
            # Corrupt lock — but do NOT steal it from a live session (CFG-468)
            if _project_has_live_cc "$project_dir" "$self_pid"; then
                echo "Corrupt lock but a live session is active in this project — refusing" >&2
                return 1
            fi
            rm -f "$lockfile"
        else
            # Same session ID — idempotent re-acquire. Preserve the existing cc
            # binding (unless the caller supplies a new one) and the ORIGINAL owner
            # PID, so a re-acquire never un-stamps a lock or resets its PID to the
            # transient hook $$ (CFG-452 F3). _read_lock populated the globals above.
            if [[ "$_LOCK_SESSION" == "$session_id" ]]; then
                _write_lock "$lockfile" "$session_id" "${cc_session_id:-$_LOCK_CC_SESSION}" "$_LOCK_PID"
                return 0
            fi

            # Different machine — can't verify PID, refuse
            if [[ "$_LOCK_MACHINE" != "$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)" ]]; then
                echo "Lock held by another machine: $_LOCK_MACHINE (session: $_LOCK_SESSION)" >&2
                return 1
            fi

            # Same machine — recorded PID alive → refuse
            if _is_pid_alive "$_LOCK_PID"; then
                echo "Lock held by live process PID=$_LOCK_PID (session: $_LOCK_SESSION)" >&2
                return 1
            fi

            # Recorded PID dead — but a live CC may still hold this project under a
            # different pid (ephemeral-hook bug). Refuse BEFORE removing the lock so
            # a newcomer never deletes a live incumbent's lock. FAIL OPEN. (CFG-468)
            if _project_has_live_cc "$project_dir" "$self_pid"; then
                echo "Lock stale but a live session is active in this project — refusing" >&2
                return 1
            fi

            # Genuinely stale — will overwrite below
            rm -f "$lockfile"
        fi
    else
        # No lock file — but a live foreign CC may already own the project
        # (direct/non-afleet launch, or an incumbent whose lock decayed). (CFG-468)
        if _project_has_live_cc "$project_dir" "$self_pid"; then
            echo "A live session is active in this project — refusing acquire" >&2
            return 1
        fi
    fi

    # Atomic write: mkdir is atomic on POSIX — prevents concurrent acquires.
    # Only reached when lock file doesn't exist (free, stale-cleaned, or corrupt-cleaned).
    if mkdir "$lockdir" 2>/dev/null; then
        # CFG-723: record the resolved CC pid when known. Without it the lock carried
        # $$ — the SessionStart hook's subshell, dead within seconds of acquiring.
        _write_lock "$lockfile" "$session_id" "$cc_session_id" "$self_pid"
        rmdir "$lockdir" 2>/dev/null || true
        return 0
    fi

    # mkdir failed — another session is writing the lock right now
    echo "Lock acquisition race lost — another session acquired first" >&2
    return 1
}

# ── release_lock ────────────────────────────────────────────────────────────
# Remove lock file. Only if we own it (check sessionId or PID).
# Returns: 0 = released or no lock, 1 = lock owned by someone else

release_lock() {
    local project_dir="$1"
    local session_id="${2:-}"
    local lockfile="$project_dir/.claude/.session-lock"

    # No lock — noop success
    if [[ ! -f "$lockfile" ]]; then
        return 0
    fi

    # Try to read lock
    if ! _read_lock "$lockfile"; then
        # Corrupt — just remove
        rm -f "$lockfile"
        return 0
    fi

    # If session_id provided, check it matches
    if [[ -n "$session_id" ]]; then
        if [[ "$_LOCK_SESSION" == "$session_id" ]]; then
            rm -f "$lockfile"
            return 0
        else
            echo "Lock owned by session $_LOCK_SESSION, not $session_id" >&2
            return 1
        fi
    fi

    # No session_id — check PID
    if [[ "$_LOCK_PID" == "$$" ]]; then
        rm -f "$lockfile"
        return 0
    fi

    echo "Lock owned by PID $_LOCK_PID, not $$" >&2
    return 1
}

# ── release_own_lock (CFG-452) ───────────────────────────────────────────────
# Remove the lock ONLY if the caller can PROVE ownership: the lock's sessionId
# must equal the caller-supplied expected_session_id. NEVER derives ownership
# from the lock file and NEVER force-removes — a follower session must not delete
# a live leader's lock. Anything it cannot prove is its own is left intact.
# Returns: 0 = released, or safe no-op (no lock at all);
#          1 = a lock is present but not provably ours (left intact)

# ── stamp_cc_session (CFG-452 Phase 1) ───────────────────────────────────────
# Bind an already-owned lock to a unique CC session id (from the SessionStart
# hook's stdin) WITHOUT changing the recorded PID — this is what makes ownership
# immune to an inherited AFLEET_SESSION_ID env var (a nested CC process has a
# DIFFERENT cc session id). Only stamps a lock on THIS machine that is not
# already bound to a different cc session.
# Returns: 0 = stamped, 1 = no lock / not this machine / already bound elsewhere

stamp_cc_session() {
    local project_dir="$1"
    local cc_session_id="$2"
    local lockfile="$project_dir/.claude/.session-lock"

    [[ -f "$lockfile" ]] || return 1
    [[ -n "$cc_session_id" ]] || return 1
    _read_lock "$lockfile" || return 1

    local myhost
    myhost="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)"
    [[ "$_LOCK_MACHINE" == "$myhost" ]] || return 1

    # Already bound to a different CC session — do not override
    if [[ -n "$_LOCK_CC_SESSION" && "$_LOCK_CC_SESSION" != "$cc_session_id" ]]; then
        return 1
    fi

    # CFG-454: binding an UNSTAMPED lock is an ownership claim and needs POSITIVE
    # proof — "not a proven nested CC" was not enough. A CC started through
    # tmux-launch.sh / setsid is parented to the tmux server, not to the leader's
    # CC, so the nesting gate could not see it, yet it inherits the leader's
    # AFLEET_SESSION_ID; with the leader's lock still unstamped (deploy-transition
    # window, CC_SESSION_ID empty at the leader's SessionStart) it bound the lock
    # to ITS cc id and released it at its own SessionEnd (3b(4)).
    # Proof is ancestry (3a): the lock pid is this hook's own shell (07b acquired
    # it a moment ago — $$ is a DESCENDANT of our CC, so ancestry cannot say so)
    # or a live launcher ancestor of our CC with no other CC in between (the af
    # shape). Without it the lock is someone else's whenever its pid is alive OR
    # another live CC is cwd'd in the project (a direct-launch leader whose hook
    # pid has died). Fail-open only when our own CC pid is unresolvable: the
    # spoof needs a resolvable rival, which a detection-degraded platform
    # equally lacks, and a leader there stamps at its own SessionStart first.
    if [[ -z "$_LOCK_CC_SESSION" ]]; then
        local _mycc; _mycc="$(_cc_self_pid)"
        if [[ -n "$_mycc" && "$_LOCK_PID" != "$$" ]] && ! _cc_owns_lock_pid "$_LOCK_PID"; then
            if _is_pid_alive "$_LOCK_PID" || _project_has_live_cc "$project_dir" "$_mycc"; then
                return 1
            fi
        fi
    fi

    # Rewrite preserving sessionId and the ORIGINAL pid (never clobber it with $$).
    # Propagate _write_lock's status so an unsafe cc id (refused by _write_lock)
    # is not reported as a successful stamp (CFG-452 F2).
    _write_lock "$lockfile" "$_LOCK_SESSION" "$cc_session_id" "$_LOCK_PID"
}

# ── release_own_lock (CFG-452) ───────────────────────────────────────────────
# Remove the lock ONLY if the caller can PROVE ownership. Ownership proof:
#   - if the lock carries a ccSessionId (bound to a unique CC session), ONLY a
#     matching expected_cc_sid releases it — an inherited AFLEET_SESSION_ID does
#     NOT (closes the nested-process env-inheritance spoof);
#   - legacy locks without a ccSessionId fall back to a sessionId match.
# NEVER derives the expected id from the lock file and NEVER force-removes.
# Returns: 0 = released or safe no-op (no lock); 1 = present but not provably ours.

release_own_lock() {
    local project_dir="$1"
    local expected_sid="$2"
    local expected_cc_sid="${3:-}"
    local lockfile="$project_dir/.claude/.session-lock"

    # No lock — nothing to do
    [[ -f "$lockfile" ]] || return 0

    # Unreadable/corrupt — cannot prove it's ours, leave it (startup stale-cleans)
    _read_lock "$lockfile" || return 1

    # Lock bound to a unique CC session — ONLY that proves ownership; sessionId ignored.
    if [[ -n "$_LOCK_CC_SESSION" ]]; then
        if [[ -n "$expected_cc_sid" && "$_LOCK_CC_SESSION" == "$expected_cc_sid" ]]; then
            rm -f "$lockfile"
            return 0
        fi
        return 1
    fi

    # Unstamped lock (no ccSessionId). When we can resolve our own CC pid, ownership
    # is proven by PROCESS ANCESTRY (_cc_owns_lock_pid): the lock's recorded pid must
    # be a live ancestor of THIS session's CC with no other CC in between (we are the
    # outermost/leader CC that owns it). An inherited AFLEET_SESSION_ID no longer
    # proves anything — a nested CC hits the leader's CC first and is refused. This
    # closes the F1 residual (CFG-454).
    if [[ -n "$(_cc_self_pid)" ]]; then
        if _cc_owns_lock_pid "$_LOCK_PID"; then
            rm -f "$lockfile"
            return 0
        fi
        return 1
    fi

    # Degraded: our own CC pid is unresolvable (e.g. the native-binary detection gap
    # — CFG-454 3b). Fall back to the legacy sessionId proof so a genuine leader can
    # still release its own lock. The inheritance spoof needs a resolvable rival CC
    # pid — which a detection-degraded platform equally lacks — so this fallback is
    # not a spoof vector here.
    if [[ -n "$expected_sid" && "$_LOCK_SESSION" == "$expected_sid" ]]; then
        rm -f "$lockfile"
        return 0
    fi

    # Not provably ours — never remove
    return 1
}

# ── check_lock ──────────────────────────────────────────────────────────────
# Check if lock exists.
# Returns: 0 = free, 1 = locked by us, 2 = locked by another (same machine),
#          3 = locked by another machine, 4 = cannot determine (blind scan —
#          see the header; the lock is kept, callers treat it as held)
#
# CFG-673 / GH#9: every "free" verdict below rests on the liveness scan having
# found no live CC. When the scan can see no CC process at all (_cc_visible),
# that finding is the scan's blindness, so the verdict is 4 and nothing is
# removed. The alive-pid and remote-machine verdicts do not rest on the scan
# and are unchanged. Deliberately NOT extended: an unresolvable own CC while
# OTHER CCs are visible keeps its fail-open contract (it is not blind) — the
# caller reports that shape via lock_self_unknown (CFG-592) — and
# acquire_lock keeps its own scan (afleet runs it before any CC exists).

check_lock() {
    local project_dir="$1"
    # self_pid = this session's own CC pid to exclude from the liveness scan.
    # ${2-...} (no colon): an explicitly-passed empty string is RESPECTED as
    # "unresolvable self" (→ fail open); only an UNSET arg resolves via ancestry.
    local self_pid="${2-$(_cc_self_pid)}"
    local lockfile="$project_dir/.claude/.session-lock"

    # No lock file — but a live foreign CC in the project still means LOCKED (CFG-468)
    if [[ ! -f "$lockfile" ]]; then
        _project_has_live_cc "$project_dir" "$self_pid" && return 2
        _cc_visible "$self_pid" || return 4
        return 0
    fi

    # Corrupt — do NOT clean/steal while a live foreign CC is present, nor on a
    # blind scan (CFG-673)
    if ! _read_lock "$lockfile"; then
        _project_has_live_cc "$project_dir" "$self_pid" && return 2
        _cc_visible "$self_pid" || return 4
        rm -f "$lockfile"
        return 0
    fi

    # Different machine — can't verify PID
    if [[ "$_LOCK_MACHINE" != "$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)" ]]; then
        return 3
    fi

    # Same machine — recorded PID alive?
    if _is_pid_alive "$_LOCK_PID"; then
        # Ours if the recorded pid is our shell or our resolved CC pid.
        if [[ "$_LOCK_PID" == "$$" || ( -n "$self_pid" && "$_LOCK_PID" == "$self_pid" ) ]]; then
            return 1
        fi
        # CFG-536: on the primary `af`/afleet launch path the lock records the
        # LAUNCHER shell, never the claude.exe pid, so the comparison above can
        # never match and a leader read its own live lock as foreign. Fall back
        # to the ownership signals the library already computes.
        #
        # Gate them all on "not a nested CC" first: a nested CC INHERITS the
        # leader's CC_SESSION_ID / AFLEET_SESSION_ID, so an ungated id comparison
        # would hand it ownership and reopen the CFG-454 F1 spoof.
        if ! _cc_is_nested; then
            # ccSessionId is the reliable ownership signal; the pid is not.
            # _lock_bound_to_caller repeats the nesting gate — cheap, and keeps
            # the one definition of "bound to the caller" in one place.
            if _lock_bound_to_caller; then
                return 1
            fi
            # Ancestry: the lock pid is a live ancestor of our CC with no other CC
            # in between ⇒ we are the session that shell launched.
            if _cc_owns_lock_pid "$_LOCK_PID"; then
                return 1
            fi
            # CFG-672: the afleet id is an INHERITED env var and the nesting gate
            # above is ancestry-only. A CC started through tmux-launch.sh is
            # parented to the tmux server — which carries the AFLEET_SESSION_ID of
            # whichever session started it — not to the leader's CC, so the gate
            # cannot see it and an ungated id match handed it the leader's lock.
            # Ancestry already proves the af leader whenever our own CC pid
            # resolves; the id match is accepted only when it does not (degraded
            # matcher), mirroring release_own_lock's sessionId fallback.
            if [[ -z "$(_cc_self_pid)" && -n "$_LOCK_SESSION" && -n "${AFLEET_SESSION_ID:-}" && "$_LOCK_SESSION" == "${AFLEET_SESSION_ID}" ]]; then
                return 1
            fi
        fi
        # Another live session on this machine
        return 2
    fi

    # Recorded PID dead. A lock bound to OUR cc session is ours whatever its pid
    # says (CFG-454): a direct launch records the SessionStart hook's pid, dead
    # seconds later (CFG-468), so without this the leader read its own lock as
    # foreign whenever any other CC — a follower, a tmux job — was cwd'd in the
    # project (the ivbook refusal), and with nobody else there it deleted its own
    # lock as stale. Checked before the scan, which it also saves.
    if _lock_bound_to_caller; then
        return 1
    fi

    # Otherwise the session may still be live under a different pid (the lock's
    # pid is often the ephemeral SessionStart hook). Only auto-clean when NO live
    # CC process is cwd'd in this project. FAIL OPEN. (CFG-468)
    if _project_has_live_cc "$project_dir" "$self_pid"; then
        return 2
    fi
    # CFG-673: a scan that sees no CC at all cannot tell "stale" from "held by
    # a session I cannot see" (the Bash sandbox hides the host's processes, so
    # the recorded pid read dead above for the same reason). Keep the lock.
    if ! _cc_visible "$self_pid"; then
        return 4
    fi
    rm -f "$lockfile"
    return 0
}

# ── lock_age ──────────────────────────────────────────────────────────────
# Compute human-readable age from lock timestamp (CFG-218)
# Output: "Xd Yh Zm" (e.g., "2h 15m", "1d 3h", "5m")
# Returns: 0 on success, 1 if no lock or unreadable

lock_age() {
    local project_dir="$1"
    local lockfile="$project_dir/.claude/.session-lock"

    [[ -f "$lockfile" ]] || return 1
    _read_lock "$lockfile" || return 1

    local lock_epoch now_epoch diff_secs
    lock_epoch=$(date -u -d "$_LOCK_TIMESTAMP" +%s 2>/dev/null) || return 1
    now_epoch=$(date -u +%s)
    diff_secs=$((now_epoch - lock_epoch))

    if [[ $diff_secs -lt 0 ]]; then
        diff_secs=0
    fi

    local days hours minutes
    days=$((diff_secs / 86400))
    hours=$(( (diff_secs % 86400) / 3600 ))
    minutes=$(( (diff_secs % 3600) / 60 ))

    local result=""
    if [[ $days -gt 0 ]]; then
        result="${days}d ${hours}h"
    elif [[ $hours -gt 0 ]]; then
        result="${hours}h ${minutes}m"
    else
        result="${minutes}m"
    fi

    echo "$result"
}

# ── lock_info ───────────────────────────────────────────────────────────────
# Print lock contents as human-readable text

lock_info() {
    local project_dir="$1"
    local lockfile="$project_dir/.claude/.session-lock"

    if [[ ! -f "$lockfile" ]]; then
        echo "No lock — project is free"
        return 0
    fi

    if ! _read_lock "$lockfile"; then
        echo "Lock file exists but is corrupt"
        return 0
    fi

    echo "Session Lock:"
    echo "  Machine:    $_LOCK_MACHINE"
    echo "  PID:        $_LOCK_PID"
    echo "  Session ID: $_LOCK_SESSION"
    echo "  User:       $_LOCK_USER"
    echo "  Timestamp:  $_LOCK_TIMESTAMP"

    # Age (CFG-218)
    local _age
    _age=$(lock_age "$project_dir" 2>/dev/null) || _age="unknown"
    echo "  Age:        $_age"

    # Status check
    if [[ "$_LOCK_MACHINE" != "$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)" ]]; then
        echo "  Status:     REMOTE (cannot verify PID)"
    elif _is_pid_alive "$_LOCK_PID"; then
        if [[ "$_LOCK_PID" == "$$" ]]; then
            echo "  Status:     ACTIVE (our session)"
        else
            echo "  Status:     ACTIVE (another session)"
        fi
    else
        echo "  Status:     STALE (PID dead)"
    fi
}

# ── force_release ───────────────────────────────────────────────────────────
# Force-remove lock regardless of owner (manual override)

force_release() {
    local project_dir="$1"
    local lockfile="$project_dir/.claude/.session-lock"

    rm -f "$lockfile"
    return 0
}

# ── Role marker (CFG-452 Phase 2) ────────────────────────────────────────────
# A minimal per-session leader|follower marker, persisted at SessionStart (when
# the acquire result is unambiguous) and read at SessionEnd to gate shared-state
# mutation. One file per session identity so parallel sessions coexist:
#   $PROJECT_DIR/.claude/.session-role.<id>   (single-word body, gitignored)
# Identity key = CC session id (stable across a session's start+end hooks), else
# the afleet id. With NEITHER (degraded launch) no marker is written — shutdown
# then falls back to lock ownership rather than risk a shared-slot mis-write.

_role_file_path() {
    # Echo the deterministic marker path for this identity, or return 1 if no
    # stable id. The id is sanitized to _write_lock's safe charset so a hostile
    # value can neither traverse out of .claude/ nor create an odd filename.
    local project_dir="$1" cc_sid="${2:-}" afleet_sid="${3:-}"
    local id="${cc_sid:-$afleet_sid}"
    [[ -n "$id" ]] || return 1
    id="$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '_')"
    [[ -n "$id" ]] || return 1
    printf '%s/.claude/.session-role.%s' "$project_dir" "$id"
}

# Default lifetime of a role marker, in days. A session that has not written its
# marker for this long is gone; 7 is deliberately generous, since the only cost
# of keeping one too long is one stale file and the cost of dropping a live
# session's marker is a misread role at shutdown.
: "${_ROLE_MAX_AGE_DAYS:=7}"

gc_roles() {
    # CFG-468 Defect E — nothing ever removed role markers, so they accumulated
    # for months (12 in the live repo on 2026-08-23, oldest Jul 7). Collect the
    # expired ones, and NEVER the caller's own marker whatever its age.
    #
    # Deliberately narrow: only `.claude/.session-role.*` under the given project
    # dir, only past the age threshold, and always rc 0 so a cleanup failure can
    # never break a session start.
    local project_dir="$1" max_age="${2:-$_ROLE_MAX_AGE_DAYS}"
    local keep_cc="${3:-}" keep_afleet="${4:-}"
    local rdir="$project_dir/.claude"
    [[ -d "$rdir" ]] || return 0
    [[ "$max_age" =~ ^[0-9]+$ ]] || return 0

    local keep=""
    keep="$(_role_file_path "$project_dir" "$keep_cc" "$keep_afleet" 2>/dev/null)" || keep=""

    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        [[ "$f" == "$keep" ]] && continue
        rm -f -- "$f" 2>/dev/null || true
    done < <(find "$rdir" -maxdepth 1 -type f -name '.session-role.*' \
                  -mtime "+$max_age" 2>/dev/null)
    return 0
}

write_role() {
    # Persist this session's role (leader|follower). Returns 1 (no write) on an
    # invalid role or when no stable identity is available.
    local project_dir="$1" role="$2" cc_sid="${3:-}" afleet_sid="${4:-}"
    case "$role" in leader|follower) ;; *) return 1 ;; esac
    local rf
    rf="$(_role_file_path "$project_dir" "$cc_sid" "$afleet_sid")" || return 1
    mkdir -p "$(dirname "$rf")" 2>/dev/null || true
    printf '%s\n' "$role" > "$rf" 2>/dev/null || return 1
    # Opportunistic GC on the way in: this runs at every SessionStart via 07b, so
    # the cleanup needs no new call site and no hook edit. A cleanup that has to
    # be invoked deliberately is the state this fixes.
    gc_roles "$project_dir" "" "$cc_sid" "$afleet_sid" || true
    return 0
}

read_role() {
    # Echo this session's persisted role (rc 0). Returns 1 with no output when
    # there is no stable id, no marker, or a body that is not leader|follower.
    local project_dir="$1" cc_sid="${2:-}" afleet_sid="${3:-}"
    local rf
    rf="$(_role_file_path "$project_dir" "$cc_sid" "$afleet_sid")" || return 1
    [[ -f "$rf" ]] || return 1
    local r
    r="$(<"$rf")"
    r="${r//[[:space:]]/}"
    case "$r" in
        leader|follower) printf '%s' "$r"; return 0 ;;
        *) return 1 ;;
    esac
}

clear_role() {
    # Remove this session's role marker. Always a safe no-op (rc 0).
    local project_dir="$1" cc_sid="${2:-}" afleet_sid="${3:-}"
    local rf
    rf="$(_role_file_path "$project_dir" "$cc_sid" "$afleet_sid")" || return 0
    rm -f "$rf" 2>/dev/null || true
    return 0
}
