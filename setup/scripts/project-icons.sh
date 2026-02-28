#!/usr/bin/env bash
# project-icons.sh — Generate priority badge icons and apply them to project folders
#
# Usage:
#   bash project-icons.sh generate          # Generate .ico and .png badge icons
#   bash project-icons.sh apply-windows     # Create Windows shortcut hub with icons
#   bash project-icons.sh apply-kde         # Apply icons to KDE Dolphin via .directory files
#   bash project-icons.sh apply-all         # Both Windows + KDE
#   bash project-icons.sh clean-windows     # Remove Windows shortcut hub
#   bash project-icons.sh clean-kde         # Remove .directory files from project folders
#
# Priority colors:
#   P1 = red (#DC2828)    — critical/daily
#   P2 = orange (#F59E0B) — active/weekly
#   P3 = blue (#3B82F6)   — ongoing/as-needed
#   P4 = gray (#9CA3AF)   — paused
#   P5 = dim (#6B7280)    — dormant
#
# Architecture:
#   - Icons stored in ~/agent-fleet/setup/icons/ (committed to repo)
#   - Windows: shortcut hub on NTFS at C:\Users\<user>\Projects\ (desktop.ini
#     doesn't work on \\wsl.localhost ext4 paths — Windows file attributes
#     don't persist on non-NTFS filesystems)
#   - KDE: .directory files inside each project folder (Dolphin reads them natively)
#
# Dependencies:
#   - Python 3 + Pillow (for icon generation)
#   - PowerShell (for Windows shortcut creation, via WSL interop)
#   - kwriteconfig5 or kwriteconfig6 (for KDE, only needed on Fedora)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ICON_DIR="$REPO_DIR/setup/icons"
REGISTRY="$REPO_DIR/registry.md"

# Windows hub location (NTFS — required for desktop.ini/attrib to work)
WIN_HUB_PARENT='C:\Users'
WIN_HUB_NAME="Projects"

# --- Icon generation -----------------------------------------------------------

generate_icons() {
    mkdir -p "$ICON_DIR"

    python3 << 'PYEOF'
import os
from PIL import Image, ImageDraw

ICON_DIR = os.environ.get("ICON_DIR", os.path.expanduser("~/agent-fleet/setup/icons"))
os.makedirs(ICON_DIR, exist_ok=True)

# Priority color map: (R, G, B)
PRIORITIES = {
    "P1": (220, 40, 40),    # red
    "P2": (245, 158, 11),   # orange
    "P3": (59, 130, 246),   # blue
    "P4": (156, 163, 175),  # gray
    "P5": (107, 114, 128),  # dim gray
}

ICO_SIZES = [(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
# For KDE, a single 128x128 PNG is sufficient
KDE_SIZE = 128

for priority, (r, g, b) in PRIORITIES.items():
    # Create high-res base image (256x256)
    base = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    draw = ImageDraw.Draw(base)

    # Filled circle with slight padding
    margin = 16
    draw.ellipse(
        [margin, margin, 255 - margin, 255 - margin],
        fill=(r, g, b, 255),
    )

    # Optional: add a subtle lighter highlight on top-left for 3D effect
    highlight = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    hdraw = ImageDraw.Draw(highlight)
    hdraw.ellipse(
        [margin + 20, margin + 10, margin + 100, margin + 70],
        fill=(255, 255, 255, 50),
    )
    base = Image.alpha_composite(base, highlight)

    # Save .ico (multi-size for Windows)
    ico_path = os.path.join(ICON_DIR, f"{priority.lower()}.ico")
    base.save(ico_path, format="ICO", sizes=ICO_SIZES)

    # Save .png (single size for KDE)
    png_path = os.path.join(ICON_DIR, f"{priority.lower()}.png")
    png = base.resize((KDE_SIZE, KDE_SIZE), Image.LANCZOS)
    png.save(png_path, format="PNG")

    print(f"  {priority}: {ico_path} + {png_path}")

print(f"\nAll icons generated in {ICON_DIR}")
PYEOF
}

# --- Parse registry -----------------------------------------------------------

# Outputs lines: PRIORITY|PATH|PROJECT_NAME
parse_registry() {
    # Skip header lines, extract Priority, Path, and Project columns
    awk -F'|' '
        /^\| [a-zA-Z]/ && !/^\| Project/ && !/^\| Machine/ {
            gsub(/^[ \t]+|[ \t]+$/, "", $2)  # project name
            gsub(/^[ \t]+|[ \t]+$/, "", $3)  # priority
            gsub(/^[ \t]+|[ \t]+$/, "", $4)  # path
            if ($3 ~ /^P[1-5]$/ && $4 ~ /^`~/) {
                # Strip backticks from path
                gsub(/`/, "", $4)
                # Expand ~ to HOME
                sub(/^~/, ENVIRON["HOME"], $4)
                print $3 "|" $4 "|" $2
            }
        }
    ' "$REGISTRY"
}

# --- Windows approach ----------------------------------------------------------
#
# PROBLEM: desktop.ini + attrib don't work on \\wsl.localhost\Ubuntu\... paths.
# Windows file attributes (System, Hidden) don't persist on ext4 filesystems.
# attrib.exe runs without error but the flags silently don't stick.
#
# SOLUTION: Create a "Projects" shortcut hub folder on NTFS (C:\Users\<user>\)
# containing .lnk shortcuts to each WSL project, with custom priority icons.
# The .ico files are also stored on NTFS so Windows can read them.
#
# The hub folder itself gets a desktop.ini for a nice icon.

apply_windows() {
    if [ ! -d /mnt/c/ ]; then
        echo "ERROR: /mnt/c/ not found — not a WSL environment."
        exit 1
    fi

    # Find Windows username
    WIN_USER=$(powershell.exe -NoProfile -Command '[Environment]::UserName' 2>/dev/null | tr -d '\r' || echo "")
    if [ -z "$WIN_USER" ]; then
        echo "ERROR: Could not determine Windows username."
        exit 1
    fi

    WIN_HUB_WIN="${WIN_HUB_PARENT}\\${WIN_USER}\\${WIN_HUB_NAME}"
    WIN_HUB_LINUX="/mnt/c/Users/${WIN_USER}/${WIN_HUB_NAME}"
    WIN_ICONS_WIN="${WIN_HUB_WIN}\\icons"
    WIN_ICONS_LINUX="${WIN_HUB_LINUX}/icons"

    echo "Windows hub: ${WIN_HUB_WIN}"
    echo "Linux path:  ${WIN_HUB_LINUX}"
    echo ""

    # Create hub + icons dir on NTFS
    mkdir -p "$WIN_ICONS_LINUX"

    # Copy .ico files to NTFS
    for ico in "$ICON_DIR"/*.ico; do
        [ -f "$ico" ] || continue
        cp "$ico" "$WIN_ICONS_LINUX/"
        echo "  Copied $(basename "$ico") to NTFS icons dir"
    done

    # Create shortcuts for each project
    echo ""
    echo "Creating shortcuts..."

    # Build a PowerShell script that creates all shortcuts in one call
    # (avoids the stdin-consumption bug where powershell.exe eats the pipe)
    local ps_script="${WIN_HUB_LINUX}/_create-shortcuts.ps1"

    cat > "$ps_script" << 'PSHEADER'
$ws = New-Object -ComObject WScript.Shell
PSHEADER

    local count=0
    while IFS='|' read -r priority path name; do
        if [ ! -d "$path" ]; then
            echo "  SKIP $name ($path not found)"
            continue
        fi

        priority_lower=$(echo "$priority" | tr 'A-Z' 'a-z')
        wsl_win_path=$(wslpath -w "$path" 2>/dev/null)

        if [ -z "$wsl_win_path" ]; then
            echo "  SKIP $name (could not convert path)"
            continue
        fi

        # Escape backslashes for PowerShell string
        wsl_win_escaped=$(echo "$wsl_win_path" | sed 's/\\/\\\\/g')
        ico_escaped=$(echo "${WIN_ICONS_WIN}\\${priority_lower}.ico" | sed 's/\\/\\\\/g')
        lnk_escaped=$(echo "${WIN_HUB_WIN}\\${name}.lnk" | sed 's/\\/\\\\/g')

        cat >> "$ps_script" << PSENTRY
\$sc = \$ws.CreateShortcut("${lnk_escaped}")
\$sc.TargetPath = "${wsl_win_escaped}"
\$sc.IconLocation = "${ico_escaped},0"
\$sc.Description = "${priority} - ${name}"
\$sc.Save()
PSENTRY

        echo "  ${priority} ${name} -> ${wsl_win_path}"
        count=$((count + 1))
    done < <(parse_registry)

    if [ "$count" -gt 0 ]; then
        # Execute the batch PowerShell script
        local ps_win_path
        ps_win_path=$(wslpath -w "$ps_script")
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps_win_path" 2>/dev/null
        echo ""
        echo "  Created $count shortcuts."
    fi

    # Clean up the temporary script
    rm -f "$ps_script"

    # Create desktop.ini for the hub folder itself (use a generic folder icon)
    cat > "${WIN_HUB_LINUX}/desktop.ini" << 'INI'
[.ShellClassInfo]
InfoTip=Project shortcuts with priority badges
IconResource=%SystemRoot%\System32\shell32.dll,43
INI

    attrib.exe +s +h "${WIN_HUB_WIN}\\desktop.ini" 2>/dev/null || true
    attrib.exe +s "${WIN_HUB_WIN}" 2>/dev/null || true

    echo ""
    echo "Done. Hub created at: ${WIN_HUB_WIN}"
    echo ""
    echo "To access: open Explorer, navigate to ${WIN_HUB_WIN}"
    echo "Or pin the folder to Quick Access."
    echo ""
    echo "NOTE: To refresh icon cache if icons don't appear immediately:"
    echo "  ie4uinit.exe -show"
}

clean_windows() {
    WIN_USER=$(powershell.exe -NoProfile -Command '[Environment]::UserName' 2>/dev/null | tr -d '\r' || echo "")
    WIN_HUB_LINUX="/mnt/c/Users/${WIN_USER}/${WIN_HUB_NAME}"

    if [ -d "$WIN_HUB_LINUX" ]; then
        rm -rf "$WIN_HUB_LINUX"
        echo "Removed: $WIN_HUB_LINUX"
    else
        echo "Hub not found at $WIN_HUB_LINUX"
    fi
}

# --- KDE approach --------------------------------------------------------------
#
# KDE Dolphin reads .directory files inside each folder.
# Format:
#   [Desktop Entry]
#   Icon=/absolute/path/to/icon.png
#
# The kwriteconfig5 (or kwriteconfig6 on newer KDE) tool can create these,
# but a plain file write works just as well.
#
# gio set also works:
#   gio set /path/to/folder metadata::custom-icon file:///path/to/icon.png
#
# We use the .directory approach since it's portable and stored in the folder.

apply_kde() {
    echo "Applying KDE Dolphin folder icons..."
    echo ""

    # Determine which kwriteconfig is available
    KWCONFIG=""
    if command -v kwriteconfig6 &>/dev/null; then
        KWCONFIG="kwriteconfig6"
    elif command -v kwriteconfig5 &>/dev/null; then
        KWCONFIG="kwriteconfig5"
    fi

    parse_registry | while IFS='|' read -r priority path name; do
        if [ ! -d "$path" ]; then
            echo "  SKIP $name ($path not found)"
            continue
        fi

        priority_lower=$(echo "$priority" | tr 'A-Z' 'a-z')
        icon_path="${ICON_DIR}/${priority_lower}.png"

        if [ ! -f "$icon_path" ]; then
            echo "  SKIP $name (icon $icon_path not found — run 'generate' first)"
            continue
        fi

        if [ -n "$KWCONFIG" ]; then
            # Use kwriteconfig for proper KDE integration
            $KWCONFIG --file "${path}/.directory" --group 'Desktop Entry' --key 'Icon' "$icon_path"
        else
            # Direct file write (works the same way)
            cat > "${path}/.directory" << EOF
[Desktop Entry]
Icon=${icon_path}
EOF
        fi

        echo "  ${priority} ${name}: .directory -> ${icon_path}"
    done

    echo ""
    echo "Done. Dolphin should pick up icons on next folder view refresh."
    echo "If not visible immediately, close and reopen the Dolphin window."
}

clean_kde() {
    echo "Removing .directory files from project folders..."

    parse_registry | while IFS='|' read -r priority path name; do
        if [ -f "${path}/.directory" ]; then
            rm "${path}/.directory"
            echo "  Removed: ${path}/.directory"
        fi
    done

    echo "Done."
}

# --- Main dispatch -------------------------------------------------------------

case "${1:-help}" in
    generate)
        echo "Generating priority badge icons..."
        ICON_DIR="$ICON_DIR" generate_icons
        ;;
    apply-windows)
        apply_windows
        ;;
    apply-kde)
        apply_kde
        ;;
    apply-all)
        apply_windows
        echo ""
        echo "---"
        echo ""
        apply_kde
        ;;
    clean-windows)
        clean_windows
        ;;
    clean-kde)
        clean_kde
        ;;
    *)
        echo "Usage: $0 {generate|apply-windows|apply-kde|apply-all|clean-windows|clean-kde}"
        echo ""
        echo "  generate       Create .ico and .png badge icons in setup/icons/"
        echo "  apply-windows  Create shortcut hub on NTFS with priority-colored icons"
        echo "  apply-kde      Write .directory files for KDE Dolphin"
        echo "  apply-all      Both Windows + KDE"
        echo "  clean-windows  Remove Windows shortcut hub"
        echo "  clean-kde      Remove .directory files from project folders"
        exit 1
        ;;
esac
