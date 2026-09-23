#!/usr/bin/env bash
# PreToolUse hook: refuse `pkill -f` / `pgrep -f` whose pattern can match the command
# carrying it.  CFG-597 / CFG-693.
#
# `-f` matches against the FULL command line of every process. The shell running the pkill
# has that pattern in its own argv, so the pattern matches its own shell — and pkill kills
# it. Measured 2026-09-23: `ssh … 'pkill -f cru181_body_over_wifi.py'` killed its own remote
# shell; robot telemetry was down ~1 min. The same defect was recorded 11 days earlier,
# filed as a RULE change, and parked behind a consent step nobody ever requested. The
# knowledge that prevents it lives in on-demand files that are never loaded at the moment
# someone types pkill, which is why this is a hook: a rule cannot fire where it is not
# loaded.
#
# The same mechanism has a quieter half — `until ! pgrep -f <pat>` never sees a job finish,
# because the loop's own shell keeps matching.
#
# BLOCKED: pkill/pgrep with -f (or --full) and a bare pattern.
# ALLOWED: a self-excluding character class ([c]ru181), -x, no -f at all, --help, and
#          searching for the literal string with grep and friends.
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

# Fast path.
case "$CMD" in
    *pkill*|*pgrep*) ;;
    *) exit 0 ;;
esac

# Reading or searching for the string is not running it. Deliberately keyed on the FIRST
# word, so `grep -rn 'pkill -f' docs/` passes while `grep x y; pkill -f z` does not.
case "$CMD" in
    grep\ *|rg\ *|ag\ *|ack\ *|cat\ *|less\ *|head\ *|tail\ *|awk\ *|sed\ *) exit 0 ;;
esac

# Each pkill/pgrep invocation and its arguments, up to a shell separator or a closing
# quote. Covers payloads inside ssh '…' and bash -c "…" for free: the text is still there.
_offenders=$(printf '%s' "$CMD" \
    | grep -oE '(pkill|pgrep)([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^;&|)"'"'"']+' || true)
[ -z "$_offenders" ] && exit 0

_bad_pattern=""
while IFS= read -r _inv; do
    [ -z "$_inv" ] && continue
    case "$_inv" in *--help*|*' -h '*) continue ;; esac

    # -f / --full present? Includes clusters such as -9f and -af.
    _has_f=0
    printf '%s' "$_inv" | grep -qE '(^|[[:space:]])--full([[:space:]]|$)' && _has_f=1
    printf '%s' "$_inv" | grep -qE '(^|[[:space:]])-[A-Za-z0-9]*f[A-Za-z0-9]*([[:space:]]|$)' && _has_f=1
    [ "$_has_f" -eq 0 ] && continue

    # -x matches exactly rather than as a substring, so it cannot catch a longer argv.
    printf '%s' "$_inv" | grep -qE '(^|[[:space:]])(-[A-Za-z0-9]*x[A-Za-z0-9]*|--exact)([[:space:]]|$)' && continue

    # The pattern is the first non-option token after the command word.
    _pat=$(printf '%s' "$_inv" \
        | sed -E 's/^(pkill|pgrep)//' \
        | tr ' ' '\n' | grep -v '^$' | grep -v '^-' | head -1 \
        | sed "s/^['\"]//; s/['\"]$//")
    [ -z "$_pat" ] && continue

    # A bracket expression makes the pattern not match its own literal text.
    case "$_pat" in *\[?\]*) continue ;; esac

    _bad_pattern="$_pat"
    break
done <<EOF
$_offenders
EOF

[ -z "$_bad_pattern" ] && exit 0

# Rewrite THEIR pattern, not a generic example — the fix should be copy-pasteable.
_first=$(printf '%s' "$_bad_pattern" | cut -c1)
_rest=$(printf '%s' "$_bad_pattern" | cut -c2-)
_safe="[${_first}]${_rest}"

cat >&2 <<BLOCKED_MSG
BLOCKED: \`pkill -f $_bad_pattern\` matches the command line of the shell running it.

\`-f\` matches every process's FULL argv, and this shell's argv contains the pattern — so
the pattern matches its own shell and pkill kills it. On 2026-09-23 exactly this killed an
ssh session mid-task and took robot telemetry down for a minute. With pgrep the same
mechanism is quieter: \`until ! pgrep -f $_bad_pattern\` never exits, because the loop keeps
matching itself.

Use the self-excluding character class — same match, cannot match its own literal text:

  pkill -f '$_safe'
  pgrep -f '$_safe'

Other safe forms: \`-x\` (exact match, not substring), or drop \`-f\` to match the process
NAME instead of the full command line.

Better still, if you started the process: kill the PID you recorded at launch. A session
should only kill what it can prove it started (CFG-694).
BLOCKED_MSG
exit 2
