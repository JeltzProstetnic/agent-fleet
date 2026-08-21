#!/usr/bin/env bash
# clean-pending-files.sh — DEPRECATED: backward-compat wrapper for manage-pending.sh
# All functionality has moved to manage-pending.sh. This script forwards calls.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGE="$SCRIPT_DIR/manage-pending.sh"

# Map old flags to new interface
ARGS=("report")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)       shift ;;  # report is the default
        --stale-only) shift ;;  # no direct equivalent, report shows all
        --project-dir) ARGS+=("--project-dir" "$2"); shift 2 ;;
        *) shift ;;
    esac
done

exec bash "$MANAGE" "${ARGS[@]}"
