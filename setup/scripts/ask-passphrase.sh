#!/usr/bin/env bash
# ask-passphrase.sh — Cross-platform masked passphrase dialog for agent-fleet
#
# Part of agent-fleet (~/agent-fleet/setup/scripts/).
# Collects a passphrase with masked input and outputs ONLY the passphrase to stdout.
# All UI prompts go to stderr so the result can be captured via $(...).
#
# Usage:
#   PASS=$(bash ask-passphrase.sh)                        # single prompt, default title
#   PASS=$(bash ask-passphrase.sh "Decrypt vault")        # single prompt, custom title
#   PASS=$(bash ask-passphrase.sh --confirm "Encrypt")    # double prompt, verify match
#
# Exit codes:
#   0 — passphrase collected successfully
#   1 — user cancelled, empty input, or passphrase mismatch

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CONFIRM=false
TITLE="Enter passphrase"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm)
      CONFIRM=true
      shift
      if [[ $# -gt 0 ]]; then
        TITLE="$1"
        shift
      fi
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      TITLE="$1"
      shift
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Detection: which GUI tool is available?
# ---------------------------------------------------------------------------
_has() { command -v "$1" &>/dev/null; }

_detect_method() {
  if _has kdialog && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    echo "kdialog"
  elif _has zenity && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    echo "zenity"
  elif _has osascript; then
    echo "osascript"
  else
    echo "read"
  fi
}

METHOD=$(_detect_method)

# ---------------------------------------------------------------------------
# Single passphrase prompt — returns the passphrase in variable RESULT
# Sets RESULT="" and returns 1 on cancel/empty
# ---------------------------------------------------------------------------
_prompt_once() {
  local prompt_title="$1"
  local result=""

  case "$METHOD" in
    kdialog)
      result=$(kdialog --password "$prompt_title" 2>/dev/null) || return 1
      ;;
    zenity)
      result=$(zenity --password --title="$prompt_title" 2>/dev/null) || return 1
      ;;
    osascript)
      result=$(osascript -e \
        "tell application \"System Events\" to display dialog \"${prompt_title}\" default answer \"\" with hidden answer" \
        -e "text returned of result" 2>/dev/null) || return 1
      ;;
    read)
      echo -n "${prompt_title}: " >&2
      local IFS=''
      read -r -s result </dev/tty
      echo >&2   # newline after silent input
      ;;
  esac

  if [[ -z "$result" ]]; then
    echo "Passphrase cannot be empty." >&2
    return 1
  fi

  RESULT="$result"
  return 0
}

# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------
if [[ "$CONFIRM" == "false" ]]; then
  # Single-prompt mode
  if ! _prompt_once "$TITLE"; then
    exit 1
  fi
  printf '%s' "$RESULT"

else
  # Double-prompt confirm mode
  if ! _prompt_once "$TITLE"; then
    exit 1
  fi
  PASS1="$RESULT"

  CONFIRM_TITLE="${TITLE} (confirm)"
  if ! _prompt_once "$CONFIRM_TITLE"; then
    exit 1
  fi
  PASS2="$RESULT"

  if [[ "$PASS1" != "$PASS2" ]]; then
    echo "Error: passphrases do not match." >&2
    # Show error dialog if GUI is available
    case "$METHOD" in
      kdialog)
        kdialog --error "Passphrases do not match." &>/dev/null || true
        ;;
      zenity)
        zenity --error --text="Passphrases do not match." &>/dev/null || true
        ;;
      osascript)
        osascript -e 'tell application "System Events" to display alert "Passphrases do not match."' &>/dev/null || true
        ;;
    esac
    exit 1
  fi

  printf '%s' "$PASS1"
fi
