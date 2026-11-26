#!/usr/bin/env bash
# tmp-sweep.sh — age out the fleet's own scratch (CFG-851, 2026-10-27: nothing ever deleted it).
#
# Every session writes into <project>/tmp/, Windows staging (C:\temp\cc-open) and session scratch,
# and nothing ever deleted any of it. Run at SessionEnd; one report line for the next start.
#
#   <home>/<project>/tmp/  untracked files older than TMP_SWEEP_DAYS (14) — only in git repos, never a
#                          git-tracked file, never inside a venv — are MOVED, not deleted, into the
#                          quarantine (CFG-1112, 2026-11-26: the sweep deleted simopt notes that existed
#                          nowhere else; no backup covers WSL home):
#                            TMP_SWEEP_QUARANTINE/<sweep date>/<path relative to home>
#                            e.g. ~/.local/share/tmp-sweep-quarantine/2026-11-26/simopt/tmp/silverlight/note.md
#                          mtime is kept; an existing destination gets a numeric suffix (.1, .2, …);
#                          when mv fails the file is copied (cp -p), verified (cmp) and only then
#                          removed; a file that cannot be quarantined stays in tmp/ and is counted
#                          as an error. Restore with mv. Day-dirs named YYYY-MM-DD and more than
#                          TMP_SWEEP_QUARANTINE_DAYS (30) days old are purged; nothing else under
#                          the quarantine root is ever touched.
#   TMP_SWEEP_STAGING      colon-separated dirs, files older than TMP_SWEEP_STAGING_DAYS (7) — deleted
#                          (copies of files that still exist elsewhere, so no quarantine)
#
# Usage: tmp-sweep.sh [--dry-run]
# Env:   TMP_SWEEP_HOME (default $HOME), TMP_SWEEP_REPORT (default ~/.claude/.tmp-sweep-last),
#        TMP_SWEEP_QUARANTINE (default ~/.local/share/tmp-sweep-quarantine), TMP_SWEEP_QUARANTINE_DAYS (30)

set -uo pipefail
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1
HOME_DIR="${TMP_SWEEP_HOME:-$HOME}"
DAYS="${TMP_SWEEP_DAYS:-14}"
SDAYS="${TMP_SWEEP_STAGING_DAYS:-7}"
STAGING="${TMP_SWEEP_STAGING-/mnt/c/temp/cc-open:/tmp/claude-$(id -u)}"
REPORT="${TMP_SWEEP_REPORT:-$HOME/.claude/.tmp-sweep-last}"
QROOT="${TMP_SWEEP_QUARANTINE:-$HOME/.local/share/tmp-sweep-quarantine}"
QDAYS="${TMP_SWEEP_QUARANTINE_DAYS:-30}"
TODAY=$(date +%Y-%m-%d)
QDIR="$QROOT/$TODAY"

QN=0; QBYTES=0; ERRS=0        # project tmp/ files quarantined / left in place
PN=0; PBYTES=0                # quarantine day-dirs purged
SN=0; SBYTES=0                # staging files deleted
PER=""; VENV_NOTE=""

_unique() { # <path> → the first of <path>, <path>.1, <path>.2 … that does not exist yet
    local p="$1" i=0
    while [[ -e "$p" || -L "$p" ]]; do i=$((i+1)); p="$1.$i"; done
    printf '%s' "$p"
}

_move() { # <src> <dest> → 0 only when src verifiably lives at dest; never deletes an unverified src
    mv -- "$1" "$2" 2>/dev/null && [[ ! -e "$1" && -e "$2" ]] && return 0
    [[ -e "$1" ]] || return 1                       # src gone without a verified move: touch nothing
    cp -p -- "$1" "$2" 2>/dev/null && cmp -s -- "$1" "$2" && rm -f -- "$1" && return 0
    rm -f -- "$2" 2>/dev/null; return 1             # drop the partial copy; src is untouched
}

_quarantine() { # <size> <file> — move into QDIR under the path relative to HOME_DIR
    local dest="$QDIR/${2#"$HOME_DIR"/}"
    if [[ $DRY -eq 1 ]]; then echo "would quarantine: $2 -> $(_unique "$dest")"
    else
        mkdir -p -- "$(dirname "$dest")" 2>/dev/null || { ERRS=$((ERRS+1)); return; }
        dest=$(_unique "$dest")
        _move "$2" "$dest" || { ERRS=$((ERRS+1)); return; }
    fi
    QN=$((QN+1)); QBYTES=$((QBYTES+$1))
}

_remove() { # <size> <file> — staging only
    if [[ $DRY -eq 1 ]]; then echo "would remove: $2"; else rm -f -- "$2" || return; fi
    SN=$((SN+1)); SBYTES=$((SBYTES+$1))
}

_sweep_project() { # <project dir>
    local proj="$1" before=$QBYTES t v sz f quarantined
    declare -A TRACKED=()
    while IFS= read -r -d '' t; do TRACKED["$t"]=1; done < <(git -C "$proj" ls-files -z -- tmp 2>/dev/null)
    # A venv is never touched by being used, so age says nothing about it: skip and report.
    VENVS=()
    while IFS= read -r -d '' v; do VENVS+=("$(dirname "$v")"); done < <(find "$proj/tmp" -name pyvenv.cfg -print0 2>/dev/null)
    for v in "${VENVS[@]}"; do VENV_NOTE="${VENV_NOTE:+$VENV_NOTE, }${v#"$HOME_DIR"/}"; done
    while IFS=' ' read -r -d '' sz f; do
        [[ -n "${TRACKED[${f#"$proj"/}]:-}" ]] && continue
        for v in "${VENVS[@]}"; do [[ "$f" == "$v"/* ]] && continue 2; done
        _quarantine "$sz" "$f"
    done < <(find "$proj/tmp" -type f -mtime +"$DAYS" -printf '%s %p\0' 2>/dev/null)
    [[ $DRY -eq 0 ]] && find "$proj/tmp" -mindepth 1 -type d -empty -delete 2>/dev/null
    quarantined=$((QBYTES-before))
    [[ $quarantined -gt 1048576 ]] && PER="${PER:+$PER, }$(basename "$proj") $((quarantined/1048576))M"
}

_purge() { # remove day-dirs named YYYY-MM-DD that are more than QDAYS days before today — nothing else
    local cutoff d name bytes
    cutoff=$(date -d "$TODAY -$QDAYS days" +%Y-%m-%d) || return
    for d in "$QROOT"/*/; do
        d="${d%/}"; name="${d##*/}"
        [[ -d "$d" && ! -L "$d" ]] || continue
        [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
        [[ "$name" < "$cutoff" ]] || continue
        bytes=$(du -sb -- "$d" 2>/dev/null | cut -f1); bytes=${bytes:-0}
        if [[ $DRY -eq 1 ]]; then echo "would purge: $d"; else rm -rf -- "$d" || continue; fi
        PN=$((PN+1)); PBYTES=$((PBYTES+bytes))
    done
}

_report() {
    local vq=quarantined vp=purged vf=freed qshow="$QDIR" err=""
    [[ $DRY -eq 1 ]] && { vq="would quarantine"; vp="would purge"; vf="would free"; }
    [[ "$QDIR" == "$HOME"/* ]] && qshow="~${QDIR#"$HOME"}"
    [[ $ERRS -gt 0 ]] && err=" | $ERRS files could not be quarantined and stay in tmp/"
    line="TMP_SWEEP: $vq $QN files ($((QBYTES/1048576)) MB) to $qshow/ (restore from there within $QDAYS d), $vp $PN day-dirs older than $QDAYS d ($((PBYTES/1048576)) MB), staging $vf $((SBYTES/1048576)) MB in $SN files ($TODAY)${PER:+ — $PER}${err}${VENV_NOTE:+ | venv in tmp/ kept, move it out: $VENV_NOTE}"
    echo "$line"
    [[ $DRY -eq 0 ]] && { mkdir -p "$(dirname "$REPORT")"; printf '%s\n' "$line" > "$REPORT"; }
}

for proj in "$HOME_DIR"/*/; do
    proj="${proj%/}"; [[ -d "$proj/tmp" && -d "$proj/.git" ]] || continue
    _sweep_project "$proj"
done

IFS=':' read -r -a sdirs <<< "$STAGING"
for d in "${sdirs[@]}"; do
    [[ -n "$d" && -d "$d" ]] || continue
    while IFS=' ' read -r -d '' sz f; do _remove "$sz" "$f"; done < <(find "$d" -type f -mtime +"$SDAYS" -printf '%s %p\0' 2>/dev/null)
    [[ $DRY -eq 0 ]] && find "$d" -mindepth 1 -type d -empty -delete 2>/dev/null
done

_purge
_report
exit 0
