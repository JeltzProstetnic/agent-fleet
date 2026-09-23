#!/usr/bin/env bash
# launch-registry.sh — the record of what THIS machine's fleet launchers started.
#
# CFG-694. MG, 2026-09-23: "you need to learn some control and discipline when killing
# processes before you kill something important by mistake!!!" — and, on a proposal that he
# approve kills by PID: "did you think i would know processes by PID?? ridiculous, do
# better - this is cfg job". So this is mechanical: no human is in the loop.
#
# Three kills in one night all picked their target by NAME rather than by OWNERSHIP:
#   1. `ssh 'pkill -f <script>'` self-matched its own shell (CFG-597/CFG-693)
#   2. a start script recorded a SUBSHELL's $! instead of the service's pid, so its own
#      stop killed an unrelated process
#   3. a cleanup killed every `sleep 300` on the box — correct by luck alone
#
# A session's own descendants are provable from the process tree. Anything a launcher
# detaches is NOT — a tmux pane is a child of the tmux server, not of the session that
# asked for it — so those get written down here at launch. Start-time is stored alongside
# the pid because pids are recycled, and "the pid I started" must not become a licence to
# kill whatever now holds that number.
#
# Usage:
#   launch-registry.sh add <pid> <label> [<argv...>]
#   launch-registry.sh has <pid>            # exit 0 if registered AND still the same process
#   launch-registry.sh list                 # human-readable, live entries only
#   launch-registry.sh prune                # drop entries whose process is gone
set -uo pipefail

REGISTRY="${CC_LAUNCH_REGISTRY:-${XDG_CACHE_HOME:-$HOME/.cache}/cfg-agent-fleet/launch-registry.tsv}"

# Linux: field 22 of /proc/<pid>/stat is starttime in clock ticks since boot. It is the
# only cheap value that distinguishes a recycled pid from the original.
_starttime() {  # <pid> → starttime, or empty when the process is gone
    local pid="$1" stat
    [ -r "/proc/$pid/stat" ] || return 0
    # comm can contain spaces and parentheses, so cut after the LAST ')'.
    stat=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null) || return 0
    printf '%s' "$stat" | awk '{print $20}'
}

_ensure() { mkdir -p "$(dirname "$REGISTRY")" 2>/dev/null || true; [ -f "$REGISTRY" ] || : > "$REGISTRY"; }

registry_add() {  # <pid> <label> [argv...]
    local pid="$1" label="${2:-}"; shift 2 2>/dev/null || shift 1
    local argv="${*:-}" st
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    st=$(_starttime "$pid")
    [ -n "$st" ] || return 1          # never register a pid that is already gone
    _ensure
    printf '%s\t%s\t%s\t%s\n' "$pid" "$st" "$label" "$argv" >> "$REGISTRY"
}

registry_has() {  # <pid> → 0 when this exact process was registered by us
    local pid="$1" st line r_pid r_st
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -f "$REGISTRY" ] || return 1
    st=$(_starttime "$pid")
    [ -n "$st" ] || return 1
    while IFS=$'\t' read -r r_pid r_st _ _; do
        [ "$r_pid" = "$pid" ] || continue
        # Same pid AND same start time. Same pid alone would hand a recycled number over.
        [ "$r_st" = "$st" ] && return 0
    done < "$REGISTRY"
    return 1
}

registry_list() {  # live entries only — a dead entry is noise in a refusal message
    [ -f "$REGISTRY" ] || return 0
    local r_pid r_st r_label r_argv st
    while IFS=$'\t' read -r r_pid r_st r_label r_argv; do
        [ -n "$r_pid" ] || continue
        st=$(_starttime "$r_pid")
        [ "$st" = "$r_st" ] || continue
        printf '  %-8s %s%s\n' "$r_pid" "${r_label:-<unlabelled>}" \
            "$( [ -n "$r_argv" ] && printf ' — %.70s' "$r_argv" )"
    done < "$REGISTRY"
}

registry_prune() {
    [ -f "$REGISTRY" ] || return 0
    local tmp r_pid r_st rest st
    tmp="${REGISTRY}.tmp.$$"
    while IFS=$'\t' read -r r_pid r_st rest; do
        [ -n "$r_pid" ] || continue
        st=$(_starttime "$r_pid")
        [ "$st" = "$r_st" ] && printf '%s\t%s\t%s\n' "$r_pid" "$r_st" "$rest"
    done < "$REGISTRY" > "$tmp"
    mv -f "$tmp" "$REGISTRY"
}

# CLI only when executed, so the hook can source it without side effects.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        add)   shift; registry_add "$@" ;;
        has)   shift; registry_has "$@" ;;
        list)  registry_list ;;
        prune) registry_prune ;;
        *) printf 'usage: launch-registry.sh add <pid> <label> [argv...] | has <pid> | list | prune\n' >&2; exit 2 ;;
    esac
fi
