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
