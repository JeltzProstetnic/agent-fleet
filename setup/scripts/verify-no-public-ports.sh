#!/usr/bin/env bash
# verify-no-public-ports.sh — check from OFF-HOST that a deployed host exposes
# nothing beyond an explicit allowlist of intentionally-public ports (CFG-594).
#
# Why this exists: an on-host `curl localhost:PORT` succeeds whether a service is
# bound to 127.0.0.1 or to 0.0.0.0, so only a probe from a DIFFERENT machine can
# tell a safe deploy from an exposed one. That is how a clickdummy served HTTP 200
# on a public IP, no auth, no TLS, for ~2 months.
#
# HONESTY CONTRACT — what one vantage can and cannot know: a completed handshake
# PROVES open; an explicit "connection refused" (RST) proves not-listening;
# SILENCE proves NOTHING — target-side firewall DROP (safe) and vantage-side
# egress block (blind — Zscaler, hotel wifi) are byte-identical from here.
# Therefore PASS requires every probed port to have been OBSERVED (open or
# refused). Any unanswered port makes the whole run INCONCLUSIVE — loud and
# non-zero — unless an unexpected open port was proven, which is always FAIL.
# On a default-deny-DROP target, expect INCONCLUSIVE: that is the true answer
# from one vantage, not a defect. Treat exit 3 as "verify another way"
# (on-target `ss -tlnp` + provider firewall rules), never as a pass.
#
# Exit codes:
#   0 PASS every port observed, nothing unexpected open | 1 FAIL exposure proven
#   2 USAGE bad arguments (including empty --allow/--ports)
#   3 INCONCLUSIVE >=1 port unobserved or scan did not run — NEVER a pass
#   4 ERROR run from the target host itself; that vantage cannot answer

set -uo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────

DEFAULT_ALLOW="22,80,443"
# Common service/app ports. NOT exhaustive — the verdict prints the computed count.
DEFAULT_PORTS="21,22,23,25,53,80,110,135,139,143,443,445,465,587,993,995,1080,1433,1521,2375,2376,3000,3001,3128,3306,3389,4000,4200,5000,5173,5432,5601,5672,5900,5984,6379,7000,8000,8001,8008,8080,8081,8086,8090,8096,8123,8200,8384,8420,8422,8443,8500,8788,8888,9000,9090,9092,9200,9300,11211,11434,15672,27017,50000"
MAX_PARALLEL=24

info() { echo "[ports] $*"; }
err()  { echo "[ports] $*" >&2; }

usage() {
    cat << 'EOF'
Usage: verify-no-public-ports.sh <host> [options]
  --allow LIST     Intentionally-public ports (default: 22,80,443)
  --ports LIST     Ports to probe (default: built-in common-service set)
  --timeout SEC    Per-port connect timeout, whole seconds (default: 2)
Exit: 0 pass (every port observed, nothing unexpected open)
      1 unexpected port open   | 2 usage error
      3 inconclusive — >=1 port unanswered or scan did not run; NEVER a pass
      4 run on the target itself (that vantage cannot answer)
EOF
}

# ── Probe ─────────────────────────────────────────────────────────────────────

# Classify one connect attempt. Only TWO results are observations:
#   open   — the TCP handshake completed
#   closed — the target explicitly refused (RST)
# Everything else — timeout, no route, network unreachable, DNS failure, any
# unrecognised error — is "noanswer": the port was NOT observed. Folding those
# into "not open" was the fail-open the refutation caught (an unroutable network
# would otherwise read as "everything closed" and pass).
_classify_connect() {
    local rc="$1" errtext="$2"
    if   (( rc == 0 ));   then echo open
    elif (( rc == 124 )); then echo noanswer
    elif [[ "$errtext" == *"onnection refused"* ]]; then echo closed
    else echo noanswer
    fi
}

# bash /dev/tcp only — deliberately no `nc`: the nc variants (ncat, busybox,
# BSD) disagree on flags and output, and a wrong guess about either used to be
# silently classified as "not open". /dev/tcp has one failure vocabulary, and
# LC_ALL=C pins it. Host/port are passed as arguments, never interpolated into
# the -c string.
_default_probe() {
    local host="$1" port="$2" rc=0 errtext=""
    errtext=$(timeout "$TIMEOUT" env LC_ALL=C \
        bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$host" "$port" 2>&1) || rc=$?
    _classify_connect "$rc" "$errtext"
}
_probe() { ${VERIFY_PORTS_PROBE_CMD:-_default_probe} "$@"; }

_default_local_addrs() { hostname 2>/dev/null; hostname -I 2>/dev/null | tr ' ' '\n'; }
_local_addrs() { ${VERIFY_PORTS_LOCAL_ADDRS_CMD:-_default_local_addrs}; }

# ── Parsing & scanning ────────────────────────────────────────────────────────

# Expand "22,80,8000-8010" to one port per line. Returns 1 on ANY unparseable
# entry — a partial expansion would silently shrink the scan and still say PASS.
expand_list() {
    local spec="$1" item lo hi p
    local -a items
    IFS=',' read -r -a items <<< "$spec"
    for item in "${items[@]}"; do
        [[ -z "$item" ]] && continue
        if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
            (( lo >= 1 && hi <= 65535 && lo <= hi )) || return 1
            for (( p = lo; p <= hi; p++ )); do echo "$p"; done
        elif [[ "$item" =~ ^[0-9]+$ ]] && (( item >= 1 && item <= 65535 )); then
            echo "$item"
        else
            return 1
        fi
    done
}

# Expand a spec into the named array, or report a usage error (return 2).
# An EMPTY spec ('' or ',') is a usage error too: `--allow ''` used to crash
# with the same exit code as a genuine exposure finding, and an empty --ports
# would be a vacuous pass over nothing.
parse_into() {
    local -n _out="$1"
    local what="$2" spec="$3" expanded=""
    expanded=$(expand_list "$spec") \
        || { err "ERROR: unparseable --$what spec: $spec"; return 2; }
    [[ -n "$expanded" ]] \
        || { err "ERROR: --$what expanded to no ports: '$spec'"; return 2; }
    mapfile -t _out < <(sort -n -u <<< "$expanded" | grep -vx '')
    [[ ${#_out[@]} -gt 0 ]] || { err "ERROR: --$what expanded to no ports: '$spec'"; return 2; }
}

# The off-host vantage IS the check: probing yourself returns an identical result
# for a loopback-bound and a world-bound service. That is how CFG-594 happened.
is_local_target() {
    local target="$1" addr
    case "$target" in localhost|127.0.0.1|0.0.0.0|::1) return 0 ;; esac
    while read -r addr; do
        [[ -n "$addr" && "$addr" == "$target" ]] && return 0
    done < <(_local_addrs)
    return 1
}

# Probe every port with bounded parallelism. Prints "<port> <state>" per line.
# Returns 1 if the scan could not run at all. A missing/empty per-port result
# reads as "noanswer" — unobserved — never as an implicit safe.
scan_ports() {
    local host="$1"; shift
    local workdir port launched=0 state
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/verifyports.XXXXXX") || return 1
    for port in "$@"; do
        _probe "$host" "$port" > "$workdir/$port" 2>/dev/null &
        launched=$(( launched + 1 ))
        (( launched % MAX_PARALLEL == 0 )) && wait
    done
    wait
    for port in "$@"; do
        state=$(tr -d '[:space:]' < "$workdir/$port" 2>/dev/null)
        printf '%s %s\n' "$port" "${state:-noanswer}"
    done
    rm -rf "$workdir"
}

# ── Main ──────────────────────────────────────────────────────────────────────

parse_args() {
    HOST=""; ALLOW_SPEC="$DEFAULT_ALLOW"; PORTS_SPEC="$DEFAULT_PORTS"; TIMEOUT=2
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --allow|--ports|--timeout)
                [[ $# -ge 2 ]] || { err "ERROR: $1 needs a value"; return 2; }
                case "$1" in
                    --allow) ALLOW_SPEC="$2" ;;
                    --ports) PORTS_SPEC="$2" ;;
                    --timeout)
                        [[ "$2" =~ ^[1-9][0-9]*$ ]] || { err "ERROR: --timeout must be a positive whole number: $2"; return 2; }
                        TIMEOUT="$2" ;;
                esac
                shift 2 ;;
            --help|-h) usage; return 10 ;;
            -*) err "ERROR: unknown option: $1"; usage >&2; return 2 ;;
            *)  [[ -z "$HOST" ]] || { err "ERROR: only one host may be given"; return 2; }
                HOST="$1"; shift ;;
        esac
    done
    [[ -n "$HOST" ]] || { err "ERROR: no target host given"; usage >&2; return 2; }
    [[ "$HOST" =~ ^[A-Za-z0-9._:-]+$ ]] || { err "ERROR: invalid host: $HOST"; return 2; }
}

main() {
    local rc=0; parse_args "$@" || rc=$?
    (( rc == 10 )) && return 0
    (( rc == 0 )) || return "$rc"

    local -a ports=() allow=()
    parse_into ports "ports" "$PORTS_SPEC" || return 2
    parse_into allow "allow" "$ALLOW_SPEC" || return 2
    local -A allowed=(); local p
    for p in "${allow[@]}"; do allowed["$p"]=1; done

    # A run that measured nothing must be self-identifying: if any probe/addr
    # seam is overridden, every line of the verdict says so.
    local seams="" SEAM_TAG=""
    [[ -n "${VERIFY_PORTS_PROBE_CMD:-}" ]] && seams+="VERIFY_PORTS_PROBE_CMD "
    [[ -n "${VERIFY_PORTS_LOCAL_ADDRS_CMD:-}" ]] && seams+="VERIFY_PORTS_LOCAL_ADDRS_CMD "
    if [[ -n "$seams" ]]; then
        SEAM_TAG=" [TEST SEAM — not a real measurement]"
        info "WARNING: TEST SEAM ACTIVE (${seams% }) — this run does NOT measure a real network."
    fi

    if is_local_target "$HOST"; then
        err "ERROR: '$HOST' is this machine. An on-host probe succeeds whether a service is"
        err "       bound to 127.0.0.1 or 0.0.0.0, so it cannot answer the exposure question"
        err "       at all. Run this from a DIFFERENT machine.$SEAM_TAG"
        return 4
    fi

    info "target: $HOST — probing ${#ports[@]} ports, allowlist: $(IFS=,; echo "${allow[*]}"), timeout ${TIMEOUT}s$SEAM_TAG"

    local scan_out=""
    scan_out=$(scan_ports "$HOST" "${ports[@]}") || {
        err "ERROR: the scan could not run (workdir creation failed) — NOTHING was measured.$SEAM_TAG"
        return 3
    }

    local state n_closed=0
    local -a unexpected=() allowed_open=() unanswered=()
    while read -r p state; do
        case "$state" in
            open)   if [[ -n "${allowed[$p]:-}" ]]; then allowed_open+=("$p"); else unexpected+=("$p"); fi ;;
            closed) n_closed=$(( n_closed + 1 )) ;;
            *)      unanswered+=("$p") ;;   # includes unrecognised probe output
        esac
    done <<< "$scan_out"

    local n=${#ports[@]} n_un=${#unanswered[@]} ok_list="none"
    (( ${#allowed_open[@]} > 0 )) && ok_list=$(IFS=,; echo "${allowed_open[*]}")
    info "observed — allowed-open: $ok_list; refused (closed): $n_closed; no answer: $n_un of $n$SEAM_TAG"

    if (( ${#unexpected[@]} > 0 )); then
        err "FAIL: $(IFS=,; echo "${unexpected[*]}") open on $HOST from off-host, not in the allowlist.$SEAM_TAG"
        err "      Anyone who can route here reaches these. Bind to 127.0.0.1 or firewall the"
        err "      port — vhost auth on :80/:443 does not cover a raw port."
        (( n_un > 0 )) && err "      Additionally $n_un of $n probed ports gave no answer and were never measured: $(IFS=,; echo "${unanswered[*]}")"
        return 1
    fi
    if (( n_un > 0 )); then
        err "INCONCLUSIVE: $n_un of $n probed ports on $HOST gave NO ANSWER: $(IFS=,; echo "${unanswered[*]}")$SEAM_TAG"
        err "      Silence is ambiguous from one vantage: 'target firewall drops it' (safe) and"
        err "      'this network's egress blocks it' (blind) look identical. Those ports'"
        err "      exposure was NEVER measured, so this is NOT a pass. Re-run from a vantage"
        err "      with unrestricted egress, or verify on-target: ss -tlnp + provider firewall."
        return 3
    fi
    info "PASS: $HOST — all $n probed ports observed, nothing unexpected open (allowed-open: $ok_list; refused: $n_closed).$SEAM_TAG"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
