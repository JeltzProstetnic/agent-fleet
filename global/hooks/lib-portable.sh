#!/usr/bin/env bash
# lib-portable.sh — Portable wrappers for GNU vs BSD/macOS differences.
# Source from hooks that need sed -i, readlink -f, or stat portability.
# Also included in setup/lib.sh for scripts.

[[ "${_LIB_PORTABLE_LOADED:-}" == "true" ]] && return 0
_LIB_PORTABLE_LOADED="true"

# Portable sed in-place edit. Usage: _sed_i 's/old/new/' file
_sed_i() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# Portable readlink -f (follows all symlinks to canonical path).
_readlink_f() {
    readlink -f "$1" 2>/dev/null && return
    local target="$1"
    [ "${target#/}" = "$target" ] && target="$PWD/$target"
    while [ -L "$target" ]; do
        local link
        link=$(readlink "$target") || break
        [ "${link#/}" = "$link" ] && link="$(dirname "$target")/$link"
        target="$link"
    done
    local dir
    dir=$(cd "$(dirname "$target")" 2>/dev/null && pwd -P) || return 1
    echo "$dir/$(basename "$target")"
}

# Portable stat: modification time (epoch seconds).
_stat_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Portable stat: file size (bytes).
_stat_size() {
    stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null
}

# Convert path to native format for non-MSYS tools (Python, etc.).
# On MINGW64/Cygwin, bash paths like /c/Users/... must become C:/Users/... for
# native Windows programs. No-op on Linux/macOS. (CFG-336)
_to_native_path() {
    local path="$1"
    if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]] && command -v cygpath &>/dev/null; then
        cygpath -m "$path"
    else
        echo "$path"
    fi
}

# ---- Native Windows bash (MSYS2 / Cygwin / Git Bash) — CFG-335, CFG-1087 ----------------------
# WSL is Linux and never matches. OSTYPE is `msys` on older Git for Windows and `cygwin` on current
# ones (2.55 measured 2026-11-25); sync.sh's PLATFORM=windows counts as well.
_is_native_windows() {
    [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* || "${PLATFORM:-}" == windows ]]
}

# Where cc-mirror puts the launcher for <variant> (default mclaude): ~/.local/bin/<variant> on
# Linux/macOS/WSL, ~/.cc-mirror/bin/<variant>.cmd on native Windows (agent-fleet GH#2).
_cc_launcher_path() {
    local variant="${1:-mclaude}"
    if _is_native_windows; then
        echo "$HOME/.cc-mirror/bin/${variant}.cmd"
    else
        echo "$HOME/.local/bin/${variant}"
    fi
}

# First existing launcher for <variant>: the platform's own location first, then the other one
# (cc-mirror versions differ in where they write it). Prints the path; 1 when none exists.
_cc_launcher_find() {
    local variant="${1:-mclaude}" c
    for c in "$(_cc_launcher_path "$variant")" "$HOME/.local/bin/${variant}" "$HOME/.cc-mirror/bin/${variant}.cmd"; do
        if [[ -f "$c" ]]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

# ---- Python resolution (CFG-1087 slice 2) -------------------------------------------------------
# Off native Windows the fleet runs `python3`, unprobed — Linux/macOS/WSL behaviour is unchanged.
# On Git Bash `python3` is often only the Microsoft Store redirector: it prints "Python was not
# found; run without arguments to install from the Microsoft Store…" and EXITS 0 (measured
# 2026-11-25), so a `command -v python3` guard passes and the call fails. Each candidate — python3,
# python, py -3 — is run once with --version and accepted only when it prints a `Python 3.` banner;
# the first that does wins. Cached in _FLEET_PYTHON (python3 | python | py -3 | none), the probe
# verdicts in _FLEET_PYTHON_WHY. A caller may pre-set _FLEET_PYTHON (tests, overrides).
_FLEET_PYTHON="${_FLEET_PYTHON:-}"
_FLEET_PYTHON_WHY="${_FLEET_PYTHON_WHY:-}"

# _python_probe_one <cmd…> — true when `<cmd…> --version` prints a Python 3 banner; records why.
_python_probe_one() {
    local v why
    v=$(_timeout 10 "$@" --version 2>&1 </dev/null | head -1 | tr -d '\r')
    case "$v" in
        "Python 3."*) _FLEET_PYTHON_WHY="${_FLEET_PYTHON_WHY:+$_FLEET_PYTHON_WHY; }$* answers \"$v\""; return 0 ;;
    esac
    why="${v:-no output}"
    _FLEET_PYTHON_WHY="${_FLEET_PYTHON_WHY:+$_FLEET_PYTHON_WHY; }$* unusable (${why:0:90})"
    return 1
}

# Probe once; sets _FLEET_PYTHON and _FLEET_PYTHON_WHY. 1 when nothing usable runs.
_probe_python() {
    _FLEET_PYTHON_WHY=""
    if ! _is_native_windows; then
        _FLEET_PYTHON="python3"
        _FLEET_PYTHON_WHY="python3, unprobed (not native Windows)"
        return 0
    fi
    local c
    for c in python3 python "py -3"; do
        if ! command -v "${c%% *}" >/dev/null 2>&1; then
            _FLEET_PYTHON_WHY="${_FLEET_PYTHON_WHY:+$_FLEET_PYTHON_WHY; }${c%% *} not on PATH"
            continue
        fi
        # shellcheck disable=SC2086  # `py -3` is two words by design
        if _python_probe_one $c; then _FLEET_PYTHON="$c"; return 0; fi
    done
    _FLEET_PYTHON="none"
    return 1
}

# Prints the Python command to run (python3 | python | py -3); 1 and nothing when none runs.
# Call outside `$(…)` where the cache should persist (as _python3 does).
_fleet_python() {
    if [[ -z "$_FLEET_PYTHON" ]]; then _probe_python || true; fi
    [[ "$_FLEET_PYTHON" != none ]] || return 1
    printf '%s\n' "$_FLEET_PYTHON"
}

# _python3 <args…> — run the resolved Python; 127 when none, as a missing python3 would.
_python3() {
    _fleet_python >/dev/null || return 127
    # shellcheck disable=SC2086  # `py -3` is two words; the value is one of our own literals
    $_FLEET_PYTHON "$@"
}

# _have_python3 — the hooks' guard, in place of `command -v python3` (CFG-1087 slice 3). Off native
# Windows it IS `command -v python3`: same verdict, no probe, so a box without python3 still takes a
# hook's grep/sed fallback exactly as before. On Git Bash `command -v python3` is true for the Store
# redirector and would let the broken call through, so there the probe's verdict decides.
_have_python3() {
    if _is_native_windows; then
        _fleet_python >/dev/null 2>&1
    else
        command -v python3 >/dev/null 2>&1
    fi
}

# Prints the command and the probe verdicts — for the setup/deploy log.
_python_report() {
    _fleet_python >/dev/null 2>&1 || true
    printf '%s — %s\n' "$_FLEET_PYTHON" "${_FLEET_PYTHON_WHY:-set by caller}"
}

# ---- Portable link helpers (CFG-335: native Windows) -------------------------------------------
# On MSYS2/Cygwin without rights `ln -s` silently COPIES, so every `[ -L ]` check fails (agent-fleet
# GH#2). The mode is chosen once per process by what the host actually allows, cached in
# _SYMLINK_MODE, and stated by _link_mode_report:
#   symlink  — real symlinks. Linux/macOS/WSL always (no probe, behaviour unchanged); native Windows
#              only with Developer Mode or elevation, forced through MSYS=winsymlinks:nativestrict
#              (`native` would fall back to a copy and hide the failure again).
#   junction — directories as NTFS junctions (`mklink /J`, no rights needed; bash reports them as
#              symlinks and `rm` removes only the junction), files as copies.
#   copy     — everything copied; re-run setup/deploy after repo updates.
# A caller may pre-set _SYMLINK_MODE (tests, overrides); the probe then does not run.
_SYMLINK_MODE="${_SYMLINK_MODE:-}"
_SYMLINK_WHY="${_SYMLINK_WHY:-}"

# ln with native symlinks forced on Windows; the plain call everywhere else.
_ln_s() {
    if _is_native_windows; then
        MSYS=winsymlinks:nativestrict ln "$@"
    else
        ln "$@"
    fi
}

# _mk_junction <src-dir> <dst> — NTFS directory junction; cmd's mklink wants Windows paths.
_mk_junction() {
    cmd //c mklink //J "$(cygpath -w "$2")" "$(cygpath -w "$1")" >/dev/null 2>&1
}

# Probe the host once; sets _SYMLINK_MODE and _SYMLINK_WHY.
_probe_link_mode() {
    if ! _is_native_windows; then
        _SYMLINK_MODE="symlink"
        _SYMLINK_WHY="symlinks are native here"
        return 0
    fi
    local t
    t=$(mktemp -d)
    echo test > "$t/src"
    mkdir -p "$t/srcdir"
    if _ln_s -s "$t/src" "$t/link" 2>/dev/null && [ -L "$t/link" ]; then
        _SYMLINK_MODE="symlink"
        _SYMLINK_WHY="native Windows symlinks allowed (Developer Mode or elevated shell)"
    elif command -v cmd >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1 \
            && _mk_junction "$t/srcdir" "$t/junc" && [ -L "$t/junc" ]; then
        _SYMLINK_MODE="junction"
        _SYMLINK_WHY="symlinks refused without Developer Mode or elevation; directories become NTFS junctions, files are copied"
    else
        _SYMLINK_MODE="copy"
        _SYMLINK_WHY="neither symlinks nor junctions available; files and directories are copied — re-run setup/deploy after repo updates"
    fi
    rm -rf "$t"
}

# True in symlink mode. Probes on first use.
_can_symlink() {
    if [[ -z "$_SYMLINK_MODE" ]]; then
        _probe_link_mode
    fi
    [[ "$_SYMLINK_MODE" == "symlink" ]]
}

# Prints the mode (symlink | junction | copy). Call outside `$(…)` where the cache should persist.
_link_mode() {
    _can_symlink >/dev/null 2>&1 || true
    printf '%s\n' "$_SYMLINK_MODE"
}

# Prints the mode and why it was chosen — for the setup/deploy log.
_link_mode_report() {
    _can_symlink >/dev/null 2>&1 || true
    printf '%s — %s\n' "$_SYMLINK_MODE" "${_SYMLINK_WHY:-mode set by caller}"
}

# _link_file <source> <target> — symlink in symlink mode, copy otherwise
_link_file() {
    local src="$1" dst="$2"
    if _can_symlink; then
        _ln_s -sf "$src" "$dst"
    else
        cp -f "$src" "$dst"
    fi
}

# _link_dir <source> <target> — symlink, junction or copy of a directory. A real directory at
# <target> must be moved aside by the caller first (see sync-lib/setup.sh _replace_dir_with_link).
_link_dir() {
    local src="$1" dst="$2"
    if _can_symlink; then
        _ln_s -sfn "$src" "$dst"
    elif [[ "$_SYMLINK_MODE" == "junction" ]]; then
        if [ -L "$dst" ]; then rm -f "$dst"; fi
        _mk_junction "$src" "$dst"
    else
        rm -rf "$dst"
        cp -rf "$src" "$dst"
    fi
}

# _check_linked <path> — true when <path> is what this mode deploys: a symlink; in junction mode a
# junction for a directory and an existing file otherwise; in copy mode anything that exists.
_check_linked() {
    local path="$1"
    if _can_symlink; then
        [ -L "$path" ]
    elif [[ "$_SYMLINK_MODE" == "junction" && -d "$path" ]]; then
        [ -L "$path" ]
    else
        [ -e "$path" ]
    fi
}

# _check_linked_valid <path> — as _check_linked, and the link target exists
_check_linked_valid() {
    local path="$1"
    if _can_symlink; then
        [ -L "$path" ] && [ -e "$path" ]
    elif [[ "$_SYMLINK_MODE" == "junction" && -d "$path" ]]; then
        [ -L "$path" ] && [ -e "$path" ]
    else
        [ -e "$path" ]
    fi
}

# Portable `timeout`. Usage: _timeout <secs> <cmd> [args...]
# Same contract as GNU timeout: the command's own exit status, 124 when it had to be
# killed, 127 when it does not exist. macOS ships no `timeout`, and a bare
# `timeout N cmd … || true` there exits 127 with the `|| true` hiding it — afleet's
# git sync silently never ran (agent-fleet GH#5). Order: timeout, gtimeout
# (Homebrew coreutils), perl (always on macOS), then pure bash. Bash 3.2-safe.
# _PORTABLE_TIMEOUT_IMPL=timeout|gtimeout|perl|bash forces a backend (tests).
_timeout() {
    local secs="$1"; shift
    local impl="${_PORTABLE_TIMEOUT_IMPL:-}"
    if [ -z "$impl" ]; then
        if command -v timeout >/dev/null 2>&1; then impl=timeout
        elif command -v gtimeout >/dev/null 2>&1; then impl=gtimeout
        elif command -v perl >/dev/null 2>&1; then impl=perl
        else impl=bash
        fi
    fi
    case "$impl" in
        timeout|gtimeout)
            "$impl" "$secs" "$@" ;;
        perl)
            # Own process group like GNU timeout, so a script's children die with it
            # and cannot keep a $(…) pipe open after the kill. That group is a
            # BACKGROUND group: git/ssh prompting on /dev/tty (passphrase, host key,
            # https username) get SIGTTIN and stop, and a stopped process keeps a TERM
            # pending forever — so, like GNU timeout, follow the TERM with a CONT.
            # Durations take GNU's suffixes (s m h d); alarm() wants whole seconds.
            perl -e '
                my $t = shift @ARGV;
                my %mult = ("" => 1, s => 1, m => 60, h => 3600, d => 86400);
                exit 125 unless $t =~ /^(\d+(?:\.\d*)?|\.\d+)([smhd]?)$/;
                my $secs = $1 * $mult{$2};
                $secs = int($secs) + ($secs > int($secs) ? 1 : 0);
                my $pid = fork();
                exit 125 unless defined $pid;
                if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127; }
                my $expired = 0;
                $SIG{ALRM} = sub { $expired = 1; kill "TERM", -$pid; kill "CONT", -$pid; };
                alarm $secs;
                while (waitpid($pid, 0) == -1) { last unless $!{EINTR}; }
                my $st = $?;
                alarm 0;
                exit 124 if $expired;
                exit(($st & 127) ? 128 + ($st & 127) : $st >> 8);
            ' "$secs" "$@" ;;
        *)
            # Last resort, pure bash. A background job's stdin defaults to /dev/null
            # when job control is off, so `<&0` keeps the caller's stdin. The
            # watchdog's fds go to /dev/null so it cannot hold a $(…) pipe open after
            # the command is done. Only the command itself is signalled (no process
            # groups without job control) — its children may outlive it.
            local flag; flag=$(mktemp "${TMPDIR:-/tmp}/_timeout.XXXXXX" 2>/dev/null) || flag=""
            "$@" <&0 &
            local pid=$!
            (
                trap 'kill "$_sp" 2>/dev/null; exit 0' TERM
                sleep "$secs" & _sp=$!
                wait "$_sp"
                [ -n "$flag" ] && echo expired > "$flag"
                kill -TERM "$pid" 2>/dev/null
                kill -CONT "$pid" 2>/dev/null   # a stopped command keeps TERM pending
            ) >/dev/null 2>&1 </dev/null &
            local watchdog=$! rc=0
            wait "$pid" || rc=$?
            kill -TERM "$watchdog" 2>/dev/null || true
            wait "$watchdog" 2>/dev/null || true
            # Killed by a signal AND the watchdog had fired: that is an expiry.
            if [ "$rc" -ge 128 ] && [ -n "$flag" ] && [ -s "$flag" ]; then rc=124; fi
            [ -n "$flag" ] && rm -f "$flag"
            return "$rc" ;;
    esac
}
