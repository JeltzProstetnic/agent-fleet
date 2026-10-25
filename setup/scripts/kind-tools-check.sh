#!/usr/bin/env bash
# kind-tools-check.sh — list the tools the user's project kinds need that are missing here,
# each with an install hint for this OS (CFG-829). SUGGESTS ONLY: it never runs a package
# manager; onboarding shows the list and installs only on the user's yes.
#
#   kind-tools-check.sh [kind ...]     e.g.  kind-tools-check.sh writing code
#
# `all` rows are always checked. Exit 0 = nothing missing, 1 = something missing,
# 2 = unknown kind. Table: setup/config/project-kind-tools.conf (KIND_TOOLS_CONF overrides);
# package manager auto-detected (KIND_TOOLS_OS=apt|dnf|pacman|brew overrides).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${KIND_TOOLS_CONF:-$SCRIPT_DIR/../config/project-kind-tools.conf}"

detect_pm() {
    [[ -n "${KIND_TOOLS_OS:-}" ]] && { echo "$KIND_TOOLS_OS"; return; }
    [[ "$(uname -s)" == Darwin ]] && { echo brew; return; }
    local id=""
    [[ -r /etc/os-release ]] && id=$(. /etc/os-release; echo "${ID:-} ${ID_LIKE:-}")
    case " $id " in
        *" debian "*|*" ubuntu "*)               echo apt ;;
        *" fedora "*|*" rhel "*|*" centos "*)    echo dnf ;;
        *" arch "*|*" steamos "*)               echo pacman ;;
        *)                                       echo apt ;;
    esac
}

# The hint text for package $2 under manager $1 (printed, never executed).
install_hint() {
    local pm="$1" pkg="$2"
    [[ "$pkg" == "-" ]] && { echo "not packaged here — see the tool's site"; return; }
    case "$pm" in
        apt)    echo "sudo apt install $pkg" ;;
        dnf)    echo "sudo dnf install $pkg" ;;
        pacman) echo "sudo pacman -S $pkg" ;;
        brew)   echo "brew install $pkg" ;;
    esac
}

rows=$(awk -F'|' '!/^[[:space:]]*(#|$)/ { for (i=1;i<=NF;i++) gsub(/^[ \t]+|[ \t]+$/,"",$i); print $1"\t"$2"\t"$3"\t"$4"\t"$5"\t"$6"\t"$7"\t"$8 }' "$CONF")
known=$(cut -f1 <<<"$rows" | sort -u | grep -vx all | tr '\n' ' ')
for k in "$@"; do
    grep -qx -- "$k" <<<"$(cut -f1 <<<"$rows")" || { echo "unknown kind: $k (known: $known)" >&2; exit 2; }
done

pm=$(detect_pm); col=4
case "$pm" in apt) col=4 ;; dnf) col=5 ;; pacman) col=6 ;; brew) col=7 ;; esac
wanted=" all $* "
missing=0 seen=" "
while IFS=$'\t' read -r kind tool check _ _ _ _ why; do
    [[ "$wanted" == *" $kind "* ]] || continue
    [[ "$seen" == *" $tool "* ]] && continue
    seen+="$tool "
    bash -c "$check" >/dev/null 2>&1 && continue
    pkg=$(awk -F'\t' -v t="$tool" -v c="$col" '$2==t {print $c; exit}' <<<"$rows")
    printf '%-12s %-36s %s\n' "$tool" "$(install_hint "$pm" "$pkg")" "($kind: $why)"
    missing=$((missing + 1))
done <<<"$rows"

[[ $missing -eq 0 ]] && { echo "all tools present for: all $*"; exit 0; }
exit 1
