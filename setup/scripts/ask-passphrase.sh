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
  local proc_version="${_ASK_PASS_PROC_VERSION:-/proc/version}"
  local has_tty="${_ASK_PASS_HAS_TTY:-auto}"

  # Auto-detect TTY availability
  if [[ "$has_tty" == "auto" ]]; then
    [ -t 0 ] && has_tty=true || has_tty=false
  fi

  # Claude Code / no-TTY on WSL → PowerShell WPF dialog
  if [[ "$has_tty" == "false" ]] && [[ -f "$proc_version" ]] \
     && grep -qi "microsoft" "$proc_version" 2>/dev/null; then
    echo "powershell_wpf"
    return
  fi

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
    powershell_wpf)
      local wpf_result="${_ASK_PASS_WPF_RESULT_FILE:-/mnt/c/temp/_vp_$$.bin}"
      local wpf_ps1="${_ASK_PASS_WPF_PS1_FILE:-/mnt/c/temp/_ask_vp_$$.ps1}"
      rm -f "$wpf_result"

      # Write the PowerShell script (avoids quoting hell through cmd.exe)
      cat > "$wpf_ps1" << 'PSEOF'
Add-Type -AssemblyName PresentationFramework
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="TITLE_PLACEHOLDER" Height="150" Width="350"
        WindowStartupLocation="CenterScreen" Topmost="True">
  <StackPanel Margin="15">
    <TextBlock Text="TITLE_PLACEHOLDER" Margin="0,0,0,8"/>
    <PasswordBox Name="pb" Margin="0,0,0,10"/>
    <Button Name="ok" Content="OK" Width="80" IsDefault="True"/>
  </StackPanel>
</Window>
"@
$reader = New-Object System.Xml.XmlNodeReader $xaml
$w = [Windows.Markup.XamlReader]::Load($reader)
$pb = $w.FindName('pb')
$ok = $w.FindName('ok')
$ok.Add_Click({ $w.DialogResult = $true; $w.Close() })
if ($w.ShowDialog()) {
    [IO.File]::WriteAllBytes('RESULT_PLACEHOLDER', [Text.Encoding]::UTF8.GetBytes($pb.Password))
}
PSEOF
      # Patch placeholders — escape backslashes for sed replacement (CFG-238 fix:
      # \t in C:\temp\ was interpreted as TAB, corrupting the result path)
      local win_result
      win_result=$(echo "$wpf_result" | sed 's|^/mnt/\([a-z]\)/|\U\1:\\|; s|/|\\|g')
      local win_result_escaped
      win_result_escaped=$(printf '%s' "$win_result" | sed 's/\\/\\\\/g')
      local title_escaped
      title_escaped=$(printf '%s' "$prompt_title" | sed 's/\\/\\\\/g; s/|/\\|/g')
      sed -i "s|TITLE_PLACEHOLDER|${title_escaped}|g" "$wpf_ps1"
      sed -i "s|RESULT_PLACEHOLDER|${win_result_escaped}|g" "$wpf_ps1"

      local win_ps1
      win_ps1=$(echo "$wpf_ps1" | sed 's|^/mnt/\([a-z]\)/|\U\1:\\|; s|/|\\|g')

      # Execute (mockable via _ASK_PASS_WPF_CMD)
      if declare -F _ASK_PASS_WPF_CMD &>/dev/null; then
        _ASK_PASS_WPF_CMD "$win_ps1" || { rm -f "$wpf_ps1" "$wpf_result"; return 1; }
      else
        cmd.exe /c "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $win_ps1" \
          >/dev/null 2>&1 || { rm -f "$wpf_ps1" "$wpf_result"; return 1; }
      fi

      # Read result
      if [[ -f "$wpf_result" ]]; then
        result=$(cat "$wpf_result")
        rm -f "$wpf_result" "$wpf_ps1"
      else
        rm -f "$wpf_ps1"
        return 1
      fi
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
# Source guard — when sourced for testing, only define functions
# ---------------------------------------------------------------------------
if [[ "${ASK_PASS_SOURCE_ONLY:-0}" == "1" ]]; then
  METHOD="${ASK_PASS_FORCE_METHOD:-$(_detect_method)}"
  return 0 2>/dev/null || exit 0
fi

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
