#!/usr/bin/env bash
# fleet-drift.sh — head-vantage drift probe over registered fleet installations (CFG-615).
#
# Reads setup/config/fleet-installations.conf, probes each installation from a local
# vantage repo via bounded, read-only `git fetch`, classifies it — IN-SYNC / BEHIND /
# AHEAD / DIVERGED / DISCONNECTED / UNREACHABLE / no-vantage degrade — checks local
# fleet checkouts for fetch staleness, and writes ONE machine-local cache file.
# Prints exactly one FLEET_DRIFT line; silence never occurs, so a missing line is
# itself a fault. Two defects this exists to kill: fake precision (a DISCONNECTED
# repo must NEVER print behind/ahead counts — only "N|M commits-each-side") and
# stale health (a count with an old probe date must never render as health — the
# 29-day / "0 behind" incident; probe age escalates the severity).
#
# PARADIGM CONSTRAINT — no auto-reconcile, ever. The only write surface is the
# cache file: never merge, push, re-graft or file issues. Revoking a drift grant
# is a head decision, not a probe side effect.
#
# Modes: --if-due (daily sched gate, hook mode) | --force | --status (cache only)
#        | --local-only (checkout staleness only, zero remote probing)
# Test seams (optional env; empty = unset): FLEET_DRIFT_CONF, FLEET_DRIFT_CACHE,
#   FLEET_DRIFT_TIMEOUT, FLEET_DRIFT_HEAD_REPO, FLEET_DRIFT_HEAD_REF,
#   FLEET_DRIFT_LOCAL_REPOS (colon-separated scan override),
#   FLEET_DRIFT_FETCH_CMD (replaces the fetch: CMD <repo> <remote> <branch>),
#   FLEET_DRIFT_PROBE_LOG (one line per network probe — lets tests count calls).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

FD_CONF="${FLEET_DRIFT_CONF:-$REPO_ROOT/setup/config/fleet-installations.conf}"
FD_CACHE="${FLEET_DRIFT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/cfg-agent-fleet/fleet-drift.status}"
FD_TIMEOUT="${FLEET_DRIFT_TIMEOUT:-}"
[ -n "$FD_TIMEOUT" ] || FD_TIMEOUT=8
FD_HEAD_REPO="${FLEET_DRIFT_HEAD_REPO:-$HOME/agent-fleet}"
FD_HEAD_REF="${FLEET_DRIFT_HEAD_REF:-origin/main}"
FD_TODAY="$(date +%Y-%m-%d)"; FD_NOW="$(date +%s)"

# Thresholds: probe age warn/severe (d), activity warn (d), local fetch fresh (h)
FD_PROBE_WARN_D=7; FD_PROBE_SEVERE_D=14; FD_ACTIVITY_WARN_D=30; FD_LOCAL_FRESH_H=24

# Shared probe state: FRAGS holds "rank<TAB>text" (sorted worst-first for the
# body); INST_LINES holds per-installation cache lines (last-known memory).
FRAGS=(); INST_LINES=(); OVERALL="OK"; _FD_HEAD_FETCHED=""

_rank() { case "$1" in SEVERE) echo 3 ;; WARN) echo 2 ;; NOTE) echo 1 ;; *) echo 0 ;; esac; }

_worse() {
    if [ "$(_rank "$1")" -ge "$(_rank "$2")" ]; then echo "$1"; else echo "$2"; fi
}

add_frag() {  # severity text
    FRAGS+=("$(_rank "$1")	$2")
    OVERALL="$(_worse "$OVERALL" "$1")"
}

_probe_log() { [ -z "${FLEET_DRIFT_PROBE_LOG:-}" ] || echo "$1" >> "$FLEET_DRIFT_PROBE_LOG"; }

_epoch_date() { date -d "@$1" +%Y-%m-%d 2>/dev/null || date -r "$1" +%Y-%m-%d 2>/dev/null || echo "?"; }

# Bounded read-only fetch. The seam replaces the whole call for tests.
_fetch() {  # repo remote branch
    _probe_log "fetch $1 $2 $3"
    if [ -n "${FLEET_DRIFT_FETCH_CMD:-}" ]; then
        timeout "$FD_TIMEOUT" "$FLEET_DRIFT_FETCH_CMD" "$1" "$2" "$3" >/dev/null 2>&1
    else
        timeout "$FD_TIMEOUT" git -C "$1" fetch --quiet "$2" >/dev/null 2>&1
    fi
}

# ── Conf parsing ─────────────────────────────────────────────────────────────

_conf_rows() {  # prints "lineno<TAB>trimmed-row" per non-comment, non-blank line
    local n=0 line t
    [ -f "$FD_CONF" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        t="${line#"${line%%[![:space:]]*}"}"
        [ -z "$t" ] && continue
        [ "${t:0:1}" = "#" ] && continue
        printf '%s\t%s\n' "$n" "$t"
    done < "$FD_CONF"
}

# ── Last-known memory (from the previous cache) ──────────────────────────────

_last_known() {  # id → "date|summary" (summary may itself contain pipes)
    [ -f "$FD_CACHE" ] || return 0
    grep "^inst|${1}|" "$FD_CACHE" 2>/dev/null | head -1 | cut -d'|' -f3-
}

_unreachable() {  # id class reason
    local id="$1" class="$2" reason="$3" lk frag
    lk="$(_last_known "$id")"
    if [ -n "$lk" ]; then
        local lkdate="${lk%%|*}" lksum="${lk#*|}"
        frag="$class $id: UNREACHABLE ($reason) — last known: $lksum (as of $lkdate)"
        INST_LINES+=("inst|$id|$lkdate|$lksum")   # carry the knowledge forward
    else
        frag="$class $id: UNREACHABLE ($reason) — no prior probe on this machine"
    fi
    add_frag WARN "$frag"
}

# ── Per-installation probe ───────────────────────────────────────────────────

_probe_row() {  # lineno raw-row
    local lineno="$1" raw="$2"
    local id class url branch vantage warn severe extra
    IFS='|' read -r id class url branch vantage warn severe extra <<< "$raw"
    if [ -z "$id" ] || [ -z "$class" ] || [ -z "$url" ] || [ -z "$branch" ] || [ -z "$vantage" ] \
       || ! [[ "$warn" =~ ^[0-9]+$ ]] || ! [[ "$severe" =~ ^[0-9]+$ ]]; then
        add_frag WARN "CONFIG-ERROR (line $lineno): malformed row in $(basename "$FD_CONF") — expected id|class|url|branch|vantage|warn-behind|severe-behind"
        return 0
    fi

    local vrepo="${vantage%%:*}" vremote="${vantage##*:}"
    vrepo="${vrepo/#\~/$HOME}"

    # No usable vantage → degrade to an ls-remote tip check, and say so.
    if [ "$vantage" = "-" ] || [ ! -d "$vrepo/.git" ] \
       || ! git -C "$vrepo" remote get-url "$vremote" >/dev/null 2>&1; then
        _probe_log "ls-remote $url"
        local tip
        tip=$(timeout "$FD_TIMEOUT" git ls-remote "$url" "refs/heads/$branch" 2>/dev/null | head -1 | cut -c1-7)
        if [ -n "$tip" ]; then
            local frag="$class $id: reachable, tip $tip — counts unavailable on this machine (no usable vantage repo)"
            add_frag NOTE "$frag"
            INST_LINES+=("inst|$id|$FD_TODAY|$frag")
        else
            _unreachable "$id" "$class" "no usable vantage repo and ls-remote failed"
        fi
        return 0
    fi

    # Keep the head's own position fresh in this vantage before counting against
    # it — counting against a stale head ref is the 29-day defect in another form.
    local headremote="${FD_HEAD_REF%%/*}"
    case "$_FD_HEAD_FETCHED" in
        *"|$vrepo:$headremote|"*) ;;
        *)
            _FD_HEAD_FETCHED="$_FD_HEAD_FETCHED|$vrepo:$headremote|"
            if [ "$headremote" != "$vremote" ] && git -C "$vrepo" remote get-url "$headremote" >/dev/null 2>&1; then
                if ! _fetch "$vrepo" "$headremote" "(head)"; then
                    add_frag WARN "head remote $headremote unreachable from $vrepo — head position may be stale"
                fi
            fi
            ;;
    esac

    if ! _fetch "$vrepo" "$vremote" "$branch"; then
        _unreachable "$id" "$class" "fetch of $vremote failed or timed out (${FD_TIMEOUT}s)"
        return 0
    fi

    local headref="$FD_HEAD_REF" instref="$vremote/$branch"
    if ! git -C "$vrepo" rev-parse --verify --quiet "$headref" >/dev/null 2>&1 \
       || ! git -C "$vrepo" rev-parse --verify --quiet "$instref" >/dev/null 2>&1; then
        _unreachable "$id" "$class" "refs $headref/$instref unavailable in vantage $vrepo"
        return 0
    fi

    local headsha counts nbehind nahead act_epoch act_days act_date frag sev
    headsha=$(git -C "$vrepo" rev-parse --short "$headref" 2>/dev/null || echo "?")
    counts=$(git -C "$vrepo" rev-list --left-right --count "$headref...$instref" 2>/dev/null || echo "")
    nbehind="${counts%%[[:space:]]*}"; nahead="${counts##*[[:space:]]}"
    act_epoch=$(git -C "$vrepo" log -1 --format=%ct "$instref" 2>/dev/null || echo "$FD_NOW")
    act_days=$(( (FD_NOW - act_epoch) / 86400 ))
    act_date="$(_epoch_date "$act_epoch")"

    if ! git -C "$vrepo" merge-base "$headref" "$instref" >/dev/null 2>&1; then
        # DISCONNECTED — behind/ahead is UNDEFINED; refuse to print those counts.
        local vdelta="" hv iv
        hv=$(git -C "$FD_HEAD_REPO" show "$FD_HEAD_REF:.agent-fleet-version" 2>/dev/null | tr -d '[:space:]')
        iv=$(git -C "$vrepo" show "$instref:.agent-fleet-version" 2>/dev/null | tr -d '[:space:]')
        [ -n "$hv" ] && [ -n "$iv" ] && vdelta=" Version marker v$iv vs head v$hv."
        frag="$class $id: DISCONNECTED — no common ancestor with head $headsha. ${nbehind:-?}|${nahead:-?} commits-each-side (NOT behind/ahead — histories are unrelated). Git update from head cannot ff or merge; propagation is file-copy only until re-grafted.${vdelta} Last activity $act_date (${act_days}d). HEAD DECISION REQUIRED."
        add_frag SEVERE "$frag"
        INST_LINES+=("inst|$id|$FD_TODAY|$frag")
        return 0
    fi

    local state grant="" nb="${nbehind:-0}" na="${nahead:-0}"
    sev=OK
    if [ "$nb" -eq 0 ] && [ "$na" -eq 0 ]; then
        state="IN-SYNC"
    else
        if [ "$na" -eq 0 ]; then state="BEHIND $nb"
        elif [ "$nb" -eq 0 ]; then state="AHEAD $na — local evolution"
        else state="DIVERGED ${nb}↓ ${na}↑"
        fi
        if [ "$nb" -ge "$severe" ] && [ "$nb" -gt 0 ]; then
            sev=SEVERE; grant=" (severe at $severe) — HEAD DECISION REQUIRED"
        elif [ "$nb" -ge "$warn" ] && [ "$nb" -gt 0 ]; then
            sev=WARN; grant=" — beyond granted drift (warn at $warn)"
        else
            grant=" — within granted drift (warn at $warn)"
        fi
    fi
    frag="$class $id: ${state}${grant}, last activity $act_date (${act_days}d)"
    if [ "$act_days" -gt "$FD_ACTIVITY_WARN_D" ]; then
        sev="$(_worse "$sev" WARN)"
        frag="$frag [WARN — activity staleness]"
    fi
    add_frag "$sev" "$frag"
    INST_LINES+=("inst|$id|$FD_TODAY|$frag")
}

# ── Local checkout fetch-staleness ───────────────────────────────────────────

_local_fragments() {
    local repos=() r vrow vantage vrepo dup
    if [ -n "${FLEET_DRIFT_LOCAL_REPOS:-}" ]; then
        IFS=':' read -r -a repos <<< "$FLEET_DRIFT_LOCAL_REPOS"
    else
        repos=("$FD_HEAD_REPO")
        while IFS=$'\t' read -r _ vrow; do
            vantage=$(printf '%s' "$vrow" | cut -d'|' -f5)
            vrepo="${vantage%%:*}"; vrepo="${vrepo/#\~/$HOME}"
            [ "$vrepo" = "-" ] || [ -z "$vrepo" ] && continue
            dup=0
            for r in "${repos[@]}"; do [ "$r" = "$vrepo" ] && dup=1; done
            [ "$dup" -eq 0 ] && repos+=("$vrepo")
        done < <(_conf_rows)
    fi

    local checked=0 stale=0 fh age_s age_d nbehind branch never
    for r in "${repos[@]}"; do
        [ -d "$r/.git" ] || continue
        checked=$((checked + 1))
        branch=$(git -C "$r" symbolic-ref --short HEAD 2>/dev/null || echo main)
        nbehind=$(git -C "$r" rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo "?")
        fh="$r/.git/FETCH_HEAD"
        never=0
        if [ -f "$fh" ]; then
            age_s=$(( FD_NOW - $(stat -c %Y "$fh" 2>/dev/null || stat -f %m "$fh" 2>/dev/null || echo "$FD_NOW") ))
        else
            never=1; age_s=$(( FD_LOCAL_FRESH_H * 3600 + 1 ))
        fi
        if [ "$age_s" -gt $(( FD_LOCAL_FRESH_H * 3600 )) ]; then
            stale=$((stale + 1))
            if [ "$never" -eq 1 ]; then
                add_frag WARN "local checkout $r reports $nbehind behind — but no fetch has ever been recorded here; that figure is against clone-time origin/$branch and means nothing. Run: git -C $r fetch origin"
            else
                age_d=$(( age_s / 86400 ))
                add_frag WARN "local checkout $r reports $nbehind behind — but last fetch was ${age_d}d ago; that figure is against a ${age_d}d-old origin/$branch and means nothing. Run: git -C $r fetch origin"
            fi
        fi
    done
    if [ "$checked" -gt 0 ] && [ "$stale" -eq 0 ]; then
        add_frag OK "local checkouts fresh (all fetched <${FD_LOCAL_FRESH_H}h)"
    fi
}

# ── Body composition, cache, render ──────────────────────────────────────────

_join_frags() {  # worst severity first, stable within rank
    local out="" f
    [ ${#FRAGS[@]} -eq 0 ] && return 0
    while IFS= read -r f; do
        out="${out:+$out | }$f"
    done < <(printf '%s\n' "${FRAGS[@]}" | sort -s -t'	' -k1,1nr | cut -f2-)
    printf '%s' "$out"
}

_head_line() {
    local sha ver name
    name=$(basename "$FD_HEAD_REPO")
    if sha=$(git -C "$FD_HEAD_REPO" rev-parse --short "$FD_HEAD_REF" 2>/dev/null); then
        ver=$(git -C "$FD_HEAD_REPO" show "$FD_HEAD_REF:.agent-fleet-version" 2>/dev/null | tr -d '[:space:]')
        echo "head $name $sha${ver:+ v$ver}"
    else
        echo "head checkout unavailable ($FD_HEAD_REPO)"
    fi
}

_write_cache() {  # body
    local body="$1" tmp
    mkdir -p "$(dirname "$FD_CACHE")" 2>/dev/null || true
    tmp="$FD_CACHE.tmp.$$"
    {
        echo "# fleet-drift cache — machine-local, the probe's ONLY write surface"
        echo "probe_epoch=$FD_NOW"
        echo "probe_date=$FD_TODAY"
        echo "severity=$OVERALL"
        echo "body=$body"
        if [ ${#INST_LINES[@]} -gt 0 ]; then
            printf '%s\n' "${INST_LINES[@]}"
        fi
    } > "$tmp" && mv "$tmp" "$FD_CACHE"
}

_probe_all() {
    FRAGS=(); INST_LINES=(); OVERALL="OK"; _FD_HEAD_FETCHED=""
    if [ ! -f "$FD_CONF" ]; then
        add_frag WARN "CONFIG-ERROR — fleet-installations.conf not found at $FD_CONF"
        _write_cache "$(_join_frags)"
        return 0
    fi
    local rows=0 lineno row
    while IFS=$'\t' read -r lineno row; do
        rows=$((rows + 1))
        _probe_row "$lineno" "$row"
    done < <(_conf_rows)
    if [ "$rows" -eq 0 ]; then
        _write_cache "no sub-fleets registered"
        return 0
    fi
    _local_fragments
    _write_cache "$(_head_line) | $(_join_frags)"
}

_render() {
    if [ ! -f "$FD_CACHE" ]; then
        echo "FLEET_DRIFT[WARN]: never probed on this machine — run 'bash $SCRIPT_DIR/fleet-drift.sh --force'"
        return 0
    fi
    local epoch pdate sev body age_d
    epoch=$(sed -n 's/^probe_epoch=//p' "$FD_CACHE" | head -1)
    pdate=$(sed -n 's/^probe_date=//p' "$FD_CACHE" | head -1)
    sev=$(sed -n 's/^severity=//p' "$FD_CACHE" | head -1)
    body=$(sed -n 's/^body=//p' "$FD_CACHE" | head -1)
    [ -n "$epoch" ] || epoch=0
    age_d=$(( (FD_NOW - epoch) / 86400 ))
    if [ "$body" = "no sub-fleets registered" ] && [ "$age_d" -le "$FD_PROBE_WARN_D" ]; then
        echo "FLEET_DRIFT: no sub-fleets registered"
        return 0
    fi
    # A count without a fresh probe is never presented as health.
    if [ "$age_d" -gt "$FD_PROBE_SEVERE_D" ]; then
        sev=SEVERE
        body="STALE-PROBE: last probe was ${age_d}d ago — every count below was measured then; a count without a fresh probe is never health. Run 'bash $SCRIPT_DIR/fleet-drift.sh --force'. | $body"
    elif [ "$age_d" -gt "$FD_PROBE_WARN_D" ]; then
        sev="$(_worse "$sev" WARN)"
        body="STALE-PROBE (${age_d}d): counts below were measured ${age_d}d ago. Run 'bash $SCRIPT_DIR/fleet-drift.sh --force'. | $body"
    fi
    if [ "$sev" = "OK" ]; then
        echo "FLEET_DRIFT: probed $pdate | $body"
    else
        echo "FLEET_DRIFT[$sev]: $body | probed $pdate"
    fi
}

_local_only() {
    FRAGS=(); OVERALL="OK"
    _local_fragments
    if [ ${#FRAGS[@]} -eq 0 ]; then
        echo "FLEET_DRIFT: no local fleet checkouts found on this machine"
        return 0
    fi
    if [ "$OVERALL" = "OK" ]; then
        echo "FLEET_DRIFT: $(_join_frags)"
    else
        echo "FLEET_DRIFT[$OVERALL]: $(_join_frags)"
    fi
}

# ── Daily gate (sched-lib, with an inline fallback) ──────────────────────────

_gate_due() {
    if [ -f "$SCRIPT_DIR/sched-lib.sh" ]; then
        # shellcheck source=/dev/null
        source "$SCRIPT_DIR/sched-lib.sh"
        sched_is_due "fleet-drift" "daily"
    else
        [ ! -f "${FD_CACHE}.gate-$FD_TODAY" ]
    fi
}

_gate_done() {
    if type sched_mark_done >/dev/null 2>&1; then
        sched_mark_done "fleet-drift" "daily"
    else
        mkdir -p "$(dirname "$FD_CACHE")" 2>/dev/null || true
        : > "${FD_CACHE}.gate-$FD_TODAY"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

case "${1:---status}" in
    --status)     _render ;;
    --local-only) _local_only ;;
    --force)      _probe_all; _render ;;
    --if-due)
        if _gate_due; then
            _probe_all
            _gate_done
        fi
        _render
        ;;
    -h|--help)
        sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        ;;
    *)
        echo "fleet-drift.sh: unknown mode '$1' (use --if-due|--force|--status|--local-only)" >&2
        exit 2
        ;;
esac
exit 0
