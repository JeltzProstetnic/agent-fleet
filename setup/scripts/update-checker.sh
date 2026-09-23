#!/usr/bin/env bash
# cc-mirror update checker
# ========================
# Runs at mclaude startup (interactive sessions only).
# Checks for Claude Code updates once per day.

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Skip if explicitly disabled
if [[ "${CC_MIRROR_SKIP_UPDATE:-0}" == "1" ]]; then
  exit 0
fi

# Only check once per day (unless forced)
UPDATE_MARKER="$HOME/.cc-mirror/.last-update-check"
if [[ -f "$UPDATE_MARKER" ]] && [[ "${CC_MIRROR_FORCE_UPDATE:-0}" != "1" ]]; then
  LAST_CHECK=$(cat "$UPDATE_MARKER" 2>/dev/null || echo "0")
  NOW=$(date +%s)
  if (( NOW - LAST_CHECK < 86400 )); then
    exit 0
  fi
fi

# Get installed version — BOTH cc-mirror layouts
# ------------------------------------------------
#   npm:    <variant>/npm/node_modules/@anthropic-ai/claude-code/package.json
#   native: <variant>/native/claude — a bare binary, NO npm/ directory at all
# On a native install variant.json holds the REQUESTED spec (nativeVersion is
# usually the literal "latest"; cc-mirror 2.1.0 writes the resolved version only
# into claudeOrig as "native:X.Y.Z"), so the binary is the ground truth:
# `claude --version` prints "X.Y.Z (Claude Code)" in ~10 ms (measured WSL
# 2026-09-23), bounded by `timeout 5` here. Order: package.json → binary → any
# x.y.z in variant.json. Anything else is UNKNOWN and said OUT LOUD: the old
# npm-only read fell through silently on native installs and one fleet machine
# sat 33 releases behind without a single notice.
MIRROR_DIR="${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}"
NPM_PKG="$MIRROR_DIR/npm/node_modules/@anthropic-ai/claude-code/package.json"

_semver() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true; }
_json_field() { grep -o "\"$2\": *\"[^\"]*\"" "$1" 2>/dev/null | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/' || true; }
# `|| true` matters: under `set -euo pipefail` a hanging or crashing binary would
# otherwise abort this script through the `&& INSTALLED=$(...)` assignment below.
_probe_binary() {
  [[ -n "$1" && -x "$1" ]] || return 0
  if command -v timeout &>/dev/null; then
    timeout 5 "$1" --version 2>/dev/null </dev/null | _semver || true
  else
    "$1" --version 2>/dev/null </dev/null | _semver || true
  fi
}

INSTALLED=""
[[ -f "$NPM_PKG" ]] && INSTALLED=$(_json_field "$NPM_PKG" version | _semver)
# One binary, probed once: variant.json's binaryPath when it is still executable
# (it goes stale when an npm tree is removed by an npm→native migration), else
# the native-layout default. On a real native install both are the same file.
_bin=$(_json_field "$MIRROR_DIR/variant.json" binaryPath); [[ -x "$_bin" ]] || _bin="$MIRROR_DIR/native/claude"
[[ -z "$INSTALLED" ]] && INSTALLED=$(_probe_binary "$_bin")
for _key in nativeVersion claudeOrig npmVersion; do
  [[ -z "$INSTALLED" ]] && INSTALLED=$(_json_field "$MIRROR_DIR/variant.json" "$_key" | _semver)
done

if [[ -z "$INSTALLED" ]]; then
  echo -e "${YELLOW}Claude Code installed version UNKNOWN under ${MIRROR_DIR} — no npm package.json, no runnable native/claude, no x.y.z in variant.json. The update check is BLIND on this machine; probe by hand: ${MIRROR_DIR}/native/claude --version${NC}"
  mkdir -p "$(dirname "$UPDATE_MARKER")"
  date +%s > "$UPDATE_MARKER"
  exit 0
fi

# Check latest version from npm registry (timeout 5s to not block startup)
# Use timeout if available (GNU coreutils), fall back to bare command on macOS
if command -v timeout &>/dev/null; then
  LATEST=$(timeout 5 npm view @anthropic-ai/claude-code version 2>/dev/null || echo "")
else
  LATEST=$(npm view @anthropic-ai/claude-code version 2>/dev/null || echo "")
fi

mkdir -p "$(dirname "$UPDATE_MARKER")"
date +%s > "$UPDATE_MARKER"

if [[ -z "$LATEST" ]]; then
  # Network issue — skip silently
  exit 0
fi

# The remedy is the fleet's own wrapper on BOTH layouts — never a raw `cc-mirror` verb and
# never a bare npm install. Measured 2026-09-23: the documented `cc-mirror update …` resolved
# to a stale cc-mirror on PATH that ignored --claude-version, re-provisioned from the
# creation-time pin (2.1.274 → 2.1.1), rewrote the launcher to a missing cli.js, exit 0.
# cc-update.sh resolves the target first, refuses downgrades, backs up, verifies the result
# against cc-install-invariants.sh and rolls back on failure. A bare `npm update` leaves
# variant.json and the launcher stale, which is the other half of the same failure.
_REPO="${CONFIG_REPO:-$HOME/cfg-agent-fleet}"
if [[ ! -f "$_REPO/setup/scripts/cc-update.sh" && -f "$HOME/agent-fleet/setup/scripts/cc-update.sh" ]]; then
  _REPO="$HOME/agent-fleet"
fi
if [[ "$INSTALLED" != "$LATEST" ]]; then
  echo -e "${YELLOW}Claude Code update available: ${INSTALLED} → ${LATEST}${NC}"
  if [[ -f "$NPM_PKG" ]]; then
    echo -e "${BLUE}  Update (after /exit, from a plain shell): bash ${_REPO}/setup/scripts/cc-update.sh --version ${LATEST}${NC}"
  else
    echo -e "${BLUE}  Update (native install, after /exit): bash ${_REPO}/setup/scripts/cc-update.sh --via cc-mirror --version ${LATEST}${NC}"
  fi
  echo -e "${BLUE}  Read the changelog first. Never a cc-mirror verb or a bare npm install by hand — both leave variant.json and the launcher stale.${NC}"
else
  echo -e "${GREEN}Claude Code ${INSTALLED} (latest)${NC}"
fi
