#!/usr/bin/env bash
# dev-browser-close.sh — SessionEnd hook: close the dev browser this session opened.
#
# Owner's order (lrn, 2026-11-11): at the latest at shutdown, every session closes each dev browser
# tab it opened — never the owner's own Chrome tabs. The dev browser is the Chrome the Playwright MCP
# server launched: claude → `npm exec @playwright/mcp` → `sh -c playwright-mcp` → node playwright-mcp
# → chrome MAIN process (no --type=) with --user-data-dir=$HOME/.cache/ms-playwright-mcp/mcp-chrome-
# <sha256(project root)[:7]>. Its helpers (--type=zygote|renderer|utility|gpu-process) die with it,
# and Chrome closes every window and tab on SIGTERM.
# A browser MAIN process on such a profile qualifies when (1) it is a descendant of this session's
# claude process, or (2) its profile is the one hashed from that claude's cwd AND no live claude is
# above it (reparented after the MCP server died). A browser under a DIFFERENT live claude, one on any
# other profile, and the owner's Chrome are never touched. Walks /proc — no `pkill -f` (CFG-597).
# Never reads stdin, always exits 0, one log line per action.
# Test knobs: DBC_PROC_ROOT (default /proc), DBC_KILL_CMD (default kill), DBC_START_PID ($PPID).
set +e
PROC="${DBC_PROC_ROOT:-/proc}"
KILL="${DBC_KILL_CMD:-kill}"
START="${DBC_START_PID:-$PPID}"
PROFILE_ROOT="$HOME/.cache/ms-playwright-mcp"
LOG="$HOME/.claude/logs/dev-browser-close.log"

log() {
    mkdir -p "${LOG%/*}" 2>/dev/null
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true
}
# stat_fields <pid> — sets ST to the stat fields after the comm (which may hold spaces and ')').
# Grouped so a failed `<` — the SHELL's error — stays silent for an entry that vanished mid-scan.
stat_fields() { { read -r ST < "$PROC/$1/stat"; } 2>/dev/null || return 1; ST="${ST##*) }"; }
ppid_of() { stat_fields "$1" || return 1; set -- $ST; echo "$2"; }
# read_cmd <pid> — sets CMD to the space-joined argv (builtin, no fork; fails when unreadable).
read_cmd() { local a; { mapfile -t -d '' a < "$PROC/$1/cmdline"; } 2>/dev/null || return 1; CMD="${a[*]}"; }
alive() { "$KILL" -0 "$1" 2>/dev/null && stat_fields "$1" && [ "${ST%% *}" != "Z" ]; }
# is_claude <pid> — the Claude Code process: the native binary (…/claude-code/bin/claude.exe, or an
# argv[0]/exe named claude) or the npm CLI (node …/@anthropic-ai/claude-code/cli.js). Deliberately
# NOT a bare `*claude*` substring: this hook's own shells run from ~/.claude/hooks/.
is_claude() {
    local exe a0; read_cmd "$1" || CMD=""; exe="$(readlink "$PROC/$1/exe" 2>/dev/null)"
    case " $exe $CMD" in *claude-code/bin/claude*|*@anthropic-ai/claude-code/cli.js*) return 0 ;; esac
    for a0 in "${CMD%% *}" "$exe"; do case "${a0##*/}" in claude|claude.exe) return 0 ;; esac; done
    return 1
}
# claudes_above <pid> — every claude process at or above <pid>, nearest first (none = reparented).
claudes_above() {
    local p="$1" n=0
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$n" -lt 64 ]; do
        is_claude "$p" && echo "$p"
        p="$(ppid_of "$p")" || return 0; n=$((n + 1))
    done
}
# dev_profile <pid> — sets PROF when <pid> is a browser MAIN process (no --type=) on an MCP profile.
dev_profile() {
    read_cmd "$1" || return 1
    case "$CMD" in *" --type="*) return 1 ;; esac
    case "$CMD" in *" --user-data-dir=$PROFILE_ROOT/"*) ;; *) return 1 ;; esac
    PROF="${CMD#* --user-data-dir=}"; PROF="${PROF%% *}"
}

claude="$(claudes_above "$START" | head -1)"
[ -n "$claude" ] || { log "start=$START no claude ancestor — nothing to close"; exit 0; }
cwd="$(readlink "$PROC/$claude/cwd" 2>/dev/null)"; want=""         # the cwd exactly as reported
[ -n "$cwd" ] && want="$PROFILE_ROOT/mcp-chrome-$(printf '%s' "$cwd" | sha256sum | cut -c1-7)"
declare -A profile; targets=""
for d in "$PROC"/[0-9]*; do
    pid="${d##*/}"; dev_profile "$pid" || continue
    chain=" $(claudes_above "$pid" | tr '\n' ' ')"
    case "$chain" in *" $claude "*) ;; " ") [ -n "$want" ] && [ "$PROF" = "$want" ] || continue ;; *) continue ;; esac
    targets="$targets $pid"; profile[$pid]="$PROF"
done
[ -n "$targets" ] || { log "claude=$claude cwd=$cwd no dev browser — nothing to close"; exit 0; }

for pid in $targets; do "$KILL" -TERM "$pid" 2>/dev/null; done
left="$targets"
for _ in $(seq 1 15); do                                  # ≤ 3 s, well inside the SessionEnd budget
    rem=""; for pid in $left; do alive "$pid" && rem="$rem $pid"; done
    left="$rem"; [ -n "$left" ] || break; sleep 0.2
done
for pid in $targets; do
    case " $left " in *" $pid "*) continue ;; esac
    log "claude=$claude pid=$pid profile=${profile[$pid]} result=closed-on-sigterm"
done
for pid in $left; do
    "$KILL" -KILL "$pid" 2>/dev/null; sleep 0.2
    if alive "$pid"; then r=survived-sigkill; else r=killed-with-sigkill; fi
    log "claude=$claude pid=$pid profile=${profile[$pid]} result=$r"
done
exit 0
