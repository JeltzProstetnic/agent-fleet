#!/usr/bin/env bash
# afleet-ide.sh — "IDE terminal" mode for the fleet launcher (CFG-991 step 1).
#
# Claude Code connects to a VS Code or JetBrains IDE through a lock file the IDE's
# Claude Code extension writes (`<lock dir>/<port>.lock`, JSON: pid, ideName,
# workspaceFolders, runningInWindows, authToken) and a WebSocket on that port. The
# CLI searches, in order: `<CLAUDE_CONFIG_DIR>/ide`; `~/.claude/ide` when the variable
# is set (an IDE started without it writes there); on WSL also every Windows profile's
# `.claude/ide` (`%USERPROFILE%` and `/mnt/c/Users/*`). A lock is valid for a session
# when the session's folder lies inside one of the IDE's workspace folders.
#
# This library reproduces that discovery so the launcher can SAY what the CLI will find
# before it starts (`af --ide`, `af ide status`) and so a test can prove discovery under
# a non-default config dir and the WSL path with a fake lock file and a WebSocket stub —
# no IDE installed. It writes nothing except `autoConnectIde` in the global config, and
# only when the user runs `af ide autoconnect on` (opt-in; `af` itself is unchanged).
#
# Two ways in: sourced (functions only) or run as a CLI (bottom). Every path it reads
# can be overridden for tests through AFLEET_IDE_* variables; none is printed with a
# token. The auth token leaves this process only on the loopback probe, as the CLI
# sends it.

# ── Where the CLI looks ───────────────────────────────────────────────────────

# The config dir the launched Claude Code will use: the launcher's mclaude exports
# CLAUDE_CONFIG_DIR itself, so `af`'s own shell usually has it unset.
afleet_ide_config_dir() {
    if [[ -n "${AFLEET_IDE_CONFIG_DIR:-}" ]]; then printf '%s\n' "$AFLEET_IDE_CONFIG_DIR"; return; fi
    if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then printf '%s\n' "$CLAUDE_CONFIG_DIR"; return; fi
    local mirror="${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}/config"
    if [[ -d "$mirror" ]]; then printf '%s\n' "$mirror"; else printf '%s\n' "$HOME/.claude"; fi
}

afleet_ide_is_wsl() {
    case "${AFLEET_IDE_WSL:-}" in 1) return 0 ;; 0) return 1 ;; esac
    [[ -n "${WSL_DISTRO_NAME:-}" ]] && return 0
    grep -qi microsoft /proc/version 2>/dev/null
}

# `C:\Users\acme\proj` or `C:/Users/acme/proj` → `/mnt/c/Users/acme/proj`; anything else
# passes through. Pure bash: wslpath is not on every box and a test needs its own mount root.
_afleet_ide_win2wsl() {
    local p="${1//\\//}" mnt="${AFLEET_IDE_WIN_MNT:-/mnt}" drive
    if [[ "$p" =~ ^([A-Za-z]):(/.*)?$ ]]; then
        drive="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
        p="$mnt/$drive${BASH_REMATCH[2]:-}"
    fi
    p="${p%/}"
    printf '%s\n' "${p:-/}"
}

# The lock dirs in the CLI's search order, each once. Windows profile dirs appear only
# when they exist (the CLI globs them the same way).
afleet_ide_lock_dirs() {
    local cfg seen=$'\n' d prof
    cfg="$(afleet_ide_config_dir)"
    _afleet_ide_emit() { [[ "$seen" == *$'\n'"$1"$'\n'* ]] && return; seen+="$1"$'\n'; printf '%s\n' "$1"; }
    _afleet_ide_emit "$cfg/ide"
    [[ "$cfg" != "$HOME/.claude" ]] && _afleet_ide_emit "$HOME/.claude/ide"
    if afleet_ide_is_wsl; then
        if [[ -n "${USERPROFILE:-}" ]]; then
            prof="$(_afleet_ide_win2wsl "$USERPROFILE")"
            [[ -d "$prof/.claude/ide" ]] && _afleet_ide_emit "$prof/.claude/ide"
        fi
        for d in "${AFLEET_IDE_WIN_USERS:-/mnt/c/Users}"/*/.claude/ide; do
            [[ -d "$d" ]] && _afleet_ide_emit "$d"
        done
    fi
    return 0
}

_afleet_ide_dir_is_windows() { [[ "$1" == "${AFLEET_IDE_WIN_MNT:-/mnt}/"* ]]; }

# The IDE terminal we run in, by the variables the CLI itself reads: vscode | jetbrains.
afleet_ide_terminal() {
    if [[ "${TERM_PROGRAM:-}" == "vscode" ]]; then echo vscode; return 0; fi
    if [[ "${TERMINAL_EMULATOR:-}" == "JetBrains-JediTerm" ]]; then echo jetbrains; return 0; fi
    return 1
}

# ── Is the IDE behind a lock file still there? ───────────────────────────────

# One WebSocket handshake on loopback, as the CLI opens it. Runs in the caller's $(…)
# subshell: a refused connection makes `exec` end this subshell, nothing more.
_afleet_ide_handshake() {   # <port> <token> — prints the HTTP status line, or nothing
    local port="$1" token="$2" key line=""
    exec 3<>"/dev/tcp/127.0.0.1/$port" 2>/dev/null || exit 1
    key="$(head -c 16 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -d '\n')"
    printf 'GET / HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: %s\r\n' \
        "$port" "${key:-YWZsZWV0LWlkZS1wcm9iZQ==}" >&3
    [[ -n "$token" ]] && printf 'X-Claude-Code-Ide-Authorization: %s\r\n' "$token" >&3
    printf '\r\n' >&3
    IFS= read -r -t "${AFLEET_IDE_PROBE_TIMEOUT:-3}" line <&3 2>/dev/null || true
    exec 3>&- 3<&-
    printf '%s' "${line%$'\r'}"
}

# live = the port answers the handshake with 101; answers = something speaks HTTP there
# (a server, but not for this token); stale = nothing listens (the IDE is gone).
afleet_ide_probe() {   # <port> <token>
    local line
    line="$(_afleet_ide_handshake "$1" "$2" 2>/dev/null)" || { echo stale; return 1; }
    case "$line" in
        "HTTP/1.1 101"*|"HTTP/1.0 101"*) echo live; return 0 ;;
        HTTP/*) echo answers; return 0 ;;
        *) echo stale; return 1 ;;
    esac
}

# ── The IDEs the CLI would see ───────────────────────────────────────────────

# rc 0 when <dir> is one of the `;`-joined workspace folders or lies below one.
# Windows folders (a Windows-side IDE) are translated before the comparison.
afleet_ide_matches() {   # <dir> <folders>
    local dir="${1%/}" f
    local IFS=';'
    for f in $2; do
        [[ -n "$f" ]] || continue
        f="$(_afleet_ide_win2wsl "$f")"
        [[ "$dir" == "$f" || "$dir" == "$f"/* ]] && return 0
    done
    return 1
}

# One line per lock file: port<TAB>ideName<TAB>live|answers|stale<TAB>yes|no|-<TAB>lockfile<TAB>folders
# The 4th field is the workspace match for <dir> (`-` when no dir is given). The token
# stays in a local variable: it is read for the probe and never printed.
afleet_ide_list() {   # [dir]
    local dir="${1:-}" d f port name token win folders match status
    [[ -n "$dir" ]] && dir="$(realpath -m "$dir" 2>/dev/null || printf '%s' "$dir")"
    command -v jq >/dev/null 2>&1 || { echo "afleet-ide: jq is required to read IDE lock files" >&2; return 3; }
    while IFS= read -r d; do
        [[ -d "$d" ]] || continue
        for f in "$d"/*.lock; do
            [[ -f "$f" ]] || continue
            port="${f##*/}"; port="${port%.lock}"
            IFS=$'\t' read -r name win folders token < <(jq -r \
                '[(.ideName // "unknown"), ((.runningInWindows // false) | tostring), ((.workspaceFolders // []) | join(";")), (.authToken // "")] | join("\t")' \
                "$f" 2>/dev/null) || { name="unreadable"; win=false; folders=""; token=""; }
            [[ -n "$name" ]] || name="unreadable"
            status="$(afleet_ide_probe "$port" "$token")" || true
            match="-"
            if [[ -n "$dir" ]]; then
                if afleet_ide_matches "$dir" "$folders"; then match=yes; else match=no; fi
            fi
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$port" "$name" "$status" "$match" "$f" "$folders"
        done
    done < <(afleet_ide_lock_dirs)
    return 0
}

# ── autoConnectIde: the opt-in in the CLI's global config ────────────────────

# The CLI's global config: `<config dir>/.claude.json`, or `~/.claude.json` for the
# default dir (that file sits beside ~/.claude, not inside it).
afleet_ide_claude_json() {
    if [[ -n "${AFLEET_IDE_CLAUDE_JSON:-}" ]]; then printf '%s\n' "$AFLEET_IDE_CLAUDE_JSON"; return; fi
    local cfg; cfg="$(afleet_ide_config_dir)"
    if [[ "$cfg" == "$HOME/.claude" ]]; then printf '%s\n' "$HOME/.claude.json"; else printf '%s\n' "$cfg/.claude.json"; fi
}

# No argument: print the current value (true | false | unset). on|off: write it, keeping
# every other key (atomic rewrite beside the file); an unparseable file is left alone.
afleet_ide_autoconnect() {   # [on|off]
    local cj val tmp; cj="$(afleet_ide_claude_json)"
    command -v jq >/dev/null 2>&1 || { echo "afleet-ide: jq is required" >&2; return 3; }
    case "${1:-}" in
        "")
            val="$(jq -r 'if has("autoConnectIde") then (.autoConnectIde | tostring) else "unset" end' "$cj" 2>/dev/null)" || val="unset"
            printf 'autoConnectIde: %s (%s)\n' "${val:-unset}" "$cj"; return 0 ;;
        on) val=true ;;
        off) val=false ;;
        *) echo "usage: af ide autoconnect [on|off]" >&2; return 2 ;;
    esac
    if [[ -f "$cj" ]]; then
        jq -e . "$cj" >/dev/null 2>&1 || { echo "afleet-ide: $cj is not valid JSON — left untouched" >&2; return 1; }
    else
        mkdir -p "$(dirname "$cj")" && printf '{}\n' > "$cj" || return 1
    fi
    tmp="$(mktemp "$(dirname "$cj")/.afleet-ide.XXXXXX")" || return 1
    if jq --argjson v "$val" '.autoConnectIde = $v' "$cj" > "$tmp"; then
        mv "$tmp" "$cj" && printf 'autoConnectIde: %s (%s)\n' "$val" "$cj"
    else
        rm -f "$tmp"; echo "afleet-ide: could not write $cj" >&2; return 1
    fi
}

# ── What the user sees ───────────────────────────────────────────────────────

# Advisory check before `af --ide` hands the flag to the CLI. rc 0: exactly one live IDE
# has this folder open (what `--ide` needs); 1: none; 2: several (use /ide to pick).
afleet_ide_preflight() {   # <dir>
    local dir="$1" rows live=0 n=0 names="" d
    rows="$(afleet_ide_list "$dir")" || true
    while IFS=$'\t' read -r _ name status match _ _; do
        [[ -n "$name" ]] || continue
        n=$((n + 1))
        [[ "$status" == live && "$match" == yes ]] && { live=$((live + 1)); names="${names:+$names, }$name"; }
    done <<< "$rows"
    if [[ $live -eq 1 ]]; then
        echo "  IDE: $names has this folder open — --ide connects to it."; return 0
    elif [[ $live -gt 1 ]]; then
        echo "  IDE: $live IDEs have this folder open ($names) — --ide needs exactly one; run /ide inside the session to pick."; return 2
    fi
    echo "  IDE: no running IDE has this folder open ($n lock file(s) found). Searched, in Claude Code's order:"
    while IFS= read -r d; do echo "    $d$([[ -d "$d" ]] || echo ' (absent)')"; done < <(afleet_ide_lock_dirs)
    echo "  Open the folder in VS Code or a JetBrains IDE with the Claude Code extension, then /ide inside the session."
    afleet_ide_is_wsl && echo "  (WSL: a Windows-side IDE is reached over loopback only with mirrored networking or a firewall rule.)"
    return 1
}

afleet_ide_status() {   # [dir]
    local dir="${1:-$PWD}" term d n rows
    term="$(afleet_ide_terminal)" || term="none detected (TERM_PROGRAM / TERMINAL_EMULATOR)"
    echo "IDE terminal:    $term"
    echo "Config dir:      $(afleet_ide_config_dir)"
    echo "Lock dirs searched (Claude Code's order):"
    while IFS= read -r d; do
        if [[ -d "$d" ]]; then n=$(find "$d" -maxdepth 1 -name '*.lock' 2>/dev/null | wc -l | tr -d ' '); else n="absent"; fi
        printf '  %s  (%s%s)\n' "$d" "$n" "$([[ "$n" == absent ]] || echo ' lock file(s)')$(_afleet_ide_dir_is_windows "$d" && echo '; Windows-side IDE')"
    done < <(afleet_ide_lock_dirs)
    echo "IDEs (port, name, state, has $dir open, lock file):"
    rows="$(afleet_ide_list "$dir")" || true
    [[ -n "$rows" ]] && printf '%s\n' "$rows" | awk -F'\t' '{ printf "  %-6s %-22s %-8s %-4s %s\n", $1, $2, $3, $4, $5 }' || echo "  (none)"
    afleet_ide_autoconnect | sed 's/^/  /'
    echo "Connect: \`af --ide\` (exactly one IDE with this folder open) or \`/ide\` inside the session; \`af ide autoconnect on\` to connect every launch."
}

# ── CLI ───────────────────────────────────────────────────────────────────────
#   status [dir]            what the CLI will find for <dir> (default: cwd)
#   preflight <dir>         one-line verdict for `af --ide` (rc 0 one, 1 none, 2 several)
#   list [dir]              machine-readable rows
#   lock-dirs               the search path
#   autoconnect [on|off]    read or set the opt-in in the global config
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-status}" in
        status)       afleet_ide_status "${2:-$PWD}" ;;
        preflight)    afleet_ide_preflight "${2:-$PWD}" ;;
        list)         afleet_ide_list "${2:-}" ;;
        lock-dirs)    afleet_ide_lock_dirs ;;
        autoconnect)  afleet_ide_autoconnect "${2:-}" ;;
        --help|-h|help)
            sed -n '/^# ── CLI/,/^if \[\[/p' "$0" | sed -n '2,7p' | sed 's/^#   //'; exit 0 ;;
        *) echo "usage: afleet-ide.sh status [dir] | preflight <dir> | list [dir] | lock-dirs | autoconnect [on|off]" >&2; exit 2 ;;
    esac
fi
