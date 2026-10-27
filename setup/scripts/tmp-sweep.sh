#!/usr/bin/env bash
# tmp-sweep.sh — age out the fleet's own scratch (CFG-851, 2026-10-27: nothing ever deleted it).
#
# Every session writes into <project>/tmp/, Windows staging (C:\temp\cc-open) and session scratch,
# and nothing ever deleted any of it. Run at SessionEnd; one report line for the next start.
#
#   <home>/<project>/tmp/  untracked files older than TMP_SWEEP_DAYS (14) — only in git repos,
#                          never a git-tracked file
#   TMP_SWEEP_STAGING      colon-separated dirs, files older than TMP_SWEEP_STAGING_DAYS (7)
#
# Usage: tmp-sweep.sh [--dry-run]
# Env:   TMP_SWEEP_HOME (default $HOME), TMP_SWEEP_REPORT (default ~/.claude/.tmp-sweep-last)

set -uo pipefail
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1
HOME_DIR="${TMP_SWEEP_HOME:-$HOME}"
DAYS="${TMP_SWEEP_DAYS:-14}"
SDAYS="${TMP_SWEEP_STAGING_DAYS:-7}"
STAGING="${TMP_SWEEP_STAGING-/mnt/c/temp/cc-open:/tmp/claude-$(id -u)}"
REPORT="${TMP_SWEEP_REPORT:-$HOME/.claude/.tmp-sweep-last}"

N=0; BYTES=0; PER=""; VENV_NOTE=""

_remove() { # <size> <file>
    if [[ $DRY -eq 1 ]]; then echo "would remove: $2"; else rm -f -- "$2" || return; fi
    N=$((N+1)); BYTES=$((BYTES+$1))
}

for proj in "$HOME_DIR"/*/; do
    proj="${proj%/}"; [[ -d "$proj/tmp" && -d "$proj/.git" ]] || continue
    before=$BYTES
    declare -A TRACKED=()
    while IFS= read -r -d '' t; do TRACKED["$t"]=1; done < <(git -C "$proj" ls-files -z -- tmp 2>/dev/null)
    # A venv is never touched by being used, so age says nothing about it: skip and report.
    VENVS=()
    while IFS= read -r -d '' v; do VENVS+=("$(dirname "$v")"); done < <(find "$proj/tmp" -name pyvenv.cfg -print0 2>/dev/null)
    for v in "${VENVS[@]}"; do VENV_NOTE="${VENV_NOTE:+$VENV_NOTE, }${v#"$HOME_DIR"/}"; done
    while IFS=' ' read -r -d '' sz f; do
        [[ -n "${TRACKED[${f#"$proj"/}]:-}" ]] && continue
        for v in "${VENVS[@]}"; do [[ "$f" == "$v"/* ]] && continue 2; done
        _remove "$sz" "$f"
    done < <(find "$proj/tmp" -type f -mtime +"$DAYS" -printf '%s %p\0' 2>/dev/null)
    unset TRACKED
    [[ $DRY -eq 0 ]] && find "$proj/tmp" -mindepth 1 -type d -empty -delete 2>/dev/null
    freed=$((BYTES-before)); [[ $freed -gt 1048576 ]] && PER="${PER:+$PER, }$(basename "$proj") $((freed/1048576))M"
done

IFS=':' read -r -a sdirs <<< "$STAGING"
for d in "${sdirs[@]}"; do
    [[ -n "$d" && -d "$d" ]] || continue
    while IFS=' ' read -r -d '' sz f; do _remove "$sz" "$f"; done < <(find "$d" -type f -mtime +"$SDAYS" -printf '%s %p\0' 2>/dev/null)
    [[ $DRY -eq 0 ]] && find "$d" -mindepth 1 -type d -empty -delete 2>/dev/null
done

line="TMP_SWEEP: $([[ $DRY -eq 1 ]] && echo 'would free' || echo 'freed') $((BYTES/1048576)) MB in $N files ($(date +%Y-%m-%d))${PER:+ — $PER}${VENV_NOTE:+ | venv in tmp/ kept, move it out: $VENV_NOTE}"
echo "$line"
[[ $DRY -eq 0 ]] && { mkdir -p "$(dirname "$REPORT")"; printf '%s\n' "$line" > "$REPORT"; }
exit 0
