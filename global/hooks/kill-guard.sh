#!/usr/bin/env bash
# PreToolUse hook: a session may only kill what it can PROVE it started.  CFG-694.
#
# MG, 2026-09-23: "you need to learn some control and discipline when killing processes
# before you kill something important by mistake!!!" — and, on a proposal that he approve
# kills by PID: "did you think i would know processes by PID?? ridiculous, do better —
# this is cfg job". So no human is in the loop here; ownership is proved mechanically.
#
# Two proofs count:
#   1. SAME SESSION — the target shares this hook's session id, i.e. it descends from the
#      same shell tree the Bash tool runs in.
#   2. REGISTERED — a fleet launcher wrote it down at launch (setup/scripts/launch-registry.sh).
#      Needed because a tmux pane is a child of the TMUX SERVER, not of the session that
#      asked for it, so ownership of detached work is not visible in the process tree.
#
# Everything else is refused, and the refusal lists what this session may actually kill.
#
# It deliberately UNDER-blocks: a target it cannot resolve (a variable, a command
# substitution, a job spec) is allowed through, exactly as cfg-boundary-guard does. A guard
# that blocks legal work gets switched off, and takes its working half with it (CFG-658).
# `pkill -f` self-matching is a different defect with its own hook (pkill-guard.sh).
# Exit 2 = block. Exit 0 = allow.

INPUT=$(cat)

case "$INPUT" in
    *'"tool_name":"Bash"'*|*'"tool_name": "Bash"'*) ;;
    *) exit 0 ;;
esac

CMD=""
if command -v jq >/dev/null 2>&1; then
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
fi
if [ -z "$CMD" ]; then
    CMD=$(printf '%s' "$INPUT" | grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
          | sed 's/.*"command"[^"]*"\([^"]*\)"/\1/')
fi
[ -z "$CMD" ] && exit 0

case "$CMD" in
    *kill*) ;;
    *) exit 0 ;;
esac

# Reading or searching for the word is not running it.
case "$CMD" in
    grep\ *|rg\ *|ag\ *|ack\ *|cat\ *|less\ *|head\ *|tail\ *|awk\ *|sed\ *) exit 0 ;;
esac

_REG="${CC_LAUNCH_REGISTRY_LIB:-}"
if [ -z "$_REG" ]; then
    for _c in "$HOME/cfg-agent-fleet/setup/scripts/launch-registry.sh" \
              "$HOME/agent-fleet/setup/scripts/launch-registry.sh"; do
        [ -f "$_c" ] && { _REG="$_c"; break; }
    done
fi
# No registry library reachable → this hook cannot prove anything. Allow rather than
# block every kill on a machine that has not deployed it yet.
[ -n "$_REG" ] && [ -f "$_REG" ] || exit 0
# shellcheck disable=SC1090
. "$_REG"

_our_sid=$(ps -o sid= -p $$ 2>/dev/null | tr -d ' ')

_is_ours() {  # <pid> → 0 when this session may kill it
    local pid="$1" sid
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac   # unresolvable → allow (under-block)
    [ "$pid" = "$$" ] && return 0
    sid=$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$_our_sid" ] && [ "$sid" = "$_our_sid" ] && return 0
    registry_has "$pid" && return 0
    return 1
}

_targets=""     # resolved pids we are not allowed to kill
_how=""         # how they were named, for the message

# `flatpak kill` is not kill(1): its argument is a flatpak INSTANCE id (or an app id, which
# flatpak-kill-guard.sh refuses), never a PID. Read as `kill <pid>`, an instance id is a pid
# nobody owns, so the kill-one-instance form flatpak-kill-guard recommends was always
# refused (CFG-412 review). Take those out of the kill(1) scan and judge them below.
_FK_RE='(^|[^A-Za-z0-9_.-])flatpak([[:space:]]+-[^[:space:]]+)*[[:space:]]+kill'
_kcmd=$(printf '%s \n' "$CMD" | sed -E "s/${_FK_RE}([[:space:]])/\\1flatpak_kill\\3/g")

# ── kill [-SIG] <pid>… ────────────────────────────────────────────────────────
# -0 probes without signalling and -l only lists names: neither kills anything.
if printf '%s' "$_kcmd" | grep -qE '(^|[;&|(]|&&|\|\||[[:space:]])kill([[:space:]]|$)' \
   && ! printf '%s' "$_kcmd" | grep -qE '(^|[[:space:]])kill[[:space:]]+(-0|-l|-L)([[:space:]]|$)'; then
    _seg=$(printf '%s' "$_kcmd" | grep -oE '(^|[;&|[:space:]])kill([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^;&|)]+' | head -1)
    for _t in $(printf '%s' "$_seg" | sed -E 's/^[^k]*kill//' | tr ' ' '\n'); do
        case "$_t" in
            ''|-*|%*|\$*|\`*|*'$('*) continue ;;   # flags, job specs, anything unresolved
            *[!0-9]*) continue ;;
        esac
        _is_ours "$_t" || { _targets="$_targets $_t"; _how="kill"; }
    done
fi

# ── pkill / killall <name-or-pattern> ─────────────────────────────────────────
# Resolve what they would actually hit, read-only, and judge those pids.
if printf '%s' "$CMD" | grep -qE '(^|[;&|(]|&&|\|\||[[:space:]])(pkill|killall)([[:space:]]|$)'; then
    _pat=$(printf '%s' "$CMD" \
        | grep -oE '(pkill|killall)([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^;&|)"'"'"']+' | head -1 \
        | sed -E 's/^(pkill|killall)//' \
        | tr ' ' '\n' | grep -v '^$' | grep -v '^-' | head -1 \
        | sed "s/^['\"]//; s/['\"]$//")
    case "$_pat" in ''|*'$'*|*'`'*) _pat="" ;; esac   # unresolved → under-block
    if [ -n "$_pat" ]; then
        _pf=""
        printf '%s' "$CMD" | grep -qE '(^|[[:space:]])-[A-Za-z0-9]*f[A-Za-z0-9]*([[:space:]]|$)|--full' && _pf="-f"
        for _t in $(pgrep $_pf -- "$_pat" 2>/dev/null); do
            [ "$_t" = "$$" ] && continue
            _is_ours "$_t" || { _targets="$_targets $_t"; _how="${_how:-name}"; }
        done
    fi
fi

# ── flatpak kill <instance-id> ────────────────────────────────────────────────
# Judge the process the instance resolves to — the one flatpak will signal — read-only via
# `flatpak ps`, the way pkill's pattern is resolved above. An id flatpak does not know
# kills nothing (flatpak fails on its own); a quoted ssh payload is not resolved locally.
_fk_ids=$(printf '%s \n' "$CMD" \
    | grep -oE "${_FK_RE}([[:space:]]+-[^[:space:]]+)*[[:space:]]+[0-9]+[[:space:];&|)]" \
    | grep -oE '[0-9]+[[:space:];&|)]$' | tr -dc '0-9\n' | sort -u)
_fk_note=""
if [ -n "$_fk_ids" ]; then
    _fk_ps=$(flatpak ps --columns=instance,pid 2>/dev/null)
    for _id in $_fk_ids; do
        _pid=$(printf '%s\n' "$_fk_ps" | awk -v id="$_id" '$1 == id && $2 ~ /^[0-9]+$/ { print $2; exit }')
        [ -n "$_pid" ] || continue
        _is_ours "$_pid" && continue
        _targets="$_targets $_pid"; _how="${_how:-flatpak}"
        _fk_note="$_fk_note  (flatpak instance $_id is pid $_pid)
"
    done
fi

_targets=$(printf '%s' "$_targets" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
[ -z "$(printf '%s' "$_targets" | tr -d ' ')" ] && exit 0

{
    printf 'BLOCKED: this session cannot prove it started the process(es) it is about to kill.\n\n'
    printf 'Target(s) that are neither in this session'"'"'s process tree nor in the launch registry:\n'
    for _p in $_targets; do
        printf '  %-8s %s\n' "$_p" "$(ps -o args= -p "$_p" 2>/dev/null | cut -c1-90)"
    done
    [ -n "$_fk_note" ] && printf '%s' "$_fk_note"
    printf '\nThree kills in one night (2026-09-23) picked their target by NAME rather than by\n'
    printf 'OWNERSHIP: an ssh pkill that matched its own shell, a stop script that had recorded a\n'
    printf 'subshell'"'"'s pid instead of the service'"'"'s, and a cleanup that killed every `sleep 300`\n'
    printf 'on the box. The third was correct by luck.\n\n'
    printf 'What this session MAY kill — its own descendants, plus these registered launches:\n'
    _l=$(registry_list 2>/dev/null)
    if [ -n "$_l" ]; then printf '%s\n' "$_l"; else printf '  (nothing registered)\n'; fi
    printf '\nIf a fleet launcher started it, kill it the way it was started —\n'
    printf '  tmux kill-session -t=<name>     (note -t=, not -t: -t PREFIX-matches)\n'
    printf 'If you started it in this session, kill the pid you recorded at launch.\n'
    printf 'If it is somebody else'"'"'s process, it is not yours to kill.\n'
} >&2
exit 2
