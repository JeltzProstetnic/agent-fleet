#!/usr/bin/env bash
# audit-tools.sh — Generate system tools inventory for the current machine
# Usage: audit-tools.sh [--stdout | --update FILE]
# --stdout (default): print markdown section to stdout
# --update FILE: replace current machine's section in FILE in-place

set -euo pipefail

# --- Machine detection (mirrors CLAUDE.md Machine Identity table) ---
detect_machine() {
    local hostname
    hostname=$(hostname)
    local user
    user=$(whoami)

    # Add your own machine detection rules here.
    # Match hostname patterns, usernames, or other environment signals.
    # Examples:
    #   if [[ "$hostname" == "myserver" ]]; then echo "my-server"; return; fi
    #   if [[ "$hostname" == WORK* ]]; then echo "work-laptop"; return; fi
    #   if [[ -d /mnt/c ]]; then echo "wsl"; return; fi
    echo "${hostname}"
}

# --- Helper: check if command exists, return version or "NOT INSTALLED" ---
check_tool() {
    local cmd="$1"
    local version_flag="${2:---version}"
    if command -v "$cmd" &>/dev/null; then
        local ver
        ver=$("$cmd" $version_flag 2>&1 | head -1) || ver="installed"
        echo "$ver"
    else
        echo "NOT INSTALLED"
    fi
}

# --- Helper: check tool, output table row ---
tool_row() {
    local name="$1"
    local cmd="${2:-$name}"
    local version_flag="${3:---version}"
    local result
    result=$(check_tool "$cmd" "$version_flag")
    if [[ "$result" == "NOT INSTALLED" ]]; then
        echo "| $name | NOT INSTALLED | — |"
    else
        # Trim to something reasonable
        local short
        short=$(echo "$result" | sed 's/^.*[Vv]ersion[: ]*//' | head -c 60)
        echo "| $name | installed | $short |"
    fi
}

# --- Helper: simple installed/not row ---
simple_row() {
    local name="$1"
    local cmd="${2:-$name}"
    if command -v "$cmd" &>/dev/null; then
        local ver
        ver=$("$cmd" --version 2>&1 | head -1 | grep -oP '[\d]+\.[\d]+[.\d]*' | head -1) || ver=""
        if [[ -n "$ver" ]]; then
            echo "| $name | $ver |"
        else
            echo "| $name | installed |"
        fi
    else
        echo "| $name | NOT INSTALLED |"
    fi
}

# --- Detect OS ---
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$NAME $VERSION_ID"
    else
        uname -s
    fi
}

# --- Generate the section ---
generate_section() {
    local machine_id
    machine_id=$(detect_machine)
    local os
    os=$(detect_os)
    local today
    today=$(date -u +%Y-%m-%d)

    cat <<EOF
## $machine_id ($os)

**Audited:** $today

### PDF/Document Conversion
| Tool | Status | Path/Version |
|------|--------|-------------|
$(tool_row "pandoc")
$(tool_row "weasyprint")
$(tool_row "xelatex" "xelatex" "-version")
$(tool_row "pdflatex" "pdflatex" "-version")
$(tool_row "wkhtmltopdf")

### Python
EOF

    if command -v python3 &>/dev/null; then
        local pyver
        pyver=$(python3 --version 2>&1)
        echo "- **Version:** $pyver"

        # Check key packages
        local key_packages="openpyxl python-pptx matplotlib pandas numpy pillow beautifulsoup4 flask requests rich Pygments Jinja2 PyYAML markdown-it-py weasyprint"
        local installed=()
        local missing=()
        for pkg in $key_packages; do
            if python3 -c "import importlib; importlib.import_module('${pkg//-/_}')" 2>/dev/null; then
                installed+=("$pkg")
            else
                missing+=("$pkg")
            fi
        done
        if [[ ${#installed[@]} -gt 0 ]]; then
            local joined
            joined=$(printf '%s, ' "${installed[@]}")
            echo "- **Key packages:** ${joined%, }"
        fi
        if [[ ${#missing[@]} -gt 0 ]]; then
            local joined
            joined=$(printf '%s, ' "${missing[@]}")
            echo "- **Missing:** ${joined%, }"
        fi
    else
        echo "- **python3:** NOT INSTALLED"
    fi

    cat <<EOF

### Node.js
EOF
    if command -v node &>/dev/null; then
        echo "- **Version:** $(node --version 2>&1)"
        if command -v npm &>/dev/null; then
            echo "- **npm:** $(npm --version 2>&1)"
        else
            echo "- **npm:** NOT INSTALLED"
        fi
    else
        echo "- **node:** NOT INSTALLED"
    fi

    cat <<EOF

### Git/GitHub
| Tool | Status |
|------|--------|
$(simple_row "git")
$(simple_row "gh")

### Containers
| Tool | Status |
|------|--------|
$(simple_row "docker")
$(simple_row "podman")

### Search/File Tools
| Tool | Status |
|------|--------|
$(simple_row "rg" "rg")
$(simple_row "fd")
$(simple_row "bat")
$(simple_row "fzf")

### Media
| Tool | Status |
|------|--------|
$(simple_row "ffmpeg")
$(simple_row "imagemagick" "convert")

### System Tools
| Tool | Status |
|------|--------|
$(simple_row "tmux")
$(simple_row "screen")
$(simple_row "htop")
$(simple_row "curl")
$(simple_row "wget")
$(simple_row "jq")
$(simple_row "openssl")
EOF
}

# --- Main ---
MODE="--stdout"
FILE=""

if [[ $# -ge 1 ]]; then
    MODE="$1"
fi
if [[ $# -ge 2 ]]; then
    FILE="$2"
fi

SECTION=$(generate_section)
MACHINE_ID=$(detect_machine)

case "$MODE" in
    --stdout)
        echo "$SECTION"
        ;;
    --update)
        if [[ -z "$FILE" ]]; then
            echo "Error: --update requires a FILE argument" >&2
            exit 1
        fi
        if [[ ! -f "$FILE" ]]; then
            echo "Error: File not found: $FILE" >&2
            exit 1
        fi

        # Replace the machine's section in the file
        # A section starts with "## machine-id" and ends before the next "## " or EOF
        TEMP=$(mktemp)
        awk -v machine="## $MACHINE_ID" -v replacement="$SECTION" '
            BEGIN { in_section=0; replaced=0 }
            $0 ~ "^" machine " " || $0 == machine {
                if (!replaced) {
                    print replacement
                    replaced=1
                }
                in_section=1
                next
            }
            in_section && /^## / {
                in_section=0
            }
            !in_section { print }
        ' "$FILE" > "$TEMP"

        mv "$TEMP" "$FILE"
        echo "Updated $MACHINE_ID section in $FILE"
        ;;
    *)
        echo "Usage: $0 [--stdout | --update FILE]" >&2
        exit 1
        ;;
esac
