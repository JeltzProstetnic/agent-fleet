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
