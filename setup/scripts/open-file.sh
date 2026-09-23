#!/usr/bin/env bash
# open-file.sh — open a produced file for the user to LOOK AT (CFG-560)
#
# MG, 2026-09-10: "these image filesystem links do nothing for me, when i ask you to
# open stuff, open it." Reporting a path is not showing someone a file, and neither is
# SendUserFile — it delivers a reference and reports success, which is why it misleads.
#
# Usage:  bash open-file.sh <path> [<path> ...]
#
# Env:
#   OPEN_FILE_DRY=1        resolve and print the decision, launch nothing (tests)
#   OPEN_FILE_MACHINE=<m>  override machine detection (tests)
#   OPEN_FILE_WIN_STAGE=<dir>  Windows-native staging dir for WSL launches
#
# The file-type → application mapping is held as DATA, one row set per machine, so a
# new type is a table row rather than a new branch.

set -uo pipefail

# ── Machine detection ───────────────────────────────────────────────────────
# Mirrors the identity table in global/CLAUDE.md. Anything unrecognised degrades to
# path-only rather than guessing: launching a wrong GUI command on an unknown box can
# hang the calling tool call, which is a worse failure than printing a path.
# Detection is by CAPABILITY, not by hostname. Two reasons: a hostname table would put
# the fleet's machine names into a public template, and it would silently mis-handle any
# machine nobody had added a row for. Capability detection makes a new box correct by
# default, and a machine that wants explicit rows sets OPEN_FILE_MACHINE in its own file.
_detect_machine() {
    [ -n "${OPEN_FILE_MACHINE:-}" ] && { printf '%s' "$OPEN_FILE_MACHINE"; return; }
    # WSL: a Windows drive is mounted and the interop launcher is reachable.
    if [ -d /mnt/c ] && command -v powershell.exe >/dev/null 2>&1; then
        printf 'wsl'; return
    fi
    # Native Linux desktop: an actual display server is attached.
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v xdg-open >/dev/null 2>&1; then
        printf 'xdg-desktop'; return
    fi
    # Headless: SSH-only boxes, servers, anything without a display.
    printf 'headless'
}

# ── Association tables ──────────────────────────────────────────────────────
# WSL rows are MG-approved verbatim (2026-09-10, revised the same evening):
#   png/jpg/jpeg/gif/webp/svg/pdf/html -> Chrome
#   txt/md/log + source/config text    -> Notepad
#   everything else                    -> print the path
#
# VS Code is RETIRED here. MG 2026-09-10: "yes, no more vs code", reaffirming his
# fleet-wide 2026-08-25 ruling ("no more vs code, notepad preferred") over the
# narrower table approved earlier the same day. Do not reintroduce a `code` row.
#
# The catch-all is a SPLIT, not a rename, and that is the load-bearing part: routing
# every unmapped extension to Notepad would open .docx/.xlsx/.zip as binary garbage.
# Text-shaped files keep the convenience; genuinely binary ones degrade to the path.
_VIEWER_EXT="png jpg jpeg gif webp svg pdf html"
_TEXT_EXT="txt md log"
# Source and config formats: plain text, so Notepad renders them correctly.
# Extensions only — a file with NO extension (Makefile, LICENSE) resolves to the path,
# because guessing that an unknown extensionless file is text is how binary reaches Notepad.
_SOURCE_EXT="py sh bash zsh json yml yaml csv tsv ts js tsx jsx toml ini cfg conf env xml sql rb go rs c h cpp hpp java php pl lua r css scss diff patch tex bib gitignore"

# _assoc <machine> <ext> -> app token (chrome|notepad|xdg) or PATH_ONLY
_assoc() {
    local machine="$1" ext="$2"
    case "$machine" in
        wsl)
            if printf '%s ' $_VIEWER_EXT | grep -qw -- "$ext"; then printf 'chrome'
            elif printf '%s ' $_TEXT_EXT | grep -qw -- "$ext"; then printf 'notepad'
            elif printf '%s ' $_SOURCE_EXT | grep -qw -- "$ext"; then printf 'notepad'
            else printf 'PATH_ONLY'; fi
            ;;
        xdg-desktop)
            # Native Linux desktop. Per-extension rows are not individually approved, so
            # this defers to the desktop's own handler rather than inventing a mapping —
            # xdg-open is at least the user's own configured choice.
            printf 'xdg'
            ;;
        *)
            # Headless, or a machine class with no rows defined. Per MG's scoping these
            # degrade to printing the path with a stated reason.
            printf 'PATH_ONLY'
            ;;
    esac
}

_reason_for() {
    case "$1" in
        headless) printf 'no display server on this machine (SSH-only or server)' ;;
        *)        printf 'no GUI associations defined for this machine class' ;;
    esac
}

# ── WSL launch ──────────────────────────────────────────────────────────────
# Three traps, all from machines/wsl.md. A rewrite that drops any of them appears to
# work and then hangs the tool call or leaks PowerShell processes:
#
#   1. `cmd.exe /c start` BLOCKS the calling Bash tool call — WSL's Win32 interop waits
#      on the entire detached process tree. Start-Process detaches properly and the
#      launched process survives the tool-call boundary (measured 2026-08-27:
#      a CC-launched overlay lived 17 minutes past the call and rendered on screen).
#   2. A `\\wsl.localhost\...` UNC path spawns zombie PowerShells — the 2026-03-10
#      lockout, 9 PowerShell + 3 cmd zombies froze the Windows session. So anything
#      not already under /mnt is copied to a Windows-native staging dir first.
#   3. Windows executables must be invoked from a /mnt cwd or the unc-path-guard
#      refuses them.
_win_stage() {
    local src="$1" stage base
    case "$src" in
        /mnt/*) printf '%s' "$src"; return 0 ;;   # already Windows-native
    esac
    # Deliberately username-free so this file is byte-identical in the public template.
    # Override with OPEN_FILE_WIN_STAGE if a machine wants its own staging directory.
    stage="${OPEN_FILE_WIN_STAGE:-/mnt/c/temp/cc-open}"
    mkdir -p "$stage" 2>/dev/null || return 1
    base="$(basename "$src")"
    cp -f "$src" "$stage/$base" 2>/dev/null || return 1
    printf '%s' "$stage/$base"
}

# Build the PowerShell -Command string for a Windows launch.
#
# Factored out so it can be ASSERTED WITHOUT LAUNCHING ANYTHING: the defect this exists to
# prevent (CFG-681) was found because two calls put 16 Chrome tabs on MG's desktop, so a
# test that launches is the one thing a test here must never do.
#
# The bug: `-ArgumentList '$win'` hands PowerShell ONE string, which it passes through as
# the raw command line — Chrome then re-splits it on spaces and opens every token as a URL.
# "200 Software Project Assignment — AI First PDP.pdf" is 8 tokens, hence 8 tabs per call.
# Embedded double quotes make Windows' command-line parser see exactly one argument.
#
# The no-exe form is NOT affected and must stay as it is: there the path is the -FilePath
# positional as a single-quoted PowerShell string, which already handles spaces.
_win_launch_cmd() {  # <exe|""> <windows-path>
    local _exe="$1" _win="$2"
    if [ -n "$_exe" ]; then
        printf "Start-Process '%s' -ArgumentList '\"%s\"'" "$_exe" "$_win"
    else
        printf "Start-Process '%s'" "$_win"
    fi
}

_launch_wsl() {
    local app="$1" path="$2" staged win

    # No `code` branch: VS Code was retired fleet-wide by MG on 2026-09-10. Every
    # remaining app is a Windows executable, so all of them go through staging.
    staged="$(_win_stage "$path")" || { echo "open-file: could not stage $path" >&2; return 1; }
    win="$(wslpath -w "$staged" 2>/dev/null)" || { echo "open-file: wslpath failed for $staged" >&2; return 1; }

    local exe
    case "$app" in
        chrome)  exe='chrome.exe' ;;
        notepad) exe='notepad.exe' ;;
        *)       exe='' ;;
    esac

    if [ -n "$exe" ]; then
        env -C /mnt/c powershell.exe -NoProfile -Command "$(_win_launch_cmd "$exe" "$win")" >/dev/null 2>&1 \
        || env -C /mnt/c powershell.exe -NoProfile -Command "$(_win_launch_cmd "" "$win")" >/dev/null 2>&1
    else
        env -C /mnt/c powershell.exe -NoProfile -Command "$(_win_launch_cmd "" "$win")" >/dev/null 2>&1
    fi
    # Report it. MEASURED 2026-09-23: this path printed NOTHING on success, so a session
    # that piped the call through `tail -3`, saw nothing and could not tell whether it had
    # fired simply ran it again — 8 junk tabs became 16 on MG's desktop. A launch that
    # reports itself cannot be repeated by a caller that is guessing.
    printf 'open-file: launched %s -> %s\n' "${exe:-<default app>}" "$path"
}

# ── Main ────────────────────────────────────────────────────────────────────
[ "$#" -ge 1 ] || { echo "usage: open-file.sh <path> [<path> ...]" >&2; exit 2; }

_machine="$(_detect_machine)"
_rc=0

for _path in "$@"; do
    if [ ! -f "$_path" ]; then
        echo "open-file: no such file: $_path" >&2
        _rc=1
        continue
    fi

    _abs="$(cd "$(dirname "$_path")" && pwd)/$(basename "$_path")"
    _ext="${_path##*.}"
    # A filename with no dot leaves _ext equal to the whole name; normalise it to empty
    # so it falls through to the catch-all row instead of matching a bogus extension.
    [ "$_ext" = "$(basename "$_path")" ] && _ext=""
    _ext="$(printf '%s' "$_ext" | tr '[:upper:]' '[:lower:]')"

    _app="$(_assoc "$_machine" "$_ext")"

    if [ "$_app" = "PATH_ONLY" ]; then
        # Say why. A silent no-op would be worse than the path-reporting this rule
        # exists to replace, because the session would believe it had shown something.
        echo "open-file: path-only on '$_machine' — $(_reason_for "$_machine"):"
        echo "  $_abs"
        continue
    fi

    if [ -n "${OPEN_FILE_DRY:-}" ]; then
        echo "open-file: [dry] would open with $_app: $_abs"
        continue
    fi

    case "$_machine" in
        wsl)         _launch_wsl "$_app" "$_abs" || _rc=1 ;;
        xdg-desktop) xdg-open "$_abs" >/dev/null 2>&1 & ;;
    esac
done

exit "$_rc"
