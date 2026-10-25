#!/usr/bin/env bash
# build-pdf.sh — DOCX -> PDF via headless LibreOffice, cross-platform.
#
#   bash build-pdf.sh <input.docx> [output-dir]
#
# Native Linux uses `soffice` from PATH. WSL has no Linux LibreOffice on the
# fleet machines, so it drives the Windows install: that requires a real C:\
# working directory (the UNC path guard rejects \\wsl.localhost\... as a CWD)
# and a dedicated user profile so a running GUI instance does not block us.
set -euo pipefail

SRC="${1:-}"
OUTDIR="${2:-$(dirname "${SRC:-.}")}"

if [[ -z "$SRC" || ! -f "$SRC" ]]; then
    echo "usage: bash build-pdf.sh <input.docx> [output-dir]" >&2
    exit 2
fi
mkdir -p "$OUTDIR"

is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }

if is_wsl; then
    SOFFICE="/mnt/c/Program Files/LibreOffice/program/soffice.exe"
    if [[ ! -x "$SOFFICE" ]]; then
        echo "ERROR: LibreOffice not found at $SOFFICE" >&2
        echo "       Install it on the Windows side, or run this on a Linux machine." >&2
        exit 1
    fi
    STAGE="/mnt/c/temp/fleet-pdf"
    mkdir -p "$STAGE"
    cp -f "$SRC" "$STAGE/"
    BASE="$(basename "$SRC")"
    # Must run from a /mnt CWD; profile kept separate from the GUI's.
    ( cd "$STAGE" && "$SOFFICE" \
        -env:UserInstallation=file:///C:/temp/fleet-lo-profile \
        --headless --norestore --convert-to pdf \
        --outdir "C:\\temp\\fleet-pdf" "$BASE" >/dev/null 2>&1 )
    PDF="$STAGE/${BASE%.*}.pdf"
else
    SOFFICE="$(command -v soffice || command -v libreoffice || true)"
    if [[ -z "$SOFFICE" ]]; then
        echo "ERROR: no soffice/libreoffice on PATH." >&2
        exit 1
    fi
    STAGE="$(mktemp -d)"
    "$SOFFICE" --headless --norestore --convert-to pdf \
        --outdir "$STAGE" "$SRC" >/dev/null 2>&1
    PDF="$STAGE/$(basename "${SRC%.*}").pdf"
fi

if [[ ! -f "$PDF" ]]; then
    echo "ERROR: conversion produced no PDF (is a LibreOffice instance holding the file?)" >&2
    exit 1
fi

DEST="$OUTDIR/$(basename "$PDF")"
mv -f "$PDF" "$DEST"
SIZE=$(stat -c%s "$DEST")
if (( SIZE < 5000 )); then
    echo "ERROR: PDF is suspiciously small ($SIZE bytes)" >&2
    exit 1
fi
echo "built: $DEST ($SIZE bytes)"
