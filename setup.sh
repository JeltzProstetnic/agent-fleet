#!/usr/bin/env bash
# setup.sh — Entry point for Claude Code configuration setup.
# Delegates to setup/install.sh which orchestrates the two-phase installation.
#
# Usage:
#   bash setup.sh [options]
#
# See setup/install.sh --help for all options.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/setup/install.sh" "$@"
