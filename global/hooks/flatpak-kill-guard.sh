#!/usr/bin/env bash
# PreToolUse hook: refuse `flatpak kill <app-id>`.  CFG-412.
#
# `flatpak kill` takes an INSTANCE — a numeric instance id OR an application id — and given
# an application id it stops EVERY running instance of that app, not the one this session
# started. Recurring offense (lrn audit 2026-04-24, Finding B; MG strongly frustrated).
# The rule already sat in a machine file, which is not loaded at the moment
# someone types the command — a rule cannot fire where it is not loaded (CFG-695).
#
# BLOCKED: flatpak [opts] kill [opts] <app-id>, anywhere in the command — ssh payloads and
#          heredocs fed to ssh or a shell too (those bodies run).
# ALLOWED: a numeric instance id (kill-guard.sh judges whose instance it is), --help, an
#          unresolved target ($VAR — guards under-block, CFG-658), the string inside a commit
#          message or a heredoc written to a file, a command line that only reads/searches.
# ESCAPE HATCH: a `bash -c '…'` wrapper — the same deliberate, visible override
#          manifest-push-check.sh uses. It covers its own payload, not what follows it.
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
    *flatpak*kill*) ;;
    *) exit 0 ;;
esac

# Reading or searching for the string is not running it — when EVERY command on the line
# only reads (`cd x && grep …`, `grep … | head`). Keyed per command, not on the first word:
# `cat log; flatpak kill <app-id>` runs the kill. A $(…) or `…` that mentions flatpak runs.
# Quoted strings become Q before the line is split at ; | & ( ), read the way the shell
# reads them: whichever quote opens first governs (the ' in "it's" is not a quote), a
# backslash escapes one character (outside '…'), and $'…' honours \'. Like bash, it joins a
# \<newline> before it looks past a $, and reads $$ (the PID) as one token, so $$'…' is a
# plain '…' that no backslash escapes. A line this cannot
# read for certain is not exempt: an unclosed quote, a word that starts with # (a comment's
# apostrophes are not quotes, but inside ${…} a # is no comment at all), or a heredoc (its
# body is text, not shell words — the scan below knows which bodies run).
_ro=1
case "$CMD" in *'$('*flatpak*|*'`'*flatpak*) _ro=0 ;; esac
printf '%s' "$CMD" | grep -qE '(^|[^<])<<[^<]' && _ro=0
if [ "$_ro" -eq 1 ] && _words=$(printf '%s\n' "$CMD" | awk '
        { s = s (NR > 1 ? "\n" : "") $0 }
        END {
            n = length(s); out = ""; m = ""; ws = 1
            for (i = 1; i <= n; i++) {
                c = substr(s, i, 1)
                if (m == "s") { if (c == "\047") m = ""; continue }
                if (m != "") {                  # "…" and ANSI-C $-quotes: a backslash escapes one char
                    if (c == "\\") i++
                    else if ((m == "d" && c == "\"") || (m == "a" && c == "\047")) m = ""
                    continue
                }
                if (c == "\\") { if (substr(s, i + 1, 1) != "\n") { out = out "E"; ws = 0 }; i++; continue }
                if (c == "#" && ws) exit 1              # a comment, or not (${a:- #b}): unreadable
                if (c == "\047") { m = "s"; out = out "Q"; ws = 0; continue }
                if (c == "\"") { m = "d"; out = out "Q"; ws = 0; continue }
                if (c == "$") {                 # bash joins \<newline> first, then reads $$ as one token
                    j = i + 1
                    while (substr(s, j, 2) == "\\\n") j += 2
                    if (substr(s, j, 1) == "$") { out = out "$$"; i = j; ws = 0; continue }
                    if (substr(s, j, 1) == "\047") { m = "a"; i = j; out = out "Q"; ws = 0; continue }
                }
                out = out c
                ws = (c ~ /[ \t\n;&|()<>]/)
            }
            if (m != "") exit 1
            print out
        }'); then
    while IFS= read -r _cl; do
        _cl="${_cl#"${_cl%%[![:space:]]*}"}"
        [ -z "$_cl" ] && continue
        case "$_cl" in
            grep\ *|rg\ *|ag\ *|ack\ *|cat\ *|less\ *|head|head\ *|tail|tail\ *|awk\ *|sed\ *) ;;
            cd|cd\ *|echo|echo\ *|printf\ *|wc|wc\ *|sort|sort\ *|uniq|uniq\ *) ;;
            # git's readers only — bisect run, rebase -x, submodule foreach and -c alias run commands.
            git\ *) [[ "$_cl" =~ ^git([[:space:]]+(-C[[:space:]]+[^[:space:]]+|--no-pager))*[[:space:]]+(log|show|diff|grep|status|blame|shortlog)([[:space:]]|$) ]] \
                        || { _ro=0; break; } ;;
            *) _ro=0; break ;;
        esac
    done <<EOF
$(printf '%s\n' "$_words" | tr ';|&()' '\n\n\n\n\n')
EOF
else
    _ro=0
fi
[ "$_ro" -eq 1 ] && exit 0

# What is data, not a command:
#  - a heredoc body, UNLESS the pipeline it feeds runs it (ssh, a shell, sudo/su, eval,
#    source): `git commit -F - <<EOF` and `cat > f <<EOF` are data, `ssh deck <<EOF`,
#    `ssh deck bash -s <<EOF`, `bash <<EOF` and `cat <<EOF | ssh deck sh` are not.
#    A `<<` inside $(( … )) is a shift and `<<<` is a here-string — neither opens one.
#  - -m/--message strings (a commit message describing the command is not the command).
#  - the payload of the `bash -c '…'` escape hatch: a deliberate "yes, every instance".
_scan=$(printf '%s\n' "$CMD" \
    | awk '
        inhd {
            t = $0; sub(/^[ \t]+/, "", t)
            if (t == d) { inhd = 0; next }
            if (exe) print
            next
        }
        { print }
        {
            line = $0
            gsub(/\$\(\([^)]*\)\)/, "", line)
            if (match(line, /(^|[^<])<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
                pre = substr(line, 1, RSTART); post = substr(line, RSTART + RLENGTH)
                d = substr(line, RSTART, RLENGTH); sub(/^[^<]?<<-?[ \t]*["\047]?/, "", d)
                n1 = split(pre, a, /;|&&|\|\||&/); split(post, b, /;|&&|\|\||&/)
                p = a[n1] " " b[1]; gsub(/["\047]/, " ", p)
                exe = (p ~ /(^|[ \t\/(])(ssh|bash|sh|zsh|dash|ksh|mksh|fish|sudo|doas|su|pkexec|eval|source)([ \t]|$)/)
                inhd = 1
            }
        }' \
    | sed -E 's/(^|[[:space:]])(-m|--message)(=|[[:space:]]+)"[^"]*"/\1/g' \
    | sed -E "s/(^|[[:space:]])(-m|--message)(=|[[:space:]]+)'[^']*'/\\1/g" \
    | sed -E "s/(^|[;&|(\`[:space:]])bash[[:space:]]+-c[[:space:]]+'[^']*'/\\1/g" \
    | sed -E 's/(^|[;&|(`[:space:]])bash[[:space:]]+-c[[:space:]]+"[^"]*"/\1/g')

# Each flatpak … kill … <target> invocation, up to a separator or a closing quote. Quoted
# targets ('org.x.Y') are unwrapped below. Covers ssh '…' payloads for free.
_invs=$(printf '%s' "$_scan" \
    | grep -oE '(^|[^A-Za-z0-9_.-])flatpak([[:space:]]+-[^[:space:]]+)*[[:space:]]+kill([[:space:]]+-[^[:space:]]+)*[[:space:]]+["'"'"']?[^;&|)"'"'"'[:space:]]+' \
    || true)
[ -z "$_invs" ] && exit 0

_app=""
while IFS= read -r _inv; do
    [ -z "$_inv" ] && continue
    case "$_inv" in *--help*|*' -h'|*' -h '*) continue ;; esac
    _t=$(printf '%s' "$_inv" | awk '{print $NF}' | sed "s/^['\"]//; s/['\"]\$//")
    case "$_t" in
        ''|-*) continue ;;
        \$*|\`*|*'$('*|'<'*) continue ;;   # unresolved or a <placeholder> → under-block
        *[!0-9]*) _app="$_t"; break ;; # an application id: every instance
        *) continue ;;                 # numeric instance id: exactly one
    esac
done <<EOF
$_invs
EOF

[ -z "$_app" ] && exit 0

cat >&2 <<BLOCKED_MSG
BLOCKED: \`flatpak kill $_app\` stops EVERY running instance of $_app — not just the one
this session started.

\`flatpak kill\` accepts an instance id or an application id, and an application id means
all of them. This is a recurring foot-gun (lrn audit 2026-04-24): it has taken down
instances somebody else was using.

Kill the one instance you mean, by PID:

  flatpak ps --columns=instance,pid,application   # find it
  kill <PID>                                       # the PID from your launcher log / flatpak ps

or stop exactly one instance by its id: flatpak kill <instance-id>

(kill-guard.sh checks either way that the instance is one this session started.)

If you really do mean every instance of $_app, say so explicitly:

  bash -c 'flatpak kill $_app'
BLOCKED_MSG
exit 2
