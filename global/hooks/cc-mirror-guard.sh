#!/usr/bin/env bash
# PreToolUse hook: refuse the cc-mirror verbs that RE-PROVISION a variant.
#
# 2026-09-23: `cc-mirror update mclaude --claude-version latest --no-tweak` — the command
# global/CLAUDE.md itself documented — resolved bare `cc-mirror` on PATH to a Windows-
# installed cc-mirror 1.6.2 whose bundle contains ZERO occurrences of `claude-version`.
# The flag was silently ignored; the variant was re-provisioned from its `claudeOrig` pin
# (unchanged since 2026-02-09); Claude Code went 2.1.274 -> 2.1.1; the launcher was rewritten
# to `exec node .../cli.js`, which modern versions do not ship, leaving `mclaude` dead; and
# it exited 0. docs/decisions.md:329 already forbade in-session updates. Fixing the runbook
# is advisory — an agent can still type the command. This hook is the fence.
#
# BLOCKED: update | create | quick | remove  (the verbs that write a variant)
# ALLOWED: list | doctor | tasks | --help, anything under the ~/.cc-mirror DIRECTORY, and
#          setup/scripts/cc-update.sh, which is the sanctioned route and may call cc-mirror
#          itself in its pinned `--via` form.
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

# Fast path: nothing to do unless the literal tool name appears at all.
case "$CMD" in
    *cc-mirror*) ;;
    *) exit 0 ;;
esac

# The sanctioned wrapper owns this operation, including its pinned `--via cc-mirror` form.
case "$CMD" in
    *cc-update.sh*) exit 0 ;;
esac

# Match the COMMAND, never the path. The install lives at ~/.cc-mirror/, so a path match
# would refuse routine work on every Bash call fleet-wide — `cat ~/.cc-mirror/…`,
# `npm install` into the mirror (the repair path), `ls`, and so on.
#   - `cc-mirror <verb>` at a command position (start, or after ; & | && || or a pipe)
#   - `npx [-y] cc-mirror[@ver] <verb>`
# A preceding `/` or `.` (as in `~/.cc-mirror/`) is therefore NOT a command position.
_verb_re='(update|create|quick|remove)'
_blocked=0

if printf '%s' "$CMD" | grep -qE "(^|[;&|(]|&&|\|\||[[:space:]])cc-mirror[[:space:]]+(-[^[:space:]]+[[:space:]]+)*${_verb_re}([[:space:]]|$)"; then
    _blocked=1
fi
if printf '%s' "$CMD" | grep -qE "npx[[:space:]]+(-y[[:space:]]+)?cc-mirror(@[^[:space:]]+)?[[:space:]]+(-[^[:space:]]+[[:space:]]+)*${_verb_re}([[:space:]]|$)"; then
    _blocked=1
fi

# A command EXECUTOR carrying the verb as a quoted payload. This is how it actually ran on
# 2026-09-23 — `tmux-launch.sh <name> "<label>" --log <f> "cc-mirror update …"` — where the
# verb sits inside quotes and so is never at a command position in the outer string.
# Deliberately an explicit executor list rather than "any quoted occurrence": the latter
# would refuse `grep 'cc-mirror update' CLAUDE.md`, and searching for the string is not
# running it.
if printf '%s' "$CMD" | grep -qE '(tmux-launch\.sh|tmux[[:space:]]+new-session|(bash|sh|zsh)[[:space:]]+-c|eval|nohup|setsid|timeout[[:space:]]|env[[:space:]])' \
   && printf '%s' "$CMD" | grep -qE "cc-mirror(@[^[:space:]]+)?[[:space:]]+(-[^[:space:]]+[[:space:]]+)*${_verb_re}([[:space:]\"']|$)"; then
    _blocked=1
fi

# `--help` on any verb mutates nothing.
case "$CMD" in
    *--help*|*' -h'*) _blocked=0 ;;
esac

[ "$_blocked" -eq 0 ] && exit 0

cat >&2 <<'BLOCKED_MSG'
BLOCKED: `cc-mirror update|create|quick|remove` RE-PROVISIONS the variant — it does not
merely bump a version. On 2026-09-23 this exact command downgraded Claude Code from
2.1.274 to 2.1.1, rewrote the launcher to an entry point that no longer exists (leaving
`mclaude` dead), and exited 0.

Use the fleet's wrapper, which pins the installer, refuses a downgrade, verifies the
result and rolls back on failure:

  bash ~/cfg-agent-fleet/setup/scripts/cc-update.sh --version <x.y.z>

Run it from a plain shell AFTER `/exit` — never inside a session. It guards on
CLAUDE_CONFIG_DIR and will refuse; that refusal is the point (docs/decisions.md:329).

Read-only cc-mirror verbs (list, doctor, tasks, --help) are not blocked.
BLOCKED_MSG
exit 2
