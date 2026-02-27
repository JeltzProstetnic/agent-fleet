#!/usr/bin/env bash
# infra-discover.sh — Network & environment discovery script
#
# Produces a structured markdown report of the local infrastructure:
# network interfaces, gateways, DNS, public IP, peers, SSH hosts,
# Docker containers, cloud CLIs, tunnels/VPNs, and listening ports.
#
# Works on Linux, macOS, WSL, and SteamOS (Arch-based).
# Make executable: chmod +x infra-discover.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# try_cmd: run a command with a timeout, return output or empty string.
# Usage: result=$(try_cmd <timeout_seconds> <command> [args...])
try_cmd() {
    local timeout_sec="$1"; shift
    if command -v timeout &>/dev/null; then
        timeout "$timeout_sec" "$@" 2>/dev/null || true
    else
        # macOS lacks coreutils timeout; use a background job + wait
        "$@" 2>/dev/null &
        local pid=$!
        ( sleep "$timeout_sec" && kill "$pid" 2>/dev/null ) &
        local watcher=$!
        wait "$pid" 2>/dev/null || true
        kill "$watcher" 2>/dev/null || true
        wait "$watcher" 2>/dev/null || true
    fi
}

# has_cmd: check if a command exists
has_cmd() { command -v "$1" &>/dev/null; }

# section_header: print a markdown section header
section_header() { printf '\n## %s\n\n' "$1"; }

# not_detected: placeholder when a section has no data
not_detected() { echo "_(not detected)_"; }

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

detect_platform() {
    if [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        echo "macos"
    else
        echo "linux"
    fi
}

PLATFORM=$(detect_platform)

# ---------------------------------------------------------------------------
# Report header
# ---------------------------------------------------------------------------

cat <<EOF
# Infrastructure Map

Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Machine: $(hostname)
Platform: ${PLATFORM}
EOF

# ---------------------------------------------------------------------------
# 1. Network Interfaces
# ---------------------------------------------------------------------------

section_header "Network Interfaces"

if has_cmd ip; then
    output=$(try_cmd 5 ip -brief addr show)
    if [[ -n "$output" ]]; then
        echo '```'
        echo "$output"
        echo '```'
    else
        not_detected
    fi
elif has_cmd ifconfig; then
    output=$(try_cmd 5 ifconfig)
    if [[ -n "$output" ]]; then
        echo '```'
        echo "$output"
        echo '```'
    else
        not_detected
    fi
else
    not_detected
fi

# ---------------------------------------------------------------------------
# 2. Gateway & DNS
# ---------------------------------------------------------------------------

section_header "Gateway & DNS"

# Default gateway
echo "### Default Gateway"
echo ""
if has_cmd ip; then
    gw=$(try_cmd 5 ip route show default)
    if [[ -n "$gw" ]]; then
        echo '```'
        echo "$gw"
        echo '```'
    else
        not_detected
    fi
elif has_cmd route; then
    gw=$(try_cmd 5 route -n get default 2>/dev/null || try_cmd 5 route -n 2>/dev/null)
    if [[ -n "$gw" ]]; then
        echo '```'
        echo "$gw"
        echo '```'
    else
        not_detected
    fi
else
    not_detected
fi

echo ""
echo "### DNS Servers"
echo ""

# Try resolvectl first (systemd-resolved), then fall back to resolv.conf
if has_cmd resolvectl; then
    dns=$(try_cmd 5 resolvectl status 2>/dev/null | grep -E 'DNS Servers|DNS Server' || true)
    if [[ -n "$dns" ]]; then
        echo '```'
        echo "$dns"
        echo '```'
    elif [[ -f /etc/resolv.conf ]]; then
        nameservers=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null || true)
        if [[ -n "$nameservers" ]]; then
            echo '```'
            echo "$nameservers"
            echo '```'
        else
            not_detected
        fi
    else
        not_detected
    fi
elif [[ -f /etc/resolv.conf ]]; then
    nameservers=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null || true)
    if [[ -n "$nameservers" ]]; then
        echo '```'
        echo "$nameservers"
        echo '```'
    else
        not_detected
    fi
else
    not_detected
fi

# ---------------------------------------------------------------------------
# 3. Public IP & NAT Detection
# ---------------------------------------------------------------------------

section_header "Public IP & NAT Detection"

public_ip=$(try_cmd 5 curl -s --max-time 5 https://ifconfig.me)
if [[ -n "$public_ip" ]]; then
    echo "**Public IP:** \`${public_ip}\`"

    # Collect local IPs for NAT comparison
    local_ips=""
    if has_cmd ip; then
        local_ips=$(ip -4 addr show 2>/dev/null \
            | sed -n 's/.*inet \([0-9.]*\).*/\1/p' \
            | grep -v '^127\.' || true)
    elif has_cmd ifconfig; then
        local_ips=$(ifconfig 2>/dev/null \
            | grep -oE 'inet [0-9.]+' \
            | awk '{print $2}' \
            | grep -v '^127\.' || true)
    fi

    if [[ -n "$local_ips" ]]; then
        if echo "$local_ips" | grep -qF "$public_ip"; then
            echo "**NAT:** No (public IP matches a local interface)"
        else
            echo "**NAT:** Yes (public IP does not match any local interface)"
        fi
    fi
else
    not_detected
fi

# ---------------------------------------------------------------------------
# 4. Local Network Peers
# ---------------------------------------------------------------------------

section_header "Local Network Peers"

# ARP / neighbor table
peers=""
if has_cmd ip; then
    peers=$(try_cmd 5 ip neigh show)
elif has_cmd arp; then
    peers=$(try_cmd 5 arp -a)
fi

if [[ -n "$peers" ]]; then
    echo '```'
    echo "$peers"
    echo '```'
else
    not_detected
fi

# mDNS / Avahi
if has_cmd avahi-browse; then
    echo ""
    echo "### mDNS (Avahi)"
    echo ""
    mdns=$(try_cmd 5 avahi-browse -alrpt 2>/dev/null | head -30)
    if [[ -n "$mdns" ]]; then
        echo '```'
        echo "$mdns"
        echo '```'
    else
        echo "_(avahi-browse found but returned no results)_"
    fi
fi

# ---------------------------------------------------------------------------
# 5. SSH Config Hosts
# ---------------------------------------------------------------------------

section_header "SSH Config Hosts"

ssh_config="${HOME}/.ssh/config"
if [[ -f "$ssh_config" ]]; then
    # Extract Host entries (skip wildcards)
    hosts=$(grep -i '^Host ' "$ssh_config" 2>/dev/null \
        | awk '{print $2}' \
        | grep -v '[*?]' || true)

    if [[ -n "$hosts" ]]; then
        echo "| Host | Ping |"
        echo "|------|------|"
        while IFS= read -r host; do
            if try_cmd 3 ping -c 1 -W 1 "$host" &>/dev/null; then
                echo "| \`${host}\` | reachable |"
            else
                echo "| \`${host}\` | unreachable |"
            fi
        done <<< "$hosts"
    else
        echo "_(no host entries found)_"
    fi
else
    echo "_(no ~/.ssh/config)_"
fi

# ---------------------------------------------------------------------------
# 6. Docker Containers
# ---------------------------------------------------------------------------

section_header "Docker Containers"

if has_cmd docker; then
    containers=$(try_cmd 5 docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null)
    if [[ -n "$containers" ]]; then
        echo '```'
        echo "$containers"
        echo '```'
    else
        echo "_(docker available but no running containers or permission denied)_"
    fi
else
    not_detected
fi

# ---------------------------------------------------------------------------
# 7. Cloud CLIs
# ---------------------------------------------------------------------------

section_header "Cloud CLIs"

found_cloud=false
for cli in aws az gcloud doctl flyctl; do
    if has_cmd "$cli"; then
        version=$(try_cmd 3 "$cli" --version 2>&1 | head -1)
        echo "- **${cli}**: ${version:-installed}"
        found_cloud=true
    fi
done

if [[ "$found_cloud" == false ]]; then
    not_detected
fi

# ---------------------------------------------------------------------------
# 8. Tunnels & VPNs
# ---------------------------------------------------------------------------

section_header "Tunnels & VPNs"

found_tunnel=false

# WireGuard
if has_cmd wg; then
    wg_output=$(try_cmd 5 sudo wg show 2>/dev/null || try_cmd 5 wg show 2>/dev/null)
    if [[ -n "$wg_output" ]]; then
        echo "### WireGuard"
        echo '```'
        echo "$wg_output"
        echo '```'
        found_tunnel=true
    fi
fi

# Tailscale
if has_cmd tailscale; then
    ts_status=$(try_cmd 5 tailscale status 2>/dev/null)
    if [[ -n "$ts_status" ]]; then
        echo "### Tailscale"
        echo '```'
        echo "$ts_status"
        echo '```'
        found_tunnel=true
    else
        echo "- **tailscale**: installed (status unavailable)"
        found_tunnel=true
    fi
fi

# Cloudflared
if has_cmd cloudflared; then
    cf_version=$(try_cmd 3 cloudflared --version 2>&1 | head -1)
    echo "- **cloudflared**: ${cf_version:-installed}"
    found_tunnel=true
fi

# ngrok
if has_cmd ngrok; then
    ngrok_version=$(try_cmd 3 ngrok version 2>&1 | head -1)
    echo "- **ngrok**: ${ngrok_version:-installed}"
    found_tunnel=true
fi

if [[ "$found_tunnel" == false ]]; then
    not_detected
fi

# ---------------------------------------------------------------------------
# 9. Listening Ports
# ---------------------------------------------------------------------------

section_header "Listening Ports"

if has_cmd ss; then
    ports=$(try_cmd 5 ss -tlnp 2>/dev/null)
    if [[ -n "$ports" ]]; then
        echo '```'
        echo "$ports"
        echo '```'
    else
        not_detected
    fi
elif has_cmd netstat; then
    ports=$(try_cmd 5 netstat -tlnp 2>/dev/null)
    if [[ -n "$ports" ]]; then
        echo '```'
        echo "$ports"
        echo '```'
    else
        not_detected
    fi
else
    not_detected
fi

# ---------------------------------------------------------------------------
# Footer
# ---------------------------------------------------------------------------

echo ""
echo "---"
echo "_Report complete._"
