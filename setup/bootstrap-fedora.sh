#!/usr/bin/env bash
#
# bootstrap-fedora.sh — One-shot system dependency installer for Fedora
# =====================================================================
# Run with sudo: sudo bash bootstrap-fedora.sh
#
# Installs everything that needs root on a Fedora workstation so that
# Claude Code (mclaude via cc-mirror) and the LaTeX/PDF toolchain
# can run as the unprivileged user (LaTeX/PDF toolchain, gh CLI, etc.).
#
# This script is idempotent — safe to re-run.
#

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}${BOLD}── Step $1/$2: $3 ──${NC}"; }
log_skip()  { echo -e "    ${YELLOW}skip${NC} $*"; }
log_inst()  { echo -e "    ${GREEN}install${NC} $*"; }

TOTAL_STEPS=4
INSTALLED=()
SKIPPED=()

# ── Guard: must be root ────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run with sudo:${NC}"
    echo "  sudo bash $0"
    exit 1
fi

# ── Step 1: Core system packages ───────────────────────────────────
log_step 1 $TOTAL_STEPS "Core system packages"

core_packages=(
    # Build essentials
    gcc
    gcc-c++
    make
    # Dev tools
    git
    curl
    jq
    socat
    bubblewrap
    # Python
    python3
    python3-pip
    pipx
)

for pkg in "${core_packages[@]}"; do
    if rpm -q "$pkg" &>/dev/null; then
        log_skip "$pkg (already installed)"
        SKIPPED+=("$pkg")
    else
        log_inst "$pkg"
        INSTALLED+=("$pkg")
    fi
done

needed=()
for pkg in "${core_packages[@]}"; do
    rpm -q "$pkg" &>/dev/null || needed+=("$pkg")
done

if [[ ${#needed[@]} -gt 0 ]]; then
    dnf install -y "${needed[@]}"
else
    echo "    All core packages present."
fi

# ── Step 2: GitHub CLI ─────────────────────────────────────────────
log_step 2 $TOTAL_STEPS "GitHub CLI (gh)"

if command -v gh &>/dev/null; then
    log_skip "gh $(gh --version | head -1) already installed"
    SKIPPED+=(gh)
else
    dnf install -y gh
    log_inst "gh $(gh --version | head -1)"
    INSTALLED+=(gh)
fi

# ── Step 3: Pandoc + LaTeX (PDF toolchain) ─────────────────────────
log_step 3 $TOTAL_STEPS "Pandoc + LaTeX (PDF toolchain)"

latex_packages=(
    pandoc
    texlive-scheme-basic
    texlive-collection-fontsrecommended
    texlive-collection-latexrecommended
    # Extra packages commonly needed for markdown→PDF via pandoc
    texlive-amsmath
    texlive-unicode-math
    texlive-xetex
    texlive-booktabs
    texlive-fancyvrb
    texlive-upquote
    texlive-microtype
    texlive-parskip
    texlive-xurl
    texlive-bookmark
    texlive-footnotehyper
)

needed_latex=()
for pkg in "${latex_packages[@]}"; do
    if rpm -q "$pkg" &>/dev/null; then
        log_skip "$pkg"
        SKIPPED+=("$pkg")
    else
        needed_latex+=("$pkg")
    fi
done

if [[ ${#needed_latex[@]} -gt 0 ]]; then
    echo "    Installing ${#needed_latex[@]} LaTeX/pandoc packages..."
    dnf install -y "${needed_latex[@]}"
    for pkg in "${needed_latex[@]}"; do
        log_inst "$pkg"
        INSTALLED+=("$pkg")
    done
else
    echo "    All LaTeX/pandoc packages present."
fi

# ── Step 4: Verification ──────────────────────────────────────────
log_step 4 $TOTAL_STEPS "Verification"

verify_cmds=(git curl jq gh pandoc pdflatex xelatex python3 pip3 gcc make socat bwrap)
all_ok=true

for cmd in "${verify_cmds[@]}"; do
    if command -v "$cmd" &>/dev/null; then
        ver=$($cmd --version 2>/dev/null | head -1 || echo "ok")
        echo -e "    ${GREEN}✓${NC} $cmd  ($ver)"
    else
        echo -e "    ${RED}✗${NC} $cmd  MISSING"
        all_ok=false
    fi
done

# ── Summary ────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════${NC}"
if [[ ${#INSTALLED[@]} -gt 0 ]]; then
    echo -e "${GREEN}${BOLD}Installed (${#INSTALLED[@]}):${NC} ${INSTALLED[*]}"
fi
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo -e "${BLUE}Already present (${#SKIPPED[@]}):${NC} ${#SKIPPED[@]} packages"
fi

if $all_ok; then
    echo -e "\n${GREEN}${BOLD}All good. System is ready for Claude Code on Fedora.${NC}"
else
    echo -e "\n${YELLOW}${BOLD}Some tools missing — check output above.${NC}"
fi
echo -e "${BOLD}════════════════════════════════════════${NC}"
